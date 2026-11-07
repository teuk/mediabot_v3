use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Mediabot::IRC::TextBudget qw(truncate_utf8 _irc_wire_bytes);

# U+FFFD is also legitimate input: never strip it to repair a partial cut.
for my $text ('a�z', 'a��z', '�é🪄 fin', 'a�é fin', 'a�☕ fin', 'a�🪄 fin') {
    utf8::upgrade($text);
    my $raw = encode('UTF-8', $text);
    my $original = $raw;
    for my $budget (1 .. length($raw) + 1) {
        my $expected = '';
        for my $ch (split //, $text) {
            last if length(encode('UTF-8', $expected.$ch)) > $budget;
            $expected .= $ch;
        }
        for my $suffix ('', '...', '…') {
            my $want = $expected . ($budget < length($raw) ? $suffix : '');
            my $got = truncate_utf8($raw, $budget, $suffix);
            is($got, encode('UTF-8', $want), "raw content preserved at budget $budget");
            ok(!utf8::is_utf8($got), 'raw result stays encoded');
            is(decode('UTF-8', $got, FB_CROAK | LEAVE_SRC), $want, 'valid UTF-8 output');
            is(truncate_utf8($text, $budget, $suffix), $want, 'character/raw parity');
        }
        is($raw, $original, 'source buffer unchanged');
    }
}
# Invalid bytes continue to use the decoder replacement policy.
is(truncate_utf8("a\xffz", 2, ''), encode('UTF-8', "a�"),
    'invalid complete byte is represented, not silently deleted');
is(truncate_utf8(encode('UTF-8', '�x'), 0), encode('UTF-8', '�x'),
    'legacy zero budget remains unchanged');
done_testing;
