# t/cases/636_mb421_fortnite_float_formatting.t
# =============================================================================
# mb421 — Les stats Fortnite flottantes (K/D, taux de victoire) sont arrondies
# pour l'affichage IRC.
#
# fortnite-api.com renvoie winRate/kd en flottants non bornés (ex.
# kd=1.2345678901). Affichés bruts, ils étaient illisibles sur le canal. mb421
# arrondit à l'affichage (K/D 2 décimales, winRate 1) et supprime les zéros
# inutiles (2.00 -> 2, 1.50 -> 1.5), tout en laissant passer une valeur non
# numérique inchangée (API inattendue).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_636 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Reproduction fidèle du formateur mb421.
sub _fmt {
    my ($v, $dp) = @_;
    return $v unless defined $v && $v =~ /\A-?\d+(?:\.\d+)?\z/;
    my $s = sprintf("%.${dp}f", $v);
    $s =~ s/\.?0+\z// if index($s, '.') >= 0;
    return $s;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique -----------------------------------------------------
    $assert->is(_fmt('1.2345678901', 2), '1.23', 'K/D long arrondi à 2 décimales');
    $assert->is(_fmt('8.5', 1),          '8.5',  'winRate 1 décimale');
    $assert->is(_fmt('2.0', 2),          '2',    'zéros inutiles supprimés (2.0 -> 2)');
    $assert->is(_fmt('1.50', 2),         '1.5',  '1.50 -> 1.5');
    $assert->is(_fmt('0', 1),            '0',    'zéro entier inchangé');
    $assert->is(_fmt(12.34, 1),          '12.3', 'arrondi au dixième');
    $assert->is(_fmt('n/a', 2),          'n/a',  'valeur non numérique laissée telle quelle');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_636(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my ($body) = $src =~ /(sub fortniteStats_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/\$kd\s*=\s*\$fmt_num->\(\$kd, 2\);/,       'K/D formaté à 2 décimales');
    $assert->like($code, qr/\$win_rate\s*=\s*\$fmt_num->\(\$win_rate, 1\);/, 'winRate formaté à 1 décimale');
    $assert->like($code, qr/index\(\$s, '\.'\) >= 0/,                  'suppression des zéros inutiles');
    $assert->like($src, qr/mb421-R1/, 'tag mb421-R1');
};
