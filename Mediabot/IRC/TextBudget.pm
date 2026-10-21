package Mediabot::IRC::TextBudget;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(encode);
require Mediabot::Helpers;

our @EXPORT_OK = qw(_irc_wire_bytes _irc_prefix_for_budget);

# Return the number of bytes that the IRC layer will put on the wire. Character
# strings are UTF-8 encoded downstream; byte strings are already encoded and
# must not be encoded a second time. This mirrors _split_text_for_irc (mb325).
sub _irc_wire_bytes {
    my ($text) = @_;
    return 0 unless defined $text;
    return utf8::is_utf8($text)
        ? length(encode('UTF-8', $text))
        : length($text);
}

# Return a byte-bounded prefix using the same shared splitter as normal IRC
# wrapping. Tiny defensive budgets are handled locally because the shared
# helper deliberately normalises values below 16 bytes.
sub _irc_prefix_for_budget {
    my ($text, $max_bytes) = @_;
    return '' unless defined($text) && length($text);
    return '' unless defined($max_bytes) && $max_bytes =~ /^\d+\z/ && $max_bytes > 0;
    return $text if _irc_wire_bytes($text) <= $max_bytes;

    if ($max_bytes >= 16) {
        my @chunks = Mediabot::Helpers::_split_text_for_irc($text, $max_bytes);
        return $chunks[0] // '';
    }

    my ($prefix, $used) = ('', 0);
    for my $ch (split //, $text) {
        my $cost = _irc_wire_bytes($ch);
        last if $used + $cost > $max_bytes;
        $prefix .= $ch;
        $used += $cost;
    }
    return $prefix;
}

1;
