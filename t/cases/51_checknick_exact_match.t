# t/cases/51_checknick_exact_match.t
# =============================================================================
# Static regression checks for checknick exact lookup.
#
# checknick <nick> inspects one nick. It must not interpret '%' or '_' as SQL
# wildcards.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_checknick_exact {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_checknick_exact {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_checknick_exact(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $func = _extract_sub_checknick_exact($src, 'mbDbCheckNickHostname_ctx');

    $assert->ok(
        $func =~ /WHERE nick = \?/,
        'checknick uses exact nick lookup'
    );

    $assert->ok(
        $func !~ /WHERE nick LIKE \?/,
        'checknick no longer uses nick LIKE'
    );

    $assert->ok(
        $func !~ /\$use_like/,
        'checknick no longer has wildcard branch'
    );

    $assert->ok(
        $func =~ /checknick is not a wildcard search command/,
        'checknick documents literal % and _ behavior'
    );

    $assert->ok(
        $func =~ /LIMIT 10/,
        'checknick still limits hostmask results to 10'
    );

    $assert->ok(
        $func =~ /checknick\[%02d\]/,
        'checknick pagination remains present'
    );
};
