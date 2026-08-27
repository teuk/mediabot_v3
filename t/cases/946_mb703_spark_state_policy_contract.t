# t/cases/946_mb703_spark_state_policy_contract.t
# =============================================================================
# MB703-G — State stays pure while guarded delivery consumes its generation.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Policy qw(evaluate_spark_start);
use Mediabot::Spark::State;

return sub {
    my ($assert) = @_;

    my $now = 100_000;
    my $state = Mediabot::Spark::State->new(clock => sub { $now });
    $state->observe_human(channel => '#spark', nick => 'Alice');
    $now += 10;
    $state->observe_human(channel => '#spark', nick => 'Bob');
    $now += 1_200;

    my $snap = $state->snapshot('#spark');
    my $decision = evaluate_spark_start(
        enabled          => 1,
        channel          => '#spark',
        runtime_active   => 1,
        irc_connected    => 1,
        channel_joined   => 1,
        flood_suppressed => 0,
        event_active     => $snap->{event_active},
        game_active      => 0,
        wit_pending      => 0,
        recent_humans    => $snap->{recent_humans},
        last_human_at    => $snap->{last_human_at},
        cooldown_until   => $snap->{cooldown_until},
        now              => $now,
    );
    $assert->is($decision->{action}, 'consider',
        'mb703-946: pure State metadata can satisfy pure Spark Policy after silence');
    $assert->is($decision->{reason}, 'eligible',
        'mb703-946: state/policy handoff preserves deterministic eligibility reason');

    my $gen = $state->begin_event(channel => '#spark', kind => 'callback');
    $snap = $state->snapshot('#spark');
    $decision = evaluate_spark_start(
        enabled          => 1,
        channel          => '#spark',
        runtime_active   => 1,
        irc_connected    => 1,
        channel_joined   => 1,
        event_active     => $snap->{event_active},
        recent_humans    => $snap->{recent_humans},
        last_human_at    => $snap->{last_human_at},
        cooldown_until   => $snap->{cooldown_until},
        now              => $now,
    );
    $assert->is($decision->{reason}, 'event_active',
        'mb703-946: active State event feeds Policy duplicate-event gate');

    $assert->ok($state->generation_is_current('#spark', $gen),
        'mb703-946: future AI work can bind to active event generation');
    $state->invalidate_event('#spark');
    $assert->ok(!$state->generation_is_current('#spark', $gen),
        'mb703-946: future late AI completion can be revoked deterministically');

    my $module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Spark/State.pm"
            or die "open State.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($module, qr/\b(?:DBI|HTTP|HTTPS|AI::Client|Provider::Anthropic|Provider::OpenAI)\b/,
        'mb703-946: Spark State owns no database, network or AI provider dependency');
    $assert->unlike($module, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb703-946: Spark State owns no IRC emission primitive');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };
    $assert->like($main, qr/Mediabot::Spark::State/,
        'mb703-946: later MB703-D runtime wiring reuses the same pure State metadata');
    $assert->like($main, qr/SPARK_SEND_ARMED/,
        'mb703-946: runtime delivery arm is separate from pure State semantics');
};
