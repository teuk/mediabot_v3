# t/cases/920_mb699_tellme_client_adoption.t
# =============================================================================
# MB699-H — tellme adopts the provider-neutral AI::Client.
#
# The public command keeps its historical IRC/config contract, but model
# planning, provider serialization, HTTP and AsyncWorker ownership now sit
# behind AI::Client. Legacy transport helpers remain temporarily for a later
# cleanup round; chatGPT() itself must not call them anymore.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use JSON::PP qw(encode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);

sub _slurp_920 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_920 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = $-[0];
    my $pos = pos($src);
    my $depth = 1;
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

{
    package MB699H::Conf;
    sub new { my ($class, %kv) = @_; bless \%kv, $class }
    sub get { $_[0]{ $_[1] } }
}

{
    package MB699H::HTTP;
    sub new { bless {}, shift }
    sub request {
        return {
            success => 0,
            status  => 401,
            reason  => 'Unauthorized',
            content => JSON::PP::encode_json({ error => {
                type    => "authentication_error\n",
                code    => 'invalid_api_key',
                message => "bad\x00 key\nvalue",
            } }),
        };
    }
}

return sub {
    my ($assert) = @_;

    my $external = _slurp_920(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );
    my $client_src = _slurp_920(
        File::Spec->catfile('.', 'Mediabot', 'AI', 'Client.pm')
    );

    my $chatgpt = _extract_sub_920($external, 'chatGPT') // '';
    my $accept  = _extract_sub_920($external, '_chatgpt_accept_client_result') // '';
    my $deliver = _extract_sub_920($external, '_chatgpt_deliver_answer') // '';

    $assert->like($external, qr/use\s+Mediabot::AI::Client\s*\(\s*\)/,
        'mb699-920: External Claude imports provider-neutral AI client');
    $assert->like($chatgpt, qr/Mediabot::AI::Client->new\(/,
        'mb699-920: tellme creates common AI client');
    $assert->like($chatgpt, qr/provider\s*=>\s*'openai'/,
        'mb699-920: tellme remains strict OpenAI rather than auto routing');
    $assert->like($chatgpt, qr/purpose\s*=>\s*'tellme'/,
        'mb699-920: canonical request identifies tellme purpose');
    $assert->unlike($chatgpt, qr/Mediabot::AI::Provider::OpenAI::build_payload/,
        'mb699-920: tellme no longer serializes provider payload itself');
    $assert->unlike($chatgpt, qr/_chatgpt_transport_request\s*\(/,
        'mb699-920: tellme no longer invokes legacy OpenAI transport');
    $assert->unlike($chatgpt, qr/Mediabot::AsyncWorker->start\s*\(/,
        'mb699-920: tellme no longer owns worker lifecycle');
    $assert->like($chatgpt, qr/\$client->submit\(/,
        'mb699-920: production path submits through common client');
    $assert->like($chatgpt, qr/\$client->execute\(\$request\)/,
        'mb699-920: no-loop compatibility uses common client too');

    $assert->like($chatgpt, qr/'openai\.API_URL'\s*=>\s*\$chatgpt_api_url/,
        'mb699-920: legacy sanitized endpoint policy is preserved via safe override');
    $assert->like($chatgpt, qr/'openai\.FALLBACK_MODEL'\s*=>\s*\$chatgpt_fallback_model/,
        'mb699-920: legacy sanitized fallback policy is preserved via safe override');
    $assert->like($client_src, qr/config_overrides may not contain credentials/,
        'mb699-920: client config overlays explicitly reject credentials');

    $assert->like($accept, qr/error_type/,
        'mb699-920: caller receives sanitized provider error type');
    $assert->like($accept, qr/_chatgpt_user_error_message/,
        'mb699-920: historical actionable OpenAI user diagnosis is preserved');
    $assert->like($accept, qr/_chatgpt_deliver_answer/,
        'mb699-920: successful normalized result reaches common parent delivery');
    $assert->like($deliver, qr/_queue_irc_chunks/,
        'mb699-920: IRC pacing remains parent-owned');
    $assert->unlike($deliver, qr/Raw API response/,
        'mb699-920: normalized delivery has no raw provider body to log');

    my $conf = MB699H::Conf->new(
        'openai.API_KEY'        => 'secret-920',
        'openai.API_URL'        => 'http://legacy-invalid.example/v1/chat/completions',
        'openai.MODEL'          => 'gpt-test-920',
        'openai.FALLBACK_MODEL' => '',
        'openai.MAX_TOKENS'     => 64,
        'openai.TEMPERATURE'    => '0.2',
        'openai.TIMEOUT'        => 10,
    );

    my $client = Mediabot::AI::Client->new(
        conf => $conf,
        config_overrides => {
            'openai.API_URL' => 'https://openai.example/v1/chat/completions',
        },
        http_factory => sub { MB699H::HTTP->new },
    );

    my $result = $client->execute(build_request(
        provider => 'openai',
        purpose  => 'tellme',
        system   => 'test',
        messages => [ { role => 'user', content => 'ping' } ],
    ));

    $assert->ok(!$result->{ok},
        'mb699-920: provider error returns normalized failure');
    $assert->is($result->{status}, 401,
        'mb699-920: normalized failure preserves HTTP status');
    $assert->is($result->{error_type}, 'authentication_error',
        'mb699-920: provider error type is sanitized and preserved');
    $assert->is($result->{error_code}, 'invalid_api_key',
        'mb699-920: provider error code is sanitized and preserved');
    $assert->is($result->{error_message}, 'bad key value',
        'mb699-920: provider error message strips controls before caller logging');

    my $serialized = encode_json($result);
    $assert->unlike($serialized, qr/secret-920|Authorization|Bearer|content_b64/i,
        'mb699-920: common failure result exposes no credential/header/raw body');

    my $credential_override_ok = eval {
        Mediabot::AI::Client->new(
            conf => $conf,
            config_overrides => { 'openai.API_KEY' => 'must-not-be-accepted' },
        );
        1;
    };
    $assert->ok(!$credential_override_ok,
        'mb699-920: config override cannot inject or shadow an API credential');
};
