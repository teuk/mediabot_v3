# t/cases/656_mb441_chronos_excerpt_utf8.t
# =============================================================================
# mb441 — L'extrait du premier message dans !chronos est tronqué UTF-8-safe.
#
# mbChronos_ctx affichait le premier message du canal (publictext, OCTETS
# UTF-8) tronqué par `substr($t, 0, 60) . '...'` : si la coupe tombait entre
# les deux octets d'un caractère accenté, l'extrait finissait en séquence UTF-8
# invalide (mojibake). mb441 route ce site par le helper partagé mb429
# Mediabot::Helpers::truncate_utf8.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_656 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Le helper réel produit un extrait valide ----------------------
    require Mediabot::Helpers;
    my $s = "abc" . chr(0xC3) . chr(0xA9) . ('x' x 100);   # abc é xxxx...
    # tronque juste après "abc" + premier octet du é
    my $r = Mediabot::Helpers::truncate_utf8($s, 4);
    (my $b = $r) =~ s/\.\.\.\z//;
    my $chk = $b;
    my $valid = eval { Encode::decode('UTF-8', $chk, Encode::FB_CROAK); 1 } ? 1 : 0;
    $assert->is($valid, 1, 'extrait tronqué reste UTF-8 valide');
    $assert->is($b, 'abc', 'caractère accenté incomplet retiré');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_656(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbChronos_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/\$first_text = Mediabot::Helpers::truncate_utf8\(\$first_text, 60\)/,
        'extrait via truncate_utf8');
    $assert->unlike($code, qr/substr\(\$first_text, 0, 60\) \. '\.\.\.'/,
        'plus de substr brut');

    $assert->like($src, qr/mb441-B1/, 'tag mb441-B1');
};
