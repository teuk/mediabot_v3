# t/cases/193_whoami_does_not_select_password.t
# =============================================================================
# Regression checks for userWhoAmI_ctx().
#
# whoami should report whether a password exists, but it should not SELECT or
# load the password/hash value itself. It should use a boolean has_password
# value instead.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_193 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_193 {
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

    my $src = _slurp_193(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $body = _extract_sub_body_193($src, 'userWhoAmI_ctx');

    $assert->ok(defined $body, 'userWhoAmI_ctx body found');

    $assert->like(
        $body // '',
        qr/CASE\s+WHEN password IS NOT NULL AND password <> '' THEN 1\s+ELSE 0\s+END AS has_password/s,
        'userWhoAmI_ctx selects a has_password boolean'
    );

    $assert->like(
        $body // '',
        qr/my \$has_password = defined\(\$ref->\{has_password\}\) \? int\(\$ref->\{has_password\}\) : 0;/,
        'userWhoAmI_ctx reads has_password safely'
    );

    $assert->like(
        $body // '',
        qr/my \$pass_set\s+= \$has_password \? "Password set" : "Password not set";/,
        'userWhoAmI_ctx reports pass flag from has_password'
    );

    $assert->like(
        $body // '',
        qr/\$pass_set \| Status: \$auth_status \| AUTOLOGIN: \$autologin/,
        'userWhoAmI_ctx still reports password status'
    );

    $assert->unlike(
        $body // '',
        qr/SELECT username, password, creation_date, last_login, auth FROM USER/,
        'userWhoAmI_ctx no longer SELECTs password directly'
    );

    $assert->unlike(
        $body // '',
        qr/\$ref->\{password\}/,
        'userWhoAmI_ctx no longer reads password from fetched row'
    );

    $assert->unlike(
        $body // '',
        qr/defined\(\$ref->\{password\}\)/,
        'userWhoAmI_ctx no longer checks password contents directly'
    );
};
