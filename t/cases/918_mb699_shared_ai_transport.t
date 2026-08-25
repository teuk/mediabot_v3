# t/cases/918_mb699_shared_ai_transport.t
# Shared transport remains the only HTTP envelope used by AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s918 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s918(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $client=_s918(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    my $transport=_s918(File::Spec->catfile('.','Mediabot','AI','Transport.pm'));
    my $openai=_s918(File::Spec->catfile('.','Mediabot','AI','Provider','OpenAI.pm'));
    my $anthropic=_s918(File::Spec->catfile('.','Mediabot','AI','Provider','Anthropic.pm'));
    $assert->like($transport, qr/sub usable_loop\s*\{/, 'shared loop helper exists');
    $assert->like($transport, qr/sub post_json\s*\{/, 'shared JSON POST helper exists');
    $assert->like($transport, qr/sub decode_content\s*\{/, 'shared response decoder exists');
    $assert->like($client, qr/Mediabot::AI::Transport::post_json\(/, 'client uses shared HTTP envelope');
    $assert->like($client, qr/Mediabot::AI::Transport::decode_content\(\$res\)/, 'client uses shared response decoding');
    $assert->like($client, qr/Mediabot::AI::Transport::usable_loop/, 'client uses shared loop detection');
    $assert->like($openai, qr/sub build_headers\s*\{/, 'OpenAI owns OpenAI headers');
    $assert->like($anthropic, qr/sub build_headers\s*\{/, 'Anthropic owns Anthropic headers');
    $assert->unlike($external, qr/Mediabot::AI::Transport::post_json\(/, 'legacy caller no longer performs provider HTTP');
};
