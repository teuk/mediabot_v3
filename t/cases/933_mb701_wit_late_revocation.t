# t/cases/933_mb701_wit_late_revocation.t
# =============================================================================
# MB701-C2C — deterministic late revocation of an already-submitted Wit reply.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationDryRun ();
use Mediabot::AI::ConversationEmission qw(
    evaluate_emission
    emission_summary
    format_emission_dryrun_log
);
use Mediabot::AI::ConversationRuntimeState ();

{
    package MB701C2C::DelayedExecutor;

    sub new {
        return bless {
            calls   => 0,
            pending => undef,
        }, shift;
    }

    sub submit_dryrun {
        my ($self, %args) = @_;
        die "duplicate delayed submission\n" if $self->{pending};
        $self->{calls}++;
        $self->{pending} = $args{on_done};
        return 1;
    }

    sub complete_reply {
        my ($self, %args) = @_;
        my $cb = delete $self->{pending}
            or die "no delayed submission pending\n";

        $cb->({
            ok                => 1,
            action            => 'reply',
            reason            => 'model_reply',
            provider          => $args{provider} // 'anthropic',
            model             => $args{model} // 'claude-test',
            provider_fallback => 0,
            model_fallback    => 0,
            text              => $args{text} // 'Une réponse différée.',
        });
        return 1;
    }

    sub has_pending {
        my ($self) = @_;
        return $self->{pending} ? 1 : 0;
    }
}

sub _new_live_state {
    my ($channel) = @_;
    my $state = Mediabot::AI::ConversationRuntimeState->new();
    $state->mark_connected();
    my $generation = $state->mark_joined($channel);
    return ($state, $generation);
}

