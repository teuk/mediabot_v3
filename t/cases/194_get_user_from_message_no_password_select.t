# t/cases/194_get_user_from_message_no_password_select.t
# =============================================================================
# Regression checks for get_user_from_message().
#
# get_user_from_message() resolves users by IRC hostmask. It does not need to
# SELECT or carry the password/hash value. Password checks belong to
# Mediabot::Auth::verify_credentials().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_194 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_194 {
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

    my $helpers = _slurp_194(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $auth = _slurp_194(
        File::Spec->catfile('.', 'Mediabot', 'Auth.pm')
    );

    my $body = _extract_sub_body_194($helpers, 'get_user_from_message');

    $assert->ok(defined $body, 'get_user_from_message body found');

    $assert->like(
        $body // '',
        qr/GROUP_CONCAT\(uh\.hostmask ORDER BY uh\.id_user_hostmask SEPARATOR ','\) AS hostmasks/,
        'get_user_from_message still loads hostmasks'
    );

    $assert->like(
        $body // '',
        qr/Mediabot::User->new\(\{/,
        'get_user_from_message still builds a Mediabot::User object'
    );

    $assert->unlike(
        $body // '',
        qr/\bu\.password\s*,/,
        'get_user_from_message no longer SELECTs or GROUPs u.password'
    );

    $assert->unlike(
        $body // '',
        qr/\bUSER\.password\s*,/,
        'get_user_from_message no longer SELECTs USER.password'
    );

    $assert->unlike(
        $body // '',
        qr/\$ref->\{password\}/,
        'get_user_from_message no longer reads password from fetched row'
    );

    $assert->like(
        $auth,
        qr/SELECT id_user, nickname, password FROM USER WHERE/,
        'Mediabot::Auth still owns password lookup for real credential checks'
    );

    $assert->like(
        $auth,
        qr/sub verify_credentials/,
        'Mediabot::Auth::verify_credentials remains the password-checking path'
    );
};
