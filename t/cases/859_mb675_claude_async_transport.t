# t/cases/859_mb675_claude_async_transport.t
# =============================================================================
# MB675 — Anthropic transport must not block the production IO::Async loop.
#
# The public/PM/summary/Partyline Claude paths all converge on claudeAI().
# Production runtime must launch only the HTTP transport in AsyncWorker while
# keeping history, cache, metrics and output callbacks in the parent process.
# The historical synchronous adapter remains only as a no-loop compatibility
# fallback for lightweight contexts.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_859 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_859 {
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

    my $src = _slurp_859(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $ai      = _extract_sub_859($src, 'claudeAI') // '';
    my $can     = _extract_sub_859($src, '_claude_can_async') // '';
    my $async   = _extract_sub_859($src, '_claude_send_and_parse_async') // '';
    my $sync    = _extract_sub_859($src, '_claude_send_and_parse') // '';
    my $http    = _extract_sub_859($src, '_claude_http_request') // '';
    my $accept  = _extract_sub_859($src, '_claude_accept_http_result') // '';
    my $deliver = _extract_sub_859($src, '_claude_deliver_answer') // '';

    $assert->like($src, qr/use\s+Mediabot::AsyncWorker\s*\(\s*\)/,
        'Claude module loads shared AsyncWorker');

    $assert->ok($ai ne '',      'claudeAI body found');
    $assert->ok($can ne '',     '_claude_can_async body found');
    $assert->ok($async ne '',   '_claude_send_and_parse_async body found');
    $assert->ok($sync ne '',    '_claude_send_and_parse sync fallback found');
    $assert->ok($http ne '',    '_claude_http_request body found');
    $assert->ok($accept ne '',  '_claude_accept_http_result body found');
    $assert->ok($deliver ne '', '_claude_deliver_answer body found');

    # Production dispatch chooses async whenever a real loop is present.
    $assert->like($ai, qr/my\s+\$use_async\s*=\s*_claude_can_async\(\$self\)/,
        'claudeAI resolves async capability before transport');
    $assert->like($ai, qr/if\s*\(\$use_async\)\s*\{.*?_claude_send_and_parse_async/s,
        'production claudeAI path calls async transport');
    $assert->unlike($ai, qr/_make_http\s*\(/,
        'claudeAI itself performs no HTTP construction');
    $assert->unlike($ai, qr/->request\s*\(/,
        'claudeAI itself performs no blocking HTTP request');

    # Async execution makes concurrency possible; preserve old serialized
    # conversation semantics explicitly.
    $assert->like($ai, qr/_claude_inflight.*\$hist_key/s,
        'per-conversation in-flight guard exists');
    $assert->like($ai, qr/Claude is already processing a request/,
        'concurrent prompt receives explicit busy feedback');
    $assert->like($ai, qr/delete\s+\$self->\{_claude_inflight\}\{\$hist_key\}/,
        'in-flight guard is released by completion');

    my $busy_pos = index($ai, '_claude_inflight');
    my $rate_pos = index($ai, '_claude_ratelimit');
    $assert->ok($busy_pos >= 0 && $rate_pos >= 0 && $busy_pos < $rate_pos,
        'busy rejection does not consume rate-limit quota');

    # Event-loop capability contract mirrors AsyncWorker requirements.
    $assert->like($can, qr/can\('add'\)/,
        'async capability requires loop add');
    $assert->like($can, qr/can\('remove'\)/,
        'async capability requires loop remove');
    $assert->like($can, qr/can\('watch_process'\)/,
        'async capability requires loop watch_process');

    # Worker lifecycle is bounded and shared with the rest of Mediabot.
    $assert->like($async, qr/Mediabot::AsyncWorker->start\s*\(/,
        'Claude uses shared AsyncWorker lifecycle');
    $assert->like($async, qr/label\s*=>\s*'claude anthropic request'/,
        'worker has a diagnostic label');
    $assert->like($async, qr/timeout\s*=>\s*32/,
        'worker timeout bounds 30s HTTP transport');
    $assert->like($async, qr/max_output\s*=>\s*128\s*\*\s*1024/,
        'worker output is bounded');
    $assert->like($async,
        qr/child\s*=>\s*sub\s*\{\s*return\s+_claude_http_request\(\\%transport,\s*\$payload\)/s,
        'child performs only scalar Anthropic transport');
    $assert->like($async, qr/on_done\s*=>\s*\$worker_done/,
        'worker completion returns to parent callback');
    $assert->like($async, qr/_claude_accept_http_result\s*\(\s*\$self/s,
        'response/history processing happens in parent completion');

    # Child transport does not receive the bot object. This is the key state
    # boundary: no child-side history/cache/IRC mutation can leak from a fork.
    $assert->like($http, qr/my\s*\(\$transport,\s*\$payload\)\s*=\s*\@_/,
        'HTTP helper accepts transport scalars, not bot state');
    $assert->unlike($http, qr/\$self/,
        'HTTP worker helper does not touch bot object');
    $assert->like($http, qr/x-api-key/,
        'worker preserves Anthropic API key header');
    $assert->like($http, qr/anthropic-version/,
        'worker preserves Anthropic version header');
    $assert->like($http, qr/encode_base64\s*\(\$content/,
        'worker transports response bytes safely through JSON protocol');

    # Parent completion owns semantic state exactly as before.
    $assert->like($accept, qr/decode_base64/,
        'parent restores raw Anthropic response bytes');
    $assert->like($accept, qr/_claude_extract_answer/,
        'parent parses Anthropic content blocks');
    $assert->like($accept, qr/role\s*=>\s*'assistant'.*content\s*=>\s*\$answer/s,
        'assistant answer is appended to parent history');
    $assert->like($accept, qr/_claude_prompt_cache.*prompt_key/s,
        'prompt cache is updated in parent');

    # Both sync compatibility and async runtime share the same HTTP/parser
    # primitives, avoiding two divergent Claude semantics.
    $assert->like($sync, qr/_claude_http_request/,
        'sync fallback shares HTTP transport helper');
    $assert->like($sync, qr/_claude_accept_http_result/,
        'sync fallback shares parent response parser');

    $assert->like($deliver, qr/_queue_irc_chunks/,
        'IRC answer pacing remains nonblocking after async completion');
    $assert->like($deliver, qr/_claude_emit/,
        'callback/Partyline output still uses parent emitter');
    $assert->like($deliver, qr/mediabot_claude_requests_total/,
        'success metric remains parent-owned');

    # Failure still rolls back the user message rather than leaving malformed
    # user,user history for the next Anthropic request.
    $assert->like($ai, qr/rollback orphan user msg in history/,
        'orphan user rollback remains present');
    $assert->like($ai, qr/\$state\s+eq\s+'failure'.*\$rollback_orphan->\(\)/s,
        'async failures trigger history rollback');
};
