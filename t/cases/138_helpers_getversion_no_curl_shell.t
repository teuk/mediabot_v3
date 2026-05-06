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

    $assert->like(
        $body // '',
        qr/my \$version_url = 'https:\/\/raw\.githubusercontent\.com\/teuk\/mediabot_v3\/master\/VERSION';/,
        'getVersion defines the remote VERSION URL'
    );

    $assert->like(
        $body // '',
        qr/HTTP::Tiny->new\(timeout => 5\)->get\(\$version_url\)/,
        'getVersion fetches remote VERSION through HTTP::Tiny'
    );

    $assert->like(
        $body // '',
        qr/\$remote_version = \$response->\{content\} \/\/ '';/,
        'getVersion reads remote version from HTTP response content'
    );

    $assert->like(
        $body // '',
        qr/\$remote_version =~ s\/\\r\?\\n\\z\/\/;/,
        'getVersion strips one trailing newline from the remote version'
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

    $assert->like(
        $body // '',
        qr/Failed to fetch version from GitHub: HTTP \$status/,
        'getVersion logs HTTP status on fetch failure'
    );
};
