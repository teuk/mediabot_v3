# t/cases/552_mb330_calc_parser_no_eval.t
# =============================================================================
# mb330 — replace internal !calc string eval with a recursive-descent parser.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::SafeCalc qw(evaluate_expression format_result);

sub _slurp_552 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _error_552 {
    my ($expression) = @_;
    my $ok = eval { evaluate_expression($expression); 1 };
    return '' if $ok;
    my $error = $@ // '';
    $error =~ s/\s+\z//;
    return $error;
}

return sub {
    my ($assert) = @_;

    my %exact = (
        '2+2'             => 4,
        '2+2*3'           => 8,
        '(2+2)*3'         => 12,
        '2**3**2'         => 512,
        '-2**2'           => -4,
        '2**-2'           => 0.25,
        '1e5*2'           => 200000,
        '0x41+1'          => 66,
        'sqrt(16)'        => 4,
        'pow(2,8)'        => 256,
        'fmod(10.5,3)'    => 1.5,
        'round(-3.7)'     => -4,
        'floor(3.9)'      => 3,
        'ceil(3.1)'       => 4,
        '5^3'             => 125,
        '2^-2'            => 0.25,
    );

    for my $expression (sort keys %exact) {
        $assert->is(
            evaluate_expression($expression),
            $exact{$expression},
            "safe parser evaluates $expression"
        );
    }

    my $pi_result = evaluate_expression('pi*2');
    $assert->ok(abs($pi_result - 6.28318530717958) < 1e-12,
        'pi constant is evaluated without textual substitution');

    my $trig = evaluate_expression('cos(deg2rad(45))');
    $assert->ok(abs($trig - 0.707106781186548) < 1e-12,
        'nested trigonometric functions work');

    my $atan = evaluate_expression('atan(1)');
    $assert->ok(abs($atan - 0.785398163397448) < 1e-12,
        'atan is now implemented instead of merely allowlisted');

    for my $bad (
        'kill(9,-1)',
        'sleep(99999999)',
        'fork()',
        'unlink(passwd)',
        '9x999999',
        'system(ls)',
        '`id`',
        '2;system(ls)',
        'sqrt(1,2)',
        '1/0',
        'sqrt(-1)',
        'log(0)',
        '2**1001',
        '2 2',
    ) {
        $assert->ok(_error_552($bad) ne '', "unsafe/invalid input rejected: $bad");
    }

    $assert->is(format_result(4), '4', 'integer formatting preserved');
    $assert->is(format_result(0.707106781186548), '0.707107',
        'historical six-significant-digit formatting preserved');
    $assert->is(format_result(-0.0), '0', 'negative zero is normalized');

    my $safe = _slurp_552(File::Spec->catfile('.', 'Mediabot', 'SafeCalc.pm'));
    my $db   = _slurp_552(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    $assert->like($safe, qr/sub _parse_power/, 'SafeCalc contains a real precedence parser');
    $assert->like($safe, qr/MAX_EXPONENT_ABS/, 'SafeCalc caps exponents');
    $assert->like($safe, qr/MAX_ABS_RESULT/, 'SafeCalc caps result magnitude');
    $assert->unlike($safe, qr/eval\s+\$\w+\b/, 'SafeCalc never string-evals input');
    $assert->unlike($db, qr/eval\s+\$expr\b/, 'mbCalc_ctx no longer string-evals input');
    $assert->like($db, qr/"\$expr = \$formatted"/, 'history preserves the original expression');
};
