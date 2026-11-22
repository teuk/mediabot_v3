package Mediabot::Plugin::ScriptProcessV3;

use strict;
use warnings;
use IO::Async::Stream;
use POSIX qw(WNOHANG);
use Scalar::Util qw(refaddr);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

sub new {
    my ($class, $loop) = @_;
    return bless { loop => $loop, active => {}, closing => 0 }, $class;
}

sub pending_count {
    my ($self) = @_;
    return scalar keys %{ $self->{active} };
}

# The ScriptRunner produces the argv and bounded input for this subprocess.
# Consume both pipes as they become readable, and keep ownership until reap.
sub start {
    my ($self, $owner, $plan, $done) = @_;
    my $key = refaddr($owner);
    return 0 if $self->{closing} || exists $self->{active}{$key}
        || keys(%{ $self->{active} }) >= 4;
    die "script input exceeds the byte limit\n"
        if length($plan->{stdin}) > $plan->{max_stdin_bytes};

    my $loop = $self->{loop} or die "script process has no event loop\n";
    pipe(my $input, my $writer) or die "cannot open script input\n";
    pipe(my $reader, my $output) or die "cannot open script output\n";
    pipe(my $errors, my $error_output) or die "cannot open script error pipe\n";

    my $job = { key => $key, owner => $owner, done => $done,
        streams => [], readers => 2, stdout => '', stderr_size => 0 };
    $self->{active}{$key} = $job;
    my $ok = eval {
        my $stdin = IO::Async::Stream->new(write_handle => $writer,
            writer => sub {
                my (undef, $handle, undef, $length) = @_;
                local $SIG{PIPE} = 'IGNORE';
                my $written = syswrite($handle, $_[2], $length);
                substr($_[2], 0, $written, '') if $written;
                return $written;
            },
            on_write_error => sub { $self->_abort($job, 'script input failed') });
        push @{ $job->{streams} }, $stdin;
        push @{ $job->{streams} }, $self->_reader($job, $reader, $plan->{max_stdout_bytes}, 1);
        push @{ $job->{streams} }, $self->_reader($job, $errors, $plan->{max_stderr_bytes}, 0);
        $loop->add($_) for @{ $job->{streams} };
        $job->{timer} = $loop->watch_time(after => $plan->{timeout}, code => sub {
            delete $job->{timer};
            $self->_abort($job, 'script timed out');
        });
        $job->{pid} = $loop->spawn_child(
            command => $plan->{command},
            setup => [stdin => [dup => $input], stdout => [dup => $output],
                stderr => [dup => $error_output]],
            on_exit => sub {
                my ($pid, $status, $errno) = @_;
                return unless ($job->{pid} // 0) == $pid;
                delete $job->{pid};
                $self->_abort($job, 'script process failed') if $status || $errno;
                $self->_finish($job);
            },
        ) or die "script spawn failed\n";
        close $_ for ($input, $output, $error_output);
        $stdin->write($plan->{stdin});
        $stdin->close_when_empty;
        1;
    };
    $self->_abort($job, 'script could not start') unless $ok;
    return 1;
}

sub _reader {
    my ($self, $job, $handle, $max, $stdout) = @_;
    return IO::Async::Stream->new(read_handle => $handle,
        on_read_error => sub { $self->_abort($job, 'script output failed') },
        on_read => sub {
            my (undef, $buffer, $eof) = @_;
            my $bytes = length $$buffer;
            my $already = $stdout ? length($job->{stdout}) : $job->{stderr_size};
            if ($already + $bytes > $max) {
                $$buffer = '';
                $self->_abort($job, 'script output exceeds the byte limit');
                return 0;
            }
            if ($stdout) {
                $job->{stdout} .= $$buffer;
            } else {
                $job->{stderr_size} += $bytes;
            }
            $$buffer = '';
            if ($eof) {
                $job->{readers}--;
                $self->_finish($job);
            }
            return 0;
        });
}

sub _close {
    my ($self, $job) = @_;
    my $timer = delete $job->{timer};
    $self->{loop}->unwatch_time($timer) if defined $timer;
    my $streams = delete $job->{streams} || [];
    $_->close_now for @$streams;
}

sub _abort {
    my ($self, $job, $error) = @_;
    return if $job->{error};
    $job->{error} = $error;
    $self->_close($job);
    kill 'KILL', $job->{pid} if defined $job->{pid};
    $self->_finish($job);
}

sub _finish {
    my ($self, $job) = @_;
    return if $job->{pid} || ($job->{readers} && !$job->{error});
    return unless exists $self->{active}{ $job->{key} }
        && $self->{active}{ $job->{key} } == $job;
    delete $self->{active}{ $job->{key} };
    $self->_close($job);
    my $done = delete $job->{done};
    $done->($job->{error}, $job->{stdout}) if $done;
}

sub cancel {
    my ($self, $owner) = @_;
    my $job = $self->{active}{refaddr($owner)} or return;
    delete $job->{done};
    $self->_abort($job, 'script was cancelled');
}

sub shutdown {
    my ($self) = @_;
    $self->{closing} = 1;
    $self->cancel($_->{owner}) for values %{ $self->{active} };
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 0.25;
    # Final shutdown does not iterate the loop or call plugin callbacks.
    while (keys %{ $self->{active} }) {
        for my $job (values %{ $self->{active} }) {
            my $pid = $job->{pid};
            my $result = waitpid($pid, WNOHANG);
            next if $result == 0 || ($result < 0 && $!{EINTR});
            $self->{loop}->unwatch_process($pid);
            delete $job->{pid};
            $self->_finish($job);
        }
        return 0 if keys(%{ $self->{active} }) && clock_gettime(CLOCK_MONOTONIC) >= $deadline;
        sleep 0.01 if keys %{ $self->{active} };
    }
    return 1;
}

1;
