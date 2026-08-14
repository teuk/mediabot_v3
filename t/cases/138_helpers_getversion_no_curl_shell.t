# t/cases/138_helpers_getversion_no_curl_shell.t
# =============================================================================
# Regression checks for Mediabot::Helpers::getVersion().
#
# getVersion should fetch the remote VERSION file with HTTP::Tiny, not by
# launching curl through a shell command string.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_helpers_getversion {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_helpers_getversion {
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

    my $src = _slurp_helpers_getversion(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $body = _extract_sub_body_helpers_getversion($src, 'getVersion');

    $assert->ok(
        defined $body,
        'getVersion body found'
    );

    $assert->like(
        $src,
        qr/^use HTTP::Tiny;$/m,
        'Helpers.pm imports HTTP::Tiny'
    );

    # mb638: la requete a demenage dans fetch_remote_version — une seule
    # implementation, qui rend AUSSI la raison de l'echec (le fils de
    # getVersion_async a un logger muet : sans elle, « github: Undefined »
    # n'apprenait rien a l'operateur). Le contrat de CE fichier — aucune
    # sortie shell, une requete Perl — vaut desormais pour les deux subs.
    my $fetch = _extract_sub_body_helpers_getversion($src, 'fetch_remote_version');
    $assert->ok(defined $fetch, 'fetch_remote_version body found');

    $assert->like(
        $src,
        qr/'https:\/\/raw\.githubusercontent\.com\/teuk\/mediabot_v3\/master\/VERSION'/,
        'getVersion defines the remote VERSION URL'
    );

    $assert->like(
        $fetch // '',
        qr/HTTP::Tiny->new\(/,
        'getVersion fetches remote VERSION through HTTP::Tiny'
    );

    $assert->like(
        $body // '',
        qr/my \(\$fetched, \$fetch_error\) = fetch_remote_version\(\$self\);/,
        'getVersion reads remote version from HTTP response content'
    );

    $assert->like(
        $fetch // '',
        qr/\$body =~ s\/\\s\+\\z\/\/;/,
        'getVersion strips one trailing newline from the remote version'
    );

    $assert->unlike(
        $fetch // '',
        qr/curl --connect-timeout/,
        'fetch_remote_version no longer shells out to curl'
    );

    $assert->unlike(
        $body // '',
        qr/curl --connect-timeout/,
        'getVersion no longer shells out to curl'
    );

    $assert->unlike(
        $body // '',
        qr/open my \$gh, '-\|'/,
        'getVersion no longer opens a command pipe'
    );

    # mb638: le journal porte desormais la RAISON complete (statut + detail
    # reseau) au lieu du seul code — c'est ce qui manquait sur le terrain.
    $assert->like(
        $body // '',
        qr/Failed to fetch version from GitHub: " \. \(\$fetch_error/,
        'getVersion logs HTTP status on fetch failure'
    );
};
