package Mediabot::Partyline::Privileged;

# =============================================================================
# Mediabot::Partyline::Privileged
# =============================================================================
# MB678-IV-O: privileged Partyline control extraction.
#
# This module owns the two Owner-only controls that can execute arbitrary Perl
# or terminate the bot process. Their historical Mediabot::Partyline method
# surface remains available via import; dispatcher routing is unchanged.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use IO::Async::Stream;
use IO::Async::Timer::Countdown;
use POSIX qw(WNOHANG);

our @EXPORT_OK = qw(
    _cmd_eval
    _cmd_die
);

# ---------------------------------------------------------------------------
# .eval <perl code> - Owner only
# ---------------------------------------------------------------------------
sub _cmd_eval {
    my ($self, $stream, $id, $code) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login} // 'unknown';
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {
        $stream->write("Access denied: .eval requires Owner level.\r\n");
        return;
    }

    my $eval_enabled = eval { $bot->{conf}->get('main.PARTYLINE_EVAL_ENABLED') } // 0;
    $eval_enabled = 0 unless defined($eval_enabled) && $eval_enabled =~ /^(?:1|yes|true|on)$/i;

    unless ($eval_enabled) {
        $stream->write("Access denied: .eval is disabled by configuration.\r\n");
        $stream->write("Set PARTYLINE_EVAL_ENABLED=1 in [main] to enable it.\r\n");
        return;
    }

    unless (defined $code && $code =~ /\S/) {
        $stream->write("Usage: .eval <perl code>\r\n");
        $stream->write("WARNING: code runs in a forked subprocess. Confirmation required.\r\n");
        return;
    }

    # One-step confirmation with hard 30-second expiry.
    my $pending_key = "_eval_pending_$id";
    my $now_eval = time();

    if (!$self->{$pending_key}
        || $self->{$pending_key}{code} ne $code
        || ($now_eval - ($self->{$pending_key}{at} // 0)) > 30)
    {
        $self->{$pending_key} = { code => $code, at => $now_eval };
        $stream->write("--- .eval confirmation required ---\r\n");
        $stream->write("Code: $code\r\n");
        $stream->write("Type the same .eval command again within 30 seconds to execute.\r\n");
        return;
    }

    delete $self->{$pending_key};

    my $eval_timeout = eval { $bot->{conf}->get('main.PARTYLINE_EVAL_TIMEOUT_SECONDS') } || 5;
    $eval_timeout = 5 unless defined($eval_timeout) && $eval_timeout =~ /^\d+$/;
    $eval_timeout = 1  if $eval_timeout < 1;
    $eval_timeout = 15 if $eval_timeout > 15;

    $bot->{logger}->log(1, "Partyline: $nick executing eval in subprocess timeout=${eval_timeout}s: $code");
    # A4: log code summary to consolechan (truncate long payloads)
    {
        my $summary = length($code) > 60
            ? substr($code, 0, 57) . "..."
            : $code;
        eval { noticeConsoleChan($bot, "[partyline] $nick .eval (${\ length($code)}c): $summary") };
    }
    $self->_broadcast("[${nick}\@partyline] .eval $code", $id);

    my $pid = open(my $pipe, "-|");

    unless (defined $pid) {
        $stream->write("Cannot fork eval subprocess.\r\n");
        $bot->{logger}->log(1, "Partyline: failed to fork eval subprocess for $nick");
        return;
    }

    if ($pid == 0) {
        # Child process. Never mutate the live bot from here: this is a forked copy.
        eval {
            open STDERR, '>&', \*STDOUT;

            local $SIG{ALRM} = sub { die "__MEDIABOT_EVAL_TIMEOUT__\n" };
            alarm($eval_timeout);

            local $_ = undef;
            my $result = eval $code;
            my $err = $@;

            alarm(0);

            if ($err) {
                if ($err =~ /__MEDIABOT_EVAL_TIMEOUT__/) {
                    print "__MEDIABOT_EVAL_TIMEOUT__\n";
                    exit 124;
                }

                $err =~ s/\r?\n/ /g;
                print "__MEDIABOT_EVAL_ERROR__ $err\n";
                exit 2;
            }

            print "$result\n" if defined($result) && $result ne '';
            exit 0;
        };

        my $fatal = $@ || 'unknown eval subprocess failure';
        alarm(0);
        $fatal =~ s/\r?\n/ /g;
        print "__MEDIABOT_EVAL_FATAL__ $fatal\n";
        exit 2;
    }

    # MB309: read the eval pipe asynchronously and reap the child without
    # ever blocking the IRC loop. User-supplied eval code can close STDOUT and
    # continue running; EOF on the pipe therefore does not prove process exit.
    my $eval_ctx = {
        lines            => [],
        truncated        => 0,
        timed_out        => 0,
        timeout_reported => 0,
        errors           => [],
        finalized        => 0,
        pipe_eof         => 0,
        wait_status      => undef,
    };

    my ($watchdog, $kill_timer, $reap_timer, $io);
    my ($finalize, $schedule_reap);

    my $remove_timer = sub {
        my ($timer_ref) = @_;
        return unless $timer_ref && $$timer_ref;

        my $timer = $$timer_ref;
        $$timer_ref = undef;
        eval { $timer->stop if $timer->can('stop') };
        eval { $bot->{loop}->remove($timer) };
    };

    my $report_timeout = sub {
        return if $eval_ctx->{timeout_reported}++;

        if ($self->{streams}{$id}) {
            $stream->write("--- timeout ---\r\n");
            $stream->write("Eval timed out after ${eval_timeout}s.\r\n");
        }

        $bot->{logger}->log(1,
            "Partyline: $nick eval timed out after ${eval_timeout}s");
    };

    $finalize = sub {
        return if $eval_ctx->{finalized}++;

        $remove_timer->(\$watchdog);
        $remove_timer->(\$kill_timer);
        $remove_timer->(\$reap_timer);
        eval { $bot->{loop}->remove($io) if $io };

        if ($eval_ctx->{timed_out}) {
            $report_timeout->();
            return;
        }

        my $status = $eval_ctx->{wait_status};
        if (defined $status) {
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if ($signal && !@{ $eval_ctx->{errors} }) {
                push @{ $eval_ctx->{errors} },
                    "eval subprocess terminated by signal $signal";
            }
            elsif ($exit != 0 && !@{ $eval_ctx->{errors} }) {
                push @{ $eval_ctx->{errors} },
                    "eval subprocess exited with status $exit";
            }
        }

        return unless $self->{streams}{$id};

        $stream->write("--- eval output ---\r\n");
        if (@{ $eval_ctx->{lines} }) {
            $stream->write("$_\r\n") for @{ $eval_ctx->{lines} };
        }
        else {
            $stream->write("(no output)\r\n")
                unless @{ $eval_ctx->{errors} };
        }

        $stream->write("[... output truncated at 20 lines ...]\r\n")
            if $eval_ctx->{truncated};

        if (@{ $eval_ctx->{errors} }) {
            $stream->write("--- error ---\r\n");
            for my $err (@{ $eval_ctx->{errors} }) {
                $err =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                $stream->write("$err\r\n");
            }
            $bot->{logger}->log(1, "Partyline: $nick eval error: "
                . join(' | ', @{ $eval_ctx->{errors} }));
        }
        else {
            $stream->write("--- ok ---\r\n");
            $bot->{logger}->log(1, "Partyline: $nick eval done");
        }
    };

    $schedule_reap = sub {
        return if $eval_ctx->{finalized};
        return if $reap_timer;

        my $waited = waitpid($pid, WNOHANG);
        if ($waited == $pid) {
            $eval_ctx->{wait_status} = $?;
            $finalize->();
            return;
        }

        if ($waited == -1) {
            push @{ $eval_ctx->{errors} }, "waitpid failed: $!"
                unless $eval_ctx->{timed_out};
            $finalize->();
            return;
        }

        $reap_timer = IO::Async::Timer::Countdown->new(
            delay     => 0.05,
            on_expire => sub {
                my $expired = $reap_timer;
                $reap_timer = undef;
                eval { $bot->{loop}->remove($expired) if $expired };
                $schedule_reap->();
            },
        );
        $bot->{loop}->add($reap_timer);
        $reap_timer->start;
    };

    # Parent-side watchdog. TERM and KILL are separated by an asynchronous
    # grace timer; no sleep/usleep is allowed in the IO::Async event loop.
    $watchdog = IO::Async::Timer::Countdown->new(
        delay     => $eval_timeout,
        on_expire => sub {
            return if $eval_ctx->{finalized};

            $eval_ctx->{timed_out} = 1;
            $report_timeout->();
            kill 'TERM', $pid;
            $schedule_reap->();

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.5,
                on_expire => sub {
                    return if $eval_ctx->{finalized};

                    my $waited = waitpid($pid, WNOHANG);
                    if ($waited == $pid) {
                        $eval_ctx->{wait_status} = $?;
                        $finalize->();
                        return;
                    }

                    if ($waited == -1) {
                        $finalize->();
                        return;
                    }

                    kill 'KILL', $pid;
                    $schedule_reap->();
                },
            );
            $bot->{loop}->add($kill_timer);
            $kill_timer->start;
        },
    );
    $bot->{loop}->add($watchdog);
    $watchdog->start;

    $io = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($s, $buffref, $eof) = @_;

            while ($$buffref =~ s/^([^\n]*\n)//) {
                my $line = $1;
                chomp $line;
                $line =~ s/\r//g;

                if ($line =~ /^__MEDIABOT_EVAL_TIMEOUT__/) {
                    $eval_ctx->{timed_out} = 1;
                    next;
                }
                if ($line =~ /^__MEDIABOT_EVAL_(?:ERROR|FATAL)__\s*(.*)$/) {
                    push @{ $eval_ctx->{errors} }, $1;
                    next;
                }

                $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                $line = substr($line, 0, 497) . '...'
                    if length($line) > 500;

                if (@{ $eval_ctx->{lines} } < 20) {
                    push @{ $eval_ctx->{lines} }, $line;
                }
                else {
                    $eval_ctx->{truncated} = 1;
                }
            }

            if ($eof && !$eval_ctx->{pipe_eof}++) {
                # Preserve a final line that is not newline-terminated.
                if (length $$buffref) {
                    my $line = $$buffref;
                    $$buffref = '';
                    $line =~ s/\r//g;
                    $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
                    $line = substr($line, 0, 497) . '...'
                        if length($line) > 500;
                    if (@{ $eval_ctx->{lines} } < 20) {
                        push @{ $eval_ctx->{lines} }, $line;
                    }
                    else {
                        $eval_ctx->{truncated} = 1;
                    }
                }

                eval { $bot->{loop}->remove($s) };
                $schedule_reap->();
            }

            return 0;
        },
    );
    $bot->{loop}->add($io);
}

# ---------------------------------------------------------------------------
# .die [message] - Owner only
# ---------------------------------------------------------------------------
sub _cmd_die {
    my ($self, $stream, $id, $msg) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .die requires Owner level.\r\n");
        return;
    }

    $msg //= "Partyline requested termination";

    $bot->{logger}->log(2, "Partyline: $nick requested die ($msg)");
    $stream->write("Terminating bot...\r\n");

    $stream->close_when_empty;
    $self->_close_session($id);

    # mb645: `.die` is an intentional final shutdown, not a restart request.
    # Exit 75 is reserved by the shipped systemd unit via
    # RestartPreventExitStatus=75.
    $bot->setShutdownExitCode($bot->getNoRestartExitCode());
    $bot->{Quit} = 1;
    $bot->{irc}->send_message("QUIT", undef, $msg);
}

1;
