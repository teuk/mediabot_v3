package Mediabot::User;

use strict;
use warnings;
use Carp;

=head1 NAME

Mediabot::User - Represents a user in the Mediabot system.

=head1 SYNOPSIS

  use Mediabot::User;

  my $user = Mediabot::User->new($user_row);
  $user->set_dbh($dbh);
  $user->load_level();
  $user->maybe_autologin($bot, $hostmask);

=head1 DESCRIPTION

This module encapsulates a user known to the bot. It provides accessors,
privilege-level management, and optional auto-login logic.

=cut

# Constructor
sub new {
    my ($class, $args) = @_;

    croak "Mediabot::User->new expects a hashref" unless ref($args) eq 'HASH';

    my $self = {
        id           => $args->{id_user},
        nickname     => $args->{nickname},
        password     => $args->{password},
        username     => $args->{username},
        hostmasks    => $args->{hostmasks},
        info1        => $args->{info1},
        info2        => $args->{info2},
        level_id     => $args->{id_user_level},
        auth         => $args->{auth},
        level        => undef,
        level_desc   => undef,
        dbh          => $args->{dbh},  # optional
    };

    bless $self, $class;
    return $self;
}

=head2 Accessors

=cut

sub id                { $_[0]->{id} }
sub nickname          { $_[0]->{nickname} }
sub username          { $_[0]->{username} }
sub password          { $_[0]->{password} }
sub info1             { $_[0]->{info1} }
sub info2             { $_[0]->{info2} }
sub level             { $_[0]->{level} }
sub level_description { $_[0]->{level_desc} }
sub is_authenticated  { $_[0]->{auth} ? 1 : 0 }
sub hostmasks         { $_[0]->{hostmasks} }

=head2 set_dbh($dbh)

Set or override the database handle for this user object.

=cut

sub set_dbh {
    my ($self, $dbh) = @_;
    $self->{dbh} = $dbh;
}

=head2 load_level([$dbh])

Loads the user's privilege level and description from the USER_LEVEL table.
Will use stored DBH if available.

=cut

sub load_level {
    my ($self, $dbh) = @_;
    $dbh //= $self->{dbh};
    return unless $dbh && defined $self->{level_id};

    my $sth = $dbh->prepare("SELECT * FROM USER_LEVEL WHERE id_user_level=?");
    if ($sth->execute($self->{level_id})) {
        if (my $ref = $sth->fetchrow_hashref) {
            $self->{level}      = $ref->{level};
            $self->{level_desc} = $ref->{description};
        }
    }
    $sth->finish;
}

=head2 maybe_autologin($bot, $matched_hostmask)

Try to log in the user automatically using config-based or DB-based flags.

=cut

