# t/cases/942_mb703_spark_policy_foundation.t
# =============================================================================
# MB703-A2 — pure fail-closed policy for considering a future Spark event.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Policy qw(
    spark_policy_defaults
    evaluate_spark_start
    spark_policy_summary
);

sub _base_942 {
    return (
        enabled        => 1,
        channel        => '#test',
        runtime_active => 1,
        irc_connected  => 1,
        channel_joined => 1,
        recent_humans  => 2,
        now            => 10_000,
        last_human_at  => 8_000,
    );
}

return sub {
    my ($assert) = @_;

    my $defaults = spark_policy_defaults();
    $assert->is($defaults->{min_silence_seconds}, 1_200,
        'mb703-942: default Spark silence threshold is 20 minutes');
    $assert->is($defaults->{min_recent_humans}, 2,
        'mb703-942: Spark requires at least two recent humans by default');

    for my $case (
        [ disabled          => { enabled => 0 } ],
        [ private           => { channel => 'Alice' } ],
        [ runtime_inactive  => { runtime_active => 0 } ],
        [ irc_disconnected  => { irc_connected => 0 } ],
        [ not_joined        => { channel_joined => 0 } ],
        [ flood_suppression => { flood_suppressed => 1 } ],
        [ event_active      => { event_active => 1 } ],
        [ game_active       => { game_active => 1 } ],
        [ wit_pending       => { wit_pending => 1 } ],
        [ insufficient_humans => { recent_humans => 1 } ],
    ) {
        my ($reason, $override) = @$case;
        my %args = (_base_942(), %$override);
        my $d = evaluate_spark_start(%args);
        $assert->is($d->{action}, 'skip', "mb703-942: $reason fails closed");
        $assert->is($d->{reason}, $reason, "mb703-942: $reason reason is explicit");
    }

    my $cooldown = evaluate_spark_start(
        _base_942(), cooldown_until => 10_300,
    );
    $assert->is($cooldown->{reason}, 'cooldown',
        'mb703-942: active cooldown suppresses Spark');
    $assert->is($cooldown->{retry_after_seconds}, 300,
        'mb703-942: cooldown reports bounded retry timing');

    my $busy = evaluate_spark_start(
        _base_942(), last_human_at => 9_500,
    );
    $assert->is($busy->{reason}, 'not_quiet',
        'mb703-942: recent conversation suppresses Spark');
    $assert->is($busy->{retry_after_seconds}, 700,
        'mb703-942: quiet-time gate reports remaining delay');

    my $eligible = evaluate_spark_start(_base_942());
    $assert->is($eligible->{action}, 'consider',
        'mb703-942: quiet eligible channel may be considered');
    $assert->is($eligible->{reason}, 'eligible',
        'mb703-942: eligible decision is explicit');

    my $summary = spark_policy_summary($eligible);
    $assert->is($summary->{action}, 'consider',
        'mb703-942: policy summary carries action');
    $assert->is($summary->{reason}, 'eligible',
        'mb703-942: policy summary carries reason only');
    $assert->ok(!exists($summary->{channel}) && !exists($summary->{nick}) && !exists($summary->{message}),
        'mb703-942: summary contains no channel identity or conversation payload');
};
