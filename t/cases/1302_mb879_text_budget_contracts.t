use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use IPC::Open3;
use Symbol qw(gensym);
use Mediabot::IRC::TextBudget ();
use Mediabot::Helpers ();

# Loading the budget layer must not pull in the bot's runtime or providers.
for my $order (
    [qw(IRC::TextBudget)],
    [qw(IRC::TextBudget Helpers)],
    [qw(Helpers IRC::TextBudget)],
) {
    my $code = join('', map {"require Mediabot::$_;\n"} @$order);
    $code .= q{die 'runtime loaded' if $INC{'Mediabot/External/Claude.pm'} || $INC{'Mediabot/AI/Client.pm'};};
    $code .= q{die 'Helpers loaded' if $INC{'Mediabot/Helpers.pm'};} if @$order == 1;
    $code .= q{print 'loaded';};
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, 'fresh interpreter loads the pure layer in either order');
    is($stdout, 'loaded', 'all dependency checks complete');
    is($stderr, '', 'no circular imports or redefinitions');
}

my $latin = chr(0xe9);
utf8::downgrade($latin);
my $unicode = 'é🙂';
my $raw = encode('UTF-8', $unicode);
for my $row (
    [undef, 0, 0], ['', 0, 0], ['0', 1, 1], ['plain', 5, 5],
    [$latin, 1, 2], [$unicode, 6, 6], [$raw, 6, 12],
) {
    is(Mediabot::IRC::TextBudget::_irc_wire_bytes($row->[0]), $row->[1],
        'wire accounting respects already encoded buffers');
    is(Mediabot::IRC::TextBudget::_utf8_text_bytes($row->[0]), $row->[2],
        'character accounting retains explicit UTF-8 encoding semantics');
}

for my $text (undef, '', '0', 'hello world', 'é🙂 ' x 30, $raw x 30,
    "one\r\nforged\0tail", "\x02" . ('word ' x 70) . "\x0f") {
    for my $budget (0, 15, 16, 40, 391, 400) {
        my @owner = Mediabot::IRC::TextBudget::_split_text_for_irc($text, $budget);
        my @legacy = Mediabot::Helpers::_split_text_for_irc($text, $budget);
        is_deeply(\@legacy, \@owner, 'legacy splitter delegates without changing list results');
        my $effective = $budget < 16 ? 400 : $budget;
        ok(!grep({Mediabot::IRC::TextBudget::_irc_wire_bytes($_) > $effective} @owner),
            'chunks obey the historical minimum/default budget');
        ok(!grep({/[\r\n\0]/} @owner), 'wire chunks cannot introduce extra IRC lines');
    }
}
is_deeply([Mediabot::IRC::TextBudget::_split_text_for_irc('alpha beta gamma delta', 16)],
    ['alpha beta ', 'gamma delta'], 'word wrapping keeps the established whitespace rule');
is(Mediabot::Helpers::_sanitize_irc_text("hello\r\nworld\0!"), 'hello world !',
    'legacy sanitizer preserves the log/history normalization contract');

for my $row (
    ['abcdef', 3, '...', 'abc...'],
    ['abcdef', 3, '', 'abc'],
    ['é🙂abcdef', 6, '!', 'é🙂!'],
    ['short', 0, '...', 'short'],
    ['short', -1, '...', 'short'],
    [undef, 3, '...', ''],
    [encode('UTF-8', 'abcéxyz'), 4, '...', 'abc...'],
    [encode('UTF-8', 'abcéxyz'), 5, '...', encode('UTF-8', 'abcé') . '...'],
) {
    my ($text, $max, $suffix, $expected) = @$row;
    for my $call (\&Mediabot::Helpers::truncate_utf8, \&Mediabot::IRC::TextBudget::truncate_utf8) {
        is($call->($text, $max, $suffix), $expected,
            'legacy truncation reserves content only and appends the caller suffix');
    }
}
is(length(Mediabot::Helpers::truncate_utf8('x' x 20, 4)), 7,
    'the legacy suffix remains outside max; it is not a total-line cap');
# MB885: preserve representation even when a Unicode message ends in ASCII.
my @unicode_tail = Mediabot::IRC::TextBudget::_split_text_for_irc(('é' x 8) . 'x', 16);
is_deeply([map {[$_, utf8::is_utf8($_) ? 1 : 0]} @unicode_tail],
    [[('é' x 8), 1], ['x', 1]], 'a final ASCII chunk retains the input character representation');
my $flagged_ascii = 'a' x 41;
utf8::upgrade($flagged_ascii);
my $ascii_prefix = Mediabot::IRC::TextBudget::_irc_prefix_for_budget($flagged_ascii, 16);
is_deeply([$ascii_prefix, utf8::is_utf8($ascii_prefix) ? 1 : 0],
    [('a' x 16), 0], 'prefix-only ASCII keeps the legacy normalized scalar representation');
is_deeply([Mediabot::IRC::TextBudget::_split_text_for_irc(('x' x 16) . (' ' x 30), 16)],
    ['x' x 16], 'whitespace after a full chunk is still discarded');
is(Mediabot::IRC::TextBudget::_irc_prefix_for_budget("a\r\n\0" x 8, 16), 'a ' x 8,
    'prefix overflow is decided before normalization, then uses sanitized text');
is_deeply([
    scalar Mediabot::IRC::TextBudget::_split_text_for_irc('short', 16),
    scalar Mediabot::IRC::TextBudget::_split_text_for_irc('x' x 33, 16),
], ['short', 3], 'legacy scalar context retains the short string or wrapped chunk count');

# Bound actual byte-accounting work, without machine-dependent timing limits.
# The input is long enough to catch repeated scans of the shrinking tail.
my $long_text = 'été 🙂 words ' x 600;
for my $mode (qw(split prefix)) {
    my ($work, $result) = (0);
    my $wire_bytes = \&Mediabot::IRC::TextBudget::_irc_wire_bytes;
    {
        no warnings 'redefine';
        local *Mediabot::IRC::TextBudget::_irc_wire_bytes = sub {
            $work += length($_[0] // '');
            return $wire_bytes->(@_);
        };
        $result = $mode eq 'split'
            ? [Mediabot::IRC::TextBudget::_split_text_for_irc($long_text, 400)]
            : [Mediabot::IRC::TextBudget::_irc_prefix_for_budget($long_text, 400)];
    }
    ok($work <= 4 * length($long_text), "$mode avoids repeated full-tail byte accounting")
        or diag("accounted $work characters for " . length($long_text) . ' input characters');
    is($result->[0], ('été 🙂 words ' x 23) . 'été ',
        "$mode retains the established first word boundary while limiting work");
}

done_testing;
