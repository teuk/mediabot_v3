# t/cases/626_mb408_title_truncation_and_cache_key.t
# =============================================================================
# mb408 — Deux finitions du pipeline UrlTitle :
#   (a) la troncature des titres > 300 caractères coupe à la FRONTIÈRE DE MOT
#       et ajoute une ellipse (avant : coupe brute en plein mot, sans signal) ;
#   (b) la clé du cache anti-répétition replie aussi le CANAL en lc
#       (cohérence avec la clé canonique lc de mb407).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_626 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_626(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));

    # --- 1. Troncature : sub réelle extraite et exécutée --------------------
    my ($body) = $src =~ /(sub _clean_generic_url_title \{.*?\n\}\n)/s;
    $assert->ok(defined $body && $body ne '', '_clean_generic_url_title extraite');

    my $fn;
    { no strict; no warnings;
      # _decode_html vient du même fichier ; pour l'isolation on le stubbe
      # (identité) — le test porte sur la troncature, pas le décodage.
      $fn = eval "package T626; sub _decode_html { \$_[0] } $body; \\&T626::_clean_generic_url_title"; }
    $assert->ok(ref($fn) eq 'CODE', 'compilée en isolation');

    my $long = 'mot ' x 100;   # 400 caractères
    my $r = $fn->($long);
    $assert->ok(length($r) <= 301, 'titre long tronqué (<= 300 + ellipse)');
    $assert->like($r, qr/mot\x{2026}\z/, 'coupe à la frontière de mot + ellipse');
    $assert->is($fn->('titre court'), 'titre court', 'titre court inchangé');
    my $nospace = 'x' x 350;
    $assert->like($fn->($nospace), qr/x\x{2026}\z/, 'sans espace: coupe dure + ellipse');
    $assert->ok(!defined $fn->('Just a moment...'), 'titres bot-wall toujours filtrés');

    # --- 2. Clé du cache : canal en lc --------------------------------------
    (my $code = $src) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/lc\(\$url\) \. "\\x00" \. lc\(\$sChannel \/\/ ''\)/,
        'clé du cache anti-répétition: URL et canal en lc');

    $assert->like($src, qr/mb408-R1/, 'tag mb408-R1');
};
