# t/cases/916_mb699_openai_provider_adapter.t
# =============================================================================
# MB699-D — OpenAI provider adapter contract.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use JSON::PP qw(decode_json encode_json);
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Provider::OpenAI qw(
    build_payload build_headers extract_answer extract_error user_error_message
);

return sub {
    my ($assert) = @_;

    my $request = build_request(
        provider          => 'openai',
        purpose           => 'tellme',
        model             => 'gpt-test',
        system            => 'Be concise.',
        messages          => [ { role => 'user', content => 'Hello' } ],
        max_output_tokens => 123,
        temperature       => 0.4,
        timeout_seconds   => 20,
    );

    my $payload_json = build_payload($request);
    my $payload = decode_json($payload_json);

    $assert->is($payload->{model}, 'gpt-test', 'OpenAI payload uses request model');
    $assert->is($payload->{max_tokens}, 123, 'provider-neutral token limit maps to max_tokens');
    $assert->is($payload->{temperature}, 0.4, 'temperature preserved');
    $assert->is(scalar(@{ $payload->{messages} }), 2, 'system prompt is prepended to conversation');
    $assert->is($payload->{messages}[0]{role}, 'system', 'first OpenAI message is system');
    $assert->is($payload->{messages}[0]{content}, 'Be concise.', 'system content preserved');
    $assert->is($payload->{messages}[1]{role}, 'user', 'provider-neutral user message preserved');
    $assert->is($payload->{messages}[1]{content}, 'Hello', 'user content preserved');
    $assert->ok(!exists($payload->{api_key}), 'API key never enters payload');
    $assert->ok(!exists($payload->{timeout_seconds}), 'transport timeout never enters payload');

    my $headers = build_headers({ api_key => 'sk-test-secret' });
    $assert->is($headers->{'Content-Type'}, 'application/json', 'OpenAI JSON content type');
    $assert->is($headers->{Authorization}, 'Bearer sk-test-secret', 'OpenAI Bearer auth header');
    $assert->unlike($payload_json, qr/sk-test-secret/, 'credential absent from serialized payload');

    my $answer = extract_answer(encode_json({
        choices => [ { message => { role => 'assistant', content => 'Hello back' } } ],
    }));
    $assert->is($answer, 'Hello back', 'Chat Completions answer extracted');
    $assert->ok(!defined(extract_answer('{}')), 'missing choices returns undef');
    $assert->ok(!defined(extract_answer('{bad json')), 'invalid JSON returns undef');
    $assert->ok(!defined(extract_answer(encode_json({ choices => [] }))), 'empty choices returns undef');

    my ($type, $code, $message) = extract_error(encode_json({
        error => {
            type    => "rate_limit\nerror",
            code    => 'rate_limit_exceeded',
            message => "Too many\r\nrequests",
        },
    }));
    $assert->is($type, 'rate_limit error', 'error type controls are sanitized');
    $assert->is($code, 'rate_limit_exceeded', 'error code extracted');
    $assert->is($message, 'Too many requests', 'error message sanitized');

    ($type, $code, $message) = extract_error('');
    $assert->is("$type$code$message", '', 'empty error body is safe');

    $assert->like(
        user_error_message(429, 'insufficient_quota', 'insufficient_quota'),
        qr/key accepted.*credits|budget/i,
        'quota exhaustion is distinguished from rate limiting'
    );
    $assert->like(user_error_message(429, 'requests', 'rate_limit_exceeded'), qr/rate limit/i,
        'rate limiting diagnosis preserved');
    $assert->like(user_error_message(401, 'invalid_request_error', 'invalid_api_key'), qr/rejected.*key|replace.*API_KEY/i,
        'invalid API key diagnosis preserved');
    $assert->like(user_error_message(403, 'permission_error', 'access_denied'), qr/permission|not necessarily invalid/i,
        'permission diagnosis preserved');
    $assert->like(user_error_message(404, '', 'model_not_found'), qr/model unavailable|not permitted/i,
        'model diagnosis preserved');
    $assert->like(user_error_message(0, '', ''), qr/DNS|TLS|firewall/i,
        'network diagnosis preserved');
    $assert->like(user_error_message(500, '', ''), qr/service error|retry/i,
        'server diagnosis preserved');

    my $wrong = build_request(
        provider          => 'anthropic',
        model             => 'claude-test',
        messages          => [ { role => 'user', content => 'Hello' } ],
        max_output_tokens => 10,
    );
    my $ok = eval { build_payload($wrong); 1 };
    $assert->ok(!$ok, 'OpenAI adapter rejects an Anthropic request');

    $ok = eval { build_headers({}); 1 };
    $assert->ok(!$ok, 'OpenAI adapter requires API key transport input');
};
