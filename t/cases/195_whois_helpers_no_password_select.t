# t/cases/195_whois_helpers_no_password_select.t
# =============================================================================
# Regression checks for WHOIS helper password handling.
#
# WHOIS hostmask matching helpers should not SELECT, carry, or log password/hash
# values. Password checks belong to Mediabot::Auth::verify_credentials().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_195 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_195 {
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

    my $helpers = _slurp_195(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $auth = _slurp_195(
        File::Spec->catfile('.', 'Mediabot', 'Auth.pm')
    );

    my $whois_body = _extract_sub_body_195($helpers, 'get_user_from_whois');
    my $nick_body  = _extract_sub_body_195($helpers, 'getNickInfoWhois');

    $assert->ok(defined $whois_body, 'get_user_from_whois body found');
    $assert->ok(defined $nick_body,  'getNickInfoWhois body found');

    for my $pair (
        [ $whois_body, 'get_user_from_whois' ],
        [ $nick_body,  'getNickInfoWhois' ],
    ) {
        my ($body, $name) = @$pair;

        $assert->like(
            $body // '',
            qr/GROUP_CONCAT\(uh\.hostmask ORDER BY uh\.id_user_hostmask SEPARATOR ','\) AS hostmasks/,
            "$name still loads hostmasks"
        );

        $assert->like(
            $body // '',
            qr/hostmask_matches/,
            "$name still uses hostmask matching"
        );

        $assert->unlike(
            $body // '',
            qr/u\.password/,
            "$name no longer SELECTs or GROUPs u.password"
        );

        $assert->unlike(
            $body // '',
            qr/\$best_ref->\{password\}/,
            "$name no longer carries password from best_ref"
        );

        $assert->unlike(
            $body // '',
            qr/\$ref->\{password\}/,
            "$name no longer reads password from fetched row"
        );
    }

    $assert->like(
        $whois_body // '',
        qr/Mediabot::User->new\(\{/,
        'get_user_from_whois still builds a Mediabot::User object'
    );

    $assert->unlike(
        $whois_body // '',
        qr/password\s+=>/,
        'get_user_from_whois no longer sets password on the user object'
    );

    $assert->like(
        $nick_body // '',
        qr/\$sMatchingUserPasswd/,
        'getNickInfoWhois keeps legacy password return slot for compatibility'
    );

    $assert->unlike(
        $nick_body // '',
        qr/sMatchingUserPasswd :/,
        'getNickInfoWhois no longer logs the password/hash slot'
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
