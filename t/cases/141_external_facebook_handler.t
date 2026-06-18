# t/cases/141_external_facebook_handler.t
# =============================================================================
# Regression checks for dedicated Facebook URL title handling.
#
# Facebook should not go through the plain generic handler first.  It needs a
# dedicated path that normalizes facebook.com to www.facebook.com and can use
# Chromium as a fallback when the HTTP title is not usable.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_external_facebook_handler {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_external_facebook_handler {
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

    my $src = _slurp_external_facebook_handler(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my $display_body  = _extract_sub_body_external_facebook_handler($src, 'displayUrlTitle');
    my $facebook_body = _extract_sub_body_external_facebook_handler($src, '_handle_facebook');
    my $url_body      = _extract_sub_body_external_facebook_handler($src, '_facebook_url');
    my $title_body    = _extract_sub_body_external_facebook_handler($src, '_facebook_title_from_html');

    $assert->ok(defined $display_body,  'displayUrlTitle body found');
    $assert->ok(defined $facebook_body, '_handle_facebook body found');
    $assert->ok(defined $url_body,      '_facebook_url body found');
    $assert->ok(defined $title_body,    '_facebook_title_from_html body found');

    $assert->like(
        $src,
        qr/^\s+_handle_facebook$/m,
        '_handle_facebook is exported for tests and consistency'
    );

    $assert->like(
        $url_body // '',
        qr/facebook\.com/,
        '_facebook_url recognizes facebook.com'
    );

    $assert->like(
        $url_body // '',
        qr/https:\/\/www\.facebook\.com\//,
        '_facebook_url normalizes root facebook.com to www.facebook.com'
    );

    $assert->like(
        $title_body // '',
        qr/og:title/,
        '_facebook_title_from_html tries og:title'
    );

    $assert->like(
        $title_body // '',
        qr/<title/,
        '_facebook_title_from_html falls back to title tag'
    );

    $assert->like(
        $facebook_body // '',
        qr/HTTP::Tiny|_make_http/,
        '_handle_facebook uses the shared HTTP path first'
    );

    $assert->like(
        $facebook_body // '',
        qr/_fetch_url_chromium_dumpdom/,
        '_handle_facebook uses Chromium fallback'
    );

    $assert->like(
        $display_body // '',
        qr/_handle_facebook\(\$self, \$message, \$sNick, \$sChannel, \$url\)/,
        'displayUrlTitle dispatches Facebook to the dedicated handler'
    );

    my $facebook_pos = index($display_body // '', '_handle_facebook($self, $message, $sNick, $sChannel, $url)');
    my $generic_pos  = index($display_body // '', '_handle_generic_title($self, $message, $sNick, $sChannel, $url)');

    $assert->ok(
        $facebook_pos >= 0 && $generic_pos >= 0 && $facebook_pos < $generic_pos,
        'Facebook dispatch happens before the generic URL handler'
    );
};
