# t/cases/197_partyline_login_no_password_select.t
# =============================================================================
# Regression checks for Partyline::_do_login().
#
# Partyline login should not SELECT or carry the password/hash value directly.
# It should delegate credential checks to Mediabot::Auth::verify_credentials().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_197 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_197 {
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

    my $partyline = _slurp_197(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    my $auth = _slurp_197(
        File::Spec->catfile('.', 'Mediabot', 'Auth.pm')
    );

    my $body = _extract_sub_body_197($partyline, '_do_login');

    $assert->ok(defined $body, '_do_login body found');

    $assert->like(
        $body // '',
        qr/SELECT u\.id_user, u\.nickname, ul\.level, ul\.description/,
        '_do_login selects user identity and level only'
    );

    $assert->like(
        $body // '',
        qr/\$bot->\{auth\}->verify_credentials\(\$row->\{id_user\}, \$login, \$password\)/,
        '_do_login delegates password validation to Mediabot::Auth'
    );

    $assert->like(
        $body // '',
        qr/Access denied: Master level or above required\./,
        '_do_login still enforces Partyline minimum level'
    );

    $assert->unlike(
        $body // '',
        qr/u\.password/,
        '_do_login no longer SELECTs u.password'
    );

    $assert->unlike(
        $body // '',
        qr/\$row->\{password\}/,
        '_do_login no longer reads password from fetched row'
    );

    $assert->like(
        $auth,
        qr/SELECT id_user, nickname, password FROM USER WHERE/,
        'Mediabot::Auth still owns password lookup for credential checks'
    );

    $assert->like(
        $auth,
        qr/sub verify_credentials/,
        'Mediabot::Auth::verify_credentials remains the credential-checking path'
    );
};
