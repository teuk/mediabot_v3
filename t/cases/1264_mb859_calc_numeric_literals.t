use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::SafeCalc qw(evaluate_expression format_result);

# Perl's numeric conversion does not implement Unicode decimal digits even
# though its regex \d class accepts them. Every numeric position must agree.
for my $case (
    ['arabic_indic', 0x661], ['extended_arabic_indic', 0x6f2],
    ['devanagari', 0x969], ['fullwidth', 0xff14], ['mathematical', 0x1d7d3],
) {
    my ($name, $cp) = @$case; my $digit = chr($cp);
    for my $input (
        ['integer', "$digit+1"], ['integer_suffix', "1$digit+1"],
        ['fraction', "1.$digit+1"], ['leading_fraction', ".$digit+1"],
        ['exponent', "2e$digit"], ['signed_exponent', "2e-$digit"],
    ) {
        my ($position, $expr) = @$input; my (@warnings, $error, $value);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            eval { $value = evaluate_expression($expr); 1 } or $error = $@;
        }
        ok(!defined($value) && ($error // '') eq "Invalid characters in expression.\n",
            "$name $position is refused rather than evaluated from a numeric prefix");
        is_deeply(\@warnings, [], "$name $position emits no Perl conversion warning");
    }
}
for my $case (
    ['0', 0], ['01+2', 3], ['.5 + 1.', 1.5], ['12.5e+1', 125],
    ['2E-2', .02], ['0Xff+1', 256], ['2**-2', .25], ['-2^2', -4],
    ['pow(2,3)+sqrt(16)', 12], ['fmod(10.5,3)', 1.5],
    ["\x{2003}2 + 3\x{2003}", 5], ['1e300 / 1e300', 1],
) {
    my ($expr, $expected) = @$case; my (@warnings, $value, $error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval { $value = evaluate_expression($expr); 1 } or $error = $@;
    }
    ok(!defined($error) && defined($value) && $value == $expected,
        'existing ASCII literals, operators and supported whitespace remain usable');
    is_deeply(\@warnings, [], 'valid arithmetic remains warning-free');
}
{
    my $expr = '12.5e1+1'; utf8::upgrade($expr);
    is(evaluate_expression($expr), 126, 'ASCII digits remain valid in a UTF-8 flagged string');
    is(format_result(evaluate_expression('1/3')), '0.333333', 'historical six-significant-digit formatting is preserved');
}
done_testing;
