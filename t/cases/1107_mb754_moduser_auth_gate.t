# MB754 follow-up — moduser rejects unauthenticated privileged hostmask matches.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Spec;

sub _slurp_1107 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _sub_body_1107 {
    my ($src, $name) = @_;
    return undef unless $src =~ /^sub\s+\Q$name\E\s*\{/mg;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;

    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        if ($char eq '}') {
            $depth--;
            return substr($src, $start, $pos - $start) if $depth == 0;
        }
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $usercommands = _slurp_1107(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );
    my $context = _slurp_1107(
        File::Spec->catfile('.', 'Mediabot', 'Context.pm')
    );

    my $moduser = _sub_body_1107($usercommands, 'mbModUser_ctx');
    my $require_level = _sub_body_1107($context, 'require_level');

    $assert->ok(defined $moduser,
        'moduser handler body is available for the security contract');
    $assert->ok(defined $require_level,
        'context level guard body is available for the security contract');

    my $guard = q{$ctx->require_level('Administrator') or return;};
    my $guard_at  = index($moduser // '', $guard);
    my $target_at = index($moduser // '', 'my $target_nick = shift @args;');
    my $select_at = index($moduser // '', 'my $select_one = sub');

    $assert->ok($guard_at >= 0,
        'moduser requires the documented Administrator level');
    $assert->ok($target_at >= 0 && $guard_at < $target_at,
        'moduser authenticates before resolving a target account');
    $assert->ok($select_at >= 0 && $guard_at < $select_at,
        'moduser authenticates before preparing any database helper');

    $assert->like(
        $require_level // '',
        qr/unless \$user && \$user->is_authenticated/,
        'the shared level guard rejects an unauthenticated user object'
    );
    $assert->like(
        $require_level // '',
        qr/return 1 if \$user->has_level\(\$level\)/,
        'the shared level guard also enforces the requested privilege'
    );
};
