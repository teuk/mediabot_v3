# t/cases/154_external_x_status_fallback_variants.t
# =============================================================================
# Regression checks for X/Twitter status fallback labels.
#
# X/Twitter links can appear as /status/, legacy /statuses/, or internal
# /i/web/status/ URLs.  If Chromium cannot extract a real title, fallback labels
# should still identify them as posts.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::External;

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://x.com/teuk/status/123456'),
        'X post by @teuk',
        'X fallback handles x.com /status/ URLs'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://twitter.com/teuk/status/123456'),
        'X post by @teuk',
        'X fallback handles twitter.com /status/ URLs'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://twitter.com/teuk/statuses/123456'),
        'X post by @teuk',
        'X fallback handles legacy twitter.com /statuses/ URLs'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://x.com/i/web/status/123456'),
        'X post',
        'X fallback handles x.com /i/web/status/ URLs'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://twitter.com/i/web/status/123456'),
        'X post',
        'X fallback handles twitter.com /i/web/status/ URLs'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://www.twitter.com/teuk/statuses/123456?ref=test'),
        'X post by @teuk',
        'X fallback handles www.twitter.com statuses URL with query string'
    );
};
