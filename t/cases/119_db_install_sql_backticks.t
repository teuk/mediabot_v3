# t/cases/119_db_install_sql_backticks.t
# =============================================================================
# Regression checks for install/db_install.sh SQL identifier quoting.
#
# Bash interprets raw backticks inside double-quoted strings as command
# substitution. SQL identifier backticks must therefore be escaped as \`.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_db_install_backticks {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_db_install_backticks(
        File::Spec->catfile('.', 'install', 'db_install.sh')
    );

    $assert->like(
        $src,
        qr/printf "DROP DATABASE IF EXISTS \\\`%s\\\`;\\n" "\$MYSQL_DB"/,
        'DROP DATABASE printf escapes SQL backticks for Bash'
    );

    $assert->like(
        $src,
        qr/printf "CREATE DATABASE \\\`%s\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\\n" "\$MYSQL_DB"/,
        'CREATE DATABASE printf escapes SQL backticks for Bash'
    );

    $assert->unlike(
        $src,
        qr/printf "DROP DATABASE IF EXISTS `%s`;\\n"/,
        'DROP DATABASE printf does not contain raw Bash backticks'
    );

    $assert->unlike(
        $src,
        qr/printf "CREATE DATABASE `%s` CHARACTER SET/,
        'CREATE DATABASE printf does not contain raw Bash backticks'
    );
};
