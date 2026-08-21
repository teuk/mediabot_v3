# t/cases/567_mb348_publictext_filter_sweep.t
# =============================================================================
# mb348 — Balayage systémique du faux filtre « est un message ».
#
# `publictext IS NOT NULL` était utilisé partout comme synonyme de « message »,
# alors qu'il est faux (logBotAction stocke publictext verbatim : join/part ''
# IS NOT NULL, kick/mode/topic/notice portent du texte). mb347 avait corrigé
# Achievements ; mb348 étend la correction à toutes les stats/contextes basés sur
# CHANNEL_LOG :
#   - UserCommands.pm + SocialHistory.pm : requêtes de stats historiques ;
#     MB670 a déplacé une partie de ces requêtes vers SocialHistory sans
#     modifier le contrat de filtrage ;
#   - External/Claude.pm : 2 requêtes de contexte IA ;
#   - Partyline.pm : _cmd_ai (contexte IA).
# Laissé VOLONTAIREMENT : Partyline _cmd_chanlog (.logs) — viewer de log brut
# Master-only qui peut légitimement afficher tous les événements.
#
# Pas de DBI réel : validation par (a) rappel de la sémantique des deux filtres
# et (b) scan de source exhaustif.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_567 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# compte les occurrences SQL (hors lignes de commentaire Perl/SQL)
sub _count_sql {
    my ($src, $needle) = @_;
    my $sql = $src;
    $sql =~ s/^\s*#.*$//mg;
    my $n = () = $sql =~ /\Q$needle\E/g;
    return $n;
}

return sub {
    my ($assert) = @_;

    # --- Rappel sémantique (témoin) --------------------------------------
    my @clog = (
        ['public','hi'], ['action','waves'],
        ['join',''], ['part','bye'], ['kick','bob (flood)'], ['mode','+o bob'],
        ['topic','t'], ['notice','n'], ['quit','timeout'],
    );
    my $old = grep { defined $_->[1] } @clog;                              # publictext IS NOT NULL
    my $new = grep { $_->[0] eq 'public' || $_->[0] eq 'action' } @clog;   # event_type filter
    $assert->is($old, 9, 'témoin: ancien filtre compte tous les événements');
    $assert->is($new, 2, 'nouveau filtre: seuls public+action');

    # --- UserCommands + SocialHistory : contrat préservé après MB670 ------
    my $uc = _slurp_567(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $sh = _slurp_567(File::Spec->catfile('.', 'Mediabot', 'SocialHistory.pm'));
    my $stats_src = $uc . "\n" . $sh;
    $assert->is(_count_sql($uc, 'publictext IS NOT NULL'), 0,
                'UserCommands: plus aucun publictext IS NOT NULL en SQL');
    $assert->is(_count_sql($sh, 'publictext IS NOT NULL'), 0,
                'SocialHistory: aucun publictext IS NOT NULL réintroduit');
    $assert->ok(_count_sql($stats_src, "event_type IN ('public','action')") >= 27,
                'UserCommands + SocialHistory: >= 27 requêtes conservent le filtre public/action');
    $assert->ok(_count_sql($sh, "event_type IN ('public','action')") > 0,
                'SocialHistory: les requêtes extraites conservent le filtre public/action');
    $assert->like($uc, qr/mb348-B1/, 'UserCommands: tag mb348-B1');

    # --- External/Claude.pm : contexte IA balayé -------------------------
    my $cl = _slurp_567(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    $assert->is(_count_sql($cl, 'publictext IS NOT NULL'), 0,
                'Claude: plus aucun publictext IS NOT NULL en SQL');
    $assert->ok(_count_sql($cl, "event_type IN ('public','action')") >= 2,
                'Claude: contexte IA filtre event_type');
    $assert->like($cl, qr/mb348-B1/, 'Claude: tag mb348-B1');

    # --- Partyline.pm : _cmd_ai balayé, .logs (_cmd_chanlog) PRÉSERVÉ -----
    my $pl = _slurp_567(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'))
           . "\n"
           . _slurp_567(File::Spec->catfile('.', 'Mediabot', 'Partyline', 'Commands.pm'));
    # _cmd_ai utilise le filtre
    my ($ai) = $pl =~ /(sub _cmd_ai \{.*?\n\}\n)/s; $ai //= '';
    $assert->like($ai, qr/event_type IN \('public','action'\)/, 'Partyline _cmd_ai: filtre event_type');
    (my $ai_sql = $ai) =~ s/^\s*#.*$//mg;   # retire les commentaires (qui citent l'ancien filtre)
    $assert->unlike($ai_sql, qr/publictext IS NOT NULL/, 'Partyline _cmd_ai: plus de publictext IS NOT NULL en SQL');
    # _cmd_chanlog (.logs) : initialement laissé non filtré en mb348, puis filtré
    # en mb349 (à la demande). On vérifie ici qu'il utilise désormais le filtre SQL.
    my ($logs) = $pl =~ /(sub _cmd_chanlog \{.*?\n\}\n)/s; $logs //= '';
    $assert->ok($logs ne '', 'Partyline _cmd_chanlog extraite');
    (my $logs_sql = $logs) =~ s/^\s*#.*$//mg;   # retire les commentaires
    $assert->like($logs_sql, qr/event_type IN \('public','action'\)/,
                  'Partyline .logs: filtre event_type (mb349)');
    $assert->unlike($logs_sql, qr/publictext IS NOT NULL/,
                  'Partyline .logs: plus de publictext IS NOT NULL en SQL');
    # plus aucune occurrence SQL de publictext IS NOT NULL dans Partyline
    $assert->is(_count_sql($pl, 'publictext IS NOT NULL'), 0,
                'Partyline: plus aucun publictext IS NOT NULL en SQL');
    $assert->like($pl, qr/mb348-B1/, 'Partyline: tag mb348-B1');
};
