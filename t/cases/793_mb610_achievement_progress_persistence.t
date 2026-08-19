# t/cases/793_mb610_achievement_progress_persistence.t
# =============================================================================
# mb610 — la progression vers les achievements SURVIT au redemarrage.
#   [1] registre : bump rend la nouvelle valeur, progress la relit, cle
#       canonique lc(nick)+lc(canal) — 'Teuk' sur '#Chan' et 'teuk' sur
#       '#chan' sont le MEME merite.
#   [2] merite par canal (un achievement se debloque par canal).
#   [3] PERSISTANCE REELLE : une instance ecrit, une seconde instance
#       relit le meme fichier et retrouve les compteurs (= le redemarrage).
#   [4] format v2 : enveloppe {version, profiles, progress} ; un fichier
#       HERITE (table de profils a plat) se charge sans perte et repart
#       en v2 — les unlocks existants de teuk sont preserves.
#   [5] plafond : au-dela de $MAX_PROGRESS_ENTRIES, ce sont les compteurs
#       les PLUS FAIBLES qui tombent, jamais les plus avances.
#   [6] cablage : les 6 familles de compteurs passent par le registre, y
#       compris trivia et quotegame dont le hook recevait le score de la
#       PARTIE (palier 100 inatteignable) ; repli si pas d'achievements.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

my $DIR = tempdir(CLEANUP => 1);

{
    package Log793; sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<:utf8', $path or die "open $path: $!";
    local $/; my $raw = <$fh>; close $fh;
    return JSON::PP->new->utf8(0)->decode($raw);
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    my $path = "$DIR/ach.json";
    my $A = Mediabot::Achievements->new(path => $path, logger => Log793->new);

    # [1] increment, lecture, canonicalisation
    $assert->is($A->bump_progress('horoscope', 'teuk', '#chan'), 1,
        'mb610-793: le premier increment rend 1');
    $assert->is($A->bump_progress('horoscope', 'teuk', '#chan'), 2,
        'mb610-793: le suivant rend 2');
    $assert->is($A->progress('horoscope', 'teuk', '#chan'), 2,
        'mb610-793: la lecture retrouve la valeur');
    $assert->is($A->bump_progress('horoscope', 'TeuK', '#CHAN'), 3,
        'mb610-793: casse du nick ET du canal repliees (meme merite)');
    $assert->is($A->progress('horoscope', 'inconnu', '#chan'), 0,
        'mb610-793: un inconnu vaut 0, jamais undef');
    $assert->is($A->bump_progress('horoscope', undef, '#chan'), 0,
        'mb610-793: un nick absent n incremente rien');

    # [2] merite par canal
    $A->bump_progress('horoscope', 'teuk', '#autre');
    $assert->is($A->progress('horoscope', 'teuk', '#chan'), 3,
        'mb610-793: les canaux ne se melangent pas');
    $assert->is($A->progress('horoscope', 'teuk', '#autre'), 1,
        'mb610-793: chaque canal a son propre merite');
    $A->bump_progress('duel_win', 'teuk', '#chan');
    $assert->is($A->progress('horoscope', 'teuk', '#chan'), 3,
        'mb610-793: les types de compteur ne se melangent pas non plus');

    # [3] LE POINT DE LA DEMANDE : survivre au redemarrage
    $A->save(1);
    my $B = Mediabot::Achievements->new(path => $path, logger => Log793->new);
    $assert->is($B->progress('horoscope', 'teuk', '#chan'), 3,
        'mb610-793: une instance NEUVE retrouve la progression (redemarrage)');
    $assert->is($B->progress('duel_win', 'teuk', '#chan'), 1,
        'mb610-793: ... pour tous les types');
    $assert->is($B->bump_progress('horoscope', 'teuk', '#chan'), 4,
        'mb610-793: et elle repart de la ou on s etait arrete');
    my $all = $B->progress_for_nick('teuk', '#chan');
    $assert->is(join(',', map { "$_=$all->{$_}" } sort keys %$all),
        'duel_win=1,horoscope=4',
        'mb610-793: progress_for_nick rend les compteurs non nuls');

    # [4] format v2 + heritage
    $B->save(1);
    my $file = _read_file($path);
    $assert->is($file->{version}, '2', 'mb610-793: fichier ecrit en v2');
    $assert->ok(ref $file->{profiles} eq 'HASH' && ref $file->{progress} eq 'HASH',
        'mb610-793: enveloppe {profiles, progress}');
    my $legacy = "$DIR/legacy.json";
    open my $lf, '>:utf8', $legacy or die $!;
    print {$lf} JSON::PP->new->utf8(0)->encode({
        "teuk\x00#chan" => { first_msg => 1700000000, megaphone => 1700000001 } });
    close $lf;
    my $C = Mediabot::Achievements->new(path => $legacy, logger => Log793->new);
    my $kept = $C->get_for_nick('teuk', '#chan');
    $assert->is(scalar(keys %$kept), 2,
        'mb610-793: fichier HERITE — les unlocks existants sont preserves');
    $assert->is($C->progress('horoscope', 'teuk', '#chan'), 0,
        'mb610-793: ... et la progression demarre a zero, sans erreur');
    $C->bump_progress('mood', 'teuk', '#chan');
    $C->save(1);
    my $migrated = _read_file($legacy);
    $assert->is($migrated->{version}, '2',
        'mb610-793: le fichier herite repart en v2 au prochain save');
    $assert->ok(exists $migrated->{profiles}{"teuk\x00#chan"}{megaphone},
        'mb610-793: ... unlocks toujours la apres migration');

    # [5] plafond : les plus faibles tombent
    {
        local $Mediabot::Achievements::MAX_PROGRESS_ENTRIES = 3;
        my $D = Mediabot::Achievements->new(path => "$DIR/cap.json", logger => Log793->new);
        $D->bump_progress('mood', "petit$_", '#chan') for 1 .. 3;   # valeur 1
        $D->bump_progress('mood', 'grand', '#chan') for 1 .. 9;     # valeur 9
        $assert->is($D->progress('mood', 'grand', '#chan'), 9,
            'mb610-793: le compteur le plus avance survit au plafond');
        my $left = scalar keys %{ $D->{progress}{mood} };
        $assert->is($left, 3, 'mb610-793: le plafond est respecte');
    }

    # [6] cablage des 6 familles
    my $users = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/UserCommands.pm'
        or die $!; local $/; <$fh> };
    my $social = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/SocialHistory.pm'
        or die $!; local $/; <$fh> };
    my $wired_src = $users . "\n" . $social;
    my $wired = 0;
    for my $kind (qw(horoscope compat mood duel_win trivia_correct quotegame_solved)) {
        $wired++ if $wired_src =~ /_ach_progress\(\$self, '\Q$kind\E'/;
    }
    $assert->is($wired, 6, 'mb610-793: les 6 familles de compteurs passent au registre');
    $assert->like($social, qr/sub _ach_progress \{.*?return undef unless \$ach->can\('bump_progress'\)/s,
        'mb610-793: repli silencieux si le systeme d achievements est absent');
    $assert->like($users, qr/my \$total = _ach_progress\(\$self, 'trivia_correct'.*?\/\/ \$score;/s,
        'mb610-793: trivia — total cumule, avec repli sur le score de partie');
    $assert->like($users, qr/check_trivia\(\$nick, \$channel, \$total, \$response_time\)/,
        'mb610-793: ... et c est bien le total qui part au hook');
    $assert->like($users, qr/check_quotegame\(\$sNick, \$sChannel, \$qg_total\)/,
        'mb610-793: quotegame — idem (palier 50 enfin atteignable)');
};
