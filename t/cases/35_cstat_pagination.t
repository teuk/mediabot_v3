# t/cases/35_cstat_pagination.t
# =============================================================================
# Static regression checks for cstat authenticated users pagination.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_cstat_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_cstat_pagination {
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

    my $src  = _slurp_cstat_pagination(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $func = _extract_sub_cstat_pagination($src, 'userCstat_ctx');

    $assert->ok(
        $func =~ /Authenticated users: \$count result\(s\)/,
        'cstat has summary line'
    );

    $assert->ok(
        $func =~ /Authenticated users: none/,
        'cstat handles empty authenticated user list'
    );

    $assert->ok(
        $func =~ /my \$per_line = 5;/,
        'cstat paginates at 5 users per line'
    );

    $assert->ok(
        $func =~ /cstat\[%02d\]/,
        'cstat detail lines are numbered'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'cstat sends paginated details by notice'
    );

    $assert->ok(
        $func =~ /ORDER BY USER_LEVEL\.level, USER\.nickname/,
        'cstat output is sorted by level then nickname'
    );

    $assert->ok(
        $func !~ /Keep it one line/,
        'cstat old one-line truncation comment is gone'
    );

    $assert->ok(
        $func !~ /my \$max = 380/,
        'cstat no longer uses old max length truncation'
    );

    $assert->ok(
        $func !~ /Authenticated users: ' \. join/,
        'cstat no longer builds one huge authenticated users line'
    );
};
