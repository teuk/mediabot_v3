# t/cases/932_mb701_wit_late_emission_dryrun.t
# =============================================================================
# MB701-C — private candidate handoff + late emission authorization dry-run.
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
use Mediabot::AI::ConversationEmission qw(
    evaluate_emission
    emission_summary
    format_emission_dryrun_log
);

{
    package MB701C::Executor;

    sub new {
        my ($class, %args) = @_;
        return bless { result => $args{result}, calls => 0 }, $class;
    }

    sub submit_dryrun {
        my ($self, %args) = @_;
        $self->{calls}++;
        $args{on_done}->($self->{result});
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    my $secret_text = 'Réponse privée qui ne doit jamais apparaître dans un log.';
    my $executor = MB701C::Executor->new(
        result => {
            ok => 1,
            action => 'reply',
            reason => 'model_reply',
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 0,
            text => $secret_text,
        },
    );

    my $dryrun = Mediabot::AI::ConversationDryRun->new(
        executor => $executor,
        clock => sub { 3_000 },
    );

    my ($candidate, $result);
    my $started = $dryrun->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Alice',
        bot_nick => 'mediabotv3',
        message => 'Une phrase éligible.',
        language => 'fr',
        command_char => '!',
        on_candidate => sub { $candidate = shift },
        on_result => sub { $result = shift },
    );

    $assert->is($started, 1,
        'mb701-932: eligible line starts provider dry-run');
    $assert->is($executor->{calls}, 1,
        'mb701-932: exactly one provider submission occurs');
    $assert->is($candidate->{text}, $secret_text,
        'mb701-932: private candidate callback receives normalized reply text');
    $assert->is($candidate->{reason}, 'model_reply',
        'mb701-932: candidate keeps normalized model decision metadata');
    $assert->ok(!exists($result->{text}),
        'mb701-932: public AI result summary still discards generated text');
    $assert->is($result->{reply_chars}, length($secret_text),
        'mb701-932: public AI summary retains reply length only');

    my $late = evaluate_emission(
        enabled => 1,
        runtime_active => 1,
        irc_connected => 1,
        channel_joined => 1,
        request_generation => 17,
        current_generation => 17,
        channel => '#test',
        text => $candidate->{text},
    );
    my $late_summary = emission_summary($late);
    $assert->is($late_summary->{action}, 'emit',
        'mb701-932: unchanged late state authorizes candidate');
    $assert->is($late_summary->{reason}, 'authorized',
        'mb701-932: late gate exposes authorized reason');
    $assert->ok(!exists($late_summary->{text}),
        'mb701-932: emission summary never exposes candidate text');

    my $emit_log = format_emission_dryrun_log('#test', $late_summary);
    $assert->like($emit_log,
        qr/^\[WIT_EMIT_DRYRUN\] channel=#test action=emit reason=authorized /,
        'mb701-932: final dry-run log has explicit emission marker');
    $assert->unlike($emit_log, qr/Réponse privée|Alice|phrase éligible/,
        'mb701-932: final dry-run log contains no generated/user text or nick');
    $assert->like($emit_log, qr/reply_chars=\d+ reply_bytes=\d+ request_generation=17$/,
        'mb701-932: final dry-run log exposes bounded size/generation metadata');

    my $disabled = evaluate_emission(
        enabled => 0,
        runtime_active => 1,
        irc_connected => 1,
        channel_joined => 1,
        request_generation => 17,
        current_generation => 17,
        channel => '#test',
        text => $candidate->{text},
    );
    my $disabled_log = format_emission_dryrun_log('#test', emission_summary($disabled));
    $assert->like($disabled_log, qr/action=no_emit reason=disabled$/,
        'mb701-932: late +Wit opt-out wins and leaks no candidate metadata');
    $assert->unlike($disabled_log, qr/Réponse privée/,
        'mb701-932: disabled log cannot expose reply text');

    my $stale = evaluate_emission(
        enabled => 1,
        runtime_active => 1,
        irc_connected => 1,
        channel_joined => 1,
        request_generation => 17,
        current_generation => 18,
        channel => '#test',
        text => $candidate->{text},
    );
    $assert->is($stale->{reason}, 'stale_generation',
        'mb701-932: generation change rejects stale callback');

    my $no_reply_executor = MB701C::Executor->new(
        result => {
            ok => 1,
            action => 'no_reply',
            reason => 'model_no_reply',
            provider => 'openai',
            model => 'gpt-test',
            provider_fallback => 0,
            model_fallback => 0,
        },
    );
    my $dryrun2 = Mediabot::AI::ConversationDryRun->new(
        executor => $no_reply_executor,
        clock => sub { 4_000 },
    );
    my $candidate_calls = 0;
    my $no_reply_result;
    $dryrun2->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Bob',
        bot_nick => 'mediabotv3',
        message => 'No reply candidate expected.',
        language => 'en',
        command_char => '!',
        on_candidate => sub { $candidate_calls++ },
        on_result => sub { $no_reply_result = shift },
    );
    $assert->is($candidate_calls, 0,
        'mb701-932: model NO_REPLY never crosses candidate boundary');
    $assert->is($no_reply_result->{reason}, 'model_no_reply',
        'mb701-932: NO_REPLY still reaches ordinary metadata callback');

    my $failing_executor = MB701C::Executor->new(
        result => {
            ok => 1,
            action => 'reply',
            reason => 'model_reply',
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 0,
            text => 'candidate',
        },
    );
    my $dryrun3 = Mediabot::AI::ConversationDryRun->new(
        executor => $failing_executor,
        clock => sub { 5_000 },
    );
    my $guard_failure;
    my $guard_started = $dryrun3->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Carol',
        bot_nick => 'mediabotv3',
        message => 'Trigger a failing final guard callback.',
        language => 'en',
        command_char => '!',
        on_candidate => sub { die "late guard exploded\n" },
        on_result => sub { $guard_failure = shift },
    );
    $assert->is($guard_started, 1,
        'mb701-932: provider submission itself still started');
    $assert->is($guard_failure->{action}, 'no_reply',
        'mb701-932: candidate callback exception fails closed');
    $assert->is($guard_failure->{reason}, 'runtime_guard_error',
        'mb701-932: candidate callback exception is machine-visible');
    $assert->is($guard_failure->{error}, 'candidate_callback_exception',
        'mb701-932: candidate callback exception is bounded metadata');
    $assert->ok(!exists($guard_failure->{text}),
        'mb701-932: guard failure cannot leak candidate text');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };
    $assert->like($main, qr/use Mediabot::AI::ConversationEmission \(\);/,
        'mb701-932: runtime imports final emission contract');
    $assert->like($main, qr/capture_generation\(\$where\)/,
        'mb701-932: runtime captures channel generation before async result');
    $assert->like($main, qr/on_candidate\s*=>\s*sub/,
        'mb701-932: runtime has private candidate callback');
    $assert->like($main, qr/ConversationEmission::evaluate_emission\s*\(/,
        'mb701-932: callback passes candidate through final gate');
    $assert->like($main, qr/ConversationEmission::format_emission_dryrun_log\s*\(/,
        'mb701-932: final gate is logged as dry-run metadata');

    my ($wit_block) = $main =~ /(\# mb700-G: \+Wit.*?)(?=\n\s*my \(\$sCommand,\@tArgs\))/s;
    $assert->ok(defined($wit_block),
        'mb701-932: Wit runtime block remains identifiable');
    $assert->unlike($wit_block // '', qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,
        'mb701-932: Wit block still contains no IRC delivery primitive');

    my $dryrun_module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDryRun.pm"
            or die "open ConversationDryRun.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($dryrun_module, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice)\b/,
        'mb701-932: candidate transport still owns neither DB/chanset nor IRC emission');

    my $emission_module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationEmission.pm"
            or die "open ConversationEmission.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($emission_module, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice)\b/,
        'mb701-932: final gate remains pure after dry-run formatter addition');
}
