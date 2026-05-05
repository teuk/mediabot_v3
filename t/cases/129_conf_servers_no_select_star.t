# t/cases/129_conf_servers_no_select_star.t
# =============================================================================
# Regression checks for install/conf_servers.pl SQL queries.
#
# The IRC server configuration helper should not use SELECT * when it only
# needs explicit NETWORK/SERVERS columns.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_conf_servers_no_select_star {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_conf_servers_no_select_star(
        File::Spec->catfile('.', 'install', 'conf_servers.pl')
    );

    $assert->unlike(
        $src,
        qr/SELECT\s+\*/i,
        'install/conf_servers.pl does not use SELECT *'
    );

    $assert->like(
        $src,
        qr/SELECT id_network, network_name FROM NETWORK WHERE network_name LIKE \?/,
        'NETWORK lookup selects only id_network and network_name'
    );

    $assert->like(
        $src,
        qr/SELECT id_server FROM SERVERS WHERE server_hostname LIKE \?/,
        'SERVERS hostname lookup selects only id_server'
    );

    $assert->like(
        $src,
        qr/SELECT id_server, server_hostname FROM SERVERS WHERE id_network=\?/,
        'SERVERS network listing selects id_server and server_hostname'
    );

    $assert->like(
        $src,
        qr/SELECT id_server FROM SERVERS WHERE id_server=\?/,
        'SERVERS delete lookup selects only id_server'
    );

    $assert->like(
        $src,
        qr/SELECT id_network, network_name FROM NETWORK/,
        'NETWORK listing selects only id_network and network_name'
    );

    $assert->like(
        $src,
        qr/IRC Server \$server_hostname added in SERVERS table with id : \$id_server/,
        'addIrcServer logs the local server_hostname argument'
    );

    $assert->unlike(
        $src,
        qr/IRC Server \$line added in SERVERS table/,
        'addIrcServer no longer logs the global $line value'
    );
};
