# t/cases/188_userinfo_does_not_select_password.t
# =============================================================================
# Regression checks for userInfo_ctx().
#
# userinfo should report whether a password exists, but it should not SELECT or
# load USER.password itself. It should use a boolean has_password value instead.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_188 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_188 {
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

    my $src = _slurp_188(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $body = _extract_sub_body_188($src, 'userInfo_ctx');

    $assert->ok(defined $body, 'userInfo_ctx body found');

    $assert->like(
        $body // '',
        qr/CASE\s+WHEN USER\.password IS NOT NULL AND USER\.password <> '' THEN 1\s+ELSE 0\s+END AS has_password/s,
        'userInfo_ctx selects a has_password boolean'
    );

    $assert->like(
        $body // '',
        qr/my \$has_password = defined\(\$ref->\{has_password\}\) \? int\(\$ref->\{has_password\}\) : 0;/,
        'userInfo_ctx reads has_password safely'
    );

    $assert->like(
        $body // '',
        qr/my \$pass_set = \$has_password \? 'yes' : 'no';/,
        'userInfo_ctx reports pass flag from has_password'
    );

    $assert->like(
        $body // '',
        qr/Pass: \$pass_set/,
        'userInfo_ctx still reports whether a password exists'
    );

    $assert->unlike(
        $body // '',
        qr/USER\.password,/,
        'userInfo_ctx no longer SELECTs USER.password as a value'
    );

    $assert->unlike(
        $body // '',
        qr/my \$password = \$ref->\{password\};/,
        'userInfo_ctx no longer loads password into a Perl variable'
    );

    $assert->unlike(
        $body // '',
        qr/defined\(\$password\)/,
        'userInfo_ctx no longer checks password contents directly'
    );
};
