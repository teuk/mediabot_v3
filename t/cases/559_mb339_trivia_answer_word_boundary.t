# t/cases/559_mb339_trivia_answer_word_boundary.t
# =============================================================================
# mb339 — La validation de réponse trivia ne doit plus faire un match SOUS-CHAÎNE.
#
# checkTrivia faisait :
#     lc($text) eq $answer || lc($text) =~ /\Qanswer\E/
# La 2e branche était un match sous-chaîne brut : un mot plus long contenant la
# réponse validait à tort ("war" gagnée par "warsaw"/"toward"), et une mention
# incidente terminait la manche. Le quotegame résolvait déjà cette classe de bug
# (mb121-B2) en bornant le terme par des frontières de caractères. mb339 applique
# le même bornage alphanumérique à la trivia.
#
# Le test :
#   1. reproduit le prédicat corrigé et vérifie la classification (in-word rejeté,
#      exact / délimité / ponctuation / multi-mots / accents acceptés ou rejetés
#      correctement) ;
#   2. scan de source : checkTrivia utilise bien le bornage (?<![A-Za-z0-9]) … (?!…)
#      et n'a plus le match sous-chaîne nu.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction EXACTE du prédicat mb339 (doit rester synchrone avec checkTrivia).
sub _matched {
    my ($text, $answer) = @_;
    $answer = lc $answer;
    return ( lc($text) eq $answer
             || lc($text) =~ /(?<![A-Za-z0-9\x80-\xFF])\Q$answer\E(?![A-Za-z0-9\x80-\xFF])/ ) ? 1 : 0;
}

sub _slurp_559 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Classification --------------------------------------------------
    my @cases = (
        # [ texte utilisateur, réponse, attendu, description ]
        [ 'warsaw',           'war',      0, 'in-word début (faux positif corrigé)' ],
        [ 'toward',           'war',      0, 'in-word milieu' ],
        [ 'war',              'war',      1, 'exact' ],
        [ 'the war ended',    'war',      1, 'mot délimité par espaces' ],
        [ 'paris',            'paris',    1, 'exact' ],
        [ 'it is paris!',     'paris',    1, 'ponctuation finale' ],
        [ 'i think new york', 'new york', 1, 'multi-mots délimité' ],
        [ 'newyorker',        'new york', 0, 'pas de sous-chaîne contiguë' ],
        [ 'WAR',              'war',      1, 'insensible à la casse' ],
        [ "caf\x{e9}",        "caf\x{e9}",1, 'accent exact' ],
        [ "caf\x{e9}s",       "caf\x{e9}",0, 'accent + s -> rejet' ],
        # mb443: octet d'accent adjacent ne fait plus frontière (byte-safe).
        [ "gar".chr(0xC3).chr(0xA7)."on", 'on', 0, 'garçon ne valide plus "on" (mb443)' ],
        [ 'the answer is on', 'on',       1, '"on" délimité par espaces reste valide' ],
    );

    for my $c (@cases) {
        my ($text, $answer, $exp, $desc) = @$c;
        $assert->is(_matched($text, $answer), $exp, "trivia match: $desc");
    }

    # --- 2. Scan de source --------------------------------------------------
    my $src = _slurp_559(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    $assert->like(
        $src,
        qr/\(\?<!\[A-Za-z0-9\\x80-\\xFF\]\)\\Q\$answer\\E\(\?!\[A-Za-z0-9\\x80-\\xFF\]\)/,
        'checkTrivia borne la réponse par des frontières byte-safe (mb443)'
    );
    $assert->unlike(
        $src,
        qr/lc\(\$text\)\s*=~\s*\/\\Q\$trivia->\{answer\}\\E\//,
        'checkTrivia n\'a plus le match sous-chaîne nu'
    );
    $assert->like($src, qr/mb339-B1/, 'tag mb339-B1 présent');
};
