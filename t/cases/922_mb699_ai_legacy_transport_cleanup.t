# t/cases/922_mb699_ai_legacy_transport_cleanup.t
# =============================================================================
# MB699-J — after live proof of both historical callers through AI::Client,
# obsolete provider transport helpers must not remain as a second code path.
# =============================================================================
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _s922 { my($p)=@_; open my$f,'<:raw',$p or die$!; local$/; <$f> }
sub _sub922 {
    my($s,$name)=@_;
    return '' unless $s =~ /(?m)^sub\s+\Q$name\E\s*\{/g;
    my $start=$-[0]; my $pos=pos($s); my $d=1;
    while($pos<length$s){ my$c=substr($s,$pos,1); $d++ if$c eq'{'; $d-- if$c eq'}'; return substr($s,$start,$pos+1-$start) if !$d; $pos++; }
    return '';
}

return sub {
    my($assert)=@_;
    my $external=_s922(File::Spec->catfile('.','Mediabot','External','Claude.pm'));
    my $client=_s922(File::Spec->catfile('.','Mediabot','AI','Client.pm'));
    my $chatgpt=_sub922($external,'chatGPT');
    my $claude=_sub922($external,'claudeAI');

    my @dead = qw(
        _chatgpt_http_request
        _chatgpt_decode_worker_content
        _chatgpt_fallback_worthy
        _chatgpt_transport_request
        _chatgpt_accept_transport_result
        _chatgpt_send_and_parse
        _chatgpt_send_and_parse_async
        _claude_build_payload
        _claude_http_request
        _claude_extract_answer
        _claude_accept_http_result
    );
    for my $name (@dead) {
        $assert->unlike($external, qr/^sub\s+\Q$name\E\b/m, "mb699-922: obsolete helper $name removed");
    }

    $assert->unlike($external, qr/use\s+Mediabot::AsyncWorker\b/, 'caller no longer imports AsyncWorker');
    $assert->unlike($external, qr/use\s+Mediabot::AI::Provider::Anthropic\b/, 'caller no longer imports Anthropic wire adapter');
    $assert->like($external, qr/use\s+Mediabot::AI::Client\s*\(\s*\)/, 'caller keeps common AI client');
    $assert->like($external, qr/use\s+Mediabot::AI::Transport\s*\(\s*\)/, 'caller keeps only loop capability helper from shared transport');

    $assert->like($chatgpt, qr/\$client->submit\(/, 'tellme production path uses AI client');
    $assert->like($chatgpt, qr/\$client->execute\(\$request\)/, 'tellme sync compatibility uses same AI client');
    $assert->like($claude, qr/_claude_send_and_parse_async/, 'Claude production path uses client-backed async adapter');
    $assert->like($claude, qr/_claude_send_and_parse\(/, 'Claude no-loop compatibility uses client-backed sync adapter');

    $assert->unlike($claude, qr/api_url\s*=>|api_key\s*=>|api_version\s*=>/, 'Claude parent request state carries no provider transport credentials/config');
    $assert->like($client, qr/require Mediabot::AsyncWorker/, 'AI client is sole worker owner');
    $assert->like($client, qr/Mediabot::AI::Transport::post_json\(/, 'AI client is sole provider HTTP transport caller');
};
