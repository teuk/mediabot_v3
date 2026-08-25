# t/cases/635_mb420_verified_api_transport.t
# All credentialed AI HTTP must flow through AI::Transport with TLS verification.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s635 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s635(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $transport=_s635(File::Spec->catfile('.','Mediabot','AI','Transport.pm'));
    my $client=_s635(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    my $openai=_s635(File::Spec->catfile('.','Mediabot','AI','Provider','OpenAI.pm'));
    my $anthropic=_s635(File::Spec->catfile('.','Mediabot','AI','Provider','Anthropic.pm'));
    $assert->like($transport, qr/verify_SSL\s*=>\s*1/, 'shared transport enforces TLS verification');
    $assert->like($transport, qr/\$http->request\(\s*'POST'/s, 'shared transport performs bounded POST');
    $assert->like($client, qr/Mediabot::AI::Transport::post_json\(/, 'AI client uses shared verified transport');
    $assert->like($openai, qr/'Authorization'\s*=>\s*"Bearer \$api_key"/, 'OpenAI provider owns bearer credential header');
    $assert->like($anthropic, qr/'x-api-key'\s*=>\s*\$api_key/, 'Anthropic provider owns credential header');
    $assert->unlike($external, qr/Authorization\s*=>|x-api-key\s*=>/, 'External::Claude owns no credentialed AI headers');
    $assert->unlike($external, qr/HTTP::Tiny->new.*?(?:openai|anthropic)/si, 'External::Claude has no direct AI HTTP client construction');
};
