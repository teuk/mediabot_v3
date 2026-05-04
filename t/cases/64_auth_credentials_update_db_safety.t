# t/cases/64_auth_credentials_update_db_safety.t
# =============================================================================
# Static regression checks for Auth credential/autologin DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_auth_credentials_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_auth_credentials_safety {
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

    my $src    = _slurp_auth_credentials_safety(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));
    my $verify = _extract_sub_auth_credentials_safety($src, 'verify_credentials');
    my $auto   = _extract_sub_auth_credentials_safety($src, 'maybe_autologin');

    $assert->ok(
        $verify =~ /unless \(\$dbh\)/,
        'verify_credentials handles missing DB handle'
    );

    $assert->ok(
        $verify =~ /unless \(defined\(\$user_id_or_nick\) && \$user_id_or_nick ne ''\)/,
        'verify_credentials rejects empty lookup key'
    );

    $assert->ok(
        $verify =~ /unless \(\$sth\)/,
        'verify_credentials handles prepare failure'
    );

    $assert->ok(
        $verify =~ /verify_credentials: DB prepare error/,
        'verify_credentials logs prepare failure'
    );

    $assert->ok(
        $verify =~ /unless \(\$sth->execute\(\$val\)\)/,
        'verify_credentials handles execute failure'
    );

    $assert->ok(
        $verify =~ /\$sth->finish;\s*return 0;/s,
        'verify_credentials finishes statement on execute failure'
    );

    $assert->ok(
        $verify =~ /\$sth->finish;\s*unless \(\$row\)/s,
        'verify_credentials finishes statement before row handling'
    );

    $assert->ok(
        $verify !~ /eval\s*\{\s*my \$sth = \$dbh->prepare/s,
        'verify_credentials no longer wraps unchecked DB calls in eval'
    );

    $assert->ok(
        $auto =~ /unless \(\$dbh\)/,
        'maybe_autologin handles missing DB handle'
    );

    $assert->ok(
        $auto =~ /my \$sql_update = "UPDATE USER SET auth=1, last_login=NOW\(\) WHERE id_user=\?"/,
        'maybe_autologin keeps auth update query'
    );

    $assert->ok(
        $auto =~ /unless \(\$sth\)/,
        'maybe_autologin update handles prepare failure'
    );

    $assert->ok(
        $auto =~ /db_update_prepare_failed/,
        'maybe_autologin returns explicit prepare failure reason'
    );

    $assert->ok(
        $auto =~ /unless \(\$sth->execute\(\$uid\)\)/,
        'maybe_autologin update handles execute failure'
    );

    $assert->ok(
        $auto =~ /\$sth->finish;\s*return \(0, "db_update_execute_failed"\);/s,
        'maybe_autologin finishes statement on execute failure'
    );

    $assert->ok(
        $auto =~ /my \$rows = \$sth->rows;\s*\$sth->finish;/s,
        'maybe_autologin stores row count then finishes statement'
    );

    $assert->ok(
        $auto !~ /eval\s*\{\s*my \$sth = \$dbh->prepare\("UPDATE USER SET auth=1/s,
        'maybe_autologin no longer wraps unchecked update in eval'
    );
};
