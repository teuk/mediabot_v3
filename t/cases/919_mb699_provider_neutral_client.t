# t/cases/919_mb699_provider_neutral_client.t
# =============================================================================
# MB699-G — provider-neutral AI client/dispatcher.
#
# The future +Wit consumer must be able to submit one canonical request without
# knowing Anthropic/OpenAI wire formats, credentials, endpoints or IRC details.
# Explicit providers stay strict; auto may fail over only because the caller
# explicitly granted provider choice.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use JSON::PP qw(decode_json encode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);

{
    package MB699G::Conf;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}

{
    package MB699G::Loop;
    sub new { bless {}, shift }
    sub add { 1 }
    sub remove { 1 }
    sub watch_process { 1 }
}

{
    package MB699G::Owner;
    sub new { bless { loop => $_[1] }, $_[0] }
    sub getLoop { $_[0]{loop} }
}

{
    package MB699G::Worker;
    sub new { bless {}, shift }
}

{
    package MB699G::HTTP;
    sub new { bless { handler => $_[1] }, $_[0] }
    sub request {
        my ($self, @args) = @_;
        return $self->{handler}->(@args);
    }
}

sub _conf_919 {
    return MB699G::Conf->new(
        'anthropic.API_KEY'     => 'anthropic-secret-919',
        'anthropic.API_URL'     => 'https://anthropic.example/v1/messages',
        'anthropic.API_VERSION' => '2023-06-01',
        'anthropic.MODEL'       => 'claude-test-919',
        'anthropic.MAX_TOKENS'  => 111,
        'anthropic.TEMPERATURE' => '0.4',

        'openai.API_KEY'        => 'openai-secret-919',
        'openai.API_URL'        => 'https://openai.example/v1/chat/completions',
        'openai.MODEL'          => 'gpt-primary-919',
        'openai.FALLBACK_MODEL' => 'gpt-fallback-919',
        'openai.MAX_TOKENS'     => 222,
        'openai.TEMPERATURE'    => '0.6',
        'openai.TIMEOUT'        => 19,
    );
}

sub _request_919 {
    my ($provider, %extra) = @_;
    return build_request(
        provider => $provider,
        purpose  => 'wit',
        system   => 'Be brief.',
        messages => [ { role => 'user', content => 'ping' } ],
        %extra,
    );
}

sub _factory_919 {
    my ($calls, $handler) = @_;
    return sub {
        my (%factory) = @_;
        return MB699G::HTTP->new(sub {
            my ($method, $url, $req) = @_;
            push @$calls, {
                method  => $method,
                url     => $url,
                headers => { %{ $req->{headers} || {} } },
                payload => $req->{content},
                timeout => $factory{timeout},
                verify  => $factory{verify_SSL},
            };
            return $handler->($method, $url, $req, \%factory, $calls);
        });
    };
}

sub _anthropic_ok_919 {
    my ($text) = @_;
    return {
        success => 1,
        status  => 200,
        reason  => 'OK',
        content => encode_json({ content => [ { type => 'text', text => $text } ] }),
    };
}

sub _openai_ok_919 {
    my ($text) = @_;
    return {
        success => 1,
        status  => 200,
        reason  => 'OK',
        content => encode_json({ choices => [ { message => { content => $text } } ] }),
    };
}