sub _start_delayed_wit {
    my (%args) = @_;

    my $executor = $args{executor};
    my $state = $args{state};
    my $enabled_ref = $args{enabled_ref};
    my $channel = $args{channel};
    my $clock_value = $args{clock_value};

    my $dryrun = Mediabot::AI::ConversationDryRun->new(
        executor => $executor,
        clock    => sub { $clock_value },
    );

    my ($captured_generation, $emission, $ai_result);
    my $started = $dryrun->handle_public_line(
        enabled      => 1,
        channel      => $channel,
        nick         => 'Alice',
        bot_nick     => 'mediabotv3',
        message      => 'Une phrase qui déclenche une réponse différée.',
        language     => 'fr',
        command_char => '!',
        on_observation => sub {
            my ($summary) = @_;
            if (ref($summary) eq 'HASH'
                && ($summary->{action} // '') eq 'consider') {
                $captured_generation = $state->capture_generation($channel);
            }
        },
        on_candidate => sub {
            my ($candidate) = @_;
            my $runtime = $state->snapshot($channel);
            my $decision = evaluate_emission(
                enabled            => $$enabled_ref,
                runtime_active     => $runtime->{runtime_active},
                irc_connected      => $runtime->{irc_connected},
                channel_joined     => $runtime->{channel_joined},
                request_generation => $captured_generation,
                current_generation => $runtime->{current_generation},
                channel            => $channel,
                text               => $candidate->{text},
            );
            $emission = emission_summary($decision);
        },
        on_result => sub {
            $ai_result = shift;
        },
    );

    return {
        dryrun              => $dryrun,
        started             => $started,
        captured_generation => \$captured_generation,
        emission            => \$emission,
        ai_result           => \$ai_result,
    };
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # Scenario 1: +Wit is enabled when the request is submitted, but the
    # administrator disables it before the provider callback arrives.
    # ------------------------------------------------------------------
    my $channel = '#test';
    my ($state1, $generation1) = _new_live_state($channel);
    my $enabled1 = 1;
    my $executor1 = MB701C2C::DelayedExecutor->new();
    my $run1 = _start_delayed_wit(
        executor    => $executor1,
        state       => $state1,
        enabled_ref => \$enabled1,
        channel     => $channel,
        clock_value => 10_000,
    );

    $assert->is($run1->{started}, 1,
        'mb701-933: request starts while +Wit and live membership are valid');
    $assert->is($executor1->{calls}, 1,
        'mb701-933: exactly one delayed provider request is submitted');
    $assert->ok($executor1->has_pending,
        'mb701-933: provider callback remains pending for deterministic revocation');
    $assert->is(${ $run1->{captured_generation} }, $generation1,
        'mb701-933: submit captures the exact live channel generation');
    $assert->ok(!defined(${ $run1->{emission} }),
        'mb701-933: no final emission decision exists before provider completion');

    $enabled1 = 0;
    $executor1->complete_reply(text => 'Cette réponse arrive après le opt-out.');

    my $emit1 = ${ $run1->{emission} };
    my $ai1 = ${ $run1->{ai_result} };
    $assert->is($emit1->{action}, 'no_emit',
        'mb701-933: late +Wit opt-out suppresses an already-generated candidate');
    $assert->is($emit1->{reason}, 'disabled',
        'mb701-933: late opt-out wins with explicit disabled reason');
    $assert->ok(!exists($emit1->{text}),
        'mb701-933: emission summary never retains the revoked candidate text');
    $assert->is($ai1->{action}, 'reply',
        'mb701-933: provider result can still be a valid model reply');
    $assert->is($ai1->{reason}, 'model_reply',
        'mb701-933: AI result remains independently observable as metadata');
    $assert->ok(!exists($ai1->{text}),
        'mb701-933: ordinary AI result summary still contains no reply text');

    my $log1 = format_emission_dryrun_log($channel, $emit1);
    $assert->like($log1, qr/action=no_emit reason=disabled/,
        'mb701-933: dry-run log records the late opt-out decision');
    $assert->unlike($log1, qr/opt-out|réponse|Cette/i,
        'mb701-933: revoked candidate text is absent from dry-run log');

    # ------------------------------------------------------------------
    # Scenario 2: the bot leaves and rejoins while the provider request is
    # pending. It is joined again at callback time, but under a NEW generation.
    # This must be stale_generation, never authorized.
    # ------------------------------------------------------------------
    my ($state2, $generation2) = _new_live_state($channel);
    my $enabled2 = 1;
    my $executor2 = MB701C2C::DelayedExecutor->new();
    my $run2 = _start_delayed_wit(
        executor    => $executor2,
        state       => $state2,
        enabled_ref => \$enabled2,
        channel     => $channel,
        clock_value => 20_000,
    );

    $assert->is(${ $run2->{captured_generation} }, $generation2,
        'mb701-933: second request captures its original generation');

    my $left_generation = $state2->mark_left($channel);
    my $rejoined_generation = $state2->mark_joined($channel);
    my $snapshot2 = $state2->snapshot($channel);

    $assert->ok($left_generation > $generation2,
        'mb701-933: PART invalidates the outstanding generation');
    $assert->ok($rejoined_generation > $left_generation,
        'mb701-933: re-JOIN creates a newer generation');
    $assert->is($snapshot2->{channel_joined}, 1,
        'mb701-933: bot can be joined again before stale callback returns');
    $assert->is($snapshot2->{current_generation}, $rejoined_generation,
        'mb701-933: callback sees the new post-rejoin generation');

    $executor2->complete_reply(text => 'Ancienne réponse après un nouveau JOIN.');

    my $emit2 = ${ $run2->{emission} };
    my $ai2 = ${ $run2->{ai_result} };
    $assert->is($emit2->{action}, 'no_emit',
        'mb701-933: stale pre-PART candidate cannot emit after re-JOIN');
    $assert->is($emit2->{reason}, 'stale_generation',
        'mb701-933: generation mismatch is the explicit rejection reason');
    $assert->ok(!exists($emit2->{request_generation}),
        'mb701-933: stale rejection summary does not expose generation metadata');
    $assert->ok(!exists($emit2->{text}),
        'mb701-933: stale candidate text is absent from emission summary');
    $assert->is($ai2->{reason}, 'model_reply',
        'mb701-933: stale authorization does not rewrite provider decision metadata');

    my $log2 = format_emission_dryrun_log($channel, $emit2);
    $assert->like($log2, qr/action=no_emit reason=stale_generation/,
        'mb701-933: stale-generation rejection is visible in dry-run metadata');
    $assert->unlike($log2, qr/Ancienne|réponse|JOIN/i,
        'mb701-933: stale candidate text never appears in dry-run log');

    # ------------------------------------------------------------------
    # Priority rule: if both opt-out and generation invalidation happen while
    # the same request is pending, administrative opt-out wins first.
    # ------------------------------------------------------------------
    my ($state3) = _new_live_state($channel);
    my $enabled3 = 1;
    my $executor3 = MB701C2C::DelayedExecutor->new();
    my $run3 = _start_delayed_wit(
        executor    => $executor3,
        state       => $state3,
        enabled_ref => \$enabled3,
        channel     => $channel,
        clock_value => 30_000,
    );

    $enabled3 = 0;
    $state3->mark_left($channel);
    $state3->mark_joined($channel);
    $executor3->complete_reply(text => 'Double révocation.');

    my $emit3 = ${ $run3->{emission} };
    $assert->is($emit3->{reason}, 'disabled',
        'mb701-933: explicit late opt-out takes precedence over stale generation');

    # Source-level regression: the production callback must re-read +Wit and
    # runtime state from inside on_candidate, not reuse submit-time booleans.
    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };
    my ($candidate_block) = $main =~ /(on_candidate\s*=>\s*sub\s*\{.*?\n\s*\},\n\s*on_result)/s;
    $assert->ok(defined($candidate_block),
        'mb701-933: production late candidate callback remains identifiable');
    $assert->like($candidate_block // '', qr/chanset_enabled\s*\(/,
        'mb701-933: production callback re-reads +Wit at completion time');
    $assert->like($candidate_block // '', qr/wit_runtime_state\}->snapshot\(\$where\)/,
        'mb701-933: production callback re-reads runtime membership/generation');
    $assert->like($candidate_block // '', qr/request_generation\s*=>\s*\$wit_request_generation/,
        'mb701-933: production callback compares against submit generation');
    $assert->unlike($candidate_block // '', qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-933: late revocation callback still cannot deliver IRC output');
};
