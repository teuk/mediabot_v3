package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use List::Util qw(min);
use Exporter 'import';
use Try::Tiny;
use Mediabot::Helpers;

our @EXPORT = qw(
    _del_user_tz
    _get_user_tz
    _sendModUserSyntax
    _set_user_tz
    addUserHost_ctx
    addUser_ctx
    dbLogoutUsers
    delUser_ctx
    getIdUserLevel
    getLevelUser
    getUserChannelLevel
    getUserLevelDesc
    getUserName
    mbModUser_ctx
    mbSeen_ctx
    setUserLevel
    userBirthday_ctx
    userCstat_ctx
    userGreet_ctx
    userInfo_ctx
    userModinfoSyntax
    userModinfo_ctx
    userOnJoin
    userStats_ctx
    userTopSay_ctx
);

sub dbLogoutUsers {
    my ($self) = @_;

    my $dbh = $self->{dbh};
    unless ($dbh) {
        $self->{logger}->log(1, "dbLogoutUsers() no database handle")
            if $self->{logger};
        return 0;
    }

    my $sLogoutQuery = "UPDATE USER SET auth=0 WHERE auth=1";
    my $sth = $dbh->prepare($sLogoutQuery);

    unless ($sth) {
        $self->{logger}->log(1, "dbLogoutUsers() SQL prepare error : " . $DBI::errstr . " Query : " . $sLogoutQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute()) {
        $self->{logger}->log(1, "dbLogoutUsers() SQL execute error : " . $DBI::errstr . "(" . $DBI::err . ") Query : " . $sLogoutQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    $sth->finish;
    $self->{logger}->log(1, "Logged out all users")
        if $self->{logger};

    return 1;
}


# Set server attribute
sub getUserName {
    my $self = shift;
    my $conf = $self->{conf};
    return $conf->get('connection.CONN_USERNAME');
}

# Get IRC real name from configuration
sub userOnJoin {
    my ($self, $message, $sChannel, $sNick) = @_;

    # Try to match user from the IRC message
    my $user = $self->get_user_from_message($message);

    if ($user) {
        # Check for channel-specific user settings (auto mode and greet)
        my $sql = "SELECT uc.*, c.* FROM USER_CHANNEL AS uc JOIN CHANNEL AS c ON c.id_channel = uc.id_channel WHERE c.name = ? AND uc.id_user = ?;";
        $self->{logger}->log(4, $sql)
            if $self->{logger};

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "userOnJoin() SQL prepare error: " . $DBI::errstr . " Query: $sql")
                if $self->{logger};
        }
        elsif ($sth->execute($sChannel, $user->id)) {
            if (my $ref = $sth->fetchrow_hashref()) {

                # Apply auto mode if defined
                my $auto_mode = $ref->{automode};
                if (defined $auto_mode && $auto_mode ne '') {
                    if ($auto_mode eq 'OP') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+o", $sNick));
                    }
                    elsif ($auto_mode eq 'VOICE') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+v", $sNick));
                    }
                }

                # Send greet message to channel if defined
                my $greet = $ref->{greet};
                if (defined $greet && $greet ne '') {
                    botPrivmsg($self, $sChannel, "($user->{nickname}) $greet");
                }
            }

            $sth->finish;
        }
        else {
            $self->{logger}->log(1, "userOnJoin() SQL execute error: " . $DBI::errstr . " Query: $sql")
                if $self->{logger};
            $sth->finish;
        }
    }

    # Now check if the channel has a default notice to send on join
    my $sql_channel = "SELECT id_channel, notice FROM CHANNEL WHERE name = ?";
    $self->{logger}->log(4, $sql_channel)
        if $self->{logger};

    my $sth = $self->{dbh}->prepare($sql_channel);

    unless ($sth) {
        $self->{logger}->log(1, "userOnJoin() channel SQL prepare error: " . $DBI::errstr . " Query: $sql_channel")
            if $self->{logger};
        return;
    }

    if ($sth->execute($sChannel)) {
        if (my $ref = $sth->fetchrow_hashref()) {
            my $notice = $ref->{notice};
            if (defined $notice && $notice ne '') {
                botNotice($self, $sNick, $notice);
            }
        }

        $sth->finish;
    }
    else {
        $self->{logger}->log(1, "userOnJoin() channel SQL execute error: " . $DBI::errstr . " Query: $sql_channel")
            if $self->{logger};
        $sth->finish;
    }

    return;
}


# 🧙‍♂️ mbCommandPublic: The Sorting Hat of Mediabot – routes every incantation to the proper spell
sub getIdUserLevel {
    my ($self, $sLevel) = @_;

    return undef unless defined($sLevel) && $sLevel ne '';

    my $sQuery = "SELECT id_user_level FROM USER_LEVEL WHERE description = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getIdUserLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sLevel)) {
        $self->{logger}->log(1, "getIdUserLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $id_user_level;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_user_level = $ref->{id_user_level};
    }

    $sth->finish;
    return $id_user_level;
}


# Get user level (numeric) from nickname (handle)
# Get user level (numeric) from nickname (handle)
sub getLevelUser {
    my ($self, $sUserHandle) = @_;

    return undef unless defined($sUserHandle) && $sUserHandle ne '';

    my $sQuery = "SELECT USER_LEVEL.level FROM USER JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level WHERE USER.nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getLevelUser() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUserHandle)) {
        $self->{logger}->log(1, "getLevelUser() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $level;
    if (my $ref = $sth->fetchrow_hashref()) {
        $level = $ref->{level};
    }

    $sth->finish;
    return $level;
}


sub userCstat_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Administrator only
    return unless $ctx->require_level('Administrator');

    my $query = q{
        SELECT USER.nickname, USER_LEVEL.description
        FROM USER JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level
        WHERE USER.auth = 1
        ORDER BY USER_LEVEL.level, USER.nickname
    };

    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute) {
        $self->{logger}->log(1, "userCstat_ctx() SQL Error: $DBI::errstr");
        botNotice($self, $nick, 'Internal error (DB query failed).');
        $sth->finish if $sth;
        return;
    }

    my @entries;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $u = $ref->{nickname}    // '';
        my $d = $ref->{description} // '';
        push @entries, "$u($d)" if $u ne '';
    }
    $sth->finish;

    unless (@entries) {
        botNotice($self, $nick, "Authenticated users: none");
        logBot($self, $ctx->message, undef, 'cstat', undef);
        return 0;
    }

    my $count = scalar(@entries);
    botNotice($self, $nick, "Authenticated users: $count result(s)");

    my $per_line = 5;
    my $page     = 1;

    while (@entries) {
        my @chunk = splice(@entries, 0, $per_line);
        my $line  = sprintf("cstat[%02d]: %s", $page, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    logBot($self, $ctx->message, undef, 'cstat', undef);
    return $count;
}


# Context-based: Add a new user with a specified hostmask and optional level
sub addUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level("Master");
    my $user = $ctx->user;
    return unless $user;

    my ($name, $mask, $level) = @args;
    $level //= 'User';

    unless ($name && $mask && $mask =~ /@/) {
        botNotice($self, $nick, "Syntax: adduser <nick> <hostmask> [level]");
        return;
    }

    if (getIdUser($self, $name)) {
        botNotice($self, $nick, "User $name already exists");
        return;
    }

    my $id = userAdd($self, $mask, $name, undef, $level);
    botNotice($self, $nick, "User $name added (id=$id, level=$level)");

    logBot($self, $ctx->message, undef, "adduser", $name);
}

