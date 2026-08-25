# t/cases/220_external_claude_api.t
# Anthropic wire contract lives in Provider::Anthropic and AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use JSON::PP qw(decode_json);
use Mediabot::AI::Provider::Anthropic ();
use Mediabot::AI::Request qw(build_request);
sub _s220 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s220(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $provider=_s220(File::Spec->catfile('.','Mediabot','AI','Provider','Anthropic.pm'));
    my $client=_s220(File::Spec->catfile('.','Mediabot','AI','Client.pm'));

    $assert->like($provider, qr/'x-api-key'\s*=>\s*\$api_key/, 'Anthropic adapter owns x-api-key');
    $assert->like($provider, qr/'anthropic-version'\s*=>\s*\$api_version/, 'Anthropic adapter owns API version header');
    $assert->like($provider, qr/sub extract_answer\s*\{/, 'Anthropic adapter owns response parsing');
    $assert->like($client, qr/Mediabot::AI::Provider::Anthropic::build_headers/, 'AI client obtains Anthropic headers from provider');
    $assert->like($client, qr/Mediabot::AI::Provider::Anthropic::extract_answer/, 'AI client delegates Anthropic response parsing');
    $assert->like($external, qr/provider\s*=>\s*'anthropic'/, 'Claude caller builds explicit Anthropic request');
    $assert->unlike($external, qr/sub _claude_http_request\b|use Mediabot::AI::Provider::Anthropic/, 'Claude message transport no longer owns Anthropic wire adapter');

    my $r=build_request(provider=>'anthropic',purpose=>'ai',model=>'claude-test',messages=>[{role=>'user',content=>'x'}],max_output_tokens=>10);
    my $payload=decode_json(Mediabot::AI::Provider::Anthropic::build_payload($r));
    $assert->is($payload->{model}, 'claude-test', 'provider payload keeps model');
    $assert->is(Mediabot::AI::Provider::Anthropic::extract_answer('{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}'), 'AB', 'provider joins text blocks');
};
