# t/cases/620_mb402_trivia_hint_structure.t
# =============================================================================
# mb402 — L'indice trivia préserve la structure de la réponse.
#
# Avant : hint = première lettre + '_' x (length-1), ESPACES COMPRIS :
# "emile zola" -> "e_________" (le joueur ne savait pas qu'il y a deux mots,
# ni leur longueur). mb402 : seuls les caractères de mot sont masqués ;
# espaces, tirets et apostrophes restent visibles.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_620 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Reproduction fidèle de la logique mb402.
sub _hint {
    my ($ans) = @_;
    return '' unless length $ans;
    my $rest = substr($ans, 1);
    $rest =~ s/[^\s'\-]/_/g;
    return substr($ans, 0, 1) . $rest;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique -----------------------------------------------------
    $assert->is(_hint('paris'),            'p____',            'mot simple');
    $assert->is(_hint('emile zola'),       'e____ ____',       'deux mots: espace visible');
    $assert->is(_hint("rock 'n' roll"),    "r___ '_' ____",    'apostrophes visibles');
    $assert->is(_hint('jean-paul sartre'), 'j___-____ ______', 'tirets visibles');
    $assert->is(_hint('42'),               '4_',               'numérique');
    $assert->is(_hint('a'),                'a',                'réponse d\'une lettre');
    $assert->is(_hint(''),                 '',                 'réponse vide');
    # longueur inchangée (aucun caractère ajouté/perdu).
    $assert->is(length(_hint('emile zola')), length('emile zola'), 'longueur préservée');

    # --- 2. Scan source ------------------------------------------------------
    my $src = _slurp_620(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    (my $code = $src) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/\$rest =~ s\/\[\^\\s'\\-\]\/_\/g;/,
        'le hint masque seulement les caractères de mot');
    $assert->unlike($code, qr/'_' x \(length\(\$ans\) - 1\)/,
        'plus de masquage plein (espaces compris)');
    $assert->like($src, qr/mb402-R1/, 'tag mb402-R1');
};
