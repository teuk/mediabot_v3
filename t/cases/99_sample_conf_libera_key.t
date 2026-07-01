use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_libera {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample    = _slurp_mb378_libera(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $main      = _slurp_mb378_libera(File::Spec->catfile('.', 'mediabot.pl'));
    my $configure = _slurp_mb378_libera(File::Spec->catfile('.', 'install', 'configure.pl'));

    $assert->like($sample, qr/^\[libera\]$/m, 'sample config documents [libera]');
    $assert->like($sample, qr/^LIBERA_NICKSERV_PASSWORD=$/m,
        'sample defines empty LIBERA_NICKSERV_PASSWORD');
    $assert->like($sample, qr/CONN_NETWORK_TYPE=2/,
        'sample explains the network type condition');
    $assert->like($sample, qr/Libera-style NickServ authentication|Libera NickServ authentication/,
        'sample explains Libera NickServ authentication');

    $assert->like($main, qr/get\('libera\.LIBERA_NICKSERV_PASSWORD'\)/,
        'runtime reads libera.LIBERA_NICKSERV_PASSWORD');
    $assert->like($main, qr/CONN_NETWORK_TYPE'\)\s*==\s*2/,
        'runtime uses the Libera key for network type 2');

    $assert->like($configure, qr/Configuring the Libera\/NickServ service section/,
        'wizard names the Libera section');
    $assert->like($configure, qr/0=Other, 1=Undernet \(X\), 2=Libera\/NickServ/,
        'wizard displays network type 2 as Libera/NickServ');
    $assert->like($configure, qr/\$set\{'libera\.LIBERA_NICKSERV_PASSWORD'\}/,
        'wizard updates LIBERA_NICKSERV_PASSWORD through the atomic overlay');
    $assert->like($configure, qr/write_overlay_and_merge/,
        'wizard writes the Libera setting through the shared merge path');

    my $obsolete_network_name = join('', qw(free node));
    for my $src_name ([sample => $sample], [main => $main], [configure => $configure]) {
        my ($name, $src) = @$src_name;
        $assert->unlike($src, qr/\Q$obsolete_network_name\E/i,
            "$name does not mention the obsolete network name");
    }
};
