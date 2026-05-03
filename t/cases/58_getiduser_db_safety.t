# t/cases/58_getiduser_db_safety.t
# =============================================================================
# Static regression checks for Helpers::getIdUser DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_getiduser_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_getiduser_safety {
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

    my $src  = _slurp_getiduser_safety(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $func = _extract_sub_getiduser_safety($src, 'getIdUser');

    $assert->ok(
        $func =~ /return undef unless defined\(\$sUserhandle\) && \$sUserhandle ne ''/,
        'getIdUser rejects empty user handle input'
    );

    $assert->ok(
        $func =~ /SELECT id_user FROM USER WHERE nickname = \?/,
        'getIdUser uses exact nickname lookup'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'getIdUser handles prepare failure'
    );

    $assert->ok(
        $func =~ /getIdUser\(\) SQL prepare error/,
        'getIdUser logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$sUserhandle\)\)/,
        'getIdUser handles execute failure'
    );

    $assert->ok(
        $func =~ /getIdUser\(\) SQL execute error/,
        'getIdUser logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return undef;/s,
        'getIdUser finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \$id_user;/,
        'getIdUser stores result before returning'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \$id_user;/s,
        'getIdUser finishes statement before final return'
    );
};
