# t/cases/644_mb429_shared_truncate_utf8.t
# =============================================================================
# mb429 — Helper partagé Mediabot::Helpers::truncate_utf8 (généralisation de
# mb428) appliqué aux textes libres tronqués issus de la DB.
#
# Le _quote_excerpt de mb428 est promu en helper partagé et réutilisé là où du
# texte utilisateur (publictext, actions, contenus IA) était tronqué par un
# substr brut susceptible de couper un caractère UTF-8 multi-octets.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_644 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Le helper réel, exécuté ---------------------------------------
    require Mediabot::Helpers;
    $assert->ok(Mediabot::Helpers->can('truncate_utf8'), 'truncate_utf8 défini');

    my $s = "abc" . chr(0xC3) . chr(0xA9) . ('x' x 300);   # abc é xxxx...

    my $r4 = Mediabot::Helpers::truncate_utf8($s, 4);
    (my $b4 = $r4) =~ s/\.\.\.\z//;
    my $chk4 = $b4; my $valid4 = eval { Encode::decode('UTF-8', $chk4, Encode::FB_CROAK); 1 } ? 1 : 0;
    $assert->is($valid4, 1, 'coupe en plein caractère -> UTF-8 valide');
    $assert->is($b4, 'abc', 'caractère incomplet retiré');

    my $r5 = Mediabot::Helpers::truncate_utf8($s, 5);
    (my $b5 = $r5) =~ s/\.\.\.\z//;
    $assert->is(unpack('H*', $b5), '616263c3a9', 'caractère complet conservé (abcé)');

    $assert->is(Mediabot::Helpers::truncate_utf8('court', 300), 'court', 'court inchangé');
    $assert->is(length(Mediabot::Helpers::truncate_utf8('y' x 500, 300)), 303, 'ASCII long: 300 + ...');
    $assert->is(Mediabot::Helpers::truncate_utf8('hello', 3, '…'),
        Encode::encode('UTF-8', 'hel') . '…', 'ellipse personnalisable');

    # --- 2. Quotes délègue au helper --------------------------------------
    my $q = _slurp_644(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));
    $assert->like($q, qr/Mediabot::Helpers::truncate_utf8\(\$s, \$max, '\.\.\.'\)/,
        '_quote_excerpt délègue au helper partagé');

    # --- 3. Sites de texte libre convertis --------------------------------
    my $cc = _slurp_644(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    $assert->like($cc, qr/truncate_utf8\(\$text, 297\)/, 'chanlog: publictext UTF-8-safe');
    $assert->unlike($cc, qr/substr\(\$text, 0, 297\) \. '\.\.\.'/, 'plus de substr brut chanlog');

    my $pl = _slurp_644(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    $assert->like($pl, qr/truncate_utf8\(\$text, 160\)/,    'action text UTF-8-safe');
    $assert->like($pl, qr/truncate_utf8\(\$content, 120\)/, 'contenu IA UTF-8-safe');

    my $h = _slurp_644(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    $assert->like($h, qr/^\s+truncate_utf8$/m, 'truncate_utf8 exporté');
    $assert->like($h, qr/mb429-R1/, 'tag mb429-R1');
};
