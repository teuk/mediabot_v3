use strict;
use warnings;
use Test::More;
use Mediabot::SafeCalc qw(evaluate_expression);

my @cases = (
    [('-' x 127).'1', -1],
    [('+' x 127).'1', 1],
    [('-+' x 63).'-1', 1],
    [('+-' x 63).'+1', -1],
    ['-2**2', -4],
    ['(-2)**2', 4],
    ['2**-2', .25],
    ['2^-2^2', .0625],
    ['--2**3**2', 512],
    ['3*-+-2', 6],
    ['1--2', 3],
    ['-0', 0],
    ['abs(---5)', 5],
    ['pow(--2,-+3)', .125],
    [('(' x 30).('-' x 60).'1'.(')' x 30), 1],
);
for my $n (1, 2, 63, 98, 99, 100, 126, 127) {
    push @cases, [('-' x $n).'1', $n % 2 ? -1 : 1];
}
for my $case (@cases) {
    my ($expr, $want) = @$case;
    my (@warnings, $got, $error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $got = eval { evaluate_expression($expr) };
        $error = $@;
    }
    is($error, '', 'valid expression accepted');
    is($got, $want, 'sign parity and operator precedence preserved');
    is_deeply(\@warnings, [], 'valid expression emits no recursion warning');
    # Repeated calculations must not retain sign state between expressions.
    is(evaluate_expression('2+3'), 5, 'next expression is independent');
}
for my $case (
    [('-' x 128).'1', qr/Expression too long/],
    ['-' x 128, qr/Invalid expression/],
    ['2**---1001', qr/Exponent too large/],
    ['1/--0', qr/Division by zero/],
    ['--sqrt(-1)', qr/Invalid function domain/],
) {
    my (@warnings, $error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval { evaluate_expression($case->[0]) };
        $error = $@;
    }
    like($error, $case->[1], 'invalid expression retains its expected error');
    is_deeply(\@warnings, [], 'rejected expression emits no recursion warning');
}
done_testing;
