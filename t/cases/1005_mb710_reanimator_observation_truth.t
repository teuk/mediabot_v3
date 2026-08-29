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

return sub {
    my ($assert) = @_;

    my $now = 30_000;
    my $clock = sub { $now };
    my $state = Mediabot::Spark::State->new(clock => $clock);
    my $observer = Mediabot::Spark::Observer->new(clock => $clock);
    my $runtime = Mediabot::Spark::Orchestrator->new(
        state => $state,
        observer => $observer,
        flood_guard => Mediabot::AI::ConversationFloodGuard->new(clock => $clock),
        clock => $clock,
        min_silence_seconds => 1_200,
        action_min_humans => 2,
        action_min_lines => 3,
        action_min_pause_seconds => 45,
        action_max_pause_seconds => 180,
    );

    for my $row (
        [Relay => 'feed item', 1, 0],
        [Alice => 'm status', 0, 1],
    ) {
        $runtime->observe_public_line(
            enabled => 1, channel => '#room', nick => $row->[0],
            bot_nick => 'Mediabot', message => $row->[1], command_char => '!',
            from_bot => $row->[2], initial_trigger_enabled => $row->[3],
        );
        $now++;
    }
    $assert->is($state->snapshot('#room')->{recent_humans}, 0,
        'mb710-1005: bot and command traffic cannot manufacture an audience');
    $assert->is(scalar(@{ $observer->context_lines('#room') }), 0,
        'mb710-1005: bot and command traffic cannot reach provider context');

    for my $row (
        [Alice => 'le café arrive'],
        [Bob => 'le test attend'],
        [Alice => 'le serveur négocie'],
    ) {
        $runtime->observe_public_line(
            enabled => 1, channel => '#room', nick => $row->[0],
            bot_nick => 'Mediabot', message => $row->[1], command_char => '!',
        );
        $now++;
    }
    $assert->is($state->snapshot('#room')->{recent_humans}, 2,
        'mb710-1005: genuine conversation still populates Spark state');

    $runtime->observe_public_line(
        enabled => 1, channel => '#room', nick => 'Relay',
        bot_nick => 'Mediabot', message => 'another item', command_char => '!',
        from_bot => 1,
    );
    $now += 10;
    my %gate = (
        spark_enabled => 1, action_enabled => 1, ai_available => 1,
        channel => '#room', runtime_active => 1, irc_connected => 1,
        channel_joined => 1, game_active => 0, wit_pending => 0,
    );
    my $pressure_wait = $runtime->evaluate_action_channel(%gate);
    $assert->is($pressure_wait->{reason}, 'action_probe_wait',
        'mb710-1005: recent bot pressure postpones an unsolicited action');

    $now += 35;
    my $candidate = $runtime->evaluate_action_channel(%gate);
    $assert->is($candidate->{action}, 'action_candidate',
        'mb710-1005: a real small-group pause remains eligible after pressure clears');
    $assert->ok($candidate->{effective_humans_milli} > 1_000,
        'mb710-1005: candidate metadata carries effective audience size');
    my $log = Mediabot::Spark::Orchestrator::format_action_candidate_log(
        '#room', $candidate,
    );
    $assert->like($log, qr/effective_humans_milli=\d+/,
        'mb710-1005: effective audience is visible in metadata-only diagnostics');
    $assert->unlike($log, qr/café|serveur|Alice|Bob|Relay/i,
        'mb710-1005: diagnostics expose neither content nor identities');
};
