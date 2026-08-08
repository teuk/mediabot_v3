# t/cases/800_mb617_news_output_charter.t
# =============================================================================
# mb617 — la sortie news retrouve une vraie charte IRC et des liens utilisables.
#   [1] les lignes article sont construites depuis les resultats Tavily, pas
#       depuis Claude ; elles portent date/source en gris et le lien bleu
#       souligne comme dans le script Windrop d'origine.
#   [2] les URLs sont raccourcies quand un shortener est fourni.
#   [3] les segments sont regroupes sur une ou plusieurs lignes IRC avec le
#       separateur orange, sans couper les segments en leur milieu.
#   [4] au runtime, les lignes article sont preferees a la simple ligne
#       "Sources:" quand elles existent.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::External::News;

    my $now = 1786000000;
    my $day = 86400;
    my $picked = [
        { title => 'Investiture d\'Abelardo de la Espriella en Colombie',
          domain => 'lemonde.fr', url => 'https://www.lemonde.fr/very/long/path/1', epoch => $now },
        { title => 'Gianni Infantino se rend en Colombie pour l\'investiture',
          domain => 'lequipe.fr', url => 'https://www.lequipe.fr/very/long/path/2', epoch => $now - $day },
        { title => 'Crise de la FIFA : Washington promet une aide',
          domain => 'bfmtv.com', url => 'https://www.bfmtv.com/very/long/path/3', epoch => $now - 2*$day },
    ];

    my $segments = Mediabot::External::News::_news_article_segments($picked, sub {
        my ($url) = @_;
        return 'https://tinyurl.com/' . substr($url, -1);
    });
    $assert->is(scalar @$segments, 3, 'mb617-800: trois segments article produits');
    $assert->like($segments->[0], qr/\x0314\d\d\/\d\d lemonde\.fr\x03 /,
        'mb617-800: date+source en gris, comme le TCL');
    $assert->like($segments->[0], qr/\x1f\x0312https:\/\/tinyurl\.com\/1\x0f/,
        'mb617-800: lien raccourci bleu souligne');
    $assert->like($segments->[1], qr/Gianni Infantino/,
        'mb617-800: le titre reste visible');

    my $lines = Mediabot::External::News::_news_article_lines($segments, 260);
    $assert->ok(@$lines >= 2, 'mb617-800: emballage sur plusieurs lignes quand necessaire');
    $assert->like($lines->[0], qr/\x0307\|\x03/,
        'mb617-800: separateur orange entre segments');
    $assert->like(join("\n", @$lines), qr/tinyurl\.com\/3/,
        'mb617-800: tous les liens restent presents');

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/News.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/_news_article_segments\(\$display_articles,\s*\n?\s*sub \{ _news_shorten_url\(\$tiny_http, shift\) \}\)/,
        'mb617-800: le runtime construit les lignes article a partir de la liste de presentation');
    $assert->like($src, qr/if \(@\$article_lines\) \{\s*push \@lines, \@\$article_lines;\s*\}\s*else \{/s,
        'mb617-800: les lignes article sont privilegiees sur Sources:');
    $assert->like($src, qr/sub _news_shorten_url \{/,
        'mb617-800: le raccourcisseur tinyurl existe');
    $assert->like($src, qr{tinyurl\.com/api-create\.php\?url=},
        'mb617-800: tinyurl utilise son endpoint public');
    $assert->like($src, qr/last if \@segments >= 3;/,
        'mb617-800: on borne le nombre d articles exposes');
    $assert->like($src, qr/last if \@lines >= 2;/,
        'mb617-800: la synthese reste bornee a deux lignes');
    $assert->like($src, qr/my \$summary_count = 0;/,
        'mb617-800: le badge ne doit ouvrir que la premiere ligne de synthese');
    $assert->like($src, qr/timeout => 2, max_size => 4096/,
        'mb617-800: tinyurl a un timeout court pour respecter le budget async');
    $assert->like($src, qr/Prefer three different publishers/,
        'mb617-800: la presentation privilegie des sources distinctes');
};
