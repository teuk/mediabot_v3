package Mediabot::DB;

use strict;
use warnings;
use DBI;

sub new {
    my ($class, $conf, $logger) = @_;
    my $self = {
        conf   => $conf,
        logger => $logger,
        dbh    => undef,
    };

    bless $self, $class;

    # Read database configuration from the provided config object
    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME') || '';
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') || 'localhost';
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER') || '';
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS') || '';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') || 3306;

    unless ($dbname && $dbuser) {
        $logger->log(0, "❌ Missing DB configuration: DDBNAME or DBUSER is undefined.");
        $logger->log(0, "Check your [mysql] section in mediabot.conf");
        exit 1;
    }

    $logger->log(1, "Connecting to DB: $dbname at $dbhost:$dbport");

    my $dsn = "DBI:mysql:database=$dbname;host=$dbhost;port=$dbport";

    my $dbh = DBI->connect(
        $dsn, $dbuser, $dbpass,
        {
            RaiseError           => 0,
            PrintError           => 0,
            mysql_enable_utf8mb4 => 1,
            mysql_auto_reconnect => 1,
        }
    );

    if (!defined $dbh) {
        $logger->log(0, "❌ DBI connect failed: " . $DBI::errstr);
        $logger->log(0, "Check your credentials in mediabot.conf");
        $logger->log(0, "Aborting startup.");
        exit 1;
    }

    # Set character set to utf8mb4
    foreach my $sql (
        "SET NAMES 'utf8mb4'",
        "SET CHARACTER SET utf8mb4'",
        "SET COLLATION_CONNECTION = 'utf8mb4_unicode_ci'"
    ) {
        my $sth = $dbh->prepare($sql);
        unless ($sth->execute) {
            $logger->log(1, "SQL error during init: $DBI::errstr (query: $sql)");
        }
        $sth->finish;
    }

    # Optional: print current DB collation for verification
    my $sth = $dbh->prepare("SHOW VARIABLES LIKE 'collation_connection'");
    if ($sth->execute) {
        my ($name, $value) = $sth->fetchrow_array;
        $logger->log(3, "⚙️  DB collation in use: $value");
    }
    $sth->finish;

    $self->{dbh} = $dbh;
    $logger->log(3, "✅ DBI connection successful");

    return $self;
}

sub _connect {
    my ($self) = @_;
    my $conf   = $self->{conf};
    my $logger = $self->{logger};

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME');
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') || 'localhost';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') || 3306;
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER');
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS');

    my $dsn = "DBI:mysql:database=$dbname;host=$dbhost;port=$dbport";
    $logger->log(1, "Connecting to DB: $dbname at $dbhost:$dbport");

    my $dbh = DBI->connect($dsn, $dbuser, $dbpass, {
        RaiseError           => 0,
        PrintError           => 0,
        mysql_auto_reconnect => 1,
        mysql_enable_utf8mb4 => 1,
    });

    unless ($dbh) {
        $logger->log(0, "DBI connect failed: $DBI::errstr");
        return undef;
    }

    foreach my $sql (
        "SET NAMES 'utf8mb4'",
        "SET CHARACTER SET utf8mb4'",
        "SET COLLATION_CONNECTION = 'utf8mb4_unicode_ci'"
    ) {
        my $sth = $dbh->prepare($sql);
        unless ($sth->execute) {
            $logger->log(1, "SQL error during init: $DBI::errstr (query: $sql)");
        }
        $sth->finish;
    }

    $self->{dbh} = $dbh;
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh};
}

1;