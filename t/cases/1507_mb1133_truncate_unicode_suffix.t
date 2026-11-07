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
done_testing;
