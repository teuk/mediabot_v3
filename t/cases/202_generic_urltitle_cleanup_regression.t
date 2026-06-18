# t/cases/202_generic_urltitle_cleanup_regression.t
# =============================================================================
# Regression checks for generic UrlTitle cleanup.
#
# Generic URL titles should:
#   - strip trailing punctuation from pasted URLs;
#   - prefer og:title/twitter:title over plain <title>;
#   - reject useless anti-bot/error/browser shell titles;
#   - keep the historical label style while hard-resetting before displayed text.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_202 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_between_202 {
    my ($src, $start_marker, $next_marker) = @_;

    my $start = index($src, $start_marker);
    return undef if $start < 0;

    my $end = index($src, $next_marker, $start);
    return undef if $end < 0;

    return substr($src, $start, $end - $start);
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_202(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my $extract_url = _extract_between_202(
        $src,
        'sub _extract_url {',
        '# ---------------------------------------------------------------------------' . "\n" . '# _decode_html'
    );

    $assert->ok(
        defined $extract_url && $extract_url ne '',
        '_extract_url body found'
    );

    $assert->like(
        $extract_url // '',
        qr/\(https\?:\/\/\\S\+\)/,
        '_extract_url captures first HTTP(S) URL'
    );

    $assert->like(
        $extract_url // '',
        qr/\$url\s*=~\s*s\/\[\)\\\]\.,!\?;:\]\+\$\/\/;/,
        '_extract_url strips common trailing punctuation'
    );

    $assert->like(
        $extract_url // '',
        qr/\$url\s*=~\s*s\/\["'\]\+\$\/\/;/,
        '_extract_url strips trailing quotes'
    );

    my $cleaner = _extract_between_202(
        $src,
        'sub _clean_generic_url_title {',
        '# ---------------------------------------------------------------------------' . "\n" . '# _handle_generic_title'
    );

    $assert->ok(
        defined $cleaner && $cleaner ne '',
        '_clean_generic_url_title body found'
    );

    for my $bad_title (
        'Just a moment',
        'Attention Required',
        'Access Denied',
        '403 Forbidden',
        '404 Not Found',
        'Page Not Found',
        'please enable javascript',
        'checking your browser',
        'verify you are human',
    ) {
        $assert->like(
            $cleaner // '',
            qr/\Q$bad_title\E/i,
            "_clean_generic_url_title rejects '$bad_title'"
        );
    }

    $assert->like(
        $cleaner // '',
        qr/substr\(\$title,\s*0,\s*300\)/,
        '_clean_generic_url_title caps displayed title length'
    );

    my $generic = _extract_between_202(
        $src,
        'sub _handle_generic_title {',
        '# ---------------------------------------------------------------------------' . "\n" . '# displayUrlTitle'
    );

    $assert->ok(
        defined $generic && $generic ne '',
        '_handle_generic_title body found'
    );

    $assert->like(
        $generic // '',
        qr/content-type/i,
        '_handle_generic_title checks content-type'
    );

    $assert->like(
        $generic // '',
        qr/text\/html\|application\/xhtml\\\+xml\|application\/xml\|text\/xml/,
        '_handle_generic_title only accepts HTML/XML-like content'
    );

    $assert->like(
        $generic // '',
        qr/og:title\|twitter:title/,
        '_handle_generic_title prefers social metadata titles'
    );

    $assert->like(
        $generic // '',
        qr/<title\[\^>\]\*>\(\.\*\?\)<\\\/title>/,
        '_handle_generic_title still falls back to <title>'
    );

    $assert->like(
        $generic // '',
        qr/_clean_generic_url_title\(\$candidate\)/,
        '_handle_generic_title cleans every title candidate'
    );

    $assert->like(
        $generic // '',
        qr/my\s+\$label\s*=\s*String::IRC->new\("URL"\)->grey\('black'\);/,
        '_handle_generic_title starts the current URL badge'
    );

    $assert->like(
        $generic // '',
        qr/\$label\s+\.=\s+String::IRC->new\(" \$domain"\)->white\('black'\) if \$domain;/,
        '_handle_generic_title can add the current domain to the badge'
    );

    $assert->like(
        $generic // '',
        qr/\$label\s+\.=\s+String::IRC->new\(" \$nick:"\)->grey\('black'\);/,
        '_handle_generic_title keeps the nick in the current badge'
    );

    $assert->like(
        $generic // '',
        qr/botPrivmsg\(\$self,\s*\$channel,\s*"\$label\\x0f\s+\$title"\);/,
        '_handle_generic_title hard-resets after label before displayed title'
    );

    $assert->unlike(
        $generic // '',
        qr/my\s+\$msg\s*=\s*String::IRC->new\(/,
        '_handle_generic_title no longer appends displayed title through a msg object'
    );
};
