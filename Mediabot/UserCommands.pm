package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Time::Piece;
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
    mbRemindSnooze_ctx
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
    mbKarmaWatch_ctx
    mbKarmaDiff_ctx
    mbKarmaGraph_ctx
    mbKarmaInfo_ctx
    mbKarmaReset_ctx
    mbPollExtend_ctx
    mbPollStatus_ctx
    mbPollVoters_ctx
    mbTriviaReset_ctx
    mbTriviaStop_ctx
    mbTriviaTop_ctx
    mbUnvote_ctx
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
        $self->{logger}->log(1, "dbLogoutUsers() SQL execute error : " . $DBI::errstr . "(" . $DBI::errstr . ") Query : " . $sLogoutQuery)
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
    # JJ3: group by level — parse 'nick(Level)' format in @entries
    my %by_level;
    for my $e (@entries) {
        my ($lvl) = $e =~ /\(([^)]+)\)$/;
        $by_level{$lvl // 'Unknown'}++ if defined $lvl;
    }
    my $level_summary = %by_level
        ? join(', ', map { "$_:$by_level{$_}" } sort keys %by_level)
        : '';
    my $summary_str = $level_summary ? " ($level_summary)" : '';
    botNotice($self, $nick, "Authenticated users: $count$summary_str");

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

    # Optional -n flag means: notify the added IRC nick.
    #
    # Supported forms:
    #   adduser <handle> <hostmask> [level]
    #   adduser <handle> -n <hostmask> [level]
    #   adduser -n <handle> <hostmask> [level]
    #
    # "handle" is the nickname stored in the Mediabot USER table, Eggdrop-style.
    my $notify_added_user = 0;
    @args = grep {
        if (defined($_) && $_ eq '-n') {
            $notify_added_user = 1;
            0;
        }
        else {
            1;
        }
    } @args;

    my ($name, $mask, $level) = @args;
    $level //= 'User';

    unless ($name && $mask && $mask =~ /@/) {
        botNotice($self, $nick, "Syntax: adduser <handle> [-n] <hostmask> [level]");
        return;
    }

    if (getIdUser($self, $name)) {
        botNotice($self, $nick, "User $name already exists");
        return;
    }

    my $id = userAdd($self, $mask, $name, undef, $level);
    unless ($id) {
        botNotice($self, $nick, "Unable to add user $name");
        return;
    }

    botNotice($self, $nick, "User $name added (id=$id, level=$level)");

    if ($notify_added_user) {
        my $warning = _adduser_notify_online_guard($self, $name, $mask);

        if (defined($warning) && $warning ne '') {
            $self->{logger}->log(1, $warning) if $self->{logger};

            my (undef, $console_chan) = eval { $self->getConsoleChan() };
            if (defined($console_chan) && $console_chan ne '') {
                botNotice($self, $console_chan, "WARNING: $warning");
            }

            botNotice($self, $nick, "User $name added, but not notified: $warning");
        }
        else {
            my $botnick = eval { $self->{irc}->nick_folded } || 'mediabot';
            my $login_handle = $name;

            botNotice(
                $self,
                $name,
                "You have been added as a Mediabot user with level $level. "
              . "Your Mediabot handle is '$login_handle'. "
              . "Set your password with: /msg $botnick pass my_fonky_password "
              . "then login with: /msg $botnick login $login_handle my_fonky_password"
            );

            botNotice($self, $nick, "User $name notified with password/login instructions.");
        }
    }

    logBot($self, $ctx->message, undef, "adduser", $name);
}

sub _adduser_irc_glob_match {
    my ($pattern, $value) = @_;
    return 0 unless defined($pattern) && defined($value);

    my $re = quotemeta($pattern);
    $re =~ s/\\*/.*/g;
    $re =~ s/\\?/./g;

    my $ok = eval { $value =~ /^$re$/i };
    return $ok ? 1 : 0;
}

sub _adduser_notify_online_guard {
    my ($self, $name, $mask) = @_;

    $name //= '';
    $mask //= '';

    my %nicklists = ();
    if (defined($self->{hChannelsNicks}) && ref($self->{hChannelsNicks}) eq 'HASH') {
        %nicklists = %{ $self->{hChannelsNicks} };
    }
    else {
        my $ref = eval { $self->gethChannelNicks() };
        %nicklists = %{$ref} if $ref && ref($ref) eq 'HASH';
    }

    my @online_channels;
    for my $chan (sort keys %nicklists) {
        my @nicks = ();
        if (ref($nicklists{$chan}) eq 'ARRAY') {
            @nicks = @{ $nicklists{$chan} };
        }
        else {
            @nicks = eval { $self->gethChannelsNicksOnChan($chan) };
        }

        if (grep { defined($_) && lc($_) eq lc($name) } @nicks) {
            push @online_channels, $chan;
        }
    }

    unless (@online_channels) {
        my @known_channels = sort keys %nicklists;
        my $known = @known_channels ? join(', ', @known_channels) : 'none';
        return "adduser -n requested for '$name', but that nick is not currently visible in live nicklists (known channels: $known)";
    }

    my $seen;
    if ($self->{dbh}) {
        my $sth = $self->{dbh}->prepare(q{
            SELECT nick, channel, userhost, event_type, seen_at
            FROM USER_SEEN
            WHERE LOWER(nick) = LOWER(?)
            ORDER BY seen_at DESC
            LIMIT 1
        });

        if ($sth && $sth->execute($name)) {
            $seen = $sth->fetchrow_hashref;
            $sth->finish;
        }
        else {
            $sth->finish if $sth;
        }
    }

    my $userhost = $seen->{userhost} // '';
    unless ($userhost ne '') {
        return "adduser -n requested for '$name', visible on " . join(',', @online_channels)
             . ", but no USER_SEEN userhost is available to validate hostmask '$mask'";
    }

    my $fullmask = "$name!$userhost";

    unless (_adduser_irc_glob_match($mask, $fullmask) || _adduser_irc_glob_match($mask, $userhost)) {
        return "adduser -n requested for '$name', visible on " . join(',', @online_channels)
             . ", but current hostmask '$fullmask' does not match configured mask '$mask'";
    }

    return undef;
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

    my $sql_total = "SELECT COUNT(*) AS nbUsers FROM USER";
    my $sth = $bot->{dbh}->prepare($sql_total);

    unless ($sth && $sth->execute()) {
        $bot->{logger}->log(1, "userStats_ctx() SQL error: $DBI::errstr Query: $sql_total")
            if $bot->{logger};
        $sth->finish if $sth;
        $bot->botNotice($nick, "Internal error while reading user statistics.");
        return;
    }

    my ($total) = $sth->fetchrow_array;
    $sth->finish;

    $total //= 0;

    my $sql_levels = q{
        SELECT description, COUNT(*)
        FROM USER
        JOIN USER_LEVEL USING(id_user_level)
        GROUP BY description
        ORDER BY level
    };

    $sth = $bot->{dbh}->prepare($sql_levels);

    unless ($sth && $sth->execute()) {
        $bot->{logger}->log(1, "userStats_ctx() SQL error: $DBI::errstr Query: $sql_levels")
            if $bot->{logger};
        $sth->finish if $sth;
        $bot->botNotice($nick, "Internal error while reading user level statistics.");
        return;
    }

    # II10: collect levels and display as one-liner
    my @level_parts;
    while (my ($desc, $count) = $sth->fetchrow_array) {
        $desc  //= 'Unknown';
        $count //= 0;
        push @level_parts, "$desc:$count";
    }
    if (@level_parts) {
        $bot->botNotice($nick, "Users: $total total — " . join(', ', @level_parts));
    } else {
        $bot->botNotice($nick, "Users: $total total");
    }

    $sth->finish;
}

