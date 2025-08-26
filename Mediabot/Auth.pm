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

# Vérifie le mot de passe :
# 1) essai "normal" (UTF-8) : PASSWORD(?)
# 2) essai compat "legacy" (latin1) : PASSWORD(CONVERT(? USING latin1))
# Si le chemin legacy passe, on réécrit le hash en UTF-8 et on pose auth=1.
sub verify_credentials {
    my ($self, $user_id, $nickname, $password) = @_;
    my $dbh    = $self->{dbh};
    my $logger = $self->{logger};

    # --- essai UTF-8
    my $sql_u = "SELECT id_user FROM USER WHERE id_user=? AND nickname=? AND password=PASSWORD(?)";
    my $sth_u = $dbh->prepare($sql_u);
    unless ($sth_u && $sth_u->execute($user_id, $nickname, $password)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_u");
        return 0;
    }
    my $row_u = $sth_u->fetchrow_arrayref;
    $sth_u->finish;

    if ($row_u) {
        my $sql_ok = "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?";
        my $sth_ok = $dbh->prepare($sql_ok);
        unless ($sth_ok && $sth_ok->execute($user_id)) {
            $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_ok");
            return 0;
        }
        $self->{logged_in}{$user_id} = 1;
        return 1;
    }

    # --- essai legacy latin1
    my $sql_l = "SELECT id_user FROM USER WHERE id_user=? AND nickname=? AND password=PASSWORD(CONVERT(? USING latin1))";
    my $sth_l = $dbh->prepare($sql_l);
    unless ($sth_l && $sth_l->execute($user_id, $nickname, $password)) {
        $logger->log(1, "verify_credentials() SQL Error: $DBI::errstr | Query: $sql_l");
        return 0;
    }
    my $row_l = $sth_l->fetchrow_arrayref;
    $sth_l->finish;

    unless ($row_l) {
        # aucun des deux chemins ne matche
        return 0;
    }

    # Chemin legacy OK -> upgrade du hash en UTF-8
    my $sql_up = "UPDATE USER SET password=PASSWORD(?), auth=1, last_login=NOW() WHERE id_user=?";
    my $sth_up = $dbh->prepare($sql_up);
    if (!$sth_up || !$sth_up->execute($password, $user_id)) {
        $logger->log(1, "verify_credentials() legacy upgrade failed: $DBI::errstr | Query: $sql_up");
        # Même si l’upgrade échoue, on pose auth=1 pour la session courante
        my $sql_auth = "UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?";
        my $sth_a = $dbh->prepare($sql_auth);
        $sth_a->execute($user_id) if $sth_a;
    }
    $self->{logged_in}{$user_id} = 1;
    return 1;
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
