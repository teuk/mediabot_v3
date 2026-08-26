# t/cases/929_mb700_wit_async_runtime_dryrun.t
# =============================================================================
# MB700-G — async runtime dry-run orchestration for +Wit.
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

{
    package MB700G::Executor;

    sub new {
        my ($class, %args) = @_;
        return bless {
            calls    => [],
            result   => $args{result},
            deferred => $args{deferred} ? 1 : 0,
            pending  => undef,
        }, $class;
    }

    sub submit_dryrun {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, { %args };

        if ($self->{deferred}) {
            $self->{pending} = $args{on_done};
            return 1;
        }

        $args{on_done}->($self->{result});
        return 1;
    }

    sub complete {
        my ($self, $result) = @_;
        my $cb = delete $self->{pending};
        $cb->($result) if $cb;
    }
}

return sub {
    my ($assert) = @_;

    my $clock = 1_000;
    my $executor = MB700G::Executor->new(
        result => {
            ok => 1,
            action => 'reply',
            reason => 'model_reply',
            provider => 'anthropic',
            model => 'claude-test',
            provider_fallback => 0,
            model_fallback => 0,
            text => 'Secret generated reply must not reach runtime log',
        },
    );

    my $runtime = Mediabot::AI::ConversationDryRun->new(
        executor => $executor,
        clock    => sub { $clock },
    );

    my ($observation, $result);
    my $started = $runtime->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Alice',
        bot_nick => 'mediabotv3',
        message => 'Une remarque amusante sur les hiboux.',
        language => 'fr',
        command_char => '!',
        initial_trigger_enabled => 1,
        on_observation => sub { $observation = shift },
        on_result => sub { $result = shift },
    );

    $assert->is($started, 1,
        'mb700-929: eligible line starts one asynchronous dry-run');
    $assert->is($observation->{action}, 'consider',
        'mb700-929: mechanical policy must consider eligible line first');
    $assert->is(scalar(@{ $executor->{calls} }), 1,
        'mb700-929: exactly one executor submission is made');
    $assert->is($executor->{calls}[0]{provider}, 'auto',
        'mb700-929: provider-neutral auto policy reaches executor');
    $assert->is($executor->{calls}[0]{language}, 'fr',
        'mb700-929: channel language reaches executor');
    $assert->is($executor->{calls}[0]{message}, 'Une remarque amusante sur les hiboux.',
        'mb700-929: only the eligible message reaches the request boundary');

    $assert->is($result->{action}, 'reply',
        'mb700-929: executor decision reaches runtime summary');
    $assert->ok(!exists($result->{text}),
        'mb700-929: generated reply text is discarded before runtime callback');
    $assert->is($result->{reply_chars}, length('Secret generated reply must not reach runtime log'),
        'mb700-929: callback keeps reply size only');

    my $log = format_ai_dryrun_log('#test', $result);
    $assert->like($log, qr/^\[WIT_AI_DRYRUN\] channel=#test action=reply reason=model_reply /,
        'mb700-929: AI dry-run log is explicit and bounded');
    $assert->like($log, qr/provider=anthropic model=claude-test/,
        'mb700-929: log keeps provider/model metadata');
    $assert->like($log, qr/reply_chars=\d+$/,
        'mb700-929: log keeps reply length only');
    $assert->unlike($log, qr/Secret generated|Alice|hiboux/,
        'mb700-929: log contains neither generated text, nick nor message payload');

    $clock = 1_030;
    my $second_observation;
    my $second_result = 0;
    my $second_started = $runtime->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Bob',
        bot_nick => 'mediabotv3',
        message => 'Deuxième ligne trop tôt.',
        language => 'fr',
        command_char => '!',
        initial_trigger_enabled => 1,
        on_observation => sub { $second_observation = shift },
        on_result => sub { $second_result++ },
    );

    $assert->is($second_started, 0,
        'mb700-929: cooldown prevents a second provider submission');
    $assert->is($second_observation->{reason}, 'cooldown',
        'mb700-929: cooldown remains machine-visible');
    $assert->is(scalar(@{ $executor->{calls} }), 1,
        'mb700-929: cooldown spends no provider call');
    $assert->is($second_result, 0,
        'mb700-929: policy rejection has no AI result callback');

    my $deferred = MB700G::Executor->new(deferred => 1);
    my $runtime2 = Mediabot::AI::ConversationDryRun->new(
        executor => $deferred,
        clock    => sub { 2_000 },
    );
    my $first_result;
    my $first_started = $runtime2->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Alice',
        bot_nick => 'mediabotv3',
        message => 'First async line',
        language => 'en',
        command_char => '!',
        on_result => sub { $first_result = shift },
    );
    $assert->is($first_started, 1,
        'mb700-929: deferred executor starts normally');

    my $inflight_observation;
    my $inflight_started = $runtime2->handle_public_line(
        enabled => 1,
        channel => '#test',
        nick => 'Bob',
        bot_nick => 'mediabotv3',
        message => 'Second async line',
        language => 'en',
        command_char => '!',
        on_observation => sub { $inflight_observation = shift },
        on_result => sub { die 'must not receive AI result for inflight rejection' },
    );
    $assert->is($inflight_started, 0,
        'mb700-929: per-channel inflight guard rejects concurrent request');
    $assert->is($inflight_observation->{reason}, 'inflight',
        'mb700-929: inflight rejection is visible without provider call');
    $assert->is(scalar(@{ $deferred->{calls} }), 1,
        'mb700-929: inflight guard spends no second provider call');

    $deferred->complete({
        ok => 1,
        action => 'no_reply',
        reason => 'model_no_reply',
        provider => 'openai',
        model => 'gpt-test',
        provider_fallback => 0,
        model_fallback => 0,
    });
    $assert->is($first_result->{reason}, 'model_no_reply',
        'mb700-929: deferred completion is normalized safely');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };

    $assert->like($main, qr/use Mediabot::AI::ConversationDryRun \(\);/,
        'mb700-929: runtime imports the dedicated dry-run orchestrator');
    $assert->like($main, qr/handle_public_line\s*\(/,
        'mb700-929: public runtime delegates eligible observation/execution');
    $assert->like($main, qr/format_ai_dryrun_log\s*\(/,
        'mb700-929: runtime logs only sanitized AI summaries');

    my $module = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationDryRun.pm"
            or die "open ConversationDryRun.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($module, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|privmsg)\b/,
        'mb700-929: orchestrator owns neither DB/chanset nor IRC emission');
    $assert->unlike($module, qr/Provider::(?:Anthropic|OpenAI)/,
        'mb700-929: orchestrator has no provider-specific dependency');
}
