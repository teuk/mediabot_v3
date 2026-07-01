use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_select_star {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $src = _slurp_mb378_select_star(File::Spec->catfile('.', 'install', 'configure.pl'));

    $assert->unlike($src, qr/SELECT\s+\*/i, 'install/configure.pl does not use SELECT *');
    $assert->like($src, qr/SELECT id_network, network_name FROM NETWORK WHERE network_name = \?/,
        'NETWORK lookup uses explicit columns and an exact parameter');
    $assert->like($src, qr/SELECT server_hostname FROM SERVERS WHERE id_network = \? ORDER BY id_server/,
        'SERVERS lookup uses only the required column');
    $assert->like($src, qr/SELECT id_channel, name FROM CHANNEL WHERE description='console'/,
        'console lookup uses only required CHANNEL columns');
    $assert->like($src, qr/\$row->\{id_network\}/,
        'configure reads id_network from the NETWORK row');
    $assert->like($src, qr/\$row->\{network_name\}/,
        'configure reads network_name from the NETWORK row');
    $assert->like($src, qr/fetchrow_array/,
        'configure reads server_hostname through the explicit result column');
};
