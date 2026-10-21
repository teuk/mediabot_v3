# t/cases/651_mb436_define_accent_safe.t
# =============================================================================
# mb436 — "!define <mot>" accepte et encode correctement les mots accentués.
#
# Les args viennent d'IRC en OCTETS UTF-8. Deux bugs empêchaient de définir un
# mot accentué (ex. café) :
#   1. la validation `[^\w\s-]` rejetait les octets d'accent (0xC3, 0xA9...) ->
#      "Invalid word." ;
#   2. même si accepté, uri_escape_utf8() sur des octets DOUBLE-encode
#      (café -> %C3%83%C2%A9) -> mauvaise URL Wiktionary.
# mb436 : validation byte-safe (octets >= 0x80 admis) + échappement des octets
# déjà UTF-8 (uri_escape, pas uri_escape_utf8) donnant %C3%A9.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_651 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Validation byte-safe ------------------------------------------
    my $cafe = "caf" . chr(0xC3) . chr(0xA9);           # octets UTF-8
    my $noel = "no"  . chr(0xC3) . chr(0xAB) . "l";     # noël
    my $bad  = "foo!bar";                                # vraie ponctuation interdite

    my $rej = sub { my ($w) = @_; ($w =~ /[^\w\s\x80-\xFF-]/ || length($w) > 64) ? 1 : 0 };
    $assert->is($rej->($cafe), 0, 'café accepté (octets accent admis)');
    $assert->is($rej->($noel), 0, 'noël accepté');
    $assert->is($rej->('ice cream'), 0, 'mot avec espace accepté');
    $assert->is($rej->($bad), 1, 'ponctuation ASCII toujours rejetée');
    $assert->is($rej->('x' x 65), 1, 'trop long rejeté');

    # Ancien comportement : café aurait été rejeté.
    my $rej_old = sub { my ($w) = @_; ($w =~ /[^\w\s-]/ || length($w) > 64) ? 1 : 0 };
    $assert->is($rej_old->($cafe), 1, 'ancien: café était rejeté (régression évitée)');

    # --- 2. Encodage des octets (pas de double-encodage) -------------------
    my $enc = sub {
        my ($word) = @_;
        my $wb = utf8::is_utf8($word) ? Encode::encode('UTF-8', $word) : $word;
        (my $e = $wb) =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X",ord($1))/ge;
        return $e;
    };
    require Encode;
    $assert->is($enc->($cafe), 'caf%C3%A9', 'café -> caf%C3%A9 (octets UTF-8)');
    $assert->unlike($enc->($cafe), qr/%C3%83/, 'pas de double-encodage %C3%83');

    # --- 3. Câblage réel ---------------------------------------------------
    my $src = _slurp_651(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($def) = $src =~ /(sub mbDefine_ctx \{.*?\n\}\n)/s; $def //= '';
    (my $dcode = $def) =~ s/^\s*#.*$//mg;
    $assert->like($dcode, qr/\[\^\\w\\s\\x80-\\xFF-\]/, 'validation byte-safe');

    my $source = _slurp_651(File::Spec->catfile('.', 'Mediabot', 'External', 'Wiktionary.pm'));
    my ($sync) = $source =~ /(sub _define_lookup_sync \{.*?\n\}\n)/s; $sync //= '';
    (my $scode = $sync) =~ s/^\s*#.*$//mg;
    $assert->like($scode, qr/utf8::is_utf8\(\$word\) \? Encode::encode\('UTF-8', \$word\) : \$word/,
        'word normalisé en octets avant encodage');
    $assert->like($scode, qr/URI::Escape::uri_escape\(\$word_bytes/,
        'uri_escape sur octets (plus uri_escape_utf8)');
    $assert->unlike($scode, qr/uri_escape_utf8\(\$word\)/, 'plus de uri_escape_utf8($word)');

    $assert->like($src, qr/mb436-B1/, 'tag mb436-B1');
};
