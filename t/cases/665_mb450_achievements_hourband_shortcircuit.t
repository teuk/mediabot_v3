# t/cases/665_mb450_achievements_hourband_shortcircuit.t
# =============================================================================
# mb450 — check_msg : perf du GROUP BY HOUR(ts) sur CHANNEL_LOG.
#
# Le hook check_msg lance, par (nick,canal) et par passage non caché, une
# agrégation horaire sur CHANNEL_LOG (1 M+ lignes en prod Undernet) pour les
# achievements night_owl / early_bird. Historiquement, GROUP BY HOUR(ts) imposait un « Using temporary +
# filesort ». mb657 conserve les gardes mb450 mais remplace ce GROUP BY par
# deux agrégats conditionnels dans une seule requête.
#
# mb450-B1 garde deux protections, étendues par mb657 :
#   1. court-circuit mathématique contre le plus petit seuil encore verrouillé ;
#   2. throttle horaire (_hourband_check_ts).
#
# mb657 rend night_owl/early_bird mesurables et ajoute deux paliers nuit, sans
# ajouter une seconde requête horaire.
#
# Pas de DBI réel : on valide (a) la SÉMANTIQUE (impossibilité < 50, seuils
# préservés) et (b) le CÂBLAGE dans le source (garde n>=50, throttle 3600, tag).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_665 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Réplique fidèle de la règle de déblocage horaire (identique avant/après mb450) :
# night_owl si >= 50 messages en tranche 0..5h, early_bird si >= 50 en 6..8h.
sub _would_unlock {
    my (%by_h) = @_;
    my $night = 0; $night += ($by_h{$_} // 0) for (0..5);
    my $morn  = 0; $morn  += ($by_h{$_} // 0) for (6..8);
    return {
        night_owl  => ($night >= 50 ? 1 : 0),
        early_bird => ($morn  >= 50 ? 1 : 0),
    };
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique : le court-circuit ne peut jamais masquer un unlock ----
    # Si le total ($n) < 50, aucune tranche ne peut atteindre 50 (une tranche
    # est un sous-ensemble du total). Donc sauter le scan quand $n < 50 est sûr.
    my $max_n_skipped = 49;
    # Pire cas possible sous le seuil : tout concentré sur une heure.
    my $r = _would_unlock(3 => $max_n_skipped);   # 49 messages à 3h du matin
    $assert->is($r->{night_owl}, 0, 'n=49 concentré en nuit : night_owl impossible (court-circuit sûr)');
    $assert->is($r->{early_bird}, 0, 'n=49 : early_bird impossible aussi');

    # Juste au-dessus du seuil, le déblocage reste possible (logique préservée).
    my $r2 = _would_unlock(2 => 50);
    $assert->is($r2->{night_owl}, 1, 'n>=50 concentré en nuit : night_owl toujours débloquable');
    my $r3 = _would_unlock(7 => 50);
    $assert->is($r3->{early_bird}, 1, 'n>=50 le matin : early_bird toujours débloquable');

    # Répartition qui ne franchit aucun seuil malgré n>=50 : rien ne se débloque.
    # 8 msg/h sur 0..12h : nuit(0..5)=48 (<50), matin(6..8)=24 (<50) -> rien,
    # bien que le total (104) dépasse 50. Vérifie que le franchissement du
    # court-circuit ne suffit pas à débloquer sans franchir un seuil de tranche.
    my $r4 = _would_unlock(map { $_ => 8 } (0..12));
    $assert->is($r4->{night_owl}, 0, 'n=104, 8/h sur 0..12h : nuit=48 (<50), pas de night_owl');
    $assert->is($r4->{early_bird}, 0, 'n=104, 8/h : matin=24 (<50), pas de early_bird');

    # --- 2. Câblage dans le source ------------------------------------------
    my $src = _slurp_665(File::Spec->catfile('.', 'Mediabot', 'Achievements.pm'));
    my ($cm) = $src =~ /(sub check_msg \{.*?\n\}\n)/s;
    $cm //= '';
    $assert->ok($cm ne '', 'sub check_msg extraite');

    # Garde de court-circuit : mb657 dérive le plancher du plus petit seuil
    # encore verrouillé, au lieu de figer 50 dans le code.
    $assert->like($cm, qr/\@hour_pending/,
                  'check_msg: liste uniquement les paliers horaires encore verrouilles');
    $assert->like($cm, qr/\$hour_floor/,
                  'check_msg: le court-circuit est derive des seuils configurables');
    $assert->like($cm, qr/\$n\s*>=\s*\$hour_floor/,
                  'check_msg: aucun scan si le total ne peut atteindre le prochain palier');

    # Throttle horaire : clé mémoire + fenêtre de 3600 s.
    $assert->like($cm, qr/_hourband_check_ts/,
                  'check_msg: cache mémoire _hourband_check_ts présent');
    $assert->like($cm, qr/>=\s*3600/,
                  'check_msg: throttle horaire (3600 s) présent');

    # mb657: une SEULE requête ramène les deux bandes sans GROUP BY/filesort.
    $assert->unlike($cm, qr/GROUP BY HOUR\(cl\.ts\)/,
                    'check_msg: ancien GROUP BY HOUR(ts) retire');
    $assert->like($cm, qr/SUM\(CASE\s+WHEN HOUR\(cl\.ts\) BETWEEN 0 AND 5/s,
                  'check_msg: agrégat conditionnel nuit présent');
    $assert->like($cm, qr/SUM\(CASE\s+WHEN HOUR\(cl\.ts\) BETWEEN 6 AND 8/s,
                  'check_msg: agrégat conditionnel matin présent');

    require Mediabot::Achievements;
    $assert->is(Mediabot::Achievements::threshold(undef, 'night_owl'), 50,
                  'check_msg: Night Owl vaut toujours 50 par defaut');
    $assert->is(Mediabot::Achievements::threshold(undef, 'midnight_regular'), 250,
                  'check_msg: Midnight Regular vaut 250 par defaut');
    $assert->is(Mediabot::Achievements::threshold(undef, 'creature_night'), 1000,
                  'check_msg: Creature of the Night vaut 1000 par defaut');
    $assert->is(Mediabot::Achievements::threshold(undef, 'early_bird'), 50,
                  'check_msg: Early Bird vaut toujours 50 par defaut');

    # Le filtre event_type des 3 requêtes (garanti par mb347) n'a pas bougé.
    my $sql_only = $cm;
    $sql_only =~ s/^\s*#.*$//mg;
    $sql_only =~ s/--.*$//mg;
    my $n_evt = () = $sql_only =~ /event_type IN \('public','action'\)/g;
    $assert->is($n_evt, 3, 'check_msg: toujours 3 requêtes filtrant event_type (non-régression mb347)');

    $assert->like($cm, qr/mb450-B1/, 'tag mb450-B1 présent');
};
