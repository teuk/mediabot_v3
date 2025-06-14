package Mediabot::Auth;

use strict;
use warnings;
use POSIX qw(strftime);

sub new {
    my ($class, %args) = @_;
    my $self = {
        dbh    => $args{dbh},
        logger => $args{logger},
    };
    bless $self, $class;
    return $self;
}

sub verify_credentials {
    my ($self, $user_id, $nickname, $password) = @_;

    my $dbh    = $self->{dbh};
    my $logger = $self->{logger};

    my $sql_check = "SELECT * FROM USER WHERE id_user=? AND nickname=? AND password=PASSWORD(?)";
    my $sth = $dbh->prepare($sql_check);

    unless ($sth->execute($user_id, $nickname, $password)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_check");
        return 0;
    }

    my $row = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($row) {
        return 0;
    }

    # Update auth = 1
    my $sql_auth = "UPDATE USER SET auth=1 WHERE id_user=?";
    my $sth2 = $dbh->prepare($sql_auth);
    unless ($sth2->execute($user_id)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_auth");
        return 0;
    }

    # Update last_login
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $sql_login = "UPDATE USER SET last_login=? WHERE id_user=?";
    my $sth3 = $dbh->prepare($sql_login);
    unless ($sth3->execute($timestamp, $user_id)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_login");
        # pas de return ici, c’est pas critique
    }

    return 1;
}

1;