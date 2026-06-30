# t/cases/589_mb370_hailo_adaptive_chatter.t
# =============================================================================
# mb370 — HailoChatter : taux corrigé (inversion) ET adaptatif au débit.
#
# Avant : `rand(100) >= ratio` => (a) INVERSÉ (ratio=97 => ~3% au lieu de 97%),
# (b) AVEUGLE au débit. mb370 : le ratio reste la CIBLE, et la proba effective
# est modulée par le débit récent du canal (compté EN MÉMOIRE, aucune table) :
#   - calme / <= référence -> effective = ratio ;
#   - plus rapide          -> effective réduite (ref/count), avec plancher.
# Décision : chatter si rand(100) < effective.
#
# Validation : (a) sémantique (= code réel, cf. scan), (b) câblage source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction fidèle de _hailo_effective_pct (Hailo.pm).
sub _eff {
    my ($base, $count, $ref, $minpct) = @_;
    $ref    //= 10;
    $minpct //= 10;
    return 0 if !defined($base) || $base <= 0;
    $base = 100 if $base > 100;
    my $factor = ($count <= $ref) ? 1.0 : ($ref / $count);
    my $floor  = $minpct / 100;
    $factor = $floor if $factor < $floor;
    my $e = $base * $factor;
    $e = 100 if $e > 100;
    $e = 0   if $e < 0;
    return $e;
}

sub _slurp_589 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Inversion corrigée : au calme, effective == ratio -------------
    $assert->is(_eff(97, 3, 10, 10),  97, 'calme: ratio 97 -> 97% (inversion corrigée)');
    $assert->is(_eff(97, 10, 10, 10), 97, 'à la référence: 97%');
    $assert->is(_eff(20, 0, 10, 10),  20, 'ratio 20 au calme -> 20%');
    $assert->is(_eff(0, 0, 10, 10),    0, 'ratio 0 -> 0%');

    # --- 2. Bridage adaptatif quand ça s'emballe --------------------------
    $assert->ok(abs(_eff(97, 20, 10, 10) - 48.5) < 0.01, 'actif (x2 réf): bridé à ~48.5%');
    $assert->ok(abs(_eff(97, 100, 10, 10) - 9.7) < 0.01, 'très actif: plancher 9.7%');
    $assert->ok(abs(_eff(97, 5000, 10, 10) - 9.7) < 0.01, 'extrême: reste au plancher 9.7%');

    # Monotonie : effective décroît (ou stagne) quand le débit augmente.
    my @e = map { _eff(80, $_, 10, 5) } (10, 20, 50, 100, 500);
    my $mono = 1;
    for my $i (1 .. $#e) { $mono = 0 if $e[$i] > $e[$i-1] + 1e-9; }
    $assert->ok($mono, 'effective monotone décroissante avec le débit');

    # Plancher respecté : jamais en dessous de ratio * minpct%.
    $assert->ok(_eff(50, 99999, 10, 20) >= 50 * 0.20 - 1e-9, 'plancher (minpct) respecté');

    # --- 3. Scan source Hailo.pm -----------------------------------------
    my $h = _slurp_589(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    $assert->like($h, qr/sub hailo_should_chatter/,   'méthode hailo_should_chatter');
    $assert->like($h, qr/sub hailo_record_activity/,  'méthode hailo_record_activity');
    $assert->like($h, qr/sub _hailo_effective_pct/,   'helper _hailo_effective_pct');
    # direction corrigée : rand(100) < effective (et non >=).
    $assert->like($h, qr/rand\(100\)\s*<\s*\$eff/, 'décision: rand(100) < effective (inversion corrigée)');
    # bridage présent : facteur ref/count + plancher.
    $assert->like($h, qr/\$ref\s*\/\s*\$count/,        'facteur de débit ref/count');
    $assert->like($h, qr/HAILO_CHATTER_REFERENCE_MSGS/, 'clé config référence');
    $assert->like($h, qr/HAILO_CHATTER_MIN_FACTOR_PCT/, 'clé config plancher');
    # ratio toujours lu en base (schéma intact), pas modifié.
    $assert->like($h, qr/get_hailo_channel_ratio/, 'ratio lu depuis la base (inchangé)');
    # mb371 strengthens the mb370 contract end-to-end: the command must expose
    # and store that same direct percentage rather than inverting it again.
    $assert->unlike($h, qr/100\s*-\s*\$stored_ratio/, 'query path does not re-invert the stored percentage');
    $assert->unlike($h, qr/100\s*-\s*\$ratio/, 'set path does not re-invert the requested percentage');
    $assert->like($h, qr/mb370-B1/, 'tag mb370-B1 (Hailo)');

    # --- 4. Scan câblage mediabot.pl -------------------------------------
    my $main = _slurp_589(File::Spec->catfile('.', 'mediabot.pl'));
    $assert->like($main, qr/->hailo_record_activity\(\$where\)/, 'enregistre le débit pour chaque message');
    $assert->like($main, qr/elsif \(\s*\$mediabot->hailo_should_chatter\(\$where\)\s*\)/,
                  'décision chatter via hailo_should_chatter');
    # l'ancienne variable inversée a disparu.
    $assert->unlike($main, qr/luckyShotHailoChatter/, 'plus de luckyShotHailoChatter (ancienne logique)');

    # --- 5. sample.conf documente les clés -------------------------------
    my $conf = _slurp_589(File::Spec->catfile('.', 'mediabot.sample.conf'));
    $assert->like($conf, qr/HAILO_CHATTER_RATE_WINDOW/,    'sample.conf: fenêtre documentée');
    $assert->like($conf, qr/HAILO_CHATTER_REFERENCE_MSGS/, 'sample.conf: référence documentée');
    $assert->like($conf, qr/HAILO_CHATTER_MIN_FACTOR_PCT/, 'sample.conf: plancher documenté');
};
