# t/cases/944_mb703_spark_state_foundation.t
# =============================================================================
# MB703-B — pure Spark per-channel activity and event-generation state.
# No runtime wiring, AI call, timer or IRC emission.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::State qw(spark_state_defaults spark_state_summary);

return sub {
    my ($assert) = @_;

    my $defaults = spark_state_defaults();
    $assert->is($defaults->{recent_window_seconds}, 7200,
        'mb703-944: recent-human window defaults to two hours');
    $assert->is($defaults->{event_duration_seconds}, 60,
        'mb703-944: Spark event lifetime defaults to one minute');
    $assert->is(join(',', @{ $defaults->{miss_cooldown_seconds} }), '2700,5400,14400,28800',
        'mb703-944: adaptive miss cooldown ladder is 45m, 90m, 4h, 8h');

    my $now = 1_000;
    my $state = Mediabot::Spark::State->new(clock => sub { $now });

    my $snap = $state->snapshot('#Test');
    $assert->is($snap->{event_active}, 0,
        'mb703-944: unknown channel starts with no active event');
    $assert->is($snap->{recent_humans}, 0,
        'mb703-944: unknown channel starts with no recent humans');
    $assert->ok(!defined($snap->{last_human_at}),
        'mb703-944: unknown channel does not invent human activity');
    $assert->is($snap->{current_generation}, 0,
        'mb703-944: unknown channel has no event generation');

    my $seen = $state->observe_human(channel => '#Test', nick => 'Alice');
    $assert->is($seen->{recent_humans}, 1,
        'mb703-944: first distinct human is recorded');
    $assert->is($seen->{last_human_at}, 1000,
        'mb703-944: human activity records monotonic time');

    $now = 1_010;
    $state->observe_human(channel => '#test', nick => 'ALICE');
    $state->observe_human(channel => '#TEST', nick => 'Bob');
    $snap = $state->snapshot('#test');
    $assert->is($snap->{recent_humans}, 2,
        'mb703-944: channel and nick state is case-folded for distinct-human counting');
    $assert->is($snap->{last_human_at}, 1010,
        'mb703-944: latest human activity advances normally');

    my $gen1 = $state->begin_event(channel => '#test', kind => 'fork');
    $assert->ok(defined($gen1) && $gen1 > 0,
        'mb703-944: event start creates a positive generation token');
    $assert->is($state->capture_event_generation('#TEST'), $gen1,
        'mb703-944: active event exposes its generation to future async work');
    $assert->ok($state->generation_is_current('#test', $gen1),
        'mb703-944: active generation validates as current');
    $assert->ok(!defined($state->begin_event(channel => '#test', kind => 'portal')),
        'mb703-944: a channel cannot run two Spark events at once');

    $snap = $state->snapshot('#test');
    $assert->is($snap->{event_active}, 1,
        'mb703-944: snapshot exposes active event state');
    $assert->is($snap->{event_kind}, 'fork',
        'mb703-944: snapshot exposes only the event machine token');
    $assert->is($snap->{event_started_at}, 1010,
        'mb703-944: event start time is deterministic');
    $assert->is($snap->{event_deadline_at}, 1070,
        'mb703-944: default event deadline is 60 seconds');

    $now = 1_020;
    my $done = $state->finish_event(channel => '#test', outcome => 'engaged');
    $assert->is($done->{outcome}, 'engaged',
        'mb703-944: engaged event closes explicitly');
    $assert->is($done->{cooldown_seconds}, 3600,
        'mb703-944: successful participation still receives an anti-spam cooldown');
    $assert->is($done->{miss_streak}, 0,
        'mb703-944: engagement clears miss streak');
    $assert->ok($done->{new_generation} > $gen1,
        'mb703-944: event completion advances generation and revokes late work');
    $assert->ok(!$state->generation_is_current('#test', $gen1),
        'mb703-944: completed event rejects its old generation token');
    $assert->ok(!defined($state->capture_event_generation('#test')),
        'mb703-944: inactive event cannot capture a generation');
    $assert->ok(!defined($state->begin_event(channel => '#test', kind => 'callback')),
        'mb703-944: cooldown prevents an immediate replacement event');

    $now = $done->{cooldown_until};
    my $gen2 = $state->begin_event(channel => '#test', kind => 'callback', duration_seconds => 90);
    $assert->ok(defined($gen2) && $gen2 > $done->{new_generation},
        'mb703-944: event may start exactly when cooldown expires');
    $assert->is($state->snapshot('#test')->{event_deadline_at}, $now + 90,
        'mb703-944: explicit event duration is bounded and recorded');

    my $invalidated = $state->invalidate_event('#test');
    $assert->ok($invalidated > $gen2,
        'mb703-944: explicit invalidation advances generation for late AI revocation');
    $assert->ok(!$state->generation_is_current('#test', $gen2),
        'mb703-944: invalidated event rejects its former provider generation');
    $assert->is($state->snapshot('#test')->{event_active}, 0,
        'mb703-944: invalidation clears active event state');

    $now += 7_201;
    $assert->is($state->snapshot('#test')->{recent_humans}, 0,
        'mb703-944: distinct-human count ages out after the bounded recent window');

    my $summary = spark_state_summary({
        %{ $state->snapshot('#test') },
        nick       => 'Alice',
        message    => 'private payload',
        prompt     => 'secret prompt',
        provider   => 'openai',
        api_key    => 'secret',
    });
    $assert->ok(ref($summary) eq 'HASH',
        'mb703-944: state summary returns bounded metadata');
    $assert->ok(!exists($summary->{nick}) && !exists($summary->{message})
            && !exists($summary->{prompt}) && !exists($summary->{provider})
            && !exists($summary->{api_key}),
        'mb703-944: summaries cannot expose users, conversation text, prompts or credentials');

    my $bad_channel = eval { $state->snapshot('Alice'); 1 };
    $assert->ok(!$bad_channel && $@ =~ /public IRC channel/,
        'mb703-944: private targets are rejected');

    my $bad_nick = eval { $state->observe_human(channel => '#test', nick => "Bad\nNick"); 1 };
    $assert->ok(!$bad_nick && $@ =~ /nickname/,
        'mb703-944: unsafe nick input is rejected');
};
