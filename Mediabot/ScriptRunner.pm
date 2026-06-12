package Mediabot::ScriptRunner;

use strict;
use warnings;
use utf8;

use JSON::PP qw(encode_json decode_json);
use IPC::Open3 qw(open3);
use IO::Select ();
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

# ---------------------------------------------------------------------------
# Mediabot::ScriptRunner
# ---------------------------------------------------------------------------
# mb174-B1: external script runner foundation.
#
# This module deliberately does not execute external scripts yet. It defines the
# safety boundary and JSON protocol helpers we will need before allowing Perl,
# Python or Tcl scripts to be run out-of-process.
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $script_dir = defined $args{script_dir} && length $args{script_dir}
        ? $args{script_dir}
        : 'plugins/scripts';

    my $timeout = defined $args{timeout} ? int($args{timeout}) : 3;
    $timeout = 1  if $timeout < 1;
    $timeout = 30 if $timeout > 30;

    my $max_stdout = defined $args{max_stdout_bytes} ? int($args{max_stdout_bytes}) : 65536;
    $max_stdout = 1024    if $max_stdout < 1024;
    $max_stdout = 1048576 if $max_stdout > 1048576;

    return bless {
        bot              => $args{bot},
        script_dir       => $script_dir,
        timeout          => $timeout,
        max_stdout_bytes => $max_stdout,
        allowed_actions  => {
            reply  => 1,
            notice => 1,
            log    => 1,
            timer  => 1,
        },
    }, $class;
}

sub bot {
    my ($self) = @_;
    return $self->{bot};
}

sub script_dir {
    my ($self) = @_;
    return $self->{script_dir};
}

sub timeout {
    my ($self) = @_;
    return $self->{timeout};
}

sub max_stdout_bytes {
    my ($self) = @_;
    return $self->{max_stdout_bytes};
}

sub language_for {
    my ($self, $path) = @_;

    return undef unless defined $path;

    return 'perl'   if $path =~ /\.pl\z/i;
    return 'python' if $path =~ /\.py\z/i;
    return 'tcl'    if $path =~ /\.tcl\z/i;

    return undef;
}

sub validate_script_path {
    my ($self, $path) = @_;

    return (0, 'missing script path') unless defined $path && length $path;

    my $p = "$path";
    $p =~ s/^\s+|\s+$//g;

    return (0, 'empty script path') unless length $p;
    return (0, 'absolute paths are not allowed') if $p =~ m{\A/};
    return (0, 'parent directory traversal is not allowed') if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return (0, 'backslash paths are not allowed') if $p =~ m{\\};
    return (0, 'NUL byte is not allowed') if $p =~ /\0/;

    my $lang = $self->language_for($p);
    return (0, 'unsupported script extension') unless defined $lang;

    return (1, undef, $lang, $self->{script_dir} . '/' . $p);
}

sub build_event_payload {
    my ($self, $event, %data) = @_;

    $event = 'unknown' unless defined $event && length $event;

    return {
        protocol => 'mediabot-script-v1',
        event    => $event,
        data     => \%data,
    };
}

sub encode_event_payload {
    my ($self, $payload) = @_;

    return encode_json($payload || {});
}

sub decode_script_response {
    my ($self, $json) = @_;

    return {
        ok     => 0,
        errors => [ 'empty script response' ],
        actions => [],
    } unless defined $json && length $json;

    my $decoded = eval { decode_json($json) };
    if (!$decoded || ref($decoded) ne 'HASH') {
        my $err = $@ || 'decoded response is not an object';
        $err =~ s/\s+/ /g;
        return {
            ok      => 0,
            errors  => [ "invalid JSON response: $err" ],
            actions => [],
        };
    }

    my $actions = $decoded->{actions};
    if (!defined $actions) {
        $actions = [];
    }

    return {
        ok      => 0,
        errors  => [ 'actions must be an array' ],
        actions => [],
    } unless ref($actions) eq 'ARRAY';

    my @valid;
    my @errors;

    for my $idx (0 .. $#$actions) {
        my $action = $actions->[$idx];

        if (ref($action) ne 'HASH') {
            push @errors, "action[$idx] must be an object";
            next;
        }

        my $type = $action->{type};
        if (!defined $type || !length "$type") {
            push @errors, "action[$idx] missing type";
            next;
        }

        $type = lc "$type";
        if (!$self->{allowed_actions}{$type}) {
            push @errors, "action[$idx] unsupported type '$type'";
            next;
        }

        $action->{type} = $type;
        push @valid, $action;
    }

    return {
        ok      => @errors ? 0 : 1,
        errors  => \@errors,
        actions => \@valid,
    };
}

