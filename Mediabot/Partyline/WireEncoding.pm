package Mediabot::Partyline::WireEncoding;

use strict;
use warnings;
use parent 'Encode::Encoding';
use Encode ();

__PACKAGE__->Define('Mediabot-Partyline-Wire');

# IO::Async normally uses one encoding for both directions. Partyline input
# must remain bytes: Telnet IAC framing and byte limits are handled downstream.
# Output accepts both character text and already encoded/protocol octets.
# Conversion happens before enqueue/byte accounting, including deferred writes.
sub encode {
    my ($self, $text, $check) = @_;
    my $bytes = utf8::is_utf8($text)
        ? Encode::encode('UTF-8', $text) : $text;
    $_[1] = '' if $check && !($check & Encode::LEAVE_SRC());
    return $bytes;
}

sub decode {
    my ($self, $bytes, $check) = @_;
    $_[1] = '' if $check && !($check & Encode::LEAVE_SRC());
    return $bytes;
}

1;