# Context-based userinfo command (Master only)
sub userInfo_ctx {
    my ($ctx) = @_;
    return unless $ctx;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Global Administrator+ is allowed to inspect user information.
    # The internal help table already documents userinfo as admin-level.
    $ctx->require_level('Administrator') or return;

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
        $sth->finish if $sth;
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
        $chk->finish if $chk;
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
        $ins->finish if $ins;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
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
        botNotice($self, $nick, "Syntax: seen <nick> [#channel]  (wildcard: seen teu*)");
        return;
    }

    my $target_input = shift @args;
    $target_input =~ s/^\s+|\s+\z//g;

    my $targetNick = lc($target_input);  # normalize for USER_SEEN PK lookup

    # mb86-IMP1: wildcard support — seen teu* → liste jusqu'à 5 nicks correspondants
    if ($target_input =~ /[*?]/) {
        my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
        my $dest       = $is_private ? $nick : ($ctx->channel);
        # Convertir le glob IRC (*=%) en LIKE SQL
        (my $like_pat = lc($target_input)) =~ s/\*/%/g;
        $like_pat =~ s/\?/_/g;
        # Sécurité : caractères LIKE spéciaux dans la partie non-glob
        $like_pat =~ s/([%_\\])/\\$1/g if $like_pat !~ /[%_]/;  # déjà fait ci-dessus
        my $chan_for_wc;
        if (@args && defined $args[0] && $args[0] =~ /^#/) {
            $chan_for_wc = shift @args;
        } else {
            my $cc = $ctx->channel // '';
            $chan_for_wc = ($cc =~ /^#/) ? $cc : undef;
        }
        my ($sql_wc, @bind_wc);
        if ($chan_for_wc) {
            $sql_wc = q{
                SELECT nick, channel, seen_at, event_type
                FROM USER_SEEN
                WHERE nick LIKE ? AND channel = ?
                ORDER BY seen_at DESC LIMIT 5
            };
            @bind_wc = ($like_pat, $chan_for_wc);
        } else {
            $sql_wc = q{
                SELECT nick, channel, seen_at, event_type
                FROM USER_SEEN
                WHERE nick LIKE ?
                ORDER BY seen_at DESC LIMIT 5
            };
            @bind_wc = ($like_pat);
        }
        my $sth_wc = $self->{dbh}->prepare($sql_wc);
        unless ($sth_wc && $sth_wc->execute(@bind_wc)) {
            botNotice($self, $nick, 'Database error.'); return;
        }
        my @wc_rows;
        while (my $r = $sth_wc->fetchrow_hashref) { push @wc_rows, $r; }
        $sth_wc->finish;
        unless (@wc_rows) {
            my $scope = $chan_for_wc ? " on $chan_for_wc" : '';
            botNotice($self, $nick, "No nicks matching '$target_input'$scope.");
            return 1;
        }
        my $count = scalar @wc_rows;
        botNotice($self, $nick, "$count nick(s) matching '$target_input':");
        for my $r (@wc_rows) {
            botNotice($self, $nick, sprintf('  %s — last seen %s on %s (%s)',
                $r->{nick}, $r->{seen_at}, $r->{channel}, $r->{event_type}));
        }
        logBot($self, $ctx->message, ($is_private ? undef : $dest), 'seen', $target_input);
        return 1;
    }

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
        # V7: show seconds for small intervals (avoids '0m ago')
        return "${secs}s ago" if $secs < 60;
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
                ORDER BY seen_at DESC
                LIMIT 1
            };
            @bind = ($targetNick, $chan_for_part);
        }
        else {
            # mb86-B3: ORDER BY seen_at DESC — sans ORDER BY, MariaDB retourne
            # une ligne arbitraire quand le nick est présent sur plusieurs canaux
            $sql = q{
                SELECT nick, channel, userhost, event_type, last_msg, new_nick,
                       seen_at, UNIX_TIMESTAMP(seen_at) AS seen_uts
                FROM USER_SEEN
                WHERE nick = ?
                ORDER BY seen_at DESC
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
    unless ($sth && $sth->execute($nick)) {
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
    # C3/fix: guard prepare result before execute
    my $ok = ($sth && $sth->execute($tz, $nick)) ? 1 : 0;
    $sth->finish if $sth;

    return $ok;
}

# Clear timezone for a user
sub _del_user_tz {
    my ($self, $nick) = @_;

    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=NULL WHERE nickname = ?");
    # C3/fix: guard prepare result before execute
    my $ok = ($sth && $sth->execute($nick)) ? 1 : 0;
    $sth->finish if $sth;

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

        unless ($sth && $sth->execute(@bind)) {
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

        unless ($sth && $sth->execute(@bind)) {
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

    unless ($sth && $sth->execute($id_user_level, $sUser)) {
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
            $sth->finish if $sth;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
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

    # Message count + last real message on this channel.
    # MB75-S1: exclude the stats command itself from the aggregate, otherwise
    # "m stats" immediately becomes the user's last message and always shows 0h ago.
    my $sth = $self->{dbh}->prepare(q{
        SELECT COUNT(*)  AS msg_count,
               MAX(ts)  AS last_msg,
               MIN(ts)  AS first_seen
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE LOWER(cl.nick) = LOWER(?)
          AND c.name = ?
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, "Database error.");
        $sth->finish if $sth;
        return;
    }
    my $msg_row = $sth->fetchrow_hashref;
    $sth->finish;

    my $msg_count  = $msg_row->{msg_count}  // 0;
    my $last_msg   = $msg_row->{last_msg}   // 'never';
    my $first_seen = $msg_row->{first_seen} // undef;

    # A1: total messages on channel for percentage (global, no period filter)
    # Keep the denominator aligned with the user aggregate above.
    my $sth_tot = $self->{dbh}->prepare(q{
        SELECT COUNT(*) AS total
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
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
        SELECT seen_at, event_type FROM USER_SEEN WHERE nick = ?
        ORDER BY seen_at DESC LIMIT 1
    });
    unless ($sth2 && $sth2->execute($target)) {
        botNotice($self, $nick, "Database error.");
        $sth2->finish if $sth2;
        return;
    }
    my $seen_row  = $sth2->fetchrow_hashref;
    $sth2->finish;

    # MB75-R5: USER_SEEN may have no row for this nick.
    my $seen_at   = $seen_row ? ($seen_row->{seen_at}    // 'never') : 'never';
    my $seen_type = $seen_row ? ($seen_row->{event_type} // '')      : '';

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
    # V6: helper to compute '(X ago)' from a SQL timestamp string
    my $_ago = sub {
        my ($ts) = @_;
        return '' unless defined $ts && $ts =~ /^\d{4}-\d{2}-\d{2}/;
        require Time::Local;
        my ($y,$mo,$d,$h,$mi,$s) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}):(\d{2}))?$/;
        $h //= 12; $mi //= 0; $s //= 0;
        my $epoch = eval { Time::Local::timelocal($s,$mi,$h,$d,$mo-1,$y-1900) };
        return '' unless $epoch;
        my $diff = time() - $epoch;
        return '' if $diff < 0;
        my $dy = int($diff/31536000); $diff %= 31536000;
        my $dm = int($diff/2592000);  $diff %= 2592000;
        my $dd = int($diff/86400);    $diff %= 86400;
        my $dh = int($diff/3600);
        my $str = $dy  ? "${dy}y ${dm}m"
                : $dm  ? "${dm}m ${dd}d"
                : $dd  ? "${dd}d ${dh}h"
                :        int((time()-$epoch)/3600) . 'h';
        return " ($str ago)";
    };
    $out .= " | first seen: $first_seen" . $_ago->($first_seen) if $first_seen && $msg_count > 0;
    $out .= " | last msg: $last_msg" . $_ago->($last_msg)       if $msg_count > 0;

    # MB75-S1: when a user asks for their own stats, USER_SEEN may already
    # have been updated by the current command, so it is misleading and always
    # reads as "0h ago". Keep it for stats about another nick.
    my $show_seen = (lc($target // '') ne lc($nick // '')) ? 1 : 0;
    $out .= " | last seen: $seen_at ($seen_type)" . $_ago->($seen_at)
        if $show_seen && $seen_at ne 'never';

    $out .= $karma_str if $karma_str;
    $out .= " | not in database" unless $id_user || $msg_count;

    # CC17: add global rank on channel
    if ($msg_count > 0 && $total > 0) {
        my $sth_cc17 = $self->{dbh}->prepare(
            "SELECT COUNT(DISTINCT sub.nick)+1 AS rank FROM"
          . " (SELECT cl2.nick, COUNT(*) AS cnt"
          .  " FROM CHANNEL_LOG cl2 JOIN CHANNEL c2 ON c2.id_channel=cl2.id_channel"
          .  " WHERE c2.name=? GROUP BY cl2.nick HAVING cnt>?) sub");
        if ($sth_cc17 && $sth_cc17->execute($channel, $msg_count)) {
            my $r17 = $sth_cc17->fetchrow_hashref; $sth_cc17->finish;
            $out .= " | rank: #" . ($r17->{rank} // '?');
        }
    }
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

    # mb91-IMP1: !top bots — mode inverse: montrer uniquement les bots détectés
    # !top nobots — exclure les bots connus du classement (défaut implicite si conf BOT_NICKS)
    my $bots_mode    = 0;   # 1=show only bots, -1=exclude bots
    my $bots_filter  = '';
    my @bot_list;
    if (@args && lc($args[0]) eq 'bots') {
        shift @args; $bots_mode = 1;
    } elsif (@args && lc($args[0]) eq 'nobots') {
        shift @args; $bots_mode = -1;
    }
    # Charger la liste des bots depuis la conf (main.BOT_NICKS = "bot1,bot2,...")
    if ($bots_mode != 0) {
        my $conf_bots = eval { $self->{conf}->get('main.BOT_NICKS') } // '';
        @bot_list = map { lc(s/^\s+|\s+$//gr) } split /,/, $conf_bots if $conf_bots;
        # Toujours inclure le nick du bot lui-même
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        push @bot_list, lc($bot_nick) if $bot_nick;
        if (@bot_list) {
            my $placeholders = join(',', ('?') x @bot_list);
            if ($bots_mode == -1) {
                $bots_filter = "AND LOWER(cl.nick) NOT IN ($placeholders)";
            } else {
                $bots_filter = "AND LOWER(cl.nick) IN ($placeholders)";
            }
        }
    }

    # A4: optional period filter — Nd/Nh + today/yesterday/week (mb91-IMP1)
    my $period_sql  = '';
    my $period_label = '';
    if (@args) {
        my $p = lc($args[0]);
        if ($p eq 'today') {
            $period_sql   = "AND DATE(cl.ts) = CURDATE()";
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND DATE(cl.ts) = CURDATE() - INTERVAL 1 DAY";
            $period_label = " (yesterday)";
        } elsif ($p eq 'week') {
            $period_sql   = "AND cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $period_label = " (this week)";
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($val, $unit) = ($1, lc $2);
            my $interval = $unit eq 'h' ? "$val HOUR" : "$val DAY";
            $period_sql   = "AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";
            $period_label = " (last ${val}${unit})";
        }
    }

    my @bind_base = ($channel, @bot_list);

    # A2: fetch total for percentage
    my $sth_tot = $self->{dbh}->prepare(
        "SELECT COUNT(*) AS total"
        . " FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? $bots_filter $period_sql"
    );
    my $total = 0;
    if ($sth_tot && $sth_tot->execute(@bind_base)) {
        my $r = $sth_tot->fetchrow_hashref;
        $total = $r->{total} // 0;
        $sth_tot->finish;
    }

    my $sth = $self->{dbh}->prepare(
        "SELECT cl.nick, COUNT(*) AS msg_count"
        . " FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? $bots_filter $period_sql"
        . " GROUP BY cl.nick ORDER BY msg_count DESC LIMIT ?"
    );
    unless ($sth && $sth->execute(@bind_base, $n)) {
        botNotice($self, $nick, "Database error.");
        $sth->finish if $sth;
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

    # V2: show total messages in header
    my $total_hdr_str = $total > 0 ? " ($total msgs)" : "";
    my $bots_label = $bots_mode == 1 ? ' [bots]' : $bots_mode == -1 ? ' [no bots]' : '';
    botPrivmsg($self, $channel, "Top $n on $channel$period_label$bots_label$total_hdr_str:");
    my $rank = 1;
    for my $row (@rows) {
        my $msgs = $row->{msg_count};
        my $pct = $total > 0 ? sprintf(" (%.1f%%)", 100 * $msgs / $total) : "";
        botPrivmsg($self, $channel, sprintf("  %d. %-16s %d msg%s%s",
            $rank++, $row->{nick}, $msgs, ($msgs != 1 ? "s" : ""), $pct));
    }

    # V10: show caller's rank if not in top-N
    my $chan_ok = defined $channel && $channel =~ /^#/;
    if ($total > 0 && $chan_ok && $bots_mode != 1) {
        my $sth_r = $self->{dbh}->prepare(
            "SELECT COUNT(*)+1 AS rank, SUM(CASE WHEN cl.nick=? THEN 1 ELSE 0 END) AS mine"
          . " FROM (SELECT nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl2"
          .        " JOIN CHANNEL c2 ON c2.id_channel=cl2.id_channel"
          .        " WHERE c2.name=? $bots_filter $period_sql GROUP BY nick) AS sub"
          . " WHERE sub.cnt > (SELECT COUNT(*) FROM CHANNEL_LOG cl3"
          .                   " JOIN CHANNEL c3 ON c3.id_channel=cl3.id_channel"
          .                   " WHERE c3.name=? $bots_filter $period_sql AND cl3.nick=?)"
        );
        if ($sth_r && $sth_r->execute(lc($nick), $channel, @bot_list, $channel, @bot_list, lc($nick))) {
            my $r = $sth_r->fetchrow_hashref; $sth_r->finish;
            my $my_rank = $r->{rank} // 0;
            my $mine    = $r->{mine} // 0;
            if ($my_rank > $n && $mine > 0) {
                my $pct_me = $total > 0 ? sprintf('%.1f%%', 100*$mine/$total) : '0%';
                botPrivmsg($self, $channel,
                    "  (your rank: #$my_rank — $mine msg(s), $pct_me)");
            }
        }
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
        my ($sth_s, @bind_s);
        if (defined $channel && $channel =~ /^#/) {
            $sth_s = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.from_nick, r.message, r.created_at
                FROM REMINDERS r
                JOIN CHANNEL c ON c.id_channel = r.id_channel
                WHERE c.name = ? AND r.to_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_s = ($channel, lc($nick));
        } else {
            # mb90-B1: en PM, chercher sur tous les canaux
            $sth_s = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.from_nick, r.message, r.created_at
                FROM REMINDERS r
                WHERE r.to_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_s = (lc($nick));
        }
        if ($sth_s && $sth_s->execute(@bind_s)) {
            my @rows;
            while (my $r = $sth_s->fetchrow_hashref) { push @rows, $r; }
            $sth_s->finish;
            if (@rows) {
                botNotice($self, $nick, 'Reminders set for you:');
                for my $r (@rows) {
                    botNotice($self, $nick, "  [#$r->{id_reminder}] from $r->{from_nick}: $r->{message}");
                }
            } else {
                botNotice($self, $nick, 'No pending reminders set for you.');
            }
        }
        return 1;
    }

    # K1: subcommands list and cancel
    if (@args && lc($args[0]) eq 'list') {
        my ($sth_l, @bind_l);
        if (defined $channel && $channel =~ /^#/) {
            $sth_l = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.to_nick, r.message, r.created_at
                FROM REMINDERS r
                JOIN CHANNEL c ON c.id_channel = r.id_channel
                WHERE c.name = ? AND r.from_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_l = ($channel, lc($nick));
        } else {
            # mb90-B1: en PM, chercher sur tous les canaux
            $sth_l = $self->{dbh}->prepare(q{
                SELECT r.id_reminder, r.to_nick, r.message, r.created_at
                FROM REMINDERS r
                WHERE r.from_nick = ? AND r.delivered = 0
                ORDER BY r.id_reminder ASC LIMIT 10
            });
            @bind_l = (lc($nick));
        }
        if ($sth_l && $sth_l->execute(@bind_l)) {
            my @rows;
            while (my $r = $sth_l->fetchrow_hashref) { push @rows, $r; }
            $sth_l->finish;
            if (@rows) {
                botNotice($self, $nick, 'Pending reminders:');
                for my $r (@rows) {
                    botNotice($self, $nick,
                        "  [#$r->{id_reminder}] for $r->{to_nick}: $r->{message}");
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
            WHERE id_reminder = ? AND from_nick = ? AND delivered = 0
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

    # mb87-IMP1: !remind daily HH:MM <msg> — rappel récurrent quotidien (auto-recréé à la livraison)
    my $remind_daily = 0;
    my $daily_hhmm   = '';
    if (@args && lc($args[0]) eq 'daily') {
        shift @args;
        if (@args && $args[0] =~ /^(\d{1,2}):(\d{2})$/) {
            my ($hh, $mm) = (int($1), int($2));
            if ($hh < 24 && $mm < 60) {
                $daily_hhmm  = sprintf('%02d:%02d', $hh, $mm);
                $remind_daily = 1;
                shift @args;
            } else {
                botNotice($self, $nick, "Invalid time for daily remind. Use: remind daily HH:MM <nick> <msg>");
                return;
            }
        } else {
            botNotice($self, $nick, "Syntax: remind daily HH:MM <nick> <message>");
            return;
        }
    }

    # mb90-IMP1: !remind weekly <DOW> HH:MM <nick> <msg> — rappel récurrent hebdomadaire
    my $remind_weekly = 0;
    my $weekly_dow    = '';   # 0=Sun..6=Sat
    my $weekly_hhmm   = '';
    if (@args && lc($args[0]) eq 'weekly') {
        shift @args;
        my %dow_map = ( sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
                        sunday=>0, monday=>1, tuesday=>2, wednesday=>3, thursday=>4, friday=>5, saturday=>6,
                        lun=>1, mar=>2, mer=>3, jeu=>4, ven=>5, sam=>6, dim=>0 );
        if (@args && exists $dow_map{lc($args[0])}) {
            $weekly_dow = $dow_map{lc(shift @args)};
            if (@args && $args[0] =~ /^(\d{1,2}):(\d{2})$/) {
                my ($hh, $mm) = (int($1), int($2));
                if ($hh < 24 && $mm < 60) {
                    $weekly_hhmm  = sprintf('%02d:%02d', $hh, $mm);
                    $remind_weekly = 1;
                    shift @args;
                } else {
                    botNotice($self, $nick, "Invalid time. Use: remind weekly <day> HH:MM <nick> <msg>");
                    return;
                }
            } else {
                botNotice($self, $nick, "Syntax: remind weekly <day> HH:MM <nick> <msg>  (day: mon, tue, wed...)");
                return;
            }
        } else {
            botNotice($self, $nick, "Syntax: remind weekly <day> HH:MM <nick> <msg>  (day: mon, tue, wed...)");
            return;
        }
    }

    my $target  = shift @args;
    my $message = join(' ', @args);
    $message =~ s/^\s+|\s+$//g;
    $message = '[!] ' . $message if $remind_urgent;
    # mb87-IMP1: tag daily pour réinsertion automatique lors de la livraison
    $message = "[daily:$daily_hhmm] $message" if $remind_daily;
    # mb90-IMP1: tag weekly pour réinsertion hebdomadaire
    $message = "[weekly:$weekly_dow:$weekly_hhmm] $message" if $remind_weekly;

    unless (defined $target && $target ne '' && $message ne '') {
        botNotice($self, $nick, "Syntax: remind <nick> <msg>  |  remind daily HH:MM <nick> <msg>  |  remind weekly <day> HH:MM <nick> <msg>  |  remind list  |  remind cancel <id>");
        return;
    }

    # IMP8: limit pending reminders per sender (max 10) to prevent spam
    {
        my $sth_cnt = $self->{dbh}->prepare(q{
            SELECT COUNT(*) AS cnt FROM REMINDERS
            WHERE from_nick = ? AND delivered = 0
        });
        if ($sth_cnt && $sth_cnt->execute(lc($nick))) {
            my $r = $sth_cnt->fetchrow_hashref;
            $sth_cnt->finish;
            if (($r->{cnt} // 0) >= 10) {
                botNotice($self, $nick,
                    "You already have 10 pending reminders. Cancel some before adding more.");
                return 1;
            }
        }
    }

    if (length($message) > 512) {
        botNotice($self, $nick, "Message too long (max 512 chars).");
        return;
    }

    if (lc($target) eq lc($nick)) {
        botNotice($self, $nick, "You can't remind yourself.");
        return;
    }

    # mb92-B3: valider que le nick destinataire est connu (nicklist canal OU USER_SEEN)
    # On évite de créer des reminders pour des nicks fantômes mal orthographiés.
    {
        my $target_known = 0;
        # 1. Vérifier la nicklist en mémoire (le plus rapide)
        if (defined $channel && $channel =~ /^#/) {
            my @chan_nicks = eval { $self->gethChannelsNicksOnChan($channel) };
            $target_known = 1 if grep { defined($_) && lc($_) eq lc($target) } @chan_nicks;
        }
        # 2. Sinon, vérifier USER_SEEN (nick a déjà parlé sur un canal commun)
        unless ($target_known) {
            my $sth_seen = $self->{dbh}->prepare(
                'SELECT 1 FROM USER_SEEN WHERE nick = ? LIMIT 1'
            );
            if ($sth_seen && $sth_seen->execute(lc($target))) {
                $target_known = 1 if $sth_seen->fetchrow_array;
                $sth_seen->finish;
            }
        }
        # 3. Sinon, vérifier la table USER (nick enregistré)
        unless ($target_known) {
            my $sth_user = $self->{dbh}->prepare(
                'SELECT 1 FROM USER WHERE nickname = ? LIMIT 1'
            );
            if ($sth_user && $sth_user->execute(lc($target))) {
                $target_known = 1 if $sth_user->fetchrow_array;
                $sth_user->finish;
            }
        }
        unless ($target_known) {
            botNotice($self, $nick,
                "Unknown nick '$target'. The remind was not created.");
            return;
        }
    }

    # Q2: parse optional delay prefix — 'dans 2h', 'in 30m', 'dans 1h30', 'at HH:MM', 'in Nd/Nw'
    my $delay_secs = 0;
    if ($message =~ s/^(?:dans|in)\s+(\d+)h(?:(\d+)m)?\s+//i) {
        $delay_secs = $1 * 3600 + ($2 // 0) * 60;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)m\s+//i) {
        $delay_secs = $1 * 60;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)d\s+//i) {
        # mb87-B1: support 'in Nd' (jours)
        $delay_secs = $1 * 86400;
    } elsif ($message =~ s/^(?:dans|in)\s+(\d+)w\s+//i) {
        # mb87-B1: support 'in Nw' (semaines)
        $delay_secs = $1 * 7 * 86400;
    } elsif ($message =~ s/^tomorrow\s+//i) {
        $delay_secs = 86400;
    } elsif ($message =~ s/^at\s+(\d{1,2}):(\d{2})\s+//i) {
        # mb87-B1: 'at HH:MM' — prochaine occurrence de l'heure (aujourd'hui ou demain)
        my ($hh, $mm) = (int($1), int($2));
        if ($hh < 24 && $mm < 60) {
            my @now = localtime(time());
            my $today_delta = ($hh * 3600 + $mm * 60)
                            - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            # Si < 60s dans le futur, reporter à demain (évite un remind quasi-immédiat)
            $delay_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        } else {
            botNotice($self, $nick, "Invalid time. Use: at HH:MM (00:00-23:59)");
            return;
        }
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
    unless ($sth && $sth->execute($id_channel, lc($nick), lc($target), $message)) {
        $self->{logger}->log(1, "mbRemind_ctx() SQL error: $DBI::errstr");
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
        # mb91-B1: le tag [at:TS] peut être précédé de [daily:...] ou [weekly:...]
        # Format réinséré: "[daily:09:00] [at:TS] texte" — on cherche partout dans les préfixes
        my $at_ts;
        if ($r->{message} =~ /\[at:(\d+)\]/) {
            $at_ts = $1;
        }
        if (defined $at_ts) {
            next if time() < $at_ts;
            # Strip tous les [at:TS] du message avant livraison
            $r->{message} =~ s/\s*\[at:\d+\]\s*/ /g;
            $r->{message} =~ s/^\s+|\s+$//g;
        }
        # H/fix: mark delivered BEFORE sending — prevents double delivery on crash
        my $sth_up = $dbh->prepare(q{
            UPDATE REMINDERS SET delivered = 1 WHERE id_reminder = ?
        });
        # C2/fix: test execute return
        if ($sth_up) {
            unless ($sth_up->execute($r->{id_reminder})) {
                $self->{logger}->log(1, "deliverReminders: UPDATE failed for id=$r->{id_reminder}: $DBI::errstr");
                $sth_up->finish;
                next;  # skip send if we can't mark delivered
            }
            $sth_up->finish;
        } else { next; }  # can't prepare → skip
        # IMP15: show how long ago the reminder was set
        my $ago_str = '';
        if ($r->{created_at} && $r->{created_at} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            require Time::Local;
            my ($y,$mo,$d) = ($1,$2,$3);
            my $epoch = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
            if ($epoch) {
                my $diff = time() - $epoch;
                my $dy = int($diff/31536000); my $dm = int(($diff%31536000)/2592000);
                my $dd = int(($diff%2592000)/86400);
                $ago_str = $dy  ? ", ${dy}y ${dm}m ago"
                         : $dm  ? ", ${dm}m ${dd}d ago"
                         : $dd  ? ", ${dd}d ago" : '';
            }
        }
        # mb91-B1: strip les tags récurrents du message affiché
        my $display_msg = $r->{message};
        my $recur_tag = '';
        if ($display_msg =~ s/^\[daily:(\d{2}:\d{2})\]\s*//) {
            $recur_tag = " [daily $1]";
        } elsif ($display_msg =~ s/^\[weekly:(\d):(\d{2}:\d{2})\]\s*//) {
            my @dn = qw(Sun Mon Tue Wed Thu Fri Sat);
            $recur_tag = " [weekly $dn[$1] $2]";
        }
        botPrivmsg($self, $channel,
            "$nick: reminder from $r->{from_nick} ($r->{created_at}$ago_str)$recur_tag: $display_msg");

        # mb87-IMP1 / mb88-R1: si le remind est daily, le re-créer pour le lendemain
        # mb90-IMP1: si le remind est weekly, le re-créer pour la semaine suivante
        # Guard: ne réinsérer que si delivered=1 (livré normalement), pas delivered=2 (annulé)
        my $was_cancelled = 0;
        {
            my $sth_chk = $dbh->prepare('SELECT delivered FROM REMINDERS WHERE id_reminder = ?');
            if ($sth_chk && $sth_chk->execute($r->{id_reminder})) {
                my $chk = $sth_chk->fetchrow_hashref; $sth_chk->finish;
                $was_cancelled = 1 if $chk && ($chk->{delivered} // 0) == 2;
            }
        }
        if (!$was_cancelled && $r->{message} =~ /^\[daily:(\d{2}:\d{2})\]\s*(.*)/) {
            my ($hhmm, $real_msg) = ($1, $2);
            my ($hh, $mm) = split /:/, $hhmm;
            my @now = localtime(time());
            my $today_delta = ($hh * 3600 + $mm * 60)
                            - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            my $next_secs   = $today_delta > 60 ? $today_delta : $today_delta + 86400;
            my $next_ts     = time() + $next_secs;
            my $next_msg    = "[daily:$hhmm] [at:$next_ts] $real_msg";
            eval {
                my $sth_daily = $dbh->prepare(q{
                    INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
                    VALUES (?, ?, ?, ?)
                });
                $sth_daily->execute($id_channel, $r->{from_nick}, lc($nick), $next_msg)
                    if $sth_daily;
                $sth_daily->finish if $sth_daily;
            };
            $self->{logger}->log(3, "daily remind re-scheduled for $nick at $hhmm (next: $next_ts)")
                unless $@;
        } elsif (!$was_cancelled && $r->{message} =~ /^\[weekly:(\d):(\d{2}:\d{2})\]\s*(.*)/) {
            # mb90-IMP1: réinsertion hebdomadaire — calcul du prochain occurrence du DOW+HH:MM
            my ($target_dow, $hhmm, $real_msg) = ($1, $2, $3);
            my ($hh, $mm) = split /:/, $hhmm;
            my @now    = localtime(time());
            my $cur_dow = $now[6];  # 0=Sun..6=Sat
            my $days_ahead = ($target_dow - $cur_dow + 7) % 7;
            $days_ahead = 7 if $days_ahead == 0;  # même jour → semaine suivante
            my $day_secs    = $days_ahead * 86400;
            my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
            my $next_ts     = time() + $day_secs + $time_offset;
            my $next_msg    = "[weekly:$target_dow:$hhmm] [at:$next_ts] $real_msg";
            eval {
                my $sth_wk = $dbh->prepare(q{
                    INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message)
                    VALUES (?, ?, ?, ?)
                });
                $sth_wk->execute($id_channel, $r->{from_nick}, lc($nick), $next_msg) if $sth_wk;
                $sth_wk->finish if $sth_wk;
            };
            $self->{logger}->log(3, "weekly remind re-scheduled for $nick at dow=$target_dow $hhmm (next: $next_ts)")
                unless $@;
        }  # end recurring remind block
    }  # end for @pending
}  # end sub deliverReminders

# ---------------------------------------------------------------------------
# mbRemindList_ctx --- !remindlist
# Show pending reminders sent by the calling nick.
# ---------------------------------------------------------------------------
sub mbRemindList_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my ($sth, @bind_rl);
    if (defined $channel && $channel =~ /^#/) {
        $sth = $self->{dbh}->prepare(q{
            SELECT r.id_reminder, r.to_nick, r.message, r.created_at
            FROM REMINDERS r
            JOIN CHANNEL c ON c.id_channel = r.id_channel
            WHERE r.from_nick = ? AND c.name = ? AND r.delivered = 0
            ORDER BY r.created_at ASC
        });
        @bind_rl = (lc($nick), $channel);
    } else {
        # mb90-B1: en PM, afficher tous les reminders cross-canal
        $sth = $self->{dbh}->prepare(q{
            SELECT r.id_reminder, r.to_nick, r.message, r.created_at
            FROM REMINDERS r
            WHERE r.from_nick = ? AND r.delivered = 0
            ORDER BY r.created_at ASC
        });
        @bind_rl = (lc($nick));
    }
    unless ($sth && $sth->execute(@bind_rl)) {
        botNotice($self, $nick, 'Database error.');
        $sth->finish if $sth;
        return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botNotice($self, $nick, 'No pending reminders.');
        return 1;
    }

    # CC7: enriched listing — remaining time + urgent flag
    my $total = scalar(@rows);
    botNotice($self, $nick, "$total pending reminder(s) you have set:");
    for my $r (@rows) {
        my $msg = $r->{message} // '';
        # mb90-B2: strip [daily:HH:MM] et [weekly:DOW:HH:MM] FIRST et noter séparément
        my $daily_tag = '';
        if ($msg =~ s/^\[daily:(\d{2}:\d{2})\]\s*//) {
            $daily_tag = " [daily $1]";
        } elsif ($msg =~ s/^\[weekly:(\d):(\d{2}:\d{2})\]\s*//) {
            my @dow_names = qw(Sun Mon Tue Wed Thu Fri Sat);
            $daily_tag = " [weekly $dow_names[$1] $2]";
        }
        # BX-12/fix: strip [at:TS], detect remaining [at:TS] (après daily)
        my $due_str = '';
        $msg =~ s/\s*\[at:(\d+)\]\s*/ /g;  # strip tous les [at:TS]
        $msg =~ s/^\s+|\s+$//g;
        # Recalculer due_str depuis le message original si [at:TS] présent
        if ($r->{message} =~ /\[at:(\d+)\]/) {
            my $sl = $1 - time();
            $due_str = $sl > 0
                ? ' [in ' . _seconds_to_human($sl) . ']'
                : ' [overdue ' . _seconds_to_human(-$sl) . ' ago]';
        }
        my $urgent = ($msg =~ /^\[!\]/) ? ' [URGENT]' : '';
        $msg =~ s/^\[!\]\s*//;
        botNotice($self, $nick, sprintf('  #%d -> %s%s%s: "%s"%s',
            $r->{id_reminder}, $r->{to_nick}, $due_str, $daily_tag, $msg, $urgent));
    }
    return 1;
}


# ---------------------------------------------------------------------------
# mbRemindSnooze_ctx --- !remindsnooze <id> <+delay>  (FF7)
# Postpone a pending reminder. Delay format: 1h, 30m, 2h30m, 1d.
# ---------------------------------------------------------------------------
sub mbRemindSnooze_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my ($id, $delay_str) = (shift @args, shift @args);
    unless (defined $id && $id =~ /^\d+$/ && defined $delay_str) {
        botNotice($self, $nick, 'Syntax: remindsnooze <id> <delay>  (e.g. 10 30m or 3 2h)');
        return;
    }
    # Parse delay: 1h30m, 45m, 2d, etc.
    my $secs = 0;
    $secs += $1 * 86400 if $delay_str =~ /(\d+)d/;
    $secs += $1 * 3600  if $delay_str =~ /(\d+)h/;
    $secs += $1 * 60    if $delay_str =~ /(\d+)m/;
    $secs += $1         if $delay_str =~ /(\d+)s/;
    unless ($secs > 0) {
        botNotice($self, $nick, "Invalid delay '$delay_str'. Use 1h, 30m, 2h30m, 1d...");
        return;
    }
    my $new_ts = time() + $secs;

    # Keep snooze SQL simple and portable: fetch current message, rewrite the
    # [at:TS] prefix in Perl, then update the message with a normal placeholder.
    my $sth2 = $self->{dbh}->prepare(
        'UPDATE REMINDERS SET message = ? WHERE id_reminder = ? AND from_nick = ? AND delivered = 0'
    );
    # Fetch current message first
    my $sth_get = $self->{dbh}->prepare(
        'SELECT message FROM REMINDERS WHERE id_reminder = ? AND from_nick = ? AND delivered = 0'
    );
    unless ($sth_get && $sth_get->execute($id, lc($nick))) {
        botNotice($self, $nick, 'DB error.'); return;
    }
    my $row = $sth_get->fetchrow_hashref; $sth_get->finish;
    unless ($row) {
        botNotice($self, $nick, "Reminder #$id not found or already delivered."); return;
    }
    my $msg = $row->{message} // '';
    # mb88-R2: strip [at:TS] où qu'il soit dans le message (pas seulement en début)
    # Cas daily: "[daily:09:00] [at:1234] texte" → strip le [at:...] interne aussi
    $msg =~ s/^\[at:\d+\]\s*//;       # strip en début (cas standard)
    $msg =~ s/\s*\[at:\d+\]\s*/ /g;   # strip partout ailleurs (cas daily + snooze)
    $msg =~ s/^\s+|\s+$//g;           # trim
    my $new_msg = "[at:$new_ts] $msg";
    unless ($sth2 && $sth2->execute($new_msg, $id, lc($nick))) {
        botNotice($self, $nick, 'DB error updating reminder.'); return;
    }
    $sth2->finish;
    my $hm = sprintf('%dh%02dm', int($secs/3600), int(($secs%3600)/60));
    botNotice($self, $nick, "Reminder #$id snoozed for $hm.");
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
    # EE6: !remindcancel all — cancel all pending reminders set by caller
    if (defined $id && lc($id) eq 'all') {
        my $sth_a = $self->{dbh}->prepare(q{
            UPDATE REMINDERS SET delivered = 1
            WHERE from_nick = ? AND delivered = 0
        });
        unless ($sth_a && $sth_a->execute(lc($nick))) {
            botNotice($self, $nick, 'DB error.'); return;
        }
        my $rows = $sth_a->rows; $sth_a->finish;
        botNotice($self, $nick, "$rows pending reminder(s) cancelled.");
        return 1;
    }
    unless (defined $id && $id =~ /^\d+$/) {
        botNotice($self, $nick, 'Syntax: remind cancel <id>|all  (see !remindlist)');
        return;
    }

    my $sth = $self->{dbh}->prepare(q{
        UPDATE REMINDERS SET delivered = 2
        WHERE id_reminder = ? AND from_nick = ? AND delivered = 0
    });
    unless ($sth && $sth->execute($id, lc($nick))) {
        botNotice($self, $nick, 'Database error.');
        $sth->finish if $sth;
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
    # mb89-B1: envoyer en channel si appelé publiquement, en NOTICE si privé
    my $is_public = defined $channel && $channel =~ /^#/;
    my $send = $is_public
        ? sub { botPrivmsg($self, $channel, $_[0]) }
        : sub { botNotice($self, $nick, $_[0]) };

    $send->('Last ' . scalar(@$history) . ' calc(s) for ' . $nick . ':');
    for my $entry (@$history) {
        $send->("  $entry");
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

    # mb85-B3: !karma log et !karma top étaient mal routés ici — déplacés dans mbKarma_ctx

    $self->{metrics}->inc('mediabot_wordcount_requests_total') if $self->{metrics};

    # mb92/polish: wordcount is channel-scoped
    unless (defined($channel) && $channel =~ /^#/) {
        botNotice($self, $nick, "wordcount must be used from a channel.");
        return 1;
    }

    # mb94-IMP1 / mb100-IMP1 / mb100-polish:
    # Supported forms:
    #   !wordcount
    #   !wordcount <nick>
    #   !wordcount <period>
    #   !wordcount <nick> <period>
    # where <period> is today/yesterday/week/Nd/Nh.
    my $period_re = qr/^(?:today|yesterday|week|all|\d+[dh])$/i;

    my $target = lc($nick);
    my $period_arg;
    my $no_limit = 0;  # mb102-IMP2: option all = pas de LIMIT

    if (@args) {
        if (defined($args[0]) && $args[0] =~ $period_re) {
            $period_arg = lc($args[0]);
        }
        else {
            $target = lc($args[0]);
            $period_arg = lc($args[1]) if defined($args[1]) && $args[1] =~ $period_re;
        }
    }

    my $period_sql   = '';
    my $period_label = '';
    if (defined($period_arg) && $period_arg ne '') {
        my $p = $period_arg;
        if ($p eq 'today') {
            $period_sql   = "AND DATE(cl.ts) = CURDATE()";
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND DATE(cl.ts) = CURDATE() - INTERVAL 1 DAY";
            $period_label = " (yesterday)";
        } elsif ($p eq 'week') {
            $period_sql   = "AND cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $period_label = " (this week)";
        } elsif ($p eq 'all') {
            # mb102-IMP2: pas de LIMIT — peut être lent sur gros datasets
            $no_limit     = 1;
            $period_label = " (all time, no limit — may be slow)";
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($val, $unit) = ($1, lc $2);
            my $interval = $unit eq 'h' ? "$val HOUR" : "$val DAY";
            $period_sql   = "AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";
            $period_label = " (last ${val}${unit})";
        }
    }

    # mb92-B1: LIMIT 50000 par défaut — mb102-IMP2: désactivé si option 'all'
    my $ROW_LIMIT = 50_000;
    my $limit_clause = $no_limit ? '' : "LIMIT $ROW_LIMIT";
    my $sth = $self->{dbh}->prepare(qq{
        SELECT publictext FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ? AND publictext IS NOT NULL
        $period_sql
        ORDER BY cl.id_channel_log DESC
        $limit_clause
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.');
        $sth->finish if $sth;
        return;
    }
    my %words;
    my $rows_read = 0;
    while (my ($text) = $sth->fetchrow_array) {
        $rows_read++;
        $words{lc $_}++ for split /\W+/, ($text // '');
    }
    $sth->finish;
    delete $words{''};

    # V9/MB75-R4: show top 5 most frequent useful words.
    my $distinct = scalar keys %words;
    my @word_candidates = grep { defined($_) && length($_) >= 3 } keys %words;
    my @top5 = (sort { $words{$b} <=> $words{$a} || $a cmp $b } @word_candidates)[0..4];
    @top5 = grep { defined($_) } @top5;
    my $top_str = @top5
        ? '  | top words: ' . join(', ', map { "$_ ($words{$_})" } @top5)
        : '';
    # mb92-B1: avertir si le résultat est tronqué
    my $trunc_note = (!$no_limit && $rows_read >= $ROW_LIMIT) ? " [last 50k msgs]" : "";

    # mb114/mb115: activity rank among nicks on this channel.
    # Only calculate it for the unfiltered/default mode. Period filters and
    # 'all' can already be expensive, so they deliberately skip this extra query.
    #
    # This is an activity-rank proxy based on logged line count, not an exact
    # distinct-word rank for every nick. The exact distinct-word rank would need
    # a much heavier full-channel tokenization pass.
    my $rank_str = '';
    unless (defined($period_arg) && $period_arg ne '') {
        my $sth_rank = $self->{dbh}->prepare(qq{
            SELECT COUNT(*) + 1 AS rank_pos FROM (
                SELECT cl2.nick
                FROM CHANNEL_LOG cl2
                JOIN CHANNEL c2 ON c2.id_channel = cl2.id_channel
                WHERE c2.name = ?
                  AND cl2.nick != ?
                  AND cl2.publictext IS NOT NULL
                GROUP BY cl2.nick
                HAVING COUNT(*) > ?
            ) sub_q
        });
        if ($sth_rank && $sth_rank->execute($channel, $target, $rows_read)) {
            my $r = $sth_rank->fetchrow_hashref;
            $rank_str = "  | activity rank: #$r->{rank_pos}" if $r && defined $r->{rank_pos};
            $sth_rank->finish;
        }
    }

    botPrivmsg($self, $channel, "$target: $distinct distinct word(s) on $channel$period_label$trunc_note$rank_str$top_str");
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
            botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
        }
        my @rows;
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
        $sth->finish;
        unless (@rows) { botNotice($self, $nick, 'No aliases defined.'); return 1; }
        # W7: show total count in header
        botNotice($self, $nick, scalar(@rows) . ' alias(es) defined:');
        botNotice($self, $nick, "  $_->{alias} => $_->{command}") for @rows;
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
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
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

    # mb94-IMP2: !streak teuk all — forcer recalcul sans cache
    my $force_refresh = 0;
    if (@args >= 2 && lc($args[-1]) eq 'all') {
        $force_refresh = 1;
        pop @args;
    }
    my $target = $args[0] ? lc($args[0]) : lc($nick);

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
        $sth->finish if $sth;
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
        my $d1 = Time::Piece->strptime($days[$i-1], '%Y-%m-%d');
        my $d2 = Time::Piece->strptime($days[$i],   '%Y-%m-%d');
        last unless int(($d1 - $d2)->days + 0.5) == 1;  # B4/fix: ->days is float
        $streak++;
    }

    # V14: compute best streak (max consecutive run in full history)
    my $best = $streak;  # current is at least as good as best from start
    my $cur_run = 1;
    for my $i (1 .. $#days) {
        my $d1 = Time::Piece->strptime($days[$i-1], '%Y-%m-%d');
        my $d2 = Time::Piece->strptime($days[$i],   '%Y-%m-%d');
        if (int(($d1 - $d2)->days + 0.5) == 1) {
            $cur_run++;
            $best = $cur_run if $cur_run > $best;
        } else {
            $cur_run = 1;
        }
    }
    my $best_str = $best > $streak ? "  (best ever: ${best}d)" : '';

    # mb85-IMP1 / mb92-B2: rang du streak — cache TTL 5min pour éviter la sous-requête coûteuse
    my $rank_str  = '';
    my $cache_key = "streak_rank:$channel:$target:$streak";
    my $cached    = $self->{_streak_rank_cache}{$cache_key};
    # mb94-IMP2: invalider le cache si !streak all
    delete $self->{_streak_rank_cache}{$cache_key} if $force_refresh;
    $cached = undef if $force_refresh;
    if ($cached && (time() - $cached->{ts}) < 300) {
        $rank_str = $cached->{rank_str};
    } else {
        eval {
            my $sth_r2 = $self->{dbh}->prepare(q{
                SELECT COUNT(DISTINCT sub.nick) AS ahead
                FROM (
                    SELECT cl.nick, COUNT(DISTINCT DATE(cl.ts)) AS days_active
                    FROM CHANNEL_LOG cl
                    JOIN CHANNEL c ON c.id_channel = cl.id_channel
                    WHERE c.name = ?
                      AND cl.nick != ?
                      AND DATE(cl.ts) >= CURDATE() - INTERVAL 365 DAY
                    GROUP BY cl.nick
                ) sub
                WHERE sub.days_active > ?
            });
            if ($sth_r2 && $sth_r2->execute($channel, $target, $streak)) {
                my $rrow = $sth_r2->fetchrow_hashref; $sth_r2->finish;
                if ($rrow && defined $rrow->{ahead}) {
                    $rank_str = "  rank #" . ($rrow->{ahead} + 1);
                }
            }
        };
        $self->{_streak_rank_cache}{$cache_key} = { ts => time(), rank_str => $rank_str };
    }

    my $refresh_note = $force_refresh ? " [live]" : "";
    botPrivmsg($self, $channel,
        "$target: $streak consecutive day(s) active on $channel (most recent: $days[0])$best_str$rank_str$refresh_note");
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

    # mb85-B3: !karma log [nick] — déplacé ici depuis mbWordCount_ctx (S4)
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

    # mb85-B3: !karma top [n] — déplacé ici depuis mbWordCount_ctx (P1)
    if (@args && lc($args[0]) eq 'top') {
        shift @args;
        $ctx->{args} = \@args;
        return mbKarmaTop_ctx($ctx);
    }

    # NEW: explicit karma vote syntax — !karma + <nick> or !karma - <nick>
    # Replaces the fragile nick++/nick-- auto-detection (triggered on e.g. Notepad++).
    if (@args >= 2 && ($args[0] eq '+' || $args[0] eq '-' || $args[0] eq '++' || $args[0] eq '--')) {
        my $op     = ($args[0] eq '+' || $args[0] eq '++') ? '++' : '--';
        my $ktarget = lc($args[1]);
        # Reject self-karma
        if ($ktarget eq lc($nick) || $ktarget eq lc(do { (my $t=$nick)=~s/\[.*?\]//g;$t })) {
            my $dest = (defined $channel && $channel =~ /^#/) ? $channel : $nick;
            botPrivmsg($self, $dest, "$nick: you can't change your own karma.");
            return 1;
        }
        # MB75-R3: explicit karma votes require a registered public channel.
        unless (defined $channel && $channel =~ /^#/) {
            botNotice($self, $nick, "$nick: use !karma + <nick> or !karma - <nick> in a registered channel.");
            return 1;
        }

        my $sth_vote_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        my $vote_id_channel;
        if ($sth_vote_chan && $sth_vote_chan->execute($channel)) {
            my $vote_chan_row = $sth_vote_chan->fetchrow_hashref;
            $vote_id_channel = $vote_chan_row->{id_channel} if $vote_chan_row;
        }
        $sth_vote_chan->finish if $sth_vote_chan;

        unless ($vote_id_channel) {
            botNotice($self, $nick, "$nick: this channel is not registered.");
            return 1;
        }

        my @chan_nicks = eval { $self->gethChannelsNicksOnChan($channel) };
        my $present = grep { lc($_) eq $ktarget || lc(do{(my $t=$_)=~s/\[.*?\]//g;$t}) eq $ktarget } @chan_nicks;
        unless ($present) {
            botPrivmsg($self, $channel, "$nick: $ktarget is not on this channel.");
            return 1;
        }
        # Route through processKarma with a synthetic text
        my $synthetic = "$ktarget$op";
        eval { processKarma($self, $nick, $channel, $synthetic) };
        botNotice($self, $nick, "Error: $@") if $@;
        return 1;
    }

    my $target  = $args[0] ? lc($args[0]) : lc($nick);

    my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
    my $id_channel;
    if ($sth_chan && $sth_chan->execute($channel)) {
        my $r = $sth_chan->fetchrow_hashref;
        $sth_chan->finish;
        $id_channel = $r->{id_channel} if $r;
    }
    # U1/fix: informative message instead of silent return when channel not registered
    unless ($id_channel) {
        my $dest = (defined $channel && $channel =~ /^#/) ? $channel : $nick;
        botNotice($self, $dest, defined $channel && $channel =~ /^#/
            ? "$nick: this channel is not registered."
            : "$nick: use !karma in a registered channel.");
        return 1;
    }

    my $sth = $self->{dbh}->prepare(q{
        SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($id_channel, $target)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
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

    # NOTE: nick++/nick-- auto-detection is kept but gated:
    #   1. The ++ or -- must be at end-of-word (not followed by non-space/non-punct)
    #   2. The target nick must be present on the channel
    # Use '!karma + <nick>' for reliable explicit votes.
    my $karma_hits = 0;  # C2/fix: cap at 3 karma changes per message
    my @chan_nicks_pk = eval { $self->gethChannelsNicksOnChan($channel) };
    while ($text =~ /([^\s+\-]{2,32})(\+\+|--)(?![\w+\-])/g) {
        last if ++$karma_hits > 3;
        my ($target, $op) = (lc($1), $2);
        # PRESENCE CHECK: target must be on the channel
        my $on_chan = grep {
            lc($_) eq $target
            || lc(do { (my $t = $_) =~ s/\[.*?\]//g; $t }) eq $target
        } @chan_nicks_pk;
        unless ($on_chan) { next; }  # silently skip — not on channel
        # Self-karma: block and notify — mb86-B4: metrics ajoutées ici, check Y2 redondant supprimé
        if ($target eq lc($nick) || $target eq lc(do { (my $t = $nick) =~ s/\[.*?\]//g; $t })) {
            Mediabot::Helpers::botPrivmsg($self, $channel,
                "$nick: you can't change your own karma.");
            $self->{metrics}->inc('mediabot_karma_selfvote_blocked') if $self->{metrics};
            next;
        }
        # DD9: anti-brigade guard — >5 different nicks voting for same target in 30s → block
    {
        my $now = time();
        my $brigade_key = "brigade:$target:$channel";
        my $brigade     = $self->{_karma_brigade}{$brigade_key} //= { hits => [], warned => 0 };
        push @{ $brigade->{hits} }, $now;
        @{ $brigade->{hits} } = grep { ($now - $_) < 30 } @{ $brigade->{hits} };
        if (scalar @{ $brigade->{hits} } > 5) {
            unless ($brigade->{warned}) {
                $brigade->{warned} = 1;
                Mediabot::Helpers::botPrivmsg($self, $channel,
                    "Karma brigade detected for $target — votes temporarily blocked.");
                $self->{logger}->log(1, "DD9: karma brigade on $target in $channel");
            }
            next;
        }
        $brigade->{warned} = 0 if scalar @{ $brigade->{hits} } <= 2;
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
    # FF1: notify watchers of this karma change
    # B2/fix: use $op (captured at loop start) not $2 (regex global — stale)
    for my $watcher (keys %{ $self->{_karma_watch} // {} }) {
        my $wlist = $self->{_karma_watch}{$watcher} // [];
        if (grep { $_ eq $target } @$wlist) {
            my $verb = ($op eq '++') ? 'received ++' : 'received --';
            Mediabot::Helpers::botNotice($self, $watcher,
                "[karmawatch] $target $verb karma from $nick on $channel");
        }
    }
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
        splice @$klog, 0, @$klog - 500 if @$klog > 500;  # IMP3: 500 entries (was 20)
        # I8: persist to KARMA_LOG if table exists (graceful — skip on error)
        eval {
            my $sth_log = $self->{dbh}->prepare(q{
                INSERT IGNORE INTO KARMA_LOG
                    (id_channel, nick, delta, from_nick, score, ts)
                VALUES (?, ?, ?, ?, ?, NOW())
            });

            if ($sth_log && $sth_log->execute($id_channel, $target,
                    ($op eq '++' ? 1 : -1), $nick, $score)) {
                $sth_log->finish;
            }
            else {
                $sth_log->finish if $sth_log;
            }
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
    # KH1/fix: in PM, search in-memory log across all channels
    my $kh_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @klog_mem_entries;
    if ($kh_chan) {
        @klog_mem_entries = @{ $self->{_karma_log}{$kh_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @klog_mem_entries, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my @klog_combined = @db_entries ? @db_entries : @klog_mem_entries;
    my $klog = \@klog_combined;
    my $kh_reply = $kh_chan // $nick;
    unless (@$klog) {
        botPrivmsg($self, $kh_reply,
            "$nick: no karma history yet" . ($kh_chan ? " on $channel" : '') . ".");
        return 1;
    }

    my $kh_source = @db_entries ? '' : ' [memory]';
    my @entries = reverse @$klog;  # most recent first
    if ($filter) {
        @entries = grep { lc($_->{nick}) eq $filter } @entries;
        unless (@entries) {
            botPrivmsg($self, $kh_reply, "$nick: no karma history for '$filter' on $channel.");
            return 1;
        }
    }
    @entries = @entries[0..4] if @entries > 5;  # show last 5

    my $label = $filter ? "karma history for $filter" : "recent karma changes";
    # U4/fix: use $kh_chan (not $channel which is nick in PM)
    my $on_str = $kh_chan ? " on $kh_chan" : '';
    # GG1: add +/- vote summary in header
    my $kh_pos = scalar grep { ($_->{delta}//"") eq "+1" } @entries;
    my $kh_neg = scalar(@entries) - $kh_pos;
    my $kh_summary = @entries ? " (+$kh_pos/-$kh_neg)" : "";
    botPrivmsg($self, $kh_reply, "$nick: $label$on_str$kh_summary$kh_source:");
    for my $e (@entries) {
        my $sign  = $e->{score} > 0 ? '+' : '';
        my $delta = $e->{delta};
        my $ago   = _seconds_to_human(time() - $e->{ts});
        botPrivmsg($self, $kh_reply,
            "  $e->{nick} $delta (now ${sign}$e->{score}) by $e->{from} — $ago ago");
    }
    logBot($self, $ctx->message, $channel, 'karmahist', $filter // '');
    # L3: Prometheus counter for !karmahist
    $self->{metrics}->inc('mediabot_karmahist_requests_total') if $self->{metrics};
    return 1;
}

# ---------------------------------------------------------------------------
# mbLast_ctx --- !last <nick> [n]
# Show the last N messages posted by a nick on the current channel. Max 5.
# ---------------------------------------------------------------------------
sub mbLast_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, 'Syntax: last <nick> [n]  (n = 1-5, default 1)');
        return;
    }
    my $target = lc($args[0]);

    # mb107-IMP2: option [n] — afficher les N derniers messages (max 5)
    my $limit = 1;
    if (defined $args[1] && $args[1] =~ /^(\d+)$/) {
        $limit = int($1);
        $limit = 1 if $limit < 1;
        $limit = 5 if $limit > 5;
    }

    my $sth = $self->{dbh}->prepare(qq{
        SELECT cl.publictext, cl.ts,
               TIMESTAMPDIFF(MINUTE, cl.ts, NOW()) AS minutes_ago
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.publictext IS NOT NULL AND cl.publictext != ''
        ORDER BY cl.ts DESC
        LIMIT $limit
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, $row; }
    $sth->finish;

    unless (@rows) {
        botPrivmsg($self, $channel, "$target: no message found on $channel.");
        return 1;
    }

    my $fmt_ago = sub {
        my ($ago) = @_;
        return $ago < 60
            ? "${ago}m ago"
            : $ago < 1440
                ? sprintf('%dh %dm ago', int($ago/60), $ago%60)
                : sprintf('%dd %dh ago', int($ago/1440), int(($ago%1440)/60));
    };

    if ($limit == 1) {
        my $row = $rows[0];
        my $ago_str   = $fmt_ago->($row->{minutes_ago});
        my $time_exact = '';
        if ($row->{ts} && $row->{ts} =~ /\d{4}-\d{2}-\d{2} (\d{2}:\d{2})/) {
            $time_exact = ", $1";
        }
        botPrivmsg($self, $channel,
            "$target last said ($ago_str${time_exact} on $channel): \"$row->{publictext}\"");
    } else {
        botPrivmsg($self, $channel, "Last ${\scalar(@rows)} message(s) from $target on $channel:");
        for my $row (reverse @rows) {
            my $ago_str = $fmt_ago->($row->{minutes_ago});
            my $time_exact = '';
            if ($row->{ts} && $row->{ts} =~ /\d{4}-\d{2}-\d{2} (\d{2}:\d{2})/) {
                $time_exact = " [$1]";
            }
            botPrivmsg($self, $channel, "  ($ago_str$time_exact) $row->{publictext}");
        }
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbPoll_ctx --- !poll <question> | opt1 | opt2 ...
# mbVote_ctx --- !vote <n>


# ---------------------------------------------------------------------------
# mbPollVoters_ctx --- !pollvoters  (EE7)
# Show detailed vote breakdown. Requires Master level.
# ---------------------------------------------------------------------------
sub mbPollVoters_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    return unless $ctx->require_level('Master');
    my $poll = $self->{_polls}{$channel};
    unless ($poll && %{ $poll->{votes} // {} }) {
        botNotice($self, $nick, 'No poll or no votes on this channel.'); return 1;
    }
    botNotice($self, $nick,
        "Vote breakdown for \"$poll->{question}\":");
    # Group voters by option index
    my %by_opt;
    for my $voter (sort keys %{ $poll->{votes} }) {
        my $idx = $poll->{votes}{$voter};
        push @{ $by_opt{$idx} }, $voter;
    }
    for my $idx (sort { $a <=> $b } keys %by_opt) {
        my $label   = $poll->{options}[$idx] // "option $idx";
        my @voters  = @{ $by_opt{$idx} };
        botNotice($self, $nick,
            sprintf('  [%d] %s (%d): %s',
                $idx+1, $label, scalar @voters, join(', ', @voters)));
    }
    return 1;
}

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
    # BB7: build weighted option list
    my @weighted_parts;
    for my $opt (@parts) {
        if ($poll_weighted && $opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 10) {
            push @weighted_parts, { label => $1, weight => int($2) };
        } else {
            push @weighted_parts, { label => $opt, weight => 1 };
        }
    }
    # mb84-B3: supprimé le double inc() de poll_created_total (était appelé avant et après @weighted_parts)
    $self->{metrics}->inc('mediabot_poll_created_total') if $self->{metrics};  # Z10
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
    # mb84-B3b: $opts utilisait @parts (après shift question) au lieu des labels @weighted_parts
    my @opt_labels = map { $_->{label} } @weighted_parts;
    my $opts = join('  ', map { '[' . ($_+1) . '] ' . $opt_labels[$_] } 0..$#opt_labels);
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
    # DD8: show winner prominently — winner_opt is an option index (0-based)
    my ($winner_opt) = sort { ($counts{$b}//0) <=> ($counts{$a}//0) } keys %counts;
    my $winner_str = '';
    if (defined $winner_opt && $total > 0) {
        my $winner_label = $options[$winner_opt] // "option $winner_opt";
        my $wpct = sprintf('%.0f%%', 100*($counts{$winner_opt}//0)/$total);
        $winner_str = "  Winner: $winner_label ($wpct)";
    }
    botPrivmsg($self, $channel, "$status poll: \"$poll->{question}\" ($total vote(s))$winner_str");
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
    # IMP14: show top result immediately when poll closes
    my $votes  = $poll->{votes}  // {};
    my $opts   = $poll->{options} // [];
    my $total  = scalar(keys %$votes);
    if ($total > 0) {
        my %tally;
        $tally{$votes->{$_}}++ for keys %$votes;
        my ($winner) = sort { ($tally{$b}//0) <=> ($tally{$a}//0) } keys %tally;
        my $w_count  = $tally{$winner} // 0;
        my $pct      = int(100 * $w_count / $total);
        botPrivmsg($self, $channel,
            "Poll closed ($total vote(s)). Winner: $winner "
            . "($w_count/$total, ${pct}%). Use !pollresult for details.");
    } else {
        botPrivmsg($self, $channel, "Poll closed. No votes cast.");
    }
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
    # FF5: enforce max note length (200 chars)
    if (length($text) > 200) {
        botNotice($self, $nick,
            sprintf('Note too long (%d chars, max 200). Please shorten it.', length($text)));
        return 1;
    }
    # Y3: !note export — send all notes in one private message
    if ($text =~ /^export$/i) {
        my $notes = $self->{_notes}{lc $nick} // [];
        unless (@$notes) {
            botNotice($self, $nick, 'No notes to export.'); return 1;
        }
        my $export = join(' | ', map {
            my $n = $notes->[$_];
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            ($_ + 1) . ". $txt"
        } 0..$#$notes);
        botNotice($self, $nick, "Notes: $export");
        return 1;
    }

    # W7: !note search <mot> — search through notes
    if ($text =~ /^search\s+(.+)/i) {
        my $query = lc($1);
        my $notes = $self->{_notes}{lc $nick} // [];
        my @hits = grep {
            my $txt = ref($_) eq 'HASH' ? ($_->{text} // '') : ($_ // '');
            lc($txt) =~ /\Q$query\E/
        } @$notes;

        unless (@hits) {
            botNotice($self, $nick, "No notes matching '$query'."); return 1;
        }

        # II17: show count + search term
        botNotice($self, $nick, scalar(@hits) . "/" . scalar(@$notes)
            . " note(s) matching '$query':");
        for my $i (0..$#hits) {
            my $n = $hits[$i];
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            botNotice($self, $nick, "  [" . ($i+1) . "] $txt");
        }
        return 1;
    }
    unless ($text ne '') {
        botNotice($self, $nick, 'Syntax: note <message>  or  note search <word>'); return;
    }
    $self->{_notes}{lc $nick} //= [];
    if (scalar @{ $self->{_notes}{lc $nick} } >= 10) {
        botNotice($self, $nick, 'Max 10 notes reached. Delete some with !notes del <id>.'); return;
    }
    # BB1: persist note to DB — mb84-B8: récupérer last_insert_id pour stocker le vrai id DB
    my $db_note_id = undef;
    eval {
        my $sth = $self->{dbh}->prepare(
            'INSERT INTO NOTE (nick, text) VALUES (?, ?)'
        );
        if ($sth && $sth->execute(lc($nick), $text)) {
            $db_note_id = $self->{dbh}->last_insert_id(undef, undef, 'NOTE', 'id_note');
        }
        $sth->finish if $sth;
    };
    $self->{logger}->log(1, "BB1: NOTE insert failed: $@") if $@;
    # mb84-B8: utiliser l'id DB réel; fallback sur ordinal si INSERT a échoué
    my $note_id = $db_note_id // (scalar(@{ $self->{_notes}{lc $nick} }) + 1);
    push @{ $self->{_notes}{lc $nick} }, { id => $note_id, text => $text };
    my $n = scalar @{ $self->{_notes}{lc $nick} };
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
# mbKarmaWatch_ctx --- !karmawatch [nick]  (FF1)
# Watch a nick's karma changes — receive a NOTICE when someone votes for them.
# !karmawatch         → toggle watch on yourself
# !karmawatch <nick>  → toggle watch on that nick
# !karmawatch list    → show your active watches
# ---------------------------------------------------------------------------
sub mbKarmaWatch_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # !karmawatch list
    if (@args && lc($args[0]) eq 'list') {
        my $watching = $self->{_karma_watch}{lc $nick} // [];
        unless (@$watching) {
            botNotice($self, $nick, 'You are not watching any karma targets.');
            return 1;
        }
        # IMP19: show current karma score for each watched nick
        my @watch_with_scores;
        for my $wt (@$watching) {
            my $score_str = '';
            for my $ch (keys %{ $self->{_karma_log} // {} }) {
                my $klog = $self->{_karma_log}{$ch} // [];
                my ($last) = grep { lc($_->{nick}) eq lc($wt) } reverse @$klog;
                if ($last && defined $last->{score}) {
                    my $sc = $last->{score};
                    $score_str = $sc >= 0 ? "+$sc" : "$sc";
                    last;
                }
            }
            push @watch_with_scores, $score_str ne '' ? "$wt ($score_str)" : $wt;
        }
        botNotice($self, $nick, 'You are watching: ' . join(', ', @watch_with_scores));
        return 1;
    }

    my $target = @args ? lc($args[0]) : lc($nick);
    my $watchers = $self->{_karma_watch}{lc $nick} //= [];

    # Toggle: add if not watching, remove if already watching
    my $idx = do { my $i = 0; my $found = -1;
        for (@$watchers) { $found = $i if $_ eq $target; $i++; } $found };
    if ($idx >= 0) {
        splice @$watchers, $idx, 1;
        botNotice($self, $nick, "Stopped watching karma for $target.");
    } else {
        if (scalar @$watchers >= 5) {
            botNotice($self, $nick, 'Max 5 watches reached. Remove one first (!karmawatch <nick> to toggle off).');
            return 1;
        }
        push @$watchers, $target;
        botNotice($self, $nick, "Now watching karma for $target. You will be notified of any votes.");
    }
    return 1;
}

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
    my $target  = @args ? lc(shift @args) : lc($nick);

    # mb113-IMP1: mode 'all' — recherche cross-canal
    my $all_chans = 0;
    if (@args && lc($args[0]) eq 'all') {
        $all_chans = 1;
        shift @args;
    }

    # mb112-IMP1: période optionnelle Nd/Nh — borner le ring buffer
    my $window_secs;
    my $window_label = '';
    if (@args && $args[0] =~ /^(\d+)(d|h)$/i) {
        my ($val, $unit) = ($1, lc $2);
        $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
        $window_secs  = 3600    if $window_secs < 3600;
        $window_secs  = 2592000 if $window_secs > 2592000;
        $window_label = " (last ${val}${unit})";
        shift @args;
    }
    my $since = defined $window_secs ? time() - $window_secs : 0;

    # KI1/fix: karmainfo works in PM — use $channel if public, else nick-scoped log
    # mb113-IMP1: mode 'all' force la recherche cross-canal
    my $klog_chan = (!$all_chans && defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @entries;
    if ($klog_chan) {
        my $klog = $self->{_karma_log}{$klog_chan} // [];
        @entries = grep { lc($_->{nick}) eq $target && ($_->{ts}//0) >= $since } @$klog;
    } else {
        # PM ou mode all: search across all channels
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @entries, grep { lc($_->{nick}) eq $target && ($_->{ts}//0) >= $since }
                @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my $all_label  = $all_chans ? ' (all channels)' : '';
    my $reply_to   = $klog_chan // $nick;
    unless (@entries) {
        botPrivmsg($self, $reply_to, "$target: no karma activity in log$window_label$all_label."); return 1;
    }
    my ($received_pos, $received_neg, $given_pos, $given_neg) = (0,0,0,0);
    my %givers;
    for my $e (@entries) {
        if (($e->{delta} // '') eq '+1') { $received_pos++; }  # B24/fix
        else                             { $received_neg++; }
        $givers{$e->{from} // $e->{giver} // ''}++  # B23/fix: field is 'from' not 'giver'
            if ($e->{from} // $e->{giver} // '');
    }
    # KI1/fix2: use all_entries (collected across channels) for @given too
    my @all_entries_for_given;
    if ($klog_chan) {
        @all_entries_for_given = @{ $self->{_karma_log}{$klog_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @all_entries_for_given, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my @given = grep { lc(($_->{from} // $_->{giver} // '')) eq $target } @all_entries_for_given;
    # B23/fix: _karma_log uses 'from' key, not 'giver'
    for my $e (@given) {
        if (($e->{delta} // '') eq '+1') { $given_pos++; }  # B24/fix
        else                             { $given_neg++; }
    }
    # U2/fix: deterministic sort on ties (lc nick), show giver vote count
    my ($top_giver, $top_giver_count);
    if (%givers) {
        my @sorted_givers = sort {
            $givers{$b} <=> $givers{$a} || lc($a) cmp lc($b)
        } keys %givers;
        $top_giver       = $sorted_givers[0];
        $top_giver_count = $givers{$top_giver};
    } else {
        $top_giver = 'nobody'; $top_giver_count = 0;
    }
    my $net_received = $received_pos - $received_neg;
    my $sign = $net_received >= 0 ? '+' : '';
    # IMP6: show current score from last known log entry
    my $last_score = @entries ? $entries[-1]{score} : undef;
    # II15: find oldest entry for 'since' info
    my $oldest_ts = @entries ? (sort { $a->{ts} <=> $b->{ts} } @entries)[0]{ts} : 0;
    my $since_str = '';
    if ($oldest_ts) {
        my $age_d = int((time() - $oldest_ts) / 86400);
        $since_str = " (last ${age_d}d in log)" if $age_d > 0;
    }
    my $score_str  = defined $last_score
        ? ' [score: ' . ($last_score >= 0 ? "+$last_score" : "$last_score") . ']'
        : '';
    # V1: positivity ratio — must be computed BEFORE the botPrivmsg call
    my $recv_total = $received_pos + $received_neg;
    my $pct_pos    = $recv_total > 0 ? int(100 * $received_pos / $recv_total) : 0;
    my $pct_str    = $recv_total > 0 ? ", ${pct_pos}% \x{2191}" : "";
    botPrivmsg($self, $reply_to,
        "karmainfo $target$score_str$since_str [memory]$window_label$all_label: received ${sign}${net_received} "
        . "(+${received_pos}/-${received_neg}${pct_str})"
        . " | given: +${given_pos}/-${given_neg}"
        . " | top voter: $top_giver" . ($top_giver_count ? " (${top_giver_count}x)" : ''));
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
    # KG1/fix: sparkline requires a public channel context
    unless (defined $channel && $channel =~ /^#/) {
        botNotice($self, $nick, '!karmgraph requires a channel context. Use it in a channel.');
        return 1;
    }
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
        next if $age_days < 0;     # A16/fix: future ts (clock skew) → skip
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
    # mb84-B4: single-quoted \x{NNNN} ne sont pas interpolées en Perl → double-quotes requises
    my @spark_pos = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}",
                     "\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $max = (sort { $b <=> $a } map { abs($_) } @buckets)[0] || 1;
    my $spark = '';
    for my $v (@buckets) {
        if ($v == 0)    { $spark .= "\xb7"; }          # middle dot ·
        elsif ($v < 0)  { $spark .= "\x{25bc}"; }      # ▼
        else {
            my $idx = int(($v / $max) * 7);  # 0..7
            $spark .= $spark_pos[$idx];
        }
    }
    # B5/fix: guard against undef delta in _karma_log entries
    my $total = 0;
    $total += (($_ // '') eq '+1' ? 1 : -1)
        for map { $_->{delta} } grep {
            defined $_->{delta} && lc($_->{nick}) eq $target
            && $now - ($_->{ts} // 0) < $days * 86400
        } @$klog;
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

    # W3: read current score before reset for informative message
    my $old_score = 0;
    {
        my $sth_sc = $self->{dbh}->prepare(
            'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?');
        if ($sth_sc && $sth_sc->execute($rc->{id_channel}, $target)) {
            my $r = $sth_sc->fetchrow_hashref;
            $old_score = $r->{score} // 0 if $r;
            $sth_sc->finish;
        }
    }
    my $sth = $self->{dbh}->prepare(q{
        UPDATE KARMA SET score = 0
        WHERE id_channel = ? AND nick = ?
    });
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my $rows = $sth->rows; $sth->finish;
    if ($rows > 0) {
        my $was = $old_score >= 0 ? "+$old_score" : "$old_score";
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "$nick reset karma for $target to 0 (was $was).");
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

    # mb109-IMP1: !karmadiff all [period] — top 5 variations sur la période
    if (@args && lc($args[0]) eq 'all') {
        shift @args;
        my $window_secs  = 86400;
        my $window_label = '24h';
        if (@args && $args[0] =~ /^(\d+)(d|h)$/) {
            my ($val, $unit) = ($1, $2);
            $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
            $window_secs  = 3600    if $window_secs < 3600;
            $window_secs  = 2592000 if $window_secs > 2592000;
            $window_label = "${val}${unit}";
        }
        my $kd_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
        my @all_entries;
        if ($kd_chan) {
            @all_entries = @{ $self->{_karma_log}{$kd_chan} // [] };
        } else {
            for my $ch (keys %{ $self->{_karma_log} // {} }) {
                push @all_entries, @{ $self->{_karma_log}{$ch} // [] };
            }
        }
        my $now   = time();
        my $since = $now - $window_secs;
        my %deltas;
        for my $e (grep { ($_->{ts} // 0) >= $since } @all_entries) {
            $deltas{lc($e->{nick})} += (($e->{delta} // '') eq '+1' ? 1 : -1);
        }
        unless (%deltas) {
            botPrivmsg($self, $kd_chan // $nick, "No karma activity in the last $window_label.");
            return 1;
        }
        my @sorted = (sort { abs($deltas{$b}) <=> abs($deltas{$a}) || $a cmp $b } keys %deltas)[0..4];
        @sorted = grep { defined } @sorted;
        my @parts = map {
            my $d = $deltas{$_};
            my $sign = $d > 0 ? '+' : '';
            "$_: ${sign}${d}"
        } @sorted;
        botPrivmsg($self, $kd_chan // $nick,
            "Karma top movers (last $window_label): " . join('  |  ', @parts));
        return 1;
    }

    my $target  = @args ? lc($args[0]) : lc($nick);

    # mb89-IMP1 / mb108-IMP2: fenêtre temporelle configurable
    # Formes acceptées : 6h, 12h, 24h (défaut), 7d — et maintenant toute forme Nd/Nh
    my $window_secs  = 86400;
    my $window_label = '24h';
    if (@args >= 2) {
        my $w = lc($args[1]);
        if ($w =~ /^(\d+)(d|h)$/) {
            my ($val, $unit) = ($1, $2);
            $window_secs  = $unit eq 'h' ? $val * 3600 : $val * 86400;
            $window_secs  = 3600    if $window_secs < 3600;    # min 1h
            $window_secs  = 2592000 if $window_secs > 2592000; # max 30d
            $window_label = "${val}${unit}";
        } else {
            botNotice($self, $nick, "Unknown window '$w'. Use: 6h 12h 24h 7d 30d ...");
            return;
        }
    }

    # KD1/fix: search across all channels in PM
    my $kd_chan = (defined $channel && $channel =~ /^#/) ? $channel : undef;
    my @kd_entries_all;
    if ($kd_chan) {
        push @kd_entries_all, @{ $self->{_karma_log}{$kd_chan} // [] };
    } else {
        for my $ch (keys %{ $self->{_karma_log} // {} }) {
            push @kd_entries_all, @{ $self->{_karma_log}{$ch} // [] };
        }
    }
    my $now   = time();
    my $since = $now - $window_secs;
    my @entries = grep { lc($_->{nick}) eq $target && ($_->{ts} // 0) >= $since } @kd_entries_all;
    my $reply_to_kd = $kd_chan // $nick;
    unless (@entries) {
        botPrivmsg($self, $reply_to_kd,
            "$target: no karma changes in the last $window_label."); return 1;
    }
    my $delta = 0;
    $delta += (($_ ->{delta} // '') eq '+1' ? 1 : -1) for @entries;
    my $sign  = $delta > 0 ? '+' : '';

    # mb89-IMP1: top 3 givers dans la fenêtre
    my %givers_w;
    for my $e (@entries) {
        my $g = $e->{from} // $e->{giver} // '';
        $givers_w{$g}++ if $g;
    }
    my @top_givers = (sort { $givers_w{$b} <=> $givers_w{$a} || $a cmp $b }
                      keys %givers_w)[0..2];
    @top_givers = grep { defined } @top_givers;
    my $givers_str = @top_givers
        ? '  | by: ' . join(', ', map { "$_($givers_w{$_})" } @top_givers)
        : '';

    # CC11: fetch current score
    my $cur_score = undef;
    for my $ch (keys %{ $self->{_karma_log} // {} }) {
        my $klog = $self->{_karma_log}{$ch} // [];
        my ($last_e) = grep { lc($_->{nick}) eq lc($target) } reverse @$klog;
        if ($last_e && defined $last_e->{score}) {
            $cur_score = $last_e->{score}; last;
        }
    }
    my $score_info = defined $cur_score
        ? ', score: ' . ($cur_score >= 0 ? "+$cur_score" : "$cur_score")
        : '';

    botPrivmsg($self, $reply_to_kd,
        "$target: karma ${sign}${delta} in last $window_label ("
        . scalar(@entries) . " vote(s)$score_info)$givers_str");
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

    my $order = $bottom_mode ? 'ASC' : 'DESC';
    my $sth = $self->{dbh}->prepare(
        "SELECT nick, score FROM KARMA WHERE id_channel = ? ORDER BY score $order LIMIT ?"
    );
    unless ($sth && $sth->execute($id_channel, $n)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;

    unless (@rows) {
        botPrivmsg($self, $channel, "No karma data for $channel yet.");
        return 1;
    }

    # EE1: compute 24h delta per nick from _karma_log ring buffer
    my $klog    = $self->{_karma_log}{$channel} // [];
    my $now_ee1 = time();
    my %delta24;
    for my $e (@$klog) {
        next unless ($now_ee1 - ($e->{ts} // 0)) < 86400;
        $delta24{lc($e->{nick})} += (($e->{delta} // '') eq '+1' ? 1 : -1);
    }
    my $label = $bottom_mode ? "Karma bottom $n" : "Karma top $n";
    botPrivmsg($self, $channel, "$label on $channel:");
    my $rank = 1;
    for my $r (@rows) {
        my $sign = $r->{score} > 0 ? '+' : '';
        my $d    = $delta24{lc($r->{nick})} // 0;
        my $dstr = $d > 0 ? " (\x{2191}${d} today)"
                 : $d < 0 ? " (\x{2193}" . abs($d) . " today)"
                 : '';
        botPrivmsg($self, $channel, sprintf('  %2d. %-20s %s%d%s',
            $rank++, $r->{nick}, $sign, $r->{score}, $dstr));
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

    # mb85-IMP2: !roll history — show last 5 rolls on this channel
    if (@args && lc($args[0]) eq 'history') {
        my $hist = $self->{_roll_history}{$channel} // [];
        unless (@$hist) {
            botPrivmsg($self, $channel, "$nick: no roll history on $channel."); return 1;
        }
        botPrivmsg($self, $channel, 'Last rolls: ' . join('  |  ', reverse @$hist));
        return 1;
    }

    my ($num, $sides) = (1, 6);
    my $modifier = 0;   # mb85-IMP2: +N / -N bonus
    my $adv_mode = '';  # 'adv', 'dis', or ''

    if (@args && $args[0] =~ /^(\d+)d(\d+)$/i) {
        ($num, $sides) = ($1, $2);
        $num   = 1   if $num   < 1;  $num   = 20  if $num   > 20;
        $sides = 2   if $sides < 2;  $sides = 100 if $sides > 100;
    } elsif (@args && $args[0] =~ /^\d+$/) {
        $sides = int($args[0]);
        $sides = 2 if $sides < 2; $sides = 100 if $sides > 100;
    }

    # mb85-IMP2: parse trailing modifier (+N/-N) and adv/dis keyword
    for my $extra (@args[1..$#args]) {
        if ($extra =~ /^([+-]\d+)$/) {
            $modifier = int($1);
            $modifier =  100 if $modifier >  100;
            $modifier = -100 if $modifier < -100;
        } elsif ($extra =~ /^adv(?:antage)?$/i)    { $adv_mode = 'adv'; }
        elsif  ($extra =~ /^dis(?:advantage)?$/i)  { $adv_mode = 'dis'; }
    }

    my @results = map { int(rand($sides)) + 1 } 1..$num;
    my $label   = "${num}d${sides}";
    my $out;

    if ($adv_mode && $num == 1) {
        # adv/dis: roll twice, keep highest/lowest
        my $r2   = int(rand($sides)) + 1;
        my $kept = $adv_mode eq 'adv'
            ? ($results[0] >= $r2 ? $results[0] : $r2)
            : ($results[0] <= $r2 ? $results[0] : $r2);
        my $drop = $adv_mode eq 'adv'
            ? ($results[0] < $r2  ? $results[0] : $r2)
            : ($results[0] > $r2  ? $results[0] : $r2);
        my $total = $kept + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = sprintf('%s rolled %s (%s): [%d, ~~%d~~]%s  → %d',
            $nick, $label, $adv_mode, $kept, $drop, $mod_str, $total);
    } elsif ($num == 1) {
        my $total = $results[0] + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = "$nick rolled $label: $results[0]$mod_str";
    } else {
        my $sum = 0; $sum += $_ for @results;
        my $total = $sum + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : " = $sum";
        $out = sprintf('%s rolled %s: [%s]%s',
            $nick, $label, join(', ', @results), $mod_str);
    }

    # mb85-IMP2: keep rolling history (last 5 per channel)
    my $rh = $self->{_roll_history}{$channel} //= [];
    push @$rh, $out;
    splice @$rh, 0, @$rh - 5 if @$rh > 5;

    botPrivmsg($self, $channel, $out);
    logBot($self, $ctx->message, $channel, 'roll', $label);
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
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb85-IMP3: !flip stats — show heads/tails counts on this channel
    if (@args && lc($args[0]) eq 'stats') {
        my $fs = $self->{_flip_stats}{$channel} // { h => 0, t => 0 };
        my $total = $fs->{h} + $fs->{t};
        unless ($total) {
            botPrivmsg($self, $channel, "$nick: no flips yet on $channel."); return 1;
        }
        botPrivmsg($self, $channel, sprintf(
            '%s flip stats on %s: %d Heads (%.0f%%)  %d Tails (%.0f%%)  — %d total',
            $nick, $channel,
            $fs->{h}, 100*$fs->{h}/$total,
            $fs->{t}, 100*$fs->{t}/$total,
            $total));
        return 1;
    }

    # mb85-IMP3: !flip N — multi-flip (max 10)
    my $n = 1;
    if (@args && $args[0] =~ /^(\d+)$/) {
        $n = int($1); $n = 1 if $n < 1; $n = 10 if $n > 10;
    }

    my @results;
    my $fs = $self->{_flip_stats}{$channel} //= { h => 0, t => 0 };
    for (1..$n) {
        my $r = rand() < 0.5 ? 'H' : 'T';
        push @results, $r;
        $r eq 'H' ? $fs->{h}++ : $fs->{t}++;
    }

    if ($n == 1) {
        my $word = $results[0] eq 'H' ? 'Heads!' : 'Tails!';
        botPrivmsg($self, $channel, "$nick flipped a coin: $word");
    } else {
        my $heads = scalar grep { $_ eq 'H' } @results;
        my $tails = $n - $heads;
        my $seq   = join('', @results);
        $seq      =~ s/H/H/g; $seq =~ s/T/T/g;
        botPrivmsg($self, $channel, sprintf(
            '%s flipped %d coins: %s  (%d H, %d T)',
            $nick, $n, $seq, $heads, $tails));
    }
    logBot($self, $ctx->message, $channel, 'flip', join('', @results));
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
    my $use_date_filter = 0;
    my $date_filter = '';

    if (@args) {
        my $p = lc($args[0]);
        if ($p eq 'today') {
            # mb90-IMP2: activité du jour courant (depuis minuit)
            $date_filter     = "DATE(cl.ts) = CURDATE()";
            $use_date_filter = 1;
            $label           = 'today';
        } elsif ($p eq 'yesterday') {
            $date_filter     = "DATE(cl.ts) = CURDATE() - INTERVAL 1 DAY";
            $use_date_filter = 1;
            $label           = 'yesterday';
        } elsif ($p eq 'week') {
            $date_filter     = "cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $use_date_filter = 1;
            $label           = 'this week';
        } elsif ($p eq 'month') {
            $date_filter     = "YEAR(cl.ts) = YEAR(CURDATE()) AND MONTH(cl.ts) = MONTH(CURDATE())";
            $use_date_filter = 1;
            $label           = 'this month';
        } elsif ($p eq 'now') {
            $interval = '60 MINUTE';
            $label    = 'last 60min';
        } elsif ($p =~ /^(\d+)(d|h)$/i) {
            my ($v, $u) = ($1, lc $2);
            $interval = $u eq 'h' ? "$v HOUR" : "$v DAY";
            $label    = "last ${v}${u}";
        }
    }

    my $where_clause = $use_date_filter
        ? "c.name = ? AND $date_filter"
        : "c.name = ? AND cl.ts >= DATE_SUB(NOW(), INTERVAL $interval)";

    my $sth = $self->{dbh}->prepare(
        "SELECT cl.nick, COUNT(*) AS mc FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE $where_clause"
        . " GROUP BY cl.nick ORDER BY mc DESC LIMIT 30"
    );
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @nicks;
    while (my ($n, $mc) = $sth->fetchrow_array) { push @nicks, [$n, $mc]; }
    $sth->finish;

    if (@nicks) {
        # EE9: format as 'nick(msg_count)' pairs
        my $list = join(', ', map { ref $_ ? "$_->[0]($_->[1])" : $_ } @nicks);
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

    # mb105-IMP1: pour le mode 'now', ajouter aussi les nicks présents en ce moment (nicklist mémoire)
    if ($label eq 'last 60min') {
        my @online = eval { $self->gethChannelsNicksOnChan($channel) };
        if (@online) {
            my $active_set = { map { lc($_->[0]) => 1 } @nicks };
            my @online_only = grep { !$active_set->{lc($_)} } @online;
            if (@online_only) {
                my $silent = join(', ', sort @online_only);
                $silent = substr($silent, 0, 350) . '...' if length($silent) > 350;
                botPrivmsg($self, $channel,
                    "Present but silent in last 60min: $silent (" . scalar(@online_only) . " nick(s))");
            }
        }
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

    # HH10: also count total messages for richer output
    my $sth = $self->{dbh}->prepare(q{
        SELECT MIN(cl.ts) AS first_seen, COUNT(*) AS total_msgs FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
    });
    unless ($sth && $sth->execute($target, $channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my $row = $sth->fetchrow_hashref; $sth->finish;

    if ($row && $row->{first_seen}) {
        # V3: show age alongside raw date
        my $age_str = '';
        if ($row->{first_seen} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            require Time::Local;
            my ($y,$mo,$d) = ($1,$2,$3);
            my $then = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
            if ($then) {
                my $age   = int((time() - $then) / 86400);
                my $years = int($age / 365); $age -= $years * 365;
                my $months= int($age / 30);  $age -= $months * 30;
                my $days  = $age;
                if    ($years)  { $age_str = " (${years}y ${months}m ago)"; }
                elsif ($months) { $age_str = " (${months}m ${days}d ago)"; }
                else            { $age_str = " (${days}d ago)"; }
            }
        }
        my $tot_msgs = $row->{total_msgs} // 0;
        my $msgs_str = $tot_msgs > 0 ? ", $tot_msgs msg(s)" : "";
        botPrivmsg($self, $channel,
            "$target first seen on $channel: $row->{first_seen}$age_str$msgs_str");
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
    # DD8: deduplicate options (case-insensitive, preserve first occurrence)
    {
        my %seen;
        my @deduped = grep { !$seen{lc $_}++ } @raw_opts;
        if (scalar @deduped < scalar @raw_opts) {
            my $removed = scalar(@raw_opts) - scalar(@deduped);
            botNotice($self, $nick, "Note: $removed duplicate option(s) removed.");
        }
        @raw_opts = @deduped;
    }
    # U5: weighted choice — 'pizza:3' means pizza appears 3x in pool
    my @opts;
    for my $opt (@raw_opts) {
        if ($opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 20) {
            push @opts, ($1) x $2;
        } else {
            push @opts, $opt;
        }
    }
    # B-69-1/fix: guard against empty pool after dedup+weight
    unless (@opts) {
        botNotice($self, $nick, 'No valid options remain after deduplication.');
        return 1;
    }
    # BX-5/fix: better message when only 1 option remains
    unless (@opts >= 2) {
        my $msg = scalar(@opts) == 1
            ? "Only one option left after deduplication — nothing to choose from."
            : 'Syntax: choose <a> | <b>  or  choose <a> ou <b>  (at least 2 options).';
        botNotice($self, $nick, $msg);
        return;
    }
    my $choice = $opts[int(rand(scalar @opts))];
    $self->{_choose_last}{$channel} = $choice;  # X4: remember last choice
    # Y8: keep rolling history of 5 choices
    my $ch = $self->{_choose_history}{$channel} //= [];
    push @$ch, $choice;
    splice @$ch, 0, @$ch - 5 if @$ch > 5;
    # V3: show number of options for context
    my $n_opts = scalar @opts;
    botPrivmsg($self, $channel,
        "$nick: I choose... $choice!" . ($n_opts > 2 ? " (1 of $n_opts options)" : ""));
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
    # HH1: show source word count for context
    my $wcount = scalar @words;
    botPrivmsg($self, $channel, "$nick: $abbrev ($wcount word(s))");
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
        botNotice($self, $nick, 'Syntax: compare <nick1> <nick2> [Nd|Nw|Nm|all]  (ex: 7d 4w 3m)');
        return;
    }
    my ($t1, $t2) = (lc($args[0]), lc($args[1]));

    # mb86-IMP2: période optionnelle — 7d, 4w, 3m, 1y, all (défaut: all)
    my ($period_sql, $period_label) = ('', 'all time');
    if (@args >= 3) {
        my $p = lc($args[2]);
        if ($p =~ /^(\d+)d$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 DAY";
            $period_label = "last ${1}d";
        } elsif ($p =~ /^(\d+)w$/) {
            my $days = $1 * 7;
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $days DAY";
            $period_label = "last ${1}w";
        } elsif ($p =~ /^(\d+)m$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 MONTH";
            $period_label = "last ${1}m";
        } elsif ($p =~ /^(\d+)y$/) {
            $period_sql   = "AND cl.ts >= NOW() - INTERVAL $1 YEAR";
            $period_label = "last ${1}y";
        } elsif ($p eq 'all') {
            # explicit all — no filter
        } else {
            botNotice($self, $nick, "Unknown period '$p'. Use: 7d, 4w, 3m, 1y, all");
            return;
        }
    }

    my $sth = $self->{dbh}->prepare(qq{
        SELECT cl.nick, COUNT(*) AS cnt
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?,?)
        $period_sql
        GROUP BY cl.nick
    });
    unless ($sth && $sth->execute($channel, $t1, $t2)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my %counts;
    while (my $r = $sth->fetchrow_hashref) { $counts{$r->{nick}} = $r->{cnt}; }
    $sth->finish;
    my $c1 = $counts{$t1} // 0;
    my $c2 = $counts{$t2} // 0;
    my $diff = abs($c1 - $c2);
    my $leader = $c1 > $c2 ? $t1 : $c1 < $c2 ? $t2 : undef;
    my $verdict = $leader ? "$leader leads by $diff msg(s)" : 'tied!';
    my $tot_c = $c1 + $c2;
    my $p1 = $tot_c > 0 ? int(100*$c1/$tot_c) : 0;
    my $p2 = $tot_c > 0 ? 100 - $p1 : 0;
    botPrivmsg($self, $channel,
        "[$period_label] $t1: $c1 msg(s) ($p1%) | $t2: $c2 msg(s) ($p2%) | $verdict");
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
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @hours = (0) x 24;
    while (my $r = $sth->fetchrow_hashref) { $hours[$r->{h}] = $r->{cnt}; }
    $sth->finish;
    my $max = (sort { $b <=> $a } @hours)[0] || 1;
    # 6-hour blocks
    my @blocks = ('00-05', '06-11', '12-17', '18-23');
    my $grand_total = 0; $grand_total += $_ for @hours;
    # V15: afficher le total de messages en en-tête
    botPrivmsg($self, $channel,
        "$target activity by hour on $channel ($grand_total msgs total):");
    for my $b (0..3) {
        my $label = $blocks[$b];
        my @slice = @hours[$b*6 .. $b*6+5];
        my $total = 0; $total += $_ for @slice;
        my $bar_len = int(10 * $total / ($max * 6 || 1));
        $bar_len = 1 if $total > 0 && $bar_len == 0;
        # IMP22: IRC color codes — intensity: green < yellow < red
        my $ratio = $max > 0 ? $total / $max : 0;
        my $irc_color = $ratio >= 0.75 ? "\x0304"  # red
                      : $ratio >= 0.40 ? "\x0308"  # yellow
                      : $ratio >  0    ? "\x0303"  # green
                      :                  '';       # no color if 0
        my $reset = $irc_color ne '' ? "\x0f" : '';
        my $bar = $irc_color . chr(0x2588) x $bar_len . $reset
                . chr(0x2591) x (10 - $bar_len);
        botPrivmsg($self, $channel, sprintf('  %s  %s  %d msgs', $label, $bar, $total));
    }
    # V7: show peak time slot
    # mb84-B6: supprimé $peak_slot (code mort et calcul incorrect) — $peak_idx via @slot_totals est correct
    my @slot_labels = ("00-05", "06-11", "12-17", "18-23");
    my @slot_totals = map { my $s=$_; my $t=0; $t += ($hours[$s*6+$_] // 0) for 0..5; $t } 0..3;
    my ($peak_idx) = sort { $slot_totals[$b] <=> $slot_totals[$a] } 0..3;
    if ($slot_totals[$peak_idx] > 0) {
        botPrivmsg($self, $channel,
            "  Peak activity: $slot_labels[$peak_idx] ($slot_totals[$peak_idx] msgs)");
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

    # mb90-IMP3: !monthstats nick1 vs nick2 — mode comparaison côte à côte
    my ($t1, $t2);
    if (@args >= 3 && lc($args[1]) eq 'vs') {
        ($t1, $t2) = (lc($args[0]), lc($args[2]));
    }

    if (defined $t1 && defined $t2) {
        # Fetch counts for both nicks per month
        my $sth = $self->{dbh}->prepare(
            "SELECT DATE_FORMAT(cl.ts, '%Y-%m') AS ym, cl.nick, COUNT(*) AS cnt"
            . ' FROM CHANNEL_LOG cl'
            . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
            . ' WHERE cl.nick IN (?,?) AND c.name = ?'
            . '   AND cl.ts >= DATE_SUB(NOW(), INTERVAL 12 MONTH)'
            . ' GROUP BY ym, cl.nick ORDER BY ym'
        );
        unless ($sth && $sth->execute($t1, $t2, $channel)) {
            botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
        }
        my %by_month;
        while (my $r = $sth->fetchrow_hashref) {
            $by_month{$r->{ym}}{$r->{nick}} = $r->{cnt};
        }
        $sth->finish;
        unless (%by_month) {
            botPrivmsg($self, $channel, "No data found for $t1 or $t2 on $channel."); return 1;
        }
        my $max_c = 1;
        for my $ym (keys %by_month) {
            for my $n (keys %{ $by_month{$ym} }) {
                $max_c = $by_month{$ym}{$n} if $by_month{$ym}{$n} > $max_c;
            }
        }
        botPrivmsg($self, $channel, "$t1 vs $t2 on $channel (last 12 months):");
        my @parts;
        for my $ym (sort keys %by_month) {
            my $c1 = $by_month{$ym}{$t1} // 0;
            my $c2 = $by_month{$ym}{$t2} // 0;
            my $b1 = int(4 * $c1 / $max_c); $b1 = 1 if $c1 > 0 && $b1 == 0;
            my $b2 = int(4 * $c2 / $max_c); $b2 = 1 if $c2 > 0 && $b2 == 0;
            my $bar1 = chr(0x2588) x $b1 . chr(0x2591) x (4-$b1);
            my $bar2 = chr(0x2588) x $b2 . chr(0x2591) x (4-$b2);
            push @parts, "$ym $bar1/$bar2";
        }
        my @line1 = splice(@parts, 0, 6);
        my @line2 = @parts;
        botPrivmsg($self, $channel, "  $t1//$t2 — " . join('  ', @line1)) if @line1;
        botPrivmsg($self, $channel, '  ' . join('  ', @line2)) if @line2;
        return 1;
    }

    # Mode normal — un seul nick
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
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
    $sth->finish;
    unless (@rows) {
        botPrivmsg($self, $channel, "$target: no data in last 12 months on $channel.");
        return 1;
    }
    # V11: sparkline visuelle par mois
    my $max_m = (sort { $b <=> $a } map { $_->{cnt} } @rows)[0] || 1;
    my @parts;
    for my $r (@rows) {
        my $bar_len = int(5 * $r->{cnt} / $max_m);
        $bar_len = 1 if $r->{cnt} > 0 && $bar_len == 0;
        my $bar = chr(0x2588) x $bar_len . chr(0x2591) x (5 - $bar_len);
        push @parts, "$r->{ym} $bar $r->{cnt}";
    }
    botPrivmsg($self, $channel, "$target on $channel (last 12 months):");
    my @line1 = splice(@parts, 0, 6);
    my @line2 = @parts;
    botPrivmsg($self, $channel, '  ' . join('  ', @line1)) if @line1;
    botPrivmsg($self, $channel, '  ' . join('  ', @line2)) if @line2;
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
    require HTML::Entities;
    $first_def = HTML::Entities::decode_entities($first_def);  # mb84-B5: assigner la valeur de retour
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
    # mb104-IMP1: !trivia reset [nick] — réinitialiser score
    # Sans nick : reset all (Owner only). Avec nick : délègue à mbTriviaReset_ctx (Master)
    if (@args && lc($args[0]) eq 'reset') {
        if (@args > 1) {
            # Reset un nick spécifique — niveau Master suffit (mbTriviaReset_ctx)
            my @new_args = @args[1..$#args];
            $ctx->{args} = \@new_args;
            return mbTriviaReset_ctx($ctx);
        }
        # Reset all — Owner only
        return unless $ctx->require_level('Owner');
        my $sth_c = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        unless ($sth_c && $sth_c->execute($channel)) {
            botNotice($self, $nick, 'DB error.'); return;
        }
        my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
        unless ($rc) { botNotice($self, $nick, 'Channel not found.'); return; }
        my $sth = $self->{dbh}->prepare('DELETE FROM TRIVIA_SCORES WHERE id_channel = ?');
        unless ($sth && $sth->execute($rc->{id_channel})) {
            botNotice($self, $nick, 'DB error.'); $sth->finish if $sth; return;
        }
        my $rows = $sth->rows; $sth->finish;
        botPrivmsg($self, $channel, "All trivia scores reset on $channel ($rows row(s) deleted).");
        return 1;
    }


    if (@args && lc($args[0]) eq 'myscore') {
        my $target = @args > 1 ? lc($args[1]) : lc($nick);
        my $sth_ms = $self->{dbh}->prepare(q{
            SELECT ts.score, ts.last_correct,
                   (SELECT COUNT(*)+1 FROM TRIVIA_SCORES ts2
                    JOIN CHANNEL c2 ON c2.id_channel = ts2.id_channel
                    WHERE c2.name = ? AND ts2.score > ts.score) AS rank
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ? AND ts.nick = ?
        });
        unless ($sth_ms && $sth_ms->execute($channel, $channel, $target)) {
            botNotice($self, $nick, 'DB error.'); return;
        }
        my $r = $sth_ms->fetchrow_hashref; $sth_ms->finish;
        unless ($r) {
            botPrivmsg($self, $channel, "$target has no trivia score on $channel yet."); return 1;
        }
        botPrivmsg($self, $channel, sprintf(
            "Trivia score for %s on %s: %d correct answer(s)  |  rank #%d  |  last: %s",
            $target, $channel, $r->{score}, $r->{rank}, $r->{last_correct} // '?'));
        return 1;
    }


    if (@args && lc($args[0]) eq 'leaderboard') {
        my $limit = (defined $args[1] && $args[1] =~ /^\d+$/) ? int($args[1]) : 5;
        $limit = 1  if $limit < 1;
        $limit = 10 if $limit > 10;
        my $sth_lb = $self->{dbh}->prepare(q{
            SELECT ts.nick, ts.score, ts.last_correct
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ?
            ORDER BY ts.score DESC, ts.last_correct DESC
            LIMIT ?
        });
        unless ($sth_lb && $sth_lb->execute($channel, $limit)) {
            botNotice($self, $nick, 'DB error fetching leaderboard.'); return;
        }
        my @lb;
        while (my $r = $sth_lb->fetchrow_hashref) { push @lb, $r; }
        $sth_lb->finish;
        unless (@lb) {
            botPrivmsg($self, $channel, "No trivia scores yet on $channel."); return 1;
        }
        botPrivmsg($self, $channel, "Trivia leaderboard on $channel (top $limit):");
        my $rank = 1;
        for my $r (@lb) {
            botPrivmsg($self, $channel, sprintf("  %d. %-20s %d correct answer(s)  (last: %s)",
                $rank++, $r->{nick}, $r->{score}, $r->{last_correct} // '?'));
        }
        return 1;
    }

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
    # CC4: named category map — !trivia <name> maps to Open Trivia DB category ID
    my %trivia_cats = (
        general    => 9,  science    => 17, computers  => 18,
        maths      => 19, math       => 19, sports     => 21,
        geography  => 22, history    => 23, politics   => 24,
        art        => 25, celebrities=> 26, animals    => 27,
        vehicles   => 28, comics     => 29, gadgets    => 30,
        anime      => 31, manga      => 31, cartoons   => 32,
        tv         => 14, television => 14, music      => 12,
        film       => 11, movies     => 11, books      => 10,
        mythology  => 20, nature     => 27,
    );
    # !trivia categories — show available category names
    if (@args && lc($args[0]) eq 'categories') {
        botPrivmsg($self, $channel,
            'Trivia categories: ' . join(', ', sort keys %trivia_cats));
        return 1;
    }
    # X5: optional category filter
    my $trivia_cat = (@args && $args[0] !~ /^\d/ && $args[0] !~ /^(?:easy|medium|hard)$/i) ? lc(shift @args) : undef;
    my $trivia_cat_id = defined $trivia_cat ? ($trivia_cats{$trivia_cat} // undef) : undef;

    # mb105-IMP2: optional difficulty filter — easy / medium / hard
    my $trivia_diff;
    if (@args && $args[0] =~ /^(?:easy|medium|hard)$/i) {
        $trivia_diff = lc(shift @args);
    }

    # V1: increment round counter
    if ($self->{_trivia}{$channel}{multi_total}) {
        $self->{_trivia}{$channel}{multi_current}++;
        my $cur = $self->{_trivia}{$channel}{multi_current};
        my $tot = $self->{_trivia}{$channel}{multi_total};
        botPrivmsg($self, $channel, "Round $cur/$tot:");
    }
    my $http = Mediabot::External::_make_http(timeout => 8, verify_SSL => 1);
    # CC4: build URL with optional category ID + difficulty
    my $trivia_url = 'https://opentdb.com/api.php?amount=1&type=multiple';
    $trivia_url .= "&category=$trivia_cat_id" if defined $trivia_cat_id;
    $trivia_url .= "&difficulty=$trivia_diff" if defined $trivia_diff;
    my $res  = eval { $http->get($trivia_url) }
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
    # mb84-B1: preserve multi-round state and scores across question resets
    my $_prev     = $self->{_trivia}{$channel} // {};
    $self->{_trivia}{$channel} = {
        active         => 1,
        answer         => $answer_lc,
        answer_display => $answer,
        started        => time(),
        hint_given     => 0,   # B2/fix: reset hint_given for each new question
        category       => ($q->{category}   // undef),  # DD6: store for timeout display
        difficulty     => ($q->{difficulty} // undef),  # mb107-IMP1: store for correct reply
        scores         => ($_prev->{scores}       // {}),
        multi_total    => $_prev->{multi_total},       # mb84-B1: carry over round count
        multi_current  => $_prev->{multi_current},     # mb84-B1: carry over current round
    };
    my $opts = join('  ', map { "[$_]" } @choices);
    # mb106-IMP1: tag de difficulté dans la question
    my $diff_tag = '';
    if (defined $q->{difficulty} && $q->{difficulty} ne '') {
        my %diff_colors = ( easy => "\x0303", medium => "\x0308", hard => "\x0304" );
        my $dl = lc($q->{difficulty});
        my $col = $diff_colors{$dl} // '';
        $diff_tag = " ${col}[" . uc($dl) . "]\x0f" if $col;
        $diff_tag = " [" . uc($dl) . "]" unless $col;
    }
    botPrivmsg($self, $channel, "Trivia$diff_tag ($q->{category}): $question");
    botPrivmsg($self, $channel, "Choices: $opts -- reply with !answer <choice> or just say it (30s)");
    # mb111-IMP3: compteur Prometheus — questions posées
    $self->{metrics}->inc('mediabot_trivia_questions_total') if $self->{metrics};
    # Set a timeout via Scheduler or alarm — simplified: check in PRIVMSG hook
    # K3: configurable timeout (main.TRIVIA_TIMEOUT, default 30s)
    my $trivia_timeout = eval { int($self->{conf}->get('main.TRIVIA_TIMEOUT') // 30) } // 30;
    $trivia_timeout = 30 unless $trivia_timeout > 0 && $trivia_timeout <= 120;
    $self->{_trivia}{$channel}{timeout}  = $trivia_timeout;  # mb84-B2: stocker pour le hint
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
        # DD6: enriched timeout message with category + mb108-IMP1: difficulty
        my $cat_str  = $trivia->{category}   ? " ($trivia->{category})"  : '';
        my $diff_str = '';
        if (defined $trivia->{difficulty} && $trivia->{difficulty} ne '') {
            my %dc = ( easy => "\x0303", medium => "\x0308", hard => "\x0304" );
            my $dl = lc($trivia->{difficulty});
            my $c  = $dc{$dl} // '';
            $diff_str = $c ? " ${c}[" . uc($dl) . "]\x0f" : " [" . uc($dl) . "]";
        }
        Mediabot::Helpers::botPrivmsg($self, $channel,
            "Time's up!$diff_str The answer was: $trivia->{answer_display}${cat_str}");
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
                if ($sth_u) {
                    unless ($sth_u->execute($rc->{id_channel}, lc($nick))) {
                        $self->{logger}->log(1, "TRIVIA_SCORES persist execute failed: $DBI::errstr")
                            if $self->{logger};
                    }
                    $sth_u->finish;
                }
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
    my $diff_str = '';
    if (defined $trivia->{difficulty} && $trivia->{difficulty} ne '') {
        my %diff_colors = ( easy => "\x0303", medium => "\x0308", hard => "\x0304" );
        my $dl  = lc($trivia->{difficulty});
        my $col = $diff_colors{$dl} // '';
        $diff_str = $col ? " ${col}[" . uc($dl) . "]\x0f" : " [" . uc($dl) . "]";
    }
    Mediabot::Helpers::botPrivmsg($self, $channel,
        "Correct, $nick!$diff_str The answer was: $trivia->{answer_display}  (score: $score)");
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
        botPrivmsg($self, $channel, 'DB error.'); $sth_c->finish if $sth_c; return;
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
        botPrivmsg($self, $channel, 'DB error.'); $sth->finish if $sth; return;
    }
    my @ranked; my $i = 1;
    my @raw;  # JJ2: collect all rows first to compute total
    while (my $r = $sth->fetchrow_hashref) {
        push @raw, { nick => $r->{nick}, score => $r->{score}//0 };
    }
    $sth->finish;
    my $t_tot = 0; $t_tot += $_->{score} for @raw;
    for my $r (@raw) {
        my $pct = $t_tot > 0 ? sprintf(' (%.0f%%)', 100*$r->{score}/$t_tot) : '';
        push @ranked, "#${i}. $r->{nick}: $r->{score}$pct";
        $i++;
    }
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
        botNotice($self, $nick, 'DB error.'); $sth_c->finish if $sth_c; return;
    }
    my $rc = $sth_c->fetchrow_hashref; $sth_c->finish;
    unless ($rc) { botNotice($self, $nick, 'Channel not found.'); return; }
    my $sth = $self->{dbh}->prepare(
        'DELETE FROM TRIVIA_SCORES WHERE id_channel = ? AND nick = ?'
    );
    unless ($sth && $sth->execute($rc->{id_channel}, $target)) {
        botNotice($self, $nick, 'DB error.'); $sth->finish if $sth; return;
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
    # B-68-2/fix: clear scores and hint so next game starts clean
    delete $trivia->{scores};
    $trivia->{hint_given} = 0;
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
    # IMP17: also show total correct answers this session
    my $total_correct = 0; $total_correct += $scores->{$_} for keys %$scores;
    my $top = join(', ', map {
        my $pct = $total_correct > 0
            ? sprintf(' (%.0f%%)', 100*$scores->{$_}/$total_correct) : '';
        "$_: $scores->{$_}$pct"
    } @sorted[0..($#sorted > 4 ? 4 : $#sorted)]);
    botPrivmsg($self, $channel,
        "Trivia scores on $channel ($total_correct total): $top");
    logBot($self, $ctx->message, $channel, 'triviascore', '');  # Q1
    return 1;
}

1;
