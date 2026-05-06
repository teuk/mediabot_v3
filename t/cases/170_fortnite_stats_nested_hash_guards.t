# t/cases/170_fortnite_stats_nested_hash_guards.t
# =============================================================================
# Regression checks for fortniteStats_ctx().
#
# Fortnite API responses can be valid JSON but missing nested structures such
# as data.stats.all.overall. fortniteStats_ctx() must guard each level before
# dereferencing it.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_fortnite_nested_guards {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_fortnite_nested_guards {
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

    my $src = _slurp_fortnite_nested_guards(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_fortnite_nested_guards($src, 'fortniteStats_ctx');

    $assert->ok(
        defined $body,
        'fortniteStats_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \$account\s+= ref\(\$payload->\{account\}\)\s+eq 'HASH' \? \$payload->\{account\}\s+: \{\};/,
        'fortniteStats_ctx guards account hash'
    );

    $assert->like(
        $body // '',
        qr/my \$battlepass\s+= ref\(\$payload->\{battlePass\}\) eq 'HASH' \? \$payload->\{battlePass\} : \{\};/,
        'fortniteStats_ctx guards battlePass hash'
    );

    $assert->like(
        $body // '',
        qr/my \$stats\s+= ref\(\$payload->\{stats\}\)\s+eq 'HASH' \? \$payload->\{stats\}\s+: \{\};/,
        'fortniteStats_ctx guards stats hash'
    );

    $assert->like(
        $body // '',
        qr/my \$all_stats\s+= ref\(\$stats->\{all\}\)\s+eq 'HASH' \? \$stats->\{all\}\s+: \{\};/,
        'fortniteStats_ctx guards stats.all hash'
    );

    $assert->like(
        $body // '',
        qr/my \$overall = \{\};/,
        'fortniteStats_ctx defaults overall stats to an empty hash'
    );

    $assert->like(
        $body // '',
        qr/if \(ref\(\$all_stats->\{overall\}\) eq 'HASH'\)/,
        'fortniteStats_ctx checks overall before using it'
    );

    $assert->unlike(
        $body // '',
        qr/\$payload->\{stats\}\{all\}\{overall\}/,
        'fortniteStats_ctx no longer directly dereferences payload.stats.all.overall'
    );

    $assert->unlike(
        $body // '',
        qr/my \$account\s+= \$payload->\{account\}\s+\|\| \{\};/,
        'fortniteStats_ctx no longer trusts account blindly'
    );
};
