package Mediabot::IRC::OutputBudget;
use strict;
use warnings;
use Time::HiRes ();
use Scalar::Util qw(looks_like_number);
use POSIX qw(isfinite);

sub now { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }

sub _parameter {
    my ($value, $default) = @_;
    return $default unless defined($value) && !ref($value)
        && looks_like_number($value) && isfinite($value) && $value >= 0;
    return 0 + $value;
}

# Refill at the previously observed rate before adopting new settings.
# Raising capacity never grants an extra burst; lowering it clamps the balance.
sub refresh {
    my ($state, $capacity, $period) = @_;
    $capacity = _parameter($capacity, 5);
    $period = _parameter($period, 30);
    $period = 1 if $period < 1; # historical zero-duration rows must not divide by zero
    my $now = now();
    my $bucket = $state->{bucket};
    unless ($bucket) {
        # Upgrade an existing counter conservatively: no wall-clock elapsed
        # time can safely be converted into a monotonic refill interval.
        my $used = _parameter($state->{nbmsg}, 0);
        my $tokens = $capacity - $used;
        $tokens = 0 if $tokens < 0;
        $bucket = $state->{bucket} = {tokens=>$tokens, at=>$now,
            capacity=>$capacity, period=>$period};
    } else {
        if ($now > $bucket->{at}) {
            $bucket->{tokens} += ($now - $bucket->{at}) * $bucket->{capacity} / $bucket->{period};
            $bucket->{at} = $now;
        }
        $bucket->{tokens} = $bucket->{capacity} if $bucket->{tokens} > $bucket->{capacity};
        $bucket->{tokens} = $capacity if $bucket->{tokens} > $capacity;
        $bucket->{capacity} = $capacity;
        $bucket->{period} = $period;
    }
    $state->{nbmsg} = $capacity - $bucket->{tokens};
    return $bucket;
}

1;
