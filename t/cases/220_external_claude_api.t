# t/cases/220_external_claude_api.t
# =============================================================================
# Verify claudeAI() uses Anthropic API format, not OpenAI format (S4).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_220 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_220 {
    my ($src, $sub_name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = $-[0]; my $pos = pos($src); my $depth = 1;
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{'; $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_220(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));

    $assert->like($src, qr/sub claude_ctx/,  'claude_ctx sub exists');
    $assert->like($src, qr/sub claudeAI/,    'claudeAI sub exists');

    my $body = _extract_sub_220($src, 'claudeAI');
    my $send = _extract_sub_220($src, '_claude_send_and_parse');
    my $http = _extract_sub_220($src, '_claude_http_request');
    my $parse = _extract_sub_220($src, '_claude_extract_answer');
    $assert->ok(defined $body && $body ne '', 'claudeAI body found');
    $assert->ok(defined $send && $send ne '', '_claude_send_and_parse body found');
    $assert->ok(defined $http && $http ne '', '_claude_http_request body found');
    $assert->ok(defined $parse && $parse ne '', '_claude_extract_answer body found');

    # Must use Anthropic headers, not OpenAI
    $assert->like($http // '', qr/x-api-key/,
        'claudeAI uses x-api-key header (Anthropic)');

    $assert->like($http // '', qr/anthropic-version/,
        'claudeAI sends anthropic-version header');

    $assert->unlike($http // '', qr/Authorization.*Bearer/,
        'claudeAI does not use Bearer token (OpenAI pattern)');

    # Response parsing must use content[0]{text}
    $assert->like($parse // '', qr/for my \$blk .*content/s,
        'Claude parser iterates Anthropic content blocks');

    $assert->unlike($parse // '', qr/choices.*\[0\].*message/,
        'claudeAI does not use OpenAI choices structure');

    # Must use anthropic.API_KEY config key
    $assert->like($body // '', qr/anthropic\.API_KEY/,
        'claudeAI reads anthropic.API_KEY from config');

    # Constants
    $assert->like($src, qr/CLAUDE_API_URL/,   'CLAUDE_API_URL constant defined');
    $assert->like($src, qr/CLAUDE_MODEL/,      'CLAUDE_MODEL constant defined');
    $assert->like($src, qr/CLAUDE_MAX_TOKENS/, 'CLAUDE_MAX_TOKENS constant defined');
};
