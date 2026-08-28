# t/cases/798_mb615_worker_output_facade.t
# =============================================================================
# mb615 — la sortie d'un worker est capturee QUEL QUE SOIT le chemin d'appel.
#
# INCIDENT (prod #test, 2026-08-08) : « m actualités » demarrait son
# worker (« CommandAsync: 'actualites' worker started ») et ne repondait
# JAMAIS, sans la moindre erreur. Les facades du worker n'existaient que sur
# les alias IMPORTES par Mediabot::UserCommands ; External::News appelle la
# forme QUALIFIEE Mediabot::Helpers::botPrivmsg, qui partait donc vers la
# vraie socket depuis l'ENFANT — lequel ne doit jamais y toucher — avant que
# POSIX::_exit ne jette le tampon. Toutes les commandes asynchrones
# existantes vivant dans UserCommands, le trou n'avait jamais mordu.
#
#   [1] un code qui ecrit par la forme QUALIFIEE est capture.
#   [2] un code qui ecrit par l'alias IMPORTE l'est toujours (non-regression).
#   [3] les trois genres (privmsg, notice, action) et les deux chemins.
#   [4] rien n'a fui vers les VRAIS helpers pendant la collecte.
#   [5] les globs sont RESTAURES a la sortie : le rejeu cote parent doit
#       repasser par les vrais helpers, sinon le bot se parle a lui-meme.
#   [6] bornes et erreurs inchangees (MAX_INTENTS, exception remontee).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::CommandAsync;
    require Mediabot::Helpers;
    require Mediabot::UserCommands;

    # Les VRAIS helpers sont remplaces le temps du test par des mouchards :
    # si la facade laisse fuir un appel, il atterrit ici.
    my @leaked;
    no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg      = sub { push @leaked, [ 'q-privmsg', $_[2] ]; 1 };
    local *Mediabot::Helpers::botNotice       = sub { push @leaked, [ 'q-notice',  $_[2] ]; 1 };
    local *Mediabot::Helpers::botAction       = sub { push @leaked, [ 'q-action',  $_[2] ]; 1 };
    local *Mediabot::UserCommands::botPrivmsg = sub { push @leaked, [ 'i-privmsg', $_[2] ]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @leaked, [ 'i-notice',  $_[2] ]; 1 };

    # [1] + [2] + [3] : les deux chemins, les trois genres
    my ($intents, $truncated, $ok, $err) =
        Mediabot::CommandAsync::_collect_intents_run(sub {
            Mediabot::Helpers::botPrivmsg(undef, '#chan', 'qualifie');
            Mediabot::Helpers::botNotice(undef, 'nick', 'qualifie-notice');
            Mediabot::Helpers::botAction(undef, '#chan', 'qualifie-action');
            Mediabot::UserCommands::botPrivmsg(undef, '#chan', 'importe');
            Mediabot::UserCommands::botNotice(undef, 'nick', 'importe-notice');
            1;
        });
    $assert->ok($ok, 'mb615-798: le code s execute');
    $assert->is(scalar @$intents, 5, 'mb615-798: cinq intents collectes');
    my $texts = join ',', map { $_->[2] } @$intents;
    $assert->like($texts, qr/\bqualifie\b/,
        'mb615-798: la forme QUALIFIEE est capturee (le bug de #test)');
    $assert->like($texts, qr/importe/,
        'mb615-798: l alias IMPORTE l est toujours (non-regression)');
    my $kinds = join ',', map { $_->[0] } @$intents;
    $assert->is($kinds, 'privmsg,notice,action,privmsg,notice',
        'mb615-798: genre et ordre preserves sur les deux chemins');
    $assert->is($intents->[0][1], '#chan', 'mb615-798: la cible est conservee');

    # [4] aucune fuite pendant la collecte
    $assert->is(scalar @leaked, 0,
        'mb615-798: rien n a atteint les vrais helpers depuis l enfant');

    # [5] restauration a la sortie : le rejeu parent doit etre reel
    Mediabot::Helpers::botPrivmsg(undef, '#chan', 'apres');
    Mediabot::UserCommands::botPrivmsg(undef, '#chan', 'apres-importe');
    $assert->is(scalar @leaked, 2,
        'mb615-798: les globs sont restaures des la sortie de la collecte');
    $assert->is($leaked[0][0], 'q-privmsg',
        'mb615-798: ... la forme qualifiee redevient le vrai helper');
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/CommandAsync.pm'
        or die $!; local $/; <$fh> };
    my $collect_end = index($src, 'sub _replay_intents');
    my $local_pos   = index($src, 'local *Mediabot::Helpers::botPrivmsg');
    $assert->ok($local_pos > 0 && $local_pos < $collect_end,
        'mb615-798: la facade vit DANS la collecte, pas autour du rejeu');
    $assert->like($src, qr/sub _replay_intents \{.*?Mediabot::Helpers::botPrivmsg/s,
        'mb615-798: le rejeu parent passe bien par les vrais helpers');

    # [6] bornes et erreurs
    @leaked = ();
    my ($big, $trunc) = Mediabot::CommandAsync::_collect_intents_run(sub {
        Mediabot::Helpers::botPrivmsg(undef, '#chan', "l$_") for 1 .. 200;
        1;
    });
    $assert->is(scalar @$big, $Mediabot::CommandAsync::MAX_INTENTS,
        'mb615-798: la borne d intents tient sur le chemin qualifie');
    $assert->ok($trunc, 'mb615-798: ... et la troncature est signalee');
    # [7] corollaire du meme piege : un garde-fou pose DANS le worker est un
    # trompe-l'oeil (le processus fils meurt avec ses compteurs). Celui de
    # 'actualites' vit donc cote parent, et couvre TOUS ses alias — sinon on
    # le contourne en tapant 'news' juste apres 'actualites'.
    my $hsrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Helpers.pm'
        or die $!; local $/; <$fh> };
    my ($defaults) = $hsrc =~ /my %defaults = \((.*?)\);/s;
    my $covered = 0;
    for my $alias (qw(actualites actualite actu news)) {
        $covered++ if defined $defaults && $defaults =~ /^\s*\Q$alias\E\s*=> \d+,/m;
    }
    $assert->is($covered, 4,
        'mb615-798: le cooldown parent couvre les 4 alias d actualites');
    my $coolbot = bless { _cmd_cooldown => {}, _cmd_cooldown_conf => {} }, 'Cooldown798';
    $assert->is(Mediabot::Helpers::checkCmdCooldown($coolbot, '#chan', 'actualites'), 0,
        'mb615-798: premiere actualites ouvre le bucket partage');
    $assert->ok(Mediabot::Helpers::checkCmdCooldown($coolbot, '#chan', 'news') > 0,
        'mb615-798: news juste apres actualites est bloque par LE MEME bucket');
    $assert->ok(Mediabot::Helpers::checkCmdCooldown($coolbot, '#chan', 'actu') > 0,
        'mb615-798: actu ne contourne pas non plus le cooldown');
    my $nsrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/News.pm'
        or die $!; local $/; <$fh> };
    $assert->ok($nsrc !~ /\$self->\{_news_(?:cache|last)\}/,
        'mb615-798: plus aucun compteur pose dans le worker');

    my (undef, undef, $ok2, $err2) = Mediabot::CommandAsync::_collect_intents_run(sub {
        Mediabot::Helpers::botPrivmsg(undef, '#chan', 'avant');
        die "boom\n";
    });
    $assert->ok(!$ok2 && $err2 =~ /boom/,
        'mb615-798: une exception du code est remontee, pas avalee');
};
