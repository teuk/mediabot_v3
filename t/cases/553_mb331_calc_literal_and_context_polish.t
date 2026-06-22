# t/cases/553_mb331_calc_literal_and_context_polish.t
# =============================================================================
# mb331 — warning-free numeric literals, Context-safe calc replies, and a
# functional calclast [1-3] argument.
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

sub _slurp_553 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my @warnings;
    my $long_hex = '0x' . ('F' x 80);
    my $hex_value;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $hex_value = evaluate_expression($long_hex);
    }

    $assert->is(scalar(@warnings), 0,
        'long hexadecimal literal emits no Perl portability/overflow warning');
    $assert->ok(defined($hex_value) && $hex_value > 0,
        'long hexadecimal literal remains a bounded numeric value');
    $assert->is(evaluate_expression('0x41+1'), 66,
        'ordinary hexadecimal arithmetic remains compatible');

    my @decimal_warnings;
    my $decimal_error = '';
    {
        local $SIG{__WARN__} = sub { push @decimal_warnings, @_ };
        my $ok = eval { evaluate_expression('1e999999'); 1 };
        $decimal_error = $@ unless $ok;
    }
    $assert->is(scalar(@decimal_warnings), 0,
        'oversized scientific literal emits no unhandled Perl warning');
    $assert->like($decimal_error, qr/Number too large/,
        'oversized scientific literal is rejected cleanly');

    my $safe = _slurp_553(File::Spec->catfile('.', 'Mediabot', 'SafeCalc.pm'));
    my $db   = _slurp_553(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $user = _slurp_553(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $main = _slurp_553(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    $assert->like($safe, qr/sub _parse_hex_literal/,
        'SafeCalc has an explicit warning-free hexadecimal parser');
    $assert->like($safe, qr/sub _parse_decimal_literal/,
        'SafeCalc validates decimal/scientific conversion');
    $assert->unlike($safe, qr/number\s*=>\s*hex\(/,
        'tokenizer no longer calls Perl hex() directly on IRC input');

    $assert->like($db, qr/\$ctx->reply\("\$expr = \$formatted"\)/,
        'successful calc replies use Context routing');
    $assert->like($db, qr/\$ctx->reply\("calc error: \$error"\)/,
        'calculator errors use Context routing');
    $assert->unlike($db,
        qr/botPrivmsg\(\$self,\s*\$channel,\s*"(?:calc error: \$error|\$expr = \$formatted)"/,
        'calc no longer writes success/errors to a possibly undefined channel');

    $assert->like($user, qr/Syntax: calclast \[1-3\]/,
        'calclast validates its documented optional count');
    $assert->like($user, qr/my \$shown = min\(\$limit, scalar\(\@\$history\)\)/,
        'calclast limits output to the requested available count');
    $assert->like($user, qr/\$ctx->reply\('Last ' \. \$shown/,
        'calclast uses Context for public/private routing');
    $assert->like($main, qr/calclast\|calclast \[1-3\]\|public\|/,
        'help advertises the functional calclast count');
};
