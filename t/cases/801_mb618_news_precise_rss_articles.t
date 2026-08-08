# t/cases/801_mb618_news_precise_rss_articles.t
# =============================================================================
# mb618 — Tavily nourrit la synthese, Google News RSS nourrit les liens precis.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;
    require Mediabot::External::News;

    my $url = Mediabot::External::News::_news_google_rss_url('fr', 'actualité France');
    $assert->like($url, qr{^https://news\.google\.com/rss/search\?q=},
        'mb618-801: endpoint Google News RSS');
    $assert->like($url, qr/hl=fr&gl=FR&ceid=FR:fr/,
        'mb618-801: locale francaise explicite');
    $assert->like($url, qr/actualit%C3%A9%20France/,
        'mb618-801: requete encodee en UTF-8');

    my $rss = <<'XML';
<?xml version="1.0" encoding="UTF-8"?>
<rss><channel>
<item>
<title>Mortalité infantile : le rapport de l&apos;IGAS alerte sur une hausse en France - France Culture</title>
<link>https://news.google.com/rss/articles/AAA?oc=5&amp;hl=fr</link>
<pubDate>Fri, 08 Aug 2026 12:00:00 GMT</pubDate>
<source url="https://www.radiofrance.fr/franceculture">France Culture</source>
</item>
<item>
<title>Le pape Léon XIV visitera Paris, Metz et Lourdes fin septembre - Le Monde</title>
<link>https://news.google.com/rss/articles/BBB?oc=5</link>
<pubDate>Thu, 07 Aug 2026 09:00:00 GMT</pubDate>
<source url="https://www.lemonde.fr">Le Monde</source>
</item>
<item>
<title>Un second papier du même éditeur - Le Monde</title>
<link>https://news.google.com/rss/articles/CCC</link>
<pubDate>Thu, 07 Aug 2026 08:00:00 GMT</pubDate>
<source url="https://www.lemonde.fr">Le Monde</source>
</item>
<item>
<title>La mortalité infantile française au plus haut depuis plusieurs années - 20 Minutes</title>
<link>https://news.google.com/rss/articles/DDD</link>
<pubDate>Wed, 06 Aug 2026 17:00:00 GMT</pubDate>
<source url="https://www.20minutes.fr">20 Minutes</source>
</item>
</channel></rss>
XML

    my $arts = Mediabot::External::News::_news_parse_google_rss($rss, 3);
    $assert->is(scalar @$arts, 3,
        'mb618-801: trois editeurs distincts au maximum');
    $assert->is($arts->[0]{source}, 'France Culture',
        'mb618-801: editeur RSS conserve');
    $assert->is($arts->[0]{title}, "Mortalité infantile : le rapport de l'IGAS alerte sur une hausse en France",
        'mb618-801: titre article precis sans suffixe editeur');
    $assert->is($arts->[0]{url}, 'https://news.google.com/rss/articles/AAA?oc=5&hl=fr',
        'mb618-801: entite XML du lien decodee');
    $assert->ok(defined $arts->[0]{epoch},
        'mb618-801: pubDate RSS devient une date exploitable');
    $assert->is($arts->[1]{source}, 'Le Monde',
        'mb618-801: deuxieme editeur conserve');
    $assert->is($arts->[2]{source}, '20 Minutes',
        'mb618-801: doublon editeur saute au profit de la diversite');

    my $segments = Mediabot::External::News::_news_article_segments($arts, sub {
        my ($u) = @_;
        return $u =~ /AAA/ ? 'https://tinyurl.com/a1' :
               $u =~ /BBB/ ? 'https://tinyurl.com/b2' : 'https://tinyurl.com/d4';
    });
    $assert->like($segments->[0], qr/\x0314\d\d\/\d\d France Culture\x03/,
        'mb618-801: la charte affiche le vrai editeur, pas news.google.com');
    $assert->like($segments->[0], qr/rapport de l'IGAS alerte/,
        'mb618-801: la ligne annonce precisement le contenu du lien');
    $assert->unlike($segments->[0], qr/Journaux d'information|Actualit.s Ile-de-France/i,
        'mb618-801: pas de libelle de rubrique generique dans le fixture');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/News.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/my \$press_articles = _news_fetch_google_articles\(/,
        'mb618-801: runtime tente le RSS apres Tavily');
    $assert->like($src, qr/my \$display_articles = \@\$press_articles \? \$press_articles : \$picked;/,
        'mb618-801: Tavily reste le fallback de presentation');
    $assert->like($src, qr/_news_article_segments\(\$display_articles,/,
        'mb618-801: la charte consomme les articles RSS quand disponibles');
    $assert->like($src, qr/(?:Precise press headlines from Google News RSS|PRECISE PRESS HEADLINES)/,
        'mb618-801: les titres precis enrichissent aussi la synthese');
};
