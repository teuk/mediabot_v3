# t/cases/810_mb627_sargable_date_predicates.t
# =============================================================================
# mb627 — les predicats de date redeviennent utilisables par l'index.
#
# CLASSE DE DEFAUT : une fonction appliquee a la COLONNE dans un WHERE
# (DATE(ts), YEAR(ts), MONTH(ts)) interdit a MariaDB d'utiliser l'index
# (id_channel, ts) : la requete balaie. Sur la table de teuk (>10 M lignes),
# c'est un balayage complet a chaque appel de la commande. mb577 avait
# converti six sites, mb625 en avait converti deux autres — trois restaient,
# dont un OUBLI evident : la branche « mois courant » se trouve juste sous
# today/yesterday, deja convertis.
#
#   [1] recensement : plus aucun predicat non-indexable, SAUF celui qui ne
#       peut mathematiquement pas l'etre (meme jour sur TOUTES les annees),
#       et il porte l'explication sur place.
#   [2] fenetre 365 jours : DATE(ts) >= D devient ts >= D (equivalent exact,
#       DATE() tronque vers le bas).
#   [3] mois courant : plage [1er du mois, 1er du mois suivant).
#   [4] onthisday : YEAR+MONTH+DAY d'une annee CONNUE = une journee, donc une
#       plage [jour, lendemain).
#   [5] ARITE DES BINDS : l'expression apparait DEUX fois dans la plage, donc
#       les valeurs doivent etre fournies deux fois — dans les deux modes
#       (date explicite ou date du jour). C'est la ou une telle conversion
#       casse silencieusement.
#   [6] aucune regression de perimetre : les autres conditions sont intactes.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/UserCommands.pm'
        or die $!; local $/; <$fh> };

    # [1] recensement de la classe
    my @bad;
    for my $line (split /\n/, $src) {
        next if $line =~ /^\s*(?:#|--)/;                      # commentaires
        next if $line =~ /GROUP BY|ORDER BY|SELECT|COUNT\(DISTINCT/;
        push @bad, $line if $line =~ /\b(?:DATE|YEAR|MONTH|DAY|DATE_FORMAT)\s*\(\s*(?:cl\.)?ts\s*[,)]/
                         && $line =~ /(?:AND|WHERE)\s/;
    }
    my @unexplained = grep { $_ !~ /\$md_expr|\$year_bound/ } @bad;
    $assert->is(scalar @unexplained, 0,
        'mb627-810: plus aucun predicat non-indexable hors du cas impossible');
    # Les lignes restantes sont les DEFINITIONS de $md_expr / $year_bound, et
    # elles ne servent plus qu'a la requete de balayage multi-annees : la
    # conversion des deux requetes par annee les a liberees.
    $assert->is(scalar @bad, 3,
        'mb627-810: seules les definitions du cas impossible subsistent');
    my $md_uses = () = $src =~ /AND \$md_expr/g;
    $assert->is($md_uses, 1,
        'mb627-810: md_expr ne sert plus qu a UNE requete (le balayage)');
    $assert->like($src, qr/cherche le meme jour SUR TOUTES les annees/,
        'mb627-810: ... et il porte son explication sur place');

    # [2] fenetre 365 jours
    $assert->like($src, qr/AND cl\.ts >= CURDATE\(\) - INTERVAL 365 DAY/,
        'mb627-810: la fenetre 365j est une plage');
    $assert->ok($src !~ /AND DATE\(cl\.ts\) >= CURDATE\(\) - INTERVAL 365 DAY/,
        'mb627-810: ... et l ancienne forme a disparu');

    # [3] mois courant (l oubli de mb577)
    $assert->like($src,
        qr/\$date_filter\s+= "cl\.ts >= DATE_FORMAT\(CURDATE\(\), '%Y-%m-01'\)"/,
        'mb627-810: le mois courant commence au 1er');
    $assert->like($src, qr/INTERVAL 1 MONTH/,
        'mb627-810: ... et se termine au 1er du mois suivant');
    $assert->ok($src !~ /YEAR\(cl\.ts\) = YEAR\(CURDATE\(\)\)/,
        'mb627-810: ... l ancienne forme fonctionnelle a disparu');
    # les branches voisines, converties par mb577, sont intactes
    $assert->like($src, qr/cl\.ts >= CURDATE\(\) AND cl\.ts < CURDATE\(\) \+ INTERVAL 1 DAY/,
        'mb627-810: la branche du jour reste une plage');
    $assert->like($src, qr/cl\.ts >= CURDATE\(\) - INTERVAL 1 DAY AND cl\.ts < CURDATE\(\)/,
        'mb627-810: celle de la veille aussi');

    # [4] onthisday : une journee = une plage
    $assert->like($src, qr/my \$day_range_sql = "ts >= \$day_range_expr AND ts < \$day_range_expr \+ INTERVAL 1 DAY";/,
        'mb627-810: la journee visee devient une plage fermee');
    my $per_year = () = $src =~ /AND \$day_range_sql/g;
    $assert->is($per_year, 2,
        'mb627-810: les DEUX requetes par annee l utilisent');
    $assert->ok($src !~ /AND YEAR\(ts\)\s+= \?\n\s+AND \$md_expr/,
        'mb627-810: ... et plus aucune ne combine YEAR(ts) et md_expr');

    # [5] ARITE DES BINDS — le point ou ce genre de conversion casse en silence
    my ($expr_block) = $src =~ /my \$day_range_expr = (.*?);\n/s;
    $assert->ok(defined $expr_block, 'mb627-810: expression de journee localisee');
    for my $mode (
        [ 1, "STR_TO_DATE(CONCAT(?, '-', ?, '-', ?), '%Y-%m-%d')", 3 ],
        [ 0, "STR_TO_DATE(CONCAT(?, DATE_FORMAT(CURDATE(), '-%m-%d')), '%Y-%m-%d')", 1 ],
    ) {
        my ($has_date, $expr, $n) = @$mode;
        my $sql   = "ts >= $expr AND ts < $expr + INTERVAL 1 DAY";
        my $holes = () = $sql =~ /\?/g;
        $assert->is($holes, $n * 2,
            "mb627-810: mode has_date=$has_date — l expression apparait deux fois");
    }
    # la construction du code fournit bien les valeurs DEUX fois
    my $twice = () = $src =~ /\$day_range_binds->\(\$(?:r->\{y\}|ry)\), \$day_range_binds->\(\$(?:r->\{y\}|ry)\)/g;
    $assert->is($twice, 2,
        'mb627-810: les deux requetes passent les binds DEUX fois');
    $assert->like($src, qr/return \$has_date \? \(\$year, \$month, \$day\) : \(\$year\);/,
        'mb627-810: l ordre des binds suit l ordre des points d interrogation');

    # [6] perimetre inchange
    for my $keep (
        [ qr/AND CHAR_LENGTH\(publictext\) BETWEEN 25 AND 300/, 'filtre de longueur des citations' ],
        [ qr/AND event_type IN \('public','action'\)/,          'filtre de type d evenement' ],
        [ qr/GROUP BY nick ORDER BY c DESC LIMIT 3/,            'podium par annee' ],
    ) {
        $assert->like($src, $keep->[0], "mb627-810: $keep->[1] conserve");
    }
};
