# t/cases/128_configure_no_select_star.t
# =============================================================================
# Regression checks for install/configure.pl SQL queries.
#
# The installer should not use SELECT * when it only needs a few columns.
# Explicit column lists are easier to review and less fragile when schemas grow.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_configure_no_select_star {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_configure_no_select_star(
        File::Spec->catfile('.', 'install', 'configure.pl')
    );

    $assert->unlike(
        $src,
        qr/SELECT\s+\*/i,
        'install/configure.pl does not use SELECT *'
    );

    $assert->like(
        $src,
        qr/SELECT id_network, network_name FROM NETWORK WHERE network_name LIKE \?/,
        'NETWORK lookup selects only id_network and network_name'
    );

    $assert->like(
        $src,
        qr/SELECT server_hostname FROM SERVERS WHERE id_network=\?/,
        'SERVERS lookup selects only server_hostname when listing servers'
    );

    $assert->like(
        $src,
        qr/SELECT id_channel, description FROM CHANNEL WHERE description='console'/,
        'console channel lookup selects only needed CHANNEL columns'
    );

    $assert->like(
        $src,
        qr/\$ref->\{'id_network'\}/,
        'configure still reads id_network from NETWORK lookup'
    );

    $assert->like(
        $src,
        qr/\$ref->\{'network_name'\}/,
        'configure still reads network_name from NETWORK lookup'
    );

    $assert->like(
        $src,
        qr/\$ref->\{'server_hostname'\}/,
        'configure still reads server_hostname from SERVERS lookup'
    );
};
