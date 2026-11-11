package Mediabot::IRC::Timer;

use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(weaken);
use Hash::Util::FieldHash qw(fieldhash);

# Weak keys: registration must not keep a stopped notifier alive.
fieldhash my %cancellations;

our @EXPORT_OK = qw(countdown cancel_countdown);

# Start one owned countdown. Scheduling, fallback and retry policies belong to
# callers; this helper owns notifier cleanup and callback lifetime.
sub countdown {
    my (%args) = @_;
    my $loop = $args{loop};
    my $callback = $args{on_expire};
    die "countdown requires an on_expire callback\n" unless ref($callback) eq 'CODE';
    require IO::Async::Timer::Countdown;

    my ($timer, $setup_owner, $finished);
    my $cleanup = sub {
        my ($owned) = @_;
        return unless $owned;
        # Preserve the original setup/callback exception if cleanup also fails.
        my $stopped = eval { $owned->stop if $owned->can('stop'); 1 };
        my $removed = eval { $loop->remove($owned); 1 };
        return $stopped && $removed ? 1 : 0;
    };

    my $started = eval {
        $timer = IO::Async::Timer::Countdown->new(
            delay => $args{delay},
            on_expire => sub {
                return if $finished++;
                my $expired = $timer;
                delete $cancellations{$expired} if $expired;
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
        # The callback must not own its notifier: stop/remove can retire it
        # before expiry ever breaks the cycle. Keep a strong setup owner until
        # return, so add/start (including inline expiry) remain safe too.
        $setup_owner = $timer;
        weaken($timer);
        $cancellations{$timer} = sub {
            return 1 if $finished++;
            my $owned = $timer;
            undef $timer;
            undef $callback; # revoke payload before stop/remove can reenter
            my $ok = $cleanup->($owned);
            undef $cleanup;
            undef $loop;
            return $ok;
        };
        $loop->add($timer);
        # MB1146: add() may expire inline and release the timer already.
        # Do not restart completed work or dereference its cleared owner.
        $timer->start unless $finished;
        1;
    };
    unless ($started) {
        my $error = $@;
        $finished = 1;
        undef $callback;
        my $failed = $timer;
        delete $cancellations{$failed} if $failed;
        undef $timer;
        # Inline expiry may already have completed cleanup before start or
        # user code throws. Preserve that original exception in this case.
        $cleanup->($failed) if $cleanup;
        undef $cleanup;
        undef $loop;
        die $error;
    }
    return $timer;
}

# Revoke before cleanup. Repeated calls are inert; failure reports incomplete
# physical cleanup, never permission for a retained callback to run again.
sub cancel_countdown {
    my ($timer) = @_;
    return 1 unless $timer;
    my $cancel = delete $cancellations{$timer};
    return 1 unless $cancel;
    return $cancel->();
}

1;

__END__

=head1 NAME

Mediabot::IRC::Timer - Owned, single-use countdown for IRC output queues.

=head1 SYNOPSIS

    use Mediabot::IRC::Timer qw(countdown cancel_countdown);

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

The callback holds only a weak reference to its notifier. After an early
C<stop>/C<remove>, releasing the remaining notifier owners can therefore free
the notifier and its callback payload without waiting for expiry. The helper
keeps a separate strong owner during setup and return. Caller-created cycles
or externally retained callbacks still require their own lifetime management;
C<stop> alone is not a callback-revocation API.

C<cancel_countdown($timer)> explicitly revokes a live countdown created by this
module, releases its callback payload and attempts stop and removal independently.
It returns 0 if either operation throws, otherwise 1. Repeated cancellation or
cancellation after completion returns 1 without retrying cleanup; a prior 0 must
still be handled by the owner. It does not cancel arbitrary external timers.
A failed removal can leave an inert notifier attached to a broken loop.

Constructor, add, start and callback exceptions propagate unchanged. Cleanup
attempts stop/remove even after a partially successful add, and suppresses
cleanup errors to preserve the original exception. A broken loop that refuses
removal cannot be guaranteed to release its notifier.

This helper defines no send, retry, queue, rate, fallback or shutdown policy.
Output queues retain their own state and recovery decisions. Do not substitute
it for a periodic timer or a component with a different cancellation contract.

=cut
