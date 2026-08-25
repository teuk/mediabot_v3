# t/cases/167_chatgpt_json_structure_guard.t
# OpenAI response parsing belongs to Provider::OpenAI and the normalized
# AI::Client boundary; External::Claude must never dereference wire JSON.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::AI::Provider::OpenAI ();

sub _slurp_167 { my ($p)=@_; open my $f,'<:raw',$p or die $!; local $/; <$f> }

return sub {
    my ($assert)=@_;
    my $external=_slurp_167(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $provider=_slurp_167(File::Spec->catfile('.','Mediabot','AI','Provider','OpenAI.pm'));
    my $client=_slurp_167(File::Spec->catfile('.','Mediabot','AI','Client.pm'));

    $assert->like($provider, qr/sub extract_answer\s*\{/, 'OpenAI extract_answer exists');
    $assert->like($provider, qr/eval \{ decode_json\(\$content \/\/ ''\) \}/, 'JSON decode is guarded');
    $assert->like($provider, qr/ref\(\$data->\{choices\}\) eq 'ARRAY'/, 'choices must be ARRAY');
    $assert->like($provider, qr/ref\(\$data->\{choices\}\[0\]\{message\}\) eq 'HASH'/, 'message must be HASH');
    $assert->like($provider, qr/defined\(\$data->\{choices\}\[0\]\{message\}\{content\}\)/, 'content must be defined');
    $assert->like($client, qr/Mediabot::AI::Provider::OpenAI::extract_answer\(\$body\)/, 'AI client delegates successful OpenAI parsing to provider');
    $assert->like($external, qr/sub _chatgpt_accept_client_result\s*\{/, 'tellme accepts normalized AI client result');
    $assert->unlike($external, qr/\$data->\{choices\}\[0\]\{message\}\{content\}/, 'External::Claude never dereferences OpenAI wire response');

    $assert->is(Mediabot::AI::Provider::OpenAI::extract_answer('{"choices":[{"message":{"content":"ok"}}]}'), 'ok', 'valid answer parsed');
    $assert->ok(!defined Mediabot::AI::Provider::OpenAI::extract_answer('{"choices":[]}'), 'missing choice safely rejected');
    $assert->ok(!defined Mediabot::AI::Provider::OpenAI::extract_answer('not-json'), 'invalid JSON safely rejected');
};
