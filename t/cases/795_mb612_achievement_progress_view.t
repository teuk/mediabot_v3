# t/cases/795_mb612_achievement_progress_view.t
# =============================================================================
# mb612 — la progression devient VISIBLE, et la grille est complete.
#   [1] chaque achievement MESURABLE declare le compteur qui le mesure ;
#       ceux qu'on ne sait pas mesurer (sniper, underdog, declencheurs
#       instantanes) le disent au lieu d'inventer une progression.
#   [2] set_progress : valeur d'etat, monotone (une lecture plus basse
#       n'efface pas un merite constate), invalides ignorees.
#   [3] les checks qui CONNAISSENT deja la valeur l'enregistrent —
#       messages, karma, karma donne, mots distincts, canaux — sans
#       requete supplementaire.
#   [4] progress_snapshot : debloque/seuil/valeur/pourcentage, un unlock
#       force la barre a 100 %, le pourcentage est borne.
#   [5] next_goals : les plus PROCHES d'abord, jamais un palier deja
#       atteint (« 137/10 (100%) » n'est pas un objectif), jamais un
#       achievement non mesurable.
#   [6] RENDU REEL de !achievements et !achievements progress : ligne
#       Next, barre, nombres lisibles, et la vue « rien de debloque » qui
#       montre enfin ce qui est a portee.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Log795; sub new { bless {}, shift } sub log { 1 }
}
{
    package Ctx795;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub bot { $_[0]{bot} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    require Mediabot::UserCommands;
    require Mediabot::Helpers;
    my $defs = Mediabot::Achievements::list_definitions();
    my $A = Mediabot::Achievements->new(path => "$DIR/a.json", logger => Log795->new);

    # [1] grille des compteurs
    my %kind_of = map { $_ => $defs->{$_}{progress_kind} } keys %$defs;
    my @measurable = grep { $kind_of{$_} } keys %kind_of;
    $assert->is(scalar @measurable, 30,
        'mb612-795: 30 achievements sur 32 sont mesurables');
    my @unmeasurable = sort grep { !$kind_of{$_} } keys %kind_of;
    $assert->is(join(',', @unmeasurable), 'trivia_sniper,underdog',
        'mb612-795: seuls les 2 declencheurs instantanes restent non mesurables');
    my %kinds = map { $_ => 1 } values %kind_of;
    delete $kinds{''}; delete $kinds{undef};
    $assert->ok($kinds{msg_count} && $kinds{karma_score} && $kinds{distinct_words}
             && $kinds{channels_active} && $kinds{trivia_correct}
             && $kinds{night_messages} && $kinds{morning_messages},
        'mb612-795: les compteurs issus de la base sont declares comme les autres');

    # [2] set_progress : etat monotone
    $assert->is($A->set_progress('msg_count', 'teuk', '#c', 4200), 4200,
        'mb612-795: une valeur d etat est enregistree');
    $assert->is($A->set_progress('msg_count', 'teuk', '#c', 3900), 4200,
        'mb612-795: une lecture PLUS BASSE n efface pas le merite constate');
    $assert->is($A->set_progress('msg_count', 'teuk', '#c', 4300), 4300,
        'mb612-795: une valeur plus haute avance');
    $assert->is($A->set_progress('msg_count', 'teuk', '#c', 'beaucoup'), 0,
        'mb612-795: une valeur non numerique est refusee');
    $assert->is($A->progress('msg_count', 'teuk', '#c'), 4300,
        'mb612-795: ... sans abimer la valeur en place');

    # [3] les checks enregistrent ce qu ils savent deja
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Achievements.pm'
        or die $!; local $/; <$fh> };
    my $recorded = 0;
    for my $pair (['msg_count', 'check_msg'], ['karma_score', 'check_karma'],
                  ['karma_given', 'check_karma'], ['distinct_words', 'check_wordcount'],
                  ['channels_active', 'check_polyphony']) {
        my ($kind, $sub) = @$pair;
        my ($body) = $src =~ /sub \Q$sub\E \{(.*?)\n\}/s;
        $recorded++ if defined $body && $body =~ /set_progress\('\Q$kind\E'/;
    }
    $assert->is($recorded, 5,
        'mb612-795: les 5 valeurs deja connues des checks sont enregistrees');
    # mb646: persistence itself is now SQL write-through, so a module-wide
    # prepare() count is no longer meaningful. The important mb612 contract is
    # unchanged: set_progress receives a value already calculated by its caller
    # and must not launch a second SELECT to recompute that merit.
    my ($set_body) = $src =~ /sub set_progress \{(.*?)\n\}/s;
    $set_body //= '';
    $assert->ok($set_body !~ /\bSELECT\b/i,
        'mb612-795: set_progress does not recompute an already-known value');

    # [4] snapshot
    $A->set_progress('karma_score', 'teuk', '#c', 41);
    $A->unlock('teuk', '#c', 'first_msg');
    my $snap = $A->progress_snapshot('teuk', '#c');
    $assert->is($snap->{karma_star}{current}, 41, 'mb612-795: valeur courante');
    $assert->is($snap->{karma_star}{threshold}, 50, 'mb612-795: seuil du catalogue');
    $assert->is($snap->{karma_star}{pct}, 82, 'mb612-795: pourcentage');
    $assert->is($snap->{first_msg}{pct}, 100,
        'mb612-795: un achievement debloque affiche 100 %');
    $assert->ok(!$snap->{trivia_sniper}{measurable},
        'mb612-795: le sniper se declare non mesurable');
    $A->set_progress('msg_count', 'teuk', '#c', 999_999);
    $assert->is($A->progress_snapshot('teuk', '#c')->{chatterbox}{pct}, 100,
        'mb612-795: le pourcentage est borne a 100');

    # [5] next_goals
    my $goals = $A->next_goals('teuk', '#c', 3);
    $assert->is(scalar @$goals, 3, 'mb612-795: trois objectifs proposes');
    $assert->ok($goals->[0]{pct} >= $goals->[1]{pct}
             && $goals->[1]{pct} >= $goals->[2]{pct},
        'mb612-795: du plus proche au plus lointain');
    $assert->ok(!grep({ $_->{id} eq 'chatterbox' } @$goals),
        'mb612-795: un palier DEJA ATTEINT n est pas propose comme objectif');
    $assert->ok(!grep({ $_->{id} eq 'first_msg' } @$goals),
        'mb612-795: un achievement debloque non plus');
    $assert->ok(!grep({ !$_->{measurable} } @$goals),
        'mb612-795: aucun objectif non mesurable');

    # [6] RENDU REEL
    my @out;
    no warnings 'redefine';
    # UserCommands importe ces fonctions : c'est SON alias qu'il faut capturer.
    local *Mediabot::UserCommands::botPrivmsg = sub { push @out, [ 'pub', $_[2] ]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @out, [ 'not', $_[2] ]; 1 };
    local *Mediabot::Helpers::getIdChansetList = sub { undef };

    my $B = Mediabot::Achievements->new(path => "$DIR/b.json", logger => Log795->new);
    $B->set_progress('distinct_words', 'teuk', '#quebec', 980);
    $B->set_progress('karma_score', 'teuk', '#quebec', 41);
    $B->bump_progress('duel_win', 'teuk', '#quebec') for 1 .. 9;
    $B->unlock('teuk', '#quebec', 'chatterbox');
    my $bot = bless { achievements => $B, logger => Log795->new }, 'Mediabot';

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx795->new(bot => $bot, nick => 'teuk', channel => '#quebec', args => []));
    my $text = join "\n", map { $_->[1] } @out;
    $assert->like($text, qr/Next: .*Wordsmith.*980\/1k \(98%\)/,
        'mb612-795: la vue par defaut annonce le prochain objectif');
    $assert->like($text, qr/Duel Warrior.*9\/10 \(90%\)/,
        'mb612-795: ... puis le suivant, dans l ordre');
    $assert->like($text, qr/!achievements progress\x02 for the full ladder/,
        'mb612-795: et renvoie vers la vue detaillee');

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx795->new(bot => $bot, nick => 'teuk', channel => '#quebec', args => ['progress']));
    $text = join "\n", map { $_->[1] } @out;
    $assert->like($text, qr/unlocked, \d+ in progress:/,
        'mb612-795: en-tete de la vue progression');
    $assert->like($text, qr/\[\x02===========\.\x02\]/,
        'mb612-795: barre de progression a 98 %');
    $assert->like($text, qr/Karma Star\x0f 41\/50 \(82%\)/,
        'mb612-795: valeurs et pourcentage sur la ligne');
    $assert->ok(!grep({ $_->[0] eq 'pub' } @out),
        'mb612-795: la vue detaillee part en notice, pas sur le canal');

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx795->new(bot => $bot, nick => 'teuk', channel => '#quebec', args => ['newbie']));
    $text = join "\n", map { $_->[1] } @out;
    $assert->like($text, qr/no achievements unlocked yet/,
        'mb612-795: un nick vierge est annonce comme tel');
    $assert->like($text, qr/Closest: .*First Steps.*0\/1/,
        'mb612-795: ... et on lui montre enfin ce qui est a portee');

    # [7] .status partyline : l'operateur voit l'etat du registre (c'est le
    # seul etat du systeme qui ne se recalcule pas).
    my $pl_src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm'
        or die $!; local $/; <$fh> };
    $assert->like($pl_src, qr/Achv:\s+%d profile\(s\), %d progress counter\(s\)/,
        'mb612-795: .status compte profils et compteurs');
    $assert->like($pl_src, qr/\(unsaved changes\)/,
        'mb612-795: ... et signale un enregistrement en attente');
};
