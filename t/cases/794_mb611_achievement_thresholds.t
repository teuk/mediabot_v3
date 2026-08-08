# t/cases/794_mb611_achievement_thresholds.t
# =============================================================================
# mb611 — le merite exige vit dans le catalogue, se regle par conf, et croit
# avec la rarete.
#   [1] chaque achievement du catalogue porte un seuil (aucun oubli), et
#       AUCUN seuil n'est plus ecrit en dur dans les verifications.
#   [2] threshold() : defaut du catalogue, surcharge conf
#       achievements.<ID>, valeurs invalides ignorees (0, negatif, texte,
#       reference) — jamais de seuil absurde par accident.
#   [3] REEQUILIBRAGE : a l'interieur d'une meme famille, le palier rare
#       exige strictement plus que l'uncommon, l'epic plus que le rare.
#   [4] les paliers rares+ ont bien ete releves par rapport a l'ancien
#       barème (le point de la demande).
#   [5] le sniper est un seuil INVERSE (secondes, <=) et reste plus severe
#       qu'avant.
#   [6] un seuil releve ne revoque RIEN : un unlock deja enregistre reste.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Conf794;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Log794; sub new { bless {}, shift } sub log { 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    my $defs = Mediabot::Achievements::list_definitions();
    my $A = Mediabot::Achievements->new(path => "$DIR/a.json", logger => Log794->new);

    # [1] catalogue complet, plus rien en dur
    my @missing = grep { !defined $A->threshold($_) } sort keys %$defs;
    $assert->is(scalar @missing, 0,
        'mb611-794: chaque achievement porte son seuil dans le catalogue');
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Achievements.pm'
        or die $!; local $/; <$fh> };
    my ($checks) = $src =~ /(# -- Hook : v.rifie les achievements 'msg'.*)/s;
    $assert->ok(defined $checks && $checks !~ /unlock\([^)]*\)\s*if[^;]*>=\s*\d/s,
        'mb611-794: aucun seuil numerique en dur dans les verifications');

    # [2] surcharge conf et garde-fous
    $assert->is($A->threshold('trivia_champion'), 300,
        'mb611-794: defaut du catalogue');
    my $tuned = Mediabot::Achievements->new(path => "$DIR/b.json", logger => Log794->new,
        bot => { conf => Conf794->new({ 'achievements.TRIVIA_CHAMPION' => '120' }) });
    $assert->is($tuned->threshold('trivia_champion'), 120,
        'mb611-794: la conf regle le seuil sans toucher au code');
    $assert->is($tuned->threshold('quote_master'), 150,
        'mb611-794: les autres gardent le defaut');
    for my $bad ('0', '-5', 'beaucoup', '') {
        my $b = Mediabot::Achievements->new(path => "$DIR/c.json", logger => Log794->new,
            bot => { conf => Conf794->new({ 'achievements.QUOTE_MASTER' => $bad }) });
        $assert->is($b->threshold('quote_master'), 150,
            "mb611-794: valeur conf invalide ('$bad') ignoree");
    }
    my $r = Mediabot::Achievements->new(path => "$DIR/d.json", logger => Log794->new,
        bot => { conf => Conf794->new({ 'achievements.QUOTE_MASTER' => [ 1 ] }) });
    $assert->is($r->threshold('quote_master'), 150,
        'mb611-794: une reference en conf est ignoree');

    # [3] la rarete se paie, famille par famille
    my @ladders = (
        [ 'messages',  qw(chatterbox megaphone icon legend) ],
        [ 'karma',     qw(karma_star karma_legend) ],
        [ 'trivia',    qw(trivia_rookie trivia_champion) ],
        [ 'duel',      qw(duel_warrior duel_master) ],
        [ 'quotegame', qw(quote_detective quote_master) ],
        [ 'mots',      qw(wordsmith polyglot) ],
    );
    my $monotone = 0;
    for my $ladder (@ladders) {
        my ($label, @ids) = @$ladder;
        my $ok = 1;
        for my $i (1 .. $#ids) {
            $ok = 0 unless $A->threshold($ids[$i]) > $A->threshold($ids[$i-1]);
        }
        $monotone++ if $ok;
    }
    $assert->is($monotone, scalar @ladders,
        'mb611-794: dans chaque famille, le palier suivant exige strictement plus');

    # [4] les rares+ ont ete releves (ancien barème en commentaire)
    my %was = (trivia_champion => 100, quote_master => 50, duel_master => 50,
               karma_legend => 100, gift_giver => 100, polyglot => 5_000,
               polyphony => 5, underdog => 5, legend => 100_000, matchmaker => 10,
               quote_detective => 10);
    my $raised = 0;
    for my $id (sort keys %was) {
        $raised++ if $A->threshold($id) > $was{$id};
    }
    $assert->is($raised, scalar(keys %was),
        'mb611-794: tous les paliers vises ont ete releves');
    $assert->is($A->threshold('first_msg'), 1,
        'mb611-794: le premier pas reste un premier pas');
    $assert->is($A->threshold('trivia_rookie'), 10,
        'mb611-794: les paliers d entree ne bougent pas');

    # [5] seuil inverse du sniper
    $assert->is($A->threshold('trivia_sniper'), 2,
        'mb611-794: le sniper passe a 2 secondes');
    $assert->like($src, qr/response_seconds <= \$self->threshold\('trivia_sniper'\)/,
        'mb611-794: ... et reste compare en <= (seuil inverse)');

    # [6] relever un seuil ne revoque rien
    my $E = Mediabot::Achievements->new(path => "$DIR/e.json", logger => Log794->new,
        bot => { conf => Conf794->new({ 'achievements.QUOTE_MASTER' => '10' }) });
    $E->unlock('teuk', '#chan', 'quote_master');
    my $F = Mediabot::Achievements->new(path => "$DIR/e.json", logger => Log794->new,
        bot => { conf => Conf794->new({ 'achievements.QUOTE_MASTER' => '9999' }) });
    $assert->ok(exists $F->get_for_nick('teuk', '#chan')->{quote_master},
        'mb611-794: un achievement gagne reste acquis apres un durcissement');
};
