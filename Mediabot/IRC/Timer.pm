package Mediabot::IRC::Timer;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(countdown);

# Start one owned countdown. Scheduling, fallback and retry policies belong to
# callers; this helper owns notifier cleanup and callback lifetime.
sub countdown {
    my (%args) = @_;
    my $loop = $args{loop};
    my $callback = $args{on_expire};
    die "countdown requires an on_expire callback\n" unless ref($callback) eq 'CODE';
    require IO::Async::Timer::Countdown;

    my ($timer, $finished);
    my $cleanup = sub {
        my ($owned) = @_;
        return unless $owned;
        # Preserve the original setup/callback exception if cleanup also fails.
        eval { $owned->stop if $owned->can('stop') };
        eval { $loop->remove($owned) };
    };

    my $started = eval {
        $timer = IO::Async::Timer::Countdown->new(
            delay => $args{delay},
            on_expire => sub {
                return if $finished++;
                my $expired = $timer;
                # mb326-B1: release the closure's timer before invoking user code,
                # including when that code throws or schedules another timer.
                undef $timer;
                my $run = $callback;
                undef $callback;
                $cleanup->($expired);
                undef $cleanup;
                undef $loop;
                return $run->(@_);
            },
        );
        $loop->add($timer);
        $timer->start;
        1;
    };
    unless ($started) {
        my $error = $@;
        $finished = 1;
        undef $callback;
        my $failed = $timer;
        undef $timer;
        $cleanup->($failed);
        undef $cleanup;
        undef $loop;
        die $error;
    }
    return $timer;
}

1;

__END__

=head1 NAME

Mediabot::IRC::Timer - Owned, single-use countdown for IRC output queues.

=head1 SYNOPSIS

    use Mediabot::IRC::Timer qw(countdown);

    countdown(
        loop => $loop,
        delay => 1.5,
        on_expire => sub { ... },
    );

=head1 CONTRACT

C<countdown> creates, adds and starts one IO::Async countdown. It returns the
started notifier. The loop must support C<add> and C<remove>; the callback must
be a code reference. IO::Async is loaded only when scheduling is requested.

At expiration the helper stops and removes its notifier before invoking the
callback, forwards event arguments, and releases its captured payload and timer.
A retained expiry callback is inert after completion or failed setup. The
returned notifier is single-use; restarting it is outside this contract.

Constructor, add, start and callback exceptions propagate unchanged. Cleanup
attempts stop/remove even after a partially successful add, and suppresses
cleanup errors to preserve the original exception. A broken loop that refuses
removal cannot be guaranteed to release its notifier.

This helper defines no send, retry, queue, rate, fallback or shutdown policy.
Output queues retain their own state and recovery decisions. Do not substitute
it for a periodic timer or a component with a different cancellation contract.

=cut
