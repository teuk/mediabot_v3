# t/cases/17_timer_validation.t
# =============================================================================
# Static regression checks for addtimer validation.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    $assert->ok(
        $src =~ /\$name =~ \/\^\[A-Za-z0-9_\.-\]\{1,64\}\$\/ / ||
        $src =~ /\$name =~ \/\^\[A-Za-z0-9_\.-\]\{1,64\}\$\/\)/,
        'addtimer validates timer name format and length'
    );

    $assert->ok(
        $src =~ /Timer name must be 1-64 chars/,
        'addtimer has user-facing invalid name message'
    );

    $assert->ok(
        $src =~ /\$interval < 5 \|\| \$interval > 86400/,
        'addtimer clamps interval range'
    );

    $assert->ok(
        $src =~ /Timer interval must be between 5 and 86400 seconds/,
        'addtimer has user-facing invalid interval message'
    );

    $assert->ok(
        $src =~ /length\(\$cmd\) > 255/,
        'addtimer rejects commands longer than TIMERS.command'
    );

    $assert->ok(
        $src =~ /Timer command is too long \(max 255 chars\)/,
        'addtimer has user-facing command length message'
    );

    $assert->ok(
        $src =~ /my \@allowed_verbs = qw\(PRIVMSG NOTICE JOIN PART TOPIC MODE KICK INVITE WHO WHOIS PING PONG\)/,
        'addtimer still validates allowed IRC verbs'
    );
};
