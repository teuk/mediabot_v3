# t/cases/952_mb703_spark_orchestrator_dryrun.t
# =============================================================================
# MB703-D — Deterministic disarmed runtime orchestration.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Orchestrator;
use Mediabot::Spark::State;

return sub {
    my ($assert) = @_;

    my $now = 20_000;
    my $clock = sub { $now };
    my $state = Mediabot::Spark::State->new(clock => $clock);
    my $observer = Mediabot::Spark::Observer->new(clock => $clock);
    my $flood = Mediabot::AI::ConversationFloodGuard->new(clock => $clock);
    my $rt = Mediabot::Spark::Orchestrator->new(
        state => $state,
        observer => $observer,
        flood_guard => $flood,
        clock => $clock,
        min_silence_seconds => 1_200,
        candidate_probe_seconds => 300,
    );

    for my $row (
        [Alice => 'on garde le service comme ça'],
        [Bob   => 'ça semble raisonnable'],
        [Carol => 'phrase dangereuse sur ce serveur'],
    ) {
        $rt->observe_public_line(
            enabled => 1, channel => '#spark', nick => $row->[0],
            bot_nick => 'Mediabot', message => $row->[1], command_char => '!',
        );
        $now += 5;
    }

    $now += 1_200;
    my $decision = $rt->evaluate_channel(
        enabled => 1, channel => '#spark', runtime_active => 1,
        irc_connected => 1, channel_joined => 1,
        game_active => 0, wit_pending => 0, ai_available => 1,
    );
    $assert->is($decision->{action}, 'dryrun_candidate',
        'mb703-952: silence may produce a metadata-only dry-run candidate');
    $assert->is($decision->{kind}, 'reaction',
        'mb708: first rich-context candidate is a natural Reaction');
    $assert->is($state->snapshot('#spark')->{event_active}, 0,
        'mb703-952: disarmed dry-run never creates a fake active event');

    my $log = Mediabot::Spark::Orchestrator::format_dryrun_log('#spark', $decision);
    $assert->like($log, qr/^\[SPARK_DRYRUN\].*kind=reaction/,
        'mb708: Reaction candidate has a grep-friendly metadata log');
    $assert->unlike($log, qr/service|raisonnable|dangereuse/,
        'mb703-952: runtime log never leaks conversation text');

    my $wait = $rt->evaluate_channel(
        enabled => 1, channel => '#spark', runtime_active => 1,
        irc_connected => 1, channel_joined => 1,
        game_active => 0, wit_pending => 0, ai_available => 1,
    );
    $assert->is($wait->{reason}, 'probe_wait',
        'mb703-952: a dry-run candidate is throttled instead of logging every 5 seconds');

    $now += 300;
    my $next = $rt->evaluate_channel(
        enabled => 1, channel => '#spark', runtime_active => 1,
        irc_connected => 1, channel_joined => 1,
        game_active => 0, wit_pending => 0, ai_available => 1,
    );
    $assert->is($next->{action}, 'dryrun_candidate',
        'mb703-952: dry-run may reconsider after its bounded probe interval');
    $assert->ok($next->{kind} ne 'reaction',
        'mb708: contextual schedule avoids immediate event repetition');

    $now += 300;
    my $game = $rt->evaluate_channel(
        enabled => 1, channel => '#spark', runtime_active => 1,
        irc_connected => 1, channel_joined => 1,
        game_active => 1, wit_pending => 0, ai_available => 1,
    );
    $assert->is($game->{reason}, 'game_active',
        'mb703-952: an active game remains an authoritative deterministic gate');
};
