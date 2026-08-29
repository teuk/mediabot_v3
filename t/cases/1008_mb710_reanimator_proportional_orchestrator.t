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

sub _revival_gate {
    return (
        enabled => 1, channel => '#room', runtime_active => 1,
        irc_connected => 1, channel_joined => 1,
        game_active => 0, wit_pending => 0, ai_available => 1,
        vdm_enabled => 1,
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

    my $solo_now = 10_000;
    my $solo = _runtime(sub { $solo_now });
    for my $line ('le café attend', 'le serveur réfléchit', 'toujours ici') {
        _observe($solo, 'Alice', $line);
        $solo_now++;
    }
    $solo_now += 1_199;
    my $solo_wait = $solo->evaluate_channel(_revival_gate());
    $assert->is($solo_wait->{reason}, 'not_quiet',
        'mb710-1008: solo audience does not inherit social revival pacing');
    $assert->is($solo_wait->{retry_after_seconds}, 1_200,
        'mb710-1008: solo audience waits the second half of its quiet period');

    $solo_now += 1_200;
    my $solo_candidate = $solo->evaluate_channel(_revival_gate());
    $assert->is($solo_candidate->{action}, 'dryrun_candidate',
        'mb710-1008: one human may receive a rare contextual revival');
    $assert->is($solo_candidate->{audience_regime}, 'solo',
        'mb710-1008: revival candidate carries its audience regime');
    $assert->is($solo_candidate->{kind}, 'reaction',
        'mb710-1008: solo revival avoids a forced group interaction');
    $assert->is($solo_candidate->{policy_silence_seconds}, 2_400,
        'mb710-1008: candidate exposes the applied solo silence policy');

    my $small_now = 20_000;
    my $small = _runtime(sub { $small_now });
    for my $row (
        [Alice => 'première ligne'], [Bob => 'deuxième ligne'],
        [Alice => 'troisième ligne'], [Bob => 'quatrième ligne'],
    ) {
        _observe($small, @$row);
        $small_now++;
    }
    $small_now += 44;
    my $small_candidate = $small->evaluate_action_channel(_action_gate());
    $assert->is($small_candidate->{action}, 'action_candidate',
        'mb710-1008: a genuine two-person exchange can build momentum');
    $assert->is($small_candidate->{audience_regime}, 'small',
        'mb710-1008: momentum candidate identifies the small regime');
    $assert->is($small_candidate->{policy_cooldown_seconds}, 1_800,
        'mb710-1008: small audience receives the longer shared budget');
    $assert->is($small->action_cooldown_seconds('#room'), 1_800,
        'mb710-1008: State delivery override sees the same small budget');
    my $small_paced = $small->mark_action_delivered('#room');
    $assert->is($small_paced->{cooldown_seconds}, 1_800,
        'mb710-1008: delivered small action installs adaptive pacing');
    my $cross_lane = $small->evaluate_channel(_revival_gate());
    $assert->is($cross_lane->{reason}, 'shared_budget',
        'mb710-1008: momentum delivery also blocks the revival lane');
    $assert->is($cross_lane->{retry_after_seconds}, 1_800,
        'mb710-1008: both lanes observe the same remaining budget');

    my $crowded_now = 30_000;
    my $crowded = _runtime(sub { $crowded_now });
    my @people = qw(Alice Bob Carol Dave Erin Frank);
    for my $round (1 .. 2) {
        for my $nick (@people) {
            _observe($crowded, $nick, "ligne $round");
            $crowded_now++;
        }
    }
    $crowded_now += 29;
    my $crowded_candidate = $crowded->evaluate_action_channel(_action_gate());
    $assert->is($crowded_candidate->{action}, 'action_candidate',
        'mb710-1008: a crowded channel recognizes a shorter breathing pause');
    $assert->is($crowded_candidate->{audience_regime}, 'crowded',
        'mb710-1008: busy momentum carries the crowded regime');
    $assert->is($crowded_candidate->{policy_min_pause_seconds}, 30,
        'mb710-1008: crowded action uses the proportional short pause');
    $assert->is($crowded_candidate->{policy_cooldown_seconds}, 804,
        'mb710-1008: crowded audience receives budget sooner than a small one');
    $assert->is($crowded->action_cooldown_seconds('#room'), 804,
        'mb710-1008: State delivery override sees the crowded budget');
    my $crowded_paced = $crowded->mark_action_delivered('#room');
    $assert->is($crowded_paced->{cooldown_seconds}, 804,
        'mb710-1008: crowded delivery installs its adaptive shared cooldown');

    my $log = Mediabot::Spark::Orchestrator::format_action_candidate_log(
        '#room', $crowded_candidate,
    );
    $assert->like($log, qr/audience_regime=crowded/,
        'mb710-1008: metadata log exposes the applied regime');
    $assert->like($log, qr/policy_cooldown_seconds=804/,
        'mb710-1008: metadata log exposes the applied pacing decision');
    $assert->unlike($log, qr/Alice|Bob|Carol|ligne/i,
        'mb710-1008: proportional diagnostics expose no content or identity');
};
