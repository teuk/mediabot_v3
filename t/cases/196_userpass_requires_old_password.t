# t/cases/196_userpass_requires_old_password.t
# =============================================================================
# Regression checks for userPass().
#
# If an account already has a password, changing it must require the old
# password. The one-argument "pass <newpassword>" form is only for first-time
# password setup when no password exists yet.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_196 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_196 {
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

    my $login = _slurp_196(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $main = _slurp_196(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $body = _extract_sub_body_196($login, 'userPass');

    $assert->ok(defined $body, 'userPass body found');

    $assert->like(
        $body // '',
        qr/SELECT password FROM USER WHERE id_user = \? LIMIT 1/,
        'userPass reads current password only inside password-change path'
    );

    $assert->like(
        $body // '',
        qr/my \$has_password = defined\(\$stored_hash\) && \$stored_hash ne '' \? 1 : 0;/,
        'userPass detects whether a password already exists'
    );

    $assert->like(
        $body // '',
        qr/if \(\$has_password\)/,
        'userPass branches when a password already exists'
    );

    $assert->like(
        $body // '',
        qr/Syntax: pass <oldpassword> <newpassword>/,
        'userPass requires old and new password when password already exists'
    );

    $assert->like(
        $body // '',
        qr/Syntax: pass <newpassword>/,
        'userPass still supports first password setup'
    );

    $assert->like(
        $body // '',
        qr/Current password is invalid\./,
        'userPass rejects invalid old password'
    );

    $assert->like(
        $body // '',
        qr/Failed - bad old password/,
        'userPass logs bad old password attempts'
    );

    $assert->like(
        $body // '',
        qr/UPDATE USER SET password=\? WHERE id_user=\?/,
        'userPass still updates password'
    );

    $assert->unlike(
        $body // '',
        qr/if \(defined\(\$tArgs\[0\]\) && \(\$tArgs\[0\] ne ""\)\)/,
        'userPass no longer treats single arg as enough for all cases'
    );

    $assert->like(
        $main,
        qr/pass\|pass <newpass>\|pass <oldpass> <newpass>\|private\|Set first password, or change existing password with old password verification\./,
        'help documents first setup and old-password change modes'
    );
};
