# t/cases/23_legacy_auth_hash_safety.t
# =============================================================================
# Static regression checks for legacy auth hash safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_legacy_auth_hash {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_legacy_auth_hash {
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

    my $src = _slurp_legacy_auth_hash(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));

    my $user_pass = _extract_sub_legacy_auth_hash($src, 'userPass');
    my $ident     = _extract_sub_legacy_auth_hash($src, 'checkAuthByUser');

    $assert->ok(
        $user_pass =~ /my \$hash_ok = eval \{/,
        'userPass protects make_password_hash with eval'
    );

    $assert->ok(
        $user_pass =~ /userPass\(\) make_password_hash failed/,
        'userPass logs password hash failures'
    );

    $assert->ok(
        $user_pass =~ /Internal error \(hash compute failed\)/,
        'userPass reports hash failure cleanly'
    );

    $assert->ok(
        $ident =~ /my \$hash_ok = eval \{/,
        'checkAuthByUser protects make_password_hash with eval'
    );

    $assert->ok(
        $ident =~ /checkAuthByUser\(\) make_password_hash failed/,
        'checkAuthByUser logs password hash failures'
    );

    $assert->ok(
        $ident =~ /\$sth->finish;\s*return \(\$id_user,0\);/s,
        'checkAuthByUser finishes main statement before success return'
    );

    $assert->ok(
        $ident =~ /\$chk->finish;\s*\$sth->finish;\s*return \(\$id_user, 1\);/s,
        'checkAuthByUser finishes main statement before existing-hostmask success return'
    );

    $assert->ok(
        $ident =~ /\$ins->finish if \$ins;\s*\$sth->finish if \$sth;\s*return \(0,0\);/s,
        'checkAuthByUser finishes statements on insert error'
    );

    $assert->ok(
        $user_pass !~ /my \$sHashedNewPw = make_password_hash\(\$sNewPassword\);/,
        'userPass no longer uses direct make_password_hash assignment'
    );

    $assert->ok(
        $ident !~ /my \$sHashedPw = make_password_hash\(\$sPassword\);/,
        'checkAuthByUser no longer uses direct make_password_hash assignment'
    );
};
