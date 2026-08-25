# t/cases/859_mb675_claude_async_transport.t
# Historical async Claude guarantee: runtime I/O stays off the IRC loop. Since
# MB699-I worker lifecycle is owned by provider-neutral AI::Client.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _s859 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
return sub {
    my($assert)=@_;
    my $external=_s859(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $client=_s859(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    my $transport=_s859(File::Spec->catfile('.','Mediabot','AI','Transport.pm'));
    $assert->like($external, qr/sub _claude_send_and_parse_async\s*\{/, 'Claude async adapter retained');
    $assert->like($external, qr/\$client->submit\(\s*\$request/s, 'Claude async path submits to AI client');
    $assert->unlike($external, qr/Mediabot::AsyncWorker->start/, 'Claude caller no longer owns worker lifecycle');
    $assert->like($client, qr/require Mediabot::AsyncWorker/, 'AI client lazily loads shared worker');
    $assert->like($client, qr/return Mediabot::AsyncWorker->start\(%args\)/, 'AI client owns worker launch');
    $assert->like($client, qr/child\s*=>\s*sub \{ _run_plan\(\$plan, \$http_factory\) \}/, 'provider plan executes inside worker');
    $assert->like($transport, qr/sub usable_loop\s*\{/, 'shared loop capability detection retained');
    $assert->like($external, qr/_claude_inflight/, 'per-conversation in-flight serialization remains parent-owned');
    $assert->like($external, qr/rollback orphan user msg in history/, 'history rollback remains parent-owned');
};
