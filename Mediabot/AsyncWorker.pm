package Mediabot::AsyncWorker;

use strict;
use warnings;

use JSON::PP ();
use Time::HiRes ();

our $VERSION = '1.0';

my $DEFAULT_TIMEOUT      = 30;
my $DEFAULT_TERM_GRACE   = 0.5;
my $DEFAULT_FORCE_GRACE  = 2.0;
my $DEFAULT_MAX_OUTPUT   = 64 * 1024;
my $MIN_MAX_OUTPUT       = 256;
my $MAX_MAX_OUTPUT       = 16 * 1024 * 1024;
my $MAX_DETAIL           = 512;
my $PROTOCOL_VERSION     = 1;

sub start {
    my ($class, %args) = @_;

    my $done = $args{on_done};
    return undef unless ref($done) eq 'CODE';

    my $self = bless {
        loop          => $args{loop},
        child         => $args{child},
        on_done       => $done,
        on_progress   => ref($args{on_progress}) eq 'CODE' ? $args{on_progress} : undef,
        label         => _clean_scalar($args{label}, 'worker', 80),
        timeout       => _bounded_number($args{timeout},
            $DEFAULT_TIMEOUT, 0.01, 3600),
        term_grace    => _bounded_number($args{term_grace},
            $DEFAULT_TERM_GRACE, 0.01, 60),
        force_grace   => _bounded_number($args{force_grace},
            $DEFAULT_FORCE_GRACE, 0.05, 60),
        max_output    => _bounded_integer($args{max_output},
            $DEFAULT_MAX_OUTPUT, $MIN_MAX_OUTPUT, $MAX_MAX_OUTPUT),
        started_at    => Time::HiRes::time(),
        buffer        => '',
        bytes         => 0,
        final_record  => undef,
        protocol_error => undef,
        progress_count => 0,
        pipe_eof      => 0,
        child_done    => 0,
        wait_status   => undef,
        finalized     => 0,
        timed_out     => 0,
        cancelled     => 0,
        cancel_reason => undef,
        term_sent     => 0,
        kill_sent     => 0,
        forced        => 0,
    }, $class;

    unless (ref($self->{child}) eq 'CODE') {
        $self->_complete(_error_result(
            'worker_setup', 'child',
            'child callback is required',
        ));
        return undef;
    }

    my $loop = $self->{loop};
    unless ($loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') }) {
        $self->_complete(_error_result(
            'worker_setup', 'event_loop',
            'IO::Async loop with add/remove/watch_process is required',
        ));
        return undef;
    }

    my $deps_ok = eval {
        require IO::Async::Stream;
        require IO::Async::Timer::Countdown;
        require POSIX;
        1;
    };
    unless ($deps_ok) {
        my $error = _exception_text($@ || 'IO::Async worker dependencies unavailable');
        $self->_complete(_error_result(
            'worker_setup', 'dependencies', $error,
        ));
        return undef;
    }

    my ($read_fh, $write_fh);
    unless (pipe($read_fh, $write_fh)) {
        $self->_complete(_error_result(
            'worker_setup', 'pipe', _os_error(),
        ));
        return undef;
    }

    my $pid = fork();
    unless (defined $pid) {
        eval { close $read_fh };
        eval { close $write_fh };
        $self->_complete(_error_result(
            'worker_setup', 'fork', _os_error(),
        ));
        return undef;
    }

    if ($pid == 0) {
        $self->_child_main($read_fh, $write_fh);
    }

    $self->{pid}      = $pid;
    $self->{read_fh}  = $read_fh;
    $self->{write_fh} = $write_fh;
    eval { close $write_fh };
    delete $self->{write_fh};

    my $watch_ok = eval {
        $loop->watch_process(
            $pid,
            sub {
                my ($seen_pid, $wait_status) = @_;
                return if $self->{finalized};
                return unless defined($seen_pid) && $seen_pid == $pid;

                $self->{wait_status} = $wait_status;
                $self->{child_done}  = 1;
                $self->_maybe_finish;
            },
        );
        1;
    };

    unless ($watch_ok) {
        my $error = _exception_text($@ || 'watch_process registration failed');
        $self->_signal_child('KILL');
        eval { close $read_fh };
        delete $self->{read_fh};

        # watch_process never accepted ownership of this PID, so there is no
        # IO::Async reaping race on this exceptional setup path. Give SIGKILL
        # a short bounded window to make the child collectable and reap it.
        eval {
            require POSIX;
            for (1 .. 20) {
                my $seen = waitpid($pid, POSIX::WNOHANG());
                last if $seen == $pid || $seen == -1;
                Time::HiRes::sleep(0.005);
            }
            1;
        };

        $self->_complete(_error_result(
            'worker_setup', 'watch_process', $error,
        ));
        return undef;
    }

    my $stream_ok = eval {
        $self->{stream} = IO::Async::Stream->new(
            read_handle => $read_fh,
            on_read     => sub {
                my ($io, $buffref, $eof) = @_;
                $self->_consume_output($buffref, $eof, $io);
                return 0;
            },
        );
        $loop->add($self->{stream});
        1;
    };

    unless ($stream_ok) {
        my $error = _exception_text($@ || 'stream setup failed');
        $self->_signal_child('KILL');
        $self->_remove_stream;
        eval { close $read_fh };
        delete $self->{read_fh};
        $self->_complete(_error_result(
            'worker_setup', 'stream', $error,
        ));
        return undef;
    }

    my $timer_ok = eval {
        $self->{timeout_timer} = $self->_new_timer(
            $self->{timeout},
            sub { $self->_begin_termination('timeout') },
        );
        1;
    };

    unless ($timer_ok) {
        my $error = _exception_text($@ || 'timeout timer setup failed');
        $self->_signal_child('KILL');
        $self->_cleanup;
        $self->_complete(_error_result(
            'worker_setup', 'timeout_timer', $error,
        ));
        return undef;
    }

    return $self;
}

