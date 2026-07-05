# t/cases/667_mb454_dbcommands_truncate_utf8.t
# =============================================================================
# mb454 — DBCommands : troncatures de lignes de pagination UTF-8-safe.
#
# Huit sites de DBCommands.pm tronquaient les lignes d'affichage (timers,
# countcmd/topcmd/popcmd/lastcmd/searchcmd… au format "[NN/MM]:") avec un
# substr($x, 0, 357) . '...' BRUT. Ces lignes contiennent du texte issu de la
# DB (noms/commandes/actions), potentiellement accentué (octets UTF-8). Couper
# à l'octet 357 peut trancher un caractère multi-octets en deux -> séquence
# invalide -> mojibake au point de coupe sur le fil.
#
# mb454 route ces huit sites vers le helper partagé truncate_utf8 (mb429), qui
# retire une éventuelle séquence multi-octets incomplète. La garde
# `length(...) > 360` est conservée : les lignes courtes restent inchangées.
#
# Le comportement du helper lui-même est déjà couvert par 644_mb429 ; ici on
# valide (a) la conversion des huit sites et (b) l'absence de substr brut.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_667 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_667(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    # DBCommands importe bien le helper (use Mediabot::Helpers -> @EXPORT).
    $assert->like($src, qr/^use Mediabot::Helpers;/m,
        'DBCommands importe Mediabot::Helpers (truncate_utf8 disponible)');

    # 1. Plus AUCUN substr brut à 357 dans DBCommands.
    my $raw = () = $src =~ /substr\(\$\w+, 0, 357\)/g;
    $assert->is($raw, 0, 'aucun substr($x, 0, 357) brut restant dans DBCommands');

    # 2. Les huit sites sont convertis vers truncate_utf8($x, 357).
    my $conv = () = $src =~ /truncate_utf8\(\$(?:out|line), 357\)/g;
    $assert->is($conv, 8, 'les 8 troncatures de pagination passent par truncate_utf8');

    # 3. La garde de longueur (> 360) est préservée : les lignes courtes ne sont
    #    pas touchées, on ne tronque que ce qui dépasse.
    my $guards = () = $src =~ /if \(length\(\$(?:out|line)\) > 360\) \{/g;
    $assert->is($guards, 8, 'garde `length > 360` conservée sur les 8 sites');

    # 4. Sanity : le helper cité est bien le partagé (même nom que mb429).
    $assert->like($src, qr/truncate_utf8/, 'appel au helper partagé truncate_utf8');
};
