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
<rss version="2.0"><channel>
<item>
<link>http://www.viedemerde.fr/article/black-mirror_513889.html</link>
<title>Black Mirror</title>
<description>Aujourd'hui, le hibou de test confond encore deux cheminées. VDM — flux mobile</description>
<pubDate>Thu, 27 Aug 2026 12:00:00 +0000</pubDate>
<guid>http://www.viedemerde.fr/article/black-mirror_513889.html</guid>
</item>
</channel></rss>
XML

    my $p = parse_vdm_feed_document($rss, max_items => 5);
    $assert->ok($p->{ok},
        'mb704-985: current RSS shape accepts a short suffix after the published VDM marker');
    $assert->is(scalar(@{ $p->{items} }), 1,
        'mb704-985: suffixed current RSS item yields exactly one normalized story');
    $assert->is($p->{items}[0]{id}, '513889',
        'mb704-985: current http article/guid form still yields its numeric id');
    $assert->is($p->{items}[0]{story},
        "Aujourd'hui, le hibou de test confond encore deux cheminées. VDM",
        'mb704-985: parser removes feed suffix but preserves the published story through VDM');

    my $not_story = <<'XML';
<rss><channel><item>
<link>http://www.viedemerde.fr/article/x_999999.html</link>
<description>Résumé éditorial VDM — flux mobile</description>
</item></channel></rss>
XML
    $assert->is(parse_vdm_feed_document($not_story)->{error}, 'no_valid_items',
        'mb704-985: a VDM token alone does not turn arbitrary feed text into a story');

    my $huge_suffix = 'x' x 129;
    my $too_much = qq{<rss><channel><item><link>http://www.viedemerde.fr/article/x_888888.html</link><description>Aujourd'hui, test. VDM$huge_suffix</description></item></channel></rss>};
    $assert->is(parse_vdm_feed_document($too_much)->{error}, 'no_valid_items',
        'mb704-985: unexpectedly large post-VDM payload fails closed');
};
