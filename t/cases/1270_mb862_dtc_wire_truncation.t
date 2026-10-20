use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK);
use Mediabot::DTC::Format qw(format_quote_lines);

sub plain862 {
    my ($line) = @_;
    $line =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $line =~ s/[\x02\x0f]//g;
    return $line;
}
my $url = 'Consultez la quote ici : https://danstonchat.com/quote/15924.html';
my $head = "\x03" . '01,15' . "\x02[15924]\x02\x03" . '00,14' . ' ';
my $rest = "\x03" . '00,14';
my @warnings;
local $SIG{__WARN__} = sub {push @warnings, @_};

# The complete first line is exactly 430 bytes including colors and reset.
my $exact = 'x' x (430 - length(encode('UTF-8', $head)) - 1);
is_deeply(format_quote_lines(15924, $exact), [$head . $exact . "\x0f"],
    'exactly fitting first line retains its bytes and needs no link');
my $over = format_quote_lines(15924, $exact . 'x');
is(scalar @$over, 2, 'one excess byte adds the full quote link');
is(plain862($over->[-1]), $url, 'byte-truncated single line has the exact canonical link');
like($over->[0], qr/…\x0f\z/, 'truncated dialogue has an ellipsis and color reset');
is(length(encode('UTF-8', $over->[0])), 430, 'first line retains the full allowed byte budget');

for my $unit ('x', 'é', '€', '🚀') {
    my $width = length(encode('UTF-8', $unit));
    for my $at (0, 1) {
        my @text = ('First: short', 'Second: short');
        $text[$at] = 'Speaker: ' . ($unit x 2000);
        my $lines = format_quote_lines(15924, join("\n", @text));
        is(scalar @$lines, 3, "width/position $width/$at: two dialogues plus link");
        is(plain862($lines->[-1]), $url, "width/position $width/$at: omitted text remains reachable");
        my $expected = ($at ? $rest : $head) . $text[$at] . "\x0f";
        my $prefix = $lines->[$at];
        $prefix =~ s/…\x0f\z//;
        is(index($expected, $prefix), 0, "width/position $width/$at: clipped text remains an exact prefix");
        ok(length(encode('UTF-8', $lines->[$at])) <= 430,
            "width/position $width/$at: clipping respects byte bound");
        ok(length(encode('UTF-8', $lines->[$at])) > 430 - length(encode('UTF-8', $unit)),
            "width/position $width/$at: only an incomplete final character is dropped");
        my $roundtrip = eval {decode('UTF-8', encode('UTF-8', $lines->[$at]), FB_CROAK)};
        is($roundtrip, $lines->[$at], "width/position $width/$at: no broken UTF-8 character");
        unlike($lines->[$at], qr/\x{fffd}/, "width/position $width/$at: no replacement character inserted");
    }
}

for my $max (3, 5, 10) {
    for my $count ($max - 1, $max, $max + 1) {
        for my $position (1, $count) {
            my @text = map {"dialogue $_"} 1 .. $count;
            $text[$position - 1] .= ' ' . ('é' x 600);
            my $lines = format_quote_lines(15924, join("\n", @text), max_lines => $max);
            is(scalar @$lines, $max, "$max/$count/$position: link stays within batch budget");
            is(plain862($lines->[-1]), $url, "$max/$count/$position: canonical URL is last");
            is(scalar(grep {/https:\/\/danstonchat[.]com\/quote\/15924[.]html/} @$lines), 1,
                "$max/$count/$position: exactly one full-quote link");
            if ($count >= $max) {
                is(plain862($lines->[-2]), '...', "$max/$count/$position: omitted dialogues remain explicit");
                like(plain862($lines->[0]), qr/^\[15924\] dialogue 1/,
                    "$max/$count/$position: original ID and beginning survive");
            }
        }
    }
}

for my $count (1, 9, 10) {
    my @text = map {"Speaker: dialogue $_"} 1 .. $count;
    my $lines = format_quote_lines(15924, join("\n", @text));
    my @expected = ($head . shift(@text) . "\x0f", map {$rest . $_ . "\x0f"} @text);
    is_deeply($lines, \@expected, "$count short dialogues retain the complete legacy presentation");
}
for my $id ('??', undef, 'not-an-id') {
    my $lines = format_quote_lines($id, 'Speaker: ' . ('x' x 2000));
    is(scalar @$lines, 1, 'unidentified clipped quote invents no URL or extra message');
    unlike(join('', @$lines), qr/https?:/, 'unidentified quote has no fabricated destination');
    like(plain862($lines->[0]), qr/^\[\?\?\].*…\z/, 'unknown-ID prefix and visible clipping remain');
}
is_deeply(format_quote_lines(15924, "\n \n"), [], 'empty content still produces no quote');
is_deeply(\@warnings, [], 'ASCII and international clipping emit no warnings');
done_testing;
