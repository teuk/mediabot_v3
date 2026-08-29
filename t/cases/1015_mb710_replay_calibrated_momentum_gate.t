use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Orchestrator;
use Mediabot::Spark::State;

sub _runtime {
    my ($clock) = @_;
    return Mediabot::Spark::Orchestrator->new(
        state => Mediabot::Spark::State->new(clock => $clock),
        observer => Mediabot::Spark::Observer->new(clock => $clock),
        flood_guard => Mediabot::AI::ConversationFloodGuard->new(clock => $clock),
        clock => $clock,
        min_silence_seconds => 1_200,
        candidate_probe_seconds => 300,
        action_min_humans => 3,
        action_min_lines => 6,
        action_min_pause_seconds => 45,
        action_max_pause_seconds => 180,
        action_cooldown_seconds => 1_200,
    );
}

sub _observe {
    my ($runtime, $nick, $message) = @_;
    return $runtime->observe_public_line(
        enabled => 1, channel => '#room', nick => $nick,
        bot_nick => 'Mediabot', message => $message, command_char => '!',
    );
}

sub _action_gate {
    return (
        spark_enabled => 1, action_enabled => 1, ai_available => 1,
        channel => '#room', runtime_active => 1, irc_connected => 1,
        channel_joined => 1, game_active => 0, wit_pending => 0,
    );
}

return sub {
    my ($assert) = @_;

    my $dominated_now = 40_000;
    my $dominated = _runtime(sub { $dominated_now });
    for my $row (
        [Anchor => 'one'], [Anchor => 'two'], [Visitor => 'three'],
        [Anchor => 'four'], [Anchor => 'five'], [Anchor => 'six'],
    ) {
        _observe($dominated, @$row);
        $dominated_now++;
    }
    $dominated_now += 67;
    my $blocked = $dominated->evaluate_action_channel(_action_gate());
    $assert->is($blocked->{action}, 'skip',
        'mb710-1015: replay-shaped dominant exchange cannot start momentum');
    $assert->is($blocked->{reason}, 'audience_too_small',
        'mb710-1015: effective audience owns the momentum gate');
    $assert->is($blocked->{audience_regime}, 'solo',
        'mb710-1015: dominant raw pair remains an effective solo audience');
    $assert->is($blocked->{recent_humans}, 2,
        'mb710-1015: raw nick evidence is retained for metadata diagnostics');
    $assert->ok($blocked->{dominant_share_pct} >= 75,
        'mb710-1015: block is backed by measured speaker dominance');
    $assert->ok($blocked->{effective_humans_milli} < 1_500,
        'mb710-1015: effective audience stays below the small-room threshold');

    my $balanced_now = 50_000;
    my $balanced = _runtime(sub { $balanced_now });
    for my $row (
        [North => 'one'], [South => 'two'],
        [North => 'three'], [South => 'four'],
    ) {
        _observe($balanced, @$row);
        $balanced_now++;
    }
    $balanced_now += 44;
    my $allowed = $balanced->evaluate_action_channel(_action_gate());
    $assert->is($allowed->{action}, 'action_candidate',
        'mb710-1015: balanced two-person exchange still starts momentum');
    $assert->is($allowed->{reason}, 'momentum_ready',
        'mb710-1015: calibrated gate preserves the existing momentum path');
    $assert->is($allowed->{audience_regime}, 'small',
        'mb710-1015: balanced exchange keeps the patient small-room policy');
};
