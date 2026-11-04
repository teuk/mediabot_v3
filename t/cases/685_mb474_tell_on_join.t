# t/cases/685_mb474_tell_on_join.t
# =============================================================================
# mb474 — Les messages différés (!remind <nick> / !tell <nick>) sont délivrés
#         quand le destinataire REJOINT le canal, pas seulement quand il parle.
#
# Avant : deliverReminders() n'était appelé que dans le handler de message
# (mediabot.pl ~1812). Un nick qui rejoignait et lisait sans parler ne recevait
# jamais le message qu'on lui avait laissé.
#
# mb474 :
#   [1] appelle aussi deliverReminders() dans on_message_JOIN (au retour) ;
#   [2] ajoute l'alias !tell -> mbRemind_ctx (même logique, nom intuitif) ;
#   [3] documente !tell.
#
# Pas de vrai serveur IRC dans le conteneur : on vérifie le câblage par scan,
# et on s'assure que la délivrance au JOIN réutilise le MÊME deliverReminders
# idempotent (marque delivered=1 avant l'envoi -> pas de double délivrance).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_685 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $main = _slurp_685(File::Spec->catfile('.', 'mediabot.pl'));

    # -------------------------------------------------------------------------
    # [1] Délivrance au JOIN câblée dans on_message_JOIN
    # -------------------------------------------------------------------------
    my ($join) = $main =~ /(sub on_message_JOIN \{.*?\n\}\n)/s;
    $join //= '';
    $assert->ok($join ne '', 'on_message_JOIN localisé');
    $assert->like($join, qr/deliverReminders\s*\(\s*\$mediabot\s*,\s*\$sNick\s*,\s*\$target_name\s*\)/,
        '[1] deliverReminders(nick, channel) appelé sur JOIN');
    $assert->like($join, qr/mb474/, '[1] ajout tracé mb474');
    # L'appel doit être dans le bloc "else" (nick != bot), donc après userOnJoin.
    $assert->like($join, qr/userOnJoin.*deliverReminders/s,
        '[1] délivrance placée pour un autre nick que le bot (après userOnJoin)');
    # best-effort : sous eval, ne casse pas le JOIN.
    $assert->like($join, qr/eval \{ Mediabot::UserCommands::deliverReminders/,
        '[1] délivrance best-effort sous eval');

    # -------------------------------------------------------------------------
    # [2] Alias !tell -> mbRemind_ctx
    # -------------------------------------------------------------------------
    my $med = _slurp_685(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($med,
        qr/tell\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*mbRemind_ctx\(\$ctx\)\s*\}/,
        '[2] alias tell -> mbRemind_ctx dans le registre');

    # -------------------------------------------------------------------------
    # [3] Documentation help de tell
    # -------------------------------------------------------------------------
    $assert->like($med, qr/^tell\|tell <nick> <msg>\|public\|/m,
        '[3] tell documenté dans le help');

    # MB1100: real pre-send claims, due filtering and repeated delivery are
    # exercised by 397/1337/1339/1384. Avoid pinning a comment or code spelling.
};