sub pid {
    my ($self) = @_;
    return $self->{pid};
}

sub is_done {
    my ($self) = @_;
    return $self->{finalized} ? 1 : 0;
}

sub cancel {
    my ($self, $reason) = @_;
    return 0 if !$self || $self->{finalized};

    $self->{cancelled} = 1;
    $self->{cancel_reason} = _clean_scalar(
        $reason, 'worker cancelled', $MAX_DETAIL,
    );
    $self->_begin_termination('cancel');
    return 1;
}

sub _child_main {
    my ($self, $read_fh, $write_fh) = @_;

    eval { close $read_fh };
    binmode($write_fh, ':raw');
    local $SIG{PIPE} = 'IGNORE';
    local $SIG{TERM} = 'DEFAULT';
    local $SIG{INT}  = 'DEFAULT';
    local $SIG{HUP}  = 'DEFAULT';

    # MB653: the child may stream bounded progress records before its one
    # terminal result record. Existing children may ignore the emitter.
    my $emit_progress = sub {
        my ($value) = @_;
        my $record = {
            protocol => $PROTOCOL_VERSION,
            type     => 'progress',
            value    => $value,
        };

        my $payload = eval { JSON::PP::encode_json($record) };
        return 0 if !defined($payload) || ref($payload);
        $payload .= "\n";
        return 0 if length($payload) > $self->{max_output};
        return _write_all($write_fh, $payload);
    };

    my $record;
    my $value = eval { $self->{child}->($emit_progress) };
    if ($@) {
        $record = {
            protocol => $PROTOCOL_VERSION,
            type     => 'result',
            ok       => JSON::PP::false,
            error    => 'worker_exception',
            stage    => 'child',
            detail   => _exception_text($@),
        };
    }
    else {
        $record = {
            protocol => $PROTOCOL_VERSION,
            type     => 'result',
            ok       => JSON::PP::true,
            value    => $value,
        };
    }

    my $payload = eval { JSON::PP::encode_json($record) };
    if (!defined($payload) || ref($payload) || $payload eq '') {
        $payload = _encode_child_error(
            'worker_encode', 'encode',
            _exception_text($@ || 'worker result could not be encoded'),
        );
    }

    # Keep the terminal record independently bounded. The parent also enforces
    # max_output across the complete progress + result byte stream.
    if (length($payload) + 1 > $self->{max_output}) {
        $payload = _encode_child_error(
            'worker_output_limit', 'child_payload',
            'worker result exceeded output limit',
        );
    }

    $payload .= "\n";
    _write_all($write_fh, $payload);
    eval { close $write_fh };
    POSIX::_exit(0);
}

