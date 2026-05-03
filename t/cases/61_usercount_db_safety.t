# t/cases/61_usercount_db_safety.t
# =============================================================================
# Static regression checks for Helpers::userCount DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_usercount_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_usercount_safety {
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

    my $src  = _slurp_usercount_safety(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $func = _extract_sub_usercount_safety($src, 'userCount');

    $assert->ok(
        $func =~ /SELECT count\(\*\) as nbUser FROM USER/,
        'userCount keeps user count query'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'userCount handles prepare failure'
    );

    $assert->ok(
        $func =~ /userCount\(\) SQL prepare error/,
        'userCount logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\)\)/,
        'userCount handles execute failure'
    );

    $assert->ok(
        $func =~ /userCount\(\) SQL execute error/,
        'userCount logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return 0;/s,
        'userCount finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \$nbUser = 0;/,
        'userCount initializes safe default count'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \$nbUser;/s,
        'userCount finishes statement before final return'
    );
};
