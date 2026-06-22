package Mediabot::SafeCalc;

# =============================================================================
# Mediabot::SafeCalc
# =============================================================================
# A dependency-light, recursive-descent arithmetic parser used by !calc.
#
# Security model:
#   * no string eval;
#   * numeric literals, constants, operators and explicitly listed functions;
#   * bounded expression length, exponent and result magnitude;
#   * deterministic parser with no variable, method, package or file access.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use POSIX ();
use Scalar::Util qw(looks_like_number);

our @EXPORT_OK = qw(evaluate_expression format_result);

use constant MAX_EXPRESSION_LENGTH => 128;
use constant MAX_EXPONENT_ABS      => 1000;
use constant MAX_ABS_RESULT        => 1e300;
use constant MAX_PARSE_STEPS       => 512;

our %CONSTANT = (
    pi  => 3.14159265358979,
    tau => 6.28318530717959,
    e   => 2.71828182845905,
);

my %ARITY = (
    sqrt    => 1,
    sin     => 1,
    cos     => 1,
    tan     => 1,
    asin    => 1,
    acos    => 1,
    atan    => 1,
    atan2   => 2,
    abs     => 1,
    int     => 1,
    log     => 1,
    exp     => 1,
    floor   => 1,
    ceil    => 1,
    round   => 1,
    pow     => 2,
    fmod    => 2,
    deg2rad => 1,
    rad2deg => 1,
);

sub evaluate_expression {
    my ($expression) = @_;

    die "Empty expression.\n"
        unless defined($expression) && $expression =~ /\S/;

    die "Expression too long.\n"
        if length($expression) > MAX_EXPRESSION_LENGTH;

    my $tokens = _tokenize($expression);
    my $parser = bless {
        tokens => $tokens,
        index  => 0,
        steps  => 0,
    }, 'Mediabot::SafeCalc::Parser';

    my $value = $parser->_parse_add;
    $parser->_expect('eof');

    return _guard_number($value);
}

sub format_result {
    my ($value) = @_;
    $value = _guard_number($value);

    # Avoid displaying the slightly surprising string "-0".
    $value = 0 if $value == 0;

    return sprintf('%d', $value)
        if $value == int($value) && abs($value) < 1e15;

    # Preserve the historical !calc formatting (six significant digits).
    return sprintf('%g', $value);
}

# Parse hexadecimal literals without Perl's hex() portability/overflow
# warnings. Long IRC-controlled literals used to write warnings directly to
# STDERR during tokenization, even though the calculator later returned a
# valid bounded numeric result.
sub _parse_hex_literal {
    my ($raw) = @_;
    my $digits = $raw // '';
    $digits =~ s/^0[xX]//;

    die "Invalid numeric literal.\n" unless $digits =~ /\A[0-9A-Fa-f]+\z/;

    my $value = 0;
    for my $char (split //, $digits) {
        my $digit = index('0123456789abcdef', lc($char));
        die "Invalid numeric literal.\n" if $digit < 0;
        $value = _checked(sub { $value * 16 + $digit });
    }

    return _guard_number($value);
}

# Decimal/scientific conversion is also kept behind the numeric guard so an
# overflow can never escape as an unhandled warning or a non-finite token.
sub _parse_decimal_literal {
    my ($raw) = @_;
    my ($value, $warning) = (undef, '');

    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] // '' };
        $value = 0 + $raw;
    }

    die "Number too large.\n"
        if $warning =~ /(?:overflow|non-finite|nan|infinity)/i;

    return _guard_number($value);
}

sub _tokenize {
    my ($expression) = @_;
    my @tokens;

    pos($expression) = 0;

    while (pos($expression) < length($expression)) {
        if ($expression =~ /\G\s+/gc) {
            next;
        }

        if ($expression =~ /\G(0[xX][0-9A-Fa-f]+)/gc) {
            my $raw = $1;
            push @tokens, [ number => _parse_hex_literal($raw), $raw ];
            next;
        }

        if ($expression =~ /\G((?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+\-]?\d+)?)/gc) {
            my $raw = $1;
            push @tokens, [ number => _parse_decimal_literal($raw), $raw ];
            next;
        }

        if ($expression =~ /\G([A-Za-z_][A-Za-z0-9_]*)/gc) {
            push @tokens, [ ident => lc($1), $1 ];
            next;
        }

        if ($expression =~ /\G(\*\*|[+\-*\/%^(),])/gc) {
            push @tokens, [ op => $1, $1 ];
            next;
        }

        die "Invalid characters in expression.\n";
    }

    push @tokens, [ eof => '', '' ];
    return \@tokens;
}

