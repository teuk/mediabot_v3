use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_alt_nick {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $configure = _slurp_mb378_alt_nick(File::Spec->catfile('.', 'install', 'configure.pl'));
    my $runtime   = _slurp_mb378_alt_nick(File::Spec->catfile('.', 'mediabot.pl'));

    for my $module (qw(Mediabot Conf AdminCommands ChannelCommands UserCommands LoginCommands External Partyline)) {
        my $path = File::Spec->catfile('.', 'Mediabot', "$module.pm");
        next unless -f $path;
        $runtime .= "\n" . _slurp_mb378_alt_nick($path);
    }

    $assert->like($configure, qr/'Bot nick'/, 'configure still asks for primary bot nick');
    $assert->like($configure, qr/\$set\{'connection\.CONN_NICK'\}/,
        'configure still writes CONN_NICK through the overlay');
    $assert->like($configure, qr/'Bot ident \(username\)'/,
        'configure still asks for username');
    $assert->like($configure, qr/\$set\{'connection\.CONN_USERNAME'\}/,
        'configure still writes CONN_USERNAME through the overlay');

    $assert->unlike($configure, qr/alternative nick/i, 'configure does not ask for dead alternate nick');
    $assert->unlike($configure, qr/CONN_NICK_ALTERNATE/, 'configure does not mention CONN_NICK_ALTERNATE');
    $assert->unlike($runtime, qr/get\('connection\.CONN_NICK_ALTERNATE'\)/,
        'runtime does not read connection.CONN_NICK_ALTERNATE');
};
