# t/cases/198_userlogin_delegates_password_check_to_auth.t
# =============================================================================
# Regression checks for userLogin_ctx().
#
# The IRC login command should not SELECT or compare the password/hash directly.
# It should fetch identity/level/has_password, then delegate credential checking
# to Mediabot::Auth::verify_credentials().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_198 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_198 {
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

    my $login = _slurp_198(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $auth = _slurp_198(
        File::Spec->catfile('.', 'Mediabot', 'Auth.pm')
    );

    my $body = _extract_sub_body_198($login, 'userLogin_ctx');

    $assert->ok(defined $body, 'userLogin_ctx body found');

    $assert->like(
        $body // '',
        qr/CASE\s+WHEN password IS NOT NULL AND password <> '' THEN 1\s+ELSE 0\s+END AS has_password/s,
        'userLogin_ctx selects has_password boolean'
    );

    $assert->like(
        $body // '',
        qr/my \$has_password = defined\(\$row->\{has_password\}\) \? int\(\$row->\{has_password\}\) : 0;/,
        'userLogin_ctx reads has_password safely'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{auth\}->verify_credentials\(\$id_user, \$db_nick, \$typed_pass\)/,
        'userLogin_ctx delegates credential check to Mediabot::Auth'
    );

    $assert->like(
        $body // '',
        qr/Auth module unavailable/,
        'userLogin_ctx guards missing Auth module'
    );

    $assert->like(
        $body // '',
        qr/Your password is not set\./,
        'userLogin_ctx still reports unset password'
    );

    $assert->like(
        $body // '',
        qr/Login failed \(Bad password\)\./,
        'userLogin_ctx still reports bad password'
    );

    $assert->unlike(
        $body // '',
        qr/SELECT id_user, nickname, password, id_user_level/,
        'userLogin_ctx no longer SELECTs password directly'
    );

    $assert->unlike(
        $body // '',
        qr/\$row->\{password\}/,
        'userLogin_ctx no longer reads password from fetched row'
    );

    $assert->unlike(
        $body // '',
        qr/make_password_hash\(\$typed_pass\)/,
        'userLogin_ctx no longer computes password hash directly'
    );

    $assert->unlike(
        $body // '',
        qr/\$stored_hash eq \$calc_hash/,
        'userLogin_ctx no longer compares hashes directly'
    );

    $assert->like(
        $auth,
        qr/sub verify_credentials/,
        'Mediabot::Auth::verify_credentials exists'
    );

    $assert->like(
        $auth,
        qr/SELECT id_user, nickname, password FROM USER WHERE/,
        'Mediabot::Auth remains the password lookup owner'
    );
};