sub _guard_number {
    my ($value) = @_;

    die "Unsupported result.\n"
        if !defined($value) || ref($value) || !looks_like_number($value);

    my $rendered = "$value";
    die "Number too large.\n"
        if $rendered =~ /(?:nan|inf)/i;

    die "Number too large.\n"
        if abs($value) > MAX_ABS_RESULT;

    return 0 + $value;
}

sub _checked {
    my ($code) = @_;
    my $warning = '';
    my ($value, $ok);

    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] // '' };
        $ok = eval {
            $value = $code->();
            1;
        };
    }

    if (!$ok) {
        my $error = $@ || 'Invalid arithmetic operation.';
        $error =~ s/\s+at\s+.*?\s+line\s+\d+.*\z//s;
        $error =~ s/\s+\z//;
        die "$error\n";
    }

    die "Number too large.\n"
        if $warning =~ /(?:overflow|non-finite|nan|infinity)/i;

    return _guard_number($value);
}

sub _safe_power {
    my ($base, $exponent) = @_;

    $base     = _guard_number($base);
    $exponent = _guard_number($exponent);

    die "Exponent too large.\n"
        if abs($exponent) > MAX_EXPONENT_ABS;

    die "Division by zero.\n"
        if $base == 0 && $exponent < 0;

    return _checked(sub { $base ** $exponent });
}

sub _apply_function {
    my ($name, $args) = @_;

    die "Expression not allowed.\n"
        unless exists $ARITY{$name};

    my $expected = $ARITY{$name};
    die "Function '$name' expects $expected argument(s).\n"
        unless @$args == $expected;

    my @a = map { _guard_number($_) } @$args;

    return _checked(sub { sqrt($a[0]) }) if $name eq 'sqrt' && $a[0] >= 0;
    die "Invalid function domain.\n"     if $name eq 'sqrt';

    return _checked(sub { sin($a[0]) })  if $name eq 'sin';
    return _checked(sub { cos($a[0]) })  if $name eq 'cos';

    if ($name eq 'tan') {
        my $cos = cos($a[0]);
        die "Invalid function domain.\n" if abs($cos) < 1e-15;
        return _checked(sub { sin($a[0]) / $cos });
    }

    if ($name eq 'asin') {
        die "Invalid function domain.\n" if $a[0] < -1 || $a[0] > 1;
        return _checked(sub { atan2($a[0], sqrt(1 - $a[0] * $a[0])) });
    }

    if ($name eq 'acos') {
        die "Invalid function domain.\n" if $a[0] < -1 || $a[0] > 1;
        return _checked(sub { atan2(sqrt(1 - $a[0] * $a[0]), $a[0]) });
    }

    return _checked(sub { atan2($a[0], 1) })      if $name eq 'atan';
    return _checked(sub { atan2($a[0], $a[1]) }) if $name eq 'atan2';
    return _checked(sub { abs($a[0]) })           if $name eq 'abs';
    return _checked(sub { int($a[0]) })           if $name eq 'int';

    if ($name eq 'log') {
        die "Invalid function domain.\n" if $a[0] <= 0;
        return _checked(sub { log($a[0]) });
    }

    return _checked(sub { exp($a[0]) })          if $name eq 'exp';
    return _checked(sub { POSIX::floor($a[0]) }) if $name eq 'floor';
    return _checked(sub { POSIX::ceil($a[0]) })  if $name eq 'ceil';

    if ($name eq 'round') {
        return _checked(sub {
            int($a[0] + 0.5 * ($a[0] >= 0 ? 1 : -1));
        });
    }

    return _safe_power($a[0], $a[1]) if $name eq 'pow';

    if ($name eq 'fmod') {
        die "Division by zero.\n" if $a[1] == 0;
        return _checked(sub { POSIX::fmod($a[0], $a[1]) });
    }

    return _checked(sub { $a[0] * $CONSTANT{pi} / 180 }) if $name eq 'deg2rad';
    return _checked(sub { $a[0] * 180 / $CONSTANT{pi} }) if $name eq 'rad2deg';

    die "Expression not allowed.\n";
}

