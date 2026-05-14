# t/cases/219_usercommands_trivia_guard.t
# =============================================================================
# Verify checkTriviaAnswer has eval guard and defined check (B3/fix).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_219 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

sub _extract_sub_219 {
    my ($src, $sub_name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my $start = $-[0]; my $pos = pos($src); my $depth = 1;
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{'; $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_219(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $body = _extract_sub_219($src, 'checkTriviaAnswer');

    $assert->ok(defined $body && $body ne '', 'checkTriviaAnswer sub found');

    $assert->like($body // '', qr/defined.*answer/,
        'checkTriviaAnswer checks defined before matching');

    $assert->like($body // '', qr/eval\s*\{/,
        'checkTriviaAnswer wraps regex in eval');

    $assert->like($body // '', qr/deadline/,
        'checkTriviaAnswer checks deadline expiry');

    $assert->like($src, qr/sub mbTrivia_ctx/,   'mbTrivia_ctx exists');
    $assert->like($src, qr/sub mbTriviaScore_ctx/, 'mbTriviaScore_ctx exists');
};
