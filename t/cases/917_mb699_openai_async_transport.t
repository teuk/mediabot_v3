# t/cases/917_mb699_openai_async_transport.t
# OpenAI async transport is now wholly owned by AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s917 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s917(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $client=_s917(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    $assert->like($external, qr/sub chatGPT\s*\{/, 'tellme caller exists');
    $assert->like($external, qr/\$client->submit\(/, 'tellme submits through AI client');
    $assert->like($external, qr/\$client->execute\(\$request\)/, 'tellme keeps same-client sync compatibility');
    $assert->unlike($external, qr/sub _chatgpt_(?:http_request|decode_worker_content|fallback_worthy|transport_request|accept_transport_result|send_and_parse|send_and_parse_async)\b/, 'obsolete OpenAI transport helpers removed');
    $assert->unlike($external, qr/Mediabot::AsyncWorker->start/, 'tellme no longer owns AsyncWorker');
    $assert->like($client, qr/sub submit\s*\{/, 'AI client owns async submission');
    $assert->like($client, qr/label\s*=>\s*'provider-neutral AI request'/, 'shared worker has provider-neutral label');
    $assert->like($client, qr/child\s*=>\s*sub \{ _run_plan\(\$plan, \$http_factory\) \}/, 'worker executes provider plan');
};
