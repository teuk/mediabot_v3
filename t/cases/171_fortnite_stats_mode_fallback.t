# t/cases/171_fortnite_stats_mode_fallback.t
# =============================================================================
# Regression checks for fortniteStats_ctx() stats selection.
#
# Prefer stats.all.overall, but if the API payload has no overall stats, fall
# back to the first available mode stats: solo, duo, trio, squad.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_fortnite_mode_fallback {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_fortnite_mode_fallback {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_fortnite_mode_fallback(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_fortnite_mode_fallback($src, 'fortniteStats_ctx');

    $assert->ok(
        defined $body,
        'fortniteStats_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \$overall = \{\};/,
        'fortniteStats_ctx defaults overall stats to an empty hash'
    );

    $assert->like(
        $body // '',
        qr/if \(ref\(\$all_stats->\{overall\}\) eq 'HASH'\) \{/,
        'fortniteStats_ctx prefers stats.all.overall'
    );

    $assert->like(
        $body // '',
        qr/for my \$mode \(qw\(solo duo trio squad\)\)/,
        'fortniteStats_ctx falls back through solo/duo/trio/squad modes'
    );

    $assert->like(
        $body // '',
        qr/next unless ref\(\$all_stats->\{\$mode\}\) eq 'HASH';/,
        'fortniteStats_ctx checks each fallback mode before using it'
    );

    $assert->like(
        $body // '',
        qr/\$overall = \$all_stats->\{\$mode\};/,
        'fortniteStats_ctx assigns first available mode stats'
    );

    $assert->unlike(
        $body // '',
        qr/ref\(\$all_stats->\{overall\}\) eq 'HASH'\s+&&\s+ref\(\$all_stats->\{overall\}\{solo\}\) eq 'HASH'/s,
        'fortniteStats_ctx no longer contains the unreachable overall.solo fallback'
    );

    $assert->unlike(
        $body // '',
        qr/\$payload->\{stats\}\{all\}\{overall\}/,
        'fortniteStats_ctx still avoids direct unsafe stats dereferencing'
    );
};
