# t/cases/125_db_install_user_verify_rc.t
# =============================================================================
# Regression checks for install/db_install.sh database user verification.
#
# The script must not use:
#   if ! command; then ok_failed $?
#
# because $? can refer to the inverted shell status, not the command failure
# code we actually want to report. Capture the mysql return code explicitly.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_db_install_verify_rc {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_db_install_verify_rc(
        File::Spec->catfile('.', 'install', 'db_install.sh')
    );

    $assert->unlike(
        $src,
        qr/if\s+!\s+echo\s+"SELECT 1;"\s*\|\s*mysql\s+\$\{USER_MYSQL_PARAMS\}\s+"\$\{MYSQL_DB\}"/,
        'db_install.sh does not use inverted ! mysql verification'
    );

    $assert->like(
        $src,
        qr/echo\s+"SELECT 1;"\s*\|\s*mysql\s+\$\{USER_MYSQL_PARAMS\}\s+"\$\{MYSQL_DB\}"\s*\nverify_rc=\$\?/,
        'db_install.sh captures mysql verification return code explicitly'
    );

    $assert->like(
        $src,
        qr/if \[ "\$verify_rc" -ne 0 \]; then/,
        'db_install.sh checks the captured verify_rc value'
    );

    $assert->like(
        $src,
        qr/User \$\{MYSQL_DB_USER\} failed to connect/,
        'db_install.sh reports user verification failure clearly'
    );

    $assert->like(
        $src,
        qr/DROP USER IF EXISTS \$\{MYSQL_DB_USER_SQL\}\@\$\{AUTH_HOST_SQL\}/,
        'db_install.sh rolls back with validated SQL literals and IF EXISTS'
    );

    $assert->unlike(
        $src,
        qr/DROP USER '\$\{MYSQL_DB_USER\}'\@'\$\{AUTH_HOST\}'/,
        'db_install.sh no longer interpolates raw account values in rollback SQL'
    );

    $assert->like(
        $src,
        qr/exit "\$verify_rc"/,
        'db_install.sh exits with the captured mysql verification code'
    );

    $assert->like(
        $src,
        qr/ok_failed 0/,
        'db_install.sh still reports success when verification passes'
    );
};
