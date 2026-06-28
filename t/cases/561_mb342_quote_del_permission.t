# t/cases/561_mb342_quote_del_permission.t
# =============================================================================
# mb342 — Durcissement de la permission de suppression de quote.
#
# Avant : tout compte authentifié de niveau "User" (le plus bas) pouvait
# supprimer N'IMPORTE QUELLE quote du canal — incohérent avec le reste du bot
# (channelDelUser >= 400, ban >= 75, purge Owner). La suppression est destructive.
#
# Après : mbQuoteDel n'autorise la suppression que si l'appelant est
#   - Administrator+ (niveau global), OU
#   - l'AUTEUR de la quote (id_user), OU
#   - de niveau-canal >= 100 sur ce canal.
#
# Ce test :
#   1. reproduit la décision de permission et vérifie la table de vérité ;
#   2. scan de source : mbQuoteDel porte bien le gate (has_level Administrator +
#      comparaison auteur + seuil canal validé par configuration).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction EXACTE de la décision mb342 (doit rester synchrone avec mbQuoteDel).
#   $is_admin  : 1 si l'appelant est Administrator+
#   $caller_uid: id de l'appelant (ou undef/'' si inconnu)
#   $author_id : id_user de la quote (0 = anonyme)
#   $chan_ok   : 1 si checkUserChannelLevel(...,100) passerait
sub _allow {
    my ($is_admin, $caller_uid, $author_id, $chan_ok) = @_;

    my $is_author = (defined($caller_uid) && $caller_uid ne ''
                     && defined($author_id)
                     && "$caller_uid" eq "$author_id") ? 1 : 0;

    my $has_chan_priv = 0;
    if (!$is_admin && !$is_author && defined($caller_uid) && $caller_uid ne '') {
        $has_chan_priv = $chan_ok ? 1 : 0;
    }

    return ($is_admin || $is_author || $has_chan_priv) ? 1 : 0;
}

sub _slurp_561 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Table de vérité ----------------------------------------------
    #          is_admin, uid, author, chan_ok => attendu
    my @cases = (
        [ 1, 5,   9, 0, 1, 'Administrator supprime n\'importe quelle quote' ],
        [ 0, 7,   7, 0, 1, 'auteur supprime sa propre quote (chan < 100)' ],
        [ 0, 5,   9, 1, 1, 'non-auteur avec niveau-canal >= 100' ],
        [ 0, 5,   9, 0, 0, 'non-auteur, niveau-canal < 100 -> refus' ],
        [ 0, 5,   0, 0, 0, 'quote anonyme (author 0), bas niveau -> refus' ],
        [ 1, 5,   0, 0, 1, 'Administrator supprime une quote anonyme' ],
        [ 0, 5,   0, 1, 1, 'quote anonyme + niveau-canal >= 100 -> ok' ],
        [ 0, '',  9, 1, 0, 'uid inconnu -> refus même si chan_ok' ],
    );

    for my $c (@cases) {
        my ($adm, $uid, $auth, $chan, $exp, $desc) = @$c;
        $assert->is(_allow($adm, $uid, $auth, $chan), $exp, "q del: $desc");
    }

    # --- 2. Scan de source ------------------------------------------------
    my $src = _slurp_561(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));
    my ($del) = $src =~ /(sub mbQuoteDel \{.*?\n\})/s;
    $del //= '';

    $assert->ok($del ne '', 'mbQuoteDel source extrait');
    $assert->like($del, qr/has_level\('Administrator'\)/, 'gate: Administrator+');
    $assert->like($del, qr/\$caller_uid.*eq.*\$author_id|"\$caller_uid" eq "\$author_id"/s,
                  'gate: comparaison auteur');
    $assert->like($del, qr/QUOTE_DELETE_CHANNEL_LEVEL/,
                  'gate: seuil canal lu depuis la configuration');
    $assert->like($del, qr/checkUserChannelLevel\([^)]*,\s*\$quote_delete_level\)/,
                  'gate: seuil configuré transmis au contrôle canal');
    $assert->like($del, qr/mb342-B1/, 'tag mb342-B1 présent');
    # la requête d'existence récupère bien l'auteur
    $assert->like($del, qr/SELECT QUOTES\.id_quotes, QUOTES\.id_user/, 'auteur récupéré dans le SELECT');
};
