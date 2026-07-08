# t/cases/697_mb486_help_welcome.t
# =============================================================================
# mb486 — La porte d'entrée du help mène enfin quelque part.
#
# Avant : un "help" nu affichait soit "Syntax: help #channel" (en privé), soit
# les commandes dynamiques du canal — dans les deux cas, toute la structure
# d'aide interne (catégories, recherche, aide par commande) restait cachée.
#
# Après : "help" nu -> écran d'accueil (bannière + index des catégories +
# navigation). "help #channel" explicite -> commandes du canal (inchangé).
#
# [A] câblage dans mbHelp_ctx ; [B] contenu de l'écran d'accueil ;
# [C] l'index réutilise le même helper que "help commands".
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_697 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _extract_697 {
    my ($src, $name) = @_;
    return '' unless $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $1;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;
    my $src = _slurp_697(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    # --- [A] câblage : help nu -> welcome ; help #channel -> showcommands -----
    my $help = _extract_697($src, 'mbHelp_ctx');
    $assert->ok($help ne '', 'mbHelp_ctx localisé');
    $assert->like($help, qr/isIrcChannelTarget\(\$first\)/,
        '[A] help #channel explicite détecté');
    $assert->like($help, qr/userShowcommandsChannel_ctx\(\$ctx\)/,
        '[A] help #channel -> commandes du canal (conservé)');
    $assert->like($help, qr/_mbHelpSendWelcome\(\$ctx\)/,
        '[A] help nu -> écran d\'accueil');
    # l'ancien cul-de-sac a disparu
    $assert->unlike($help, qr/Syntax: help #channel/,
        '[A] plus de cul-de-sac "Syntax: help #channel"');

    # --- [B] contenu de l'écran d'accueil ------------------------------------
    my $welcome = _extract_697($src, '_mbHelpSendWelcome');
    $assert->ok($welcome ne '', '_mbHelpSendWelcome existe');
    $assert->like($welcome, qr/Mediabot help/, '[B] bannière');
    $assert->like($welcome, qr/Categories \(name = command count\):/, '[B] section catégories');
    $assert->like($welcome, qr/_mbHelpCategoryIndexCompact\(\)/,
        '[B] index compact (mb488) pour tenir sous le cap de la file');
    $assert->like($welcome, qr/Navigate:/, '[B] section navigation');
    $assert->like($welcome, qr/help <category>/, '[B] montre help <category>');
    $assert->like($welcome, qr/help <command>/, '[B] montre help <command>');
    $assert->like($welcome, qr/help search <term>/, '[B] montre help search');
    $assert->like($welcome, qr/help chansets/, '[B] montre help chansets');
    $assert->like($welcome, qr{https://github\.com/teuk/mediabot_v3/wiki},
        '[B] lien documentation');
    # pas d'appel réseau bloquant : VERSION lue localement, pas getVersion()
    $assert->like($welcome, qr/open\(my \$vfh, '<', 'VERSION'\)/,
        '[B] version lue localement (pas d\'appel réseau)');
    $assert->unlike($welcome, qr/\$self->getVersion/,
        '[B] n\'appelle pas getVersion (potentiellement réseau)');
    # respecte le cmd_char configuré
    $assert->like($welcome, qr/MAIN_PROG_CMD_CHAR/,
        '[B] utilise le cmd_char configuré');

    # --- [C] cohérence de l'index : même helper que "help commands" ----------
    my $idx = _extract_697($src, '_mbHelpSendCategoryIndex');
    $assert->like($idx, qr/_mbHelpCategoryIndexLines\(\)/,
        '[C] help commands garde l\'index détaillé (une ligne par catégorie)');

    # index détaillé : une ligne par catégorie non vide
    my @lines = Mediabot::_mbHelpCategoryIndexLines();
    $assert->ok(scalar(@lines) >= 10, '[C] index détaillé non vide (>=10 catégories)');
    my ($fac_line) = grep { /^\s+factoids\s/ } @lines;
    $assert->ok(defined $fac_line, '[C] la catégorie factoids apparaît dans l\'index détaillé');

    # index compact (welcome) : peu de lignes, contient toutes les catégories
    my @compact = Mediabot::_mbHelpCategoryIndexCompact();
    $assert->ok(scalar(@compact) <= 3, '[C] index compact tient en <=3 lignes');
    my $cjoined = join(' ', @compact);
    $assert->like($cjoined, qr/factoids\(\d+\)/, '[C] index compact liste factoids(N)');
    $assert->like($cjoined, qr/radio\(\d+\)/, '[C] index compact liste radio(N)');
};
