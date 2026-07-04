# t/cases/619_mb401_ban_expiry_dead_helper_removed.t
# =============================================================================
# mb401 — expires_sql_from_seconds() est supprimée et ne doit pas revenir.
#
# Cette sub formatait l'expiration d'un ban avec l'horloge du PROCESS PERL
# (strftime/localtime), exactement le bug de double horloge fermé par mb350
# (expiry calculée en SQL via NOW() + INTERVAL ? SECOND). Elle n'avait plus
# aucun appelant mais restait dans ChannelBan.pm : toute réutilisation aurait
# réintroduit le désalignement Perl vs MySQL. Ce test verrouille sa disparition
# et l'invariant mb350 (expiry côté SQL uniquement).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_619 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_619(File::Spec->catfile('.', 'Mediabot', 'ChannelBan.pm'));
    (my $code = $src) =~ s/^\s*#.*$//mg;   # ignorer les commentaires

    # La sub morte a disparu (code, pas commentaires).
    $assert->unlike($code, qr/sub expires_sql_from_seconds/,
        'expires_sql_from_seconds supprimée');
    # Plus aucun formatage d'expiration côté Perl dans le module.
    $assert->unlike($code, qr/strftime\(/,
        'plus de strftime (horloge Perl) dans ChannelBan');
    # L'invariant mb350 est toujours en place : expiry en SQL.
    $assert->like($code, qr/NOW\(\)\s*\+\s*INTERVAL\s*\?\s*SECOND/,
        'expiration toujours calculée en SQL (mb350)');
    # Personne dans l'arbre n'appelle la sub supprimée.
    for my $f (glob('Mediabot/*.pm'), glob('Mediabot/*/*.pm'), 'mediabot.pl') {
        my $s = eval { _slurp_619($f) } // next;
        $s =~ s/^\s*#.*$//mg;
        if ($s =~ /expires_sql_from_seconds/) {
            $assert->ok(0, "appelant résiduel de expires_sql_from_seconds dans $f");
        }
    }
    $assert->ok(1, 'aucun appelant résiduel dans l\'arbre');
    $assert->like($src, qr/mb401-R1/, 'tag mb401-R1');
};
