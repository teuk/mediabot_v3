package Mediabot::JSON;

use strict;
use warnings;
use Exporter 'import';
use Encode qw(encode);
use JSON::MaybeXS ();

our @EXPORT_OK = qw(decode_json_payload);

# HTTP readers may provide UTF-8 bytes or already-decoded character strings.
# Retain decode_json's values and exceptions, encoding character input once.
sub decode_json_payload {
    my ($payload) = @_;
    return JSON::MaybeXS::decode_json(
        utf8::is_utf8($payload) ? encode('UTF-8', $payload) : $payload
    );
}

1;
