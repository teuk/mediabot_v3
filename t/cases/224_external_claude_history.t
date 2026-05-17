# t/cases/224_external_claude_history.t
# =============================================================================
# Verify claudeAI() maintains per-nick conversation history (P2).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_224 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_224 {
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

    my $src = _slurp_224(File::Spec->catfile('.', 'Mediabot', 'External.pm'));

    my $ai_body    = _extract_sub_224($src, 'claudeAI');
    my $ctx_body   = _extract_sub_224($src, 'claude_ctx');

    $assert->ok(defined $ai_body  && $ai_body  ne '', 'claudeAI body found');
    $assert->ok(defined $ctx_body && $ctx_body ne '', 'claude_ctx body found');

    # History storage
    $assert->like($ai_body // '', qr/_claude_history/,
        'claudeAI accesses _claude_history');

    $assert->like($ai_body // '', qr/role.*user.*content.*prompt/s,
        'claudeAI pushes user message into history');

    $assert->like($ai_body // '', qr/role.*assistant.*content.*answer/s,
        'claudeAI stores assistant reply in history');

    # History cap
    $assert->like($ai_body // '', qr/splice.*history.*6|history.*6/,
        'claudeAI caps history at 6 messages');

    # Reset command in claude_ctx
    $assert->like($ctx_body // '', qr/reset/i,
        'claude_ctx handles !ai reset subcommand');

    $assert->like($ctx_body // '', qr/delete.*_claude_history/,
        'claude_ctx clears history on reset');

    # Messages sent as array (not single object)
    $assert->like($ai_body // '', qr/messages\s*=>\s*\$history/,
        'claudeAI sends full history array as messages');
};
