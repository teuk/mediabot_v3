use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::VDM::Source qw(parse_vdm_feed_document);

return sub {
    my ($assert) = @_;

    my $rss = <<'XML';
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>VDM</title>
<item>
<title>Bien tenté</title>
<link>https://www.viedemerde.fr/article/bien-tente_513869.html</link>
<guid>https://www.viedemerde.fr/article/bien-tente_513869.html</guid>
<description><![CDATA[<p>Aujourd'hui, mon hibou a livré la lettre au mauvais sorcier. VDM</p>]]></description>
<pubDate>Thu, 27 Aug 2026 00:30:00 +0000</pubDate>
</item>
<item>
<title>Malformed</title>
<link>https://www.viedemerde.fr/no-id</link>
<description>Aujourd'hui, ceci n'a pas de numéro. VDM</description>
</item>
</channel></rss>
XML

    my $p = parse_vdm_feed_document($rss, max_items => 10);
    $assert->ok($p->{ok}, 'mb704-970: valid RSS document parses');
    $assert->is($p->{format}, 'rss', 'mb704-970: RSS format identified');
    $assert->is(scalar(@{ $p->{items} }), 1,
        'mb704-970: malformed entries are skipped rather than poisoning the feed');
    $assert->is($p->{items}[0]{id}, '513869',
        'mb704-970: VDM numeric id comes from the article URL');
    $assert->is($p->{items}[0]{story},
        "Aujourd'hui, mon hibou a livré la lettre au mauvais sorcier. VDM",
        'mb704-970: description HTML/CDATA is reduced to clean source story text');
    $assert->unlike($p->{items}[0]{story}, qr/[<>]/,
        'mb704-970: source parser never leaks markup');

    my $atom = <<'XML';
<feed xmlns="http://www.w3.org/2005/Atom">
<entry>
<title>Une journée</title>
<id>https://www.viedemerde.fr/article/une-journee_424242.html</id>
<link rel="alternate" href="https://www.viedemerde.fr/article/une-journee_424242.html" />
<summary>Aujourd'hui, le callback est revenu après la bataille. VDM</summary>
</entry>
</feed>
XML
    my $a = parse_vdm_feed_document($atom);
    $assert->ok($a->{ok}, 'mb704-970: Atom fallback is supported');
    $assert->is($a->{items}[0]{id}, '424242',
        'mb704-970: Atom item id is normalized through the same VDM id contract');

    $assert->is(parse_vdm_feed_document('<html/>')->{error}, 'unsupported_feed',
        'mb704-970: non-feed input fails closed');
    $assert->is(parse_vdm_feed_document('<!DOCTYPE rss><rss/>')->{error}, 'forbidden_doctype',
        'mb704-970: entity-capable declarations remain forbidden');
    $assert->is(parse_vdm_feed_document("<rss>\0</rss>")->{error}, 'nul_byte',
        'mb704-970: NUL-bearing feed fails closed');

    my $no_story = <<'XML';
<rss><channel><item><link>https://www.viedemerde.fr/article/x_999.html</link>
<description>Pas de marqueur final.</description></item></channel></rss>
XML
    $assert->is(parse_vdm_feed_document($no_story)->{error}, 'no_valid_items',
        'mb704-970: source entries without their published VDM closing marker are rejected');
};
