# t/cases/660_mb445_quotegame_accent_boundary.t
# =============================================================================
# mb445 — Le masquage et la validation du quotegame utilisent des frontières
# de mot byte-safe.
#
# Le quotegame borne le nick de l'auteur avec le jeu de caractères de nick IRC
# ($nick_char). Le nick lui-même est ASCII, MAIS le texte environnant (la
# citation affichée et le message du joueur) est du TEXTE LIBRE accentué, en
# OCTETS UTF-8. Avec un $nick_char ASCII seul, un octet d'accent (>= 0x80)
# passait pour une frontière, provoquant :
#   1. sur-masquage : l'auteur "art" masqué dans le mot "béart" -> "bé???" ;
#   2. faux positif : un joueur tapant "béart" validait l'auteur "art".
# mb445 ajoute \x80-\xFF à $nick_char (les octets UTF-8 font partie du mot).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_660 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $nc = qr/[A-Za-z0-9\[\]\\^_`{}|\-\x80-\xFF]/;   # byte-safe (mb445)
    my $author = 'art';

    # béart = b é(C3 A9) a r t  -> "art" précédé de l'octet 0xA9
    my $beart = "b" . chr(0xC3) . chr(0xA9) . "art parle";

    # 1. Masquage : "art" NE doit PAS être masqué dans "béart"
    (my $masked = $beart) =~ s/(?<!$nc)\Q$author\E(?!$nc)/???/gi;
    $assert->is($masked, $beart, 'byte-safe: "art" non masqué dans "béart"');

    # 2. Réponse : "béart" NE doit PAS valider l'auteur "art"
    my $fp = ($beart =~ /(?<!$nc)\Q$author\E(?!$nc)/i) ? 1 : 0;
    $assert->is($fp, 0, 'byte-safe: "béart" ne valide pas "art" (plus de faux positif)');

    # 3. Cas légitime : "café art" DOIT matcher/masquer "art"
    my $legit = "caf" . chr(0xC3) . chr(0xA9) . " art";
    my $ok = ($legit =~ /(?<!$nc)\Q$author\E(?!$nc)/i) ? 1 : 0;
    $assert->is($ok, 1, 'auteur bien délimité (espace) toujours reconnu');

    # 4. Nick IRC à specials toujours géré (ex. [teuk])
    my $nick2 = '[teuk]';
    my $txt2  = "dixit [teuk] ce jour";
    my $m2 = ($txt2 =~ /(?<!$nc)\Q$nick2\E(?!$nc)/i) ? 1 : 0;
    $assert->is($m2, 1, 'nick IRC avec crochets toujours borné correctement');

    # --- Câblage réel ------------------------------------------------------
    my $src = _slurp_660(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $n = () = $src =~ /my \$nick_char = qr\/\[A-Za-z0-9\\\[\\\]\\\\\^_`\{\}\|\\-\\x80-\\xFF\]\//g;
    $assert->ok($n >= 2, 'les 2 définitions de $nick_char sont byte-safe');
    $assert->unlike($src, qr/my \$nick_char = qr\/\[A-Za-z0-9\\\[\\\]\\\\\^_`\{\}\|\\-\]\//,
        'plus de $nick_char ASCII seul');
    $assert->like($src, qr/mb445-B1/, 'tag mb445-B1');
};
