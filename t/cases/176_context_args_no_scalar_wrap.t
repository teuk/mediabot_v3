# t/cases/176_context_args_no_scalar_wrap.t
# =============================================================================
# Regression checks for Mediabot::Context->args().
#
# Context->args() must not wrap scalar args into an argument list. Command
# wrappers now consistently accept ARRAY args only; the Context accessor should
# enforce the same rule centrally.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Context;
use File::Spec;

sub _slurp_context_176 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $ctx_array = Mediabot::Context->new(
        bot => undef,
        message => undef,
        nick => 'teuk',
        channel => '#test',
        command => 'x',
        args => [ 'one', 'two' ],
    );

    my $array_args = $ctx_array->args;

    $assert->ok(
        ref($array_args) eq 'ARRAY',
        'Context->args returns an ARRAY ref for ARRAY args'
    );

    $assert->is(
        scalar @$array_args,
        2,
        'Context->args preserves ARRAY args'
    );

    my $ctx_scalar = Mediabot::Context->new(
        bot => undef,
        message => undef,
        nick => 'teuk',
        channel => '#test',
        command => 'x',
        args => 'single',
    );

    my $scalar_args = $ctx_scalar->args;

    $assert->ok(
        ref($scalar_args) eq 'ARRAY',
        'Context->args returns an ARRAY ref for scalar args'
    );

    $assert->is(
        scalar @$scalar_args,
        0,
        'Context->args does not convert scalar args into one command argument'
    );

    my $ctx_undef = Mediabot::Context->new(
        bot => undef,
        message => undef,
        nick => 'teuk',
        channel => '#test',
        command => 'x',
        args => undef,
    );

    my $undef_args = $ctx_undef->args;

    $assert->ok(
        ref($undef_args) eq 'ARRAY',
        'Context->args returns an ARRAY ref for undef args'
    );

    $assert->is(
        scalar @$undef_args,
        0,
        'Context->args returns empty args for undef'
    );

    my $src = _slurp_context_176(
        File::Spec->catfile('.', 'Mediabot', 'Context.pm')
    );

    $assert->unlike(
        $src,
        qr/return \[ \$args \];/,
        'Context->args no longer wraps scalar args'
    );

    $assert->like(
        $src,
        qr/return \$args if ref\(\$args\) eq 'ARRAY';/,
        'Context->args returns original ARRAY refs'
    );

    $assert->like(
        $src,
        qr/return \[\];/,
        'Context->args returns empty list for invalid/non-ARRAY args'
    );
};
