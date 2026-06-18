# t/cases/143_external_facebook_fallback_all_urls.t
# =============================================================================
# Regression checks for Facebook URL fallback titles.
#
# When Facebook only exposes a login shell, the handler should still produce a
# useful, honest label for all Facebook URL shapes, not only the root page.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_facebook_fallback_all_urls {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_facebook_fallback_all_urls {
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

    my $src = _slurp_facebook_fallback_all_urls(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my $fallback_body = _extract_sub_body_facebook_fallback_all_urls($src, '_facebook_fallback_title_from_url');
    my $handler_body  = _extract_sub_body_facebook_fallback_all_urls($src, '_handle_facebook');

    $assert->ok(defined $fallback_body, '_facebook_fallback_title_from_url body found');
    $assert->ok(defined $handler_body,  '_handle_facebook body found');

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook' if \$normalized =~/,
        'fallback handles Facebook root URL'
    );

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook reel'/,
        'fallback handles Facebook reel URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook video'/,
        'fallback handles Facebook video URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook photo'/,
        'fallback handles Facebook photo URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook story'/,
        'fallback handles Facebook story URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/return 'Facebook event'/,
        'fallback handles Facebook event URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/Facebook group post: \$group/,
        'fallback handles Facebook group post URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/Facebook group: \$group/,
        'fallback handles Facebook group URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/Facebook post by \$owner/,
        'fallback handles page/profile post URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/Facebook video by \$owner/,
        'fallback handles page/profile video URLs'
    );

    $assert->like(
        $fallback_body // '',
        qr/Facebook: \$owner/,
        'fallback handles page/profile root URLs'
    );

    $assert->like(
        $handler_body // '',
        qr/my \$fallback_title = _facebook_fallback_title_from_url\(\$fb_url\);/,
        '_handle_facebook calls the URL fallback helper'
    );

    $assert->like(
        $handler_body // '',
        qr/using URL fallback title/,
        '_handle_facebook logs URL fallback usage'
    );

    my $fallback_pos = index($handler_body // '', '_facebook_fallback_title_from_url($fb_url)');
    my $return_pos   = index($handler_body // '', 'no usable title extracted');

    $assert->ok(
        $fallback_pos >= 0 && $return_pos >= 0 && $fallback_pos < $return_pos,
        'URL fallback happens before no-title return'
    );
};
