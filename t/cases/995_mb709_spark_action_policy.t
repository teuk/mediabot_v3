# t/cases/995_mb709_spark_action_policy.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::ActionPolicy qw(
    spark_action_policy_defaults
    evaluate_spark_action_start
    spark_action_policy_summary
);

return sub {
    my ($assert) = @_;

    my $defaults = spark_action_policy_defaults();
    $assert->is($defaults->{activity_window_seconds}, 600,
        'mb709-995: momentum activity window defaults to ten minutes');
    $assert->is($defaults->{min_recent_humans}, 3,
        'mb709-995: momentum needs three distinct humans by default');
    $assert->is($defaults->{min_recent_lines}, 6,
        'mb709-995: momentum needs six recent lines by default');
    $assert->is($defaults->{min_pause_seconds}, 45,
        'mb709-995: action waits for a breathing pause');
    $assert->is($defaults->{max_pause_seconds}, 180,
        'mb709-995: stale momentum expires after three minutes');

    my %ready = (
        spark_enabled => 1, action_enabled => 1, channel => '#spark',
        runtime_active => 1, irc_connected => 1, channel_joined => 1,
        flood_suppressed => 0, event_active => 0, game_active => 0,
        wit_pending => 0, cooldown_until => 0, now => 10_000,
        last_human_at => 9_940, recent_humans => 3, recent_lines => 6,
    );

    for my $gate (
        [ spark_enabled => 0, 'spark_disabled' ],
        [ action_enabled => 0, 'action_disabled' ],
        [ runtime_active => 0, 'runtime_inactive' ],
        [ irc_connected => 0, 'irc_disconnected' ],
        [ channel_joined => 0, 'not_joined' ],
        [ flood_suppressed => 1, 'flood_suppression' ],
        [ event_active => 1, 'event_active' ],
        [ game_active => 1, 'game_active' ],
        [ wit_pending => 1, 'wit_pending' ],
    ) {
        my ($key, $value, $reason) = @$gate;
        my $decision = evaluate_spark_action_start(%ready, $key => $value);
        $assert->is($decision->{reason}, $reason,
            "mb709-995: $key gate fails closed with explicit reason");
    }

    my $private = evaluate_spark_action_start(%ready, channel => 'Alice');
    $assert->is($private->{reason}, 'private',
        'mb709-995: action policy accepts public channels only');
    my $few_humans = evaluate_spark_action_start(%ready, recent_humans => 2);
    $assert->is($few_humans->{reason}, 'insufficient_humans',
        'mb709-995: insufficient distinct participation is rejected');
    my $few_lines = evaluate_spark_action_start(%ready, recent_lines => 5);
    $assert->is($few_lines->{reason}, 'insufficient_lines',
        'mb709-995: sparse conversation is rejected');

    my $busy = evaluate_spark_action_start(%ready, last_human_at => 9_980);
    $assert->is($busy->{reason}, 'momentum_busy',
        'mb709-995: live conversation is never interrupted');
    $assert->is($busy->{retry_after_seconds}, 25,
        'mb709-995: busy decision reports the remaining breathing pause');
    my $expired = evaluate_spark_action_start(%ready, last_human_at => 9_799);
    $assert->is($expired->{reason}, 'momentum_expired',
        'mb709-995: old conversation is not reanimated');

    my $decision = evaluate_spark_action_start(%ready);
    $assert->is($decision->{action}, 'consider',
        'mb709-995: qualified recent momentum can be considered');
    $assert->is($decision->{reason}, 'momentum_ready',
        'mb709-995: eligible reason identifies the independent momentum lane');
    my $summary = spark_action_policy_summary($decision);
    $assert->is($summary->{quiet_for_seconds}, 60,
        'mb709-995: safe summary retains timing metadata');
    $assert->unlike(join(',', sort keys %$summary), qr/(?:channel|nick|message|text)/,
        'mb709-995: safe policy summary contains no identity or conversation text');

    open my $fh, '<:encoding(UTF-8)',
        "$Bin/../../Mediabot/Spark/ActionPolicy.pm" or die $!;
    local $/;
    my $source = <$fh>;
    $assert->unlike(
        $source,
        qr/\b(?:DBI|HTTP|AI::Client|botPrivmsg|botNotice|Net::Async::IRC)\b/,
        'mb709-995: pure action policy owns no DB, network, AI or IRC primitive');
};