sub getUserLevelDesc {
    my ($self, $level) = @_;

    return undef unless defined($level) && $level ne '';

    my $sQuery = "SELECT description FROM USER_LEVEL WHERE level = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserLevelDesc() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($level)) {
        $self->{logger}->log(1, "getUserLevelDesc() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $sDescription;
    if (my $ref = $sth->fetchrow_hashref()) {
        $sDescription = $ref->{description};
    }

    $sth->finish;
    return $sDescription;
}


# Context-based: Display user statistics to Master level users
sub userStats_ctx {
    my ($ctx) = @_;

    return unless $ctx->require_level('Master');

    my $bot  = $ctx->bot;
    my $nick = $ctx->nick;

    my $sth = $bot->{dbh}->prepare(
        "SELECT COUNT(*) AS nbUsers FROM USER"
    );
    $sth->execute;
    my ($total) = $sth->fetchrow_array;
    $sth->finish;

    $bot->botNotice($nick, "Number of users: $total");

    $sth = $bot->{dbh}->prepare(
        "SELECT description, COUNT(*) 
         FROM USER 
         JOIN USER_LEVEL USING(id_user_level)
         GROUP BY description
         ORDER BY level"
    );
    $sth->execute;

    while (my ($desc, $count) = $sth->fetchrow_array) {
        $bot->botNotice($nick, "$desc ($count)");
    }
    $sth->finish;
}


# Context-based userinfo command (Master only)
sub userInfo_ctx {
    my ($ctx) = @_;
    return unless $ctx;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    $ctx->require_level('Master') or return;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target = $args[0] // '';

    if ($target eq '') {
        botNotice($self, $nick, "Syntax: userinfo <username>");
        return;
    }

    my $sQuery = q{
        SELECT
            USER.id_user,
            USER.nickname,
            USER.creation_date,
            USER.last_login,
            CASE
                WHEN USER.password IS NOT NULL AND USER.password <> '' THEN 1
                ELSE 0
            END AS has_password,
            USER.info1,
            USER.info2,
            USER.auth,
            USER.username,
            USER_LEVEL.level,
            USER_LEVEL.description
        FROM USER
        JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level
        WHERE USER.nickname = ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target)) {
        $self->{logger}->log(1, "userInfo_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_user     = $ref->{id_user}       // '?';
        my $nickname    = $ref->{nickname}      // '?';
        my $created     = $ref->{creation_date} // 'N/A';
        my $last_login  = $ref->{last_login}    // 'never';

        my @hostmasks;
        my $hm_sth = $self->{dbh}->prepare(
            "SELECT hostmask FROM USER_HOSTMASK WHERE id_user=? ORDER BY id_user_hostmask LIMIT 20"
        );

        if ($hm_sth && $hm_sth->execute($id_user)) {
            while (my $hm_ref = $hm_sth->fetchrow_hashref) {
                push @hostmasks, $hm_ref->{hostmask}
                    if defined($hm_ref->{hostmask}) && $hm_ref->{hostmask} ne '';
            }
            $hm_sth->finish;
        }
        else {
            $self->{logger}->log(1, "userInfo_ctx() hostmask SQL Error: $DBI::errstr")
                if $self->{logger};
            $hm_sth->finish if $hm_sth;
        }

        my $has_password = defined($ref->{has_password}) ? int($ref->{has_password}) : 0;
        my $level        = defined $ref->{level}       ? $ref->{level}       : '?';
        my $level_d  = defined $ref->{description} ? $ref->{description} : '?';
        my $auth     = defined $ref->{auth}        ? $ref->{auth}        : 0;
        my $username = defined $ref->{username}    ? $ref->{username}    : '';
        my $info1    = defined $ref->{info1}       ? $ref->{info1}       : '';
        my $info2    = defined $ref->{info2}       ? $ref->{info2}       : '';

        # Compact output — 2 NOTICE lines to avoid Excess Flood
        my $pass_set = $has_password ? 'yes' : 'no';
        botNotice($self, $nick,
            "[$id_user] $nickname | Level: $level_d | Auth: $auth | Pass: $pass_set"
            . ($username ne '' ? " | Username: $username" : "")
        );
        botNotice($self, $nick,
            "Created: $created | Last login: $last_login"
            . ($info1 ne '' ? " | Info1: $info1" : "")
            . ($info2 ne '' ? " | Info2: $info2" : "")
        );

        if (@hostmasks) {
            my $mask_count = scalar(@hostmasks);
            botNotice($self, $nick, "Hostmasks: $mask_count shown, max 20");

            my $per_line = 2;
            my $page     = 1;

            while (@hostmasks) {
                my @chunk = splice(@hostmasks, 0, $per_line);
                my $line  = sprintf("userinfo-masks[%02d]: %s", $page, join(' | ', @chunk));

                if (length($line) > 360) {
                    $line = substr($line, 0, 357) . '...';
                }

                botNotice($self, $nick, $line);
                $page++;
            }
        }
        else {
            botNotice($self, $nick, "Hostmasks: none");
        }
    }
    else {
        botNotice($self, $nick, "Unknown user $target");
    }

    $sth->finish;
    return;
}

# Context-based addhost command: add a new hostmask to an existing user (Master only)
sub addUserHost_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Master privilege
    $ctx->require_level('Master') or return;

    # Expected: addhost <username> <hostmask>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target_user  = $args[0] // '';
    my $new_hostmask = $args[1] // '';

    if ($target_user eq '' || $new_hostmask eq '') {
        botNotice($self, $nick, "Syntax: addhost <username> <hostmask>");
        return;
    }

    # Basic sanitization (keep behavior: strip ';')
    $new_hostmask =~ s/;//g;
    $new_hostmask =~ s/^\s+|\s+$//g;

    $self->{logger}->log(3, "addUserHost_ctx() target='$target_user' hostmask='$new_hostmask'");

    my $id_user = getIdUser($self, $target_user);
    unless (defined $id_user) {
        botNotice($self, $nick, "User $target_user does not exist");
        logBot($self, $ctx->message, undef, "addhost", "User $target_user does not exist");
        return;
    }

    # Check duplicate in USER_HOSTMASK
    my $chk = $self->{dbh}->prepare(
        "SELECT id_user_hostmask FROM USER_HOSTMASK WHERE id_user=? AND hostmask=? LIMIT 1"
    );
    unless ($chk && $chk->execute($id_user, $new_hostmask)) {
        $self->{logger}->log(1, "addUserHost_ctx() SQL Error: $DBI::errstr");
        return;
    }
    if ($chk->fetchrow_arrayref) {
        $chk->finish;
        my $msg = $ctx->message->prefix . " Hostmask $new_hostmask already exists for user $target_user";
        $self->{logger}->log(0, $msg);
        noticeConsoleChan($self, $msg);
        logBot($self, $ctx->message, undef, "addhost", $msg);
        return;
    }
    $chk->finish;

    my $ins = $self->{dbh}->prepare(
        "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)"
    );
    unless ($ins && $ins->execute($id_user, $new_hostmask)) {
        $self->{logger}->log(1, "addUserHost_ctx() SQL Insert Error: $DBI::errstr");
        return;
    }
    $ins->finish;

    my $msg = $ctx->message->prefix . " Hostmask $new_hostmask added for user $target_user";
    $self->{logger}->log(0, $msg);
    noticeConsoleChan($self, $msg);
    logBot($self, $ctx->message, undef, "addhost", $msg);

    botNotice($self, $nick, "Hostmask added for user $target_user");
}

