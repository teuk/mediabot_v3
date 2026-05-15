# t/cases/226_external_claude_ratelimit.t
# =============================================================================
# Verify claudeAI() has per-nick rate limiting (R2).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_226 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_226 {
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

    my $src  = _slurp_226(File::Spec->catfile('.', 'Mediabot', 'External.pm'));
    my $body = _extract_sub_226($src, 'claudeAI');

    $assert->ok(defined $body && $body ne '', 'claudeAI body found');

    $assert->like($body // '', qr/_claude_ratelimit/,
        'claudeAI uses _claude_ratelimit hash');

    $assert->like($body // '', qr/Rate limit/,
        'claudeAI sends rate limit notice to user');

    # Window of 60 seconds
    $assert->like($body // '', qr/60/,
        'claudeAI uses 60-second rate limit window');

    # Skipped for Partyline (output_fn set)
    $assert->like($body // '', qr/unless.*output_fn/,
        'claudeAI skips rate limit when output_fn callback is set (Partyline)');

    # Prometheus metric
    $assert->like($body // '', qr/claude_ratelimit_total/,
        'claudeAI increments claude_ratelimit_total metric');
};
