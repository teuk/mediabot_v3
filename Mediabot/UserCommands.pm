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
    mbStats_ctx
    mbTop_ctx
    mb8ball_ctx
    mbRemind_ctx
    mbRemindList_ctx
    mbRemindCancel_ctx
    deliverReminders
    mbCalcLast_ctx
    mbWordCount_ctx
    mbAlias_ctx
    mbStreak_ctx
    mbSlap_ctx
    mbKarma_ctx
    mbKarmaTop_ctx
    mbKarmaHist_ctx
    processKarma
    mbRoll_ctx
    mbFlip_ctx
    mbActive_ctx
    mbWhen_ctx
    mbWeatherCompare_ctx
    mbChoose_ctx
    mbMorse_ctx
    mbAbbrev_ctx
    mbCompare_ctx
    mbHeatmap_ctx
    mbMonthStats_ctx
    mbDefine_ctx
    mbTrivia_ctx
    mbTriviaScore_ctx
    checkTriviaAnswer
    mbLast_ctx
    mbPoll_ctx
    mbVote_ctx
    mbPollResult_ctx
    mbPollStop_ctx
    mbNote_ctx
    mbNotes_ctx
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
        $self->{logger}->log(1, "dbLogoutUsers() SQL prepare error : " . $DBI::errstrstr . " Query : " . $sLogoutQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute()) {
        $self->{logger}->log(1, "dbLogoutUsers() SQL execute error : " . $DBI::errstrstr . "(" . $DBI::errstr . ") Query : " . $sLogoutQuery)
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
            $self->{logger}->log(1, "userOnJoin() SQL prepare error: " . $DBI::errstrstr . " Query: $sql")
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
            $self->{logger}->log(1, "userOnJoin() SQL execute error: " . $DBI::errstrstr . " Query: $sql")
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
        $self->{logger}->log(1, "userOnJoin() channel SQL prepare error: " . $DBI::errstrstr . " Query: $sql_channel")
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
        $self->{logger}->log(1, "userOnJoin() channel SQL execute error: " . $DBI::errstrstr . " Query: $sql_channel")
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
        $self->{logger}->log(1, "getIdUserLevel() SQL prepare error : " . $DBI::errstrstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sLevel)) {
        $self->{logger}->log(1, "getIdUserLevel() SQL execute error : " . $DBI::errstrstr . " Query : " . $sQuery)
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
        $self->{logger}->log(1, "getLevelUser() SQL prepare error : " . $DBI::errstrstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUserHandle)) {
        $self->{logger}->log(1, "getLevelUser() SQL execute error : " . $DBI::errstrstr . " Query : " . $sQuery)
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
        $self->{logger}->log(1, "userCstat_ctx() SQL Error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "getUserLevelDesc() SQL prepare error : " . $DBI::errstrstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($level)) {
        $self->{logger}->log(1, "getUserLevelDesc() SQL execute error : " . $DBI::errstrstr . " Query : " . $sQuery)
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
        $self->{logger}->log(1, "userInfo_ctx() SQL Error: $DBI::errstrstr | Query: $sQuery");
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
            $self->{logger}->log(1, "userInfo_ctx() hostmask SQL Error: $DBI::errstrstr")
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
        $self->{logger}->log(1, "addUserHost_ctx() SQL Error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "addUserHost_ctx() SQL Insert Error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "getUserChannelLevel() SQL prepare error : " . $DBI::errstrstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sChannel, $id_user)) {
        $self->{logger}->log(1, "getUserChannelLevel() SQL execute error : " . $DBI::errstrstr . " Query : " . $sQuery)
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
            $self->{logger}->log(1, "userModinfo_ctx(): issuer SQL prepare error: $DBI::errstrstr Query: $sql")
                if $self->{logger};
            return (undef, "prepare");
        }

        unless ($sth->execute($id_channel, $handle)) {
            $self->{logger}->log(1, "userModinfo_ctx(): issuer SQL execute error: $DBI::errstrstr Query: $sql")
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
            $self->{logger}->log(1, "userModinfo_ctx(): target SQL prepare error: $DBI::errstrstr Query: $sql")
                if $self->{logger};
            return (undef, undef, "prepare");
        }

        unless ($sth->execute($id_channel, $handle)) {
            $self->{logger}->log(1, "userModinfo_ctx(): target SQL execute error: $DBI::errstrstr Query: $sql")
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
            $self->{logger}->log(1, "userModinfo_ctx(): update SQL prepare error: $DBI::errstrstr Query: $sql")
                if $self->{logger};
            return 0;
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "userModinfo_ctx(): update SQL execute error: $DBI::errstrstr Query: $sql")
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
        $self->{logger}->log(1, "userTopSay_ctx() SQL Error: $DBI::errstrstr Query: $sql");
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
        $self->{logger}->log(1, "userGreet_ctx() SQL Error: $DBI::errstrstr Query: $sql");
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
    # If seen <nick> #channel was requested, keep the persisted lookup scoped
    # to that channel too. Otherwise, keep the historical global lookup.
    my $seen_row;
    {
        my ($sql, @bind);

        if (defined($chan_for_part) && $chan_for_part ne '') {
            $sql = q{
                SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                       seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
                FROM USER_SEEN
                WHERE nick = ? AND channel = ?
                LIMIT 1
            };
            @bind = ($targetNick, $chan_for_part);
        }
        else {
            $sql = q{
                SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                       seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
                FROM USER_SEEN
                WHERE nick = ?
                LIMIT 1
            };
            @bind = ($targetNick);
        }

        my $sth = $self->{dbh}->prepare($sql);
        if ($sth && $sth->execute(@bind)) {
            $seen_row = $sth->fetchrow_hashref;
            $sth->finish;
        }
    }

    # --- 2. Fallback: CHANNEL_LOG events (older data pre-USER_SEEN) ---
    my ($quit, $part, $chanlog);

    unless ($seen_row) {
        my $id_channel = 0;

        if (defined $chan_for_part) {
            my $channel_obj = $self->{channels}{$chan_for_part}
                           || $self->{channels}{lc($chan_for_part)};
            $id_channel = eval { $channel_obj->get_id } || 0;
        }

        if (defined($chan_for_part) && $id_channel) {
            my $sth_chanlog = $self->{dbh}->prepare(
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext, event_type
                 FROM CHANNEL_LOG
                 WHERE id_channel = ?
                   AND nick = ?
                   AND event_type IN ('message', 'join', 'part', 'quit')
                 ORDER BY ts DESC LIMIT 1"
            );

            if ($sth_chanlog && $sth_chanlog->execute($id_channel, $targetNick)) {
                if (my $r = $sth_chanlog->fetchrow_hashref) {
                    $chanlog = {
                        ts    => $r->{ts},
                        uts   => $r->{uts} // 0,
                        host  => $r->{userhost} // '',
                        text  => $r->{publictext} // '',
                        event => $r->{event_type} // 'message',
                    };
                }
                $sth_chanlog->finish;
            }
        }
        else {
            my $sth_quit = $self->{dbh}->prepare(
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
                 FROM CHANNEL_LOG
                 WHERE nick = ? AND event_type = 'quit'
                 ORDER BY ts DESC LIMIT 1"
            );

            if ($sth_quit && $sth_quit->execute($targetNick)) {
                if (my $r = $sth_quit->fetchrow_hashref) {
                    $quit = {
                        ts   => $r->{ts},
                        uts  => $r->{uts} // 0,
                        host => $r->{userhost} // '',
                        text => $r->{publictext} // '',
                    };
                }
                $sth_quit->finish;
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
    } elsif ($chanlog) {
        my $host = $fmt_host->($chanlog->{host});
        my $txt  = $chanlog->{text} // '';
        my $ev   = $chanlog->{event} // 'message';
        my $ago  = $fmt_ago->($chanlog->{uts});

        if ($ev eq 'message') {
            $msg = "$targetNick ($host) was last seen $ago on $chan_for_part"
                 . ($txt ne '' ? " saying: $txt" : '');
        }
        elsif ($ev eq 'join') {
            $msg = "$targetNick ($host) was last seen joining $chan_for_part $ago";
        }
        elsif ($ev eq 'part') {
            $msg = "$targetNick ($host) was last seen parting $chan_for_part $ago"
                 . ($txt ne '' ? " ($txt)" : '');
        }
        elsif ($ev eq 'quit') {
            $msg = "$targetNick ($host) was last seen quitting $ago"
                 . ($txt ne '' ? " ($txt)" : '');
        }
        else {
            $msg = "$targetNick ($host) was last seen $ago on $chan_for_part ($ev)";
        }
    } elsif ($quit || $part) {
        # Fallback CHANNEL_LOG path for global seen lookup.
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
            $self->{logger}->log(1, "mbModUser_ctx() SQL prepare error: $DBI::errstrstr Query: $sql")
                if $self->{logger};
            return (undef, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "mbModUser_ctx() SQL execute error: $DBI::errstrstr Query: $sql")
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
            $self->{logger}->log(1, "mbModUser_ctx() update SQL prepare error: $DBI::errstrstr Query: $sql")
                if $self->{logger};
            return (0, "prepare");
        }

        unless ($sth->execute(@bind)) {
            $self->{logger}->log(1, "mbModUser_ctx() update SQL execute error: $DBI::errstrstr Query: $sql")
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
        $self->{logger}->log(1, "SQL Error : " . $DBI::errstrstr . " Query : " . $sQuery);
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
            $self->{logger}->log(1, "userBirthday_ctx() SQL Error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "_birthday_add_ctx() SQL error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "_birthday_del_ctx() SQL error: $DBI::errstrstr");
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
        $self->{logger}->log(1, "_birthday_next_ctx() SQL error: $DBI::errstrstr");
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




# ---------------------------------------------------------------------------
# mbStats_ctx — !stats [nick]
# Show IRC activity stats for a nick: message count, last seen, join date.
# ---------------------------------------------------------------------------
sub mbStats_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $target = $args[0] ? lc($args[0]) : lc($nick);

    # Message count + last message on this channel
    my $sth = $self->{dbh}->prepare(q{
        SELECT COUNT(*)  AS msg_count,
               MAX(ts)  AS last_msg,
               MIN(ts)  AS first_seen
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my $msg_row = $sth->fetchrow_hashref;
    $sth->finish;

    my $msg_count  = $msg_row->{msg_count}  // 0;
    my $last_msg   = $msg_row->{last_msg}   // 'never';
    my $first_seen = $msg_row->{first_seen} // undef;

    # A1: total messages on channel for percentage (global, no period filter)
    my $sth_tot = $self->{dbh}->prepare(q{
        SELECT COUNT(*) AS total
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
    });
    my $total = 0;
    if ($sth_tot && $sth_tot->execute($channel)) {
        my $r = $sth_tot->fetchrow_hashref;
        $total = $r->{total} // 0;
        $sth_tot->finish;
    }
    my $pct = ($total > 0 && $msg_count > 0)
        ? sprintf(" (%.1f%%)", 100 * $msg_count / $total) : '';

    # S7/fix: fetch karma score for inline display in !stats
    my $karma_str = '';
    {
        my $dbh_k = eval { $self->{db}->ensure_connected } // $self->{dbh};  # C3/fix
        my $sth_chan2 = $dbh_k->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        if ($sth_chan2 && $sth_chan2->execute($channel)) {
            my $rc = $sth_chan2->fetchrow_hashref; $sth_chan2->finish;
            if ($rc) {
                my $sth_k = $dbh_k->prepare(
                    'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
                if ($sth_k && $sth_k->execute($rc->{id_channel}, lc($target))) {
                    my $kr = $sth_k->fetchrow_hashref; $sth_k->finish;
                    if ($kr) {
                        my $sign = $kr->{score} > 0 ? '+' : '';
                        $karma_str = " | karma ${sign}$kr->{score}";
                    }
                }
            }
        }
    }

    # Last seen (USER_SEEN)
    my $sth2 = $self->{dbh}->prepare(q{
        SELECT seen_at, event_type FROM USER_SEEN WHERE nick = ? LIMIT 1
    });
    unless ($sth2 && $sth2->execute($target)) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my $seen_row  = $sth2->fetchrow_hashref;
    $sth2->finish;

    my $seen_at   = $seen_row->{seen_at}    // 'never';
    my $seen_type = $seen_row->{event_type} // '';

    # User level (if registered)
    my $level_desc = '';
    my $id_user    = getIdUser($self, $target);
    if ($id_user) {
        my $sth3 = $self->{dbh}->prepare(q{
            SELECT ul.description
            FROM USER u
            JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
            WHERE u.id_user = ?
        });
        if ($sth3 && $sth3->execute($id_user)) {
            my $lvl = $sth3->fetchrow_hashref;
            $level_desc = " (" . ($lvl->{description} // '?') . ")" if $lvl;
            $sth3->finish;
        }
    }

    # Format output
    my $out = sprintf("%s%s: %d message%s%s on %s",
        $target, $level_desc,
        $msg_count, ($msg_count != 1 ? "s" : ""),
        $pct, $channel
    );
    $out .= " | first seen: $first_seen" if $first_seen && $msg_count > 0;
    $out .= " | last msg: $last_msg"   if $msg_count > 0;
    $out .= " | last seen: $seen_at ($seen_type)" if $seen_at ne 'never';
    $out .= $karma_str if $karma_str;
    $out .= " | not in database" unless $id_user || $msg_count;

    botPrivmsg($self, $channel, $out);
    logBot($self, $ctx->message, $channel, "stats", $target);
    return 1;
}



# ---------------------------------------------------------------------------
# mbTop_ctx — !top [n]
# Show the top N most active nicks on the current channel (default 5, max 10).
# ---------------------------------------------------------------------------
sub mbTop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $n = 5;
    if (@args && $args[0] =~ /^\d+$/) {
        $n = int(shift @args);
        $n = 1  if $n < 1;
        $n = 10 if $n > 10;
    }

    # A4: optional period filter e.g. !top 5 30d / 7d / 24h
    my $period_sql  = '';
    my $period_label = '';
    if (@args && $args[0] =~ /^(\d+)(d|h)$/i) {
        my ($val, $unit) = ($1, lc $2);
        my $interval = $unit eq 'h' ? "$val HOUR" : "$val DAY";
        $period_sql   = "AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";
        $period_label = " (last ${val}${unit})";
    }

    # A2: fetch total first for percentage
    my $sth_tot = $self->{dbh}->prepare(q{
        SELECT COUNT(*) AS total
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
    });
    my $total = 0;
    if ($sth_tot && $sth_tot->execute($channel)) {
        my $r = $sth_tot->fetchrow_hashref;
        $total = $r->{total} // 0;
        $sth_tot->finish;
    }

    my $sth = $self->{dbh}->prepare(
        "SELECT cl.nick, COUNT(*) AS msg_count"
        . " FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? $period_sql"
        . " GROUP BY cl.nick ORDER BY msg_count DESC LIMIT ?"
    );
    unless ($sth && $sth->execute($channel, $n)) {
        botNotice($self, $nick, "Database error.");
        return;
    }

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }
    $sth->finish;

    unless (@rows) {
        botPrivmsg($self, $channel, "No data for $channel yet.");
        return 1;
    }

    botPrivmsg($self, $channel, "Top $n on $channel$period_label:");
    my $rank = 1;
    for my $row (@rows) {
        my $msgs = $row->{msg_count};
        my $pct = $total > 0 ? sprintf(" (%.1f%%)", 100 * $msgs / $total) : "";
        botPrivmsg($self, $channel, sprintf("  %d. %-16s %d msg%s%s",
            $rank++, $row->{nick}, $msgs, ($msgs != 1 ? "s" : ""), $pct));
    }

    logBot($self, $ctx->message, $channel, "top", "$n");
    return 1;
}


# ---------------------------------------------------------------------------
# mb8ball_ctx --- !8ball <question>
# ---------------------------------------------------------------------------
sub mb8ball_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $question = join(' ', @args);
    $question =~ s/^\s+|\s+$//g;

    unless ($question ne '') {
        botNotice($self, $nick, "Syntax: 8ball <question>");
        return;
    }

    # J3: French answers if main.LANG = fr
    my $lang_8b = eval { $self->{conf}->get('main.LANG') } // 'en';

    my @answers = (
        'It is certain.',
        'It is decidedly so.',
        'Without a doubt.',
        'Yes, definitely.',
        'You may rely on it.',
        'As I see it, yes.',
        'Most likely.',
        'Outlook good.',
        'Yes.',
        'Signs point to yes.',
        'Reply hazy, try again.',
        'Ask again later.',
        'Better not tell you now.',
        'Cannot predict now.',
        'Concentrate and ask again.',
        "Don't count on it.",
        'My reply is no.',
        'My sources say no.',
        'Outlook not so good.',
        'Very doubtful.',
    );
    my @answers_fr = (
        'C\'est certain.',
        'C\'est absolument Ã§a.',
        'Sans aucun doute.',
        'Oui, dÃ©finitivement.',
        'Tu peux compter dessus.',
        'Comme je le vois, oui.',
        'TrÃ¨s probablement.',
        'Les perspectives sont bonnes.',
        'Oui.',
        'Les signes indiquent que oui.',
        'Flou, essaie encore.',
        'Demande plus tard.',
        'Mieux vaut ne pas te le dire maintenant.',
        'Je ne peux pas prÃ©dire Ã§a.',
        'Concentre-toi et redemande.',
        'N\'y compte pas.',
        'Ma rÃ©ponse est non.',
        'Mes sources disent non.',
        'Les perspectives ne sont pas bonnes.',
        'TrÃ¨s douteux.',
    );
    @answers = @answers_fr if $lang_8b eq 'fr';

    # L2: Spanish answers if main.LANG = es
    my @answers_es = (
        'Definitivamente sÃ­.',
        'Por supuesto.',
        'Sin ninguna duda.',
        'SÃ­, definitivamente.',
        'Puedes contar con ello.',
        'Las perspectivas son buenas.',
        'Muy probablemente.',
        'SÃ­.',
        'Los indicios apuntan que sÃ­.',
        'Como yo lo veo, sÃ­.',
        'La respuesta es incierta, intenta de nuevo.',
        'Pregunta mÃ¡s tarde.',
        'Mejor no responderte ahora.',
        'No puedo predecirlo.',
        'ConcÃ©ntrate y pregunta de nuevo.',
        'No cuentes con ello.',
        'Mi respuesta es no.',
        'Mis fuentes dicen que no.',
        'Las perspectivas no son buenas.',
        'Muy dudoso.',
    );
    @answers = @answers_es if $lang_8b eq 'es';


    my $answer = $answers[int(rand(scalar @answers))];
    botPrivmsg($self, $channel, "\x038\x02[8ball]\x0f $nick: $answer");
    logBot($self, $ctx->message, $channel, '8ball', $question);
    return 1;
}

# ---------------------------------------------------------------------------
# mbRemind_ctx --- !remind <nick> <message>
# Store a memo in DB; deliver it next time the target nick speaks.
# Requires table: CREATE TABLE REMINDERS (
#   id_reminder INT AUTO_INCREMENT PRIMARY KEY,
#   id_channel INT NOT NULL,
#   from_nick VARCHAR(64) NOT NULL,
#   to_nick VARCHAR(64) NOT NULL,
#   message VARCHAR(512) NOT NULL,
#   created_at DATETIME DEFAULT NOW(),
#   delivered TINYINT DEFAULT 0
# );
# ---------------------------------------------------------------------------
sub mbRemind_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # V9: !remind show — see reminders set FOR the caller (by others)
    if (@args && lc($args[0]) eq 'show') {
        my $sth_s = $self->{dbh}->prepare(q{
            SELECT r.id, r.from_nick, r.message, r.created_at
            FROM REMINDERS r
            JOIN CHANNEL c ON c.id_channel = r.id_channel
            WHERE c.name = ? AND r.to_nick = ? AND r.delivered = 0
            ORDER BY r.id ASC LIMIT 10
        });
        if ($sth_s && $sth_s->execute($channel, lc($nick))) {
            my @rows;
            while (my $r = $sth_s->fetchrow_hashref) { push @rows, $r; }
            $sth_s->finish;
            if (@rows) {
                botNotice($self, $nick, 'Reminders set for you:');
                for my $r (@rows) {
                    botNotice($self, $nick, "  [#$r->{id}] from $r->{from_nick}: $r->{message}");
                }
            } else {
                botNotice($self, $nick, 'No pending reminders set for you.');
            }
        }
        return 1;
    }

    # K1: subcommands list and cancel
    if (@args && lc($args[0]) eq 'list') {
        my $sth_l = $self->{dbh}->prepare(q{
            SELECT r.id, r.to_nick, r.message, r.created_at
            FROM REMINDERS r
            JOIN CHANNEL c ON c.id_channel = r.id_channel
            WHERE c.name = ? AND r.from_nick = ? AND r.delivered = 0
            ORDER BY r.id ASC LIMIT 10
        });
        if ($sth_l && $sth_l->execute($channel, lc($nick))) {
            my @rows;
            while (my $r = $sth_l->fetchrow_hashref) { push @rows, $r; }
            $sth_l->finish;
            if (@rows) {
                botNotice($self, $nick, 'Pending reminders:');
                for my $r (@rows) {
                    botNotice($self, $nick,
                        "  [#$r->{id}] for $r->{to_nick}: $r->{message}");
                }
            } else {
                botNotice($self, $nick, 'No pending reminders.');
            }
        }
        return 1;
    }

    if (@args && lc($args[0]) eq 'cancel') {
        my $id = $args[1];
        unless (defined $id && $id =~ /^\d+$/) {
            botNotice($self, $nick, 'Syntax: remind cancel <id>  (use remind list)');
            return;
        }
        my $sth_del = $self->{dbh}->prepare(q{
            DELETE FROM REMINDERS
            WHERE id = ? AND from_nick = ? AND delivered = 0
        });
        if ($sth_del && $sth_del->execute($id, lc($nick))) {
            my $rows = $sth_del->rows; $sth_del->finish;
            if ($rows > 0) {
                botNotice($self, $nick, "Reminder #$id cancelled.");
                logBot($self, $ctx->message, $channel, 'remind_cancel', $id);
            } else {
                botNotice($self, $nick, "Reminder #$id not found or already delivered.");
            }
        }
        return 1;
    }

    # X6: !remind ! <nick> <msg> — high-priority reminder
    my $remind_urgent = (@args && $args[0] eq '!') ? do { shift @args; 1 } : 0;
    my $target  = shift @args;
    my $message = join(' ', @args);
    $message =~ s/^\s+|\s+$//g;
    $message = '[!] ' . $message if $remind_urgent;

    unless (defined $target && $target ne '' && $message ne '') {
        botNotice($self, $nick, "Syntax: remind <nick> <message>  |  remind list  |  remind cancel <id>");
        return;
    }

    if (length($message) > 512) {
        botNotice($self, $nick, "Message too long (max 512 chars).");
        return;
    }

    if (lc($target) eq lc($nick)) {
        botNotice($self, $nick, "You can't remind yourself.");
        return;
    }

    # Q2: parse optional delay prefix — 'dans 2h', 'in 30m', 'dans 1h30'
    my $delay_secs = 0;
    if ($message =~ s/^(?:dans|in)\s+(\d+)h(?:(\d+)m)?\s+//i) {
        $delay_secs = $1 * 3600 + ($2 // 0) * 60;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)m\s+//i) {
        $delay_secs = $1 * 60;
    } elsif ($message =~ s/^tomorrow\s+//i) {
        $delay_secs = 86400;
    }
    if ($delay_secs > 0) {
        # Prefix message with delivery timestamp so deliverReminders can filter
        my $deliver_at = time() + $delay_secs;
        $message = "[at:$deliver_at] $message";
    }

    # Fetch id_channel inline (getIdChannel is in ChannelCommands scope)
    my $sth_chan = $self->{dbh}->prepare(
        'SELECT id_channel FROM CHANNEL WHERE name = ?'
    );
    my $id_channel;
    if ($sth_chan && $sth_chan->execute($channel)) {
        my $r = $sth_chan->fetchrow_hashref;
        $sth_chan->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    unless ($id_channel) {
        botNotice($self, $nick, "Channel not found.");
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
        VALUES (?, ?, ?, ?)
    });
    unless ($sth && $sth->execute($id_channel, $nick, lc($target), $message)) {
        $self->{logger}->log(1, "mbRemind_ctx() SQL error: $DBI::errstrstr");
        botNotice($self, $nick, "Database error.");
        return;
    }
    $sth->finish;

    # S2: include delay info in confirmation
    my $delay_info = $delay_secs > 0
        ? ' (due in ' . Mediabot::UserCommands::_seconds_to_human($delay_secs) . ')'
        : '';
    botNotice($self, $nick, "Reminder set for $target$delay_info.");
    logBot($self, $ctx->message, $channel, 'remind', "$target: $message");
    return 1;
}

# ---------------------------------------------------------------------------
# deliverReminders($self, $nick, $channel)
# Called from mbCommandPublic on every message; delivers pending reminders.
# ---------------------------------------------------------------------------
sub deliverReminders {
    my ($self, $nick, $channel) = @_;

    $self->{logger}->log(4, "deliverReminders() nick=$nick chan=$channel");
    # Q2: helper to check if a remind message has a future [at:TS] tag
    # Returns undef if not yet due, or stripped message if due/no tag
    # (Inline — not a separate sub to avoid scope issues)

    # S3/fix: ensure DB connection alive before using dbh
    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    return unless $dbh;
    my $sth_dc = $dbh->prepare(
        'SELECT id_channel FROM CHANNEL WHERE name = ?'
    );
    my $id_channel;
    if ($sth_dc && $sth_dc->execute($channel)) {
        my $r = $sth_dc->fetchrow_hashref;
        $sth_dc->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    return unless $id_channel;

    my $sth = $dbh->prepare(q{
        SELECT id_reminder, from_nick, message, created_at
        FROM REMINDERS
        WHERE id_channel = ? AND to_nick = ? AND delivered = 0
        ORDER BY created_at ASC
        LIMIT 3
    });
    return unless $sth && $sth->execute($id_channel, lc($nick));

    my @pending;
    while (my $row = $sth->fetchrow_hashref) { push @pending, $row; }
    $sth->finish;
    return unless @pending;

    for my $r (@pending) {
        # Q2: skip reminders with [at:TS] tag if not yet due
        if ($r->{message} =~ /^\[at:(\d+)\]/) {
            next if time() < $1;
            $r->{message} =~ s/^\[at:\d+\]\s*//;
        }
        botPrivmsg($self, $channel,
            "$nick: reminder from $r->{from_nick} ($r->{created_at}): $r->{message}");
        my $sth_up = $dbh->prepare(q{
            UPDATE REMINDERS SET delivered = 1 WHERE id_reminder = ?
        });
        if ($sth_up) { $sth_up->execute($r->{id_reminder}); $sth_up->finish; }
    }
}

# ---------------------------------------------------------------------------
# mbRemindList_ctx --- !remindlist
# Show pending reminders sent by the calling nick.
# ---------------------------------------------------------------------------
sub mbRemindList_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my $sth = $self->{dbh}->prepare(q{
        SELECT r.id_reminder, r.to_nick, r.message, r.created_at
        FROM REMINDERS r
        JOIN CHANNEL c ON c.id_channel = r.id_channel
        WHERE r.from_nick = ? AND c.name = ? AND r.delivered = 0
        ORDER BY r.created_at ASC
    });
    unless ($sth && $sth->execute($nick, $channel)) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botNotice($self, $nick, 'No pending reminders.');
        return 1;
    }

    botNotice($self, $nick, scalar(@rows) . ' pending reminder(s):');
    for my $r (@rows) {
        # T5: show remaining delay if [at:TS] tag in message
        my $msg_t5 = $r->{message} // '';
        my $due_t5 = '';
        if ($msg_t5 =~ /^\[at:(\d+)\]\s*/) {
            my $sl = $1 - time();
            $due_t5 = $sl > 0 ? ' [due in ' . _seconds_to_human($sl) . ']' : ' [overdue]';
            $msg_t5 =~ s/^\[at:\d+\]\s*//;
        }
        botNotice($self, $nick, sprintf('  #%d -> %s: "%s" (%s)',
            $r->{id_reminder}, $r->{to_nick} . $due_t5,
            $msg_t5, $r->{created_at}));
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbRemindCancel_ctx --- !remind cancel <id>
# Cancel a pending reminder by ID (must be from the calling nick).
# ---------------------------------------------------------------------------
sub mbRemindCancel_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $id = shift @args;
    unless (defined $id && $id =~ /^\d+$/) {
        botNotice($self, $nick, 'Syntax: remind cancel <id>  (see !remindlist)');
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        UPDATE REMINDERS SET delivered = 2
        WHERE id_reminder = ? AND from_nick = ? AND delivered = 0
    });
    unless ($sth && $sth->execute($id, $nick)) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my $rows = $sth->rows;
    $sth->finish;

    if ($rows > 0) {
        botNotice($self, $nick, "Reminder #$id cancelled.");
    } else {
        botNotice($self, $nick, "Reminder #$id not found or already delivered.");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbSlap_ctx --- !slap [nick]
# Classic IRC slap via CTCP ACTION.
# ---------------------------------------------------------------------------
sub mbSlap_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $target = $args[0] // $nick;
    $target = $nick if $target eq '';

    my @weapons = (
        'a large trout',
        'a wet noodle',
        'a rubber chicken',
        'a copy of the Camel Book',
        'a frozen pizza',
        'a soggy newspaper',
        'a 10kg bag of CPAN modules',
        'a Perl regex manual',
    );
    my $weapon = $weapons[int(rand(scalar @weapons))];

    botAction($self, $channel, "slaps $target with $weapon");
    logBot($self, $ctx->message, $channel, 'slap', $target);
    return 1;
}

# ---------------------------------------------------------------------------
# mbCalcLast_ctx --- !calclast [n]
# Show the last N calc results for the calling nick (default 3).
# ---------------------------------------------------------------------------
sub mbCalcLast_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my $history = $self->{_calc_history}{$nick} // [];
    unless (@$history) {
        botNotice($self, $nick, 'No calc history yet.');
        return 1;
    }
    botNotice($self, $nick, 'Last calc(s):');
    for my $entry (@$history) {
        botNotice($self, $nick, "  $entry");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbWordCount_ctx --- !wordcount [nick]
# Count distinct words spoken by a nick on the channel.
# ---------------------------------------------------------------------------
sub mbWordCount_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # S4: !karma log [nick] — show karma history from in-memory ring buffer
    if (@args && lc($args[0]) eq 'log') {
        shift @args;
        my $filter = @args ? lc($args[0]) : undef;
        my $klog   = $self->{_karma_log}{$channel} // [];
        unless (@$klog) {
            botPrivmsg($self, $channel, "$nick: no karma history on $channel."); return 1;
        }
        my @entries = reverse @$klog;
        @entries = grep { lc($_->{nick}) eq $filter } @entries if $filter;
        @entries = @entries[0..4] if @entries > 5;
        unless (@entries) {
            botPrivmsg($self, $channel, "$nick: no karma history for '$filter'."); return 1;
        }
        for my $e (@entries) {
            my $sign = $e->{score} > 0 ? '+' : '';
            my $ago  = _seconds_to_human(time() - $e->{ts});
            botPrivmsg($self, $channel,
                "  $e->{nick} $e->{delta} (now ${sign}$e->{score}) by $e->{from} — $ago ago");
        }
        return 1;
    }

    # P1: !karma top [n] — alias for !karmatop
    if (@args && lc($args[0]) eq 'top') {
        shift @args;
        $ctx->{_args} = \@args;
        return mbKarmaTop_ctx($ctx);
    }

    my $target  = $args[0] ? lc($args[0]) : lc($nick);

    my $sth = $self->{dbh}->prepare(q{
        SELECT publictext FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ? AND publictext IS NOT NULL
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my %words;
    while (my ($text) = $sth->fetchrow_array) {
        $words{lc $_}++ for split /\W+/, ($text // '');
    }
    $sth->finish;
    delete $words{''};

    my $total  = scalar keys %words;
    my $msgs   = scalar grep { 1 } values %words;
    botPrivmsg($self, $channel, "$target: $total distinct word(s) on $channel");
    return 1;
}

# ---------------------------------------------------------------------------
# mbAlias_ctx --- !alias <alias> <command>
# Create/delete/list IRC command aliases (Owner only). Stored in BOT_ALIAS.
# Requires: CREATE TABLE BOT_ALIAS (
#   id_alias INT AUTO_INCREMENT PRIMARY KEY,
#   alias VARCHAR(32) NOT NULL UNIQUE,
#   command VARCHAR(64) NOT NULL,
#   created_by VARCHAR(64),
#   created_at DATETIME DEFAULT NOW()
# ) ENGINE=InnoDB;
# ---------------------------------------------------------------------------
sub mbAlias_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Owner');

    # B6/fix: lazy-load alias cache from DB on first use
    unless ($self->{_alias_cache_loaded}) {
        my $sth_l = $self->{dbh}->prepare('SELECT alias, command FROM BOT_ALIAS');
        if ($sth_l && $sth_l->execute()) {
            while (my $r = $sth_l->fetchrow_hashref) {
                $self->{_alias_cache}{ $r->{alias} } = $r->{command};
            }
            $sth_l->finish;
        }
        $self->{_alias_cache_loaded} = 1;
    }

    my $subcmd = lc(shift @args // '');

    if ($subcmd eq 'list') {
        my $sth = $self->{dbh}->prepare('SELECT alias, command FROM BOT_ALIAS ORDER BY alias');
        unless ($sth && $sth->execute()) {
            botNotice($self, $nick, 'Database error.'); return;
        }
        my @rows;
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
        $sth->finish;
        unless (@rows) { botNotice($self, $nick, 'No aliases defined.'); return 1; }
        botNotice($self, $nick, $_->{alias} . ' => ' . $_->{command}) for @rows;
        return 1;
    }

    if ($subcmd eq 'del') {
        my $alias = lc(shift @args // '');
        unless ($alias =~ /^[a-z0-9_-]+$/) {
            botNotice($self, $nick, 'Syntax: alias del <alias>'); return;
        }
        my $sth = $self->{dbh}->prepare('DELETE FROM BOT_ALIAS WHERE alias = ?');
        if ($sth && $sth->execute($alias) && $sth->rows > 0) {
            $sth->finish;
            delete $self->{_alias_cache}{$alias};
            botNotice($self, $nick, "Alias '$alias' deleted.");
        } else {
            $sth->finish if $sth;
            botNotice($self, $nick, "Alias '$alias' not found.");
        }
        return 1;
    }

    # alias set <alias> <command>
    my $alias   = lc($subcmd);
    my $command = lc(shift @args // '');
    unless ($alias =~ /^[a-z0-9_-]{1,32}$/ && $command =~ /^[a-z0-9_-]{1,64}$/) {
        botNotice($self, $nick, 'Syntax: alias <alias> <command> | alias del <alias> | alias list');
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        INSERT INTO BOT_ALIAS (alias, command, created_by)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE command = VALUES(command), created_by = VALUES(created_by)
    });
    unless ($sth && $sth->execute($alias, $command, $nick)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    $sth->finish;
    $self->{_alias_cache}{$alias} = $command;
    botNotice($self, $nick, "Alias '$alias' => '$command' set.");
    return 1;
}

# ---------------------------------------------------------------------------
# mbStreak_ctx --- !streak [nick]
# Count consecutive days of activity on the channel.
# ---------------------------------------------------------------------------
sub mbStreak_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = $args[0] ? lc($args[0]) : lc($nick);

    my $sth = $self->{dbh}->prepare(q{
        SELECT DISTINCT DATE(ts) AS day
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
        ORDER BY day DESC
        LIMIT 365
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my @days;
    while (my ($day) = $sth->fetchrow_array) { push @days, $day; }
    $sth->finish;

    unless (@days) {
        botPrivmsg($self, $channel, "$target: no activity found on $channel.");
        return 1;
    }

    # Count consecutive days from most recent
    my $streak = 1;
    for my $i (1 .. $#days) {
        use Time::Piece;
        my $d1 = Time::Piece->strptime($days[$i-1], '%Y-%m-%d');
        my $d2 = Time::Piece->strptime($days[$i],   '%Y-%m-%d');
        last unless int(($d1 - $d2)->days + 0.5) == 1;  # B4/fix: ->days is float
        $streak++;
    }

    botPrivmsg($self, $channel,
        "$target: $streak consecutive day(s) active on $channel (most recent: $days[0])");
    logBot($self, $ctx->message, $channel, 'streak', $target);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarma_ctx --- !karma [nick]
# Show karma for a nick. nick++ / nick-- in messages auto-increment.
# Requires: CREATE TABLE KARMA (
#   id_karma INT AUTO_INCREMENT PRIMARY KEY,
#   id_channel INT NOT NULL,
#   nick VARCHAR(64) NOT NULL,
#   score INT DEFAULT 0,
#   UNIQUE KEY uniq_chan_nick (id_channel, nick)
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
# ---------------------------------------------------------------------------
sub mbKarma_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = $args[0] ? lc($args[0]) : lc($nick);

    my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    my $id_channel;
    if ($sth_chan && $sth_chan->execute($channel)) {
        my $r = $sth_chan->fetchrow_hashref;
        $sth_chan->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    return unless $id_channel;

    my $sth = $self->{dbh}->prepare(q{
        SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($id_channel, $target)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    my $score = $row ? $row->{score} : 0;
    my $sign  = $score > 0 ? '+' : '';
    # Z1: show rank alongside score
    my $rank_z1 = '';
    eval {
        my $sth_r = $self->{dbh}->prepare(
            'SELECT COUNT(*)+1 AS r FROM KARMA WHERE id_channel=? AND score>?');
        if ($sth_r && $sth_r->execute($id_channel, $score)) {
            my $rr = $sth_r->fetchrow_hashref; $sth_r->finish;
            $rank_z1 = " (rank #$rr->{r})" if $rr && defined $rr->{r};
        }
    };
    botPrivmsg($self, $channel, "$target: karma ${sign}${score}${rank_z1}");
    logBot($self, $ctx->message, $channel, 'karma', $target);  # S2/fix
    return 1;
}

# ---------------------------------------------------------------------------
# processKarma($self, $nick, $channel, $text)
# Called from on_message_PRIVMSG. Detects nick++ / nick-- patterns.
# ---------------------------------------------------------------------------
sub processKarma {
    my ($self, $nick, $channel, $text) = @_;

    # fix: [^\s+\-]+ avoids greedy \S+ consuming the ++ before the pattern can catch it
    return unless defined $text && $text =~ /[^\s+\-]{2,}(\+\+|--)/;

    my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    return unless $sth_chan && $sth_chan->execute($channel);
    my $r = $sth_chan->fetchrow_hashref; $sth_chan->finish;
    my $id_channel = $r ? $r->{id_channel} : undef;
    return unless $id_channel;

    my $karma_hits = 0;  # C2/fix: cap at 3 karma changes per message
    while ($text =~ /([^\s+\-]{2,32})(\+\+|--)/g) {
        last if ++$karma_hits > 3;
        my ($target, $op) = (lc($1), $2);
        # Self-karma: block and notify
        if ($target eq lc($nick) || $target eq lc(do { (my $t = $nick) =~ s/\[.*?\]//g; $t })) {
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "$nick: you can't change your own karma.");
            next;
        }
        # Y2: explicit anti-self-vote guard with clear message
    if (lc($nick) eq lc($target)) {
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick: you can't vote for yourself.");
        $self->{metrics}->inc('mediabot_karma_selfvote_blocked') if $self->{metrics};
        next;
    }

    # U6: anti-spam cooldown — 30s between votes targeting the same nick
        my $cd_key = lc($nick) . ':' . lc($target);
        if (time() - ($self->{_karma_cooldown}{$channel}{$cd_key} // 0) < 30) {
            my $wait = 30 - (time() - ($self->{_karma_cooldown}{$channel}{$cd_key} // 0));
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "$nick: wait ${wait}s before voting for $target again.");
            next;
        }
        $self->{_karma_cooldown}{$channel}{$cd_key} = time();
    $self->{metrics}->inc('mediabot_karma_votes_total') if $self->{metrics};  # AA6
        my $delta = ($op eq '++') ? 1 : -1;
        my $sth = $self->{dbh}->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE score = score + ?
        });
        next unless $sth && $sth->execute($id_channel, $target, $delta, $delta);
        $sth->finish;

        # Fetch updated score
        my $sth2 = $self->{dbh}->prepare('SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
        if ($sth2 && $sth2->execute($id_channel, $target)) {
            my $row = $sth2->fetchrow_hashref; $sth2->finish;
            my $score = $row ? $row->{score} : $delta;
            my $sign  = $score > 0 ? '+' : '';

            # T4: compute rank on channel
            my $rank_str = '';
            eval {
                my $sth_rank = $self->{dbh}->prepare(
                    'SELECT COUNT(*)+1 AS rank FROM KARMA WHERE id_channel=? AND score>?'
                );
                if ($sth_rank && $sth_rank->execute($id_channel, $score)) {
                    my $rr = $sth_rank->fetchrow_hashref;
                    $sth_rank->finish;
                    $rank_str = " (rank #$rr->{rank})" if $rr && defined $rr->{rank};
                }
            };

            Mediabot::Helpers::botPrivmsg(
                $self,
                $channel,
                "$target\'s karma: ${sign}${score}${rank_str}"
            );
        # I4: append to in-memory karma log (ring buffer, max 20 per channel)
        my $klog = $self->{_karma_log}{$channel} //= [];
        push @$klog, {
            ts    => time(),
            nick  => $target,
            delta => ($op eq '++' ? '+1' : '-1'),
            score => $score,
            from  => $nick,
        };
        splice @$klog, 0, @$klog - 20 if @$klog > 20;
        # I8: persist to KARMA_LOG if table exists (graceful — skip on error)
        eval {
            my $sth_log = $self->{dbh}->prepare(q{
                INSERT IGNORE INTO KARMA_LOG
                    (id_channel, nick, delta, from_nick, score, ts)
                VALUES (?, ?, ?, ?, ?, NOW())
            });
            $sth_log->execute($id_channel, $target,
                ($op eq '++' ? 1 : -1), $nick, $score);
            $sth_log->finish;
        };  # silently ignore if KARMA_LOG table doesn't exist yet
        }
    }
}

# ---------------------------------------------------------------------------
# _seconds_to_human($secs) — convert seconds to '3h 14m' style string
# B19/fix: was missing, caused crash in mbKarmaHist_ctx
# ---------------------------------------------------------------------------
sub _seconds_to_human {
    my ($secs) = @_;
    $secs = int($secs // 0);
    return '0s' unless $secs > 0;
    my $d = int($secs / 86400); $secs %= 86400;
    my $h = int($secs / 3600);  $secs %= 3600;
    my $m = int($secs / 60);    $secs %= 60;
    my $s = $secs;
    return "${d}d ${h}h" if $d;
    return "${h}h ${m}m" if $h;
    return "${m}m ${s}s" if $m;
    return "${s}s";
}

# ---------------------------------------------------------------------------
# mbKarmaHist_ctx --- !karmahist [nick]
# Show the last karma changes on the channel (optionally filtered by nick).
# ---------------------------------------------------------------------------
sub mbKarmaHist_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $filter  = @args ? lc($args[0]) : undef;

    # I8: try DB first, fall back to in-memory ring buffer
    my @db_entries;
    eval {
        my $sth_ch = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        if ($sth_ch && $sth_ch->execute($channel)) {
            my $rc = $sth_ch->fetchrow_hashref; $sth_ch->finish;
            if ($rc) {
                my $sth_hl = $self->{dbh}->prepare(q{
                    SELECT nick, delta, from_nick, score,
                           UNIX_TIMESTAMP(ts) AS ts
                    FROM KARMA_LOG WHERE id_channel = ?
                    ORDER BY ts DESC LIMIT 20
                });
                if ($sth_hl && $sth_hl->execute($rc->{id_channel})) {
                    while (my $r = $sth_hl->fetchrow_hashref) {
                        push @db_entries, {
                            nick  => $r->{nick},
                            delta => ($r->{delta} > 0 ? '+1' : '-1'),
                            from  => $r->{from_nick},
                            score => $r->{score},
                            ts    => $r->{ts},
                        };
                    }
                    $sth_hl->finish;
                }
            }
        }
    };  # silently fall back to in-memory if KARMA_LOG not available
    my $klog_mem = $self->{_karma_log}{$channel} // [];
    my $klog = @db_entries ? \@db_entries : $klog_mem;
    unless (@$klog) {
        botPrivmsg($self, $channel, "$nick: no karma history yet on $channel.");
        return 1;
    }

    my @entries = reverse @$klog;  # most recent first
    if ($filter) {
        @entries = grep { lc($_->{nick}) eq $filter } @entries;
        unless (@entries) {
            botPrivmsg($self, $channel, "$nick: no karma history for '$filter' on $channel.");
            return 1;
        }
    }
    @entries = @entries[0..4] if @entries > 5;  # show last 5

    my $label = $filter ? "karma history for $filter" : "recent karma changes";
    botPrivmsg($self, $channel, "$nick: $label on $channel:");
    for my $e (@entries) {
        my $sign  = $e->{score} > 0 ? '+' : '';
        my $delta = $e->{delta};
        my $ago   = _seconds_to_human(time() - $e->{ts});
        botPrivmsg($self, $channel,
            "  $e->{nick} $delta (now ${sign}$e->{score}) by $e->{from} — $ago ago");
    }
    logBot($self, $ctx->message, $channel, 'karmahist', $filter // '');
    # L3: Prometheus counter for !karmahist
    $self->{metrics}->inc('mediabot_karmahist_requests_total') if $self->{metrics};
    return 1;
}

# ---------------------------------------------------------------------------
# mbLast_ctx --- !last <nick>
# Show the last message posted by a nick on the current channel.
# ---------------------------------------------------------------------------
sub mbLast_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, 'Syntax: last <nick>');
        return;
    }
    my $target = lc($args[0]);

    my $sth = $self->{dbh}->prepare(q{
        SELECT cl.publictext, cl.ts,
               TIMESTAMPDIFF(MINUTE, cl.ts, NOW()) AS minutes_ago
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.publictext IS NOT NULL AND cl.publictext != ''
        ORDER BY cl.ts DESC
        LIMIT 1
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botPrivmsg($self, $channel, "$target: no message found on $channel.");
        return 1;
    }

    my $ago = $row->{minutes_ago};
    my $ago_str = $ago < 60
        ? "${ago}m ago"
        : $ago < 1440
            ? sprintf('%dh %dm ago', int($ago/60), $ago%60)
            : sprintf('%dd %dh ago', int($ago/1440), int(($ago%1440)/60));

    botPrivmsg($self, $channel,
        "$target last said ($ago_str on $channel): \"$row->{publictext}\"");
    return 1;
}

# ---------------------------------------------------------------------------
# mbPoll_ctx --- !poll <question> | opt1 | opt2 ...
# mbVote_ctx --- !vote <n>

# ---------------------------------------------------------------------------
# mbPollStatus_ctx --- !pollstatus  (W8)
# Show live poll results without closing the poll.
# ---------------------------------------------------------------------------
sub mbPollStatus_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    my $total = scalar keys %{ $poll->{votes} };
    botPrivmsg($self, $channel, "\"$poll->{question}\" -- $total vote(s) so far:");
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $cnt = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        my $pct = $total > 0 ? int($cnt * 100 / $total) : 0;
        botPrivmsg($self, $channel, sprintf('  [%d] %s: %d (%d%%)',
            $idx+1, $poll->{options}[$idx], $cnt, $pct));
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbUnvote_ctx --- !unvote  (Y6)
# ---------------------------------------------------------------------------
sub mbUnvote_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $poll    = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    unless (exists $poll->{votes}{lc $nick}) {
        botNotice($self, $nick, 'You have not voted yet.'); return 1;
    }
    delete $poll->{votes}{lc $nick};
    my $total = scalar keys %{ $poll->{votes} };
    botPrivmsg($self, $channel,
        "$nick cancelled their vote ($total vote(s) remaining).");
    return 1;
}

sub mbPollExtend_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $extra   = ($args[0] // 0) =~ /^(\d+)$/ ? int($args[0]) : 60;
    $extra = 10 if $extra < 10; $extra = 600 if $extra > 600;
    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botPrivmsg($self, $channel, 'No active poll.'); return 1;
    }
    $poll->{deadline} = ($poll->{deadline} // time()) + $extra;
    Mediabot::Helpers::botPrivmsg($self, $channel,
        sprintf('Poll extended by %ds (%ds remaining).', $extra, $poll->{deadline} - time()));
    return 1;
}

# mbPollResult_ctx --- !pollresult
# mbPollStop_ctx --- !pollstop  (Master+)
# In-memory polls, one active per channel.
# ---------------------------------------------------------------------------
sub mbPoll_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $raw = join(' ', @args);
    # V2: optional leading number sets poll timeout (10–3600s, default 300)
    my $poll_timeout = 300;
    # BB7: optional 'weighted' keyword enables weighted voting mode
    my $poll_weighted = 0;
    if ($raw =~ s/^weighted\s+//i) { $poll_weighted = 1; }
    if ($raw =~ s/^(\d+)\s+//) {
        $poll_timeout = int($1); $poll_timeout = 10 if $poll_timeout < 10;
        $poll_timeout = 3600 if $poll_timeout > 3600;
    }
    my @parts = map { s/^\s+|\s+$//gr } split(/\|/, $raw);
    unless (@parts >= 3) {
        botNotice($self, $nick, 'Syntax: poll <question> | option1 | option2 ...');
        return;
    }

    my $question = shift @parts;
    # Z10: Prometheus counter for poll creation
    $self->{metrics}->inc('mediabot_poll_created_total') if $self->{metrics};
    # BB7: build weighted option list
    my @weighted_parts;
    for my $opt (@parts) {
        if ($poll_weighted && $opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 10) {
            push @weighted_parts, { label => $1, weight => int($2) };
        } else {
            push @weighted_parts, { label => $opt, weight => 1 };
        }
    }
    $self->{metrics}->inc('mediabot_poll_created_total') if $self->{metrics};
    $self->{_polls}{$channel} = {
        question => $question,
        options  => [ map { $_->{label}  } @weighted_parts ],
        weights  => [ map { $_->{weight} } @weighted_parts ],
        weighted => $poll_weighted,
        votes    => {},
        started  => time(),
        deadline => time() + $poll_timeout,  # V2: configurable timeout
        active   => 1,
    };
    my $opts = join('  ', map { '[' . ($_+1) . '] ' . $parts[$_] } 0..$#parts);
    botPrivmsg($self, $channel, "Poll: \"$question\"  $opts  -- vote with !vote <n>");
    logBot($self, $ctx->message, $channel, 'poll', $question);  # S2/fix
    return 1;
}

sub mbVote_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $poll = $self->{_polls}{$channel};
    if ($poll && $poll->{active} && time() > ($poll->{deadline} // 0)) {
        $poll->{active} = 0;
        botPrivmsg($self, $channel, 'Poll expired. Use !pollresult to see results.');
        return;
    }
    unless ($poll && $poll->{active}) {
        botNotice($self, $nick, 'No active poll on this channel.'); return;
    }

    my $n = $args[0] // '';
    unless ($n =~ /^\d+$/ && $n >= 1 && $n <= scalar @{ $poll->{options} }) {
        botNotice($self, $nick, 'Vote: use !vote <number> (1 to ' . scalar(@{ $poll->{options} }) . ')');
        return;
    }

    $poll->{votes}{lc $nick} = $n - 1;
    my $choice = $poll->{options}[$n-1];
    my $total  = scalar keys %{ $poll->{votes} };
    botPrivmsg($self, $channel, "$nick voted for \"$choice\" ($total vote(s) cast)");
    # Y9: Prometheus counter for poll votes
    $self->{metrics}->inc('mediabot_poll_votes_total') if $self->{metrics};

    # U3: show live tally after each vote
    my @tally;
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $cnt = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        my $pct = $total > 0 ? int($cnt * 100 / $total) : 0;
        push @tally, sprintf('[%d] %s: %d (%d%%)',
            $idx+1, $poll->{options}[$idx], $cnt, $pct);
    }
    botPrivmsg($self, $channel, 'Live tally: ' . join('  ', @tally));
    logBot($self, $ctx->message, $channel, 'vote', $choice);  # S2/fix
    return 1;
}

sub mbPollResult_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my $poll = $self->{_polls}{$channel};
    unless ($poll) {
        botNotice($self, $nick, 'No poll found for this channel.'); return;
    }

    my @options = @{ $poll->{options} };
    my %counts;
    $counts{ $poll->{votes}{$_} }++ for keys %{ $poll->{votes} };
    my $total = scalar keys %{ $poll->{votes} };

    my $status = $poll->{active} ? 'Active' : 'Closed';
    botPrivmsg($self, $channel, "$status poll: \"$poll->{question}\" ($total vote(s))");
    for my $i (0 .. $#options) {
        my $c   = $counts{$i} // 0;
        my $pct = $total > 0 ? sprintf('%.0f%%', 100 * $c / $total) : '0%';
        botPrivmsg($self, $channel,
            sprintf('  [%d] %-20s %d vote(s) (%s)', $i+1, $options[$i], $c, $pct));
    }
    logBot($self, $ctx->message, $channel, 'pollresult', '');  # Q1
    return 1;
}

sub mbPollStop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    return unless $ctx->require_level('Master');

    my $poll = $self->{_polls}{$channel};
    unless ($poll && $poll->{active}) {
        botNotice($self, $nick, 'No active poll.'); return;
    }
    $poll->{active} = 0;
    $self->{metrics}->inc('mediabot_poll_closed_total') if $self->{metrics};  # Z10
    botPrivmsg($self, $channel, "Poll closed. Use !pollresult to see results.");
    logBot($self, $ctx->message, $channel, 'pollstop', '');  # S2/fix
    return 1;
}

# ---------------------------------------------------------------------------
# mbNote_ctx --- !note <message>
# mbNotes_ctx --- !notes [del <id>]
# Personal notes stored in memory per nick.
# ---------------------------------------------------------------------------
sub mbNote_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $text = join(' ', @args);
    $text =~ s/^\s+|\s+$//g;
    # Y3: !note export — send all notes in one private message
    if ($text =~ /^export$/i) {
        my $notes = $self->{_notes}{$nick} // [];
        unless (@$notes) {
            botNotice($self, $nick, 'No notes to export.'); return 1;
        }
        my $export = join(' | ', map { ($_ + 1) . ". $notes->[$_]" } 0..$#$notes);
        botNotice($self, $nick, "Notes: $export");
        return 1;
    }

    # W7: !note search <mot> — search through notes
    if ($text =~ /^search\s+(.+)/i) {
        my $query = lc($1);
        my $notes = $self->{_notes}{$nick} // [];
        my @hits = grep { lc($_) =~ /\Q$query\E/ } @$notes;
        unless (@hits) {
            botNotice($self, $nick, "No notes matching '$query'."); return 1;
        }
        botNotice($self, $nick, scalar(@hits) . " note(s) matching '$query':");
        for my $i (0..$#hits) {
            botNotice($self, $nick, "  [" . ($i+1) . "] $hits[$i]");
        }
        return 1;
    }
    unless ($text ne '') {
        botNotice($self, $nick, 'Syntax: note <message>  or  note search <word>'); return;
    }
    if (length($text) > 256) {
        botNotice($self, $nick, 'Note too long (max 256 chars).'); return;
    }

    $self->{_notes}{lc $nick} //= [];
    if (scalar @{ $self->{_notes}{lc $nick} } >= 10) {
        botNotice($self, $nick, 'Max 10 notes reached. Delete some with !notes del <id>.'); return;
    }
    my $note_id = scalar(@{ $self->{_notes}{lc $nick} }) + 1;  # C4/fix: ordinal
    push @{ $self->{_notes}{lc $nick} }, { id => $note_id, text => $text };
    my $n = scalar @{ $self->{_notes}{lc $nick} };
    # BB1: persist note to DB
    eval {
        my $sth = $self->{dbh}->prepare(
            'INSERT INTO NOTE (nick, text) VALUES (?, ?)'
        );
        $sth->execute(lc($nick), $text) if $sth; $sth->finish if $sth;
    };
    $self->{logger}->log(1, "BB1: NOTE insert failed: $@") if $@;
    botNotice($self, $nick, "Note saved (#$n total). Use !notes to list.");
    return 1;
}

sub mbNotes_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # BB1: load from DB if memory is empty (e.g. after restart)
    unless (@{ $self->{_notes}{lc $nick} // [] }) {
        eval {
            my $sth = $self->{dbh}->prepare(
                'SELECT id_note, text FROM NOTE WHERE nick = ? ORDER BY id_note ASC LIMIT 10'
            );
            if ($sth && $sth->execute(lc($nick))) {
                my @db_notes;
                while (my $r = $sth->fetchrow_hashref) {
                    push @db_notes, { id => $r->{id_note}, text => $r->{text} };
                }
                $sth->finish;
                $self->{_notes}{lc $nick} = \@db_notes if @db_notes;
            }
        };
    }
    my $notes = $self->{_notes}{lc $nick} // [];

    # !notes del <index>
    if (@args && lc($args[0]) eq 'del') {
        my $idx = ($args[1] // 1) - 1;
        if ($idx >= 0 && $idx < scalar @$notes) {
            my $del_id = $notes->[$idx]{id};
            splice @$notes, $idx, 1;
            # BB1: delete from DB
            eval {
                my $sth = $self->{dbh}->prepare('DELETE FROM NOTE WHERE nick = ? AND id_note = ?');
                $sth->execute(lc($nick), $del_id) if $sth; $sth->finish if $sth;
            };
            botNotice($self, $nick, 'Note deleted.');
        } else {
            botNotice($self, $nick, 'Note not found.');
        }
        return 1;
    }

    unless (@$notes) {
        botNotice($self, $nick, 'No notes. Use !note <message> to add one.'); return 1;
    }
    botNotice($self, $nick, scalar(@$notes) . ' note(s):');
    for my $i (0 .. $#$notes) {
        botNotice($self, $nick, sprintf('  [%d] %s', $i+1, $notes->[$i]{text}));
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbKarmaReset_ctx --- !karmareset <nick>  (V3)
# Reset a nick's karma to 0. Requires Admin level.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# mbKarmaInfo_ctx --- !karmainfo <nick>  (BB5)
# Show detailed karma stats for a nick from _karma_log.
# ---------------------------------------------------------------------------
sub mbKarmaInfo_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $klog    = $self->{_karma_log}{$channel} // [];
    my @entries = grep { lc($_->{nick}) eq $target } @$klog;
    unless (@entries) {
        botPrivmsg($self, $channel, "$target: no karma activity in log."); return 1;
    }
    my ($received_pos, $received_neg, $given_pos, $given_neg) = (0,0,0,0);
    my %givers;
    for my $e (@entries) {
        if ($e->{delta} eq '+1') { $received_pos++; }
        else                     { $received_neg++; }
        $givers{$e->{giver}}++ if $e->{giver};
    }
    my @given = grep { lc(($_->{giver} // '')) eq $target } @$klog;
    for my $e (@given) {
        if ($e->{delta} eq '+1') { $given_pos++; }
        else                     { $given_neg++; }
    }
    my $top_giver = (sort { $givers{$b} <=> $givers{$a} } keys %givers)[0] // 'nobody';
    my $net_received = $received_pos - $received_neg;
    my $sign = $net_received >= 0 ? '+' : '';
    botPrivmsg($self, $channel,
        "karmainfo $target: received ${sign}${net_received} "
        . "(+${received_pos}/-${received_neg})"
        . " | given: +${given_pos}/-${given_neg}"
        . " | top voter: $top_giver");
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaGraph_ctx --- !karma graph [nick]  (AA4)
# ASCII sparkline of karma changes over the last 7 days (from _karma_log).
# ---------------------------------------------------------------------------
sub mbKarmaGraph_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # Remove 'graph' keyword if called as '!karma graph'
    shift @args if (@args && lc($args[0]) eq 'graph');
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $klog    = $self->{_karma_log}{$channel} // [];
    my $now     = time();
    my $days    = 7;
    # Build a bucket per day (today=6, yesterday=5, ... 7 days ago=0)
    my @buckets = (0) x $days;
    for my $entry (@$klog) {
        next unless lc($entry->{nick}) eq $target;
        my $age_days = int(($now - $entry->{ts}) / 86400);
        next if $age_days >= $days;
        my $bucket = $days - 1 - $age_days;  # most recent = rightmost
        $buckets[$bucket] += ($entry->{delta} eq '+1' ? 1 : -1);
    }
    # Check if any activity
    unless (grep { $_ != 0 } @buckets) {
        botPrivmsg($self, $channel,
            "$target: no karma activity in the last ${days} days.");
        return 1;
    }
    # Sparkline: map delta to block chars
    # ▁▂▃▄▅▆▇█ for positive, ▼ for negative, · for zero
    my @spark_pos = ('\x{2581}','\x{2582}','\x{2583}','\x{2584}',
                     '\x{2585}','\x{2586}','\x{2587}','\x{2588}');
    my $max = (sort { $b <=> $a } map { abs($_) } @buckets)[0] || 1;
    my $spark = '';
    for my $v (@buckets) {
        if ($v == 0)    { $spark .= '\xb7'; }   # middle dot
        elsif ($v < 0)  { $spark .= '\x{25bc}'; }  # ▼
        else {
            my $idx = int(($v / $max) * 7);  # 0..7
            $spark .= $spark_pos[$idx];
        }
    }
    my $total = 0; $total += ($_ eq '+1' ? 1 : -1)
        for map { $_->{delta} } grep { lc($_->{nick}) eq $target
            && $now - $_->{ts} < $days * 86400 } @$klog;
    my $sign = $total >= 0 ? '+' : '';
    botPrivmsg($self, $channel,
        "karma graph $target (7d) $spark  net: ${sign}${total}");
    return 1;
}

sub mbKarmaReset_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    return unless $ctx->require_level('Master');

    my $target = lc($args[0] // '');
    unless ($target) {
        botNotice($self, $nick, 'Syntax: karmareset <nick>'); return;
    }

    my $sth_c = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    return unless $sth_c && $sth_c->execute($channel);
    my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
    return unless $rc;

    my $sth = $self->{dbh}->prepare(q{
        UPDATE KARMA SET score = 0
        WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        # V3: B26-pattern: execute failed, no open cursor
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $rows = $sth->rows; $sth->finish;
    if ($rows > 0) {
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick reset karma for $target to 0.");
        logBot($self, $ctx->message, $channel, 'karmareset', $target);
    } else {
        botNotice($self, $nick, "No karma entry found for '$target' on $channel.");
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbKarmaDiff_ctx --- !karmadiff [nick]  (Z7)
# Show karma delta from the in-memory log (today's changes).
# ---------------------------------------------------------------------------
sub mbKarmaDiff_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $klog    = $self->{_karma_log}{$channel} // [];
    my $now     = time();
    my $since   = $now - 86400;  # last 24h
    my @entries = grep { lc($_->{nick}) eq $target && $_->{ts} >= $since } @$klog;
    unless (@entries) {
        botPrivmsg($self, $channel,
            "$target: no karma changes in the last 24h."); return 1;
    }
    my $delta = 0;
    $delta += ($_->{delta} eq '+1' ? 1 : -1) for @entries;
    my $sign  = $delta > 0 ? '+' : '';
    botPrivmsg($self, $channel,
        "$target: karma changed by ${sign}${delta} in the last 24h (" .
        scalar(@entries) . " vote(s)).");
    logBot($self, $ctx->message, $channel, 'karmadiff', $target);
    return 1;
}

# ---------------------------------------------------------------------------
# mbKarmaTop_ctx --- !karmatop [n]
# Show the top N karma scores on the channel.
# ---------------------------------------------------------------------------
sub mbKarmaTop_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $n = 5;
        # Q5: 'bottom' subcommand shows lowest karma scores
        my $bottom_mode = (@args && lc($args[0]) eq 'bottom') ? 1 : 0;
        shift @args if $bottom_mode;
    if (@args && $args[0] =~ /^\d+$/) {
        $n = int($args[0]); $n = 1 if $n < 1; $n = 10 if $n > 10;
    }

    my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    my $id_channel;
    if ($sth_chan && $sth_chan->execute($channel)) {
        my $r = $sth_chan->fetchrow_hashref; $sth_chan->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    return unless $id_channel;

    my $sth = $self->{dbh}->prepare(q{
        SELECT nick, score FROM KARMA
        WHERE id_channel = ? ORDER BY score " . ($bottom_mode ? 'ASC' : 'DESC') . " LIMIT ?
    });
    unless ($sth && $sth->execute($id_channel, $n)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botPrivmsg($self, $channel, "No karma data for $channel yet.");
        return 1;
    }

    botPrivmsg($self, $channel, "Karma top $n on $channel:");
    my $rank = 1;
    for my $r (@rows) {
        my $sign = $r->{score} > 0 ? '+' : '';
        botPrivmsg($self, $channel, sprintf('  %2d. %-20s %s%d',
            $rank++, $r->{nick}, $sign, $r->{score}));
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbRoll_ctx --- !roll [NdN]
# Roll dice. Defaults to 1d6. Supports NdN format.
# ---------------------------------------------------------------------------
sub mbRoll_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my ($num, $sides) = (1, 6);
    if (@args && $args[0] =~ /^(\d+)d(\d+)$/i) {
        ($num, $sides) = ($1, $2);
        $num   = 1   if $num   < 1;  $num   = 10  if $num   > 10;
        $sides = 2   if $sides < 2;  $sides = 100 if $sides > 100;
    } elsif (@args && $args[0] =~ /^\d+$/) {
        $sides = int($args[0]);
        $sides = 2 if $sides < 2; $sides = 100 if $sides > 100;
    }

    my @results = map { int(rand($sides)) + 1 } 1..$num;
    my $total   = 0; $total += $_ for @results;
    my $label   = "${num}d${sides}";

    if ($num == 1) {
        botPrivmsg($self, $channel, "$nick rolled $label: $results[0]");
    } else {
        botPrivmsg($self, $channel, sprintf('%s rolled %s: [%s] = %d',
            $nick, $label, join(', ', @results), $total));
    }
    logBot($self, $ctx->message, $channel, 'roll', $label);  # Q1 (already present)
    return 1;
}

# ---------------------------------------------------------------------------
# mbFlip_ctx --- !flip
# Flip a coin.
# ---------------------------------------------------------------------------
sub mbFlip_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my $result = rand() < 0.5 ? 'Heads!' : 'Tails!';
    botPrivmsg($self, $channel, "$nick flipped a coin: $result");
    logBot($self, $ctx->message, $channel, 'flip', $result);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbActive_ctx --- !active [period]
# List nicks active in the last N hours or days.
# ---------------------------------------------------------------------------
sub mbActive_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $interval = '24 HOUR';
    my $label    = 'last 24h';
    if (@args && $args[0] =~ /^(\d+)(d|h)$/i) {
        my ($v, $u) = ($1, lc $2);
        $interval = $u eq 'h' ? "$v HOUR" : "$v DAY";
        $label    = "last ${v}${u}";
    }

    my $sth = $self->{dbh}->prepare(
        "SELECT DISTINCT cl.nick FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)"
        . " ORDER BY cl.nick LIMIT 30"  # B5/fix: cap nicks to avoid IRC line overflow
    );
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my @nicks;
    while (my ($n) = $sth->fetchrow_array) { push @nicks, $n; }
    $sth->finish;

    if (@nicks) {
        my $list = join(', ', @nicks);
        # B5/fix: truncate to avoid IRC 512-byte limit
        if (length($list) > 350) {
            $list = substr($list, 0, 347) . '...';
        }
        botPrivmsg($self, $channel,
            "Active in $label on $channel: $list"
            . " (" . scalar(@nicks) . " nick(s))");
    } else {
        botPrivmsg($self, $channel, "No activity in $label on $channel.");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbWhen_ctx --- !when <nick>
# When did a nick first appear on the channel.
# ---------------------------------------------------------------------------
sub mbWhen_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && $args[0] ne '') {
        botNotice($self, $nick, 'Syntax: when <nick>'); return;
    }
    my $target = lc($args[0]);

    my $sth = $self->{dbh}->prepare(q{
        SELECT MIN(cl.ts) AS first_seen FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $row = $sth->fetchrow_hashref; $sth->finish;

    if ($row && $row->{first_seen}) {
        botPrivmsg($self, $channel,
            "$target first seen on $channel: $row->{first_seen}");
    } else {
        botPrivmsg($self, $channel, "$target: no history found on $channel.");
    }
    logBot($self, $ctx->message, $channel, 'when', $target);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbWeatherCompare_ctx --- !weather compare <city1> <city2>
# Fetch and display weather for two cities side by side.
# ---------------------------------------------------------------------------
sub mbWeatherCompare_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args >= 2) {
        botNotice($self, $nick, 'Syntax: weather compare <city1> <city2>');
        return;
    }

    my ($city1, $city2) = ($args[0], $args[1]);

    # Cache key is simply lc($location) — same as displayWeather_ctx line 419
    my @parts;
    for my $city ($city1, $city2) {
        my $cache_key = lc($city);
        my $cache     = $self->{_weather_cache}{$cache_key};
        if ($cache && ($cache->{text} // '') ne '') {
            push @parts, $cache->{text};
        } else {
            push @parts, "$city: no cached data (use !weather $city first)";
        }
    }

    botPrivmsg($self, $channel, join('  ||  ', @parts));
    return 1;
}

# ---------------------------------------------------------------------------
# mbChoose_ctx --- !choose <a> | <b> | <c>
# ---------------------------------------------------------------------------
sub mbChoose_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $raw = join(' ', @args);
    # Y8: !choose history — show last 5 choices
    if (@args && lc($args[0]) eq 'history') {
        my $hist = $self->{_choose_history}{$channel} // [];
        unless (@$hist) {
            botPrivmsg($self, $channel, "$nick: no choice history on $channel."); return 1;
        }
        botPrivmsg($self, $channel, 'Last choices: ' . join(' | ', reverse @$hist));
        return 1;
    }

    # X4: !choose last — recall the last choice made on this channel
    if (@args && lc($args[0]) eq 'last') {
        my $last = $self->{_choose_last}{$channel};
        if ($last) {
            botPrivmsg($self, $channel, "$nick: last choice was: $last");
        } else {
            botPrivmsg($self, $channel, "$nick: no previous choice on this channel.");
        }
        return 1;
    }

    # J2: accept both | and ' ou ' (French) as separator
    my $sep = $raw =~ /\|/ ? '\|' : '\s+ou\s+';
    my @raw_opts = map { my $o = $_; $o =~ s/^\s+|\s+$//g; $o } split /$sep/, $raw;
    @raw_opts = grep { $_ ne '' } @raw_opts;
    # U5: weighted choice — 'pizza:3' means pizza appears 3x in pool
    my @opts;
    for my $opt (@raw_opts) {
        if ($opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 20) {
            push @opts, ($1) x $2;
        } else {
            push @opts, $opt;
        }
    }
    unless (@opts >= 2) {
        botNotice($self, $nick, 'Syntax: choose <a> | <b>  or  choose <a> ou <b>  (at least 2)');
        return;
    }
    my $choice = $opts[int(rand(scalar @opts))];
    $self->{_choose_last}{$channel} = $choice;  # X4: remember last choice
    # Y8: keep rolling history of 5 choices
    my $ch = $self->{_choose_history}{$channel} //= [];
    push @$ch, $choice;
    splice @$ch, 0, @$ch - 5 if @$ch > 5;
    botPrivmsg($self, $channel, "$nick: I choose... $choice!");
    logBot($self, $ctx->message, $channel, 'choose', $choice);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbMorse_ctx --- !morse <text>
# ---------------------------------------------------------------------------
sub mbMorse_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $text = uc(join(' ', @args));
    $text =~ s/^\s+|\s+$//g;
    unless ($text ne '') { botNotice($self, $nick, 'Syntax: morse <text>'); return; }
    if (length($text) > 80) { botNotice($self, $nick, 'Text too long (max 80 chars).'); return; }
    my %code = (
        A=>'.-',   B=>'-...',  C=>'-.-.',  D=>'-..',   E=>'.',
        F=>'..-.',  G=>'--.',   H=>'....',  I=>'..',    J=>'.---',
        K=>'-.-',   L=>'.-..',  M=>'--',    N=>'-.',    O=>'---',
        P=>'.--.',  Q=>'--.-',  R=>'.-.',   S=>'...',   T=>'-',
        U=>'..-',   V=>'...-',  W=>'.--',   X=>'-..-',  Y=>'-.--',
        Z=>'--..',  '0'=>'-----','1'=>'.----','2'=>'..---','3'=>'...--',
        '4'=>'....-','5'=>'.....','6'=>'-....','7'=>'--...','8'=>'---..',
        '9'=>'----.',
    );
    my @words = split /\s+/, $text;
    my @enc   = map {
        join(' ', map { $code{$_} // '?' } split //, $_)
    } @words;
    my $result = join(' / ', @enc);
    if (length($result) > 400) { $result = substr($result, 0, 397) . '...'; }
    botPrivmsg($self, $channel, $result);
    return 1;
}

# ---------------------------------------------------------------------------
# mbAbbrev_ctx --- !abbrev <text>
# Extract initials to form an acronym.
# ---------------------------------------------------------------------------
sub mbAbbrev_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $text = join(' ', @args);
    $text =~ s/^\s+|\s+$//g;
    unless ($text ne '') { botNotice($self, $nick, 'Syntax: abbrev <text>'); return; }
    my @words  = split /\s+/, $text;
    my $abbrev = join('', map { uc(substr($_, 0, 1)) } @words);
    botPrivmsg($self, $channel, "$nick: $abbrev");
    logBot($self, $ctx->message, $channel, 'abbrev', $abbrev);  # Q1
    return 1;
}

# ---------------------------------------------------------------------------
# mbCompare_ctx --- !compare <nick1> <nick2>
# ---------------------------------------------------------------------------
sub mbCompare_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    unless (@args >= 2) {
        botNotice($self, $nick, 'Syntax: compare <nick1> <nick2>'); return;
    }
    my ($t1, $t2) = (lc($args[0]), lc($args[1]));
    my $sth = $self->{dbh}->prepare(q{
        SELECT cl.nick, COUNT(*) AS cnt
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?,?)
        GROUP BY cl.nick
    });
    unless ($sth && $sth->execute($channel, $t1, $t2)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my %counts;
    while (my $r = $sth->fetchrow_hashref) { $counts{$r->{nick}} = $r->{cnt}; }
    $sth->finish;
    my $c1 = $counts{$t1} // 0;
    my $c2 = $counts{$t2} // 0;
    my $diff = abs($c1 - $c2);
    my $leader = $c1 > $c2 ? $t1 : $c1 < $c2 ? $t2 : undef;
    my $verdict = $leader ? "$leader leads by $diff msg(s)" : 'tied!';
    botPrivmsg($self, $channel,
        "$t1: $c1 msg(s) | $t2: $c2 msg(s) | $verdict");
    return 1;
}

# ---------------------------------------------------------------------------
# mbHeatmap_ctx --- !heatmap [nick]
# Activity by hour of day, ASCII bar chart.
# ---------------------------------------------------------------------------
sub mbHeatmap_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $sth = $self->{dbh}->prepare(
        'SELECT HOUR(cl.ts) AS h, COUNT(*) AS cnt'
        . ' FROM CHANNEL_LOG cl'
        . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
        . ' WHERE cl.nick = ? AND c.name = ?'
        . ' GROUP BY HOUR(cl.ts) ORDER BY h'
    );
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my @hours = (0) x 24;
    while (my $r = $sth->fetchrow_hashref) { $hours[$r->{h}] = $r->{cnt}; }
    $sth->finish;
    my $max = (sort { $b <=> $a } @hours)[0] || 1;
    # 6-hour blocks
    my @blocks = ('00-05', '06-11', '12-17', '18-23');
    botPrivmsg($self, $channel, "$target activity by hour on $channel:");
    for my $b (0..3) {
        my $label = $blocks[$b];
        my @slice = @hours[$b*6 .. $b*6+5];
        my $total = 0; $total += $_ for @slice;
        my $bar_len = int(10 * $total / ($max * 6 || 1));
        $bar_len = 1 if $total > 0 && $bar_len == 0;
        my $bar = chr(0x2588) x $bar_len . chr(0x2591) x (10 - $bar_len);
        botPrivmsg($self, $channel, sprintf('  %s  %s  %d msgs', $label, $bar, $total));
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbMonthStats_ctx --- !monthstats [nick]
# Activity count per month for the last 12 months.
# ---------------------------------------------------------------------------
sub mbMonthStats_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc($args[0]) : lc($nick);
    my $sth = $self->{dbh}->prepare(
        "SELECT DATE_FORMAT(cl.ts, '%Y-%m') AS ym, COUNT(*) AS cnt"
        . ' FROM CHANNEL_LOG cl'
        . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
        . ' WHERE cl.nick = ? AND c.name = ?'
        . "   AND cl.ts >= DATE_SUB(NOW(), INTERVAL 12 MONTH)"
        . ' GROUP BY ym ORDER BY ym'
    );
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;
    unless (@rows) {
        botPrivmsg($self, $channel, "$target: no data in last 12 months on $channel.");
        return 1;
    }
    my $out = join('  ', map { "$_->{ym}:$_->{cnt}" } @rows);
    botPrivmsg($self, $channel, "$target on $channel (last 12 months): $out");
    return 1;
}

# ---------------------------------------------------------------------------
# mbDefine_ctx --- !define <word>
# Fetch definition from Wiktionary REST API.
# ---------------------------------------------------------------------------
sub mbDefine_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $word = join('_', @args);
    $word =~ s/^\s+|\s+$//g;
    unless ($word ne '') { botNotice($self, $nick, 'Syntax: define <word>'); return; }
    if ($word =~ /[^\w\s-]/ || length($word) > 64) {
        botNotice($self, $nick, 'Invalid word.'); return;
    }
    require URI::Escape;
    my $encoded = URI::Escape::uri_escape_utf8($word);
    # A5: language configurable via main.DEFINE_LANG (default: en)
    my $lang = eval { $self->{conf}->get('main.DEFINE_LANG') } // 'en';
    $lang = 'en' unless $lang =~ /^[a-z]{2,5}$/;  # safety: valid lang code only
    my $url = "https://$lang.wiktionary.org/api/rest_v1/page/definition/$encoded";
    my $http = Mediabot::External::_make_http(timeout => 8, verify_SSL => 1);
    my $res  = eval { $http->get($url, { headers => { Accept => 'application/json' } }) }
              // { success => 0 };
    unless ($res->{success}) {
        botPrivmsg($self, $channel, "define: could not fetch definition for '$word'.");
        return;
    }
    require JSON;
    my $data = eval { JSON::decode_json($res->{content}) };
    unless ($data) {
        botPrivmsg($self, $channel, "define: no result for '$word'."); return;
    }
    # First definition from first language block
    my $first_lang = (values %$data)[0] // [];
    my $first_entry = $first_lang->[0] // {};
    my $first_def   = $first_entry->{definitions}[0]{definition} // '';
    # P4: extract part of speech
    my $pos = $first_entry->{partOfSpeech} // '';
    $pos =~ s/^\s+|\s+$//g;
    $first_def =~ s/<[^>]+>//g;  # strip HTML
    require HTML::Entities;              # B2/fix: decode &amp; &#39; etc.
    HTML::Entities::decode_entities($first_def);
    $first_def =~ s/^\s+|\s+$//g;
    $first_def = substr($first_def, 0, 300) . '...' if length($first_def) > 300;
    if ($first_def ne '') {
        my $lang_tag = $lang ne 'en' ? " [$lang]" : '';
        my $pos_tag  = $pos ? " ($pos)" : '';
        botPrivmsg($self, $channel, "$word$lang_tag$pos_tag: $first_def");
    } else {
        botPrivmsg($self, $channel, "define: no definition found for '$word' in $lang.wiktionary.");
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbTrivia_ctx --- !trivia
# mbTriviaAnswer_ctx --- !answer <text> (or just speak in channel)
# Simple trivia from Open Trivia DB (opentdb.com).
# ---------------------------------------------------------------------------
sub mbTrivia_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # V1: !trivia start N — multi-round mode with cumulative scores
    if (@args && lc($args[0]) eq 'start' && $args[1] && $args[1] =~ /^(\d+)$/) {
        my $rounds = int($args[1]); $rounds = 1 if $rounds < 1; $rounds = 20 if $rounds > 20;
        $self->{_trivia}{$channel}{multi_total}  = $rounds;
        $self->{_trivia}{$channel}{multi_current} = 0;
        $self->{_trivia}{$channel}{scores} = {};
        botPrivmsg($self, $channel, "Trivia: starting $rounds-round game! Scores reset.");
        @args = ();  # fall through to normal question fetch
    }

    if ($self->{_trivia}{$channel} && $self->{_trivia}{$channel}{active}) {
        botNotice($self, $nick, 'A trivia question is already active. Answer it or wait.');
        return;
    }
    # X5: optional category filter — !trivia <category>
    my $trivia_cat = (@args && $args[0] !~ /^\d/) ? lc(shift @args) : undef;

    # V1: increment round counter
    if ($self->{_trivia}{$channel}{multi_total}) {
        $self->{_trivia}{$channel}{multi_current}++;
        my $cur = $self->{_trivia}{$channel}{multi_current};
        my $tot = $self->{_trivia}{$channel}{multi_total};
        botPrivmsg($self, $channel, "Round $cur/$tot:");
    }
    my $http = Mediabot::External::_make_http(timeout => 8, verify_SSL => 1);
    my $res  = eval { $http->get('https://opentdb.com/api.php?amount=1&type=multiple') }
              // { success => 0 };
    unless ($res->{success}) {
        botPrivmsg($self, $channel, 'Trivia: could not fetch question.'); return;
    }
    require JSON;
    my $data = eval { JSON::decode_json($res->{content}) };
    my $q    = $data->{results}[0] or do {
        botPrivmsg($self, $channel, 'Trivia: no question in response.'); return;
    };
    require HTML::Entities;
    my $question = HTML::Entities::decode_entities($q->{question});
    my $answer   = HTML::Entities::decode_entities($q->{correct_answer});
    my @wrong    = map { HTML::Entities::decode_entities($_) } @{ $q->{incorrect_answers} };
    my @choices  = (@wrong, $answer);
    # Shuffle choices
    for my $i (reverse 1 .. $#choices) {
        my $j = int(rand($i + 1));
        @choices[$i, $j] = @choices[$j, $i];
    }
    my $answer_lc = lc($answer);
    $self->{_trivia}{$channel} = {
        active      => 1,
        answer      => $answer_lc,
        answer_display => $answer,
        started     => time(),
        hint_given  => 0,   # B2/fix: reset hint_given for each new question
        scores      => ($self->{_trivia}{$channel}{scores} // {}),
    };
    my $opts = join('  ', map { "[$_]" } @choices);
    botPrivmsg($self, $channel, "Trivia ($q->{category}): $question");
    botPrivmsg($self, $channel, "Choices: $opts -- reply with !answer <choice> or just say it (30s)");
    # Set a timeout via Scheduler or alarm — simplified: check in PRIVMSG hook
    # K3: configurable timeout (main.TRIVIA_TIMEOUT, default 30s)
    my $trivia_timeout = eval { int($self->{conf}->get('main.TRIVIA_TIMEOUT') // 30) } // 30;
    $trivia_timeout = 30 unless $trivia_timeout > 0 && $trivia_timeout <= 120;
    $self->{_trivia}{$channel}{deadline} = time() + $trivia_timeout;
    logBot($self, $ctx->message, $channel, 'trivia', $q->{category} // '');  # S2/fix
    return 1;
}

# Called from on_message_PRIVMSG hook and !answer command
sub checkTriviaAnswer {
    my ($self, $nick, $channel, $text) = @_;
    my $trivia = $self->{_trivia}{$channel};
    return unless $trivia && $trivia->{active};
    if (time() > $trivia->{deadline}) {
        $trivia->{active} = 0;
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "Time's up! The answer was: $trivia->{answer_display}");
        $self->{metrics}->inc('mediabot_trivia_timeout_total') if $self->{metrics};
        return;
    }
    # Y5: hint at half-time — reveal first letter(s)
    if (!$trivia->{hint_given} && defined $trivia->{deadline}
            && $trivia->{deadline} - time() < ($trivia->{timeout} // 30) / 2) {
        $trivia->{hint_given} = 1;
        my $ans = $trivia->{answer} // '';
        my $hint = substr($ans, 0, 1) . ('_' x (length($ans) - 1));
        Mediabot::Helpers::botPrivmsg($self, $channel, "Hint: $hint");
    }
    # B3/fix: guard against undef answer + wrap regex in eval
    return unless defined $trivia->{answer};
    my $matched = eval {
        lc($text) eq $trivia->{answer}
        || lc($text) =~ /\Q$trivia->{answer}\E/
    };
    return unless $matched;
    $trivia->{active} = 0;
    $trivia->{scores}{$nick} = ($trivia->{scores}{$nick} // 0) + 1;
    # X10: Prometheus counter for correct trivia answers
    # AA1: persist trivia score in DB (TRIVIA_SCORES table)
    eval {
        my $sth_c = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        if ($sth_c && $sth_c->execute($channel)) {
            my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
            if ($rc) {
                my $sth_u = $self->{dbh}->prepare(q{
                    INSERT INTO TRIVIA_SCORES (id_channel, nick, score, last_correct)
                    VALUES (?, ?, 1, NOW())
                    ON DUPLICATE KEY UPDATE score = score + 1, last_correct = NOW()
                });
                if ($sth_u) { $sth_u->execute($rc->{id_channel}, lc($nick)); $sth_u->finish; }
            }
        }
    };
    if ($@) {
        $self->{logger}->log(1, "AA1: TRIVIA_SCORES persist failed: $@");
    } else {
        $self->{metrics}->inc('mediabot_trivia_db_saves_total') if $self->{metrics};
    }
    $self->{metrics}->inc('mediabot_trivia_correct_total') if $self->{metrics};
    my $score = $trivia->{scores}{$nick};
    Mediabot::Helpers::botPrivmsg($self, $channel,
        "Correct, $nick! The answer was: $trivia->{answer_display}  (score: $score)");
    # W1: show intermediate scores in multi-round mode
    if ($trivia->{multi_total}) {
        my $cur = $trivia->{multi_current} // 0;
        my $tot = $trivia->{multi_total};
        my %sc  = %{ $trivia->{scores} // {} };
        my @sboard = map { "$_:$sc{$_}" }
                     sort { $sc{$b} <=> $sc{$a} } keys %sc;
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "Scores after round $cur/$tot: " . join('  ', @sboard[0..($#sboard > 4 ? 4 : $#sboard)]));
        if ($cur >= $tot) {
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "Game over! Final scores: " . join('  ', @sboard));
            delete $trivia->{multi_total};
            delete $trivia->{multi_current};
        }
    }
}

# ---------------------------------------------------------------------------
# mbTriviaTop_ctx --- !triviatop [n]  (AA1)
# Show top trivia scores from DB (persistent across sessions).
# ---------------------------------------------------------------------------
sub mbTriviaTop_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $limit   = (@args && $args[0] =~ /^(\d+)$/) ? int($args[0]) : 5;
    $limit = 1 if $limit < 1; $limit = 15 if $limit > 15;
    my $sth_c = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    unless ($sth_c && $sth_c->execute($channel)) {
        botPrivmsg($self, $channel, 'DB error.'); return;
    }
    my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
    unless ($rc) { botPrivmsg($self, $channel, 'Channel not found.'); return; }
    my $sth = $self->{dbh}->prepare(q{
        SELECT nick, score, last_correct
        FROM TRIVIA_SCORES
        WHERE id_channel = ?
        ORDER BY score DESC LIMIT ?
    });
    unless ($sth && $sth->execute($rc->{id_channel}, $limit)) {
        botPrivmsg($self, $channel, 'DB error.'); return;
    }
    my @ranked; my $i = 1;
    while (my $r = $sth->fetchrow_hashref) {
        push @ranked, "#${i}. $r->{nick}: $r->{score}";
        $i++;
    }
    $sth->finish;
    unless (@ranked) {
        botPrivmsg($self, $channel, 'No trivia scores in DB yet.'); return 1;
    }
    botPrivmsg($self, $channel, "Trivia hall of fame ($channel): " . join('  ', @ranked));
    return 1;
}

# ---------------------------------------------------------------------------
# mbTriviaReset_ctx --- !triviareset <nick>  (BB10)
# Reset a nick's trivia score in DB. Requires Master.
# ---------------------------------------------------------------------------
sub mbTriviaReset_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    return unless $ctx->require_level('Master');
    my $target = lc($args[0] // '');
    unless ($target) {
        botNotice($self, $nick, 'Syntax: triviareset <nick>'); return;
    }
    my $sth_c = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    unless ($sth_c && $sth_c->execute($channel)) {
        botNotice($self, $nick, 'DB error.'); return;
    }
    my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
    unless ($rc) { botNotice($self, $nick, 'Channel not found.'); return; }
    my $sth = $self->{dbh}->prepare(
        'DELETE FROM TRIVIA_SCORES WHERE id_channel = ? AND nick = ?'
    );
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        botNotice($self, $nick, 'DB error.'); return;
    }
    my $rows = $sth->rows; $sth->finish;
    if ($rows > 0) {
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick reset trivia score for $target.");
    } else {
        botNotice($self, $nick, "No trivia score found for '$target' on $channel.");
    }
    return 1;
}

sub mbTriviaStop_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    return unless $ctx->require_level('Master');
    my $trivia = $self->{_trivia}{$channel};
    unless ($trivia && $trivia->{active}) {
        botNotice($self, $nick, 'No active trivia on this channel.'); return 1;
    }
    $trivia->{active} = 0;
    delete $trivia->{multi_total}; delete $trivia->{multi_current};
    Mediabot::Helpers::botPrivmsg($self, $channel,
        "Trivia stopped by $nick. Answer: $trivia->{answer_display}");
    return 1;
}

sub mbTriviaScore_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $scores  = $self->{_trivia}{$channel}{scores} // {};
    unless (%$scores) {
        botPrivmsg($self, $channel, 'No trivia scores yet.'); return 1;
    }
    my @sorted = sort { $scores->{$b} <=> $scores->{$a} } keys %$scores;
    my $top = join(', ', map { "$_:$scores->{$_}" } @sorted[0..($#sorted > 4 ? 4 : $#sorted)]);
    botPrivmsg($self, $channel, "Trivia scores on $channel: $top");
    logBot($self, $ctx->message, $channel, 'triviascore', '');  # Q1
    return 1;
}

1;
