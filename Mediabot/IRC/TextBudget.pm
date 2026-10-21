package Mediabot::IRC::TextBudget;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(encode decode FB_QUIET);

our @EXPORT_OK = qw(
    _irc_wire_bytes _irc_prefix_for_budget
    _utf8_text_bytes
    _sanitize_irc_text _split_text_for_irc truncate_utf8
);

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
        my @chunks = _split_text_for_irc($text, $max_bytes);
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

# Count application character text as UTF-8, including downgraded Latin-1
# characters. Unlike _irc_wire_bytes, an unflagged scalar is NOT a wire buffer.
sub _utf8_text_bytes {
    my ($text) = @_;
    return 0 unless defined $text;
    return length(encode('UTF-8', $text));
}

# Single-line normalization also used before IRC logging/history in Helpers.
sub _sanitize_irc_text {
    my ($text) = @_;
    return $text unless defined $text;
    $text =~ s/[\r\n\x00]+/ /g;
    return $text;
}

# Word wrapping uses the historical 400-byte default and minimum of 16.
sub _split_text_for_irc {
    my ($text, $max_bytes) = @_;

    return () unless defined($text) && $text ne '';

    $max_bytes = 400
        unless defined($max_bytes) && $max_bytes =~ /^\d+$/ && $max_bytes >= 16;

    # Defence in depth: callers sanitise before logging/history, while the
    # splitter also protects direct future callers.
    $text = _sanitize_irc_text($text);

    my $is_chars = utf8::is_utf8($text);
    my $cost = $is_chars
        ? sub { my $o = ord($_[0]); $o < 0x80 ? 1 : $o < 0x800 ? 2 : $o < 0x10000 ? 3 : 4 }
        : sub { 1 };

    # Fast path: whole message already fits on the wire.
    return ($text) if _irc_wire_bytes($text) <= $max_bytes;

    my @chunks;
    my $buf = $text;

    while (_irc_wire_bytes($buf) > $max_bytes) {
        # Largest leading character count whose encoded form fits the budget.
        my $bytes = 0;
        my $n     = 0;
        for my $ch (split //, $buf) {
            my $cb = $cost->($ch);
            last if $bytes + $cb > $max_bytes;
            $bytes += $cb;
            $n++;
        }
        $n = 1 if $n < 1;    # always make progress, even if one char > budget

        my $prefix = substr($buf, 0, $n);

        # Prefer breaking at the last whitespace, but not before half the prefix,
        # mirroring the historical .{200,399}\s word-wrap behaviour.
        if ($prefix =~ /^(.*\s)\S+\z/s) {
            my $ws = $1;
            $prefix = $ws if length($ws) >= int($n / 2) && length($ws) >= 1;
        }

        my $cut = length($prefix);
        $cut = $n if $cut < 1;

        push @chunks, substr($buf, 0, $cut);
        $buf = substr($buf, $cut);
        $buf =~ s/^\s+//;
    }

    push @chunks, $buf if length($buf);
    return @chunks;
}

# Legacy contract: max bounds the content; ellipsis is appended OUTSIDE max.
# Preserve both character strings and legacy raw UTF-8 byte input.
sub truncate_utf8 {
    my ($s, $max, $ellipsis) = @_;
    $s = '' unless defined $s;
    $ellipsis = '...' unless defined $ellipsis;
    $max = int($max // 0);
    return $s if $max < 1;

    # mb435-B1/mb644: callers may still provide either legacy raw UTF-8 bytes
    # or character strings (DBD::MariaDB/JSON). Decoding an already-upgraded
    # character string raises
    # "Wide character" and could break `.ai context`. Preserve the input
    # representation while applying the same wire-byte budget in both cases.
    if (utf8::is_utf8($s)) {
        my $wire = Encode::encode('UTF-8', $s);
        return $s if length($wire) <= $max;

        my $out  = '';
        my $used = 0;
        for my $ch (split //, $s) {
            my $bytes = Encode::encode('UTF-8', $ch);
            last if $used + length($bytes) > $max;
            $out  .= $ch;
            $used += length($bytes);
        }
        return $out . $ellipsis;
    }

    return $s if length($s) <= $max;
    my $cut   = substr($s, 0, $max);
    my $chars = Encode::decode('UTF-8', $cut, Encode::FB_DEFAULT);
    $chars =~ s/\x{FFFD}+\z//;
    return Encode::encode('UTF-8', $chars) . $ellipsis;
}

1;
