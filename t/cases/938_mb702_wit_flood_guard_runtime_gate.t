# t/cases/938_mb702_wit_flood_guard_runtime_gate.t
# =============================================================================
# MB702-A2 — flood suppression is evaluated before inflight/policy/provider work.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationDryRun qw(format_ai_dryrun_log);
use Mediabot::AI::ConversationFloodGuard ();
use Mediabot::AI::ConversationObserver qw(format_dryrun_log);

{
    package MB702A2::Executor;

    sub new {
        my ($class) = @_;
        return bless { calls => 0, pending => [] }, $class;
    }

    sub submit_dryrun {
        my ($self, %args) = @_;
        $self->{calls}++;
        push @{ $self->{pending} }, $args{on_done};
        return 1;
    }

    sub complete_next_no_reply {
        my ($self) = @_;
        my $cb = shift @{ $self->{pending} } or die "no pending callback\n";
        $cb->({
            ok => 1,
            action => 'no_reply',
            reason => 'model_no_reply',
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 0,
        });
    }
}

{
    package MB702A2::BrokenGuard;
    sub new { bless {}, shift }
    sub observe_public_line { die "guard exploded\n" }
    sub current_decision { return { action => 'allow', reason => 'below_threshold' } }
}

return sub {
    my ($assert) = @_;

    my $flood_now = 1_000;
    my $policy_now = 10_000;
    my $executor = MB702A2::Executor->new();
    my $guard = Mediabot::AI::ConversationFloodGuard->new(
        clock => sub { $flood_now },
        threshold_lines => 3,
        suppression_seconds => 180,
    );

    my $dryrun = Mediabot::AI::ConversationDryRun->new(
        executor => $executor,
        flood_guard => $guard,
        clock => sub { $policy_now },
    );

    my @observations;
    my @results;

    my $started1 = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#Phat',
        nick => 'Alice',
        bot_nick => 'ubot',
        message => 'Une phrase normalement éligible.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started1, 1,
        'mb702-938: first below-threshold line may start one provider request');
    $assert->is($executor->{calls}, 1,
        'mb702-938: first eligible line submits exactly once');

    $flood_now = 1_001;
    my $started2 = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#PHAT',
        nick => 'Bob',
        bot_nick => 'ubot',
        message => 'Deuxième ligne pendant la requête.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started2, 0,
        'mb702-938: second line is still blocked by inflight after flood accounting');
    $assert->is($observations[-1]{reason}, 'inflight',
        'mb702-938: below-threshold inflight behavior remains unchanged');
    $assert->is($executor->{calls}, 1,
        'mb702-938: inflight line cannot create another provider request');

    $flood_now = 1_002;
    my $started3 = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#phat',
        nick => 'Carol',
        bot_nick => 'ubot',
        message => 'Troisième ligne qui déclenche la protection.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started3, 0,
        'mb702-938: threshold line is suppressed synchronously');
    $assert->is($observations[-1]{action}, 'no_reply',
        'mb702-938: flood suppression maps to ordinary no_reply observation');
    $assert->is($observations[-1]{reason}, 'flood_suppression',
        'mb702-938: runtime exposes stable flood_suppression reason');
    $assert->is($observations[-1]{retry_after_seconds}, 180,
        'mb702-938: suppression observation exposes bounded retry metadata');
    $assert->is($executor->{calls}, 1,
        'mb702-938: flood-triggering line performs zero additional provider submissions');

    my $flood_log = format_dryrun_log('#Phat', $observations[-1]);
    $assert->like($flood_log,
        qr/^\[WIT_DRYRUN\] channel=#Phat action=no_reply reason=flood_suppression language=fr provider=auto retry_after=180$/,
        'mb702-938: existing WIT_DRYRUN formatter logs flood suppression metadata');
    $assert->unlike($flood_log, qr/Carol|Troisième|déclenche/,
        'mb702-938: flood log contains no nick or public-message text');

    $flood_now = 1_003;
    my $started4 = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#phat',
        nick => 'Dave',
        bot_nick => 'ubot',
        message => 'Ligne pendant suppression.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started4, 0,
        'mb702-938: active suppression blocks subsequent public lines');
    $assert->is($observations[-1]{reason}, 'flood_suppression',
        'mb702-938: active suppression wins over existing inflight state');
    $assert->is($observations[-1]{retry_after_seconds}, 179,
        'mb702-938: suppression countdown decreases without extension');
    $assert->is($executor->{calls}, 1,
        'mb702-938: suppressed traffic still causes zero provider submissions');

    $executor->complete_next_no_reply();
    $assert->is(scalar(@results), 1,
        'mb702-938: already-submitted request may finish normally');
    $assert->is($results[0]{reason}, 'model_no_reply',
        'mb702-938: flood gate does not corrupt an existing executor callback');

    $flood_now = 1_182;
    $policy_now = 10_200;
    my $started5 = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#Phat',
        nick => 'Erin',
        bot_nick => 'ubot',
        message => 'Le calme est revenu.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started5, 1,
        'mb702-938: provider submission recovers automatically after suppression expiry');
    $assert->is($executor->{calls}, 2,
        'mb702-938: recovery permits exactly one new provider submission');
    $executor->complete_next_no_reply();

    my $other_guard = Mediabot::AI::ConversationFloodGuard->new(
        clock => sub { $flood_now },
        threshold_lines => 3,
        suppression_seconds => 180,
    );
    my $other_exec = MB702A2::Executor->new();
    my $other_dryrun = Mediabot::AI::ConversationDryRun->new(
        executor => $other_exec,
        flood_guard => $other_guard,
        clock => sub { $policy_now },
    );

    for my $n (1..3) {
        $flood_now = 2_000 + $n;
        $other_dryrun->handle_public_line(
            enabled => 1,
            channel => '#flooded',
            nick => "Flood$n",
            bot_nick => 'ubot',
            message => '!noop',
            language => 'en',
            command_char => '!',
            on_observation => sub {},
            on_result => sub {},
        );
    }

    $flood_now = 2_004;
    my $other_started = $other_dryrun->handle_public_line(
        enabled => 1,
        channel => '#quiet',
        nick => 'Quiet',
        bot_nick => 'ubot',
        message => 'Quiet channel remains eligible.',
        language => 'en',
        command_char => '!',
        on_observation => sub {},
        on_result => sub {},
    );
    $assert->is($other_started, 1,
        'mb702-938: suppression of one channel does not block provider work on another');
    $assert->is($other_exec->{calls}, 1,
        'mb702-938: per-channel isolation reaches the executor boundary');
    $other_exec->complete_next_no_reply();

    my $broken_exec = MB702A2::Executor->new();
    my $broken = Mediabot::AI::ConversationDryRun->new(
        executor => $broken_exec,
        flood_guard => MB702A2::BrokenGuard->new(),
        clock => sub { 30_000 },
    );
    my $broken_observation;
    my $broken_started = $broken->handle_public_line(
        enabled => 1,
        channel => '#broken',
        nick => 'Mallory',
        bot_nick => 'ubot',
        message => 'This must never reach a provider.',
        language => 'en',
        command_char => '!',
        on_observation => sub { $broken_observation = shift },
        on_result => sub {},
    );

    $assert->is($broken_started, 0,
        'mb702-938: flood-guard exception fails closed');
    $assert->is($broken_observation->{reason}, 'flood_guard_error',
        'mb702-938: flood-guard exception becomes bounded metadata');
    $assert->is($broken_exec->{calls}, 0,
        'mb702-938: broken guard still produces zero provider submissions');

    my $bad_constructor = eval {
        Mediabot::AI::ConversationDryRun->new(
            executor => MB702A2::Executor->new(),
            flood_guard => bless({}, 'MB702A2::NoGuardMethod'),
        );
        1;
    };
    $assert->ok(!$bad_constructor,
        'mb702-938: injected flood guard must provide the complete flood-guard interface');

    my $module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDryRun.pm"
            or die "open ConversationDryRun.pm: $!";
        local $/;
        <$fh>;
    };

    $assert->like($module, qr/use Mediabot::AI::ConversationFloodGuard \(\);/,
        'mb702-938: dry-run orchestrator owns the pure flood guard dependency');

    my $guard_pos = index($module, q{$self->{flood_guard}->observe_public_line});
    my $inflight_pos = index($module, q{$self->{inflight}{$channel_key}});
    my $policy_pos = index($module, q{my $observation = observe_public_line});
    my $submit_pos = index($module, q{$self->{executor}->submit_dryrun});

    $assert->ok($guard_pos >= 0,
        'mb702-938: flood guard invocation is present');
    $assert->ok($inflight_pos > $guard_pos,
        'mb702-938: flood guard runs before inflight rejection');
    $assert->ok($policy_pos > $guard_pos,
        'mb702-938: flood guard runs before conversation policy');
    $assert->ok($submit_pos > $guard_pos,
        'mb702-938: flood guard runs before provider submission');

    $assert->unlike($module,
        qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice)\b/,
        'mb702-938: runtime flood wiring adds no DB or IRC dependency');
}
