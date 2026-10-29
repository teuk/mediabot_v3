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
        return _irc_chunk_prefix(_sanitize_irc_text($text), $max_bytes);
    }

    my $characters = !utf8::is_utf8($text)
        ? _irc_raw_utf8_window($text, $max_bytes) : undef;
    $text = $characters if defined $characters;
    my ($prefix, $used) = ('', 0);
    for my $ch (split //, $text) {
        my $cost = _irc_wire_bytes($ch);
        last if $used + $cost > $max_bytes;
        $prefix .= $ch;
        $used += $cost;
    }
    return defined($characters) ? encode('UTF-8', $prefix) : $prefix;
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

    # Fast path: whole message already fits on the wire.
    return ($text) if _irc_wire_bytes($text) <= $max_bytes;

    my @chunks;
    my $buf = $text;
    while (length($buf)) {
        my $prefix = _irc_chunk_prefix($buf, $max_bytes);
        push @chunks, $prefix;
        last if length($prefix) == length($buf);
        $buf = substr($buf, length($prefix));
        $buf =~ s/^\s+//;
    }
    return @chunks;
}

# Recognize a valid UTF-8 prefix without changing the caller's byte buffer.
sub _irc_raw_utf8_window {
    my ($text, $max_bytes) = @_;
    # Four look-ahead bytes suffice to complete a character crossing the cut.
    # Decode only this bounded window; never repair legacy non-UTF-8 bytes.
    my $probe = substr($text, 0, $max_bytes + 4);
    my $characters = decode('UTF-8', $probe, FB_QUIET);
    utf8::upgrade($characters);
    return undef if length($probe) && _irc_wire_bytes($characters) < $max_bytes;
    return $characters;
}

# Inspect only enough characters to decide the next chunk. Every input
# character occupies at least one wire byte, so budget + 1 characters also
# suffice to distinguish a final chunk from one needing a cut. Keep this
# decision shared with prefix-only callers without building unused chunks.
sub _irc_chunk_prefix {
    my ($text, $max_bytes) = @_;
    my $characters = !utf8::is_utf8($text)
        ? _irc_raw_utf8_window($text, $max_bytes) : undef;
    $text = $characters if defined $characters;
    my $window = substr($text, 0, $max_bytes + 1);
    return defined($characters) ? encode('UTF-8', $text) : $text
        if length($window) <= $max_bytes && _irc_wire_bytes($window) <= $max_bytes;

    my $is_chars = utf8::is_utf8($window);
    my ($bytes, $n) = (0, 0);
    for my $ch (split //, $window) {
        my $o = ord($ch);
        my $cb = !$is_chars || $o < 0x80 ? 1
            : $o < 0x800 ? 2 : $o < 0x10000 ? 3 : 4;
        last if $bytes + $cb > $max_bytes;
        $bytes += $cb;
        $n++;
    }
    $n = 1 if $n < 1;

    my $prefix = substr($text, 0, $n);
    # Preserve the historical half-prefix word-break rule, including trailing
    # whitespace. Encoded input is returned as bytes after character-safe cuts.
    if ($prefix =~ /^(.*\s)\S+\z/s) {
        my $ws = $1;
        $prefix = $ws if length($ws) >= int($n / 2) && length($ws) >= 1;
    }
    return defined($characters) ? encode('UTF-8', $prefix) : $prefix;
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
