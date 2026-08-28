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
    my $now = 50_000;
    my $clock = sub { $now };
    my $state = Mediabot::Spark::State->new(clock => $clock);
    my $observer = Mediabot::Spark::Observer->new(clock => $clock);
    my $flood = Mediabot::AI::ConversationFloodGuard->new(clock => $clock);
    my $rt = Mediabot::Spark::Orchestrator->new(
        state => $state, observer => $observer, flood_guard => $flood,
        clock => $clock, action_probe_seconds => 30,
        action_cooldown_seconds => 1_200,
    );

    for my $row (
        [Alice => 'le café a gagné'], [Bob => 'encore'],
        [Carol => 'le test était rapide'], [Alice => 'dans une autre époque'],
        [Bob => 'le serveur médite'], [Carol => 'avec beaucoup de conviction'],
    ) {
        $rt->observe_public_line(
            enabled => 1, channel => '#spark', nick => $row->[0],
            bot_nick => 'Mediabot', message => $row->[1], command_char => '!',
        );
        $now += 1;
    }
    $now += 54;

    my %gate = (
        spark_enabled => 1, action_enabled => 1, ai_available => 1,
        channel => '#spark', runtime_active => 1, irc_connected => 1,
        channel_joined => 1, game_active => 0, wit_pending => 0,
    );
    my $candidate = $rt->evaluate_action_channel(%gate);
    $assert->is($candidate->{action}, 'action_candidate',
        'mb709-1001: qualified momentum produces an active-family candidate');
    $assert->is($candidate->{kind}, 'stage_cue',
        'mb709-1001: first momentum family is Stage Cue');
    $assert->is($candidate->{context_lines}, 6,
        'mb709-1001: candidate reports bounded context shape only');
    $assert->is($state->snapshot('#spark')->{event_active}, 0,
        'mb709-1001: evaluation alone never creates a visible event');

    my $event_generation = $state->begin_event(
        channel => '#spark', kind => 'stage_cue', duration_seconds => 45,
    );
    $assert->ok($event_generation,
        'mb709-1001: guarded delivery may create the visible ambient event');
    my $delivered = $state->finish_event(
        channel => '#spark', outcome => 'delivered', cooldown_seconds => 1_200,
    );
    $assert->is($delivered->{cooldown_seconds}, 1_200,
        'mb709-1001: Stage Cue uses the reviewed action cooldown in State');

    my $log = Mediabot::Spark::Orchestrator::format_action_candidate_log(
        '#spark', $candidate,
    );
    $assert->like($log, qr/^\[SPARK_ACTION_CANDIDATE\].*kind=stage_cue/,
        'mb709-1001: candidate has a dedicated metadata marker');
    $assert->unlike($log, qr/café|serveur|conviction/,
        'mb709-1001: candidate log contains no conversation text');

    my $paced = $rt->mark_action_delivered('#spark');
    $assert->is($paced->{cooldown_seconds}, 1_200,
        'mb709-1001: delivered action installs its own pacing interval');
    $now += 30;
    my $wait = $rt->evaluate_action_channel(%gate);
    $assert->is($wait->{reason}, 'action_probe_wait',
        'mb709-1001: action cooldown prevents immediate repetition');

    my $no_ai = Mediabot::Spark::Orchestrator->new(
        state => Mediabot::Spark::State->new(clock => $clock),
        observer => Mediabot::Spark::Observer->new(clock => $clock),
        flood_guard => Mediabot::AI::ConversationFloodGuard->new(clock => $clock),
        clock => $clock,
    );
    $assert->is($no_ai->evaluate_action_channel(%gate, ai_available => 0)->{reason},
        'ai_unavailable',
        'mb709-1001: Stage Cue fails closed without a provider');
};
