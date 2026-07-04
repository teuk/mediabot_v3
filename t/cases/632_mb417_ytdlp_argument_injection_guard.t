# t/cases/632_mb417_ytdlp_argument_injection_guard.t
# =============================================================================
# mb417 — SÉCURITÉ : la requête utilisateur passée à yt-dlp est précédée de
# '--' (fin d'options).
#
# _start_download() construit @cmd puis y ajoutait la requête IRC via
# `push @cmd, $query`. exec @cmd (forme liste) protège du shell, mais PAS de
# l'analyse d'options par yt-dlp : une requête commençant par '-' est traitée
# comme une OPTION. "--exec=CMD" tient en un seul argv et est une option
# valide de yt-dlp -> exécution de commande arbitraire (injection d'arguments,
# ex. `m play --exec=touch /tmp/pwned`). mb417 insère '--' avant la requête,
# forçant yt-dlp à traiter tout ce qui suit comme un terme de recherche.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_632 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_632(File::Spec->catfile('.', 'Mediabot', 'Radio', 'Request.pm'));
    my ($body) = $src =~ /(sub _start_download \{.*?\n\}\n)/s; $body //= '';
    $assert->ok($body ne '', '_start_download extraite');
    (my $code = $body) =~ s/^\s*#.*$//mg;

    # La requête est ajoutée précédée de '--'.
    $assert->like($code, qr/push \@cmd, '--', \$query;/,
        "requête précédée de '--' (fin d'options)");
    # Plus de push nu de la requête (sans le '--').
    $assert->unlike($code, qr/push \@cmd, \$query;/,
        "plus d'ajout nu de la requête");
    # L'exec reste en forme liste (pas de shell).
    $assert->like($code, qr/exec \@cmd;/, 'exec en forme liste (pas de shell)');

    # --- Démonstration de l'effet du '--' ---------------------------------
    # Sous argparse (yt-dlp), tout ce qui suit '--' est positionnel.
    my @cmd = ('yt-dlp', '-x');
    my $malicious = '--exec=touch /tmp/pwned';
    my @safe = (@cmd, '--', $malicious);
    # Le terme malicieux est bien le DERNIER élément, précédé de '--'.
    $assert->is($safe[-2], '--',        "'--' précède immédiatement la requête");
    $assert->is($safe[-1], $malicious,  'la requête reste un argument positionnel');

    $assert->like($src, qr/mb417-B1/, 'tag mb417-B1');
};
