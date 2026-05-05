# t/cases/124_conf_servers_no_duplicate_required_checks.t
# =============================================================================
# Regression checks for install/conf_servers.pl required config validation.
#
# The script should validate each required database configuration key once.
# Duplicate required checks make installer control flow harder to read and can
# hide copy/paste mistakes.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_conf_servers_checks {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_conf_servers_checks(
        File::Spec->catfile('.', 'install', 'conf_servers.pl')
    );

    my @required = qw(
        MAIN_PROG_DDBNAME
        MAIN_PROG_DBUSER
        MAIN_PROG_DBPASS
        MAIN_PROG_DBHOST
        MAIN_PROG_DBPORT
    );

    for my $var (@required) {
        my $needle = 'unless (defined($' . $var . '))';
        my $count  = () = $src =~ /\Q$needle\E/g;

        $assert->is(
            $count,
            1,
            "install/conf_servers.pl checks $var exactly once"
        );

        $assert->like(
            $src,
            qr/\Q$var\E was not found in \$CONFIG_FILE/,
            "install/conf_servers.pl has a clear error message for $var"
        );
    }

    $assert->like(
        $src,
        qr/Clause CONN_SERVER_NETWORK=<network> not found in config file/,
        'install/conf_servers.pl still validates CONN_SERVER_NETWORK'
    );
};
