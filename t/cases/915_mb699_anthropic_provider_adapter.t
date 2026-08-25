# t/cases/915_mb699_anthropic_provider_adapter.t
# Anthropic adapter is consumed by AI::Client; legacy caller must not duplicate it.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s915 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s915(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $provider=_s915(File::Spec->catfile('.','Mediabot','AI','Provider','Anthropic.pm'));
    my $client=_s915(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    $assert->like($provider, qr/sub build_payload\s*\{/, 'Anthropic provider owns payload');
    $assert->like($provider, qr/sub build_headers\s*\{/, 'Anthropic provider owns headers');
    $assert->like($provider, qr/sub extract_answer\s*\{/, 'Anthropic provider owns parser');
    $assert->like($client, qr/use Mediabot::AI::Provider::Anthropic/, 'AI client loads Anthropic provider');
    $assert->like($client, qr/Provider::Anthropic::build_payload/, 'AI client uses Anthropic payload adapter');
    $assert->like($client, qr/Provider::Anthropic::build_headers/, 'AI client uses Anthropic header adapter');
    $assert->like($client, qr/Provider::Anthropic::extract_answer/, 'AI client uses Anthropic parser');
    $assert->unlike($external, qr/use Mediabot::AI::Provider::Anthropic/, 'legacy caller no longer imports Anthropic wire adapter');
    $assert->unlike($external, qr/sub _claude_(?:build_payload|http_request|extract_answer|accept_http_result)\b/, 'obsolete Anthropic compatibility helpers removed');
};
