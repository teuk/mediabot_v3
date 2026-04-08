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

    my $sth = $dbh->prepare("SELECT level, description FROM USER_LEVEL WHERE id_user_level = ?");
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

    # Supported call styles:
    #   $user->maybe_autologin($bot, $irc_nick, $prefix)
    #   Mediabot::User::maybe_autologin($bot, $user, $irc_nick, $prefix)
    my ($bot, $user, $irc_nick, $prefix);
    if (ref($first) && ref($first) =~ /Mediabot::User/) {
        $user = $first;
        ($bot, $irc_nick, $prefix) = @rest;
    } else {
        ($bot, $user, $irc_nick, $prefix) = ($first, @rest);
    }

    return 0 unless $bot && $user;

    my $logger = $bot->{logger};

    require Mediabot::Auth;
    $bot->{auth} ||= Mediabot::Auth->new(
        dbh    => $bot->{dbh},
        logger => $bot->{logger},
    );

    my ($did, $why) = $bot->{auth}->maybe_autologin($user, ($prefix // ''));

    if ($did) {
        $user->{auth} = 1;

        my $session_nick = defined($irc_nick) && $irc_nick ne ''
            ? $irc_nick
            : (eval { $user->nickname } // $user->{nickname} // '');

        eval {
            $bot->_ensure_logged_in_state($user, $session_nick, ($prefix // ''));
            1;
        };
    }

    my $uid  = eval { $user->id }       // $user->{id};
    my $nick = eval { $user->nickname } // $user->{nickname} // '';

    $logger->log(
        3,
        sprintf(
            "[AUTOLOGIN] uid=%s nick=%s result=%s reason=%s",
            (defined $uid  ? $uid  : 'undef'),
            (defined $nick ? $nick : ''),
            ($did ? 1 : 0),
            (defined $why ? $why : '')
        )
    ) if $logger;

    return $did ? 1 : 0;
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

    $logger->log(1, "🆕 Creating user: nickname=$nickname, level=$level") if $logger;

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

    # Insert new user (no longer stores hostmasks in USER — they go in USER_HOSTMASK)
    my $sth_insert = $dbh->prepare("
        INSERT INTO USER (nickname, password, username, id_user_level, info1, info2, auth)
        VALUES (?, ?, NULL, ?, ?, ?, 0)
    ");
    my $pass_db = defined $password ? $password : undef;
    my $ok = $sth_insert->execute($nickname, $pass_db, $level_id, $info1, $info2);

    unless ($ok) {
        $sth_insert->finish;
        carp "Failed to insert user $nickname";
        $logger->log(1, "❌ Failed to insert user $nickname") if $logger;
        return undef;
    }

    # Capture id immediately before any other statement
    my $new_id = $sth_insert->{ Database }->last_insert_id(undef, undef, undef, undef);
    $sth_insert->finish;

    # Store hostmask in USER_HOSTMASK
    if ($new_id && $hostmasks) {
        for my $mask (grep { length } split /,/, $hostmasks) {
            $mask =~ s/^\s+|\s+$//g;
            my $hm = $dbh->prepare("INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)");
            $hm->execute($new_id, $mask);
            $hm->finish;
        }
    }

    # Fetch the newly created user
    my $sth_get = $dbh->prepare("SELECT id_user, nickname, password, username, id_user_level, auth, info1, info2 FROM USER WHERE nickname = ?");
    $sth_get->execute($nickname);
    my $row = $sth_get->fetchrow_hashref;
    $sth_get->finish;

    return undef unless $row;
    $row->{dbh} = $dbh;

    my $user_obj = $class->new($row);
    $user_obj->load_level($dbh);

    $logger->log(1, "✅ User created: $nickname (id_user=" . $user_obj->id . ", level=" . $user_obj->level_description . ")") if $logger;

    return $user_obj;
}

# Return true if user's level is >= required level
# Hierarchy (lower is stronger):
# Owner(0) > Master(1) > Administrator(2) > User(3)
sub has_level {
    my ($self, $required) = @_;

    return 0 unless defined $required && $required ne '';

    # Current user level (string)
    my $current = eval { $self->level_description }
               || eval { $self->level }
               || '';

    return 0 unless $current ne '';

    my %level_rank = (
        owner          => 0,
        master         => 1,
        administrator  => 2,
        user           => 3,
    );

    my $cur_lc = lc($current);
    my $req_lc = lc($required);

    # Safe deny if unknown level
    return 0
        unless exists $level_rank{$cur_lc}
            && exists $level_rank{$req_lc};

    # Lower or equal rank == sufficient privilege
    return ($level_rank{$cur_lc} <= $level_rank{$req_lc}) ? 1 : 0;
}

1;