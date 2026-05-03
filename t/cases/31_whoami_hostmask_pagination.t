# t/cases/31_whoami_hostmask_pagination.t
# =============================================================================
# Static regression checks for whoami/cstat hostmask pagination.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_whoami_hostmask {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_whoami_hostmask {
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

    my $src  = _slurp_whoami_hostmask(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my $func = _extract_sub_whoami_hostmask($src, 'userWhoAmI_ctx');

    $assert->ok(
        $func =~ /SELECT hostmask FROM USER_HOSTMASK/,
        'whoami fetches hostmasks row-by-row'
    );

    $assert->ok(
        $func =~ /LIMIT 20/,
        'whoami limits displayed hostmasks to 20'
    );

    $assert->ok(
        $func =~ /whoami-masks\[%02d\]/,
        'whoami hostmask detail lines are numbered'
    );

    $assert->ok(
        $func =~ /my \$per_line = 2;/,
        'whoami paginates hostmasks at 2 per line'
    );

    $assert->ok(
        $func =~ /Masks: \$mask_count shown, max 20/,
        'whoami has hostmask summary'
    );

    $assert->ok(
        $func !~ /GROUP_CONCAT\(hostmask/,
        'whoami no longer GROUP_CONCATs all hostmasks into one line'
    );

    $assert->ok(
        $func !~ /Masks: \$hostmasks/,
        'whoami no longer injects all masks into the status line'
    );
};