# Context-based addchan command: add a new channel and register it with a user (Administrator only)
sub getUserChannelLevel {
    my ($self, $message, $sChannel, $id_user) = @_;

    return 0 unless defined($sChannel) && $sChannel ne '';
    return 0 unless defined($id_user)  && $id_user  ne '';

    my $sQuery = "SELECT USER_CHANNEL.level FROM CHANNEL JOIN USER_CHANNEL ON USER_CHANNEL.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ? AND USER_CHANNEL.id_user = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserChannelLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sChannel, $id_user)) {
        $self->{logger}->log(1, "getUserChannelLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $iLevel = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $iLevel = $ref->{level} // 0;
    }

    $sth->finish;
    return $iLevel;
}


# Delete a user from a channel
# Requires: authenticated + (Administrator+ OR channel-level >= 400)
sub userModinfoSyntax {
    my ($self, $message, $sNick, @tArgs) = @_;

    botNotice($self, $sNick, "Syntax: modinfo [#channel] automode <user> <OP|VOICE|NONE>");
    botNotice($self, $sNick, "Syntax: modinfo [#channel] greet <user> <greet> (use \"none\" to remove it)");
    botNotice($self, $sNick, "Syntax: modinfo [#channel] level <user> <level>");
}

# Modify user info (level, automode, greet) on a specific channel
sub userModinfo_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " modinfo command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it is a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    }
    else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($channel =~ /^#/) {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }

    # Ensure channel object exists (case-insensitive)
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "userModinfo_ctx(): could not resolve id_channel for $channel")
            if $self->{logger};
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Minimal syntax: <type> <handle> <value...>
    unless (
        defined $args[0] && $args[0] ne '' &&
        defined $args[1] && $args[1] ne '' &&
        defined $args[2] && $args[2] ne ''
    ) {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }

    my $type          = lc($args[0]);
    my $target_handle = $args[1];

    # Admin check via User.pm hierarchy
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Determine issuer handle (best effort)
    my $issuer_handle = eval { $user->handle } || eval { $user->nickname } || $nick;

    my $fetch_channel_level = sub {
        my ($handle) = @_;

        my $sql = q{
            SELECT uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        };

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "userModinfo_ctx(): issuer SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (undef, "prepare");
        }

        unless ($sth->execute($id_channel, $handle)) {
            $self->{logger}->log(1, "userModinfo_ctx(): issuer SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (undef, "execute");
        }

        my ($level) = $sth->fetchrow_array;
        $sth->finish;

        $level ||= 0;
        return ($level, undef);
    };

    my $fetch_target = sub {
        my ($handle) = @_;

        my $sql = q{
            SELECT u.id_user, uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        };

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "userModinfo_ctx(): target SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (undef, undef, "prepare");
        }

        unless ($sth->execute($id_channel, $handle)) {
            $self->{logger}->log(1, "userModinfo_ctx(): target SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (undef, undef, "execute");
        }

        my ($id_user, $level) = $sth->fetchrow_array;
        $sth->finish;

        $level ||= 0;
        return ($id_user, $level, undef);
    };

    my $run_update = sub {
        my ($sql, @bind) = @_;

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "userModinfo_ctx(): update SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return 0;
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "userModinfo_ctx(): update SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return 0;
        }

        $sth->finish;
        return 1;
    };

    my ($issuer_level, $lookup_err) = $fetch_channel_level->($issuer_handle);
    if ($lookup_err) {
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    }

    my ($id_user_target, $target_level, $target_err) = $fetch_target->($target_handle);
    if ($target_err) {
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    }

    unless (defined $id_user_target) {
        botNotice($self, $nick, "User $target_handle does not exist on $channel");
        return;
    }

    # Permission check:
    # - level/automode => Admin OR channel-level >= 400
    # - greet          => Admin OR channel-level >= 1
    my $has_access = 0;
    if ($is_admin) {
        $has_access = 1;
    }
    elsif ($type eq 'greet') {
        $has_access = ($issuer_level >= 1) ? 1 : 0;
    }
    else {
        $has_access = ($issuer_level >= 400) ? 1 : 0;
    }

    unless ($has_access) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " modinfo command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$issuer_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Prevent modifying a user with equal/higher access than caller, unless admin.
    # For greet: allow if issuer_level > 0, matching the previous behavior.
    unless (
        $is_admin
        || ($issuer_level > $target_level)
        || ($type eq 'greet' && $issuer_level > 0)
    ) {
        botNotice($self, $nick, "Cannot modify a user with equal or higher access than your own.");
        return;
    }

    if ($type eq 'automode') {
        my $mode = uc($args[2] // '');

        unless ($mode =~ /^(OP|VOICE|NONE)$/i) {
            userModinfoSyntax($self, $ctx->message, $nick, @args);
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
        unless ($run_update->($query, $mode, $id_user_target, $id_channel)) {
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }

        botNotice($self, $nick, "Set automode $mode on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;
    }
    elsif ($type eq 'greet') {
        # If caller < 400, they can only set THEIR OWN greet unless admin.
        if (!$is_admin && $issuer_level < 400 && lc($target_handle) ne lc($issuer_handle)) {
            botNotice($self, $nick, "Your level does not allow you to perform this command.");
            return;
        }

        my @greet_parts = @args[ 2 .. $#args ];
        my $greet_msg = (scalar(@greet_parts) == 1 && defined($greet_parts[0]) && $greet_parts[0] =~ /none/i)
            ? undef
            : join(" ", @greet_parts);

        my $query = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
        unless ($run_update->($query, $greet_msg, $id_user_target, $id_channel)) {
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }

        botNotice($self, $nick, "Set greet (" . (defined $greet_msg ? $greet_msg : "none") . ") on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", ("greet", $target_handle, @greet_parts));
        return $id_channel;
    }
    elsif ($type eq 'level') {
        my $new_level = $args[2];

        unless (defined($new_level) && $new_level =~ /^\d+$/ && $new_level <= 500) {
            botNotice($self, $nick, "Cannot set user access higher than 500.");
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
        unless ($run_update->($query, $new_level, $id_user_target, $id_channel)) {
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }

        botNotice($self, $nick, "Set level $new_level on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;
    }

    userModinfoSyntax($self, $ctx->message, $nick, @args);
    return;
}

# Get user ID and level on a specific channel
sub userTopSay_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Destination (private notice vs channel privmsg)
    my $ctx_chan  = $ctx->channel // undef;
    my $is_private = !defined($ctx_chan) || $ctx_chan eq '';
    my $dest_chan  = $ctx_chan; # may be undef

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Require authentication
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx topsay attempt (unauthenticated user " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged in to use this command: /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx topsay attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        return;
    }

    # Channel and nick extraction:
    # - If first arg is a #channel => use it, and output there (unless ctx is private and you prefer notice; we keep original behavior)
    # - Else use ctx->channel
    my $chan = undef;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        $chan = $ctx_chan;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: topsay [#channel] <nick>");
        return;
    }

    # If command was issued in-channel, reply in that channel by default.
    # If issued in private, keep replying in notice unless a channel was explicitly provided.
    if (!$is_private) {
        $dest_chan = $chan;
    } else {
        # private: if user provided a channel explicitly, send to that channel (keeps old behavior: isPrivate is based on original sChannel)
        $dest_chan = $chan if defined $chan;
    }

    my $target_nick = (defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    my $sql = <<'SQL';
SELECT event_type, publictext, COUNT(publictext) as hit
FROM CHANNEL JOIN CHANNEL_LOG ON CHANNEL_LOG.id_channel = CHANNEL.id_channel
WHERE (CHANNEL_LOG.event_type = 'public' OR CHANNEL_LOG.event_type = 'action')
  AND CHANNEL.name = ?
  AND CHANNEL_LOG.nick LIKE ? ESCAPE '!'
GROUP BY publictext
ORDER BY hit DESC
LIMIT 30
SQL

    my $target_nick_like = $target_nick;
    $target_nick_like =~ s/!/!!/g;
    $target_nick_like =~ s/%/!%/g;
    $target_nick_like =~ s/_/!_/g;

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($chan, $target_nick_like)) {
        $self->{logger}->log(1, "userTopSay_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my @items;

    my @skip_patterns = (
        qr/^\s*$/,
        qr/^[:;=]?[pPdDoO)]$/,
        qr/^[(;][:;=]?$/,
        qr/^x?D$/i,
        qr/^(heh|hah|huh|hih)$/i,
        qr/^!/,
        qr/^=.?$/,
        qr/^;[p>]$/,
        qr/^:>$/,
        qr/^lol$/i,
    );

    while (my $ref = $sth->fetchrow_hashref()) {
        my ($text, $event_type, $count) = @{$ref}{qw/publictext event_type hit/};

        next unless defined $text;

        # Clean control characters (old behavior)
        $text =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;

        # Skip useless lines
        next if grep { $text =~ $_ } @skip_patterns;

        my $entry =
            ($event_type && $event_type eq 'action')
            ? String::IRC->new("$text ($count)")->bold
            : "$text ($count)";

        push @items, $entry;
    }

    if (!@items) {
        my $msg = "No results.";
        if ($is_private) {
            botNotice($self, $nick, $msg);
        }
        else {
            botPrivmsg($self, $dest_chan, $msg);
        }
    }
    else {
        my $count   = scalar(@items);
        my $summary = "Top sayings for $target_nick on $chan: $count result(s), showing max 30";

        if ($is_private) {
            botNotice($self, $nick, $summary);
        }
        else {
            botPrivmsg($self, $dest_chan, "$summary - details sent by notice to $nick");
        }

        my $per_line = 3;
        my $page     = 1;

        while (@items) {
            my @chunk = splice(@items, 0, $per_line);
            my $line  = sprintf("topsay[%02d]: %s", $page, join(' | ', @chunk));

            if (length($line) > 360) {
                $line = substr($line, 0, 357) . '...';
            }

            botNotice($self, $nick, $line);
            $page++;
        }
    }

    my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
    logBot($self, $ctx->message, $dest_chan, "topsay", "$pfx topsay on $target_nick");

    $sth->finish;
    return 1;
}

# Check nicknames used on a given channel by a specific hostname (fast DB query)
# Requires: authenticated + Administrator+
sub userGreet_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;  # where to speak if public

    # Resolve target channel:
    # - if first arg is #channel, use it
    # - else use ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    if ($is_private && $target_chan eq '') {
        botNotice($self, $nick, "Syntax (in private): greet #channel <nick>");
        return;
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: greet [#channel] <nick>");
        return;
    }

    # Who are we querying the greet for?
    my $greet_nick = (defined $args[0] && $args[0] ne '') ? $args[0] : $nick;
    $greet_nick =~ s/^\s+|\s+$//g;
    $greet_nick =~ s/!.*$//; # if someone passes nick!ident@host, keep nick

    my $say = sub {
        my ($text) = @_;
        if ($is_private) {
            botNotice($self, $nick, $text);
        } else {
            botPrivmsg($self, $dest_chan, $text);
        }
    };

    my $sql = <<'SQL';
SELECT uc.greet AS greet
FROM CHANNEL c
JOIN USER_CHANNEL uc ON uc.id_channel = c.id_channel
JOIN USER u         ON u.id_user     = uc.id_user
WHERE c.name = ?
  AND u.nickname = ?
LIMIT 1
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_chan, $greet_nick)) {
        $self->{logger}->log(1, "userGreet_ctx() SQL Error: $DBI::errstr Query: $sql");
        $say->("Database error while fetching greet for $greet_nick on $target_chan.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    my $greet = ($ref && defined $ref->{greet} && $ref->{greet} ne '') ? $ref->{greet} : undef;

    if ($greet) {
        $say->("greet on $target_chan ($greet_nick) $greet");
    } else {
        $say->("No greet for $greet_nick on $target_chan");
    }

    my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
    logBot($self, $ctx->message, ($is_private ? undef : $dest_chan), "greet", "$pfx greet on $greet_nick for $target_chan");

    return 1;
}

# Get stored WHOIS variables
sub mbSeen_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    unless (@args) {
        botNotice($self, $nick, "Syntax: seen <nick> [#channel]");
        return;
    }

    my $target_input = shift @args;
    $target_input =~ s/^\s+|\s+\z//g;

    my $targetNick = lc($target_input);  # normalize for USER_SEEN PK lookup

    my $chan_for_part;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan_for_part = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan_for_part = ($cc =~ /^#/) ? $cc : undef;
    }

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Check if the nick is currently online before hitting the DB.
    # If seen <nick> #channel was requested, keep this online check scoped
    # to that channel instead of reporting an unrelated channel.
    {
        my %hChannelsNicks = %{ $self->gethChannelNicks() // {} };

        for my $chan (sort keys %hChannelsNicks) {
            next if defined($chan_for_part) && lc($chan) ne lc($chan_for_part);

            my @nicks = $self->gethChannelsNicksOnChan($chan);
            my ($online_nick) = grep { lc($_) eq $targetNick } @nicks;

            if (defined($online_nick) && $online_nick ne '') {
                my $msg = "$online_nick is currently online on $chan.";

                if ($is_private) {
                    botNotice($self, $ctx->nick, $msg);
                } else {
                    botPrivmsg($self, $dest_chan, $msg);
                }

                logBot($self, $ctx->message, ($is_private ? undef : $dest_chan), "seen", $targetNick);
                return 1;
            }
        }
    }

    my $fmt_host = sub {
        my ($h) = @_; $h //= ''; $h =~ s/^.*!//; return $h;
    };

    my $fmt_ago = sub {
        my ($uts) = @_;
        my $secs = time() - ($uts // 0);
        return 'just now' if $secs < 5;
        my $d = int($secs / 86400);
        my $h = int(($secs % 86400) / 3600);
        my $m = int(($secs % 3600) / 60);
        my @p;
        push @p, "${d}d" if $d;
        push @p, "${h}h" if $h;
        push @p, "${m}m" if $m || (!$d && !$h);
        return join(' ', @p) . ' ago';
    };

    # --- 1. Check USER_SEEN first (persisted, covers messages + joins) ---
    my $seen_row;
    {
        my $sth = $self->{dbh}->prepare(
            "SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                    seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
             FROM USER_SEEN WHERE nick = ? LIMIT 1"
        );
        if ($sth && $sth->execute($targetNick)) {
            $seen_row = $sth->fetchrow_hashref;
            $sth->finish;
        }
    }

    # --- 2. Fallback: CHANNEL_LOG quit/part (older data pre-USER_SEEN) ---
    my ($quit, $part);

    unless ($seen_row) {
        my $sth_quit = $self->{dbh}->prepare(
            "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
             FROM CHANNEL_LOG
             WHERE nick = ? AND event_type = 'quit'
             ORDER BY ts DESC LIMIT 1"
        );
        if ($sth_quit && $sth_quit->execute($targetNick)) {
            if (my $r = $sth_quit->fetchrow_hashref) {
                $quit = { ts => $r->{ts}, uts => $r->{uts} // 0,
                          host => $r->{userhost} // '', text => $r->{publictext} // '' };
            }
            $sth_quit->finish;
        }

        if (defined $chan_for_part) {
            my $channel_obj = $self->{channels}{$chan_for_part}
                           || $self->{channels}{lc($chan_for_part)};
            my $id_channel = eval { $channel_obj->get_id } || 0;
            if ($id_channel) {
                my $sth_part = $self->{dbh}->prepare(
                    "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
                     FROM CHANNEL_LOG
                     WHERE id_channel = ? AND nick = ? AND event_type = 'part'
                     ORDER BY ts DESC LIMIT 1"
                );
                if ($sth_part && $sth_part->execute($id_channel, $targetNick)) {
                    if (my $r = $sth_part->fetchrow_hashref) {
                        $part = { ts => $r->{ts}, uts => $r->{uts} // 0,
                                  host => $r->{userhost} // '', text => $r->{publictext} // '' };
                    }
                    $sth_part->finish;
                }
            }
        }
    }

    # --- Build message ---
    my $msg;

    if ($seen_row) {
        my $host = $fmt_host->($seen_row->{userhost});
        my $ago  = $fmt_ago->($seen_row->{seen_uts});
        my $ev   = $seen_row->{event_type} // 'message';
        my $chan  = $seen_row->{channel} // '';

        if ($ev eq 'message') {
            my $last = $seen_row->{last_msg} // '';
            $msg = "$targetNick ($host) was last seen $ago"
                 . ($chan ? " on $chan" : '')
                 . ($last ? " saying: $last" : '');
        } elsif ($ev eq 'join') {
            $msg = "$targetNick ($host) was last seen joining $chan $ago";
        } elsif ($ev eq 'part') {
            my $last = $seen_row->{last_msg} // '';
            $msg = "$targetNick ($host) was last seen parting $chan $ago"
                 . ($last ? " ($last)" : '');
        } elsif ($ev eq 'quit') {
            my $last = $seen_row->{last_msg} // '';
            $msg = "$targetNick ($host) was last seen quitting $ago"
                 . ($last ? " ($last)" : '');
        } elsif ($ev eq 'nick') {
            my $nn = $seen_row->{new_nick} // '?';
            $msg = "$targetNick ($host) was last seen $ago changing nick to $nn";
        } else {
            $msg = "$targetNick ($host) was last seen $ago ($ev)";
        }
    } elsif ($quit || $part) {
        # Fallback CHANNEL_LOG path
        my $quit_uts = $quit ? ($quit->{uts} // 0) : 0;
        my $part_uts = $part ? ($part->{uts} // 0) : 0;
        if ($part_uts && $part_uts >= $quit_uts && $chan_for_part) {
            my $host = $fmt_host->($part->{host});
            my $txt  = $part->{text} // '';
            $msg = "$targetNick ($host) was last seen parting $chan_for_part : $part->{ts}"
                 . ($txt ne '' ? " ($txt)" : '');
        } else {
            my $host = $fmt_host->($quit->{host});
            my $txt  = $quit->{text} // '';
            $msg = "$targetNick ($host) was last seen quitting : $quit->{ts}"
                 . ($txt ne '' ? " ($txt)" : '');
        }
    } else {
        $msg = "I don't remember seeing nick $targetNick.";
    }

    if ($is_private) {
        botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "seen", $targetNick);
    } else {
        botPrivmsg($self, $dest_chan, $msg);
        logBot($self, $ctx->message, $dest_chan, "seen", $targetNick);
    }

    return 1;
}

# Get timezone for a user (nickname / handle)
sub _get_user_tz {
    my ($self, $nick) = @_;

    my $sth = $self->{dbh}->prepare("SELECT tz FROM USER WHERE nickname = ?");
    unless ($sth->execute($nick)) {
        $sth->finish;
        return undef;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    return $ref ? $ref->{tz} : undef;
}

# Set timezone for a user
sub _set_user_tz {
    my ($self, $nick, $tz) = @_;

    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=? WHERE nickname = ?");
    my $ok = $sth->execute($tz, $nick);
    $sth->finish;

    return $ok;
}

# Clear timezone for a user
sub _del_user_tz {
    my ($self, $nick) = @_;

    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=NULL WHERE nickname = ?");
    my $ok = $sth->execute($nick);
    $sth->finish;

    return $ok;
}

# date [tz|nick|alias|list|me|user add/del ...]
sub mbModUser_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;        # caller IRC nick
    my $channel = $ctx->channel;     # may be undef (private)
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------------------------
    # Resolve caller user object (Context first, then legacy)
    # ---------------------------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };

    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    my $uid    = eval { $user->id };
    my $handle = eval { $user->nickname } || $nick;
    my $level  = eval { $user->level };

    # Local DB helpers for this command only.
    my $select_one = sub {
        my ($sql, @bind) = @_;

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "mbModUser_ctx() SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (undef, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "mbModUser_ctx() SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (undef, "execute");
        }

        my $row = $sth->fetchrow_hashref();
        $sth->finish;

        return ($row, undef);
    };

    my $run_update = sub {
        my ($sql, @bind) = @_;

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1, "mbModUser_ctx() update SQL prepare error: $DBI::errstr Query: $sql")
                if $self->{logger};
            return (0, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "mbModUser_ctx() update SQL execute error: $DBI::errstr Query: $sql")
                if $self->{logger};
            $sth->finish;
            return (0, "execute");
        }

        my $rows = $sth->rows;
        $sth->finish;

        return ($rows, undef);
    };

    # ---------------------------------------------------------
    # Arguments dispatch
    # moduser <user> level <Owner|Master|Administrator|User> [force]
    # moduser <user> autologin <on|off>
    # moduser <user> fortniteid <id>
    # ---------------------------------------------------------
    unless (@args) {
        _sendModUserSyntax($self, $nick);
        return;
    }

    my $target_nick = shift @args;
    my $target_uid  = getIdUser($self, $target_nick);

    unless ($target_uid) {
        botNotice($self, $nick, "User: $target_nick does not exist");
        return;
    }

    unless (@args) {
        _sendModUserSyntax($self, $nick);
        return;
    }

    my $subcmd = shift @args;
    my @original_args_for_log = ($target_nick, $subcmd, @args);

    # =========================================================
    # LEVEL MODIFICATION
    # =========================================================
    if ($subcmd =~ /^level$/i) {

        my $target_level_str = lc($args[0] // '');
        unless ($target_level_str =~ /^(owner|master|administrator|user)$/) {
            botNotice($self, $nick, "moduser $target_nick level <Owner|Master|Administrator|User>");
            return;
        }

        my $target_level  = getLevel($self, $target_level_str);
        my $current_level = getLevelUser($self, $target_nick);

        # Safety: avoid accidental ownership transfer
        if ($target_level == 0 && $level == 0 && (!defined($args[1]) || $args[1] !~ /^force$/i)) {
            botNotice($self, $nick, "Do you really want to do that?");
            botNotice($self, $nick, "If you know what you're doing: moduser $target_nick level Owner force");
            return;
        }

        # Only allow if caller has strictly higher privileges (numeric "lower") than both
        if ($level < $current_level && $level < $target_level) {
            if ($target_level == $current_level) {
                botNotice($self, $nick, "User $target_nick is already a global $target_level_str.");
            }
            else {
                if (setUserLevel($self, $target_nick, getIdUserLevel($self, $target_level_str))) {
                    botNotice($self, $nick, "User $target_nick is now a global $target_level_str.");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                }
                else {
                    botNotice($self, $nick, "Could not set $target_nick as global $target_level_str.");
                }
            }
        }
        else {
            my $target_desc = getUserLevelDesc($self, $current_level);
            if ($target_level == $current_level) {
                botNotice($self, $nick, "You can't set $target_nick to $target_level_str: they're already $target_desc.");
            }
            else {
                botNotice($self, $nick, "You can't set $target_nick ($target_desc) to $target_level_str.");
            }
        }

        return;
    }

    # =========================================================
    # AUTOLOGIN
    # =========================================================
    elsif ($subcmd =~ /^autologin$/i) {
        my $arg = lc($args[0] // '');

        unless ($arg =~ /^(on|off)$/) {
            botNotice($self, $nick, "moduser $target_nick autologin <on|off>");
            return;
        }

        my ($row, $err) = $select_one->(
            "SELECT 1 FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'",
            $target_nick,
        );

        if ($err) {
            botNotice($self, $nick, "Internal error (DB lookup failed).");
            return;
        }

        if ($arg eq 'on') {
            if ($row) {
                botNotice($self, $nick, "Autologin is already ON for $target_nick");
                return;
            }

            my ($rows, $upd_err) = $run_update->(
                "UPDATE USER SET username = '#AUTOLOGIN#' WHERE nickname = ?",
                $target_nick,
            );

            if ($upd_err) {
                botNotice($self, $nick, "Internal error (DB update failed).");
                return;
            }

            botNotice($self, $nick, "Set autologin ON for $target_nick");
            logBot($self, $message, $channel, "moduser", @original_args_for_log);
            return $rows;
        }

        # off
        unless ($row) {
            botNotice($self, $nick, "Autologin is already OFF for $target_nick");
            return;
        }

        my ($rows, $upd_err) = $run_update->(
            "UPDATE USER SET username = NULL WHERE nickname = ?",
            $target_nick,
        );

        if ($upd_err) {
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }

        botNotice($self, $nick, "Set autologin OFF for $target_nick");
        logBot($self, $message, $channel, "moduser", @original_args_for_log);
        return $rows;
    }

    # =========================================================
    # FORTNITEID
    # =========================================================
    elsif ($subcmd =~ /^fortniteid$/i) {
        my $fortniteid = $args[0] // '';

        unless ($fortniteid ne '') {
            botNotice($self, $nick, "moduser $target_nick fortniteid <id>");
            return;
        }

        my ($already_set, $err) = $select_one->(
            "SELECT 1 FROM USER WHERE nickname = ? AND fortniteid = ?",
            $target_nick,
            $fortniteid,
        );

        if ($err) {
            botNotice($self, $nick, "Internal error (DB lookup failed).");
            return;
        }

        if ($already_set) {
            botNotice($self, $nick, "fortniteid is already $fortniteid for $target_nick");
            return;
        }

        my ($rows, $upd_err) = $run_update->(
            "UPDATE USER SET fortniteid = ? WHERE nickname = ?",
            $fortniteid,
            $target_nick,
        );

        if ($upd_err) {
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }

        botNotice($self, $nick, "Set fortniteid $fortniteid for $target_nick");
        logBot($self, $message, $channel, "fortniteid", @original_args_for_log);
        return $rows;
    }

    # =========================================================
    # Unknown subcommand
    # =========================================================
    botNotice($self, $nick, "Unknown moduser command: $subcmd");
    return;
}

# Helper: print moduser usage
sub _sendModUserSyntax {
    my ($self, $sNick) = @_;
    botNotice($self, $sNick, "moduser <user> level <Owner|Master|Administrator|User>");
    botNotice($self, $sNick, "moduser <user> autologin <on|off>");
    botNotice($self, $sNick, "moduser <user> fortniteid <id>");
}

# Set global user level (Owner/Master/Administrator/User)
sub setUserLevel {
    my ($self, $sUser, $id_user_level) = @_;

    my $sQuery = "UPDATE USER SET id_user_level=? WHERE nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth->execute($id_user_level, $sUser)) {
        $self->{logger}->log(1, "SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        $sth->finish;
        return 0;
    }
    $sth->finish;
    return 1;
}


sub userBirthday_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Normalize args
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args) {
        botNotice($self, $nick, "Syntax: birthday <username>");
        return;
    }

    # Helper: where to reply
    my $is_private = (!defined($channel) || $channel eq '');
    my $reply_chan = $channel;

    #
    # birthday <username>
    #
    if (@args == 1 && $args[0] !~ /^(add|del|next)$/i) {
        my $target = $args[0];

        my $sth = $self->{dbh}->prepare("SELECT birthday FROM USER WHERE nickname = ?");
        unless ($sth && $sth->execute($target)) {
            $self->{logger}->log(1, "userBirthday_ctx() SQL Error: $DBI::errstr");
            return;
        }

        if (my $row = $sth->fetchrow_hashref) {
            if (defined $row->{birthday} && $row->{birthday} ne '') {
                my $msg = "${target}'s birthday is $row->{birthday}";
                $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
            } else {
                my $msg = "User $target has no defined birthday.";
                $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
            }
        } else {
            my $msg = "Unknown user $target";
            $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
        }

        $sth->finish;
        return 1;
    }

    #
    # birthday next
    #
    if ($args[0] =~ /^next$/i) {
        return _birthday_next_ctx($ctx);
    }

    #
    # birthday add|del user ...
    # Requires: authenticated + Administrator
    #
    my $user = $ctx->user || $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick,
            "You must be logged in to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password");
        return;
    }

    unless (eval { $user->has_level("Administrator") }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    my ($mode, $kwd, $target, $date) = @args;

    unless (defined $mode && $mode =~ /^(add|del)$/i && defined $kwd && $kwd =~ /^user$/i && defined $target && $target ne '') {
        botNotice($self, $nick, "Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
        botNotice($self, $nick, "Syntax: birthday del user <username>");
        return;
    }

    if ($mode =~ /^add$/i) {
        return _birthday_add_ctx($ctx, $target, $date);
    }

    if ($mode =~ /^del$/i) {
        return _birthday_del_ctx($ctx, $target);
    }

    botNotice($self, $nick, "Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
    return;
}

# Send a public message to all channels with chanset +RadioPub
sub delUser_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Remove caller nick if injected
    shift @args if @args && lc($args[0]) eq lc($nick);

    return unless $ctx->require_level("Master");
    my $user = $ctx->user;
    return unless $user;

    my $target = $args[0] // '';
    $target =~ s/^\s+|\s+$//g;

    if ($target eq '') {
        botNotice($self, $nick, "Syntax: deluser <username>");
        return;
    }

    my $id_user = getIdUser($self, $target);
    unless ($id_user) {
        botNotice($self, $nick, "Undefined user $target");
        return;
    }

    # A5: two-step confirmation — operator must confirm within 30s
    my $confirm_key = "_deluser_pending_${nick}_${target}";
    my $now_confirm = time();
    if (!$self->{$confirm_key}
        || ($now_confirm - ($self->{$confirm_key}{at} // 0)) > 30)
    {
        $self->{$confirm_key} = { at => $now_confirm };
        botNotice($self, $nick,
            "WARNING: This will permanently delete user '$target' (id=$id_user). "
          . "Repeat the command within 30s to confirm.");
        return;
    }
    delete $self->{$confirm_key};

    # B2/B3/A2: atomic transaction + cascade + eval safety
    my $dbh = $self->{dbh};
    my $ok = eval {
        $dbh->begin_work;
        $dbh->do("DELETE FROM USER_CHANNEL  WHERE id_user=?", undef, $id_user);
        $dbh->do("DELETE FROM USER_HOSTMASK WHERE id_user=?", undef, $id_user);
        $dbh->do("DELETE FROM USER_SEEN     WHERE nick = ?",  undef, lc($target));
        $dbh->do("DELETE FROM USER          WHERE id_user=?", undef, $id_user);
        $dbh->commit;
        1;
    };
    if (!$ok || $@) {
        eval { $dbh->rollback };
        $self->{logger}->log(0, "delUser_ctx: transaction failed for $target: $@");
 botNotice($self, $nick, "Database error -- user not deleted.");
        return;
    }

    my $msg = "User $target (id_user: $id_user) has been deleted";
    $self->{logger}->log(0, "delUser_ctx: $msg (by $nick)");
    botNotice($self, $nick, $msg);
    logBot($self, $message, undef, "deluser", $msg);
}

# Get Fortnite ID for a user


# ---------------------------------------------------------------------------
# _birthday_add_ctx($ctx, $target, $date)
# Set birthday for a user. Format: dd/mm  or  dd/mm/YYYY
# ---------------------------------------------------------------------------
sub _birthday_add_ctx {
    my ($ctx, $target, $date) = @_;
    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    unless (defined $target && $target ne '') {
        botNotice($self, $nick, "Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
        return;
    }

    # Validate and normalize date
    my $normalized;
    if (!defined $date || $date eq '') {
        # No date — clear birthday
        $normalized = undef;
    } elsif ($date =~ m{^(\d{1,2})/(\d{1,2})(?:/(\d{4}))?$}) {
        my ($d, $m, $y) = ($1, $2, $3);

        my $check_year = defined($y) ? $y : 2000; # leap year, allows 29/02 without storing a year

        unless (_birthday_valid_date($check_year, $m, $d)) {
            botNotice($self, $nick, "Invalid birthday date.");
            return;
        }

        $normalized = defined $y
            ? sprintf("%04d-%02d-%02d", $y, $m, $d)
            : sprintf("%02d-%02d", $m, $d);
    } else {
        botNotice($self, $nick, "Date format must be dd/mm or dd/mm/YYYY.");
        return;
    }

    # A1: guard against oversized values before UPDATE
    if (defined($normalized) && length($normalized) > 10) {
        botNotice($self, $nick, "Internal error: date value too long.");
        return;
    }

    my $id_user = getIdUser($self, $target);
    unless ($id_user) {
        botNotice($self, $nick, "Unknown user: $target");
        return;
    }

    my $sth = $self->{dbh}->prepare(
        "UPDATE USER SET birthday = ? WHERE id_user = ?"
    );
    unless ($sth && $sth->execute($normalized, $id_user)) {
        $self->{logger}->log(1, "_birthday_add_ctx() SQL error: $DBI::errstr");
        botNotice($self, $nick, "Database error.");
        return;
    }
    $sth->finish;

    my $msg = defined $normalized
        ? "Birthday set to $normalized for $target."
        : "Birthday cleared for $target.";
    botNotice($self, $nick, $msg);
    logBot($self, $ctx->message, undef, "birthday add", "$target $normalized");
    return 1;
}

# ---------------------------------------------------------------------------
# _birthday_del_ctx($ctx, $target) — clear birthday for a user
# ---------------------------------------------------------------------------
sub _birthday_del_ctx {
    my ($ctx, $target) = @_;
    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    unless (defined $target && $target ne '') {
        botNotice($self, $nick, "Syntax: birthday del user <username>");
        return;
    }

    my $id_user = getIdUser($self, $target);
    unless ($id_user) {
        botNotice($self, $nick, "Unknown user: $target");
        return;
    }

    my $sth = $self->{dbh}->prepare(
        "UPDATE USER SET birthday = NULL WHERE id_user = ?"
    );
    unless ($sth && $sth->execute($id_user)) {
        $self->{logger}->log(1, "_birthday_del_ctx() SQL error: $DBI::errstr");
        botNotice($self, $nick, "Database error.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Birthday cleared for $target.");
    logBot($self, $ctx->message, undef, "birthday del", $target);
    return 1;
}

# ---------------------------------------------------------------------------
# _birthday_next_ctx($ctx) — list upcoming birthdays (next 30 days)
# ---------------------------------------------------------------------------
sub _birthday_valid_date {
    my ($year, $month, $day) = @_;

    return 0 unless defined($year)  && $year  =~ /^\d{4}\z/;
    return 0 unless defined($month) && $month =~ /^\d{1,2}\z/;
    return 0 unless defined($day)   && $day   =~ /^\d{1,2}\z/;

    return 0 if $month < 1 || $month > 12;
    return 0 if $day   < 1 || $day   > 31;

    # B3/A3: validate days-per-month (use provided year or 2000 as leap-year reference)
    my $check_year = (defined($year) && $year =~ /^\d{4}\z/) ? $year : 2000;
    my @days_in_month = (0, 31,
        ($check_year % 4 == 0 && ($check_year % 100 != 0 || $check_year % 400 == 0))
            ? 29 : 28,
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return 0 if $day > $days_in_month[$month];

    my $epoch = eval { timegm(0, 0, 12, $day, $month - 1, $year) };
    return 0 if $@ || !defined($epoch);

    my @check = gmtime($epoch);

    return (
        $check[5] + 1900 == $year
        && $check[4] + 1 == $month
        && $check[3] == $day
    ) ? 1 : 0;
}

sub _birthday_mmdd_from_value {
    my ($birthday) = @_;

    return undef unless defined($birthday) && $birthday ne '';

    if ($birthday =~ m{^(\d{2})-(\d{2})\z}) {
        return ($1, $2);
    }

    if ($birthday =~ m{^\d{4}-(\d{2})-(\d{2})\z}) {
        return ($1, $2);
    }

    return undef;
}

sub _birthday_days_ahead {
    my ($month, $day, $now) = @_;

    $now //= time();

    my @today = gmtime($now);
    my $year  = $today[5] + 1900;

    my $today_epoch = timegm(0, 0, 12, $today[3], $today[4], $year);

    for my $offset (0 .. 4) {
        my $candidate_year = $year + $offset;

        next unless _birthday_valid_date($candidate_year, $month, $day);

        my $candidate_epoch = timegm(0, 0, 12, $day, $month - 1, $candidate_year);
        next if $candidate_epoch < $today_epoch;

        return int(($candidate_epoch - $today_epoch) / 86400);
    }

    return undef;
}

# ---------------------------------------------------------------------------
# _birthday_next_ctx($ctx) — list upcoming birthdays in the next 30 days
# ---------------------------------------------------------------------------
sub _birthday_next_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $window_days = 30;

    my $sth = $self->{dbh}->prepare(q{
        SELECT nickname, birthday
        FROM USER
        WHERE birthday IS NOT NULL AND birthday != ''
    });

    unless ($sth && $sth->execute) {
        $self->{logger}->log(1, "_birthday_next_ctx() SQL error: $DBI::errstr");
        botNotice($self, $nick, "Database error.");
        return;
    }

    my @upcoming;
    my $now = time();

    while (my $row = $sth->fetchrow_hashref) {
        my ($month, $day) = _birthday_mmdd_from_value($row->{birthday});
        next unless defined($month) && defined($day);

        my $days_ahead = _birthday_days_ahead($month, $day, $now);
        next unless defined($days_ahead);
        next if $days_ahead > $window_days;

        push @upcoming, {
            nick       => $row->{nickname},
            bday       => $row->{birthday},
            mmdd       => sprintf("%02d-%02d", $month, $day),
            days_ahead => $days_ahead,
        };
    }

    $sth->finish;

    @upcoming = sort {
        $a->{days_ahead} <=> $b->{days_ahead}
            || lc($a->{nick}) cmp lc($b->{nick})
    } @upcoming;

    @upcoming = @upcoming[0 .. 9] if @upcoming > 10;  # cap at 10

    unless (@upcoming) {
        botNotice($self, $nick, "No upcoming birthdays in the next $window_days days.");
        return 1;
    }

    botNotice($self, $nick, "Upcoming birthdays in the next $window_days days:");

    for my $u (@upcoming) {
        my $when = $u->{days_ahead} == 0
            ? 'today'
            : "in $u->{days_ahead}d";

        botNotice($self, $nick, "  $u->{nick} : $u->{bday} ($when)");
    }

    return 1;
}



1;
