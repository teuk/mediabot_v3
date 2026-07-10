# t/cases/707_mb497_seen_enriched.t
# =============================================================================
# mb497 — !seen enrichi :
#   [1] le dernier message (last_msg / CHANNEL_LOG) est NETTOYÉ pour l'affichage
#       (codes couleur/formatage/contrôle IRC retirés, longueur bornée) ;
#   [2] un indice d'activité récente est ajouté : "[N msg in last 24h]" compté
#       dans CHANNEL_LOG sur le canal pertinent, pour distinguer un habitué
#       actif d'un fantôme.
#
# Style aligné sur les tests seen voisins (190/192) : scan de source des
# invariants + vérification comportementale de la logique de nettoyage.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_707 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _extract_sub_707 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = pos($src); my $depth = 1; my $pos = $start; my $len = length($src);
    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);
        if ($ch eq '{') { $depth++; }
        elsif ($ch eq '}') { $depth--; return substr($src, $start, $pos - $start) if $depth == 0; }
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_707(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $body = _extract_sub_707($src, 'mbSeen_ctx');
    $assert->ok(defined $body && $body ne '', 'mbSeen_ctx localisé');

    # --- [1] helper de nettoyage du last_msg --------------------------------
    $assert->like($body, qr/my \$fmt_last = sub \{/, '[1] helper fmt_last défini');
    $assert->like($body, qr/\\x03\\d\{0,2\}/, '[1] retire les codes couleur mIRC');
    $assert->like($body, qr/truncate_utf8\(\$txt, 200/, '[1] longueur bornée (200)');
    # appliqué aux branches d'affichage (message/part/quit)
    my $applied = () = $body =~ /\$fmt_last->\(\$seen_row->\{last_msg\}\)/g;
    $assert->ok($applied >= 3, "[1] fmt_last appliqué aux branches message/part/quit ($applied)");
    # plus d'injection brute de last_msg dans ces branches
    $assert->unlike($body, qr/my \$last = \$seen_row->\{last_msg\} \/\/ '';/,
        '[1] plus de last_msg brut injecté');

    # --- [2] compteur d'activité 24h ----------------------------------------
    $assert->like($body, qr/last 24h/, '[2] libellé "last 24h" présent');
    $assert->like($body, qr/INTERVAL 24 HOUR/, '[2] fenêtre SQL 24h');
    $assert->like($body, qr/FROM CHANNEL_LOG/, '[2] compteur sur CHANNEL_LOG');
    $assert->like($body, qr/event_type IN \('public','action'\)/,
        '[2] convention event_type (garde projet)');
    $assert->like($body, qr/\$self->\{channels\}\{lc \$act_chan\}/,
        '[2] lookup canal en lc (garde 625)');
    # best-effort : jamais bloquant (execute sous eval)
    $assert->like($body, qr/eval \{ \$sth_act->execute/,
        '[2] compteur best-effort (execute sous eval)');
    # n'affiche le compteur que s'il y a de l'activité
    $assert->like($body, qr/\$msg \.= " \[\$c msg in last 24h\]" if \$c > 0;/,
        '[2] compteur affiché seulement si > 0');
    # ne s'exécute pas sur le cas "jamais vu"
    $assert->like($body, qr/if \(\$msg !~ \/\^I don't remember\//,
        '[2] pas de compteur si nick jamais vu');

    # --- comportement du nettoyage (réplique de fmt_last) -------------------
    my $clean = sub {
        my ($txt) = @_;
        return '' unless defined $txt && $txt ne '';
        $txt =~ s/[\x02\x0f\x16\x1d\x1f]//g;
        $txt =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
        $txt =~ s/[\x00-\x08\x0a-\x1f]/ /g;
        $txt =~ s/\s{2,}/ /g;
        $txt =~ s/^\s+|\s+$//g;
        return $txt;
    };
    $assert->is($clean->("\x02hello\x0f"), 'hello', 'nettoyage: gras retiré');
    $assert->is($clean->("\x0304,00red\x03"), 'red', 'nettoyage: couleurs retirées');
    $assert->is($clean->("a\x01b\x02c"), 'a bc', 'nettoyage: contrôle -> espace, gras retiré');
    $assert->is($clean->("x\x07y"), 'x y', 'nettoyage: BEL -> espace');
    $assert->is($clean->("plain message"), 'plain message', 'nettoyage: texte simple intact');
};
