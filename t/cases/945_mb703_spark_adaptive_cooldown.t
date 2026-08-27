# t/cases/945_mb703_spark_adaptive_cooldown.t
# =============================================================================
# MB703-B — deterministic adaptive cooldown and event-expiry behavior.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::State;

return sub {
    my ($assert) = @_;

    my $now = 10_000;
    my $state = Mediabot::Spark::State->new(clock => sub { $now });

    my @expected = (2700, 5400, 14400, 28800, 28800);
    for my $round (1 .. 5) {
        my $gen = $state->begin_event(channel => '#quiet', kind => 'fork');
        $assert->ok(defined($gen),
            "mb703-945: miss round $round starts after previous cooldown");

        my $done = $state->finish_event(channel => '#quiet', outcome => 'miss');
        $assert->is($done->{miss_streak}, $round,
            "mb703-945: miss round $round increments consecutive miss streak");
        $assert->is($done->{cooldown_seconds}, $expected[$round - 1],
            "mb703-945: miss round $round selects expected adaptive cooldown");
        $assert->ok(!$state->generation_is_current('#quiet', $gen),
            "mb703-945: miss round $round revokes the completed event generation");

        $now = $done->{cooldown_until};
    }

    my $gen_success = $state->begin_event(channel => '#quiet', kind => 'portal');
    my $success = $state->finish_event(channel => '#quiet', outcome => 'engaged');
    $assert->is($success->{miss_streak}, 0,
        'mb703-945: engagement resets accumulated misses');
    $assert->is($success->{cooldown_seconds}, 3600,
        'mb703-945: engagement applies normal one-hour pacing');
    $assert->ok(!$state->generation_is_current('#quiet', $gen_success),
        'mb703-945: engagement revokes any late event-generation work');

    $now = $success->{cooldown_until};
    $state->begin_event(channel => '#quiet', kind => 'callback');
    my $superseded = $state->finish_event(channel => '#quiet', outcome => 'superseded');
    $assert->is($superseded->{miss_streak}, 0,
        'mb703-945: organic conversation superseding Spark is not counted as a flop');
    $assert->is($superseded->{cooldown_seconds}, 1800,
        'mb703-945: organic resumption gives Spark a quiet half-hour before reconsidering');

    $now = $superseded->{cooldown_until};
    $state->begin_event(channel => '#quiet', kind => 'callback');
    my $error = $state->finish_event(channel => '#quiet', outcome => 'error');
    $assert->is($error->{miss_streak}, 0,
        'mb703-945: provider/internal error does not poison social miss history');
    $assert->is($error->{cooldown_seconds}, 900,
        'mb703-945: technical failure backs off for 15 minutes');

    $now = $error->{cooldown_until};
    my $expiring_gen = $state->begin_event(
        channel          => '#quiet',
        kind             => 'fork',
        duration_seconds => 30,
    );
    $now += 29;
    $assert->ok(!defined($state->expire_due_event('#quiet')),
        'mb703-945: event does not expire before its deadline');
    $assert->ok($state->generation_is_current('#quiet', $expiring_gen),
        'mb703-945: pre-deadline generation remains current');

    $now += 1;
    my $expired = $state->expire_due_event('#quiet');
    $assert->is($expired->{outcome}, 'miss',
        'mb703-945: deadline expiry closes event as a miss');
    $assert->is($expired->{miss_streak}, 1,
        'mb703-945: deadline miss starts adaptive backoff ladder');
    $assert->is($expired->{cooldown_seconds}, 2700,
        'mb703-945: first timed-out event backs off 45 minutes');
    $assert->ok(!$state->generation_is_current('#quiet', $expiring_gen),
        'mb703-945: expiry invalidates late asynchronous completion');

    my $rollback_now = 50_000;
    my $rollback = Mediabot::Spark::State->new(clock => sub { $rollback_now });
    $rollback->observe_human(channel => '#clock', nick => 'Alice');
    $rollback_now = 49_999;
    my $clock_ok = eval { $rollback->snapshot('#clock'); 1 };
    $assert->ok(!$clock_ok && $@ =~ /clock moved backwards/,
        'mb703-945: injected backwards clock fails closed');

    my $bounded_now = 60_000;
    my $bounded = Mediabot::Spark::State->new(
        clock                  => sub { ++$bounded_now },
        max_channels           => 2,
        max_humans_per_channel => 2,
    );
    $bounded->observe_human(channel => '#one', nick => 'One');
    $bounded->observe_human(channel => '#two', nick => 'Two');
    $bounded->observe_human(channel => '#three', nick => 'Three');
    $assert->is(scalar(keys %{ $bounded->{channel_state} }), 2,
        'mb703-945: per-process channel state remains bounded');
    $assert->ok(!exists($bounded->{channel_state}{'#one'}),
        'mb703-945: oldest inactive channel is evicted first');

    $bounded->observe_human(channel => '#three', nick => 'Four');
    $bounded->observe_human(channel => '#three', nick => 'Five');
    $assert->is(scalar(keys %{ $bounded->{channel_state}{'#three'}{humans} }), 2,
        'mb703-945: distinct-human tracking remains bounded per channel');
};
