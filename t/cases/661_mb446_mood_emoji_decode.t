# t/cases/661_mb446_mood_emoji_decode.t
# =============================================================================
# mb446 — !mood détecte les emojis (comptage sur des caractères, pas des octets).
#
# publictext arrive en OCTETS UTF-8. Le comptage d'emojis utilisait
# $emoji_re avec des ranges de CODEPOINTS (\x{1F600}...), qui ne peuvent jamais
# matcher un octet (< 256) : un emoji UTF-8 (4 octets) n'était donc jamais
# reconnu, et le détail « top emoji: X×N » n'apparaissait jamais. mb446 scanne
# une COPIE DÉCODÉE (Encode::decode UTF-8 tolérant) ; la tokenisation des mots
# reste byte-safe (mb427), et FB_DEFAULT ne modifie pas la source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_661 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $emoji_re = qr/[\x{1F600}-\x{1F64F}\x{1F300}-\x{1F5FF}\x{1F680}-\x{1F6FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}]/;

    # "bien " + 😀(F0 9F 98 80) + " feu " + 🔥(F0 9F 94 A5)  — octets UTF-8
    my $txt = "bien " . chr(0xF0).chr(0x9F).chr(0x98).chr(0x80)
            . " feu " . chr(0xF0).chr(0x9F).chr(0x94).chr(0xA5);

    # 1. Sur les octets : aucun emoji détecté (le bug).
    my %old; while ($txt =~ /($emoji_re)/g) { $old{$1}++ }
    $assert->is(scalar keys %old, 0, 'octets: aucun emoji détecté (ancien comportement)');

    # 2. Sur la copie décodée : emojis détectés.
    my $chars = Encode::decode('UTF-8', $txt, Encode::FB_DEFAULT);
    my %new; while ($chars =~ /($emoji_re)/g) { $new{$1}++ }
    $assert->is(scalar keys %new, 2, 'décodé: 2 emojis détectés');
    $assert->ok($new{"\x{1F600}"}, '😀 (U+1F600) détecté');
    $assert->ok($new{"\x{1F525}"}, '🔥 (U+1F525) détecté');

    # 3. FB_DEFAULT ne modifie pas la source.
    my $before = unpack('H*', $txt);
    Encode::decode('UTF-8', $txt, Encode::FB_DEFAULT);
    $assert->is(unpack('H*', $txt), $before, 'FB_DEFAULT laisse publictext intact');

    # --- Câblage réel ------------------------------------------------------
    my $src = _slurp_661(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbMood_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/my \$txt_chars = Encode::decode\('UTF-8', \$txt, Encode::FB_DEFAULT\)/,
        'copie décodée pour le scan emoji');
    $assert->like($code, qr/while \(\$txt_chars =~ \/\(\$emoji_re\)\/g\)/,
        'scan emoji sur la copie décodée');
    $assert->unlike($code, qr/while \(\$txt =~ \/\(\$emoji_re\)\/g\)/,
        'plus de scan emoji sur les octets');
    # tokenisation des mots toujours byte-safe (mb427)
    $assert->like($code, qr/split \/\[\^0-9A-Za-z_\\x80-\\xFF\]\+\//, 'tokenisation mots byte-safe conservée');

    $assert->like($src, qr/mb446-B1/, 'tag mb446-B1');
};