sub interpreter_for_language {
    my ($self, $language) = @_;

    return undef unless defined $language;

    my $lang = lc "$language";

    return [ $^X ]       if $lang eq 'perl';
    return [ 'python3' ] if $lang eq 'python';
    return [ 'tclsh' ]   if $lang eq 'tcl';

    return undef;
}

sub build_execution_plan {
    my ($self, $script_path, $payload, %opts) = @_;

    my ($ok, $err, $language, $full_path) = $self->validate_script_path($script_path);
    unless ($ok) {
        return {
            ok      => 0,
            error   => $err,
            actions => [],
            command => [],
        };
    }

    my $interp = $self->interpreter_for_language($language);
    unless ($interp && ref($interp) eq 'ARRAY' && @$interp) {
        return {
            ok       => 0,
            error    => "no interpreter configured for language '$language'",
            language => $language,
            actions  => [],
            command  => [],
        };
    }

    my $json = $self->encode_event_payload($payload || {});

    # mb175-B1: execution plan only. This is intentionally a dry-run contract:
    # it prepares the argv/stdin/limits we will use later, but does not spawn.
    my @command = (@$interp, $full_path);

    return {
        ok               => 1,
        dry_run          => 1,
        language         => $language,
        script           => $script_path,
        full_path        => $full_path,
        command          => \@command,
        stdin            => $json,
        timeout          => $self->{timeout},
        max_stdout_bytes => $self->{max_stdout_bytes},
    };
}

sub run_dry {
    my ($self, $script_path, $event, %data) = @_;

    my $payload = $self->build_event_payload($event, %data);
    return $self->build_execution_plan($script_path, $payload);
}


sub _append_capped {
    my ($buffer_ref, $chunk, $max, $truncated_ref) = @_;

    return unless defined $chunk && length $chunk;
    $$buffer_ref //= '';

    my $remaining = $max - length($$buffer_ref);
    if ($remaining <= 0) {
        $$truncated_ref = 1;
        return;
    }

    if (length($chunk) > $remaining) {
        $$buffer_ref .= substr($chunk, 0, $remaining);
        $$truncated_ref = 1;
        return;
    }

    $$buffer_ref .= $chunk;
}