return sub {
    my ($assert) = @_;

    my $conf = _conf_919();

    # Explicit Anthropic: provider adapter and shared transport are hidden from
    # the caller, while model/config defaults are resolved by the client.
    my @anthropic_calls;
    my $anthropic = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@anthropic_calls, sub {
            return _anthropic_ok_919('anthropic-ok');
        }),
    );
    my $ar = $anthropic->execute(_request_919('anthropic'));
    $assert->ok($ar->{ok}, 'mb699-919: explicit Anthropic request succeeds');
    $assert->is($ar->{provider}, 'anthropic', 'mb699-919: Anthropic provider reported');
    $assert->is($ar->{model}, 'claude-test-919', 'mb699-919: Anthropic model comes from provider config');
    $assert->is($ar->{answer}, 'anthropic-ok', 'mb699-919: Anthropic answer parsed behind common client');
    $assert->is(scalar(@anthropic_calls), 1, 'mb699-919: one Anthropic HTTP request emitted');
    $assert->is($anthropic_calls[0]{headers}{'x-api-key'}, 'anthropic-secret-919',
        'mb699-919: Anthropic adapter owns x-api-key header');
    $assert->is($anthropic_calls[0]{verify}, 1,
        'mb699-919: shared transport still forces verified TLS');
    my $ap = decode_json($anthropic_calls[0]{payload});
    $assert->is($ap->{max_tokens}, 111,
        'mb699-919: Anthropic max token default resolved from provider config');
    $assert->is($ap->{messages}[0]{content}, 'ping',
        'mb699-919: canonical message reaches Anthropic payload');

    # Explicit OpenAI.
    my @openai_calls;
    my $openai = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@openai_calls, sub {
            return _openai_ok_919('openai-ok');
        }),
    );
    my $or = $openai->execute(_request_919('openai'));
    $assert->ok($or->{ok}, 'mb699-919: explicit OpenAI request succeeds');
    $assert->is($or->{provider}, 'openai', 'mb699-919: OpenAI provider reported');
    $assert->is($or->{model}, 'gpt-primary-919', 'mb699-919: OpenAI primary model comes from config');
    $assert->is($or->{answer}, 'openai-ok', 'mb699-919: OpenAI answer parsed behind common client');
    $assert->is($openai_calls[0]{headers}{Authorization}, 'Bearer openai-secret-919',
        'mb699-919: OpenAI adapter owns bearer header');
    my $op = decode_json($openai_calls[0]{payload});
    $assert->is($op->{max_tokens}, 222,
        'mb699-919: OpenAI max token default resolved from provider config');
    $assert->is($op->{messages}[0]{role}, 'system',
        'mb699-919: canonical system prompt mapped by OpenAI adapter');

    # Auto default and caller-selected order.
    my @auto_calls;
    my $auto = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@auto_calls, sub {
            my (undef, $url) = @_;
            return $url =~ /anthropic/
                ? _anthropic_ok_919('auto-anthropic')
                : _openai_ok_919('auto-openai');
        }),
    );
    my $auto_default = $auto->execute(_request_919('auto'));
    $assert->is($auto_default->{provider}, 'anthropic',
        'mb699-919: auto preserves deterministic Anthropic-first default');
    $assert->is(scalar(@auto_calls), 1,
        'mb699-919: successful first auto provider does not call the second');

    @auto_calls = ();
    my $auto_openai = $auto->execute(
        _request_919('auto'),
        provider_order => [qw(openai anthropic)],
    );
    $assert->is($auto_openai->{provider}, 'openai',
        'mb699-919: caller may make auto OpenAI-first');
    $assert->is(scalar(@auto_calls), 1,
        'mb699-919: OpenAI-first success remains a single request');

    # Auto cross-provider fallback is allowed; explicit provider never crosses.
    my @failover_calls;
    my $failover = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@failover_calls, sub {
            my (undef, $url) = @_;
            return {
                success => 0, status => 503, reason => 'Unavailable', content => '{}'
            } if $url =~ /anthropic/;
            return _openai_ok_919('provider-fallback-ok');
        }),
    );
    my $fr = $failover->execute(_request_919('auto'));
    $assert->ok($fr->{ok}, 'mb699-919: auto can recover through second provider');
    $assert->is($fr->{provider}, 'openai', 'mb699-919: auto failover reaches OpenAI');
    $assert->is($fr->{provider_fallback}, 1,
        'mb699-919: common result records provider fallback');
    $assert->is(scalar(@failover_calls), 2,
        'mb699-919: auto failover performs exactly two provider requests');

    @failover_calls = ();
    my $strict = $failover->execute(_request_919('anthropic'));
    $assert->ok(!$strict->{ok}, 'mb699-919: explicit Anthropic failure remains failure');
    $assert->is($strict->{provider}, 'anthropic',
        'mb699-919: explicit provider result stays Anthropic');
    $assert->is(scalar(@failover_calls), 1,
        'mb699-919: explicit provider never sends content to another company');

    # OpenAI model fallback remains provider-local and keeps its historical quota
    # exception: insufficient_quota must not burn a fallback-model request.
    my @model_calls;
    my $model_fallback = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@model_calls, sub {
            my (undef, undef, $req) = @_;
            my $payload = decode_json($req->{content});
            return {
                success => 0,
                status  => 404,
                reason  => 'Not Found',
                content => encode_json({ error => {
                    type => 'invalid_request_error', code => 'model_not_found', message => 'bad model'
                } }),
            } if $payload->{model} eq 'gpt-primary-919';
            return _openai_ok_919('model-fallback-ok');
        }),
    );
    my $mr = $model_fallback->execute(_request_919('openai'));
    $assert->ok($mr->{ok}, 'mb699-919: OpenAI provider-local model fallback succeeds');
    $assert->is($mr->{model}, 'gpt-fallback-919',
        'mb699-919: fallback result exposes the model actually used');
    $assert->is($mr->{model_fallback}, 1,
        'mb699-919: common result records model fallback');
    $assert->is(scalar(@model_calls), 2,
        'mb699-919: eligible OpenAI failure performs one fallback model request');

    my @quota_calls;
    my $quota = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => _factory_919(\@quota_calls, sub {
            return {
                success => 0,
                status  => 429,
                reason  => 'Too Many Requests',
                content => encode_json({ error => {
                    type => 'insufficient_quota', code => 'insufficient_quota', message => 'quota exhausted'
                } }),
            };
        }),
    );
    my $qr = $quota->execute(_request_919('openai'));
    $assert->ok(!$qr->{ok}, 'mb699-919: quota exhaustion is returned as failure');
    $assert->is(scalar(@quota_calls), 1,
        'mb699-919: insufficient quota does not retry OpenAI fallback model');

    # Routing/config errors fail closed before transport.
    my $anthropic_only_conf = MB699G::Conf->new(
        'anthropic.API_KEY' => 'only-anthropic',
        'anthropic.API_URL' => 'https://anthropic.example/v1/messages',
        'openai.API_KEY'    => '',
    );
    my @none_calls;
    my $anthropic_only = Mediabot::AI::Client->new(
        conf => $anthropic_only_conf,
        http_factory => _factory_919(\@none_calls, sub { die 'must not run' }),
    );
    my $missing = $anthropic_only->execute(_request_919('openai'));
    $assert->is($missing->{error}, 'not_configured',
        'mb699-919: explicit missing provider fails closed');
    $assert->is(scalar(@none_calls), 0,
        'mb699-919: missing provider causes no HTTP request');

    my $ambiguous = $auto->execute(_request_919('auto', model => 'provider-specific-model'));
    $assert->is($ambiguous->{error}, 'auto_model_ambiguous',
        'mb699-919: auto rejects provider-specific model override');

    my $bad_conf = MB699G::Conf->new(
        'openai.API_KEY' => 'configured',
        'openai.API_URL' => 'http://insecure.example/v1/chat/completions',
    );
    my $bad_client = Mediabot::AI::Client->new(conf => $bad_conf);
    my $bad_url = $bad_client->execute(_request_919('openai'));
    $assert->is($bad_url->{error}, 'invalid_config',
        'mb699-919: provider client refuses non-HTTPS endpoint');

    # Secrets are transport-only and never returned to the consumer.
    my $serialized = encode_json($or);
    $assert->unlike($serialized, qr/openai-secret-919|anthropic-secret-919|Authorization|x-api-key/i,
        'mb699-919: common result envelope contains no credentials or auth headers');

    # Async submit: the client owns worker plumbing and callback normalization;
    # caller only sees one provider-neutral result.
    my @async_calls;
    my @worker_capture;
    my $async = Mediabot::AI::Client->new(
        conf       => $conf,
        loop_owner => MB699G::Owner->new(MB699G::Loop->new),
        http_factory => _factory_919(\@async_calls, sub {
            return _anthropic_ok_919('async-ok');
        }),
        worker_start => sub {
            my (%args) = @_;
            push @worker_capture, \%args;
            my $value = $args{child}->();
            $args{on_done}->({ ok => 1, value => $value });
            return MB699G::Worker->new;
        },
    );
    my $async_result;
    my $submitted = $async->submit(
        _request_919('anthropic'),
        on_done => sub { $async_result = shift },
    );
    $assert->is($submitted, 1, 'mb699-919: async request is accepted');
    $assert->ok($async_result->{ok}, 'mb699-919: async callback receives common success result');
    $assert->is($async_result->{answer}, 'async-ok',
        'mb699-919: async callback receives parsed answer');
    $assert->is($worker_capture[0]{label}, 'provider-neutral AI request',
        'mb699-919: shared client owns a provider-neutral worker label');
    $assert->ok($worker_capture[0]{timeout} >= 30,
        'mb699-919: worker timeout covers provider HTTP timeout');

    my $no_loop = Mediabot::AI::Client->new(conf => $conf);
    my $no_loop_result;
    my $no_loop_rc = $no_loop->submit(
        _request_919('anthropic'),
        on_done => sub { $no_loop_result = shift },
    );
    $assert->is($no_loop_rc, 0,
        'mb699-919: async submit refuses to block when no usable event loop exists');
    $assert->is($no_loop_result->{error}, 'async_unavailable',
        'mb699-919: no-loop failure is explicit and provider-neutral');

    my $worker_fail_result;
    my $worker_fail = Mediabot::AI::Client->new(
        conf       => $conf,
        loop_owner => MB699G::Owner->new(MB699G::Loop->new),
        worker_start => sub {
            my (%args) = @_;
            $args{on_done}->({ ok => 0, error => 'child_failed' });
            return MB699G::Worker->new;
        },
    );
    $worker_fail->submit(
        _request_919('anthropic'),
        on_done => sub { $worker_fail_result = shift },
    );
    $assert->is($worker_fail_result->{error}, 'worker_failed',
        'mb699-919: AsyncWorker failure is normalized for callers');

    # Architectural boundary: the generic client contains no IRC delivery or
    # channel/nick semantics. +Wit may consume it without coupling AI to IRC.
    my $src = do {
        open my $fh, '<:raw', 'Mediabot/AI/Client.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->unlike($src, qr/Mediabot::Helpers|botPrivmsg|\bPRIVMSG\b|\bchannel\b|\bnick\b/i,
        'mb699-919: provider-neutral client has no IRC/channel/nick dependency');
    $assert->like($src, qr/Mediabot::AI::Provider::Anthropic/,
        'mb699-919: client dispatches through Anthropic adapter');
    $assert->like($src, qr/Mediabot::AI::Provider::OpenAI/,
        'mb699-919: client dispatches through OpenAI adapter');
    $assert->like($src, qr/Mediabot::AI::Transport::post_json/,
        'mb699-919: client dispatches through shared transport');
    $assert->like($src, qr/Mediabot::AsyncWorker->start/,
        'mb699-919: default async path uses AsyncWorker');
};
