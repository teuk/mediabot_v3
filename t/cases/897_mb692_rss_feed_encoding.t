# t/cases/897_mb692_rss_feed_encoding.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Encode qw(encode);
use Mediabot::RSS::Fetcher;

return sub {
    my ($assert) = @_;

    my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n}
            . qq{<rss><channel><title>Les news de Korben</title>}
            . qq{<item><title>pilote vérolé — SMS protégé</title>}
            . qq{<link>https://example.test/a</link></item>}
            . qq{</channel></rss>};

    my $bytes = encode('UTF-8', $xml);

    my $r = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            my ($url, %opts) = @_;
            return {
                success => 1,
                status  => 200,
                headers => { 'content-type' => 'application/rss+xml; charset=UTF-8' },
                content => $bytes,
            };
        },
        max_items => 2,
    );

    $assert->ok($r->{ok},
        'mb692-897: UTF-8 byte response parses successfully');
    $assert->is($r->{feed}{items}[0]{title},
        "pilote vérolé — SMS protégé",
        'mb692-897: UTF-8 accents/em dash decode and NBSP normalizes to space');

    my $xml_decl_only = encode('UTF-8',
        qq{<?xml version="1.0" encoding="UTF-8"?><rss><channel>}
      . qq{<title>Édition</title><item><title>café</title>}
      . qq{<link>https://example.test/b</link></item></channel></rss>});

    my $r2 = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => {},
                content => $xml_decl_only,
            };
        },
    );

    $assert->ok($r2->{ok},
        'mb692-897: XML declaration encoding is honored without HTTP charset');
    $assert->is($r2->{feed}{title}, 'Édition',
        'mb692-897: XML-declaration UTF-8 feed title is decoded');

    my $bom = "\xEF\xBB\xBF" . encode('UTF-8',
        qq{<rss><channel><title>Résumé</title>}
      . qq{<item><title>déjà vu</title><link>https://example.test/c</link></item>}
      . qq{</channel></rss>});

    my $r3 = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => {},
                content => $bom,
            };
        },
    );

    $assert->ok($r3->{ok},
        'mb692-897: UTF-8 BOM is recognized');
    $assert->is($r3->{feed}{title}, 'Résumé',
        'mb692-897: BOM is removed before XML parsing');

    my $latin = encode('Windows-1252',
        qq{<?xml version="1.0" encoding="windows-1252"?><rss><channel>}
      . qq{<title>Actualité</title><item><title>été — café</title>}
      . qq{<link>https://example.test/d</link></item></channel></rss>});

    my $r4 = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => { 'Content-Type' => 'application/rss+xml; charset=windows-1252' },
                content => $latin,
            };
        },
    );

    $assert->ok($r4->{ok},
        'mb692-897: case-insensitive HTTP Content-Type charset is honored');
    $assert->is($r4->{feed}{items}[0]{title}, 'été — café',
        'mb692-897: Windows-1252 feed text is decoded correctly');

    my $bad = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => { 'content-type' => 'application/rss+xml; charset=UTF-8' },
                content => "\xFF\xFF\xFF",
            };
        },
    );

    $assert->ok(!$bad->{ok},
        'mb692-897: malformed encoded feed is rejected');
    $assert->is($bad->{error}, 'invalid_encoding',
        'mb692-897: malformed encoding fails closed with explicit error');

    my $already_chars = qq{<rss><channel><title>Déjà décodé</title>}
                      . qq{<item><title>élève</title><link>https://example.test/e</link></item>}
                      . qq{</channel></rss>};

    my $r5 = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => {},
                content => $already_chars,
            };
        },
    );

    $assert->ok($r5->{ok},
        'mb692-897: already-decoded Perl character strings remain supported');
    $assert->is($r5->{feed}{title}, 'Déjà décodé',
        'mb692-897: decoded strings are not double-decoded');
};
