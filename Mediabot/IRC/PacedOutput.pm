package Mediabot::IRC::PacedOutput;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::IRC::Output ();
use Mediabot::IRC::Timer ();
use Scalar::Util qw(refaddr);

our @EXPORT_OK = qw(queue_privmsg_chunks queue_notices);

# Keep runtime loading lazy. Every send re-enters Helpers so workers, normal
# output policy and existing instrumentation still see the same facade.
# An optional sixth argument {can_send => CODE} is checked before each
# PRIVMSG; false or an exception cancels only that batch.
# PRIVMSG batches serialize behind existing work even when a later batch has
# one chunk or no requested delay; idle immediate-send behavior is unchanged.
sub queue_privmsg_chunks {
    require Mediabot::Helpers;
    return _queue_irc_chunks(@_);
}

sub queue_notices {
    require Mediabot::Helpers;
    return queueBotNotices(@_);
}

sub botNotice {
    return Mediabot::IRC::Output::notice(@_);
}

# Legacy state keys and the two scheduling algorithms are intentionally kept.
sub _queue_irc_chunks {
    my ($self, $target, $chunks, $sleep_us, $label, $options) = @_;
    my $can_send = ref($options) eq 'HASH' && ref($options->{can_send}) eq 'CODE'
        ? $options->{can_send} : undef;

    return 0 unless ref($chunks) eq 'ARRAY';

    my @payload = grep {
        defined($_) && $_ ne ''
    } @$chunks;

    return 0 unless @payload;

    my $queued_count = scalar @payload;

    $sleep_us = 0
        unless defined($sleep_us) && $sleep_us =~ /^\d+\z/;

    $label = 'AI'
        unless defined($label) && $label ne '';

    my $loop = eval {
        (ref($self) && $self->can('getLoop'))
            ? $self->getLoop
            : undef;
    };

    $loop ||= eval { $self->{loop} };

    my $can_add = $loop && eval { $loop->can('add') };
    my $can_start = $can_add && $sleep_us > 0 && @payload > 1;

    # Look up existing work without creating queue state on immediate paths.
    # A later single-line/zero-delay reply still belongs behind earlier work.
    my $queues = ref($self) ? eval { $self->{_external_ai_output_queues} } : undef;
    my ($key, $state);
    if ($can_start || ($queues && %$queues)) {
        $key = defined($target) && $target ne '' ? lc($target) : '__unknown__';
        $state = $queues ? $queues->{$key} : undef;
    }
    my $has_pending = $state
        && ($state->{current} || @{ $state->{batches} // [] });
    my $can_schedule = ($state && $state->{active})
        || ($can_add && ($has_pending || $can_start));

    unless ($can_schedule) {
        for my $chunk (@payload) {
            last if $can_send && !eval { $can_send->() };
            Mediabot::IRC::Output::privmsg($self, $target, $chunk);
        }
        return $queued_count;
    }

    $queues //= $self->{_external_ai_output_queues} //= {};
    $state //= $queues->{$key} //= {
        active  => 0,
        batches => [],
        timer   => undef,
        current => undef,
    };

    push @{ $state->{batches} }, {
        chunks => \@payload,
        delay  => $sleep_us / 1_000_000,
        label  => $label,
        can_send => $can_send,
    };

    return $queued_count if $state->{active};

    $state->{active} = 1;

    my ($pump, $schedule);

    my $is_current = sub {
        my $registered = $self->{_external_ai_output_queues} or return 0;
        return (refaddr($registered->{$key}) // 0) == refaddr($state);
    };
    my $finish = sub {
        # Retire only this pump's state, even if a new connection has already
        # registered another queue for the same target.
        delete $queues->{$key}
            if (refaddr($queues->{$key}) // 0) == refaddr($state);
        delete $state->{retire};
        delete $state->{arm};
        $state->{current} = undef;
        $state->{batches} = [];
        $state->{active} = 0;
        undef $pump;
        undef $schedule;
        return;
    };

    $state->{retire} = $finish;

    $schedule = sub {
        my ($delay) = @_;

        my $arm = $state->{arm} = {};
        my $started = eval {
            my $timer = Mediabot::IRC::Timer::countdown(
                loop => $loop,
                delay => $delay,
                on_expire => sub {
                    return unless (refaddr($state->{arm}) // 0) == refaddr($arm);
                    delete $state->{arm};
                    $state->{timer} = undef;
                    $pump->() if $pump;
                },
            );
            if ($is_current->() && (refaddr($state->{arm}) // 0) == refaddr($arm)) {
                $state->{timer} = $timer;
            } elsif ($timer) {
                # Setup may replace the connection or expire inline. Never
                # publish this late notifier over a successor arm.
                retire_notice_timers($self, [$timer], 'PRIVMSG');
            }
            1;
        };
        unless ($started) {
            my $error = $@;
            # Preserve unsent chunks for the next batch, without leaving an
            # active queue that can never be pumped. Never burst a failed arm.
            if ((refaddr($state->{arm}) // 0) == refaddr($arm)) {
                delete $state->{retire};
                delete $state->{arm};
                $state->{timer} = undef;
                $state->{active} = 0;
                $pump = undef;
                $schedule = undef;
            }
            die $error;
        }
    };

    $pump = sub {
        return $finish->() unless $is_current->();
        my $batch = $state->{current};

        unless ($batch) {
            $batch = shift @{ $state->{batches} };
            $state->{current} = $batch if $batch;
        }

        return $finish->() unless $batch;

        # A revoked or failed guard drops this batch only. The normal boundary
        # delay and successor ordering still apply; unguarded callers are unchanged.
        my $allowed = !$batch->{can_send} || eval { $batch->{can_send}->() };
        return $finish->() unless $is_current->();
        @{ $batch->{chunks} } = () unless $allowed;
        my $chunk = shift @{ $batch->{chunks} };

        if (defined($chunk) && $chunk ne '') {
            my $ok = eval {
                Mediabot::IRC::Output::privmsg($self, $target, $chunk);
                1;
            };

            unless ($ok) {
                # The send may already have reached IRC. Do not replay it,
                # and never let exception overloads strand this active pump
                # while preparing the best-effort diagnostic.
                my $error = $@;
                $error = ref($error) ne '' ? 'non-scalar send exception'
                    : defined($error) && length($error) ? $error : 'unknown send error';
                $error =~ s/\s+/ /g;
                $error = substr($error, 0, 512);
                eval {
                    $self->{logger}->log(
                        1,
                        "$batch->{label} paced output failed for $target: $error"
                    );
                };
            }
        }

        return $finish->() unless $is_current->();
        if (@{ $batch->{chunks} }) {
            $schedule->($batch->{delay});
            return;
        }

        $state->{current} = undef;

        if (@{ $state->{batches} }) {
            # Preserve ordering between consecutive replies on the same target.
            $schedule->($batch->{delay});
            return;
        }

        return $finish->();
    };

    $pump->();

    return $queued_count;
}

# Detach and revoke every old target before notifier cleanup can re-enter.
sub retire_privmsg_queues {
    my ($self, $queues) = @_;
    return 1 unless $queues;
    my @states = values %$queues;
    %$queues = ();
    my @timers;
    for my $state (@states) {
        push @timers, delete $state->{timer};
        my $retire = delete $state->{retire};
        if ($retire) {
            $retire->();
        } else {
            # Failed arms retain their unsent batches for ordinary recovery.
            # A connection replacement revokes those dormant batches as well.
            delete $state->{arm};
            $state->{current} = undef;
            $state->{batches} = [];
            $state->{active} = 0;
        }
    }
    return retire_notice_timers($self, \@timers, 'PRIVMSG');
}

# The caller has already detached this exact registry and published the new
# transport. Never inspect or clear a successor registry during cleanup.
sub retire_notice_timers {
    my ($self, $timers, $kind) = @_;
    $kind //= 'NOTICE';
    return 1 unless $timers;
    my @retired = @$timers;
    @$timers = ();
    my $ok = 1;
    for my $timer (@retired) {
        next unless $timer;
        $ok = 0 unless Mediabot::IRC::Timer::cancel_countdown($timer);
    }
    unless ($ok) {
        eval { $self->{logger}->log(1,
            "$kind output revoked; timer cleanup incomplete") if $self->{logger}; };
    }
    return $ok;
}

sub queueBotNotices {
    my ($self, $nick, @lines) = @_;

    @lines = map { defined($_) && !ref($_) ? "$_" : () } @lines;
    return 1 unless @lines;

    my $max_lines = 16;
    if (@lines > $max_lines) {
        @lines = (
            @lines[0 .. $max_lines - 2],
            '... output truncated; use help search <term> or help <command>',
        );
    }

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        botNotice($self, $nick, $_) for @lines;
        return 1;
    }

    my $delay_step = 1.5;
    $self->{_notice_queue_timers} ||= [];
    my $timers = $self->{_notice_queue_timers};
    # setIrc retires this registry when the transport changes. A nick on
    # the replacement connection must never receive old private output.
    my $is_current = sub {
        return (refaddr($self->{_notice_queue_timers}) // 0) == refaddr($timers);
    };
    my $base_delay = scalar(grep { defined $_ } @$timers) * $delay_step;

    for my $i (0 .. $#lines) {
        last unless $is_current->();
        my $line = $lines[$i];
        my $timer;

        my $started = eval {
            $timer = Mediabot::IRC::Timer::countdown(
                loop => $loop,
                delay => $base_delay + ($i * $delay_step),
                on_expire => sub {
                    my $sent = eval {
                        botNotice($self, $nick, $line) if $is_current->();
                        1;
                    };
                    my $error = $@;
                    my $expired_id = refaddr($timer);
                    @$timers = grep {
                        defined($_) && ref($_) && refaddr($_) != $expired_id
                    } @$timers;
                    undef $timer;
                    # Keep the slot during reentrant sends, but release it even
                    # if the transport throws. Preserve the original exception.
                    die $error unless $sent;
                },
            );
            if ($is_current->()) {
                push @$timers, $timer if $timer;
            } else {
                # Transport replacement during add/start precedes publication
                # in the old registry. Retire this late result explicitly.
                retire_notice_timers($self, [$timer]);
            }
            1;
        };

        unless ($started) {
            undef $timer;
            botNotice($self, $nick, $line) if $is_current->();
        }
    }

    return 1;
}

1;
