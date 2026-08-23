# t/cases/899_mb692_dbi_socket_driver.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $script = File::Spec->catfile(
    $Bin, '..', '..', 'tools', 'check_schema_drift.pl'
);

{
    package MB899::DBH;
    sub do { return 1 }
}

return sub {
    my ($assert) = @_;

    open my $fh, '<', $script or do {
        $assert->ok(0, "cannot open $script: $!");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;

    my @subs = qw(defined_non_empty connect_db);
    my $loaded = 0;

    for my $name (@subs) {
        if ($code =~ /(sub \Q$name\E.*?^}\n)/sm) {
            my $wrapped = "package MB899::Harness;\n" . $1;
            eval $wrapped;
            if ($@) {
                $assert->ok(0, "load $name: $@");
                return;
            }
            $loaded++;
        }
    }

    $assert->is(
        $loaded,
        scalar(@subs),
        'mb692-899: loaded DB socket connection helpers',
    );

    no warnings qw(redefine once);

    local *MB899::Harness::resolve_dbi_driver = sub { return $_[0] };

    my @seen;
    local *DBI::connect = sub {
        my ($class, $dsn, $user, $pass, $attrs) = @_;
        push @seen, $dsn;
        return bless {}, 'MB899::DBH';
    };

    my %common = (
        db      => 'ci_socket',
        host    => 'localhost',
        port    => 3306,
        socket  => '/run/mysqld/mysqld.sock',
        user    => 'root',
        pass    => '',
        charset => '',
    );

    my %maria = (%common, driver => 'MariaDB');
    MB899::Harness::connect_db(\%maria);

    $assert->is(
        $seen[-1],
        'DBI:MariaDB:database=ci_socket;mariadb_socket=/run/mysqld/mysqld.sock',
        'mb692-899: DBD::MariaDB receives mariadb_socket DSN attribute',
    );

    $assert->unlike(
        $seen[-1],
        qr/mysql_socket=/,
        'mb692-899: MariaDB DSN never receives mysql_socket',
    );

    my %mysql = (%common, driver => 'mysql');
    MB899::Harness::connect_db(\%mysql);

    $assert->is(
        $seen[-1],
        'DBI:mysql:database=ci_socket;mysql_socket=/run/mysqld/mysqld.sock',
        'mb692-899: DBD::mysql receives mysql_socket DSN attribute',
    );

    $assert->unlike(
        $seen[-1],
        qr/mariadb_socket=/,
        'mb692-899: mysql DSN never receives mariadb_socket',
    );
};
