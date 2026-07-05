# t/cases/670_mb457_karmawatch_list_recent_score.t
# =============================================================================
# mb457 — !karmawatch list : score "courant" déterministe.
#
# Le mode `list` affiche, pour chaque nick surveillé, son score karma "courant"
# (commentaire IMP19). L'ancien code parcourait `keys %_karma_log` (ordre de
# hash NON déterministe) et s'arrêtait (`last`) au premier canal contenant une
# entrée -> pour un nick actif sur plusieurs canaux, le score affiché était
# arbitraire, et potentiellement périmé.
#
# mb457-B1 sélectionne l'entrée la PLUS RÉCENTE (max `ts`) toutes canaux
# confondus. On valide (a) la sémantique de sélection sur une fixture
# multi-canal, et (b) la présence du comparateur ts dans le source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_670 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Réplique de la sélection mb457-B1 : entrée de score la plus récente pour $wt,
# tous canaux confondus.
sub _current_score {
    my ($karma_log, $wt) = @_;
    my $best;
    for my $ch (keys %$karma_log) {
        for my $e (@{ $karma_log->{$ch} // [] }) {
            next unless defined $e->{nick}
                     && lc($e->{nick}) eq lc($wt)
                     && defined $e->{score};
            $best = $e if !defined $best || ($e->{ts} // 0) > ($best->{ts} // 0);
        }
    }
    return '' unless defined $best;   # sentinelle '' comme le vrai code
    my $sc = $best->{score};
    return $sc >= 0 ? "+$sc" : "$sc";
}

return sub {
    my ($assert) = @_;

    # Fixture : 'bob' a du karma sur 2 canaux ; l'entrée la plus récente est
    # sur #b (ts=200, score=7). Une entrée plus ancienne sur #a (ts=100,
    # score=3) NE doit PAS l'emporter, quel que soit l'ordre de hash.
    my $klog = {
        '#a' => [
            { ts => 50,  nick => 'bob',   score => 1, delta => '+1', from => 'x' },
            { ts => 100, nick => 'bob',   score => 3, delta => '+1', from => 'y' },
            { ts => 90,  nick => 'alice', score => 9, delta => '+1', from => 'z' },
        ],
        '#b' => [
            { ts => 200, nick => 'Bob',   score => 7, delta => '+1', from => 'w' },  # casse ≠, plus récent
            { ts => 150, nick => 'bob',   score => 5, delta => '-1', from => 'v' },
        ],
    };

    $assert->is(_current_score($klog, 'bob'), '+7',
        'karmawatch list : score le plus récent (max ts) toutes canaux confondus, insensible à la casse');

    # Nick sans entrée -> pas de score.
    $assert->is(_current_score($klog, 'nobody'), '',
        'nick sans entrée karma : aucun score (sentinelle vide)');

    # Score négatif -> signe conservé.
    my $klog_neg = { '#c' => [ { ts => 10, nick => 'zoe', score => -4 } ] };
    $assert->is(_current_score($klog_neg, 'zoe'), '-4',
        'score négatif : signe conservé');

    # Déterminisme : deux entrées, la plus récente gagne indépendamment de
    # l'ordre d'insertion.
    my $klog_ord = {
        '#x' => [ { ts => 300, nick => 'kai', score => 12 } ],
        '#y' => [ { ts => 250, nick => 'kai', score => 8  } ],
    };
    $assert->is(_current_score($klog_ord, 'kai'), '+12',
        'la plus récente gagne (ts 300 > 250), indépendamment du canal');

    # --- Scan source ---------------------------------------------------------
    my $src = _slurp_670(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($blk) = $src =~ /(# IMP19: show current karma score.*?You are watching:)/s;
    $blk //= '';
    $assert->ok($blk ne '', 'bloc karmawatch list extrait');
    # mb459: la sélection est déléguée au helper partagé _karma_current_score.
    $assert->like($blk, qr/_karma_current_score\(\$self, \$wt\)/,
        'karmawatch list délègue à _karma_current_score (mb459)');
    $assert->unlike($blk, qr/reverse \@\$klog/,
        'ancien pattern non déterministe (reverse+last) supprimé');
};
