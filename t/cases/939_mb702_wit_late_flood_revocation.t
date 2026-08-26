# t/cases/939_mb702_wit_late_flood_revocation.t
# =============================================================================
# MB702-A3 — a provider reply is revoked if flood suppression becomes active
# while that request is in flight.
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

{
    package MB702A3::Executor;

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

    sub complete_next_reply {
        my ($self, $text) = @_;
        my $cb = shift @{ $self->{pending} } or die "no pending callback\n";
        $cb->({
            ok => 1,
            action => 'reply',
            reason => 'model_reply',
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 0,
            text => $text,
        });
    }
}

{
    package MB702A3::LateBrokenGuard;

    sub new {
        my ($class) = @_;
        return bless { observations => 0 }, $class;
    }

    sub observe_public_line {
        my ($self) = @_;
        $self->{observations}++;
        return { action => 'allow', reason => 'below_threshold' };
    }

    sub current_decision {
        die "late flood query exploded\n";
    }
}

return sub {
    my ($assert) = @_;

    my $flood_now = 1_000;
    my $policy_now = 10_000;
    my $executor = MB702A3::Executor->new();
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
    my @candidates;
    my @results;

    my $started = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#Phat',
        nick => 'Alice',
        bot_nick => 'ubot',
        message => 'Une requête démarre avant le flood.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_candidate => sub { push @candidates, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($started, 1,
        'mb702-939: eligible line starts exactly one provider request');
    $assert->is($executor->{calls}, 1,
        'mb702-939: provider request is in flight before flood suppression');

    $flood_now = 1_001;
    $dryrun->handle_public_line(
        enabled => 1,
        channel => '#PHAT',
        nick => 'Bob',
        bot_nick => 'ubot',
        message => 'Deuxième ligne.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_candidate => sub { push @candidates, shift },
        on_result => sub { push @results, shift },
    );

    $flood_now = 1_002;
    $dryrun->handle_public_line(
        enabled => 1,
        channel => '#phat',
        nick => 'Carol',
        bot_nick => 'ubot',
        message => 'Troisième ligne : le circuit saute.',
        language => 'fr',
        command_char => '!',
        on_observation => sub { push @observations, shift },
        on_candidate => sub { push @candidates, shift },
        on_result => sub { push @results, shift },
    );

    $assert->is($observations[-1]{reason}, 'flood_suppression',
        'mb702-939: flood suppression becomes active while provider request is pending');
    $assert->is($executor->{calls}, 1,
        'mb702-939: flood-triggering traffic creates zero extra provider requests');

    $executor->complete_next_reply('Cette réponse ne doit jamais atteindre IRC.');

    $assert->is(scalar(@candidates), 0,
        'mb702-939: in-flight provider reply is revoked before candidate callback');
    $assert->is(scalar(@results), 1,
        'mb702-939: revoked provider reply still produces one bounded result summary');
    $assert->is($results[0]{action}, 'no_reply',
        'mb702-939: late flood revocation converts reply to no_reply');
    $assert->is($results[0]{reason}, 'flood_suppression',
        'mb702-939: late flood revocation uses the stable flood_suppression reason');
    $assert->is($results[0]{provider}, 'anthropic',
        'mb702-939: late revocation preserves safe provider metadata');
    $assert->is($results[0]{model}, 'claude-test',
        'mb702-939: late revocation preserves safe model metadata');
    $assert->ok(!exists($results[0]{reply_chars}),
        'mb702-939: revoked reply summary cannot expose reply length');
    $assert->ok(!exists($results[0]{text}),
        'mb702-939: revoked reply text never reaches result metadata');

    my $late_log = format_ai_dryrun_log('#Phat', $results[0]);
    $assert->like($late_log,
        qr/^\[WIT_AI_DRYRUN\] channel=#Phat action=no_reply reason=flood_suppression provider=anthropic model=claude-test provider_fallback=0 model_fallback=0$/,
        'mb702-939: late revocation is visible as metadata-only WIT_AI_DRYRUN');
    $assert->unlike($late_log, qr/Cette réponse|jamais atteindre IRC/,
        'mb702-939: generated text cannot leak into late flood logs');

    # A different channel remains independent and can still deliver a candidate.
    $flood_now = 1_003;
    my @quiet_candidates;
    my @quiet_results;
    my $quiet_started = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#quiet',
        nick => 'Dave',
        bot_nick => 'ubot',
        message => 'Le canal calme reste normal.',
        language => 'fr',
        command_char => '!',
        on_observation => sub {},
        on_candidate => sub { push @quiet_candidates, shift },
        on_result => sub { push @quiet_results, shift },
    );

    $assert->is($quiet_started, 1,
        'mb702-939: flood suppression remains isolated from another channel');
    $assert->is($executor->{calls}, 2,
        'mb702-939: quiet channel may still make one provider request');

    $executor->complete_next_reply('Réponse autorisée sur le canal calme.');

    $assert->is(scalar(@quiet_candidates), 1,
        'mb702-939: quiet-channel reply still crosses candidate boundary');
    $assert->is($quiet_candidates[0]{text}, 'Réponse autorisée sur le canal calme.',
        'mb702-939: quiet-channel candidate text remains intact');
    $assert->is($quiet_results[0]{action}, 'reply',
        'mb702-939: quiet-channel result remains a normal reply summary');

    # Late guard failures are fail-closed: no candidate can escape.
    my $broken_exec = MB702A3::Executor->new();
    my $broken = Mediabot::AI::ConversationDryRun->new(
        executor => $broken_exec,
        flood_guard => MB702A3::LateBrokenGuard->new(),
        clock => sub { 20_000 },
    );

    my @broken_candidates;
    my @broken_results;
    my $broken_started = $broken->handle_public_line(
        enabled => 1,
        channel => '#broken',
        nick => 'Mallory',
        bot_nick => 'ubot',
        message => 'La requête démarre puis le guard casse.',
        language => 'fr',
        command_char => '!',
        on_observation => sub {},
        on_candidate => sub { push @broken_candidates, shift },
        on_result => sub { push @broken_results, shift },
    );

    $assert->is($broken_started, 1,
        'mb702-939: broken-late fixture starts one provider request');
    $assert->is($broken_exec->{calls}, 1,
        'mb702-939: broken-late fixture submits exactly once');

    $broken_exec->complete_next_reply('Cette réponse doit être bloquée aussi.');

    $assert->is(scalar(@broken_candidates), 0,
        'mb702-939: late flood-guard exception cannot reach candidate callback');
    $assert->is($broken_results[0]{action}, 'no_reply',
        'mb702-939: late flood-guard exception fails closed');
    $assert->is($broken_results[0]{reason}, 'flood_guard_error',
        'mb702-939: late flood-guard exception exposes bounded failure reason');
    $assert->is($broken_results[0]{error}, 'late_flood_guard_invalid',
        'mb702-939: late flood-guard failure exposes bounded error metadata');
    $assert->ok(!exists($broken_results[0]{text}),
        'mb702-939: late guard failure cannot expose generated text');

    my $module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDryRun.pm"
            or die "open ConversationDryRun.pm: $!";
        local $/;
        <$fh>;
    };

    my $late_guard_pos = index(
        $module,
        q{$self->{flood_guard}->current_decision(channel => $channel)}
    );
    my $candidate_pos = index($module, q{$on_candidate->($result)});

    $assert->ok($late_guard_pos >= 0,
        'mb702-939: late flood-state query exists in ConversationDryRun');
    $assert->ok($candidate_pos > $late_guard_pos,
        'mb702-939: late flood-state query runs before candidate callback');

    $assert->unlike($module,
        qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice)\b/,
        'mb702-939: late flood revocation adds no DB or IRC dependency');
}
