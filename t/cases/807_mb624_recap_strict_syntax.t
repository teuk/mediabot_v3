# t/cases/807_mb624_recap_strict_syntax.t
# =============================================================================
# mb624 — recap : mêmes exigences que 'ai summary', et un seul détecteur de
# fautes pour tout le bot.
#
# DEFAUT (meme maladie que mb623, commande soeur) : recap IGNORAIT EN SILENCE
# tout jeton non reconnu. « recap 2h ia » — une faute de frappe sur 'ai' —
# rendait les statistiques au lieu du resume demande, sans un mot ; « recap
# 30min » retombait sur la fenetre par defaut sans le dire. Le bot repondait
# quelque chose de plausible, donc l'utilisateur ne pouvait pas deviner qu'il
# s'etait trompe.
#
#   [1] la distance d'edition vit dans Helpers : UNE implementation, utilisee
#       par 'ai summary' comme par recap.
#   [2] recap lit ses arguments dans n'importe quel ordre.
#   [3] fautes de frappe annoncees, y compris les fenetres mal ecrites.
#   [4] jetons inconnus et doublons refuses au lieu d'etre avales.
#   [5] la syntaxe est ecrite une fois et lue par l'aide comme par les erreurs.
#   [6] aucune regression : les formes valides gardent leur sens exact.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;
    require Mediabot::UserCommands;
    require Mediabot::External::Claude;

    # [1] une seule implementation
    my $ed = Mediabot::Helpers->can('edit_distance_1');
    my $sg = Mediabot::Helpers->can('suggest_keyword');
    $assert->ok($ed && $sg, 'mb624-807: le detecteur vit dans Helpers');
    $assert->is($ed->('ia', 'ai'), 1, 'mb624-807: transposition');
    $assert->is($ed->('todya', 'today'), 1, 'mb624-807: transposition longue');
    $assert->is($ed->('wek', 'week'), 1, 'mb624-807: lettre manquante');
    $assert->is($ed->('publi', 'public'), 1, 'mb624-807: lettre en trop');
    $assert->is($ed->('teuk', 'week'), 0, 'mb624-807: deux fautes = pas une suggestion');
    $assert->is($ed->('ai', 'ai'), 0, 'mb624-807: identique n est pas une faute');
    $assert->is($ed->(undef, 'ai'), 0, 'mb624-807: undef ne meurt pas');
    $assert->is($sg->('todya', qw(today yesterday)), 'today',
        'mb624-807: le bon mot-cle est suggere');
    $assert->ok(!defined $sg->('teuk', qw(today week ai)),
        'mb624-807: un vrai pseudo n obtient aucune suggestion');
    my $csrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External/Claude.pm'
        or die $!; local $/; <$fh> };
    $assert->ok($csrc !~ /sub _edit_distance_1/,
        'mb624-807: la copie de Claude.pm a disparu (plus de divergence possible)');
    $assert->like($csrc, qr/Mediabot::Helpers::suggest_keyword/,
        'mb624-807: ... il consomme celle de Helpers');
    $assert->like($csrc, qr/require Mediabot::Helpers;/,
        'mb624-807: ... avec la dependance declaree, pas supposee');

    my $P = Mediabot::UserCommands->can('_recap_parse');
    $assert->ok($P, 'mb624-807: le parseur de recap est expose et testable');

    # [2] ordre libre
    for my $line ('2h ai', 'ai 2h', 'ai fr 45m', '45m lang=en ai') {
        my $o = $P->(split / /, $line);
        $assert->ok($o->{ai} && !@{ $o->{typos} } && !@{ $o->{unknown} },
            "mb624-807: '$line' est lu correctement");
    }
    my $o = $P->(qw(ai 2h));
    $assert->is($o->{window}, '2h', 'mb624-807: la fenetre est vue apres le mot ai');
    $o = $P->(qw(ai fr 45m));
    $assert->is($o->{lang}, 'fr', 'mb624-807: la langue coexiste avec le reste');
    $assert->is($o->{window}, '45m', 'mb624-807: ... et la fenetre aussi');

    # [3] fautes de frappe
    $o = $P->(qw(2h ia));
    $assert->is(scalar @{ $o->{typos} }, 1,
        'mb624-807: LE cas du terrain — « ia » ne passe plus en silence');
    $assert->is($o->{typos}[0][1], 'ai', 'mb624-807: ... et « ai » est suggere');
    $assert->is($o->{ai}, 0,
        'mb624-807: ... sans activer l IA par charite (sinon on devine a la place de l utilisateur)');
    $o = $P->('30min');
    $assert->is(scalar @{ $o->{typos} }, 1, 'mb624-807: une fenetre mal ecrite est dite');
    $assert->is($o->{typos}[0][1], '30m', 'mb624-807: ... avec la bonne forme');
    $o = $P->('2hours');
    $assert->is($o->{typos}[0][1], '2h', 'mb624-807: idem pour les heures');

    # [4] inconnus et doublons
    $o = $P->('@@');
    $assert->is(scalar @{ $o->{unknown} }, 1, 'mb624-807: jeton illisible refuse');
    $o = $P->(qw(2h 3h));
    $assert->is(scalar @{ $o->{duplicate} }, 1, 'mb624-807: deux fenetres = doublon');
    $assert->is($o->{window}, '2h', 'mb624-807: ... la premiere reste, aucune surprise');
    $o = $P->('lang=de');
    $assert->is($o->{bad_lang}, 'de', 'mb624-807: langue hors trio signalee');

    # [5] syntaxe unique
    my @usage = @Mediabot::UserCommands::RECAP_USAGE_LINES;
    $assert->ok(scalar @usage >= 4, 'mb624-807: la syntaxe de recap est documentee');
    $assert->like($usage[0], qr/l'ordre est libre/, 'mb624-807: elle annonce l ordre libre');
    $assert->ok((grep { /<N>m .*<N>h|<N>m \(minutes\)/ } @usage),
        'mb624-807: les deux unites de fenetre sont documentees');
    my $usrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/UserCommands.pm'
        or die $!; local $/; <$fh> };
    $usrc .= do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/SocialHistory.pm'
        or die $!; local $/; <$fh> };
    my $reads = () = $usrc =~ /RECAP_USAGE_LINES\[0\]/g;
    $assert->ok($reads >= 2,
        'mb624-807: les messages d erreur rappellent LA MEME ligne de syntaxe');
    $assert->like($usrc, qr/botNotice\(\$self, \$nick, \$_\) for \@(?:Mediabot::UserCommands::)?RECAP_USAGE_LINES;/,
        'mb624-807: ... et l aide lit la meme liste');

    # [6] non-regression des formes valides
    $o = $P->();
    $assert->ok(!$o->{ai} && !defined $o->{window} && !@{ $o->{unknown} },
        'mb624-807: recap sans argument reste recap sans argument');
    $o = $P->('2h');
    $assert->ok(!$o->{ai} && $o->{window} eq '2h',
        'mb624-807: une fenetre seule ne declenche pas l IA');
    $o = $P->('ai');
    $assert->ok($o->{ai} && !defined $o->{window},
        'mb624-807: « ai » seul garde la fenetre par defaut');
};
