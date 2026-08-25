# t/cases/914_mb699_ai_request_contract.t
# =============================================================================
# MB699-B — provider-neutral AI request contract.
#
# This layer deliberately owns no HTTP endpoint, credential or IRC output.
# It defines the portable request shape that future Anthropic/OpenAI adapters
# and +Wit will share.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::AI::Request;

    my $request = Mediabot::AI::Request::build_request(
        provider          => 'ChatGPT',
        purpose           => 'wit',
        model             => 'example-model-1',
        system            => 'Be brief and friendly.',
        messages          => [
            { role => 'user',      content => 'Hello' },
            { role => 'assistant', content => 'Hi!' },
            { role => 'user',      content => 'One short joke, please.' },
        ],
        max_output_tokens => 120,
        temperature       => 0.8,
        timeout_seconds   => 20,
    );

    $assert->is($request->{provider}, 'openai',
        'mb699-914: provider aliases are canonicalized');
    $assert->is($request->{purpose}, 'wit',
        'mb699-914: request purpose is retained');
    $assert->is($request->{messages}[2]{role}, 'user',
        'mb699-914: portable conversation keeps alternating roles');
    $assert->is($request->{max_output_tokens}, 120,
        'mb699-914: provider-neutral output budget is retained');
    $assert->ok(!defined Mediabot::AI::Request::validate_request($request),
        'mb699-914: normalized request validates');

    # build_request must clone caller-owned message hashes so later caller
    # mutations cannot silently alter an in-flight request.
    my $source = [ { role => 'user', content => 'original' } ];
    my $clone = Mediabot::AI::Request::build_request(messages => $source);
    $source->[0]{content} = 'mutated';
    $assert->is($clone->{messages}[0]{content}, 'original',
        'mb699-914: request owns a defensive copy of message content');
    $assert->is($clone->{provider}, 'auto',
        'mb699-914: provider defaults to auto');
    $assert->is($clone->{purpose}, 'generic',
        'mb699-914: purpose defaults to generic');

    my $summary = Mediabot::AI::Request::request_summary($request);
    $assert->is($summary->{provider}, 'openai',
        'mb699-914: safe summary exposes provider name');
    $assert->is($summary->{messages}, 3,
        'mb699-914: safe summary exposes message count');
    $assert->ok($summary->{chars} > 0,
        'mb699-914: safe summary exposes aggregate character count');
    $assert->unlike(join(' ', map { defined($_) ? $_ : '' } values %$summary),
        qr/Hello|One short joke|Be brief/i,
        'mb699-914: safe summary never exposes prompt content');

    my @invalid = (
        [ 'unknown field', {
            messages => [ { role => 'user', content => 'x' } ],
            api_key  => 'must-never-enter-request',
        }, qr/unknown request field: api_key/ ],
        [ 'unknown provider', {
            provider => 'mystery-ai',
            messages => [ { role => 'user', content => 'x' } ],
        }, qr/provider is unknown/ ],
        [ 'system role forbidden', {
            messages => [ { role => 'system', content => 'x' } ],
        }, qr/role must be user or assistant/ ],
        [ 'conversation must start user', {
            messages => [ { role => 'assistant', content => 'x' } ],
        }, qr/role must alternate from user/ ],
        [ 'conversation must alternate', {
            messages => [
                { role => 'user', content => 'x' },
                { role => 'user', content => 'y' },
            ],
        }, qr/role must alternate from user/ ],
        [ 'conversation must end user', {
            messages => [
                { role => 'user',      content => 'x' },
                { role => 'assistant', content => 'y' },
            ],
        }, qr/final message must have role=user/ ],
        [ 'empty content forbidden', {
            messages => [ { role => 'user', content => '' } ],
        }, qr/content must be a non-empty scalar/ ],
        [ 'bad output budget', {
            messages          => [ { role => 'user', content => 'x' } ],
            max_output_tokens => 0,
        }, qr/max_output_tokens/ ],
        [ 'bad temperature', {
            messages    => [ { role => 'user', content => 'x' } ],
            temperature => 3,
        }, qr/temperature/ ],
        [ 'bad timeout', {
            messages        => [ { role => 'user', content => 'x' } ],
            timeout_seconds => 0,
        }, qr/timeout_seconds/ ],
    );

    for my $case (@invalid) {
        my ($name, $candidate, $re) = @$case;
        my $error = Mediabot::AI::Request::validate_request($candidate);
        $assert->like($error // '', $re, "mb699-914: rejects $name");
    }

    my $died = eval {
        Mediabot::AI::Request::build_request(
            messages => [ { role => 'user', content => 'x' } ],
            authorization => 'Bearer secret',
        );
        0;
    };
    $assert->like($@, qr/unknown request field: authorization/,
        'mb699-914: constructor rejects transport credentials and headers');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/AI/Request.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->unlike($src, qr/api\.anthropic\.com|api\.openai\.com|x-api-key|Bearer\s/i,
        'mb699-914: request contract owns no endpoint or authentication header');
};
