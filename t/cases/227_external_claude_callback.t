# t/cases/227_external_claude_callback.t
# =============================================================================
# Verify claudeAI() accepts an optional output_fn callback (R1).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_227 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_227 {
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

    my $src      = _slurp_227(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $pl_src   = _slurp_227(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $ai_body  = _extract_sub_227($src, 'claudeAI');
    my $pl_body  = _extract_sub_227($pl_src, '_cmd_ai');

    $assert->ok(defined $ai_body && $ai_body ne '', 'claudeAI body found');

    # R1: callback detection
    $assert->like($ai_body // '', qr/ref.*output_fn.*CODE|ref.*args.*CODE/s,
        'claudeAI detects CODE ref as output_fn');

    $assert->like($ai_body // '', qr/my \$_out\s*=/,
        'claudeAI defines $_out dispatcher');

    # $_out used instead of direct botPrivmsg for output
    $assert->like($ai_body // '', qr/\$_out->.*chunk/,
        'claudeAI sends chunks via $_out');

    # Partyline _cmd_ai uses callback — no monkey-patch
    $assert->ok(defined $pl_body && $pl_body ne '', '_cmd_ai (Partyline) body found');

    $assert->like($pl_body // '', qr/output_fn|R1/,
        'Partyline _cmd_ai uses output_fn callback (R1 pattern)');

    $assert->unlike($pl_body // '', qr/local \\*.*botPrivmsg/,
        'Partyline _cmd_ai no longer monkey-patches botPrivmsg');
};
