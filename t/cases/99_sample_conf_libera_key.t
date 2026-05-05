# t/cases/99_sample_conf_libera_key.t
# =============================================================================
# Regression checks for Libera/NickServ configuration.
#
# Network type 2 is Libera-style NickServ authentication.
#
# Runtime code reads:
#   libera.LIBERA_NICKSERV_PASSWORD
#
# install/configure.pl writes:
#   [libera]
#   LIBERA_NICKSERV_PASSWORD=...
#
# The root sample config must document the same key.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_libera_key {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_libera_key(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $main = _slurp_libera_key(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    my $configure = _slurp_libera_key(
        File::Spec->catfile('.', 'install', 'configure.pl')
    );

    $assert->like(
        $sample,
        qr/^\[libera\]$/m,
        'sample config documents the [libera] section'
    );

    $assert->like(
        $sample,
        qr/^LIBERA_NICKSERV_PASSWORD=$/m,
        'sample config defines empty LIBERA_NICKSERV_PASSWORD'
    );

    $assert->like(
        $sample,
        qr/CONN_NETWORK_TYPE=2/,
        'sample config explains the network type condition'
    );

    $assert->like(
        $sample,
        qr/Libera-style NickServ authentication|Libera NickServ authentication/,
        'sample config explains Libera NickServ authentication'
    );

    $assert->like(
        $main,
        qr/get\('libera\.LIBERA_NICKSERV_PASSWORD'\)/,
        'mediabot.pl reads libera.LIBERA_NICKSERV_PASSWORD'
    );

    $assert->like(
        $main,
        qr/CONN_NETWORK_TYPE'\)\s*==\s*2/,
        'mediabot.pl uses the Libera key for CONN_NETWORK_TYPE=2'
    );

    $assert->like(
        $configure,
        qr/Configure Libera section/,
        'install/configure.pl names the section Libera'
    );

    $assert->like(
        $configure,
        qr/2 : Libera \(NickServ\)/,
        'network type 2 is displayed as Libera'
    );

    $assert->like(
        $configure,
        qr/print CONF "\[libera\]\\n"/,
        'install/configure.pl writes the [libera] section'
    );

    $assert->like(
        $configure,
        qr/print CONF "LIBERA_NICKSERV_PASSWORD=\$line\\n"/,
        'install/configure.pl writes LIBERA_NICKSERV_PASSWORD'
    );

    for my $src_name (
        [ sample    => $sample ],
        [ main      => $main ],
        [ configure => $configure ],
    ) {
        my ($name, $src) = @$src_name;

        my $obsolete_network_name = join('', qw(free node));

        $assert->unlike(
            $src,
            qr/\Q$obsolete_network_name\E/i,
            "$name no longer mentions the obsolete network name in any casing"
        );
    }
};
