# t/cases/153_external_x_url_root_normalization.t
# =============================================================================
# Regression checks for X/Twitter URL normalization.
#
# _x_url should canonicalize x.com/twitter.com roots and paths consistently,
# including root URLs without a trailing slash.
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
        Mediabot::External::_x_url('https://x.com'),
        'https://x.com/',
        '_x_url normalizes x.com root without slash'
    );

    $assert->is(
        Mediabot::External::_x_url('https://x.com/'),
        'https://x.com/',
        '_x_url keeps x.com root with slash'
    );

    $assert->is(
        Mediabot::External::_x_url('https://www.x.com'),
        'https://x.com/',
        '_x_url normalizes www.x.com root without slash'
    );

    $assert->is(
        Mediabot::External::_x_url('https://twitter.com'),
        'https://x.com/',
        '_x_url normalizes twitter.com root without slash'
    );

    $assert->is(
        Mediabot::External::_x_url('https://www.twitter.com'),
        'https://x.com/',
        '_x_url normalizes www.twitter.com root without slash'
    );

    $assert->is(
        Mediabot::External::_x_url('http://twitter.com/teuk/status/123'),
        'https://x.com/teuk/status/123',
        '_x_url normalizes http twitter.com status URL to https x.com'
    );

    $assert->is(
        Mediabot::External::_x_url('https://www.x.com/teuk'),
        'https://x.com/teuk',
        '_x_url normalizes www.x.com profile URL'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://twitter.com'),
        'X',
        'X fallback treats twitter.com root as X root'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://www.twitter.com/teuk/status/123'),
        'X post by @teuk',
        'X fallback handles www.twitter.com status URLs after normalization'
    );

    $assert->is(
        Mediabot::External::_x_fallback_title_from_url('https://www.x.com/teuk'),
        'X profile: @teuk',
        'X fallback handles www.x.com profile URLs after normalization'
    );
};
