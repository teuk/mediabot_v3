#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Cwd qw(abs_path);
use File::Spec;

my $root = abs_path('.') || '.';

sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $cpan      = slurp('install/cpan_install.sh');
my $configure = slurp('configure');
my $wizard    = slurp('install/configure.pl');
my $legacy    = slurp('install/conf_servers.pl');
my $runtime   = slurp('Mediabot/DB.pm');
my $main      = slurp('Mediabot/Mediabot.pm');
my $readme    = slurp('README.md');
my $doc       = slurp('docs/CONFIGURE.md');

like(
    $cpan,
    qr/PERL_MODULES=\(.*?"DBI"\s*\n\s*"DBD::MariaDB"/s,
    'CPAN module list includes the MariaDB runtime driver after DBI',
);
like(
    $cpan,
    qr/for perl_module in strict warnings "\$\{PERL_MODULES\[@\]\}"/,
    'runtime-user verification covers the complete list including DBD::MariaDB',
);
like(
    $cpan,
    qr/perl -MDBD::MariaDB .*?command -v mariadb_config.*?command -v mysql_config/s,
    'CPAN installer checks Connector/C build metadata when the driver is absent',
);
like(
    $cpan,
    qr/Do not install libdbd-mariadb-perl as a replacement for the CPAN phase/,
    'CPAN failure guidance distinguishes native headers from packaged Perl modules',
);
unlike(
    $cpan,
    qr/\b(?:apt|apt-get|dpkg|dnf|yum)\s+(?:install|add|remove|purge)\b/,
    'CPAN installer never invokes a system package manager',
);

like(
    $configure,
    qr/^install_perl_dependencies\(\)\s*\{/m,
    'configure keeps the MariaDB build check inside the CPAN phase',
);
like(
    $configure,
    qr/perl -MDBD::MariaDB -e 'exit 0;'/,
    'configure checks whether the runtime driver already exists',
);
like(
    $configure,
    qr/command -v mariadb_config.*?command -v mysql_config/s,
    'configure accepts MariaDB or MySQL client build metadata',
);
like(
    $configure,
    qr/DBD::MariaDB must be built by CPAN/,
    'configure gives a precise CPAN-only driver error',
);

like(
    $wizard,
    qr/return 'MariaDB' if \$available\{MariaDB\}/,
    'IRC/database wizard selects the same driver as the runtime',
);
unlike(
    $wizard,
    qr/return 'mysql' if \$available\{mysql\}/,
    'wizard no longer succeeds with a driver the runtime does not use',
);
like(
    $wizard,
    qr/DBD::MariaDB is required by the Mediabot runtime/,
    'wizard failure explains the runtime contract',
);

like(
    $legacy,
    qr/DBI:MariaDB:database=\$dbname;host=\$tcp_host;port=\$dbport/,
    'legacy server configuration uses DBD::MariaDB too',
);
unlike(
    $legacy,
    qr/DBI:mysql:/,
    'legacy configuration no longer depends on DBD::mysql',
);

like($runtime, qr/DBI:MariaDB:/, 'primary DB helper uses DBD::MariaDB');
like($main, qr/DBI:MariaDB:/, 'legacy runtime DB path uses DBD::MariaDB');

my ($bootstrap) = $readme =~ /apt install -y \\\n(.*?)\n\nsystemctl enable --now mariadb/s;
ok(defined $bootstrap, 'README Debian bootstrap block is present');
if (defined $bootstrap) {
    like($bootstrap, qr/^\s*perl \\$/m, 'README installs the Perl interpreter/client bootstrap');
    like($bootstrap, qr/^\s*libmariadb-dev\s*$/m, 'README installs MariaDB native development headers');
    unlike($bootstrap, qr/libdbi-perl/, 'README bootstrap does not install DBI from Debian');
    unlike($bootstrap, qr/libdbd-mariadb-perl/, 'README bootstrap does not install DBD::MariaDB from Debian');
    unlike($bootstrap, qr/libdbd-mysql-perl/, 'README bootstrap does not install DBD::mysql from Debian');
}

like(
    $readme,
    qr/\.\/configure` installs\s+and verifies `DBI`, `DBD::MariaDB`.*?through CPAN/s,
    'README states that Perl database modules come from CPAN',
);
like(
    $doc,
    qr/runtime uses the `DBD::MariaDB` CPAN driver/,
    'configure guide documents the exact runtime driver',
);
like(
    $doc,
    qr/`libmariadb-dev` provides the required native client\s+headers/s,
    'configure guide documents the non-Perl native build dependency',
);
like(
    $doc,
    qr/Do not use Debian packages such as `libdbi-perl`.*?as substitutes/s,
    'configure guide rejects packaged Perl driver substitutes',
);

done_testing();
