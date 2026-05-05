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

    my $configure = _slurp(File::Spec->catfile('.', 'install', 'configure.pl'));
    my $runtime   = _slurp(File::Spec->catfile('.', 'mediabot.pl'));

    for my $module (qw(Mediabot Conf AdminCommands ChannelCommands UserCommands LoginCommands External Partyline)) {
        my $path = File::Spec->catfile('.', 'Mediabot', "$module.pm");
        next unless -f $path;
        $runtime .= "\n" . _slurp($path);
    }

    $assert->like($configure, qr/Enter bot nick \[mediabot\]/, 'configure still asks for primary bot nick');
    $assert->like($configure, qr/print CONF "CONN_NICK=\$line\\n"/, 'configure still writes CONN_NICK');
    $assert->like($configure, qr/Enter bot ident \(username\)/, 'configure still asks for username');
    $assert->like($configure, qr/print CONF "CONN_USERNAME=\$line\\n"/, 'configure still writes CONN_USERNAME');

    $assert->unlike($configure, qr/Enter alternative nick/, 'configure no longer asks for dead alternate nick');
    $assert->unlike($configure, qr/CONN_NICK_ALTERNATE/, 'configure no longer mentions CONN_NICK_ALTERNATE');
    $assert->unlike($runtime, qr/get\('connection\.CONN_NICK_ALTERNATE'\)/, 'runtime does not read connection.CONN_NICK_ALTERNATE');
};
