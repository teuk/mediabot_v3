package Mediabot::External::URLCodec;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode ();
use URI::Escape ();

our @EXPORT_OK = qw(_uri_escape_bytes);

# mb438-B1: échappement d'URL byte-safe. Les entrées (villes tapées sur IRC,
# format contenant des emojis) sont des OCTETS UTF-8 ; uri_escape_utf8() les
# double-encode (Genève -> %C3%83%C2%A8..., emojis cassés). On échappe les
# octets déjà UTF-8 (repli d'encodage si la chaîne était en caractères).
sub _uri_escape_bytes {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $bytes = utf8::is_utf8($s) ? Encode::encode('UTF-8', $s) : $s;
    return URI::Escape::uri_escape($bytes, "^A-Za-z0-9\-\._~");
}

1;
