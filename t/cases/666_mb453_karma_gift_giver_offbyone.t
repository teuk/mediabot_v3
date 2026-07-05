# t/cases/666_mb453_karma_gift_giver_offbyone.t
# =============================================================================
# mb453 — processKarma : off-by-one du compteur gift_giver.
#
# gift_giver se débloque quand $given_pos (nombre de +1 donnés par le voteur)
# atteint 100 (Achievements::check_karma, seuil >= 100). Or, dans processKarma,
# $given_pos était calculé en parcourant _karma_log AVANT que le vote courant
# n'y soit poussé (le push a lieu plus bas dans la même itération). Résultat :
# le 100e don était évalué comme 99 -> gift_giver se débloquait au 101e don.
#
# mb453-B1 amorce $given_pos à 1 quand le vote courant est un don positif (++),
# 0 sinon, puis ajoute les dons historiques du ring buffer.
#
# Pas de DBI/bot réel : on valide (a) la SÉMANTIQUE du comptage corrigé sur une
# fixture _karma_log, et (b) la présence de l'amorçage dans le source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_666 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Réplique EXACTE de la logique corrigée : dons historiques dans le ring buffer
# + le don courant s'il est un ++.
sub _given_pos {
    my ($op, $nick, $klog) = @_;
    my $given_pos = ($op eq '++') ? 1 : 0;
    for my $e (@$klog) {
        $given_pos++ if defined $e->{from}
                     && lc($e->{from}) eq lc($nick)
                     && ($e->{delta} // '') eq '+1';
    }
    return $given_pos;
}

# Réplique de l'ANCIENNE logique (buggée) pour le témoin.
sub _given_pos_old {
    my ($op, $nick, $klog) = @_;
    my $given_pos = 0;
    for my $e (@$klog) {
        $given_pos++ if defined $e->{from}
                     && lc($e->{from}) eq lc($nick)
                     && ($e->{delta} // '') eq '+1';
    }
    return $given_pos;
}

return sub {
    my ($assert) = @_;

    my $voter = 'Te[u]K';

    # --- 1. Sémantique : le 100e don doit compter comme 100 --------------------
    # Log contenant 99 dons positifs déjà effectués par le voteur (pas encore le
    # 100e, qui est le vote courant, donc absent du log).
    my @klog99 = map { { from => $voter, delta => '+1' } } (1 .. 99);

    $assert->is(_given_pos_old('++', $voter, \@klog99), 99,
        "témoin: ancienne logique compte 99 au moment du 100e don (bug)");
    $assert->is(_given_pos('++', $voter, \@klog99), 100,
        "corrigé: le 100e don positif est bien compté comme 100 (gift_giver débloqué à temps)");

    # --- 2. Un vote négatif ne s'auto-compte pas ------------------------------
    $assert->is(_given_pos('--', $voter, \@klog99), 99,
        "un vote -- n'incrémente pas le compteur de dons positifs");

    # --- 3. Casse et autres voteurs ------------------------------------------
    my @mixed = (
        { from => 'te[u]k', delta => '+1' },   # même voteur, casse différente
        { from => 'someone', delta => '+1' },  # autre voteur
        { from => $voter,    delta => '-1' },   # même voteur mais don négatif
    );
    # historique du voteur = 1 (le +1 en casse différente) ; +1 pour le ++ courant
    $assert->is(_given_pos('++', $voter, \@mixed), 2,
        "compte insensible à la casse, ignore les autres voteurs et les -1");

    # --- 4. Premier don : de 0 à 1 -------------------------------------------
    $assert->is(_given_pos('++', $voter, []), 1,
        "tout premier don positif compte pour 1 (et non 0)");

    # --- 5. Scan de source ----------------------------------------------------
    my $src = _slurp_666(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($pk) = $src =~ /(sub processKarma \{.*?\n\}\n)/s;
    $pk //= '';
    $assert->ok($pk ne '', 'sub processKarma extraite');

    $assert->like($pk,
        qr/my \$given_pos = \(\$op eq '\+\+'\) \? 1 : 0;/,
        'processKarma: given_pos amorcé selon le vote courant (mb453-B1)');
    $assert->like($pk, qr/mb453-B1/, 'tag mb453-B1 présent');

    # Non-régression : le seuil et l'appel check_karma sont inchangés.
    $assert->like($pk, qr/check_karma\(\s*\$target,\s*\$channel,\s*\$score,\s*\$nick,\s*\$given_pos\s*\)/,
        'processKarma: appel check_karma inchangé (mêmes arguments)');
};