package Mediabot::SafeCalc::Parser;

use strict;
use warnings;

sub _step {
    my ($self) = @_;
    $self->{steps}++;
    die "Expression is too complex.\n"
        if $self->{steps} > Mediabot::SafeCalc::MAX_PARSE_STEPS();
}

sub _peek {
    my ($self) = @_;
    return $self->{tokens}[ $self->{index} ];
}

sub _take {
    my ($self) = @_;
    $self->_step;
    return $self->{tokens}[ $self->{index}++ ];
}

sub _accept_op {
    my ($self, $operator) = @_;
    my $token = $self->_peek;

    return 0 unless $token->[0] eq 'op' && $token->[1] eq $operator;
    $self->_take;
    return 1;
}

sub _expect {
    my ($self, $type, $value) = @_;
    my $token = $self->_peek;

    my $matches = $token->[0] eq $type;
    $matches &&= $token->[1] eq $value if defined $value;

    die "Invalid expression.\n" unless $matches;
    return $self->_take;
}

# Addition/subtraction are the top-level expression grammar. The '^'
# operator is handled as exponentiation together with '**', matching normal
# calculator notation instead of Perl's surprising bitwise-XOR semantics.
sub _parse_add {
    my ($self) = @_;
    my $value = $self->_parse_mul;

    while (1) {
        if ($self->_accept_op('+')) {
            my $right = $self->_parse_mul;
            $value = Mediabot::SafeCalc::_checked(sub { $value + $right });
            next;
        }

        if ($self->_accept_op('-')) {
            my $right = $self->_parse_mul;
            $value = Mediabot::SafeCalc::_checked(sub { $value - $right });
            next;
        }

        last;
    }

    return $value;
}

sub _parse_mul {
    my ($self) = @_;
    my $value = $self->_parse_unary;

    while (1) {
        if ($self->_accept_op('*')) {
            my $right = $self->_parse_unary;
            $value = Mediabot::SafeCalc::_checked(sub { $value * $right });
            next;
        }

        if ($self->_accept_op('/')) {
            my $right = $self->_parse_unary;
            die "Division by zero.\n" if $right == 0;
            $value = Mediabot::SafeCalc::_checked(sub { $value / $right });
            next;
        }

        if ($self->_accept_op('%')) {
            my $right = $self->_parse_unary;
            die "Division by zero.\n" if $right == 0;
            $value = Mediabot::SafeCalc::_checked(sub { $value % $right });
            next;
        }

        last;
    }

    return $value;
}

# Unary signs bind less tightly than exponentiation, preserving:
#   -2**2  == -(2**2)
#   2**-2  == 2**(-2)
sub _parse_unary {
    my ($self) = @_;

    return $self->_parse_unary if $self->_accept_op('+');

    if ($self->_accept_op('-')) {
        my $value = $self->_parse_unary;
        return Mediabot::SafeCalc::_checked(sub { -$value });
    }

    return $self->_parse_power;
}

sub _parse_power {
    my ($self) = @_;
    my $value = $self->_parse_primary;

    if ($self->_accept_op('**') || $self->_accept_op('^')) {
        my $right = $self->_parse_unary;
        $value = Mediabot::SafeCalc::_safe_power($value, $right);
    }

    return $value;
}

sub _parse_primary {
    my ($self) = @_;
    my $token = $self->_peek;

    if ($token->[0] eq 'number') {
        $self->_take;
        return Mediabot::SafeCalc::_guard_number($token->[1]);
    }

    if ($token->[0] eq 'ident') {
        my $name = $self->_take->[1];

        if ($self->_accept_op('(')) {
            my @args;

            unless ($self->_accept_op(')')) {
                push @args, $self->_parse_add;
                while ($self->_accept_op(',')) {
                    push @args, $self->_parse_add;
                }
                $self->_expect('op', ')');
            }

            return Mediabot::SafeCalc::_apply_function($name, \@args);
        }

        return $Mediabot::SafeCalc::CONSTANT{$name}
            if exists $Mediabot::SafeCalc::CONSTANT{$name};

        die "Expression not allowed.\n";
    }

    if ($self->_accept_op('(')) {
        my $value = $self->_parse_add;
        $self->_expect('op', ')');
        return $value;
    }

    die "Invalid expression.\n";
}

1;