# Auto-login helper: authenticate user if autologin flag is set OR if host cloak matches "<nickname>.users.undernet.org"
sub maybe_autologin {
    my ($first, @rest) = @_;

    # Supporte les deux styles d'appel:
    #  - $user->maybe_autologin($bot, $irc_nick, $prefix)
    #  - Mediabot::User::maybe_autologin($bot, $user, $irc_nick, $prefix)
    my ($bot, $user, $irc_nick, $prefix);
    if (ref($first) && ref($first) =~ /Mediabot::User/) {
        $user = $first;
        ($bot, $irc_nick, $prefix) = @rest;
    } else {
        ($bot, $user, $irc_nick, $prefix) = ($first, @rest);
    }

    return 0 unless $bot && $user;

    my $logger = $bot->{logger};
    my $dbh    = $bot->{dbh} // eval { $bot->{db}->dbh };

    # Déjà auth ?
    my $is_auth = eval { $user->is_authenticated ? 1 : 0 } // ($user->{auth} ? 1 : 0);
    return 0 if $is_auth;

    my $uid      = eval { $user->id }        // $user->{id_user};
    my $db_nick  = lc( eval { $user->nickname } // ($user->{nickname} // '') );

    # S'assurer qu'on a bien username; sinon on le lit en DB
    my $username = eval { $user->username } // $user->{username};
    if ((!defined $username || $username eq '') && $dbh && $uid) {
        my $row = eval { $dbh->selectrow_hashref('SELECT username, auth FROM USER WHERE id_user=?', undef, $uid) };
        if ($row) {
            $username     = $row->{username};
            $user->{username} = $username;
            $user->{auth} = $row->{auth} if defined $row->{auth};
        }
    }

    # Host IRC (si fourni)
    my $host = '';
    if (defined $prefix && $prefix ne '') {
        ($host) = $prefix =~ /@(.+)$/;
        $host = lc($host // '');
    }

    my $should_auto = 0;
    my $reason      = '';

    # A) Autologin explicite en DB
    if (defined $username && $username eq '#AUTOLOGIN#') {
        $should_auto = 1;
        $reason      = 'flag';
    }
    # B) Cloak Undernet: "<nickname>.users.undernet.org"
    elsif ($host =~ /(^|\.)users\.undernet\.org$/) {
        my ($leftmost) = split(/\./, $host, 2);
        if (defined $leftmost && $leftmost ne '' && $db_nick ne '' && lc($leftmost) eq $db_nick) {
            $should_auto = 1;
            $reason      = 'cloak';
        }
    }

    return 0 unless $should_auto;

    # Persistance DB
    if ($dbh && $uid) {
        eval {
            $dbh->do('UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?', undef, $uid);
            1;
        } or do {
            $logger->log(1, "[AUTOLOGIN] DB update failed for uid=$uid: $@");
        };
    } else {
        $logger->log(1, "[AUTOLOGIN] No DB handle; cannot persist auth state for uid=$uid");
    }

    # Caches mémoire
    eval {
        $bot->{auth}->{logged_in}{$uid} = 1 if exists $bot->{auth}->{logged_in};

        my $session_key = (defined $irc_nick && $irc_nick ne '') ? lc $irc_nick : lc($db_nick // '');
        if ($session_key ne '' && exists $bot->{auth}->{sessions}) {
            $bot->{auth}->{sessions}{$session_key} = { id_user => $uid, auth => 1 };
        }

        $user->{auth} = 1; # aligne l'objet
        1;
    };

    $logger->log(3, sprintf("[AUTOLOGIN] uid=%s nick=%s via=%s -> auth=1", $uid//'?', $db_nick||'?', $reason));
    return 1;
}








# Handle method for compatibility with other parts of the bot
sub handle {
    my ($self) = @_;
    return $self->{nickname};  # or put a field like 'handle' if needed
}


=head1 AUTHOR

Christophe <teuk@teuk.org>

=cut

=head2 create($dbh, \%params, [$logger])

Create a new user in the USER table.
Params hash must contain:
  nickname  => string (required)
  hostmasks => string (required)
  level     => string or numeric level (optional, default 'User')
  password  => string (optional)
  info1/2   => string (optional)

Returns: Mediabot::User object on success, undef on failure.

=cut

sub create {
    my ($class, $dbh, $params, $logger) = @_;

    croak "create() requires DB handle" unless $dbh;
    croak "create() requires a hashref of params" unless ref($params) eq 'HASH';

    my $nickname  = $params->{nickname}  // '';
    my $hostmasks = $params->{hostmasks} // '';
    my $level     = $params->{level}     // 'User';
    my $password  = $params->{password};
    my $info1     = $params->{info1};
    my $info2     = $params->{info2};

    unless ($nickname && $hostmasks) {
        carp "Nickname and hostmask are required";
        return undef;
    }

    $logger->log(3, "🆕 Creating user: nickname=$nickname, hostmasks=$hostmasks, level=$level") if $logger;

    # Determine level ID
    my $level_id;
    if ($level =~ /^\d+$/) {
        $level_id = $level;
    } else {
        my $sth = $dbh->prepare("SELECT id_user_level FROM USER_LEVEL WHERE description = ?");
        $sth->execute($level);
        if (my $ref = $sth->fetchrow_hashref) {
            $level_id = $ref->{id_user_level};
        }
        $sth->finish;
    }
    unless ($level_id) {
        carp "Invalid level: $level";
        $logger->log(1, "❌ Invalid level: $level") if $logger;
        return undef;
    }

    # Check if user exists
    my $sth_check = $dbh->prepare("SELECT id_user FROM USER WHERE nickname = ?");
    $sth_check->execute($nickname);
    if (my $ref = $sth_check->fetchrow_hashref) {
        carp "User $nickname already exists (id_user: $ref->{id_user})";
        $logger->log(1, "❌ User $nickname already exists (id_user: $ref->{id_user})") if $logger;
        return undef;
    }
    $sth_check->finish;

    # Insert new user
    my $sth_insert = $dbh->prepare("
        INSERT INTO USER (hostmasks, nickname, password, username, id_user_level, info1, info2, auth)
        VALUES (?, ?, ?, NULL, ?, ?, ?, 0)
    ");
    my $pass_db = defined $password ? $password : undef;
    my $ok = $sth_insert->execute($hostmasks, $nickname, $pass_db, $level_id, $info1, $info2);
    $sth_insert->finish;

    unless ($ok) {
        carp "Failed to insert user $nickname";
        $logger->log(1, "❌ Failed to insert user $nickname") if $logger;
        return undef;
    }

    # Fetch the newly created user
    my $sth_get = $dbh->prepare("SELECT * FROM USER WHERE nickname = ?");
    $sth_get->execute($nickname);
    my $row = $sth_get->fetchrow_hashref;
    $sth_get->finish;

    return undef unless $row;
    $row->{dbh} = $dbh;

    my $user_obj = $class->new($row);
    $user_obj->load_level($dbh);

    $logger->log(0, "✅ User created: $nickname (id_user=" . $user_obj->id . ", level=" . $user_obj->level_description . ")") if $logger;

    return $user_obj;
}


1;