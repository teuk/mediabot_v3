# t/cases/653_mb438_weather_accent_url.t
# =============================================================================
# mb438 — L'URL météo (wttr.in) encode correctement les villes accentuées et
# le format à emojis.
#
# Les entrées (ville tapée sur IRC, chaîne de format contenant des emojis)
# sont des OCTETS UTF-8. uri_escape_utf8() sur des octets DOUBLE-encode
# (Genève -> %C3%83%C2%A8ve ; emojis cassés) -> mauvaise URL / séparateurs
# illisibles. mb438 : helper _uri_escape_bytes qui échappe les octets déjà
# UTF-8 (uri_escape, pas uri_escape_utf8).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_653 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique de l'encodage byte-safe ----------------------------
    my $esc = sub {
        my ($s) = @_;
        my $b = utf8::is_utf8($s) ? Encode::encode('UTF-8', $s) : $s;
        (my $e = $b) =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X",ord($1))/ge;
        return $e;
    };

    my $geneve = "Gen" . chr(0xC3) . chr(0xA8) . "ve";   # Genève octets UTF-8
    $assert->is($esc->($geneve), 'Gen%C3%A8ve', 'Genève -> Gen%C3%A8ve (octets)');
    $assert->unlike($esc->($geneve), qr/%C3%83/, 'pas de double-encodage');

    $assert->is($esc->('Paris'), 'Paris', 'ASCII inchangé');

    # emoji (💧 = F0 9F 92 A7) encodé octet par octet, pas double
    my $drop = chr(0xF0).chr(0x9F).chr(0x92).chr(0xA7);
    $assert->is($esc->($drop), '%F0%9F%92%A7', 'emoji encodé octet par octet');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_653(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));

    $assert->like($src, qr/sub _uri_escape_bytes \{/, 'helper _uri_escape_bytes défini');
    my ($h) = $src =~ /(sub _uri_escape_bytes \{.*?\n\}\n)/s; $h //= '';
    $assert->like($h, qr/utf8::is_utf8\(\$s\) \? Encode::encode\('UTF-8', \$s\) : \$s/,
        'octets normalisés');
    $assert->like($h, qr/URI::Escape::uri_escape\(\$bytes/, 'uri_escape sur octets');

    my ($w) = $src =~ /(sub displayWeather_ctx \{.*?\n\}\n)/s; $w //= '';
    (my $wcode = $w) =~ s/^\s*#.*$//mg;
    $assert->like($wcode, qr/_uri_escape_bytes\(\$location\)/, 'location encodée byte-safe');
    $assert->like($wcode, qr/_uri_escape_bytes\(\$format\)/, 'format encodé byte-safe');
    $assert->unlike($wcode, qr/uri_escape_utf8\(\$location\)/, 'plus de uri_escape_utf8 sur location');

    $assert->like($src, qr/mb438-B1/, 'tag mb438-B1');
};
