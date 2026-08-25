# t/cases/921_mb699_claude_client_adoption.t
# =============================================================================
# MB699-I — Claude/!ai must use the provider-neutral AI::Client while keeping
# all conversation/social state in the parent Mediabot process.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_921 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_921 {
    my ($src, $sub_name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
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

return sub {
    my ($assert) = @_;

    my $src = _slurp_921(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );
    my $client_src = _slurp_921(
        File::Spec->catfile('.', 'Mediabot', 'AI', 'Client.pm')
    );

    my $ai       = _extract_sub_921($src, 'claudeAI') // '';
    my $build    = _extract_sub_921($src, '_claude_build_client_request') // '';
    my $factory  = _extract_sub_921($src, '_claude_client') // '';
    my $accept   = _extract_sub_921($src, '_claude_accept_client_result') // '';
    my $sync     = _extract_sub_921($src, '_claude_send_and_parse') // '';
    my $async    = _extract_sub_921($src, '_claude_send_and_parse_async') // '';
    my $deliver  = _extract_sub_921($src, '_claude_deliver_answer') // '';

    $assert->like($src, qr/use\s+Mediabot::AI::Client\s*\(\s*\)/,
        'Claude module loads provider-neutral AI::Client');
    $assert->like($src, qr/use\s+Mediabot::AI::Request\s+qw\(build_request\)/,
        'Claude module loads canonical request builder');

    $assert->ok($ai ne '',      'claudeAI body found');
    $assert->ok($build ne '',   'Claude client request builder found');
    $assert->ok($factory ne '', 'Claude AI::Client factory found');
    $assert->ok($accept ne '',  'Claude client-result acceptor found');
    $assert->ok($sync ne '',    'Claude synchronous compatibility adapter found');
    $assert->ok($async ne '',   'Claude asynchronous adapter found');

    $assert->like($build, qr/provider\s*=>\s*'anthropic'/,
        'Claude client request is explicitly Anthropic');
    $assert->like($build, qr/purpose\s*=>\s*'ai'/,
        'Claude request purpose remains ai');
    $assert->like($build, qr/system\s*=>\s*\$p->\{sys_prompt\}/,
        'effective persona/pinned system prompt enters canonical request');
    $assert->like($build, qr/messages\s*=>\s*\$p->\{history\}/,
        'parent-owned conversation history enters canonical request');
    $assert->like($build, qr/max_output_tokens\s*=>\s*\$p->\{max_tokens\}/,
        'historical Anthropic token limit is preserved');
    $assert->like($build, qr/temperature\s*=>\s*\$p->\{temperature\}/,
        'historical Anthropic temperature is preserved');

    $assert->like($factory, qr/Mediabot::AI::Client->new\s*\(/,
        'Claude constructs the common AI client');
    $assert->like($factory, qr/conf\s*=>\s*\$self->\{conf\}/,
        'common client uses normal Mediabot configuration');
    $assert->like($factory, qr/loop_owner\s*=>\s*\$self/,
        'common client receives loop owner for async submission');
    $assert->like($factory, qr/http_factory\s*=>\s*\\&Mediabot::External::_make_http/,
        'common client keeps the verified shared HTTP factory');

    $assert->like($sync, qr/_claude_build_client_request/,
        'sync compatibility path builds canonical request');
    $assert->like($sync, qr/->execute\(\$request\)/,
        'sync compatibility path executes through AI::Client');
    $assert->like($sync, qr/_claude_accept_client_result/,
        'sync compatibility path accepts normalized client result');
    $assert->unlike($sync, qr/_claude_http_request/,
        'sync runtime path no longer calls legacy Anthropic HTTP helper');

    $assert->like($async, qr/_claude_build_client_request/,
        'async runtime path builds canonical request');
    $assert->like($async, qr/->submit\s*\(\s*\$request/s,
        'async runtime path submits through AI::Client');
    $assert->like($async, qr/on_done\s*=>\s*\$client_done/,
        'AI::Client completion returns to parent callback');
    $assert->like($async, qr/_claude_accept_client_result/,
        'async completion accepts normalized result in parent');
    $assert->unlike($async, qr/Mediabot::AsyncWorker->start/,
        'Claude caller no longer owns an AsyncWorker implementation');
    $assert->unlike($async, qr/_claude_http_request/,
        'Claude async caller no longer owns HTTP transport');

    $assert->like($accept, qr/\(\$result->\{provider\}\s*\/\/\s*''\)\s*ne\s*'anthropic'/,
        'Claude refuses an unexpected provider result');
    $assert->like($accept, qr/role\s*=>\s*'assistant'.*content\s*=>\s*\$answer/s,
        'assistant answer is appended to parent-owned history');
    $assert->like($accept, qr/_claude_prompt_cache.*prompt_key/s,
        'prompt cache remains parent-owned after client completion');
    $assert->unlike($accept, qr/content_b64|Authorization|x-api-key|API_KEY/,
        'client-result acceptor has no raw transport or credential dependency');

    $assert->like($ai, qr/_claude_ratelimit/,
        'historical per-conversation rate limiting remains in claudeAI');
    $assert->like($ai, qr/_claude_persona/,
        'historical persona state remains in claudeAI');
    $assert->like($ai, qr/_claude_pinned/,
        'historical pinned context remains in claudeAI');
    $assert->like($ai, qr/_claude_inflight/,
        'historical per-conversation serialization remains in claudeAI');
    $assert->like($ai, qr/rollback orphan user msg in history/,
        'history rollback remains in parent caller');
    $assert->like($deliver, qr/_queue_irc_chunks/,
        'IRC pacing remains parent-owned');

    $assert->like($client_src, qr/last if \(\$plan->\{requested\} \/\/ ''\) ne 'auto'/,
        'explicit Anthropic routing cannot silently cross providers');
};
