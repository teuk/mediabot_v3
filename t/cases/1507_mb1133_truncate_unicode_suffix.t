use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Mediabot::IRC::TextBudget qw(truncate_utf8 _irc_wire_bytes);

for my $case (
    ['café noir', 5, 'café'],
    ['été au soleil', 3, 'ét'],
    ['☕☕ café', 4, '☕'],
    ['🪄🪄 magie', 5, '🪄'],
) {
    my ($text,$budget,$prefix) = @$case;
    my $input = encode('UTF-8', $text);
    my $original = $input;
    for my $suffix ('…', ' ✨') {
        my $result = truncate_utf8($input, $budget, $suffix);
        ok(!utf8::is_utf8($result), 'truncated raw UTF-8 stays a byte buffer');
        my $wire = utf8::is_utf8($result) ? encode('UTF-8', $result) : $result;
        is(decode('UTF-8', $wire, FB_CROAK | LEAVE_SRC), $prefix.$suffix,
            'wire text retains accents and Unicode suffix without mojibake');
        is(_irc_wire_bytes($result), length(encode('UTF-8', $prefix.$suffix)),
            'wire byte length includes the suffix exactly once');
        is($input, $original, 'caller byte buffer unchanged');
    }
}
my $raw = encode('UTF-8', 'café noir');
is(truncate_utf8($raw, 5), encode('UTF-8', 'café...'), 'default ASCII suffix preserved');
is(truncate_utf8($raw, 5, ''), encode('UTF-8', 'café'), 'empty suffix preserved');
is(truncate_utf8($raw, 5, encode('UTF-8','…')), encode('UTF-8','café…'), 'already encoded suffix is not re-encoded');
is(truncate_utf8('café noir', 5, '…'), 'café…', 'character input remains correct');
is(truncate_utf8($raw, 100, '…'), $raw, 'fitting byte text unchanged');
ok(!utf8::is_utf8(truncate_utf8($raw, 100, '…')), 'fitting byte text retains its representation');
is(truncate_utf8($raw, 0, '…'), $raw, 'legacy zero budget leaves input unchanged');
is(truncate_utf8(undef, 10, '…'), '', 'undefined input remains empty');


# MB1163: consolidated from 1508_mb1134_truncate_replacement_character.t
{
package MB1163::Case1508;
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


}

done_testing;
