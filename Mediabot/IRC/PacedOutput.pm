package Mediabot::IRC::PacedOutput;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Scalar::Util qw(refaddr);

our @EXPORT_OK = qw(queue_privmsg_chunks queue_notices);

# Keep runtime loading lazy. Every send re-enters Helpers so workers, normal
# output policy and existing instrumentation still see the same facade.
sub queue_privmsg_chunks {
    require Mediabot::Helpers;
    return _queue_irc_chunks(@_);
}

sub queue_notices {
    require Mediabot::Helpers;
    require IO::Async::Timer::Countdown;
    return queueBotNotices(@_);
}

sub botNotice {
    return Mediabot::Helpers::botNotice(@_);
}

# Legacy state keys and the two scheduling algorithms are intentionally kept.
sub _queue_irc_chunks {
    my ($self, $target, $chunks, $sleep_us, $label) = @_;

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

    my $can_schedule = $loop
        && eval { $loop->can('add') }
        && $sleep_us > 0
        && @payload > 1;

    unless ($can_schedule) {
        Mediabot::Helpers::botPrivmsg($self, $target, $_) for @payload;
        return $queued_count;
    }

    require IO::Async::Timer::Countdown;

    my $key = defined($target) && $target ne ''
        ? lc($target)
        : '__unknown__';

    my $queues = $self->{_external_ai_output_queues} //= {};
    my $state  = $queues->{$key} //= {
        active  => 0,
        batches => [],
        timer   => undef,
        current => undef,
    };

    push @{ $state->{batches} }, {
        chunks => \@payload,
        delay  => $sleep_us / 1_000_000,
        label  => $label,
    };

    return $queued_count if $state->{active};

    $state->{active} = 1;

    my ($pump, $schedule);

    my $cleanup = sub {
        my ($timer) = @_;
        return unless $timer;

        eval { $timer->stop if $timer->can('stop') };
        eval { $loop->remove($timer) };
    };

    $schedule = sub {
        my ($delay) = @_;

        my $timer;
        $timer = IO::Async::Timer::Countdown->new(
            delay     => $delay,
            on_expire => sub {
                $cleanup->($timer);
                $state->{timer} = undef;
                $pump->();
                # mb326-B1: rompre le cycle closure<->timer (le slot hash est vidé
                # mais le lexical capturé maintenait l'objet en vie).
                undef $timer;
            },
        );

        $state->{timer} = $timer;
        $loop->add($timer);
        $timer->start;
    };

    $pump = sub {
        my $batch = $state->{current};

        unless ($batch) {
            $batch = shift @{ $state->{batches} };
            $state->{current} = $batch if $batch;
        }

        unless ($batch) {
            delete $queues->{$key};
            $pump     = undef;
            $schedule = undef;
            return;
        }

        my $chunk = shift @{ $batch->{chunks} };

        if (defined($chunk) && $chunk ne '') {
            my $ok = eval {
                Mediabot::Helpers::botPrivmsg($self, $target, $chunk);
                1;
            };

            unless ($ok) {
                my $error = $@ || 'unknown send error';
                $error =~ s/\s+/ /g;
                eval {
                    $self->{logger}->log(
                        1,
                        "$batch->{label} paced output failed for $target: $error"
                    );
                };
            }
        }

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

        delete $queues->{$key};
        $pump     = undef;
        $schedule = undef;
    };

    $pump->();

    return $queued_count;
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
    my $base_delay = scalar(grep { defined $_ } @$timers) * $delay_step;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        my $timer;

        $timer = IO::Async::Timer::Countdown->new(
            delay => $base_delay + ($i * $delay_step),
            on_expire => sub {
                botNotice($self, $nick, $line);
                eval { $loop->remove($timer) };
                my $expired_id = refaddr($timer);
                @$timers = grep {
                    defined($_) && ref($_) && refaddr($_) != $expired_id
                } @$timers;
                undef $timer;
            },
        );

        push @$timers, $timer;
        my $started = eval {
            $loop->add($timer);
            $timer->start;
            1;
        };

        unless ($started) {
            my $failed_id = refaddr($timer);
            @$timers = grep {
                defined($_) && ref($_) && refaddr($_) != $failed_id
            } @$timers;
            botNotice($self, $nick, $line);
            undef $timer;
        }
    }

    return 1;
}

1;
