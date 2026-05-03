# t/cases/34_partyline_match_hostmask_pagination.t
# =============================================================================
# Static regression checks for Partyline .match hostmask pagination.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_partyline_match {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_partyline_match {
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

    my $src  = _slurp_partyline_match(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $func = _extract_sub_partyline_match($src, '_cmd_match');

    $assert->ok(
        $func =~ /WHERE u\.nickname LIKE \? ESCAPE '!'/,
        q{.match uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$sql_pat =~ s\/!\/!!\/g/,
        '.match escapes LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$sql_pat =~ s\/%\/!%\/g/,
        '.match escapes literal percent before wildcard conversion'
    );

    $assert->ok(
        $func =~ /\$sql_pat =~ s\/_\/!_\/g/,
        '.match escapes literal underscore before wildcard conversion'
    );

    $assert->ok(
        $func =~ /SELECT hostmask/,
        '.match fetches hostmasks row-by-row'
    );

    $assert->ok(
        $func =~ /LIMIT 20/,
        '.match limits displayed hostmasks to 20'
    );

    $assert->ok(
        $func =~ /Hosts\[%02d\]/,
        '.match hostmask detail lines are numbered'
    );

    $assert->ok(
        $func =~ /my \$per_line = 2;/,
        '.match paginates hostmasks at 2 per line'
    );

    $assert->ok(
        $func !~ /GROUP_CONCAT\(uh\.hostmask/,
        '.match no longer GROUP_CONCATs all hostmasks'
    );

    $assert->ok(
        $func !~ /Hosts\s+: %s/,
        '.match no longer writes all hostmasks on one line'
    );
};
