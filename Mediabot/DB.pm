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
    $self->_connect;
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
        RaiseError         => 0,
        PrintError         => 0,
        mysql_auto_reconnect => 1,
    });

    unless ($dbh) {
        $logger->log(0, "DBI connect failed: $DBI::errstr");
        return undef;
    }

    foreach my $sql (
        "SET NAMES 'utf8'",
        "SET CHARACTER SET utf8",
        "SET COLLATION_CONNECTION = 'utf8_general_ci'"
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
