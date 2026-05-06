# t/cases/155_external_x_title_meta_attribute_order.t
# =============================================================================
# Regression checks for X/Twitter title extraction.
#
# Rendered X/Twitter DOM can include meta tags with attributes in many orders
# and with unrelated attributes between property/name and content.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

{
    package Local::XTitleLogger;
    sub new { bless {}, shift }
    sub log { return 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External;

    my $self = {
        logger => Local::XTitleLogger->new,
    };

    $assert->is(
        Mediabot::External::_x_title_from_html(
            $self,
            q{<html><head><meta data-rh="true" property="og:title" data-extra="x" content="Post title from OG"></head></html>},
            'test'
        ),
        'Post title from OG',
        '_x_title_from_html handles og:title with attributes between property and content'
    );

    $assert->is(
        Mediabot::External::_x_title_from_html(
            $self,
            q{<html><head><meta content="Post title from Twitter" data-extra="x" name="twitter:title"></head></html>},
            'test'
        ),
        'Post title from Twitter',
        '_x_title_from_html handles twitter:title when content comes first'
    );

    $assert->is(
        Mediabot::External::_x_title_from_html(
            $self,
            q{<html><head><meta name="twitter:title" data-rh="true" content="Tweet &amp; title"></head></html>},
            'test'
        ),
        'Tweet & title',
        '_x_title_from_html decodes HTML entities from flexible meta title'
    );

    $assert->is(
        Mediabot::External::_x_title_from_html(
            $self,
            q{<html><head><meta name="description" content="not a title"><title>Fallback title / X</title></head></html>},
            'test'
        ),
        'Fallback title / X',
        '_x_title_from_html still falls back to title tag'
    );

    my $missing_content_title = Mediabot::External::_x_title_from_html(
        $self,
        q{<html><head><meta data-rh="true" property="og:title"></head><body></body></html>},
        'test'
    );

    $assert->ok(
        !defined($missing_content_title),
        '_x_title_from_html ignores title meta tags without content'
    );
};
