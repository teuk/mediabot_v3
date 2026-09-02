# Google Gemini provider adapter and common-client contract.

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use JSON::PP qw(decode_json encode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Provider::Gemini qw(
    build_url build_payload build_headers extract_answer extract_diagnostic extract_error
    user_error_message
);

{
    package Gemini1028::Conf;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}

{
    package Gemini1028::HTTP;
    sub new { bless { call => $_[1] }, $_[0] }
    sub request {
        my ($self, @args) = @_;
        return $self->{call}->(@args);
    }
}

return sub {
    my ($assert) = @_;

    my $request = build_request(
        provider          => 'gemini',
        purpose           => 'gemini',
        model             => 'gemini-test',
        system            => 'Be concise.',
        messages          => [
            { role => 'user',      content => 'Hello' },
            { role => 'assistant', content => 'Hi' },
            { role => 'user',      content => 'Continue' },
        ],
        max_output_tokens => 123,
        temperature       => 0.4,
        timeout_seconds   => 17,
    );

    $assert->is(
        build_url('https://generativelanguage.example/v1beta/models/', 'gemini-test'),
        'https://generativelanguage.example/v1beta/models/gemini-test:generateContent',
        'Gemini URL builder appends validated model and method'
    );
    for my $bad_model ('../secret', 'model?key=secret', 'model/name') {
        my $ok = eval { build_url('https://example.test/v1beta/models', $bad_model); 1 };
        $assert->ok(!$ok, "unsafe Gemini model rejected: $bad_model");
    }

    my $payload_json = build_payload($request);
    my $payload = decode_json($payload_json);
    $assert->is($payload->{contents}[0]{role}, 'user',
        'user role maps to Gemini user');
    $assert->is($payload->{contents}[1]{role}, 'model',
        'assistant role maps to Gemini model');
    $assert->is($payload->{contents}[2]{parts}[0]{text}, 'Continue',
        'message content is preserved');
    $assert->is($payload->{systemInstruction}{parts}[0]{text}, 'Be concise.',
        'system prompt maps to systemInstruction');
    $assert->is($payload->{generationConfig}{maxOutputTokens}, 123,
        'neutral output token limit maps to maxOutputTokens');
    $assert->is($payload->{generationConfig}{temperature}, 0.4,
        'temperature is preserved');
    $assert->ok(!exists($payload->{generationConfig}{thinkingConfig}),
        'adapter adds no model-specific thinking policy implicitly');
    my $low_payload = decode_json(build_payload(
        $request, { thinking_level => 'low' }
    ));
    $assert->is(
        $low_payload->{generationConfig}{thinkingConfig}{thinkingLevel},
        'LOW',
        'validated Gemini thinking level maps into generationConfig'
    );
    my $bad_thinking = eval {
        build_payload($request, { thinking_level => 'minimal' });
        1;
    };
    $assert->ok(!$bad_thinking,
        'unsupported Gemini 3.8 thinking level fails closed');
    $assert->ok(!exists($payload->{model}),
        'model stays in validated URL instead of payload');

    my $headers = build_headers({ api_key => 'gemini-test-secret' });
    $assert->is($headers->{'x-goog-api-key'}, 'gemini-test-secret',
        'Gemini key uses x-goog-api-key header');
    $assert->unlike($payload_json, qr/gemini-test-secret/,
        'Gemini credential never enters payload');

    my $answer = extract_answer(encode_json({ candidates => [ { content => {
        parts => [
            { thought => JSON::PP::true, text => 'internal reasoning' },
            { text => 'Visible ' },
            { text => 'answer' },
        ],
    } } ] }));
    $assert->is($answer, 'Visible answer',
        'visible text parts are joined and thought parts are excluded');
    $assert->ok(!defined extract_answer('{}'), 'missing candidates fail closed');
    $assert->ok(!defined extract_answer('{bad'), 'invalid JSON fails closed');

    my $empty_success = encode_json({
        candidates => [ {
            finishReason => 'MAX_TOKENS',
            content => { parts => [ {
                thought => JSON::PP::true,
                text => 'private reasoning that must not enter diagnostics',
            } ] },
        } ],
        usageMetadata => {
            thoughtsTokenCount => 128,
            candidatesTokenCount => 0,
            totalTokenCount => 137,
        },
    });
    my ($diag_type, $diag_code, $diag_message) =
        extract_diagnostic($empty_success);
    $assert->is($diag_type, 'MAX_TOKENS',
        'empty HTTP success preserves the bounded finish reason');
    $assert->is($diag_code, 'OUTPUT_BUDGET_EXHAUSTED',
        'token exhaustion has a stable diagnostic code');
    $assert->like($diag_message,
        qr/thoughts=128 candidates=0 .*thought_parts=1 text_parts=0/,
        'diagnostic exposes only structural token and part counts');
    $assert->unlike($diag_message, qr/private reasoning/,
        'diagnostic never exposes thought text');

    my ($type, $code, $message) = extract_error(encode_json({ error => {
        status => "RESOURCE_EXHAUSTED\n", code => 429,
        message => "Quota\r\nexceeded",
    } }));
    $assert->is($type, 'RESOURCE_EXHAUSTED', 'Gemini status is sanitized');
    $assert->is($code, '429', 'Gemini numeric error code is normalized');
    $assert->is($message, 'Quota exceeded', 'Gemini error message is sanitized');
    $assert->like(user_error_message(429, $type, $code), qr/quota|rate/i,
        'Gemini quota diagnosis is actionable');
    $assert->like(user_error_message(403, 'PERMISSION_DENIED', 403), qr/API_KEY|access/i,
        'Gemini permission diagnosis is actionable');
    $assert->like(
        user_error_message(200, 'MAX_TOKENS', 'OUTPUT_BUDGET_EXHAUSTED'),
        qr/response budget|retry/i,
        'empty success token exhaustion has a bounded public message'
    );

    my $conf = Gemini1028::Conf->new(
        'gemini.API_KEY'    => 'gemini-client-secret',
        'gemini.API_URL'    => 'https://gemini.example/v1beta/models',
        'gemini.MODEL'      => 'gemini-client-model',
        'gemini.MAX_TOKENS' => 222,
        'gemini.TEMPERATURE'=> '0.6',
        'gemini.TIMEOUT'    => 19,
        'gemini.THINKING_LEVEL' => 'LOW',
    );
    my @calls;
    my $client = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => sub {
            my (%factory) = @_;
            return Gemini1028::HTTP->new(sub {
                my ($method, $url, $req) = @_;
                push @calls, {
                    method => $method, url => $url,
                    headers => { %{ $req->{headers} || {} } },
                    payload => $req->{content}, factory => \%factory,
                };
                return {
                    success => 1, status => 200, reason => 'OK',
                    content => encode_json({ candidates => [ { content => {
                        parts => [ { text => 'client-ok' } ],
                    } } ] }),
                };
            });
        },
    );
    my $result = $client->execute(build_request(
        provider => 'gemini', purpose => 'gemini',
        messages => [ { role => 'user', content => 'ping' } ],
    ));
    $assert->ok($result->{ok}, 'explicit Gemini request succeeds through common client');
    $assert->is($result->{provider}, 'gemini', 'client reports Gemini provider');
    $assert->is($result->{model}, 'gemini-client-model', 'model comes from Gemini config');
    $assert->is($result->{answer}, 'client-ok', 'Gemini answer is normalized');
    $assert->is(scalar(@calls), 1, 'one Gemini HTTP request is emitted');
    $assert->is($calls[0]{url},
        'https://gemini.example/v1beta/models/gemini-client-model:generateContent',
        'common client uses provider-built Gemini URL');
    $assert->is($calls[0]{headers}{'x-goog-api-key'}, 'gemini-client-secret',
        'common client delegates Gemini authentication header');
    $assert->is($calls[0]{factory}{verify_SSL}, 1,
        'shared transport forces verified TLS');
    my $client_payload = decode_json($calls[0]{payload});
    $assert->is(
        $client_payload->{generationConfig}{thinkingConfig}{thinkingLevel},
        'LOW',
        'common client applies bounded low thinking for IRC-oriented Gemini'
    );
    my $serialized = encode_json($result);
    $assert->unlike($serialized, qr/gemini-client-secret|x-goog-api-key/i,
        'normalized result contains no credential or auth header');

    my $parse_client = Mediabot::AI::Client->new(
        conf => $conf,
        http_factory => sub {
            return Gemini1028::HTTP->new(sub {
                return {
                    success => 1, status => 200, reason => 'OK',
                    content => $empty_success,
                };
            });
        },
    );
    my $parse_result = $parse_client->execute(build_request(
        provider => 'gemini', purpose => 'gemini-empty-success',
        messages => [ { role => 'user', content => 'ping' } ],
    ));
    $assert->ok(!$parse_result->{ok},
        'HTTP success without visible Gemini text still fails closed');
    $assert->is($parse_result->{error}, 'parse_error',
        'empty successful Gemini envelope is classified as parse error');
    $assert->is($parse_result->{error_type}, 'MAX_TOKENS',
        'common client retains the safe Gemini finish reason');
    $assert->like($parse_result->{error_message}, qr/thoughts=128/,
        'common client retains safe structural Gemini diagnostics');
    $assert->unlike(encode_json($parse_result), qr/private reasoning/,
        'common result never contains thought text');

    my $auto_result = $client->execute(build_request(
        provider => 'auto', purpose => 'auto-gemini',
        messages => [ { role => 'user', content => 'auto ping' } ],
    ));
    $assert->ok($auto_result->{ok},
        'auto mode can select Gemini when it is the configured provider');
    $assert->is($auto_result->{provider}, 'gemini',
        'auto mode reports its Gemini choice');

    my $wrong = build_request(
        provider => 'openai', model => 'gpt-test',
        messages => [ { role => 'user', content => 'Hello' } ],
        max_output_tokens => 10,
    );
    my $ok = eval { build_payload($wrong); 1 };
    $assert->ok(!$ok, 'Gemini adapter rejects an OpenAI request');
};
