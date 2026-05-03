# t/cases/60_getuserautologin_db_safety.t
# =============================================================================
# Static regression checks for LoginCommands::getUserAutologin DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_getuserautologin_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_getuserautologin_safety {
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

    my $src  = _slurp_getuserautologin_safety(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my $func = _extract_sub_getuserautologin_safety($src, 'getUserAutologin');

    $assert->ok(
        $func =~ /return 0 unless defined\(\$sMatchingUserHandle\) && \$sMatchingUserHandle ne ''/,
        'getUserAutologin rejects empty handle input'
    );

    $assert->ok(
        $func =~ /SELECT 1 FROM USER WHERE nickname = \? AND username = '#AUTOLOGIN#'/,
        'getUserAutologin keeps exact nickname autologin lookup'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'getUserAutologin handles prepare failure'
    );

    $assert->ok(
        $func =~ /getUserAutologin\(\) SQL prepare error/,
        'getUserAutologin logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$sMatchingUserHandle\)\)/,
        'getUserAutologin handles execute failure'
    );

    $assert->ok(
        $func =~ /getUserAutologin\(\) SQL execute error/,
        'getUserAutologin logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return 0;/s,
        'getUserAutologin finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \$ok = \$sth->fetchrow_hashref\(\) \? 1 : 0;/,
        'getUserAutologin stores result before returning'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \$ok;/s,
        'getUserAutologin finishes statement before final return'
    );

    $assert->ok(
        $func !~ /unless \(\$sth->execute\(\$sMatchingUserHandle\)\)/s || $func =~ /unless \(\$sth\)/,
        'getUserAutologin does not execute without checking prepare first'
    );
};
