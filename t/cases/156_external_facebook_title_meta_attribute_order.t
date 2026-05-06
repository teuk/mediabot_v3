# t/cases/156_external_facebook_title_meta_attribute_order.t
# =============================================================================
# Regression checks for Facebook title extraction.
#
# Rendered Facebook DOM can include meta tags with attributes in many orders
# and with unrelated attributes between property and content.
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
    package Local::FacebookTitleLogger;
    sub new { bless {}, shift }
    sub log { return 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External;

    my $self = {
        logger => Local::FacebookTitleLogger->new,
    };

    $assert->is(
        Mediabot::External::_facebook_title_from_html(
            $self,
            q{<html><head><meta data-rh="true" property="og:title" data-extra="x" content="Facebook post title"></head></html>},
            'test'
        ),
        'Facebook post title',
        '_facebook_title_from_html handles og:title with attributes between property and content'
    );

    $assert->is(
        Mediabot::External::_facebook_title_from_html(
            $self,
            q{<html><head><meta content="Facebook title first" data-extra="x" property="og:title"></head></html>},
            'test'
        ),
        'Facebook title first',
        '_facebook_title_from_html handles og:title when content comes first'
    );

    $assert->is(
        Mediabot::External::_facebook_title_from_html(
            $self,
            q{<html><head><meta property="og:title" data-rh="true" content="Facebook &amp; title"></head></html>},
            'test'
        ),
        'Facebook & title',
        '_facebook_title_from_html decodes HTML entities from flexible meta title'
    );

    $assert->is(
        Mediabot::External::_facebook_title_from_html(
            $self,
            q{<html><head><meta name="description" content="not a title"><title>Fallback title / Facebook</title></head></html>},
            'test'
        ),
        'Fallback title / Facebook',
        '_facebook_title_from_html still falls back to title tag'
    );

    my $missing_content_title = Mediabot::External::_facebook_title_from_html(
        $self,
        q{<html><head><meta data-rh="true" property="og:title"></head><body></body></html>},
        'test'
    );

    $assert->ok(
        !defined($missing_content_title),
        '_facebook_title_from_html ignores title meta tags without content'
    );
};
