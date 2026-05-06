# t/cases/136_conf_servers_write_network_safe.t
# =============================================================================
# Regression checks for install/conf_servers.pl writeNetworkToConf().
#
# writeNetworkToConf used to call sed through a shell pipeline. That was fragile
# for network names containing shell/sed metacharacters and logged the wrong
# variable. It should be pure Perl file handling now.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_conf_servers_write_network {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_conf_servers_write_network {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;
            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_conf_servers_write_network(
        File::Spec->catfile('.', 'install', 'conf_servers.pl')
    );

    my $body = _extract_sub_body_conf_servers_write_network($src, 'writeNetworkToConf');

    $assert->ok(
        defined $body,
        'writeNetworkToConf body found'
    );

    $assert->unlike(
        $body // '',
        qr/open\s+SED/,
        'writeNetworkToConf no longer opens a sed pipeline'
    );

    $assert->unlike(
        $body // '',
        qr/sed -i/,
        'writeNetworkToConf no longer shells out to sed'
    );

    $assert->like(
        $body // '',
        qr/open my \$in, '<:encoding\(UTF-8\)', \$CONFIG_FILE/,
        'writeNetworkToConf reads the config file with Perl'
    );

    $assert->like(
        $body // '',
        qr/open my \$out, '>:encoding\(UTF-8\)', \$CONFIG_FILE/,
        'writeNetworkToConf writes the config file with Perl'
    );

    $assert->like(
        $body // '',
        qr/CONN_SERVER_NETWORK=\$sNetworkName/,
        'writeNetworkToConf writes the requested network name'
    );

    $assert->like(
        $body // '',
        qr/Set CONN_SERVER_NETWORK to \$sNetworkName in config file/,
        'writeNetworkToConf logs the local sNetworkName argument'
    );

    $assert->unlike(
        $body // '',
        qr/Set CONN_SERVER_NETWORK to \$CONN_SERVER_NETWORK in config file/,
        'writeNetworkToConf no longer logs stale global CONN_SERVER_NETWORK'
    );
};