sub _consume_output {
    my ($self, $buffref, $eof, $io) = @_;
    return if $self->{finalized};

    if (defined($buffref) && length($$buffref)) {
        my $chunk_len = length($$buffref);
        my $before = $self->{bytes};
        $self->{bytes} += $chunk_len;

        if (!$self->{output_exceeded}) {
            my $remaining = $self->{max_output} - $before;
            if ($remaining > 0) {
                $self->{buffer} .= substr($$buffref, 0, $remaining);
            }
            $self->{output_exceeded} = 1
                if $self->{bytes} > $self->{max_output};
        }

        $$buffref = '';
        $self->_drain_records unless $self->{output_exceeded};
    }

    if ($eof && !$self->{pipe_eof}) {
        $self->{pipe_eof} = 1;

        if (!$self->{output_exceeded} && length($self->{buffer})) {
            $self->_handle_record($self->{buffer});
            $self->{buffer} = '';
        }

        eval { $self->{loop}->remove($io) } if $io;
        $self->{stream_removed} = 1;
        $self->_maybe_finish;
    }
}

sub _drain_records {
    my ($self) = @_;

    while ($self->{buffer} =~ s/\A([^\n]*)\n//) {
        $self->_handle_record($1);
    }
}

sub _handle_record {
    my ($self, $line) = @_;
    return if $self->{finalized};
    return if $self->{protocol_error};

    if (!defined($line) || ref($line) || $line eq '') {
        $self->{protocol_error} = 'empty_record';
        return;
    }

    my $decoded = eval { JSON::PP::decode_json($line) };
    if ($@ || ref($decoded) ne 'HASH'
        || ($decoded->{protocol} // 0) != $PROTOCOL_VERSION) {
        $self->{protocol_error} = 'invalid_record';
        return;
    }

    my $type = $decoded->{type} // '';
    if ($type eq 'progress') {
        if (!exists $decoded->{value}) {
            $self->{protocol_error} = 'progress_shape';
            return;
        }

        $self->{progress_count}++;
        my $callback = $self->{on_progress};
        eval { $callback->($decoded->{value}, $self); 1 }
            if ref($callback) eq 'CODE';
        return;
    }

    if ($type eq 'result') {
        if ($self->{final_record}) {
            $self->{protocol_error} = 'duplicate_result';
            return;
        }
        $self->{final_record} = $decoded;
        return;
    }

    $self->{protocol_error} = 'record_type';
}

sub _begin_termination {
    my ($self, $kind) = @_;
    return if $self->{finalized};

    if ($kind eq 'timeout') {
        $self->{timed_out} = 1;
    }

    $self->_signal_child('TERM') unless $self->{child_done};

    unless ($self->{kill_timer}) {
        $self->{kill_timer} = eval {
            $self->_new_timer(
                $self->{term_grace},
                sub {
                    return if $self->{finalized} || $self->{child_done};
                    $self->_signal_child('KILL');
                },
            );
        };
    }

    unless ($self->{force_timer}) {
        $self->{force_timer} = eval {
            $self->_new_timer(
                $self->{force_grace},
                sub {
                    return if $self->{finalized};
                    $self->{forced} = 1;
                    $self->_maybe_finish;
                },
            );
        };
    }

    $self->_maybe_finish;
}

sub _signal_child {
    my ($self, $signal) = @_;
    return 0 unless $self->{pid};

    if ($signal eq 'TERM') {
        return 0 if $self->{term_sent};
        $self->{term_sent} = 1;
    }
    elsif ($signal eq 'KILL') {
        return 0 if $self->{kill_sent};
        $self->{kill_sent} = 1;
    }

    return kill($signal, $self->{pid}) ? 1 : 0;
}

sub _new_timer {
    my ($self, $delay, $callback) = @_;
    my $timer = IO::Async::Timer::Countdown->new(
        delay     => $delay,
        on_expire => $callback,
    );
    $self->{loop}->add($timer);
    $timer->start;
    return $timer;
}

sub _maybe_finish {
    my ($self) = @_;
    return if $self->{finalized};

    return unless $self->{forced}
        || ($self->{child_done}
            && ($self->{pipe_eof} || $self->{timed_out} || $self->{cancelled}));

    my $result = $self->_build_result;
    $self->_cleanup;
    $self->_complete($result);
}

sub _build_result {
    my ($self) = @_;

    my $status = $self->{wait_status};
    my ($exit, $signal);
    if (defined $status) {
        $signal = $status & 127;
        $exit   = ($status >> 8) & 255;
    }

    my %meta = (
        pid            => $self->{pid},
        exit           => $exit,
        signal         => $signal,
        timed_out      => $self->{timed_out} ? 1 : 0,
        cancelled      => $self->{cancelled} ? 1 : 0,
        forced         => $self->{forced} ? 1 : 0,
        term_sent      => $self->{term_sent} ? 1 : 0,
        kill_sent      => $self->{kill_sent} ? 1 : 0,
        bytes          => 0 + ($self->{bytes} // 0),
        progress_count => 0 + ($self->{progress_count} // 0),
        elapsed_s      => Time::HiRes::time() - $self->{started_at},
    );

    if ($self->{cancelled}) {
        return {
            %{ _error_result(
                'worker_cancelled', 'cancel',
                $self->{cancel_reason} || 'worker cancelled',
            ) },
            %meta,
        };
    }

    if ($self->{timed_out}) {
        return {
            %{ _error_result(
                'worker_timeout', 'timeout',
                sprintf('%s exceeded %.3fs', $self->{label}, $self->{timeout}),
            ) },
            %meta,
        };
    }

    if ($self->{forced} && !$self->{child_done}) {
        return {
            %{ _error_result(
                'worker_liveness', 'watch_process',
                'worker finalization backstop expired before process completion',
            ) },
            %meta,
        };
    }

    if (defined($signal) && $signal) {
        return {
            %{ _error_result(
                'worker_signal', 'process_exit',
                "worker terminated by signal $signal",
            ) },
            %meta,
        };
    }

    if (defined($exit) && $exit != 0) {
        return {
            %{ _error_result(
                'worker_exit', 'process_exit',
                "worker exited with status $exit",
            ) },
            %meta,
        };
    }

    if ($self->{output_exceeded}) {
        return {
            %{ _error_result(
                'worker_output_limit', 'payload_limit',
                sprintf('worker output exceeded %d bytes', $self->{max_output}),
            ) },
            %meta,
        };
    }

    if ($self->{protocol_error}) {
        return {
            %{ _error_result(
                'worker_decode', 'record_protocol',
                $self->{protocol_error},
            ) },
            %meta,
        };
    }

    my $decoded = $self->{final_record};
    unless (ref($decoded) eq 'HASH' && exists($decoded->{ok})) {
        return {
            %{ _error_result(
                'worker_empty', 'payload',
                'worker produced no terminal result',
            ) },
            %meta,
        };
    }

    if ($decoded->{ok}) {
        return {
            ok    => 1,
            value => $decoded->{value},
            %meta,
        };
    }

    return {
        %{ _error_result(
            _clean_scalar($decoded->{error}, 'worker_failed', 80),
            _clean_scalar($decoded->{stage}, 'child', 80),
            _clean_scalar($decoded->{detail}, 'worker failed', $MAX_DETAIL),
        ) },
        %meta,
    };
}

sub _cleanup {
    my ($self) = @_;

    for my $name (qw(timeout_timer kill_timer force_timer)) {
        my $timer = delete $self->{$name};
        next unless $timer;
        eval { $timer->stop };
        eval { $self->{loop}->remove($timer) };
    }

    $self->_remove_stream;

    if (my $fh = delete $self->{read_fh}) {
        eval { close $fh };
    }
    if (my $fh = delete $self->{write_fh}) {
        eval { close $fh };
    }
}

sub _remove_stream {
    my ($self) = @_;
    my $stream = delete $self->{stream};
    return unless $stream;
    return if $self->{stream_removed};
    eval { $self->{loop}->remove($stream) };
    $self->{stream_removed} = 1;
}

sub _complete {
    my ($self, $result) = @_;
    return 0 if $self->{finalized};

    $self->{finalized} = 1;
    $result = _error_result(
        'worker_failed', 'completion', 'invalid worker result',
    ) unless ref($result) eq 'HASH';

    my $callback = delete $self->{on_done};
    if (ref($callback) eq 'CODE') {
        eval { $callback->($result); 1 };
    }

    delete $self->{child};
    delete $self->{on_progress};
    return 1;
}

sub _write_all {
    my ($fh, $payload) = @_;
    return 0 unless $fh;

    my $offset = 0;
    local $SIG{PIPE} = 'IGNORE';

    while ($offset < length($payload)) {
        my $written = syswrite(
            $fh,
            $payload,
            length($payload) - $offset,
            $offset,
        );
        next if !defined($written) && $!{EINTR};
        return 0 unless defined($written) && $written > 0;
        $offset += $written;
    }

    return 1;
}

sub _encode_child_error {
    my ($error, $stage, $detail) = @_;
    return JSON::PP::encode_json({
        protocol => $PROTOCOL_VERSION,
        type     => 'result',
        ok       => JSON::PP::false,
        error    => $error,
        stage    => $stage,
        detail   => _clean_scalar($detail, 'worker failed', $MAX_DETAIL),
    });
}

sub _error_result {
    my ($error, $stage, $detail) = @_;
    return {
        ok     => 0,
        error  => $error,
        stage  => $stage,
        detail => _clean_scalar($detail, 'worker failed', $MAX_DETAIL),
    };
}

sub _exception_text {
    my ($error) = @_;
    $error = 'unknown worker error' unless defined($error) && !ref($error);
    $error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
    $error =~ s/[\r\n\0]+/ /g;
    $error =~ s/\s{2,}/ /g;
    return substr($error, 0, $MAX_DETAIL);
}

sub _os_error {
    my $error = "$!";
    return _clean_scalar($error, 'unknown operating-system error', $MAX_DETAIL);
}

sub _clean_scalar {
    my ($value, $fallback, $limit) = @_;
    $limit ||= $MAX_DETAIL;
    return $fallback if !defined($value) || ref($value);

    $value = "$value";
    $value =~ s/[\r\n\0]+/ /g;
    $value =~ s/\s{2,}/ /g;
    $value =~ s/^\s+|\s+$//g;
    $value = $fallback unless length $value;
    return substr($value, 0, $limit);
}

sub _bounded_number {
    my ($value, $default, $min, $max) = @_;
    return $default
        if !defined($value) || ref($value)
            || "$value" !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/;
    $value = 0 + $value;
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

sub _bounded_integer {
    my ($value, $default, $min, $max) = @_;
    return $default
        if !defined($value) || ref($value) || "$value" !~ /\A\d+\z/;
    $value = int($value);
    $value = $min if $value < $min;
    $value = $max if $value > $max;
    return $value;
}

1;

__END__

=head1 NAME

Mediabot::AsyncWorker - shared fork/pipe lifecycle for bounded JSON workers

=head1 SYNOPSIS

    my $worker = Mediabot::AsyncWorker->start(
        loop       => $loop,
        label      => 'version check',
        timeout    => 10,
        max_output => 64 * 1024,
        child      => sub {
            my ($emit_progress) = @_;
            $emit_progress->({ stage => 'fetching' });
            return { version => fetch_version() };
        },
        on_progress => sub {
            my ($event) = @_;
        },
        on_done    => sub {
            my ($result) = @_;
            return unless $result->{ok};
            my $value = $result->{value};
        },
    );

=head1 CONTRACT

The parent owns process completion through C<watch_process>. The child writes
a bounded newline-delimited JSON record stream to a dedicated pipe: zero or more
C<progress> records followed by exactly one terminal C<result> record. Existing
children may ignore the progress emitter passed as their first argument.
Timeout uses TERM, then KILL, plus a liveness backstop. Completion is guarded so
C<on_done> runs at most once.

The child callback is the consumer boundary. Consumers that inherit live DBI or
socket handles remain responsible for making those inherited handles safe and
for opening isolated resources inside that callback.

This module does not provide a synchronous fallback. A consumer may choose one
explicitly when C<start> returns false.

=cut
