use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::External::SearchCommand qw(_query);
use Mediabot::External::URLCodec qw(_uri_escape_bytes);

my $characters = 'thé ☕';
my $octets = encode('UTF-8', 'café');
for my $args ([$octets, $characters], [$characters, $octets]) {
    my @before = @$args;
    my @flags = map { utf8::is_utf8($_) ? 1 : 0 } @$args;
    my $expected = $args->[0] eq $octets ? 'café thé ☕' : 'thé ☕ café';
    my $result = _query($args);
    is($result, $expected, 'mixed byte/character arguments retain accents in either order');
    is(_uri_escape_bytes($result), _uri_escape_bytes($expected), 'outbound query is encoded exactly once');
    is_deeply($args, \@before, 'caller arguments are unchanged');
    is_deeply([map { utf8::is_utf8($_) ? 1 : 0 } @$args], \@flags, 'caller UTF-8 flags are unchanged');
}
for my $bad ("\xff", "\xc3", "\xc0\xaf", "\xed\xa0\x80") {
    ok(!defined scalar _query([$characters, $bad]), 'Unicode neighbour cannot hide invalid UTF-8 bytes');
    ok(!defined scalar _query([$bad, $characters]), 'invalid leading UTF-8 bytes are rejected');
}
is(_query([encode('UTF-8', 'été'), encode('UTF-8', 'noël')]), 'été noël', 'all-byte arguments still work');
is(_query(['été', 'noël']), 'été noël', 'all-character arguments still work');
is(_query(['  café ', ' thé  ']), 'café thé', 'whitespace normalization preserved');
is(_query(['0']), '0', 'zero remains a valid query');
is(_query([encode('UTF-8', 'é' x 80), 'é' x 79]), ('é' x 80).' '.('é' x 79), '160 characters and 319 bytes accepted');
ok(!defined scalar _query(['☕' x 107]), '321-byte query rejected');
ok(!defined scalar _query(['a' x 161]), '161-character query rejected');
ok(!defined scalar _query(['a' x 641]), 'oversized raw input rejected');
ok(!defined scalar _query([('a') x 33]), 'argument count bounded');
for my $bad ([], {}, [undef], [{}], ["x\ny"], ["x\0y"]) {
    ok(!defined scalar _query($bad), 'malformed container or control characters rejected');
}
done_testing;
