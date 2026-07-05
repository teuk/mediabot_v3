# t/cases/673_mb460_note_search_index_matches_del.t
# =============================================================================
# mb460 — !note search : index affiché = index de suppression.
#
# `!note search <mot>` affichait les résultats numérotés 1..N selon leur position
# DANS LA LISTE DES HITS. Or `!notes del <index>` supprime selon la position dans
# la liste COMPLÈTE des notes. Quand les correspondances ne sont pas les
# premières notes, l'index affiché ne correspondait pas à l'index de suppression
# -> l'utilisateur supprimait la mauvaise note.
#
# mb460-B1 affiche l'index réel (position dans la liste complète) = celui
# qu'attend `!notes del`. On valide la sémantique (réplique) + le câblage source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_673 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Réplique de la sélection corrigée : renvoie la liste [index_complet_1based, texte].
sub _search_hits {
    my ($notes, $query) = @_;
    my @hits;
    for my $idx (0 .. $#$notes) {
        my $n   = $notes->[$idx];
        my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
        push @hits, [ $idx + 1, $txt ] if lc($txt) =~ /\Q\L$query\E/;
    }
    return @hits;
}

return sub {
    my ($assert) = @_;

    # 5 notes ; 'pizza' matche les notes en positions 2 et 4 (1-based).
    my $notes = [
        { id => 10, text => 'buy milk' },
        { id => 11, text => 'order PIZZA tonight' },
        { id => 12, text => 'call mom' },
        { id => 13, text => 'pizza dough recipe' },
        { id => 14, text => 'gym at 6' },
    ];

    my @hits = _search_hits($notes, 'pizza');
    $assert->is(scalar(@hits), 2, 'deux correspondances pour "pizza"');

    # Les index affichés doivent être 2 et 4 (positions dans la liste complète),
    # PAS 1 et 2 (positions dans les hits).
    $assert->is($hits[0][0], 2, 'premier hit affiché à l\'index 2 (et non 1)');
    $assert->is($hits[1][0], 4, 'second hit affiché à l\'index 4 (et non 2)');

    # Un !notes del sur l'index affiché supprime bien la note recherchée :
    # del 4 -> notes->[3] = 'pizza dough recipe'.
    my $del_index_shown = $hits[1][0];          # 4
    my $target_note = $notes->[$del_index_shown - 1];
    $assert->like($target_note->{text}, qr/pizza dough/,
        'l\'index affiché pointe bien la note recherchée pour !notes del');

    # Recherche insensible à la casse (PIZZA / pizza).
    $assert->like($hits[0][1], qr/PIZZA/, 'match insensible à la casse');

    # --- Câblage source ------------------------------------------------------
    my $src = _slurp_673(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($blk) = $src =~ /(# W7: !note search.*?return 1;\n    \}\n    unless \(\$text ne '')/s;
    $blk //= '';
    $assert->ok($blk ne '', 'bloc !note search extrait');
    $assert->like($blk, qr/push \@hits, \[ \$idx, \$n \]/,
        'search conserve l\'index complet de chaque hit');
    $assert->like($blk, qr/\[" \. \(\$idx \+ 1\) \. "\]/,
        'search affiche [idx+1] = index de la liste complète (mb460)');
    $assert->like($blk, qr/mb460-B1/, 'tag mb460-B1 présent');
    $assert->unlike($blk, qr/for my \$i \(0\.\.\$#hits\)/,
        'ancien indexage positionnel sur les hits supprimé');
};
