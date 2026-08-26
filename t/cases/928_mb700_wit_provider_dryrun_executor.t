# t/cases/928_mb700_wit_provider_dryrun_executor.t
# =============================================================================
# MB700-F — provider-neutral +Wit dry-run executor.
#
# This round wires ConversationRequest -> AI::Client -> ConversationDecision
# behind an injectable executor, but does not wire the executor into mediabot.pl
# and never emits IRC.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationExecutor qw(execution_summary);

{
    package MB700F::Client;

    sub new {
        my ($class, %args) = @_;
        return bless {
            execute_result => $args{execute_result},
            submit_result  => $args{submit_result},
            execute_calls  => [],
            submit_calls   => [],
            submit_started => exists($args{submit_started}) ? $args{submit_started} : 1,
        }, $class;
    }

    sub execute {
        my ($self, $request) = @_;
        push @{ $self->{execute_calls} }, $request;

        if (ref($self->{execute_result}) eq 'CODE') {
            return $self->{execute_result}->($request);
        }
        return $self->{execute_result};
    }

    sub submit {
        my ($self, $request, %opts) = @_;
        push @{ $self->{submit_calls} }, $request;
        $opts{on_done}->($self->{submit_result});
        return $self->{submit_started};
    }
}

return sub {
    my ($assert) = @_;

    my $missing = eval {
        Mediabot::AI::ConversationExecutor->new();
        1;
    };
    $assert->ok(!$missing,
        'mb700-928: executor requires conf unless a client is injected');
    $assert->like($@, qr/conf is required/,
        'mb700-928: missing runtime config failure is explicit');

    my $bad_client = eval {
        Mediabot::AI::ConversationExecutor->new(client => bless({}, 'MB700F::Bad'));
        1;
    };
    $assert->ok(!$bad_client,
        'mb700-928: injected client must implement execute and submit');

    my $no_reply_client = MB700F::Client->new(
        execute_result => {
            ok => 1,
            provider => 'anthropic',
            model => 'claude-test',
            answer => 'NO_REPLY',
            provider_fallback => 0,
            model_fallback => 0,
        },
    );
    my $executor = Mediabot::AI::ConversationExecutor->new(
        client => $no_reply_client,
    );

    my $no_reply = $executor->execute_dryrun(
        provider => 'Claude',
        language => 'fr',
        message => 'Salut à tous 👋',
    );
    $assert->is($no_reply->{ok}, 1,
        'mb700-928: successful provider execution is recorded');
    $assert->is($no_reply->{action}, 'no_reply',
        'mb700-928: explicit model abstention stays no_reply');
    $assert->is($no_reply->{reason}, 'model_no_reply',
        'mb700-928: explicit model abstention reason is preserved');
    $assert->is($no_reply->{provider}, 'anthropic',
        'mb700-928: provider metadata survives normalized execution');
    $assert->is($no_reply->{model}, 'claude-test',
        'mb700-928: model metadata survives normalized execution');
    $assert->ok(!exists($no_reply->{answer}),
        'mb700-928: raw model answer is not retained');

    $assert->is(scalar(@{ $no_reply_client->{execute_calls} }), 1,
        'mb700-928: dry-run performs exactly one client execute call');
    my $sent = $no_reply_client->{execute_calls}[0];
    $assert->is($sent->{provider}, 'anthropic',
        'mb700-928: request provider aliases normalize before client execution');
    $assert->is($sent->{purpose}, 'wit',
        'mb700-928: executor sends only dedicated Wit requests');
    $assert->is($sent->{messages}[0]{content}, 'Salut à tous 👋',
        'mb700-928: minimal channel message reaches AI::Client');
    $assert->like($sent->{system}, qr/NO_REPLY/,
        'mb700-928: strict decision contract reaches the client');

    my $reply_client = MB700F::Client->new(
        execute_result => {
            ok => 1,
            provider => 'openai',
            model => 'gpt-test',
            answer => "REPLY: \x02Petit clin d'œil magique ✨\x0f",
            provider_fallback => 1,
            model_fallback => 0,
        },
    );
    my $reply_executor = Mediabot::AI::ConversationExecutor->new(
        client => $reply_client,
    );
    my $reply = $reply_executor->execute_dryrun(
        provider => 'openai',
        language => 'fr',
        message => 'Une idée ?',
    );
    $assert->is($reply->{action}, 'reply',
        'mb700-928: valid REPLY output becomes a reply decision');
    $assert->is($reply->{reason}, 'model_reply',
        'mb700-928: reply reason is normalized');
    $assert->is($reply->{text}, "Petit clin d'œil magique ✨",
        'mb700-928: reply text is sanitized by ConversationDecision');
    $assert->is($reply->{provider_fallback}, 1,
        'mb700-928: provider fallback metadata is preserved');

    my $reply_summary = execution_summary($reply);
    $assert->is($reply_summary->{action}, 'reply',
        'mb700-928: dry-run summary carries reply action');
    $assert->is($reply_summary->{reply_chars}, length("Petit clin d'œil magique ✨"),
        'mb700-928: summary exposes reply size, not reply content');
    $assert->ok(!exists($reply_summary->{text}),
        'mb700-928: dry-run summary never exposes generated reply text');

    my $invalid_client = MB700F::Client->new(
        execute_result => {
            ok => 1,
            provider => 'anthropic',
            model => 'claude-test',
            answer => 'Sure, I can answer that.',
        },
    );
    my $invalid = Mediabot::AI::ConversationExecutor->new(
        client => $invalid_client,
    )->execute_dryrun(
        message => 'hello',
    );
    $assert->is($invalid->{action}, 'no_reply',
        'mb700-928: malformed provider output fails closed');
    $assert->is($invalid->{reason}, 'invalid_output',
        'mb700-928: malformed provider output is machine-visible');
    $assert->ok(!exists($invalid->{text}) && !exists($invalid->{answer}),
        'mb700-928: invalid raw provider output is discarded');

    my $failure_client = MB700F::Client->new(
        execute_result => {
            ok => 0,
            provider => 'openai',
            model => 'gpt-test',
            error => 'http_error',
            error_message => 'secret provider body must not escape',
            attempted => ['openai:gpt-test'],
        },
    );
    my $failure = Mediabot::AI::ConversationExecutor->new(
        client => $failure_client,
    )->execute_dryrun(
        provider => 'openai',
        message => 'hello',
    );
    $assert->is($failure->{ok}, 0,
        'mb700-928: provider failure remains failure');
    $assert->is($failure->{action}, 'no_reply',
        'mb700-928: provider failure can never become an IRC reply');
    $assert->is($failure->{reason}, 'provider_error',
        'mb700-928: provider failure reason is normalized');
    $assert->is($failure->{error}, 'http_error',
        'mb700-928: bounded provider error code is retained');
    $assert->ok(!exists($failure->{error_message}) && !exists($failure->{attempted}),
        'mb700-928: provider body and attempt history are not propagated');

    my $failure_summary = execution_summary($failure);
    $assert->is($failure_summary->{error}, 'http_error',
        'mb700-928: safe summary may expose bounded error code');
    $assert->ok(!exists($failure_summary->{error_message}),
        'mb700-928: safe summary cannot expose provider error body');

    my $exception_client = MB700F::Client->new(
        execute_result => sub { die "transport exploded with payload\n" },
    );
    my $exception = Mediabot::AI::ConversationExecutor->new(
        client => $exception_client,
    )->execute_dryrun(
        message => 'hello',
    );
    $assert->is($exception->{reason}, 'provider_error',
        'mb700-928: client exception fails closed');
    $assert->is($exception->{error}, 'client_exception',
        'mb700-928: client exception is reduced to a bounded code');

    my $async_client = MB700F::Client->new(
        submit_result => {
            ok => 1,
            provider => 'openai',
            model => 'gpt-async',
            answer => 'REPLY: async hello 👋',
            provider_fallback => 0,
            model_fallback => 1,
        },
        submit_started => 1,
    );
    my $async_executor = Mediabot::AI::ConversationExecutor->new(
        client => $async_client,
    );
    my $async_result;
    my $started = $async_executor->submit_dryrun(
        provider => 'GPT',
        language => 'en',
        message => 'hello async',
        on_done => sub { $async_result = shift },
    );
    $assert->is($started, 1,
        'mb700-928: async dry-run reports worker submission');
    $assert->is(scalar(@{ $async_client->{submit_calls} }), 1,
        'mb700-928: async path submits one canonical request');
    $assert->is($async_client->{submit_calls}[0]{provider}, 'openai',
        'mb700-928: async request stays provider-neutral before client routing');
    $assert->is($async_result->{action}, 'reply',
        'mb700-928: async provider result uses the same strict parser');
    $assert->is($async_result->{text}, 'async hello 👋',
        'mb700-928: async reply is normalized');
    $assert->is($async_result->{model_fallback}, 1,
        'mb700-928: async result preserves model fallback metadata');

    my $bad_arg = eval {
        $executor->execute_dryrun(
            message => 'hello',
            nick => 'Alice',
        );
        1;
    };
    $assert->ok(!$bad_arg,
        'mb700-928: executor rejects identity fields');
    $assert->like($@, qr/unknown Wit executor field: nick/,
        'mb700-928: rejected executor field is explicit');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationExecutor.pm" or die $!;
        local $/; <$fh>;
    };
    $assert->like($src, qr/use Mediabot::AI::Client/,
        'mb700-928: executor owns the provider-neutral client boundary');
    $assert->like($src, qr/use Mediabot::AI::ConversationRequest/,
        'mb700-928: executor builds the safe Wit request');
    $assert->like($src, qr/use Mediabot::AI::ConversationDecision/,
        'mb700-928: executor owns strict model decision parsing');
    $assert->unlike($src, qr/Provider::Anthropic|Provider::OpenAI|HTTP::|DBI\b|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|botAction/,
        'mb700-928: executor owns no provider wire format, DB or IRC emission');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($main, qr/use Mediabot::AI::ConversationExecutor/,
        'mb700-928: MB700-F executor is not wired into IRC runtime yet');
};