sub run_plan {
    my ($self, $plan) = @_;

    return {
        ok       => 0,
        error    => 'invalid execution plan',
        timeout  => 0,
        stdout   => '',
        stderr   => '',
        response => { ok => 0, errors => [ 'invalid execution plan' ], actions => [] },
    } unless ref($plan) eq 'HASH' && $plan->{ok};

    my @cmd = @{ $plan->{command} || [] };
    return {
        ok       => 0,
        error    => 'empty command argv',
        timeout  => 0,
        stdout   => '',
        stderr   => '',
        response => { ok => 0, errors => [ 'empty command argv' ], actions => [] },
    } unless @cmd;

    my $stdin      = defined $plan->{stdin} ? $plan->{stdin} : '';
    my $timeout    = defined $plan->{timeout} ? int($plan->{timeout}) : $self->{timeout};
    my $max_stdout = defined $plan->{max_stdout_bytes} ? int($plan->{max_stdout_bytes}) : $self->{max_stdout_bytes};
    my $max_stderr = defined $plan->{max_stderr_bytes} ? int($plan->{max_stderr_bytes}) : $self->{max_stdout_bytes};

    $timeout    = 1       if $timeout < 1;
    $timeout    = 30      if $timeout > 30;
    $max_stdout = 1024    if $max_stdout < 1024;
    $max_stderr = 1024    if $max_stderr < 1024;

    # mb176-B1: real subprocess execution, but still with the boundaries laid by
    # mb174/mb175: validated path, argv array only, no shell, JSON stdin,
    # timeout, stdout cap, stderr cap, and structured response parsing.
    my ($child_in, $child_out);
    my $child_err = gensym;

    my $pid = eval { open3($child_in, $child_out, $child_err, @cmd) };
    if (!$pid) {
        my $err = $@ || 'open3 failed';
        $err =~ s/\s+/ /g;
        return {
            ok       => 0,
            error    => $err,
            timeout  => 0,
            stdout   => '',
            stderr   => '',
            response => { ok => 0, errors => [ $err ], actions => [] },
        };
    }

    local $SIG{PIPE} = 'IGNORE';

    eval {
        print {$child_in} $stdin if defined $stdin && length $stdin;
        close $child_in;
        1;
    };

    my $selector = IO::Select->new();
    $selector->add($child_out);
    $selector->add($child_err);

    my $stdout = '';
    my $stderr = '';
    my $stdout_truncated = 0;
    my $stderr_truncated = 0;
    my $timed_out = 0;
    my $deadline = time() + $timeout;
    my $already_waited = 0;
    my $wait_status = undef;

    while ($selector->count) {
        if (time() > $deadline) {
            $timed_out = 1;
            kill 'TERM', $pid;
            sleep 0.2;
            my $w = waitpid($pid, WNOHANG);
            if ($w == 0) {
                kill 'KILL', $pid;
                waitpid($pid, 0);
                $wait_status = $?;
                $already_waited = 1;
            }
            elsif ($w == $pid) {
                $wait_status = $?;
                $already_waited = 1;
            }
            last;
        }

        my @ready = $selector->can_read(0.10);
        next unless @ready;

        for my $fh (@ready) {
            my $chunk = '';
            my $read = sysread($fh, $chunk, 4096);

            if (!defined $read) {
                next;
            }

            if ($read == 0) {
                $selector->remove($fh);
                close $fh;
                next;
            }

            if ($fh == $child_out) {
                _append_capped(\$stdout, $chunk, $max_stdout, \$stdout_truncated);
            }
            else {
                _append_capped(\$stderr, $chunk, $max_stderr, \$stderr_truncated);
            }
        }
    }

    if (!$already_waited) {
        waitpid($pid, 0);
        $wait_status = $?;
    }

    my $exit_code = $timed_out ? undef : (($wait_status >> 8) & 0xff);
    my $signal    = $timed_out ? undef : ($wait_status & 0x7f);

    my $response = $timed_out
        ? { ok => 0, errors => [ 'script timed out' ], actions => [] }
        : $self->decode_script_response($stdout);

    return {
        ok               => (!$timed_out && defined($exit_code) && $exit_code == 0 && $response->{ok}) ? 1 : 0,
        timeout          => $timed_out ? 1 : 0,
        exit_code        => $exit_code,
        signal           => $signal,
        stdout           => $stdout,
        stderr           => $stderr,
        stdout_truncated => $stdout_truncated ? 1 : 0,
        stderr_truncated => $stderr_truncated ? 1 : 0,
        response         => $response,
    };
}

sub run_script {
    my ($self, $script_path, $event, %data) = @_;

    my $plan = $self->run_dry($script_path, $event, %data);
    return $plan unless ref($plan) eq 'HASH' && $plan->{ok};

    return $self->run_plan($plan);
}


sub allowed_action_types {
    my ($self) = @_;
    return sort keys %{ $self->{allowed_actions} };
}

1;
