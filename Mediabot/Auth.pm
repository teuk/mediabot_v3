package Mediabot::Auth;

use strict;
use warnings;
use DBI ();           # pour $DBI::errstr
use POSIX qw(strftime);

sub new {
    my ($class, %args) = @_;
    my $self = {
        dbh       => $args{dbh},
        logger    => $args{logger},
        sessions  => {},    # cache sessions par nick
        logged_in => {},    # cache auth par id_user
    };
    bless $self, $class;
    return $self;
}

# Verify credentials for a user identified by id_user.
# Compatible signatures:
#   verify_credentials($id_user, $password)
#   verify_credentials($id_user, $ignored_username, $password)
sub verify_credentials {
    my ($self, @args) = @_;
    my $dbh    = $self->{dbh};
    my $logger = $self->{logger};

    my ($id_user, $password);
    if (@args == 2) {
        ($id_user, $password) = @args;
    } elsif (@args == 3) {
        ($id_user, undef, $password) = @args;  # ignore typed username
    } else {
        $logger->log(1, "verify_credentials(): invalid args (@args)");
        return 0;
    }

    # 1) Fetch stored hash by id_user
    my $sth = $dbh->prepare('SELECT password, nickname FROM USER WHERE id_user=?');
    unless ($sth && $sth->execute($id_user)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | SELECT password FROM USER WHERE id_user=?");
        return 0;
    }
    my ($stored_hash, $db_nick) = $sth->fetchrow_array;
    $sth->finish;

    return 0 unless defined $stored_hash && $stored_hash ne "";

    # 2) Compute candidate with MariaDB PASSWORD()
    my ($calc) = eval { $dbh->selectrow_array('SELECT PASSWORD(?)', undef, $password) };
    unless (defined $calc) {
        $logger->log(1, "verify_credentials() failed to compute PASSWORD(): $DBI::errstr");
        return 0;
    }

    # 3) Compare and set auth if OK
    if ($stored_hash eq $calc) {
        my $rows = $dbh->do('UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?', undef, $id_user);
        $self->{logged_in}{$id_user} = 1;
        $self->{sessions}{lc($db_nick // '')} = { id_user => $id_user, auth => 1 } if defined $db_nick;
        return 1;
    }

    return 0;
}




# Met à jour l'état d'auth en DB et en cache
sub set_logged_in {
    my ($self, $id_user, $state) = @_;
    $state = $state ? 1 : 0;
    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare('UPDATE USER SET auth=? WHERE id_user=?');
    $sth->execute($state, $id_user) if $sth;
    $self->{logged_in}{$id_user} = $state;
}

# Vérifie l'état d'auth par id_user (cache + DB)
sub is_logged_in_id {
    my ($self, $id_user) = @_;
    return 1 if $self->{logged_in}{$id_user};
    my $dbh = $self->{dbh};
    my ($auth) = $dbh->selectrow_array('SELECT auth FROM USER WHERE id_user=?', undef, $id_user);
    $self->{logged_in}{$id_user} = $auth ? 1 : 0;
    return $self->{logged_in}{$id_user};
}

# Associe l'utilisateur à une session (nick courant)
sub set_session_user {
    my ($self, $nick, $u) = @_;
    return unless defined $nick && ref($u) eq 'HASH';
    $self->{sessions}{lc $nick} = { %$u };  # copie légère
}

sub get_session_user {
    my ($self, $nick) = @_;
    return $self->{sessions}{lc $nick};
}

sub update_last_login {
    my ($self, $id_user) = @_;
    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare('UPDATE USER SET last_login=NOW() WHERE id_user=?');
    $sth->execute($id_user) if $sth;
}

1;
