# t/cases/887_mb685_debian13_fresh_database_gate.t
# =============================================================================
# MB685 — Debian 13 CI must exercise the real fresh MariaDB installer and then
# prove the generated application credentials against the strict drift checker.
# The config-backed installer path must not print its generated DB password.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_887 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $workflow = _slurp_887(File::Spec->catfile('.', '.github', 'workflows', 'debian13.yml'));
    my $dbinstall= _slurp_887(File::Spec->catfile('.', 'install', 'db_install.sh'));
    my $readme   = _slurp_887(File::Spec->catfile('.', 'README.md'));
    my $cfgdoc   = _slurp_887(File::Spec->catfile('.', 'docs', 'CONFIGURE.md'));

    $assert->like(
        $workflow,
        qr/name:\s*Exercise fresh MariaDB database installation and strict drift validation/,
        'Debian 13 workflow contains a dedicated live fresh-database step',
    );
    $assert->like(
        $workflow,
        qr/mariadbd\s+\\.*?--user=mysql.*?--datadir=\/var\/lib\/mysql.*?--socket=\/run\/mysqld\/mysqld\.sock/s,
        'workflow starts the MariaDB server from the Debian package',
    );
    $assert->like(
        $workflow,
        qr/mysqladmin\s+\\.*?--protocol=socket.*?--socket=\/run\/mysqld\/mysqld\.sock.*?-uroot ping --silent/s,
        'workflow waits for a real MariaDB socket ping',
    );
    $assert->like(
        $workflow,
        qr/for _ in \$\(seq 1 60\).*?kill -0 "\$DB_PID".*?sleep 1/s,
        'MariaDB readiness wait is bounded and detects premature server death',
    );
    $assert->like(
        $workflow,
        qr/trap cleanup_db EXIT/,
        'workflow cleans up the MariaDB child process',
    );

    $assert->like(
        $workflow,
        qr/printf '\\n\\n\\n\\n\\n\\n'.*?install\/db_install\.sh\s+\\\s*-c \/home\/mediabot\/mediabot_v3\/mediabot\.conf/s,
        'CI drives the real db_install.sh fresh path with six safe default answers and a config file',
    );
    $assert->like(
        $workflow,
        qr/stat -c %U:%G \/home\/mediabot\/mediabot_v3\/mediabot\.conf.*?mediabot:mediabot/s,
        'root-side DB installer must preserve Mediabot config ownership',
    );
    $assert->like(
        $workflow,
        qr/stat -c %a \/home\/mediabot\/mediabot_v3\/mediabot\.conf.*?600/s,
        'root-side DB installer must preserve private config mode',
    );
    $assert->like(
        $workflow,
        qr/--get mysql\.MAIN_PROG_DDBNAME\)" = mediabot/,
        'CI verifies the generated database name through the config helper',
    );
    $assert->like(
        $workflow,
        qr/--get mysql\.MAIN_PROG_DBUSER\)" = mediabot/,
        'CI verifies the generated application DB user through the config helper',
    );
    $assert->like(
        $workflow,
        qr/test -n "\$\(perl install\/configure_config\.pl --config mediabot\.conf --get mysql\.MAIN_PROG_DBPASS\)"/,
        'CI verifies a DB password exists without printing it',
    );
    $assert->like(
        $workflow,
        qr/check_schema_drift\.pl\s+\\.*?--conf=mediabot\.conf\s+\\.*?--strict\s+\\.*?--types\s+\\.*?--indexes/s,
        'fresh database is validated through the complete strict schema/type/index contract',
    );
    $assert->like(
        $workflow,
        qr/sudo -u mediabot env.*?check_schema_drift\.pl/s,
        'strict drift validation runs through the non-root application identity',
    );
    $assert->like(
        $workflow,
        qr/-f '\^\(.*?886_\|887_.*?\)'/,
        'Debian 13 workflow includes both MB684 and MB685 contracts',
    );

    $assert->unlike(
        $workflow,
        qr/set -x/,
        'workflow never enables shell tracing around generated database credentials',
    );
    $assert->unlike(
        $workflow,
        qr/cat\s+.*mediabot\.conf/,
        'workflow never dumps the private generated configuration',
    );
    $assert->unlike(
        $workflow,
        qr/check_schema_drift\.pl.*?--pass(?:=|\s)/s,
        'database password is not placed on the drift-checker command line',
    );

    $assert->like(
        $dbinstall,
        qr/if \[\[ -n "\$\{CONFIG_FILE:-\}" \]\]; then\s+read -rsp .*?\[generated and stored in config\]/s,
        'config-backed db_install prompt hides the generated password value',
    );
    $assert->unlike(
        $dbinstall,
        qr/if \[\[ -n "\$\{CONFIG_FILE:-\}" \]\]; then\s*\n\s*read -rsp "[^"\n]*\$\{DEFAULT_DB_PASS\}/,
        'config-backed db_install prompt does not interpolate the generated secret',
    );
    $assert->like(
        $dbinstall,
        qr/else\s+read -rsp .*?\[\$\{DEFAULT_DB_PASS\}\]/s,
        'standalone installer retains the historical visible default for compatibility',
    );
    $assert->like(
        $dbinstall,
        qr/MYSQL_DB_PASS=\$\{MYSQL_DB_PASS:-\$DEFAULT_DB_PASS\}/,
        'blank input still selects the generated password',
    );

    $assert->like(
        $readme,
        qr/starts the Debian 13 MariaDB server.*?install\/db_install\.sh -c .*?check_schema_drift\.pl --strict --types --indexes/s,
        'README now documents the live fresh-database CI proof',
    );
    $assert->like(
        $readme,
        qr/Live systemd deployment and IRC\s+connectivity remain end-to-end runtime checks/s,
        'README keeps systemd and IRC outside the container-CI claim',
    );

    $assert->like(
        $cfgdoc,
        qr/real fresh-database installer.*?install\/db_install\.sh -c \/home\/mediabot\/mediabot_v3\/mediabot\.conf/s,
        'configure guide documents the real db_install path exercised by CI',
    );
    $assert->like(
        $cfgdoc,
        qr/generated database password is not printed when `db_install\.sh`\s+is called with `-c`/s,
        'configure guide documents config-backed password non-disclosure',
    );
    $assert->like(
        $cfgdoc,
        qr/does \*\*not\*\* claim to replace live systemd or\s+IRC end-to-end validation/s,
        'configure guide states the remaining integration boundary',
    );
};
