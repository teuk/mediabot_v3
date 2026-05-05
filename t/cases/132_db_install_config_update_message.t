# t/cases/132_db_install_config_update_message.t
# =============================================================================
# Regression checks for install/db_install.sh config update reporting.
#
# db_install.sh must not claim that a configuration file was updated when no
# -c config file was provided, or when the requested file is missing/unwritable.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_db_install_config_update {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_db_install_config_update(
        File::Spec->catfile('.', 'install', 'db_install.sh')
    );

    $assert->like(
        $src,
        qr/if \[\[ -n "\$\{CONFIG_FILE:-\}" \]\]; then/,
        'db_install.sh only enters config update block when CONFIG_FILE is set'
    );

    $assert->unlike(
        $src,
        qr/if \[\[ -n "\$\{CONFIG_FILE:-\}" && -w "\$CONFIG_FILE" \]\]; then/,
        'db_install.sh no longer silently skips missing/unwritable config files'
    );

    $assert->like(
        $src,
        qr/if \[\[ ! -f "\$CONFIG_FILE" \]\]; then/,
        'db_install.sh checks that requested config file exists'
    );

    $assert->like(
        $src,
        qr/Configuration file \$CONFIG_FILE does not exist\./,
        'db_install.sh reports missing requested config file'
    );

    $assert->like(
        $src,
        qr/if \[\[ ! -w "\$CONFIG_FILE" \]\]; then/,
        'db_install.sh checks that requested config file is writable'
    );

    $assert->like(
        $src,
        qr/Configuration file \$CONFIG_FILE is not writable\./,
        'db_install.sh reports unwritable requested config file'
    );

    $assert->like(
        $src,
        qr/messageln "Configuration file \$CONFIG_FILE updated\."/,
        'db_install.sh reports config update in the update path'
    );

    $assert->like(
        $src,
        qr/messageln "No configuration file requested; skipping config update\."/,
        'db_install.sh reports skipped config update when no config file is requested'
    );

    $assert->like(
        $src,
        qr/CHARSET_MODE=utf8mb4/,
        'db_install.sh still writes CHARSET_MODE=utf8mb4 into [mysql]'
    );
};
