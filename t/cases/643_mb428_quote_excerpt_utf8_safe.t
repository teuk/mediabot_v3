# t/cases/643_mb428_quote_excerpt_utf8_safe.t
# =============================================================================
# mb428 — Les extraits de citations sont tronqués sans casser un caractère
# UTF-8 multi-octets.
#
# quotetext arrive en OCTETS UTF-8 (DBI ne décode pas). substr($s, 0, N)
# coupait à N octets, potentiellement au milieu d'un caractère accenté ->
# séquence UTF-8 invalide -> mojibake / caractère de remplacement en fin
# d'extrait sur un canal francophone. mb428 tronque à N octets puis retire une
# éventuelle séquence multi-octets incomplète (decode tolérant), et ré-encode.
# Appliqué aux 4 sites : view, search, random, byNick.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_643 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_643(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));

    # --- 1. Reproduction fidèle du helper (comme mb426/427) ----------------
    my $fn = sub {
        my ($s, $max) = @_;
        $s = '' unless defined $s;
        return $s if length($s) <= $max;
        my $cut = substr($s, 0, $max);
        my $chars = Encode::decode('UTF-8', $cut, Encode::FB_DEFAULT);
        $chars =~ s/\x{FFFD}+\z//;
        return Encode::encode('UTF-8', $chars) . '...';
    };

    # "abc" + é(0xC3 0xA9) + bourrage
    my $s = "abc" . chr(0xC3) . chr(0xA9) . ('x' x 300);

    # Coupe à 4 octets : le é est incomplet -> doit être retiré, reste valide.
    my $r4 = $fn->($s, 4);
    (my $b4 = $r4) =~ s/\.\.\.\z//;
    $assert->ok((do { my $c=$b4; eval { Encode::decode("UTF-8", $c, Encode::FB_CROAK); 1 } }) ? 1 : 0,
        'coupe en plein caractère -> extrait UTF-8 valide');
    $assert->is($b4, 'abc', 'le caractère incomplet est retiré (abc)');
    $assert->like($r4, qr/\.\.\.\z/, 'ellipse ajoutée');

    # Coupe à 5 octets : é complet -> conservé.
    my $r5 = $fn->($s, 5); (my $b5 = $r5) =~ s/\.\.\.\z//;
    $assert->ok((do { my $c=$b5; eval { Encode::decode("UTF-8", $c, Encode::FB_CROAK); 1 } }) ? 1 : 0,
        'caractère complet conservé, valide');
    $assert->is(unpack('H*', $b5), '616263c3a9', 'abcé complet');

    # Chaîne courte : inchangée, pas d'ellipse.
    $assert->is($fn->('hello', 300), 'hello', 'chaîne courte inchangée');

    # ASCII long : tronqué + ellipse.
    my $long = 'y' x 500;
    my $rl = $fn->($long, 300);
    $assert->ok(length($rl) == 303, 'ASCII long: 300 + "..."');

    # --- 2. Câblage réel : plus de substr brut, helper partout -------------
    (my $code = $src) =~ s/^\s*#.*$//mg;
    my $n_helper = () = $code =~ /_quote_excerpt\(\$\w+, \d+\)/g;
    $assert->ok($n_helper >= 4, 'les 4 sites utilisent le helper');
    $assert->unlike($code, qr/substr\(\$excerpt, 0, \d+\) \. '\.\.\.'/,
        'plus de substr brut sur excerpt');
    $assert->unlike($code, qr/substr\(\$text, 0, 300\) \. '\.\.\.'/,
        'plus de substr brut sur text');

    $assert->like($src, qr/mb428-B1/, 'tag mb428-B1');
};
