use strict;
use warnings;
use utf8;
use Test::More;
use Encode ();
use Mediabot::External::Horoscope ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $cap = \&Mediabot::External::Horoscope::cap_text;
my $family = '👩‍👩‍👧‍👦';
for my $row (
    ['Hello world', 11, 'Hello world'],
    ['Hello world', 10, 'Hello…'],
    ['abcdefg', 4, 'a…'],
    ['éééé', 7, 'éé…'],
    ['🙂🙂🙂', 7, '🙂…'],
    ["e\x{301}" x 3, 7, "e\x{301}…"],
    [$family x 3, 30, "$family…"],
    ['abc;:def', 7, 'abc…'],
    ['foo bar', 6, 'foo…'],
    ['abc', 3, 'abc'],
    ['abcd', 3, ''],
    ['0', 1, '0'],
    ['', 0, ''],
) {
    is($cap->($row->[0], $row->[1]), $row->[2], 'established text, word, punctuation and grapheme boundaries are preserved');
}
ok(!defined $cap->(undef, 20), 'undefined text remains undefined');

for my $sample ('Readable words with accents é and emoji 🙂. ' x 5, $family x 10, "e\x{301}" x 60) {
    for my $limit (4, 7, 12, 30, 64, 120, 380) {
        my $out = $cap->($sample, $limit);
        cmp_ok(length(Encode::encode('UTF-8', $out)), '<=', $limit, 'output remains inside the requested UTF-8 byte budget');
        my $decoded = eval {Encode::decode('UTF-8', Encode::encode('UTF-8', $out), Encode::FB_CROAK())};
        ok(defined($decoded) && $decoded eq $out, 'output remains valid Unicode');
        my $prefix = $out;
        $prefix =~ s/…\z// if length(Encode::encode('UTF-8', $sample)) > $limit;
        like($sample, qr/\A\Q$prefix\E/, 'truncation retains a prefix of the supplied forecast');
        if ($sample eq $family x 10) {
            my $families = $prefix;
            $families =~ s/\Q$family\E//g;
            is($families, '', 'family emoji never loses part of its joined grapheme');
        }
    }
}

# Measure the amount of input actually passed through the real UTF-8 encoder,
# not wall-clock time or a particular loop count. Re-encoding a shrinking whole
# forecast makes this work quadratic; prefix fitting must keep it linear.
my $source = 'A useful forecast for today. ' x 200;
my ($units, $calls, $out) = (0, 0);
my $encode = \&Encode::encode;
{
    no warnings 'redefine';
    local *Encode::encode = sub {
        $units += length($_[1] // '');
        $calls++;
        return $encode->(@_);
    };
    $out = $cap->($source, 380);
}
cmp_ok($units, '<=', 3 * length($source) + 2 * 380, 'large forecasts require only linear UTF-8 encoding work');
note("UTF-8 encoder input: $units characters across $calls calls for ".length($source).' source characters');
cmp_ok(length(Encode::encode('UTF-8', $out)), '<=', 380, 'large forecast still fits the unchanged provider display budget');
like($out, qr/\AA useful forecast.*…\z/, 'large forecast remains readable with the existing ellipsis');
unlike($out, qr/\s…\z/, 'word-boundary trimming does not leave a space before the ellipsis');

my $lines = Mediabot::External::Horoscope::compact_lines(lang => 'fr', target => 'Émilie', date => '2026-10-21',
    sign => 'Lion', glyph => '♌', forecast => ('Votre journée sera utile. ' x 200), number => 42,
    colour => 'émeraude', luck => 80, companion => 'Poissons');
is(scalar @$lines, 2, 'actual compact formatter retains its two-line contract');
ok(!grep({length(Encode::encode('UTF-8', $_)) > 400} @$lines), 'actual compact formatter stays inside both 400-byte payload bounds');
like($lines->[0], qr/♌ \x02Lion\x02.*Émilie.*Votre journée/, 'actual compact formatter retains localized identity and forecast');
like($lines->[1], qr/Nombre 42.*Couleur émeraude.*Chance 80%.*Complice Poissons/, 'lucky details remain unchanged');
done_testing;
