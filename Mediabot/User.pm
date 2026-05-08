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


sub _log {
    my ($logger, $level, $msg) = @_;
    $logger->log($level, $msg) if $logger;
}


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

    return 0 unless $dbh && defined $self->{level_id};

    my $sql = "SELECT level, description FROM USER_LEVEL WHERE id_user_level = ?";
    my $sth = $dbh->prepare($sql);

    unless ($sth) {
        carp "load_level() SQL prepare error: $DBI::errstr";
        return 0;
    }

    unless ($sth->execute($self->{level_id})) {
        carp "load_level() SQL execute error: $DBI::errstr";
        $sth->finish;
        return 0;
    }

    my $loaded = 0;

    if (my $ref = $sth->fetchrow_hashref) {
        $self->{level}      = $ref->{level};
        $self->{level_desc} = $ref->{description};
        $loaded = 1;
    }

    $sth->finish;
    return $loaded;
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
        bot    => $bot,          # needed for noticeConsoleChan
        conf   => $bot->{conf},  # A3: consistency with LoginCommands::init_auth
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

    _log($logger, 1, " Creating user: nickname=$nickname, level=$level");

    # Determine level ID.
    my $level_id;
    if ($level =~ /^\d+$/) {
        $level_id = $level;
    }
    else {
        my $sql_level = "SELECT id_user_level FROM USER_LEVEL WHERE description = ?";
        my $sth = $dbh->prepare($sql_level);

        unless ($sth) {
            carp "create() level SQL prepare error: $DBI::errstr";
            _log($logger, 1, " create() level SQL prepare error: $DBI::errstr Query: $sql_level");
            return undef;
        }

        unless ($sth->execute($level)) {
            carp "create() level SQL execute error: $DBI::errstr";
            _log($logger, 1, " create() level SQL execute error: $DBI::errstr Query: $sql_level");
            $sth->finish;
            return undef;
        }

        if (my $ref = $sth->fetchrow_hashref) {
            $level_id = $ref->{id_user_level};
        }

        $sth->finish;
    }

    unless ($level_id) {
        carp "Invalid level: $level";
        _log($logger, 1, " Invalid level: $level");
        return undef;
    }

    # Check if user exists.
    my $sql_check = "SELECT id_user FROM USER WHERE nickname = ?";
    my $sth_check = $dbh->prepare($sql_check);

    unless ($sth_check) {
        carp "create() duplicate-check SQL prepare error: $DBI::errstr";
        _log($logger, 1, " create() duplicate-check SQL prepare error: $DBI::errstr Query: $sql_check");
        return undef;
    }

    unless ($sth_check->execute($nickname)) {
        carp "create() duplicate-check SQL execute error: $DBI::errstr";
        _log($logger, 1, " create() duplicate-check SQL execute error: $DBI::errstr Query: $sql_check");
        $sth_check->finish;
        return undef;
    }

    if (my $ref = $sth_check->fetchrow_hashref) {
        carp "User $nickname already exists (id_user: $ref->{id_user})";
        _log($logger, 1, " User $nickname already exists (id_user: $ref->{id_user})");
        $sth_check->finish;
        return undef;
    }

    $sth_check->finish;

    # Insert new user. Hostmasks are stored in USER_HOSTMASK.
    my $sql_insert = q{
        INSERT INTO USER (nickname, password, username, id_user_level, info1, info2, auth)
        VALUES (?, ?, NULL, ?, ?, ?, 0)
    };

    my $sth_insert = $dbh->prepare($sql_insert);

    unless ($sth_insert) {
        carp "create() user insert SQL prepare error: $DBI::errstr";
        _log($logger, 1, " create() user insert SQL prepare error: $DBI::errstr Query: $sql_insert");
        return undef;
    }

    my $pass_db = defined $password ? $password : undef;

    unless ($sth_insert->execute($nickname, $pass_db, $level_id, $info1, $info2)) {
        carp "Failed to insert user $nickname";
        _log($logger, 1, " Failed to insert user $nickname: $DBI::errstr");
        $sth_insert->finish;
        return undef;
    }

    $sth_insert->finish;

    my $new_id = $dbh->last_insert_id(undef, undef, undef, undef);
    $new_id //= $dbh->{mysql_insertid};

    unless ($new_id) {
        carp "Failed to retrieve id for newly created user $nickname";
        _log($logger, 1, " Failed to retrieve id for newly created user $nickname");
        return undef;
    }

    # Store hostmasks.
    if ($hostmasks) {
        my $sql_hostmask = "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)";
        my $hm = $dbh->prepare($sql_hostmask);

        unless ($hm) {
            carp "create() hostmask SQL prepare error: $DBI::errstr";
            _log($logger, 1, " create() hostmask SQL prepare error: $DBI::errstr Query: $sql_hostmask");
            return undef;
        }

        for my $mask (grep { length } split /,/, $hostmasks) {
            $mask =~ s/^\s+|\s+$//g;
            next if $mask eq '';

            unless ($hm->execute($new_id, $mask)) {
                carp "Failed to insert hostmask for user $nickname";
                _log($logger, 1, " Failed to insert hostmask for user $nickname: $DBI::errstr");
                $hm->finish;
                return undef;
            }
        }

        $hm->finish;
    }

    # Fetch the newly created user.
    my $sql_get = "SELECT id_user, nickname, password, username, id_user_level, auth, info1, info2 FROM USER WHERE nickname = ?";
    my $sth_get = $dbh->prepare($sql_get);

    unless ($sth_get) {
        carp "create() refetch SQL prepare error: $DBI::errstr";
        _log($logger, 1, " create() refetch SQL prepare error: $DBI::errstr Query: $sql_get");
        return undef;
    }

    unless ($sth_get->execute($nickname)) {
        carp "create() refetch SQL execute error: $DBI::errstr";
        _log($logger, 1, " create() refetch SQL execute error: $DBI::errstr Query: $sql_get");
        $sth_get->finish;
        return undef;
    }

    my $row = $sth_get->fetchrow_hashref;
    $sth_get->finish;

    return undef unless $row;

    $row->{dbh} = $dbh;

    my $user_obj = $class->new($row);
    $user_obj->load_level($dbh);

    _log(
        $logger,
        1,
        " User created: $nickname (id_user=" . $user_obj->id . ", level=" . ($user_obj->level_description // '') . ")"
    );

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