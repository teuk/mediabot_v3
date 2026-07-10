package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm timelocal);
use Time::Piece;
use List::Util qw(min);
use Exporter 'import';

# mb348-B1: les statistiques basees sur CHANNEL_LOG filtrent les VRAIS messages
# via event_type IN ('public','action'), et non l'ancien faux proxy
# publictext IS NOT NULL (qui comptait aussi join/part/kick/mode/topic/notice).
# Le viewer de log brut .logs (_cmd_chanlog) reste volontairement non filtre.
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
    mbAchievements_ctx
    mbProfil_ctx
    mbRadar_ctx
    mbDashboard_ctx
    mbDuel_ctx
    mbHoroscope_ctx
    mbCompat_ctx
    mbQuotegame_ctx
    checkQuotegameAnswer
    mbMood_ctx
    mbMilestone_ctx
    mbLeaderboard_ctx
    mbChronos_ctx
    mbFeatures_ctx
    mbObservatory_ctx
    mbRecap_ctx
    mbLearn_ctx
    mbWhatis_ctx
    mbForget_ctx
    mbFactoids_ctx
    mbFactoid_ctx
    mbOnThisDay_ctx

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

    # mb123-B1 (defensive): early return if $sChannel is not a valid channel.
    # Avant ce fix, un appel avec un $sChannel vide ou bizarre pouvait quand
    # meme essayer de fetcher un notice (Q2) avec un WHERE name = '' qui
    # retourne 0 rows. Inoffensif mais bruite les logs.
    unless (defined $sChannel && $sChannel ne '' && $sChannel =~ /^[#&!+]/) {
        $self->{logger}->log(2,
            "userOnJoin() bogus channel arg: " . (defined $sChannel ? "'$sChannel'" : '(undef)'))
            if $self->{logger};
        return;
    }
    unless (defined $sNick && $sNick ne '') {
        $self->{logger}->log(2, "userOnJoin() missing nick")
            if $self->{logger};
        return;
    }

    # Try to match user from the IRC message
    my $user = $self->get_user_from_message($message);

    $self->{logger}->log(4,
        "userOnJoin() channel='$sChannel' nick='$sNick' user_id="
        . ($user ? $user->id : '(none)'))
        if $self->{logger};

    # mb123-B1: notice retrouve, soit via Q1 (user connu), soit via Q2.
    # On utilise une variable unique pour eviter toute confusion sur la
    # provenance du texte de notice.
    my $channel_notice;
    my $channel_notice_fetched = 0;

    if ($user) {
        # mb123-B1: SELECT precis au lieu de "uc.*, c.*".
        #
        # Avant ce fix, "SELECT uc.*, c.*" ramenait toutes les colonnes des
        # deux tables. Resultats indesirables :
        #   - uc.id_user et c.id_user portent le meme nom mais des valeurs
        #     differentes (le user qui join VS l'owner du canal). Le
        #     fetchrow_hashref ecrasait le premier par le second.
        #   - On gaspillait 13 colonnes (description, key, chanmode, topic, ...)
        #     pour n'en utiliser que 3 (greet, automode, notice).
        #
        # On selectionne maintenant explicitement les trois colonnes utiles
        # avec des alias non-ambigus.
        my $sql = q{
            SELECT uc.greet     AS uc_greet,
                   uc.automode  AS uc_automode,
                   c.notice     AS c_notice
            FROM USER_CHANNEL AS uc
            JOIN CHANNEL      AS c ON c.id_channel = uc.id_channel
            WHERE c.name = ? AND uc.id_user = ?
        };

        $self->{logger}->log(4, "userOnJoin() Q1 bind: name='$sChannel' id_user=" . $user->id)
            if $self->{logger};

        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth) {
            $self->{logger}->log(1,
                "userOnJoin() SQL prepare error: " . $DBI::errstr . " Query: $sql")
                if $self->{logger};
        }
        elsif ($sth->execute($sChannel, $user->id)) {
            if (my $ref = $sth->fetchrow_hashref()) {

                # Apply auto mode if defined
                my $auto_mode = $ref->{uc_automode};
                if (defined $auto_mode && $auto_mode ne '') {
                    if ($auto_mode eq 'OP') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+o", $sNick));
                    }
                    elsif ($auto_mode eq 'VOICE') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+v", $sNick));
                    }
                }

                # Send greet message to channel if defined
                my $greet = $ref->{uc_greet};
                if (defined $greet && $greet ne '') {
                    botPrivmsg($self, $sChannel, "($user->{nickname}) $greet");
                }

                # mb123-B1: on a deja le notice ici, pas besoin de Q2.
                # Cela elimine un round-trip et garantit que le notice
                # provient bien du *meme* canal que celui matche par Q1.
                $channel_notice         = $ref->{c_notice};
                $channel_notice_fetched = 1;
            }

            $sth->finish;
        }
        else {
            $self->{logger}->log(1,
                "userOnJoin() SQL execute error: " . $DBI::errstr . " Query: $sql")
                if $self->{logger};
            $sth->finish;
        }
    }

    # Q2: only if we didn't already fetch the notice in Q1.
    # This is the case for unknown users (no $user object) or known users
    # without a USER_CHANNEL row for this channel.
    unless ($channel_notice_fetched) {
        my $sql_channel = "SELECT notice FROM CHANNEL WHERE name = ?";

        $self->{logger}->log(4, "userOnJoin() Q2 bind: name='$sChannel'")
            if $self->{logger};

        my $sth = $self->{dbh}->prepare($sql_channel);

        unless ($sth) {
            $self->{logger}->log(1,
                "userOnJoin() channel SQL prepare error: " . $DBI::errstr . " Query: $sql_channel")
                if $self->{logger};
            return;
        }

        if ($sth->execute($sChannel)) {
            if (my $ref = $sth->fetchrow_hashref()) {
                $channel_notice = $ref->{notice};
            }
            $sth->finish;
        }
        else {
            $self->{logger}->log(1,
                "userOnJoin() channel SQL execute error: " . $DBI::errstr . " Query: $sql_channel")
                if $self->{logger};
            $sth->finish;
            return;
        }
    }

    # Send the notice to the user who just joined.
    # mb123-B1: log explicitly which channel's notice is being sent and to whom.
    if (defined $channel_notice && $channel_notice ne '') {
        $self->{logger}->log(3,
            "userOnJoin() sending '$sChannel' notice to '$sNick'")
            if $self->{logger};
        botNotice($self, $sNick, $channel_notice);
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
            $line = truncate_utf8($line, 357);
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
                    $line = truncate_utf8($line, 357);
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
    my $channel_obj = $self->{channels}{lc $channel} || $self->{channels}{lc($channel)};
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
                $line = truncate_utf8($line, 357);
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
        # mb127-B3: convert IRC glob (*, ?) to SQL LIKE while escaping literal
        # LIKE metacharacters from the user input. Without ESCAPE, nicks such
        # as "bob_foo*" made "_" behave as a wildcard.
        my $like_pat = '';
        for my $ch (split //, lc($target_input)) {
            if    ($ch eq '*') { $like_pat .= '%';  }
            elsif ($ch eq '?') { $like_pat .= '_';  }
            elsif ($ch eq '!') { $like_pat .= '!!'; }
            elsif ($ch eq '%') { $like_pat .= '!%'; }
            elsif ($ch eq '_') { $like_pat .= '!_'; }
            else               { $like_pat .= $ch;  }
        }
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
                WHERE nick LIKE ? ESCAPE '!' AND channel = ?
                ORDER BY seen_at DESC LIMIT 5
            };
            @bind_wc = ($like_pat, $chan_for_wc);
        } else {
            $sql_wc = q{
                SELECT nick, channel, seen_at, event_type
                FROM USER_SEEN
                WHERE nick LIKE ? ESCAPE '!'
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

    # mb497: sanitize a stored last_msg for display — strip IRC formatting
    # codes and control chars, collapse whitespace, bound length so a single
    # seen line stays readable on IRC.
    my $fmt_last = sub {
        my ($txt) = @_;
        return '' unless defined $txt && $txt ne '';
        $txt =~ s/[\x02\x0f\x16\x1d\x1f]//g;         # bold/reset/reverse/italic/underline
        $txt =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;       # mIRC colour codes
        $txt =~ s/[\x00-\x08\x0a-\x1f]/ /g;          # remaining control chars -> space
        $txt =~ s/\s{2,}/ /g;
        $txt =~ s/^\s+|\s+$//g;
        $txt = Mediabot::Helpers::truncate_utf8($txt, 200, '...') if length($txt) > 200;
        return $txt;
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
            my $channel_obj = $self->{channels}{lc $chan_for_part}
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
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen $ago"
                 . ($chan ? " on $chan" : '')
                 . ($last ne '' ? " saying: $last" : '');
        } elsif ($ev eq 'join') {
            $msg = "$targetNick ($host) was last seen joining $chan $ago";
        } elsif ($ev eq 'part') {
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen parting $chan $ago"
                 . ($last ne '' ? " ($last)" : '');
        } elsif ($ev eq 'quit') {
            my $last = $fmt_last->($seen_row->{last_msg});
            $msg = "$targetNick ($host) was last seen quitting $ago"
                 . ($last ne '' ? " ($last)" : '');
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

    # mb497: activity hint — append how many messages this nick posted in the
    # last 24h on the relevant channel, so "seen 3h ago" also tells you whether
    # they are an active regular or a ghost. Best-effort, never blocks the
    # answer; only when we can resolve a channel and the nick was actually seen.
    if ($msg !~ /^I don't remember/) {
        my $act_chan = $chan_for_part
            || ($seen_row ? $seen_row->{channel} : undef);
        if (defined $act_chan && $act_chan =~ /^[#&]/) {
            my $chan_obj = $self->{channels}{lc $act_chan};
            my $id_channel = $chan_obj ? eval { $chan_obj->get_id } : undef;
            if (defined $id_channel) {
                my $sth_act = $self->{dbh}->prepare(q{
                    SELECT COUNT(*) AS c
                    FROM CHANNEL_LOG
                    WHERE id_channel = ?
                      AND nick = ?
                      AND event_type IN ('public','action')
                      AND ts >= NOW() - INTERVAL 24 HOUR
                });
                if ($sth_act && eval { $sth_act->execute($id_channel, $targetNick) }) {
                    my $row = $sth_act->fetchrow_hashref;
                    $sth_act->finish;
                    my $c = $row ? ($row->{c} // 0) : 0;
                    $msg .= " [$c msg in last 24h]" if $c > 0;
                }
            }
        }
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

    # mb399-B1: calendrier LOCAL, cohérent avec l'annonce automatique
    # (check_birthdays_today utilise localtime). Avant, ce helper comptait en
    # gmtime : sur un serveur en Europe/Paris, entre minuit et 01:00/02:00
    # locales, "!birthday next" affichait "in 1d" un anniversaire qui était
    # déjà "today" (et déjà annoncé sur le canal).
    my @today = localtime($now);
    my $year  = $today[5] + 1900;

    my $today_epoch = timelocal(0, 0, 12, $today[3], $today[4], $year);

    for my $offset (0 .. 4) {
        my $candidate_year = $year + $offset;

        # mb434-R1: aligner "!birthday next" sur l'annonce automatique (mb433).
        # Un anniversaire du 29 février est OBSERVÉ le 28 février les années non
        # bissextiles (c'est ce jour-là que check_birthdays_today le fête).
        # Avant, ce helper sautait les années non bissextiles pour un 29/02 et
        # renvoyait le prochain 29 février réel (jusqu'à ~4 ans plus tard),
        # désaccordé avec l'annonce.
        my ($obs_month, $obs_day) = ($month, $day);
        if ($month == 2 && $day == 29) {
            my $leap = ($candidate_year % 4 == 0
                && ($candidate_year % 100 != 0 || $candidate_year % 400 == 0)) ? 1 : 0;
            ($obs_month, $obs_day) = (2, 28) unless $leap;
        }

        next unless _birthday_valid_date($candidate_year, $obs_month, $obs_day);

        my $candidate_epoch = eval {
            timelocal(0, 0, 12, $obs_day, $obs_month - 1, $candidate_year)
        };
        next unless defined $candidate_epoch;
        next if $candidate_epoch < $today_epoch;

        # mb399-B1: ARRONDI au plus proche, pas troncature : un midi->midi
        # local vaut 23 h le jour du passage à l'heure d'été (82800 s), que
        # int() tronquerait à 0 jour.
        return int(($candidate_epoch - $today_epoch) / 86400 + 0.5);
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
        # mb414-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_ks = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_ks) ? { id_channel => $cid_ks } : undef;
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
    # mb480: show unlocked achievement count on this channel, if any.
    if ($self->{achievements}) {
        my $ach = eval { $self->{achievements}->get_for_nick($target, $channel) };
        if (ref($ach) eq 'HASH') {
            my $n = scalar keys %$ach;
            $out .= " | achievements: $n" if $n > 0;
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

    # mb161-B2: calculer la PREMIERE occurrence des le depart.
    #
    # Avant ce fix, un `!remind daily 09:00 bob standup` cree a 14h00
    # n'inserait AUCUN tag [at:TS] -> deliverReminders le delivrait
    # immediatement (des que bob parlait, ex. 14h05) au lieu d'attendre
    # 09:00 le lendemain. Seules les RE-insertions (apres premiere
    # livraison) portaient le [at:TS] correct. Idem weekly : cree un mardi
    # pour 'weekly mon 10:00', il partait le mardi meme au premier message.
    #
    # On reutilise exactement la meme logique de calcul que la reinsertion
    # dans deliverReminders pour garantir la coherence.
    if ($remind_daily) {
        my ($hh, $mm) = split /:/, $daily_hhmm;
        my @now = localtime(time());
        my $today_delta = ($hh * 3600 + $mm * 60)
                        - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        my $next_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        my $first_ts  = time() + $next_secs;
        $message =~ s/^(\[daily:\d{2}:\d{2}\])\s*/$1 [at:$first_ts] /;
    }
    elsif ($remind_weekly) {
        my ($hh, $mm) = split /:/, $weekly_hhmm;
        my @now     = localtime(time());
        my $cur_dow = $now[6];  # 0=Sun..6=Sat
        my $days_ahead  = ($weekly_dow - $cur_dow + 7) % 7;
        my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        # Meme jour : si l'heure est deja passee (ou < 60s), reporter d'une semaine
        $days_ahead = 7 if $days_ahead == 0 && $time_offset <= 60;
        my $first_ts = time() + ($days_ahead * 86400) + $time_offset;
        $message =~ s/^(\[weekly:\d:\d{2}:\d{2}\])\s*/$1 [at:$first_ts] /;
    }

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
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
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
    # mb161-IMP1: pour daily/weekly, afficher la premiere occurrence calculee
    # (le [at:TS] insere par mb161-B2) au lieu d'un message generique.
    my $delay_info = '';
    if ($delay_secs > 0) {
        $delay_info = ' (due in ' . Mediabot::UserCommands::_seconds_to_human($delay_secs) . ')';
    }
    elsif (($remind_daily || $remind_weekly) && $message =~ /\[at:(\d+)\]/) {
        my $first_in = $1 - time();
        $delay_info = ' (first delivery in ' . Mediabot::UserCommands::_seconds_to_human($first_in) . ')'
            if $first_in > 0;
    }
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
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless $id_channel;

    # mb161-B1: scan large puis filtrer, au lieu de LIMIT 3 brut.
    #
    # Avant ce fix, le SELECT prenait les 3 plus anciens reminders pending
    # (ORDER BY created_at ASC LIMIT 3) PUIS filtrait les [at:TS] non-dus en
    # Perl. Si les 3 plus anciens etaient tous des reminders programmes dans
    # le futur (daily/weekly re-crees, ou 'remind in 7d'), ils monopolisaient
    # les 3 slots a chaque appel -> les reminders normaux plus recents
    # n'etaient JAMAIS delivres tant que les anciens n'etaient pas dus
    # (famine pouvant durer des jours).
    #
    # On scanne maintenant jusqu'a 20 rows et on ne delivre que les 3
    # premiers DUS, ce qui preserve la limite anti-flood de 3 par message.
    my $sth = $dbh->prepare(q{
        SELECT id_reminder, from_nick, message, created_at
        FROM REMINDERS
        WHERE id_channel = ? AND to_nick = ? AND delivered = 0
        ORDER BY created_at ASC
        LIMIT 20
    });
    return unless $sth && $sth->execute($id_channel, lc($nick));

    my @candidates;
    while (my $row = $sth->fetchrow_hashref) { push @candidates, $row; }
    $sth->finish;
    return unless @candidates;

    # mb161-B1: filtrer les non-dus AVANT de constituer la liste de livraison.
    my @pending;
    for my $row (@candidates) {
        if ($row->{message} =~ /\[at:(\d+)\]/) {
            next if time() < $1;   # pas encore du -> on ne le compte pas
        }
        push @pending, $row;
        last if @pending >= 3;     # limite anti-flood preservee
    }
    return unless @pending;

    for my $r (@pending) {
        # mb161-B1: le skip des non-dus est desormais fait en amont (boucle
        # @candidates). Ici on strip seulement les tags [at:TS] du message
        # avant livraison.
        if ($r->{message} =~ /\[at:(\d+)\]/) {
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

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $limit = 3;
    if (@args) {
        unless (@args == 1 && defined($args[0]) && $args[0] =~ /\A[1-3]\z/) {
            $ctx->reply_private('Syntax: calclast [1-3]');
            return 1;
        }
        $limit = int($args[0]);
    }

    my $history = $self->{_calc_history}{$nick} // [];
    unless (@$history) {
        $ctx->reply_private('No calc history yet.');
        return 1;
    }

    # mb331-B3: the documented optional count is now honored. Context keeps
    # the same public/private routing without duplicating transport logic.
    my $shown = min($limit, scalar(@$history));
    $ctx->reply('Last ' . $shown . ' calc(s) for ' . $nick . ':');
    for my $index (0 .. $shown - 1) {
        $ctx->reply('  ' . $history->[$index]);
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
        WHERE cl.nick = ? AND c.name = ? AND event_type IN ('public','action')
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
        # mb426-B1: la connexion DBI ne décode pas l'UTF-8 (pas de mariadb_utf8,
        # seulement SET NAMES) -> publictext arrive en OCTETS UTF-8. Un split
        # sur \W+ coupait sur chaque octet d'accent (café -> caf, réponse ->
        # r+ponse), faussant le comptage sur un canal francophone. On splitte
        # de façon byte-safe : les octets >= 0x80 (continuation/amorce des
        # séquences UTF-8 multi-octets) comptent comme des lettres, donc les
        # mots accentués restent entiers.
        $words{lc $_}++ for split /[^0-9A-Za-z_\x80-\xFF]+/, ($text // '');
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
                  AND cl2.event_type IN ('public','action')
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

    # mb115: hook achievements wordcount
    if ($self->{achievements}) {
        eval { $self->{achievements}->check_wordcount($target, $channel, $distinct) };
        if ($@) { $self->{logger}->log(1, "achievements check_wordcount error: $@"); }
    }
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

        # mb410-R1: id du canal depuis le cache interne (clé canonique lc,
        # mb407) — plus de SELECT par vote. La DB reste le repli si le canal
        # n'est pas (encore) dans le cache.
        my $vote_id_channel;
        my $vote_chan_obj = $self->{channels}{lc $channel};
        $vote_id_channel = $vote_chan_obj->get_id if $vote_chan_obj;
        unless ($vote_id_channel) {
            my $sth_vote_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
            if ($sth_vote_chan && $sth_vote_chan->execute($channel)) {
                my $vote_chan_row = $sth_vote_chan->fetchrow_hashref;
                $vote_id_channel = $vote_chan_row->{id_channel} if $vote_chan_row;
            }
            $sth_vote_chan->finish if $sth_vote_chan;
        }

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

    # mb410-R1: id du canal depuis le cache interne (mb407), SELECT en repli.
    my $id_channel;
    my $kchan_obj = $self->{channels}{lc $channel};
    $id_channel = $kchan_obj->get_id if $kchan_obj;
    unless ($id_channel) {
        my $sth_chan = $self->{dbh}->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
        if ($sth_chan && $sth_chan->execute($channel)) {
            my $r = $sth_chan->fetchrow_hashref;
            $sth_chan->finish;
            $id_channel = $r->{id_channel} if $r;
        }
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

    # mb413-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
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
        # mb140-B1: tracker les NICKS DISTINCTS au lieu des hits bruts.
        # Avant ce fix, brigade->{hits} etait un arrayref de timestamps qui
        # comptait toutes les tentatives de vote, meme celles deja bloquees
        # par le cooldown anti-spam plus bas. Resultat : un seul user qui
        # spam-vote 6 fois en 30s declenchait le message "Karma brigade
        # detected for X — votes temporarily blocked" alors qu'il n'y a
        # qu'un seul voteur (deja bloque par cooldown). Le commentaire dit
        # bien ">5 different nicks", mais le code ne distinguait pas.
        # On utilise maintenant un hashref { lc(nick) => last_ts } pour
        # compter les voteurs distincts dans la fenetre de 30s.
        my $brigade = $self->{_karma_brigade}{$brigade_key}
            //= { nicks => {}, warned => 0 };
        # mb140-B1 migration: ancien format (arrayref hits) -> nouveau (hash nicks)
        if (ref($brigade->{hits}) eq 'ARRAY' && !$brigade->{nicks}) {
            $brigade->{nicks} = {};
            delete $brigade->{hits};
        }
        $brigade->{nicks}{lc($nick)} = $now;
        # Purge entries older than 30s
        for my $k (keys %{ $brigade->{nicks} }) {
            delete $brigade->{nicks}{$k}
                if ($now - $brigade->{nicks}{$k}) >= 30;
        }
        my $distinct_voters = scalar keys %{ $brigade->{nicks} };
        if ($distinct_voters > 5) {
            unless ($brigade->{warned}) {
                $brigade->{warned} = 1;
                Mediabot::Helpers::botPrivmsg($self, $channel,
                    "Karma brigade detected for $target — votes temporarily blocked.");
                $self->{logger}->log(1,
                    "DD9: karma brigade on $target in $channel ($distinct_voters distinct voters)");
            }
            $self->{metrics}->inc('mediabot_karma_brigade_blocks') if $self->{metrics};
            next;
        }
        $brigade->{warned} = 0 if $distinct_voters <= 2;
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

        # mb115: hook achievements karma (positifs : score atteint, gift_giver pour le donneur)
        if ($self->{achievements}) {
            # Pour gift_giver, on compte les +1 donnés par $nick sur le canal — via ring buffer.
            # mb453-B1 (off-by-one): $given_pos était calculé AVANT que le vote
            # courant soit poussé dans _karma_log (le push est plus bas), donc le
            # don en cours n'était pas compté — gift_giver (seuil 100) se
            # débloquait au 101e don au lieu du 100e. On amorce à 1 quand le vote
            # courant est lui-même un don positif (++), 0 sinon.
            my $given_pos = ($op eq '++') ? 1 : 0;
            for my $e (@{ $self->{_karma_log}{$channel} // [] }) {
                $given_pos++ if defined $e->{from} && lc($e->{from}) eq lc($nick) && ($e->{delta} // '') eq '+1';
            }
            eval {
                $self->{achievements}->check_karma($target, $channel, $score, $nick, $given_pos);
            };
            if ($@) { $self->{logger}->log(1, "achievements check_karma error: $@"); }
        }

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
        # mb414-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_kl = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_kl) ? { id_channel => $cid_kl } : undef;
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
          AND cl.event_type IN ('public','action') AND cl.publictext != ''
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
    # mb160-B1: appliquer les poids en mode weighted (BB7).
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my $weighted_label = $weighted ? ' [weighted]' : '';
    botPrivmsg($self, $channel, "\"$poll->{question}\"${weighted_label} -- $total vote(s) so far:");
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#{ $poll->{options} }) {
            my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
            my $w      = $weights->[$idx] // 1;
            $weighted_total += $voters * $w;
        }
    }
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        if ($weighted) {
            my $w     = $weights->[$idx] // 1;
            my $score = $voters * $w;
            my $pct   = $weighted_total > 0 ? int($score * 100 / $weighted_total) : 0;
            botPrivmsg($self, $channel, sprintf('  [%d] %s (x%d): %d=%d (%d%%)',
                $idx+1, $poll->{options}[$idx], $w, $voters, $score, $pct));
        } else {
            my $pct = $total > 0 ? int($voters * 100 / $total) : 0;
            botPrivmsg($self, $channel, sprintf('  [%d] %s: %d (%d%%)',
                $idx+1, $poll->{options}[$idx], $voters, $pct));
        }
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
    # mb431-B1: si la deadline est déjà passée (l'expiration est paresseuse,
    # le sondage reste actif tant que personne n'a voté après l'échéance),
    # repartir de maintenant. Sinon `deadline_passée + $extra` restait dans le
    # passé -> "remaining" négatif et aucune vraie réouverture du vote.
    my $base = $poll->{deadline} // time();
    $base = time() if $base < time();
    $poll->{deadline} = $base + $extra;
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
    # mb160-B1: appliquer les poids quand le poll est en mode weighted (BB7).
    # Avant ce fix, $poll->{weights} etait stocke a la creation mais jamais
    # consulte dans tally/result/status -> mode 'weighted' completement dead.
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my @tally;
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#{ $poll->{options} }) {
            my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
            my $w = $weights->[$idx] // 1;
            $weighted_total += $voters * $w;
        }
    }
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $voters = scalar grep { $_ == $idx } values %{ $poll->{votes} };
        if ($weighted) {
            my $w     = $weights->[$idx] // 1;
            my $score = $voters * $w;
            my $pct   = $weighted_total > 0 ? int($score * 100 / $weighted_total) : 0;
            push @tally, sprintf('[%d] %s (x%d): %d=%d (%d%%)',
                $idx+1, $poll->{options}[$idx], $w, $voters, $score, $pct);
        } else {
            my $pct = $total > 0 ? int($voters * 100 / $total) : 0;
            push @tally, sprintf('[%d] %s: %d (%d%%)',
                $idx+1, $poll->{options}[$idx], $voters, $pct);
        }
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

    # mb160-B1: appliquer les poids en mode weighted (BB7). Sans cette
    # branche, le mode 'weighted' du poll etait sans effet : les poids
    # etaient parses et stockes mais jamais utilises dans le tally ni la
    # determination du gagnant.
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $weights  = $poll->{weights}  || [];
    my %weighted_scores;
    my $weighted_total = 0;
    if ($weighted) {
        for my $idx (0 .. $#options) {
            my $voters = $counts{$idx} // 0;
            my $w      = $weights->[$idx] // 1;
            $weighted_scores{$idx} = $voters * $w;
            $weighted_total += $voters * $w;
        }
    }

    my $status = $poll->{active} ? 'Active' : 'Closed';
    # DD8/MB306: show the winning label prominently and keep ties
    # deterministic. The previous sort started from hash keys, so equal scores
    # could select a different winner from one process to another.
    my @winner_opts;
    if ($total > 0) {
        my $best_score = -1;
        for my $idx (0 .. $#options) {
            my $score = $weighted
                ? ($weighted_scores{$idx} // 0)
                : ($counts{$idx} // 0);

            if ($score > $best_score) {
                $best_score = $score;
                @winner_opts = ($idx);
            }
            elsif ($score == $best_score) {
                push @winner_opts, $idx;
            }
        }
    }

    my $winner_str = '';
    if (@winner_opts == 1) {
        my $winner_opt   = $winner_opts[0];
        my $winner_label = $options[$winner_opt] // 'option ' . ($winner_opt + 1);
        if ($weighted && $weighted_total > 0) {
            my $wpct = sprintf('%.0f%%', 100 * ($weighted_scores{$winner_opt} // 0) / $weighted_total);
            $winner_str = "  Winner: $winner_label ($wpct weighted)";
        } else {
            my $wpct = sprintf('%.0f%%', 100 * ($counts{$winner_opt} // 0) / $total);
            $winner_str = "  Winner: $winner_label ($wpct)";
        }
    }
    elsif (@winner_opts > 1) {
        my @winner_labels = map {
            $options[$_] // 'option ' . ($_ + 1)
        } @winner_opts;
        $winner_str = '  Tie: ' . join(', ', @winner_labels);
    }
    my $weighted_label = $weighted ? ' [weighted]' : '';
    botPrivmsg($self, $channel, "$status poll${weighted_label}: \"$poll->{question}\" ($total vote(s))$winner_str");
    for my $i (0 .. $#options) {
        my $c   = $counts{$i} // 0;
        if ($weighted) {
            my $w     = $weights->[$i] // 1;
            my $score = $weighted_scores{$i} // 0;
            my $pct   = $weighted_total > 0
                ? sprintf('%.0f%%', 100 * $score / $weighted_total)
                : '0%';
            botPrivmsg($self, $channel,
                sprintf('  [%d] %-20s (x%d) %d vote(s) = %d (%s)',
                    $i+1, $options[$i], $w, $c, $score, $pct));
        } else {
            my $pct = $total > 0 ? sprintf('%.0f%%', 100 * $c / $total) : '0%';
            botPrivmsg($self, $channel,
                sprintf('  [%d] %-20s %d vote(s) (%s)', $i+1, $options[$i], $c, $pct));
        }
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
    $self->{metrics}->inc('mediabot_poll_closed_total') if $self->{metrics};

    # MB306: keep !pollstop consistent with !pollresult.
    # The old code announced the zero-based option index as the winner and
    # ignored weighted poll scores entirely.
    my $votes    = $poll->{votes}   // {};
    my $opts     = $poll->{options} // [];
    my $weights  = $poll->{weights} // [];
    my $weighted = $poll->{weighted} ? 1 : 0;
    my $total    = scalar(keys %$votes);

    my $duration = int(time() - ($poll->{started} // time()));
    $duration = 0 if $duration < 0;
    $self->{metrics}->set('mediabot_poll_duration_seconds', $duration)
        if $self->{metrics};

    if ($total > 0) {
        my %counts;
        $counts{$votes->{$_}}++ for keys %$votes;

        my %scores;
        my $score_total = 0;
        for my $idx (0 .. $#$opts) {
            my $voters = $counts{$idx} // 0;
            my $weight = $weights->[$idx] // 1;
            my $score  = $weighted ? ($voters * $weight) : $voters;
            $scores{$idx} = $score;
            $score_total += $score;
        }

        my $best_score = -1;
        my @winners;
        for my $idx (0 .. $#$opts) {
            my $score = $scores{$idx} // 0;
            if ($score > $best_score) {
                $best_score = $score;
                @winners = ($idx);
            }
            elsif ($score == $best_score) {
                push @winners, $idx;
            }
        }

        if (@winners > 1) {
            my @labels = map { $opts->[$_] // 'option ' . ($_ + 1) } @winners;
            my $basis = $weighted ? 'weighted score' : 'votes';
            botPrivmsg($self, $channel,
                "Poll closed ($total vote(s)). Tie on $basis: "
                . join(', ', @labels)
                . ". Use !pollresult for details.");
        }
        else {
            my $winner       = $winners[0];
            my $winner_label = $opts->[$winner] // 'option ' . ($winner + 1);
            my $winner_votes = $counts{$winner} // 0;
            my $winner_score = $scores{$winner} // 0;
            my $pct = $score_total > 0
                ? int(100 * $winner_score / $score_total)
                : 0;

            my $details = $weighted
                ? "$winner_votes vote(s), weighted score $winner_score/$score_total, ${pct}%"
                : "$winner_votes/$total, ${pct}%";

            botPrivmsg($self, $channel,
                "Poll closed ($total vote(s)). Winner: $winner_label "
                . "($details). Use !pollresult for details.");
        }
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
# mb437-B1: charge les notes d'un nick depuis la DB dans le cache mémoire si
# celui-ci est vide (typiquement après un restart). Partagé par mbNote_ctx
# (ajout) et mbNotes_ctx (liste) : sans ce chargement côté ajout, le plafond
# de 10 notes était évalué contre une liste mémoire vide au premier !note
# suivant un redémarrage -> plafond contourné et notes au-delà de 10
# invisibles (SELECT ... LIMIT 10).
sub _notes_ensure_loaded {
    my ($self, $nick) = @_;
    my $key = lc $nick;
    return if @{ $self->{_notes}{$key} // [] };
    eval {
        my $sth = $self->{dbh}->prepare(
            'SELECT id_note, text FROM NOTE WHERE nick = ? ORDER BY id_note ASC LIMIT 10'
        );
        if ($sth && $sth->execute($key)) {
            my @db_notes;
            while (my $r = $sth->fetchrow_hashref) {
                push @db_notes, { id => $r->{id_note}, text => $r->{text} };
            }
            $sth->finish;
            $self->{_notes}{$key} = \@db_notes if @db_notes;
        }
    };
}

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
    # mb456-B1: all note operations must see the persisted state after a
    # restart. mb437 loaded the DB before add/list, but export/search still
    # inspected the empty in-memory cache and falsely reported no notes.
    $self->{_notes}{lc $nick} //= [];
    _notes_ensure_loaded($self, $nick);

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
        # mb460-B1: keep each hit's index in the FULL notes list. The displayed
        # [N] must match the index that `!notes del <N>` expects; numbering hits
        # positionally (1..@hits) pointed the user at the wrong note to delete
        # when the matches weren't the first notes.
        my @hits;
        for my $idx (0 .. $#$notes) {
            my $n   = $notes->[$idx];
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            push @hits, [ $idx, $n ] if lc($txt) =~ /\Q$query\E/;
        }

        unless (@hits) {
            botNotice($self, $nick, "No notes matching '$query'."); return 1;
        }

        # II17: show count + search term
        botNotice($self, $nick, scalar(@hits) . "/" . scalar(@$notes)
            . " note(s) matching '$query':");
        for my $h (@hits) {
            my ($idx, $n) = @$h;
            my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
            # [idx+1] = position in the full list = the !notes del index
            botNotice($self, $nick, "  [" . ($idx + 1) . "] $txt");
        }
        return 1;
    }
    unless ($text ne '') {
        botNotice($self, $nick, 'Syntax: note <message>  or  note search <word>'); return;
    }
    # mb437/mb456: the persisted notes were loaded above before every
    # branch, including export/search and the add cap.
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

    # BB1 / mb437-B1: load from DB if memory is empty (e.g. after restart)
    _notes_ensure_loaded($self, $nick);
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
# ---------------------------------------------------------------------------
# _karma_current_score($self, $nick)  (mb459-B1)
# Shared "current karma score": the score of the MOST RECENT karma_log entry
# (max ts) for $nick across ALL channels, or undef if none.
#
# Single source of truth for the selection that was copy-pasted (and identically
# buggy) in !karmawatch list (mb457) and !karmadiff (mb458): both used
# `keys %_karma_log` (hash order) + `last`, returning an arbitrary/stale
# channel's score. Centralising the max-ts logic keeps them deterministic and
# stops the pattern from being re-introduced by copy-paste.
# ---------------------------------------------------------------------------
sub _karma_current_score {
    my ($self, $nick, $channel) = @_;

    # mb464-B1: karma scores are channel-scoped in SQL.  When a caller is
    # operating in a channel (notably !karmadiff), only that channel may supply
    # the displayed "current" score.  PM/global callers keep the historical
    # all-channel view.  Sort channel keys and apply an explicit tie-break so
    # two votes recorded in the same integer second never reintroduce hash-order
    # nondeterminism.
    my @channels = sort { lc($a) cmp lc($b) || $a cmp $b }
                   keys %{ $self->{_karma_log} // {} };
    if (defined $channel && $channel ne '') {
        @channels = grep { lc($_) eq lc($channel) } @channels;
    }

    my ($best, $best_ts, $best_channel, $best_index);
    for my $ch (@channels) {
        my $entries = $self->{_karma_log}{$ch} // [];
        for my $idx (0 .. $#$entries) {
            my $e = $entries->[$idx];
            next unless defined $e->{nick}
                     && lc($e->{nick}) eq lc($nick)
                     && defined $e->{score};

            my $ts = $e->{ts} // 0;
            my $channel_key = lc($ch);
            if (!defined $best
                || $ts > $best_ts
                || ($ts == $best_ts && $channel_key gt $best_channel)
                || ($ts == $best_ts && $channel_key eq $best_channel
                    && $idx > $best_index)) {
                ($best, $best_ts, $best_channel, $best_index)
                    = ($e, $ts, $channel_key, $idx);
            }
        }
    }
    return defined $best ? $best->{score} : undef;
}

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
        # IMP19: show current karma score for each watched nick.
        # mb459-B1: delegate to the shared _karma_current_score() helper
        # (most recent entry, max ts, all channels) — single source of truth.
        my @watch_with_scores;
        for my $wt (@$watching) {
            my $sc = _karma_current_score($self, $wt);
            my $score_str = defined $sc ? ($sc >= 0 ? "+$sc" : "$sc") : '';
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

    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_kr = Mediabot::Helpers::channel_id_cached($self, $channel);
    return unless defined $cid_kr;
    my $rc = { id_channel => $cid_kr };

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

    # CC11: fetch current score.
    # mb459/mb464: shared _karma_current_score() helper.  In a channel, the
    # displayed score is scoped to that same channel; in PM, it uses the
    # deterministic all-channel view (see also !karmawatch list).
    my $cur_score = _karma_current_score($self, $target, $kd_chan);
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

    # mb413-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel);
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
        # mb425-R1: le dé écarté était affiché "~~8~~" (barré Markdown/Discord),
        # rendu en tildes littéraux sur IRC. On utilise le vrai code de barré
        # IRC \x1e (rendu par mIRC/HexChat/WeeChat/Kiwi) + \x0f de reset, en
        # gardant le nombre lisible même sur un client qui l'ignore.
        my $drop_str = "\x1e$drop\x0f";
        $out = sprintf('%s rolled %s (%s): [%d, %s]%s  → %d',
            $nick, $label, $adv_mode, $kept, $drop_str, $mod_str, $total);
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
# _define_pick_entry($data, $preferred_lang)
# Select a usable Wiktionary entry deterministically. The REST response is a
# hash keyed by language; using `values %$data` made the chosen language depend
# on Perl hash order whenever several language blocks were returned.
# ---------------------------------------------------------------------------
sub _define_pick_entry {
    my ($data, $preferred_lang) = @_;

    return unless ref($data) eq 'HASH';

    my @keys;
    if (defined($preferred_lang)
            && !ref($preferred_lang)
            && exists $data->{$preferred_lang}) {
        push @keys, $preferred_lang;
    }

    push @keys, grep {
        !defined($preferred_lang) || $_ ne $preferred_lang
    } sort keys %$data;

    for my $lang_key (@keys) {
        my $entries = $data->{$lang_key};
        next unless ref($entries) eq 'ARRAY';

        for my $entry (@$entries) {
            next unless ref($entry) eq 'HASH';

            my $definitions = $entry->{definitions};
            next unless ref($definitions) eq 'ARRAY';

            for my $definition (@$definitions) {
                next unless ref($definition) eq 'HASH';

                my $text = $definition->{definition};
                next unless defined($text) && !ref($text) && $text ne '';

                return ($entry, $text, $lang_key);
            }
        }
    }

    return;
}

# Perform the existing Wiktionary lookup synchronously. Runtime IRC commands
# call it only from _define_lookup_async(); the synchronous form remains useful
# for lightweight tests and callers without a usable IO::Async loop.
sub _define_lookup_sync {
    my ($self, $word, $lang) = @_;

    return 'define: invalid lookup.'
        unless defined($word) && !ref($word) && $word ne '';

    $lang = 'en'
        unless defined($lang) && !ref($lang) && $lang =~ /\A[a-z]{2,5}\z/;

    require URI::Escape;
    # mb436-B1: $word est en octets UTF-8. uri_escape_utf8() sur des octets
    # double-encode (café -> %C3%83%C2%A9 au lieu de %C3%A9) -> mauvaise URL.
    # On échappe directement les octets (déjà UTF-8) ; si par sécurité la chaîne
    # était en caractères (flag utf8), on la ré-encode d'abord.
    my $word_bytes = utf8::is_utf8($word) ? Encode::encode('UTF-8', $word) : $word;
    my $encoded = URI::Escape::uri_escape($word_bytes, "^A-Za-z0-9\-\._~");
    my $url = "https://$lang.wiktionary.org/api/rest_v1/page/definition/$encoded";

    my $http = Mediabot::External::_make_http(
        timeout    => 8,
        verify_SSL => 1,
        max_size   => 512 * 1024,
    );

    my $res = eval {
        $http->get($url, { headers => { Accept => 'application/json' } });
    } // { success => 0 };

    return "define: could not fetch definition for '$word'."
        unless ref($res) eq 'HASH' && $res->{success};

    require JSON;
    my $data = eval { JSON::decode_json($res->{content} // '') };

    return "define: no result for '$word'."
        if $@ || ref($data) ne 'HASH';

    my ($entry, $first_def, $entry_lang) = _define_pick_entry($data, $lang);

    return "define: no definition found for '$word' in $lang.wiktionary."
        unless $entry && defined($first_def);

    my $pos = $entry->{partOfSpeech};
    $pos = '' unless defined($pos) && !ref($pos);
    $pos =~ s/^\s+|\s+$//g;

    $first_def =~ s/<[^>]+>//g;

    require HTML::Entities;
    $first_def = HTML::Entities::decode_entities($first_def);
    $first_def =~ s/[\r\n\t]+/ /g;
    $first_def =~ s/\s{2,}/ /g;
    $first_def =~ s/^\s+|\s+$//g;
    $first_def = substr($first_def, 0, 300) . '...'
        if length($first_def) > 300;

    return "define: no definition found for '$word' in $lang.wiktionary."
        if $first_def eq '';

    $entry_lang = $lang
        unless defined($entry_lang) && !ref($entry_lang) && $entry_lang ne '';

    my $lang_tag = $entry_lang ne 'en' ? " [$entry_lang]" : '';
    my $pos_tag  = $pos ne '' ? " ($pos)" : '';

    return "$word$lang_tag$pos_tag: $first_def";
}

# MB318: Wiktionary HTTP and DNS work must not run in the IRC event loop.
# Execute the existing synchronous lookup in a forked child and consume its
# bounded result through IO::Async.
sub _define_lookup_async {
    my ($self, $word, $lang, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 10
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 20  if $timeout > 20;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    my $fallback = "define: could not fetch definition for '$word'.";

    # Compatibility path for lightweight tests or emergency callers without a
    # usable IO::Async loop. The normal runtime path always uses the child.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $message = eval { _define_lookup_sync($self, $word, $lang) };
        $message = $fallback
            unless defined($message) && !ref($message) && $message ne '';
        eval { $callback->($message); 1; };
        return 1;
    }

    require IO::Async::Stream;
    require IO::Async::Timer::Countdown;
    require JSON::PP;

    my $child_pid = open(my $pipe, '-|');

    unless (defined $child_pid) {
        eval { $callback->($fallback); 1; };
        return 1;
    }

    if ($child_pid == 0) {
        my $message = eval { _define_lookup_sync({}, $word, $lang) };
        $message = $fallback
            unless defined($message) && !ref($message) && $message ne '';
        $message = substr($message, 0, 1024);

        my $payload = eval { JSON::PP::encode_json({ message => $message }) };
        $payload = JSON::PP::encode_json({ message => $fallback })
            unless defined($payload) && !ref($payload) && $payload ne '';

        my $offset = 0;
        local $SIG{PIPE} = 'IGNORE';
        binmode(STDOUT, ':raw');

        while ($offset < length($payload)) {
            my $written = syswrite(
                STDOUT,
                $payload,
                length($payload) - $offset,
                $offset,
            );

            next if !defined($written) && $!{EINTR};
            last unless defined($written) && $written > 0;
            $offset += $written;
        }

        POSIX::_exit(0);
    }

    my $state = {
        output      => '',
        pipe_eof    => 0,
        child_done  => 0,
        finalized   => 0,
        timed_out   => 0,
        wait_failed => 0,
        wait_status => undef,
        term_sent   => 0,
        kill_sent   => 0,
    };

    my ($stream, $timeout_timer, $kill_timer, $reap_timer);
    my ($finish, $schedule_reap);

    my $remove_timer = sub {
        my ($timer) = @_;
        return unless $timer;
        eval { $timer->stop };
        eval { $loop->remove($timer) };
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{child_done};
        return unless $state->{pipe_eof} || $state->{timed_out};

        $state->{finalized} = 1;

        $remove_timer->($timeout_timer);
        $remove_timer->($kill_timer);
        $remove_timer->($reap_timer);
        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };

        my $message = $fallback;

        unless ($state->{timed_out} || $state->{wait_failed}) {
            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if (!$signal && $exit == 0) {
                my $decoded = eval { JSON::PP::decode_json($state->{output} // '') };
                if (!$@ && ref($decoded) eq 'HASH') {
                    my $candidate = $decoded->{message};
                    $message = $candidate
                        if defined($candidate)
                            && !ref($candidate)
                            && $candidate ne ''
                            && length($candidate) <= 1024;
                }
            }
        }

        my $callback_ok = eval { $callback->($message); 1; };
        if (!$callback_ok && $self && ref($self) && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "define async callback failed: $error");
        }

        $finish        = undef;
        $schedule_reap = undef;
    };

    $schedule_reap = sub {
        return if $state->{finalized} || $state->{child_done};
        return if $reap_timer;

        $reap_timer = IO::Async::Timer::Countdown->new(
            delay     => 0.05,
            on_expire => sub {
                my $expired = $reap_timer;
                $reap_timer = undef;
                $remove_timer->($expired);

                return if $state->{finalized};

                my $waited = waitpid($child_pid, POSIX::WNOHANG());

                if ($waited == $child_pid) {
                    $state->{wait_status} = $?;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                if ($waited == -1) {
                    $state->{wait_failed} = 1;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                $schedule_reap->();
            },
        );

        $loop->add($reap_timer);
        $reap_timer->start;
    };

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => $timeout,
        on_expire => sub {
            return if $state->{finalized};

            $state->{timed_out} = 1;

            unless ($state->{term_sent}) {
                kill 'TERM', $child_pid;
                $state->{term_sent} = 1;
            }

            $schedule_reap->();

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.2,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};

                    my $waited = waitpid($child_pid, POSIX::WNOHANG());

                    if ($waited == $child_pid) {
                        $state->{wait_status} = $?;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    if ($waited == -1) {
                        $state->{wait_failed} = 1;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    unless ($state->{kill_sent}) {
                        kill 'KILL', $child_pid;
                        $state->{kill_sent} = 1;
                    }

                    $schedule_reap->();
                },
            );

            $loop->add($kill_timer);
            $kill_timer->start;
        },
    );

    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($io, $buffref, $eof) = @_;

            return 0 if $state->{finalized};

            if (length $$buffref) {
                my $remaining = 4096 - length($state->{output});
                $state->{output} .= substr($$buffref, 0, $remaining)
                    if $remaining > 0;
                $$buffref = '';
            }

            if ($eof && !$state->{pipe_eof}++) {
                eval { $loop->remove($io) };
                $schedule_reap->();
            }

            return 0;
        },
    );

    $loop->add($stream);
    return 1;
}

# ---------------------------------------------------------------------------
# mbDefine_ctx --- !define <word>
# Fetch a definition from Wiktionary without blocking the IRC event loop.
# ---------------------------------------------------------------------------
sub mbDefine_ctx {
    my ($ctx) = @_;
    my $self = $ctx->bot;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $word = join('_', @args);
    $word =~ s/^\s+|\s+$//g;

    unless ($word ne '') {
        $ctx->reply_private('Syntax: define <word>');
        return;
    }

    # mb436-B1: validation byte-safe. Les args viennent d'IRC en OCTETS UTF-8 ;
    # avec [^\w\s-] les octets d'accent (0xC3, 0xA9...) étaient rejetés, donc
    # "!define café" répondait "Invalid word.". On autorise les octets >= 0x80
    # (séquences UTF-8 multi-octets) comme faisant partie du mot.
    if ($word =~ /[^\w\s\x80-\xFF-]/ || length($word) > 64) {
        $ctx->reply_private('Invalid word.');
        return;
    }

    my $lang = eval { $self->{conf}->get('main.DEFINE_LANG') } // 'en';
    $lang = 'en' unless $lang =~ /\A[a-z]{2,5}\z/;

    return _define_lookup_async(
        $self,
        $word,
        $lang,
        sub {
            my ($message) = @_;
            $message = "define: could not fetch definition for '$word'."
                unless defined($message) && !ref($message) && $message ne '';
            $ctx->reply($message);
        },
    );
}


# ---------------------------------------------------------------------------
# _trivia_parse_api_content($json)
# Validate and normalize one Open Trivia DB multiple-choice question.
# This pure helper keeps malformed remote data away from the live game state.
# ---------------------------------------------------------------------------
sub _trivia_parse_api_content {
    my ($content, $meta) = @_;

    $meta = undef unless ref($meta) eq 'HASH';

    unless (defined($content) && !ref($content)) {
        $meta->{error} = 'content_type' if $meta;
        return;
    }

    if (length($content) == 0 || length($content) > 64 * 1024) {
        $meta->{error} = 'content_size' if $meta;
        return;
    }

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($content) };
    if ($@ || ref($data) ne 'HASH') {
        $meta->{error} = 'json' if $meta;
        return;
    }

    if (exists $data->{response_code}) {
        my $response_code = $data->{response_code};

        unless (defined($response_code)
                && !ref($response_code)
                && $response_code =~ /\A\d+\z/) {
            $meta->{error} = 'response_code' if $meta;
            return;
        }

        $response_code = int($response_code);
        $meta->{response_code} = $response_code if $meta;

        if ($response_code != 0) {
            $meta->{error} = 'api_response' if $meta;
            return;
        }
    }

    my $results = $data->{results};
    unless (ref($results) eq 'ARRAY' && @$results) {
        $meta->{error} = 'results' if $meta;
        return;
    }

    my $question = $results->[0];
    unless (ref($question) eq 'HASH') {
        $meta->{error} = 'question_type' if $meta;
        return;
    }

    my $question_text = $question->{question};
    my $correct       = $question->{correct_answer};
    my $incorrect     = $question->{incorrect_answers};

    unless (defined($question_text)
            && !ref($question_text)
            && $question_text ne ''
            && length($question_text) <= 2048) {
        $meta->{error} = 'question_text' if $meta;
        return;
    }

    unless (defined($correct)
            && !ref($correct)
            && $correct ne ''
            && length($correct) <= 512) {
        $meta->{error} = 'correct_answer' if $meta;
        return;
    }

    unless (ref($incorrect) eq 'ARRAY'
            && @$incorrect >= 1
            && @$incorrect <= 10) {
        $meta->{error} = 'incorrect_answers' if $meta;
        return;
    }

    my @wrong;
    for my $answer (@$incorrect) {
        unless (defined($answer)
                && !ref($answer)
                && $answer ne ''
                && length($answer) <= 512) {
            $meta->{error} = 'incorrect_answer' if $meta;
            return;
        }
        push @wrong, $answer;
    }

    my $category = $question->{category};
    $category = 'Unknown'
        unless defined($category)
            && !ref($category)
            && $category ne ''
            && length($category) <= 256;

    my $difficulty = $question->{difficulty};
    $difficulty = ''
        unless defined($difficulty)
            && !ref($difficulty)
            && $difficulty =~ /\A(?:easy|medium|hard)\z/i;

    delete $meta->{error} if $meta;

    return {
        question          => $question_text,
        correct_answer    => $correct,
        incorrect_answers => \@wrong,
        category          => $category,
        difficulty        => lc($difficulty),
    };
}

# Perform the Open Trivia DB request synchronously. Runtime IRC commands call
# it only from _trivia_fetch_async(), so the bounded retry below runs in the
# forked worker and never blocks the IRC event loop.
sub _trivia_fetch_sync {
    my ($category_id, $difficulty, %opts) = @_;

    require Time::HiRes;

    my $started_at = Time::HiRes::time();
    my $elapsed_ms = sub {
        return int((Time::HiRes::time() - $started_at) * 1000 + 0.5);
    };
    my $clean_detail = sub {
        my ($value, $limit) = @_;
        $limit ||= 240;
        return '' unless defined($value) && !ref($value);
        $value =~ s/[\r\n\0]+/ /g;
        $value =~ s/\s{2,}/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, $limit);
    };
    my $progress_cb = ref($opts{progress_cb}) eq 'CODE'
        ? $opts{progress_cb}
        : undef;
    my $progress = sub {
        my ($stage, %fields) = @_;
        return unless $progress_cb;
        return unless defined($stage) && !ref($stage)
            && $stage =~ /\A[a-z_]+\z/;
        my %event = (
            stage      => $stage,
            elapsed_ms => $elapsed_ms->(),
        );
        for my $field (keys %fields) {
            my $value = $fields{$field};
            next unless defined($value) && !ref($value);
            $event{$field} = $value;
        }
        eval { $progress_cb->(\%event); 1; };
    };

    $category_id = undef
        unless defined($category_id)
            && !ref($category_id)
            && $category_id =~ /\A\d+\z/
            && $category_id >= 9
            && $category_id <= 32;

    $difficulty = undef
        unless defined($difficulty)
            && !ref($difficulty)
            && $difficulty =~ /\A(?:easy|medium|hard)\z/i;

    my $url = 'https://opentdb.com/api.php?amount=1&type=multiple';
    $url .= '&category=' . int($category_id) if defined $category_id;
    $url .= '&difficulty=' . lc($difficulty) if defined $difficulty;

    my $hard_timeout = $opts{hard_timeout};
    $hard_timeout = 7
        unless defined($hard_timeout)
            && !ref($hard_timeout)
            && $hard_timeout =~ /\A\d+(?:\.\d+)?\z/;
    $hard_timeout = 0.1 if $hard_timeout < 0.1;
    $hard_timeout = 12  if $hard_timeout > 12;

    my $http = $opts{http};
    unless ($http && ref($http) && $http->can('get')) {
        $progress->('http_client_start');
        my $made = eval {
            Mediabot::External::_make_http(
                timeout    => 8,
                verify_SSL => 1,
                max_size   => 64 * 1024,
            );
        };

        if ($@ || !$made || !ref($made) || !$made->can('get')) {
            $progress->('http_client_failed');
            return {
                ok         => 0,
                error      => 'http_setup',
                stage      => 'http_client',
                detail     => $clean_detail->($@ || 'HTTP client creation failed'),
                elapsed_ms => $elapsed_ms->(),
            };
        }

        $http = $made;
        $progress->('http_client_ready');
    }
    else {
        $progress->('http_client_injected');
    }

    my $sleep_cb = ref($opts{sleep_cb}) eq 'CODE'
        ? $opts{sleep_cb}
        : sub {
            my ($seconds) = @_;
            Time::HiRes::sleep($seconds);
        };

    my $max_attempts = $opts{max_attempts};
    $max_attempts = 2
        unless defined($max_attempts)
            && !ref($max_attempts)
            && $max_attempts =~ /\A\d+\z/;
    $max_attempts = 1 if $max_attempts < 1;
    $max_attempts = 2 if $max_attempts > 2;

    ATTEMPT:
    for my $attempt (1 .. $max_attempts) {
        my $attempt_started = Time::HiRes::time();
        my ($response, $request_error);
        my $alarm_marker = '__MEDIABOT_TRIVIA_HTTP_DEADLINE__';

        $progress->('http_get_start', attempt => $attempt);

        {
            local $@;
            local $SIG{ALRM} = sub { die "$alarm_marker\n" };
            Time::HiRes::alarm($hard_timeout);
            $response = eval {
                $http->get($url, {
                    headers => {
                        Accept => 'application/json',
                    },
                });
            };
            $request_error = $@;
            Time::HiRes::alarm(0);
        }

        my $attempt_elapsed_ms = int(
            (Time::HiRes::time() - $attempt_started) * 1000 + 0.5
        );

        if (defined($request_error) && $request_error ne '') {
            if ($request_error =~ /\Q$alarm_marker\E/) {
                $progress->(
                    'http_get_timeout',
                    attempt            => $attempt,
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                );
                return {
                    ok                 => 0,
                    error              => 'http_timeout',
                    stage              => 'http_get',
                    attempts           => $attempt,
                    detail             => 'hard request deadline exceeded',
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                    elapsed_ms         => $elapsed_ms->(),
                };
            }

            $progress->(
                'http_get_exception',
                attempt            => $attempt,
                attempt_elapsed_ms => $attempt_elapsed_ms,
            );
            return {
                ok                 => 0,
                error              => 'http_exception',
                stage              => 'http_get',
                attempts           => $attempt,
                detail             => $clean_detail->($request_error),
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        my $status = ref($response) eq 'HASH'
            && defined($response->{status})
            && !ref($response->{status})
            && $response->{status} =~ /\A\d+\z/
                ? int($response->{status})
                : undef;

        my $headers = ref($response) eq 'HASH'
            && ref($response->{headers}) eq 'HASH'
                ? $response->{headers}
                : {};
        my $content_type = $clean_detail->(
            $headers->{'content-type'} // $headers->{'Content-Type'} // '',
            120,
        );
        my $content = ref($response) eq 'HASH'
            && defined($response->{content})
            && !ref($response->{content})
                ? $response->{content}
                : '';
        my $content_bytes = length($content);
        my $http_rate_limited = defined($status) && $status == 429;

        $progress->(
            'http_get_done',
            attempt            => $attempt,
            status             => (defined($status) ? $status : 0),
            success            => (ref($response) eq 'HASH' && $response->{success}) ? 1 : 0,
            content_bytes      => $content_bytes,
            attempt_elapsed_ms => $attempt_elapsed_ms,
        );

        unless (ref($response) eq 'HASH' && $response->{success}) {
            if ($http_rate_limited && $attempt < $max_attempts) {
                my $delay = exists($opts{retry_delay})
                    ? $opts{retry_delay}
                    : 5.25 + rand(0.75);
                $delay = 5.25
                    unless defined($delay)
                        && !ref($delay)
                        && $delay =~ /\A\d+(?:\.\d+)?\z/
                        && $delay >= 5.1
                        && $delay <= 8;

                $progress->(
                    'rate_limit_wait_start',
                    attempt => $attempt,
                    status  => $status,
                    delay_ms => int($delay * 1000 + 0.5),
                );
                my $slept = eval { $sleep_cb->($delay); 1; };
                return {
                    ok                 => 0,
                    error              => 'retry_wait',
                    stage              => 'rate_limit_wait',
                    attempts           => $attempt,
                    status             => $status,
                    content_type       => $content_type,
                    content_bytes      => $content_bytes,
                    attempt_elapsed_ms => $attempt_elapsed_ms,
                    elapsed_ms         => $elapsed_ms->(),
                    detail             => $clean_detail->($@ || 'retry wait failed'),
                } unless $slept;

                $progress->('rate_limit_wait_done', attempt => $attempt);
                next ATTEMPT;
            }

            my $reason = ref($response) eq 'HASH'
                ? $clean_detail->($response->{reason}, 160)
                : '';

            return {
                ok                 => 0,
                error              => $http_rate_limited ? 'rate_limit' : 'http',
                stage              => 'http_response',
                attempts           => $attempt,
                status             => $status,
                reason             => $reason,
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        $progress->('api_parse_start', attempt => $attempt);
        my %meta;
        my $question = _trivia_parse_api_content(
            $content,
            \%meta,
        );

        if (ref($question) eq 'HASH') {
            $progress->('api_parse_ok', attempt => $attempt);
            return {
                ok                 => 1,
                question           => $question,
                attempts           => $attempt,
                status             => $status,
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
            };
        }

        my $response_code = $meta{response_code};
        my $api_rate_limited = defined($response_code)
            && $response_code == 5;

        $progress->(
            'api_parse_failed',
            attempt       => $attempt,
            response_code => (defined($response_code) ? $response_code : -1),
            parse_error   => ($meta{error} // 'unknown'),
        );

        if ($api_rate_limited && $attempt < $max_attempts) {
            # Open Trivia DB limits one request per public IP every five
            # seconds. Separate Mediabot instances on the same host can race,
            # so retry once with a small jitter inside this forked worker.
            my $delay = exists($opts{retry_delay})
                ? $opts{retry_delay}
                : 5.25 + rand(0.75);
            $delay = 5.25
                unless defined($delay)
                    && !ref($delay)
                    && $delay =~ /\A\d+(?:\.\d+)?\z/
                    && $delay >= 5.1
                    && $delay <= 8;

            $progress->(
                'rate_limit_wait_start',
                attempt       => $attempt,
                response_code => $response_code,
                delay_ms      => int($delay * 1000 + 0.5),
            );
            my $slept = eval { $sleep_cb->($delay); 1; };
            return {
                ok                 => 0,
                error              => 'retry_wait',
                stage              => 'rate_limit_wait',
                attempts           => $attempt,
                status             => $status,
                response_code      => $response_code,
                parse_error        => $meta{error},
                content_type       => $content_type,
                content_bytes      => $content_bytes,
                attempt_elapsed_ms => $attempt_elapsed_ms,
                elapsed_ms         => $elapsed_ms->(),
                detail             => $clean_detail->($@ || 'retry wait failed'),
            } unless $slept;

            $progress->('rate_limit_wait_done', attempt => $attempt);
            next ATTEMPT;
        }

        return {
            ok                 => 0,
            error              => $api_rate_limited ? 'rate_limit' : 'response',
            stage              => 'api_parse',
            attempts           => $attempt,
            status             => $status,
            response_code      => $response_code,
            parse_error        => $meta{error},
            content_type       => $content_type,
            content_bytes      => $content_bytes,
            attempt_elapsed_ms => $attempt_elapsed_ms,
            elapsed_ms         => $elapsed_ms->(),
        };
    }

    return {
        ok         => 0,
        error      => 'fetch',
        stage      => 'attempt_loop',
        elapsed_ms => $elapsed_ms->(),
    };
}

# MB319: Open Trivia DB HTTP and DNS work must not run in the IRC event loop.
# Execute the synchronous request in a forked child and consume its bounded JSON
# result through IO::Async. MB394 extends the child budget for one rate-limit
# retry. MB395 registers the worker with watch_process(), because IO::Async owns
# SIGCHLD collection; manual waitpid polling can race the loop and discard a
# successful child as a detail-free fetch failure.
sub _trivia_fetch_async {
    my ($self, $category_id, $difficulty, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    require Time::HiRes;

    my $timeout = $opts{timeout};
    # The child has a seven-second hard wall around each HTTP attempt and may
    # wait once for the Open Trivia DB IP window. Keep the outer worker budget
    # larger, while still guaranteeing a callback when child notification fails.
    $timeout = 24
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 30  if $timeout > 30;

    my $debug_label = defined($opts{debug_label})
        && !ref($opts{debug_label})
            ? $opts{debug_label}
            : '';
    $debug_label =~ s/[\r\n\0]+/ /g;
    $debug_label =~ s/\s{2,}/ /g;
    $debug_label = substr($debug_label, 0, 240);

    my $debug_log = sub {
        my ($level, $message) = @_;
        return unless $self && ref($self) && $self->{logger};
        $message = '' unless defined($message) && !ref($message);
        $message =~ s/[\r\n\0]+/ /g;
        $message =~ s/\s{2,}/ /g;
        $message = substr($message, 0, 1000);
        $self->{logger}->log($level, "trivia worker $message");
    };

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    my $fallback = {
        ok    => 0,
        error => 'fetch',
        stage => 'async_fallback',
    };

    # Compatibility path for lightweight tests or emergency callers without a
    # usable event loop. Normal runtime always uses the forked child.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        $debug_log->(2, "sync fallback label=$debug_label reason=no_event_loop");
        my $result = eval {
            _trivia_fetch_sync($category_id, $difficulty);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/[\r\n\0]+/ /g;
            $error =~ s/\s{2,}/ /g;
            $result = {
                ok     => 0,
                error  => 'worker_exception',
                stage  => 'sync_fallback',
                detail => substr($error, 0, 240),
            };
        }
        $result = $fallback unless ref($result) eq 'HASH';
        eval { $callback->($result); 1; };
        return 1;
    }

    # IO::Async owns SIGCHLD/process collection. Use an ordinary pipe plus fork
    # and register that PID explicitly. A magic open '-|' filehandle can reap
    # its child while being closed at EOF, racing the IO::Async process watcher.
    unless ($loop->can('watch_process')) {
        my $result = {
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'process_watch',
            detail => 'IO::Async loop does not support watch_process',
        };
        $debug_log->(1, "setup failed label=$debug_label detail=$result->{detail}");
        eval { $callback->($result); 1; };
        return 1;
    }

    require IO::Async::Stream;
    require IO::Async::Timer::Countdown;
    require JSON::PP;
    require POSIX;

    my $worker_started = Time::HiRes::time();
    $debug_log->(
        3,
        sprintf(
            'start label=%s category=%s difficulty=%s timeout=%.1fs',
            ($debug_label ne '' ? $debug_label : '-'),
            (defined($category_id) ? $category_id : 'any'),
            (defined($difficulty) ? $difficulty : 'any'),
            $timeout,
        ),
    );

    my ($pipe, $child_write);
    unless (pipe($pipe, $child_write)) {
        my $detail = $! || 'pipe setup failed';
        $detail =~ s/[\r\n\0]+/ /g;
        $detail =~ s/\s{2,}/ /g;
        my $result = {
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'pipe',
            detail => substr("$detail", 0, 240),
        };
        $debug_log->(1, "setup failed label=$debug_label detail=$result->{detail}");
        eval { $callback->($result); 1; };
        return 1;
    }

    my $child_pid = fork();

    unless (defined $child_pid) {
        my $detail = $! || 'fork failed';
        $detail =~ s/[\r\n\0]+/ /g;
        $detail =~ s/\s{2,}/ /g;
        eval { close $pipe };
        eval { close $child_write };
        my $result = {
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'fork',
            detail => substr("$detail", 0, 240),
        };
        $debug_log->(1, "setup failed label=$debug_label detail=$result->{detail}");
        eval { $callback->($result); 1; };
        return 1;
    }

    if ($child_pid == 0) {
        eval { close $pipe };
        binmode($child_write, ':raw');
        local $SIG{PIPE} = 'IGNORE';
        local $SIG{TERM} = 'DEFAULT';
        local $SIG{INT}  = 'DEFAULT';
        local $SIG{HUP}  = 'DEFAULT';

        my $write_record = sub {
            my ($record) = @_;
            return 0 unless ref($record) eq 'HASH';
            my $payload = eval { JSON::PP::encode_json($record) };
            return 0 unless defined($payload) && !ref($payload);
            $payload .= "\n";
            return 0 if length($payload) > 20 * 1024;

            my $offset = 0;
            while ($offset < length($payload)) {
                my $written = syswrite(
                    $child_write,
                    $payload,
                    length($payload) - $offset,
                    $offset,
                );
                next if !defined($written) && $!{EINTR};
                return 0 unless defined($written) && $written > 0;
                $offset += $written;
            }
            return 1;
        };

        my $result = eval {
            _trivia_fetch_sync(
                $category_id,
                $difficulty,
                progress_cb => sub {
                    my ($event) = @_;
                    return unless ref($event) eq 'HASH';
                    $write_record->({
                        type  => 'progress',
                        event => $event,
                    });
                },
            );
        };
        if ($@) {
            my $error = $@;
            $error =~ s/[\r\n\0]+/ /g;
            $error =~ s/\s{2,}/ /g;
            $result = {
                ok     => 0,
                error  => 'worker_exception',
                stage  => 'sync_worker',
                detail => substr($error, 0, 240),
            };
        }
        $result = $fallback unless ref($result) eq 'HASH';

        my $final_record = {
            type   => 'result',
            result => $result,
        };
        my $final_probe = eval { JSON::PP::encode_json($final_record) };
        if (!defined($final_probe) || ref($final_probe)) {
            $final_record = {
                type   => 'result',
                result => {
                    ok     => 0,
                    error  => 'worker_encode',
                    stage  => 'json_encode',
                    detail => 'could not encode final worker record',
                },
            };
        }
        elsif (length($final_probe) > 20 * 1024) {
            $final_record = {
                type   => 'result',
                result => {
                    ok            => 0,
                    error         => 'worker_payload',
                    stage         => 'payload_limit',
                    payload_bytes => length($final_probe),
                },
            };
        }
        $write_record->($final_record);

        eval { close $child_write };
        POSIX::_exit(0);
    }

    eval { close $child_write };

    my $state = {
        read_buffer => '',
        output_bytes => 0,
        pipe_eof    => 0,
        child_done  => 0,
        finalized   => 0,
        timed_out   => 0,
        force_finish => 0,
        wait_status => undef,
        term_sent   => 0,
        kill_sent   => 0,
        last_stage  => 'worker_started',
        result      => undef,
        protocol_error => undef,
    };

    my ($stream, $timeout_timer, $kill_timer, $force_timer);
    my $finish;

    my $remove_timer = sub {
        my ($timer) = @_;
        return unless $timer;
        eval { $timer->stop };
        eval { $loop->remove($timer) };
    };

    my $clean_trace_value = sub {
        my ($value, $limit) = @_;
        $limit ||= 120;
        return '' unless defined($value) && !ref($value);
        $value =~ s/[\r\n\0]+/ /g;
        $value =~ s/\s{2,}/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, $limit);
    };

    my $handle_record = sub {
        my ($line) = @_;
        return if $state->{finalized};

        if (!defined($line) || ref($line) || length($line) > 20 * 1024) {
            $state->{protocol_error} ||= 'record_size';
            return;
        }

        my $record = eval { JSON::PP::decode_json($line) };
        if ($@ || ref($record) ne 'HASH') {
            $state->{protocol_error} ||= 'record_json';
            return;
        }

        my $type = $record->{type};
        if (defined($type) && !ref($type) && $type eq 'progress') {
            my $event = $record->{event};
            unless (ref($event) eq 'HASH') {
                $state->{protocol_error} ||= 'progress_shape';
                return;
            }

            my $stage = $clean_trace_value->($event->{stage}, 64);
            return unless $stage =~ /\A[a-z_]+\z/;
            $state->{last_stage} = $stage;

            my @trace = (
                'progress',
                'label=' . ($debug_label ne '' ? $debug_label : '-'),
                "pid=$child_pid",
                "stage=$stage",
            );
            for my $field (qw(attempt elapsed_ms attempt_elapsed_ms status success content_bytes response_code parse_error delay_ms)) {
                next unless exists($event->{$field})
                    && defined($event->{$field})
                    && !ref($event->{$field});
                my $value = $clean_trace_value->($event->{$field}, 80);
                push @trace, "$field=$value" if $value ne '';
            }
            $debug_log->(4, join(' ', @trace));
            return;
        }

        if (defined($type) && !ref($type) && $type eq 'result') {
            if (ref($record->{result}) eq 'HASH') {
                $state->{result} = $record->{result};
                return;
            }
            $state->{protocol_error} ||= 'result_shape';
            return;
        }

        $state->{protocol_error} ||= 'record_type';
    };

    my $drain_records = sub {
        while ($state->{read_buffer} =~ s/\A([^\n]*)\n//) {
            $handle_record->($1);
        }
        if (length($state->{read_buffer}) > 20 * 1024) {
            $state->{protocol_error} ||= 'buffer_limit';
            $state->{read_buffer} = '';
        }
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{child_done} || $state->{force_finish};
        return unless $state->{pipe_eof} || $state->{timed_out};

        $state->{finalized} = 1;

        $remove_timer->($timeout_timer);
        $remove_timer->($kill_timer);
        $remove_timer->($force_timer);
        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };

        my $elapsed = int(
            (Time::HiRes::time() - $worker_started) * 1000 + 0.5
        );
        my $status = $state->{wait_status} // 0;
        my $output_bytes = $state->{output_bytes};
        my $signal = $status & 127;
        my $exit   = ($status >> 8) & 255;
        my $result;

        if ($state->{timed_out}) {
            $result = {
                ok                  => 0,
                error               => 'worker_timeout',
                stage               => 'async_timeout',
                last_stage          => $state->{last_stage},
                worker_exit         => $exit,
                worker_signal       => $signal,
                worker_output_bytes => $output_bytes,
                worker_elapsed_ms   => $elapsed,
                forced_completion   => $state->{force_finish} ? 1 : 0,
            };
        }
        elsif ($signal || $exit != 0) {
            $result = {
                ok                  => 0,
                error               => 'worker_failed',
                stage               => 'process_exit',
                last_stage          => $state->{last_stage},
                worker_exit         => $exit,
                worker_signal       => $signal,
                worker_output_bytes => $output_bytes,
                worker_elapsed_ms   => $elapsed,
            };
        }
        elsif ($state->{protocol_error}) {
            $result = {
                ok                  => 0,
                error               => 'worker_decode',
                stage               => 'record_protocol',
                detail              => $state->{protocol_error},
                last_stage          => $state->{last_stage},
                worker_exit         => $exit,
                worker_signal       => $signal,
                worker_output_bytes => $output_bytes,
                worker_elapsed_ms   => $elapsed,
            };
        }
        elsif (ref($state->{result}) eq 'HASH') {
            $result = $state->{result};
            $result->{worker_exit} = $exit
                unless exists $result->{worker_exit};
            $result->{worker_signal} = $signal
                unless exists $result->{worker_signal};
            $result->{worker_output_bytes} = $output_bytes
                unless exists $result->{worker_output_bytes};
            $result->{worker_elapsed_ms} = $elapsed
                unless exists $result->{worker_elapsed_ms};
            $result->{last_stage} = $state->{last_stage}
                unless exists $result->{last_stage};
        }
        else {
            $result = {
                ok                  => 0,
                error               => 'worker_decode',
                stage               => 'missing_result',
                detail              => 'worker exited without a final result record',
                last_stage          => $state->{last_stage},
                worker_exit         => $exit,
                worker_signal       => $signal,
                worker_output_bytes => $output_bytes,
                worker_elapsed_ms   => $elapsed,
            };
        }

        my @trace = (
            'complete',
            'label=' . ($debug_label ne '' ? $debug_label : '-'),
            "pid=$child_pid",
            'result=' . ($result->{ok} ? 'ok' : ($result->{error} // 'unknown')),
            'stage=' . ($result->{stage} // '-'),
            'last_stage=' . ($result->{last_stage} // '-'),
            "elapsed_ms=$elapsed",
            "output_bytes=$output_bytes",
            "exit=$exit",
            "signal=$signal",
            'forced=' . ($state->{force_finish} ? 1 : 0),
        );
        for my $field (qw(attempts status response_code parse_error content_type content_bytes elapsed_ms)) {
            next unless exists($result->{$field})
                && defined($result->{$field})
                && !ref($result->{$field});
            my $value = $clean_trace_value->($result->{$field}, 120);
            push @trace, "$field=$value" if $value ne '';
        }
        $debug_log->($result->{ok} ? 3 : 2, join(' ', @trace));

        my $callback_ok = eval { $callback->($result); 1; };
        if (!$callback_ok && $self && ref($self) && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "trivia async callback failed: $error");
        }

        $finish = undef;
    };

    my $watch_ok = eval {
        $loop->watch_process(
            $child_pid,
            sub {
                my ($pid, $wait_status) = @_;
                return unless defined($pid) && $pid == $child_pid;
                return if $state->{finalized};

                $state->{wait_status} = $wait_status;
                $state->{child_done}  = 1;
                $debug_log->(
                    4,
                    "exit observed label=$debug_label pid=$child_pid status=$wait_status",
                );
                $finish->();
            },
        );
        1;
    };

    unless ($watch_ok) {
        my $error = $@ || 'watch_process registration failed';
        $error =~ s/[\r\n\0]+/ /g;
        $error =~ s/\s{2,}/ /g;

        my $sent = kill 'TERM', $child_pid;
        eval { close $pipe };
        my $result = {
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'watch_process',
            detail => substr($error, 0, 240),
        };
        $debug_log->(1, "setup failed label=$debug_label pid=$child_pid term_delivered=$sent detail=$result->{detail}");
        eval { $callback->($result); 1; };
        return 1;
    }

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => $timeout,
        on_expire => sub {
            return if $state->{finalized} || $state->{child_done};

            $state->{timed_out} = 1;
            my $sent = 0;
            unless ($state->{term_sent}) {
                $sent = kill 'TERM', $child_pid;
                $state->{term_sent} = 1;
            }
            my $errno = $sent ? '-' : $clean_trace_value->("$!", 120);
            $debug_log->(
                2,
                "timeout label=$debug_label pid=$child_pid after=${timeout}s "
                . "last_stage=$state->{last_stage} sending=TERM delivered=$sent errno=$errno",
            );

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.5,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};

                    my $kill_sent = 0;
                    unless ($state->{kill_sent}) {
                        $kill_sent = kill 'KILL', $child_pid;
                        $state->{kill_sent} = 1;
                    }
                    my $kill_errno = $kill_sent ? '-' : $clean_trace_value->("$!", 120);
                    $debug_log->(
                        1,
                        "timeout escalation label=$debug_label pid=$child_pid "
                        . "last_stage=$state->{last_stage} sending=KILL "
                        . "delivered=$kill_sent errno=$kill_errno",
                    );
                },
            );

            $force_timer = IO::Async::Timer::Countdown->new(
                delay     => 1.5,
                on_expire => sub {
                    return if $state->{finalized};
                    $state->{force_finish} = 1;
                    $debug_log->(
                        1,
                        "timeout forced completion label=$debug_label pid=$child_pid "
                        . "child_done=$state->{child_done} pipe_eof=$state->{pipe_eof} "
                        . "last_stage=$state->{last_stage}",
                    );
                    $finish->();
                },
            );

            $loop->add($kill_timer);
            $kill_timer->start;
            $loop->add($force_timer);
            $force_timer->start;
        },
    );

    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($io, $buffref, $eof) = @_;

            if (length $$buffref) {
                $state->{output_bytes} += length($$buffref);
                $state->{read_buffer} .= $$buffref;
                $$buffref = '';
                $drain_records->();
            }

            if ($eof && !$state->{pipe_eof}++) {
                if (length($state->{read_buffer})) {
                    $handle_record->($state->{read_buffer});
                    $state->{read_buffer} = '';
                }
                eval { $loop->remove($io) };
                $debug_log->(
                    4,
                    "pipe EOF label=$debug_label pid=$child_pid "
                    . "child_done=$state->{child_done} last_stage=$state->{last_stage}",
                );
                $finish->() if $finish;
            }

            return 0;
        },
    );

    $loop->add($stream);
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
        # mb413-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_tda = Mediabot::Helpers::channel_id_cached($self, $channel);
        unless (defined $cid_tda) { botNotice($self, $nick, 'Channel not found.'); return; }
        my $rc = { id_channel => $cid_tda };
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

    # !trivia categories remains available even while a question is active.
    if (@args && lc($args[0]) eq 'categories') {
        botPrivmsg($self, $channel,
            'Trivia categories: ' . join(', ', sort keys %trivia_cats));
        return 1;
    }

    if ($self->{_trivia}{$channel} && $self->{_trivia}{$channel}{active}) {
        botNotice($self, $nick, 'A trivia question is already active. Answer it or wait.');
        return;
    }

    if ($self->{_trivia_fetch}{$channel}) {
        botNotice($self, $nick, 'A trivia question request is already in progress.');
        return 1;
    }

    # V1/MB319: start a multi-round game only after active and pending guards.
    # The previous order reset the multi-round state even when another question
    # was still active.
    if (@args && lc($args[0]) eq 'start' && $args[1] && $args[1] =~ /^(\d+)$/) {
        my $rounds = int($args[1]);
        $rounds = 1  if $rounds < 1;
        $rounds = 20 if $rounds > 20;

        $self->{_trivia}{$channel}{multi_total}   = $rounds;
        $self->{_trivia}{$channel}{multi_current} = 0;
        $self->{_trivia}{$channel}{scores}        = {};

        botPrivmsg($self, $channel,
            "Trivia: starting $rounds-round game! Scores reset.");

        @args = ();
    }

    # Optional named category filter.
    my $trivia_cat = (
        @args
        && $args[0] !~ /^\d/
        && $args[0] !~ /^(?:easy|medium|hard)$/i
    ) ? lc(shift @args) : undef;

    my $trivia_cat_id = defined($trivia_cat)
        ? $trivia_cats{$trivia_cat}
        : undef;

    if (defined($trivia_cat) && !defined($trivia_cat_id)) {
        botNotice(
            $self,
            $nick,
            "Unknown trivia category '$trivia_cat'. Use !trivia categories.",
        );
        return 1;
    }

    # Optional difficulty filter.
    my $trivia_diff;
    if (@args && $args[0] =~ /^(?:easy|medium|hard)$/i) {
        $trivia_diff = lc(shift @args);
    }

    my $request_token = join(
        ':',
        $$,
        time(),
        ++$self->{_trivia_fetch_sequence},
    );

    $self->{_trivia_fetch}{$channel} = {
        token        => $request_token,
        requested_by => $nick,
        started      => time(),
    };

    my $log_message = $ctx->message;

    if ($self->{logger}) {
        my $cat_log = defined($trivia_cat_id) ? $trivia_cat_id : 'any';
        my $diff_log = defined($trivia_diff) ? $trivia_diff : 'any';
        $self->{logger}->log(
            3,
            "trivia request queued channel=$channel nick=$nick "
            . "token=$request_token category=$cat_log difficulty=$diff_log",
        );
    }

    return _trivia_fetch_async(
        $self,
        $trivia_cat_id,
        $trivia_diff,
        sub {
            my ($result) = @_;

            my $pending = $self->{_trivia_fetch}{$channel};
            return unless $pending
                && defined($pending->{token})
                && $pending->{token} eq $request_token;

            delete $self->{_trivia_fetch}{$channel};
            delete $self->{_trivia_fetch}
                unless keys %{ $self->{_trivia_fetch} // {} };

            unless (ref($result) eq 'HASH'
                    && $result->{ok}
                    && ref($result->{question}) eq 'HASH') {
                my $error = ref($result) eq 'HASH'
                    && defined($result->{error})
                    && !ref($result->{error})
                        ? $result->{error}
                        : 'unknown';

                my @details = ("error=$error");
                if (ref($result) eq 'HASH') {
                    my %numeric = (
                        attempts            => 'attempts',
                        status              => 'http_status',
                        response_code       => 'api_code',
                        content_bytes       => 'content_bytes',
                        attempt_elapsed_ms  => 'attempt_ms',
                        elapsed_ms          => 'fetch_ms',
                        worker_exit         => 'worker_exit',
                        worker_signal       => 'worker_signal',
                        worker_output_bytes => 'worker_output_bytes',
                        worker_elapsed_ms   => 'worker_ms',
                        forced_completion    => 'forced',
                    );

                    for my $field (sort keys %numeric) {
                        next unless defined($result->{$field})
                            && !ref($result->{$field})
                            && $result->{$field} =~ /\A\d+\z/;
                        push @details, $numeric{$field} . '=' . int($result->{$field});
                    }

                    for my $spec (
                        [stage        => 'stage',        qr/\A[a-z_]+\z/, 64],
                        [last_stage   => 'last_stage',   qr/\A[a-z_]+\z/, 64],
                        [parse_error  => 'parse',        qr/\A[a-z_]+\z/, 64],
                        [content_type => 'content_type', undef,              120],
                        [reason       => 'reason',       undef,              160],
                        [detail       => 'detail',       undef,              240],
                    ) {
                        my ($field, $label, $pattern, $limit) = @$spec;
                        next unless defined($result->{$field})
                            && !ref($result->{$field});
                        my $value = $result->{$field};
                        $value =~ s/[\r\n\0]+/ /g;
                        $value =~ s/\s{2,}/ /g;
                        $value =~ s/^\s+|\s+$//g;
                        next if $pattern && $value !~ $pattern;
                        $value = substr($value, 0, $limit);
                        push @details, "$label=$value" if $value ne '';
                    }
                }

                $self->{logger}->log(
                    1,
                    "trivia fetch failed for $channel token=$request_token: "
                    . join(' ', @details),
                ) if $self->{logger};

                my $message = $error eq 'rate_limit'
                    ? 'Trivia: the question service is rate-limiting this server. Please retry in a few seconds.'
                    : $error eq 'http_timeout'
                        ? 'Trivia: the question service request timed out. Details were logged.'
                        : $error =~ /\A(?:http|http_exception|http_setup)\z/
                            ? 'Trivia: the question service is temporarily unreachable.'
                            : $error eq 'worker_timeout'
                            ? 'Trivia: the question request timed out. Details were logged.'
                            : $error =~ /\Aworker_/
                                ? 'Trivia: the question worker failed. Details were logged.'
                                : $error eq 'response'
                                    ? 'Trivia: the question service returned an unusable response. Details were logged.'
                                    : 'Trivia: could not fetch question. Details were logged.';

                botPrivmsg($self, $channel, $message);
                return;
            }

            if (defined($result->{attempts})
                    && !ref($result->{attempts})
                    && $result->{attempts} =~ /\A\d+\z/
                    && $result->{attempts} > 1
                    && $self->{logger}) {
                $self->{logger}->log(
                    3,
                    "trivia fetch recovered after rate-limit retry for $channel",
                );
            }

            # A different internal path may have activated a question while the
            # fetch was in flight. Never overwrite live game state.
            if ($self->{_trivia}{$channel}
                    && $self->{_trivia}{$channel}{active}) {
                $self->{logger}->log(
                    1,
                    "Discarding stale trivia result for $channel: "
                    . 'a question became active while fetching',
                ) if $self->{logger};
                return;
            }

            my $q = $result->{question};

            require HTML::Entities;

            my $question = HTML::Entities::decode_entities(
                $q->{question} // '',
            );
            my $answer = HTML::Entities::decode_entities(
                $q->{correct_answer} // '',
            );

            my @wrong = map {
                HTML::Entities::decode_entities($_)
            } @{ $q->{incorrect_answers} // [] };

            for ($question, $answer, @wrong) {
                $_ = '' unless defined($_) && !ref($_);
                s/[\r\n\t]+/ /g;
                s/\s{2,}/ /g;
                s/^\s+|\s+$//g;
            }

            unless ($question ne '' && $answer ne '' && @wrong) {
                botPrivmsg($self, $channel,
                    'Trivia: no usable question in response.');
                return;
            }

            my @choices = (@wrong, $answer);

            # Shuffle choices.
            for my $i (reverse 1 .. $#choices) {
                my $j = int(rand($i + 1));
                @choices[$i, $j] = @choices[$j, $i];
            }

            my $_prev = $self->{_trivia}{$channel} // {};
            my $multi_total   = $_prev->{multi_total};
            my $multi_current = $_prev->{multi_current} // 0;

            # MB319: increment and announce the round only after a usable
            # question has been fetched. Failed HTTP/API requests no longer
            # consume a round.
            if ($multi_total) {
                $multi_current++;
                botPrivmsg(
                    $self,
                    $channel,
                    "Round $multi_current/$multi_total:",
                );
            }

            my $trivia_timeout = eval {
                int($self->{conf}->get('main.TRIVIA_TIMEOUT') // 30)
            } // 30;
            $trivia_timeout = 30
                unless $trivia_timeout > 0 && $trivia_timeout <= 120;

            my $category = $q->{category};
            $category = 'Unknown'
                unless defined($category)
                    && !ref($category)
                    && $category ne '';

            my $difficulty = $q->{difficulty};
            $difficulty = ''
                unless defined($difficulty)
                    && !ref($difficulty)
                    && $difficulty =~ /\A(?:easy|medium|hard)\z/i;
            $difficulty = lc($difficulty);

            $self->{_trivia}{$channel} = {
                active         => 1,
                answer         => lc($answer),
                answer_display => $answer,
                started        => time(),
                hint_given     => 0,
                category       => $category,
                difficulty     => $difficulty,
                scores         => ($_prev->{scores} // {}),
                multi_total    => $multi_total,
                multi_current  => $multi_current,
                timeout        => $trivia_timeout,
                deadline       => time() + $trivia_timeout,
            };

            my $opts = join('  ', map { "[$_]" } @choices);

            my $diff_tag = '';
            if ($difficulty ne '') {
                my %diff_colors = (
                    easy   => "\x0303",
                    medium => "\x0308",
                    hard   => "\x0304",
                );
                my $color = $diff_colors{$difficulty} // '';
                $diff_tag = $color
                    ? " ${color}[" . uc($difficulty) . "]\x0f"
                    : " [" . uc($difficulty) . "]";
            }

            botPrivmsg(
                $self,
                $channel,
                "Trivia$diff_tag ($category): $question",
            );
            botPrivmsg(
                $self,
                $channel,
                "Choices: $opts -- reply with !answer <choice> "
                . "or just say it (${trivia_timeout}s)",
            );

            $self->{metrics}->inc('mediabot_trivia_questions_total')
                if $self->{metrics};

            logBot(
                $self,
                $log_message,
                $channel,
                'trivia',
                $category,
            );

            return 1;
        },
        debug_label => "channel=$channel token=$request_token requested_by=$nick",
    );
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
        # mb402-R1: préserver la STRUCTURE de la réponse dans l'indice. Avant,
        # tout sauf la première lettre devenait '_', espaces compris :
        # "emile zola" -> "e_________" (le joueur ignorait qu'il y a 2 mots).
        # On ne masque que les caractères de mot ; espaces, tirets et
        # apostrophes restent visibles : "e____ ____", "r___ '_' ____".
        my $hint = '';
        if (length $ans) {
            my $rest = substr($ans, 1);
            $rest =~ s/[^\s'\-]/_/g;
            $hint = substr($ans, 0, 1) . $rest;
        }
        Mediabot::Helpers::botPrivmsg($self, $channel, "Hint: $hint");
    }
    # B3/fix: guard against undef answer + wrap regex in eval
    return unless defined $trivia->{answer};
    # mb339-B1: la branche "contient la réponse" faisait un match SOUS-CHAÎNE brut
    # (lc($text) =~ /\Qanswer\E/), donc un mot plus long contenant la réponse
    # validait à tort (réponse "war" gagnée par "warsaw"), et une mention
    # incidente terminait la manche. On borne désormais la réponse par des
    # frontières alphanumériques, comme le fait déjà checkQuotegameAnswer pour
    # l'auteur (mb121-B2) : "the answer is paris" / "paris!" gagnent toujours,
    # mais "warsaw" ne valide plus "war".
    my $answer = $trivia->{answer};
    # mb443-B1: frontières byte-safe. publictext/réponses sont en OCTETS UTF-8 ;
    # avec des frontières ASCII seules [A-Za-z0-9], un octet d'accent (>= 0x80)
    # passait pour une frontière -> faux positifs : la réponse "on" était
    # validée par "garçon" (l'octet 0xA7 de ç compte comme séparateur). On
    # inclut \x80-\xFF (octets des séquences UTF-8) dans les classes de
    # frontière : "garçon" ne valide plus "on", mais "... is on" / "on!" oui.
    my $matched = eval {
        lc($text) eq $answer
        || lc($text) =~ /(?<![A-Za-z0-9\x80-\xFF])\Q$answer\E(?![A-Za-z0-9\x80-\xFF])/
    };
    return unless $matched;
    $trivia->{active} = 0;
    $trivia->{scores}{$nick} = ($trivia->{scores}{$nick} // 0) + 1;
    # X10: Prometheus counter for correct trivia answers
    # AA1: persist trivia score in DB (TRIVIA_SCORES table)
    eval {
        # mb413-R1: id canal via le helper central (cache d'abord, mb411).
        my $cid_tsi = Mediabot::Helpers::channel_id_cached($self, $channel);
        {
            my $rc = defined($cid_tsi) ? { id_channel => $cid_tsi } : undef;
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

    # mb115: hook achievements trivia (score atteint, sniper si réponse < 3s)
    if ($self->{achievements}) {
        my $response_time = (time() - ($trivia->{started} // time())) || 0;
        eval {
            $self->{achievements}->check_trivia($nick, $channel, $score, $response_time);
        };
        if ($@) { $self->{logger}->log(1, "achievements check_trivia error: $@"); }
    }
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
    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_tt = Mediabot::Helpers::channel_id_cached($self, $channel);
    unless (defined $cid_tt) { botPrivmsg($self, $channel, 'Channel not found.'); return; }
    my $rc = { id_channel => $cid_tt };
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
    # mb411-R1: id canal via le helper central (cache d'abord).
    my $cid_ts = Mediabot::Helpers::channel_id_cached($self, $channel);
    unless (defined $cid_ts) { botNotice($self, $nick, 'Channel not found.'); return; }
    my $rc = { id_channel => $cid_ts };
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

    my $pending = delete $self->{_trivia_fetch}{$channel};
    delete $self->{_trivia_fetch}
        if $self->{_trivia_fetch}
            && !keys %{ $self->{_trivia_fetch} };

    my $trivia = $self->{_trivia}{$channel};

    unless ($trivia && $trivia->{active}) {
        if ($pending) {
            botNotice(
                $self,
                $nick,
                'Pending trivia question request cancelled.',
            );
        }
        else {
            botNotice(
                $self,
                $nick,
                'No active trivia on this channel.',
            );
        }
        return 1;
    }

    $trivia->{active} = 0;
    delete $trivia->{multi_total};
    delete $trivia->{multi_current};

    # B-68-2/fix: clear scores and hint so next game starts clean.
    delete $trivia->{scores};
    $trivia->{hint_given} = 0;

    Mediabot::Helpers::botPrivmsg(
        $self,
        $channel,
        "Trivia stopped by $nick. Answer: $trivia->{answer_display}",
    );

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

# =============================================================================
# mb115: Achievements / Profil / Radar
# =============================================================================

# ---------------------------------------------------------------------------
# mbAchievements_ctx --- !achievements [nick|list|all|top]
# ---------------------------------------------------------------------------
sub mbAchievements_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $ach = $self->{achievements};
    unless ($ach) {
        botNotice($self, $nick, 'Achievements system not initialized.'); return;
    }

    my $defs = $ach->list_definitions;

    # !achievements list  → liste tous les achievements possibles
    if (@args && lc($args[0]) eq 'list') {
        my @order = qw(common uncommon rare epic legendary);
        my %by_rarity;
        for my $id (keys %$defs) {
            push @{ $by_rarity{ $defs->{$id}{rarity} } }, $id;
        }
        for my $r (@order) {
            next unless $by_rarity{$r};
            my $col = $ach->rarity_color($r);
            my $rst = $col ? "\x0f" : '';
            my $count = scalar @{ $by_rarity{$r} };
            botPrivmsg($self, $nick, "${col}\x02" . uc($r) . "\x02${rst} ($count):");
            for my $id (sort @{ $by_rarity{$r} }) {
                my $a = $defs->{$id};
                botPrivmsg($self, $nick,
                    "  $a->{emoji} \x02$a->{name}\x02 — $a->{desc}");
            }
        }
        botPrivmsg($self, $nick, "Total: " . scalar(keys %$defs) . " achievements available.");
        return 1;
    }

    # !achievements top  → classement par nombre d'achievements
    if (@args && lc($args[0]) eq 'top') {
        my $counts = $ach->count_all_nicks;
        unless (%$counts) {
            botPrivmsg($self, $channel, 'No achievements unlocked yet.'); return 1;
        }
        my @sorted = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %$counts;
        my $top    = scalar @sorted > 10 ? 10 : scalar @sorted;
        my @parts;
        for my $i (0..$top-1) {
            my $n = $sorted[$i];
            push @parts, "$n:$counts->{$n}";
        }
        botPrivmsg($self, $channel, "🏆 Top achievement hunters: " . join('  |  ', @parts));
        return 1;
    }

    # !achievements all [nick]  → cross-canal
    my $cross = 0;
    if (@args && lc($args[0]) eq 'all') {
        $cross = 1; shift @args;
    }
    my $target = @args ? lc(shift @args) : lc($nick);

    my $unlocked = $cross
        ? $ach->get_for_nick_all($target)
        : $ach->get_for_nick($target, $channel);

    my $reply_to = ($channel =~ /^#/) ? $channel : $nick;

    unless (%$unlocked) {
        my $scope = $cross ? '(all channels)' : "on $channel";
        botPrivmsg($self, $reply_to,
            "$target has no achievements unlocked yet $scope. Try \x02!achievements list\x02.");
        return 1;
    }

    # Ordre d'affichage : par rareté décroissante
    my %rarity_rank = (legendary => 5, epic => 4, rare => 3, uncommon => 2, common => 1);
    my @sorted_ids = sort {
        ($rarity_rank{ $defs->{$b}{rarity} // 'common' } // 0)
        <=>
        ($rarity_rank{ $defs->{$a}{rarity} // 'common' } // 0)
        || $a cmp $b
    } keys %$unlocked;

    my $scope_str = $cross ? ' (all channels)' : '';
    botPrivmsg($self, $reply_to,
        "🏆 \x02$target\x02 — " . scalar(@sorted_ids) . " / " . scalar(keys %$defs)
        . " achievements$scope_str:");

    # Afficher par groupes de 4 par ligne pour ne pas flooder
    my @cells;
    for my $id (@sorted_ids) {
        my $a   = $defs->{$id} or next;
        my $col = $ach->rarity_color($a->{rarity});
        my $rst = $col ? "\x0f" : '';
        push @cells, "$a->{emoji} ${col}$a->{name}${rst}";
    }
    while (@cells) {
        my @chunk = splice(@cells, 0, 4);
        botPrivmsg($self, $reply_to, '  ' . join('  |  ', @chunk));
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbProfil_ctx --- !profil [nick]
# Fiche d'identité complète d'un nick sur le canal courant.
# ---------------------------------------------------------------------------
sub mbProfil_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc(shift @args) : lc($nick);

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !profil [nick]  (must be in a channel)'); return;
    }

    my $dbh = $self->{dbh};
    my %stats;

    # 1. Compte total + premier message + dernier message
    my $sth = $dbh->prepare(q{
        SELECT COUNT(*) AS msgs,
               MIN(cl.ts) AS first_ts,
               MAX(cl.ts) AS last_ts,
               TIMESTAMPDIFF(DAY, MIN(cl.ts), NOW()) AS days_seen
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick = ?
          AND cl.event_type IN ('public','action')
    });
    if ($sth && $sth->execute($channel, $target)) {
        my $r = $sth->fetchrow_hashref; $sth->finish;
        $stats{msgs}      = $r->{msgs}      // 0;
        $stats{first_ts}  = $r->{first_ts}  // '';
        $stats{last_ts}   = $r->{last_ts}   // '';
        $stats{days_seen} = $r->{days_seen} // 0;
    }

    if (($stats{msgs} // 0) == 0) {
        botPrivmsg($self, $channel, "🚫 $target: no activity recorded on $channel.");
        return 1;
    }

    # 2. Karma (depuis KARMA table)
    my $sth_k = $dbh->prepare(q{
        SELECT k.score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE c.name = ? AND k.nick = ?
    });
    if ($sth_k && $sth_k->execute($channel, $target)) {
        my $r = $sth_k->fetchrow_hashref; $sth_k->finish;
        $stats{karma} = $r ? ($r->{score} // 0) : 0;
    }

    # 3. Rank activité (proxy: nb de nicks plus actifs)
    my $sth_r = $dbh->prepare(q{
        SELECT COUNT(*) + 1 AS rank_pos FROM (
            SELECT cl2.nick
            FROM CHANNEL_LOG cl2
            JOIN CHANNEL c2 ON c2.id_channel = cl2.id_channel
            WHERE c2.name = ?
              AND cl2.nick != ?
              AND cl2.event_type IN ('public','action')
            GROUP BY cl2.nick
            HAVING COUNT(*) > ?
        ) sub_q
    });
    if ($sth_r && $sth_r->execute($channel, $target, $stats{msgs})) {
        my $r = $sth_r->fetchrow_hashref; $sth_r->finish;
        $stats{rank} = $r ? ($r->{rank_pos} // 0) : 0;
    }

    # 4. Heure de pointe + bloc le plus actif
    my $sth_h = $dbh->prepare(q{
        SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick = ?
          AND cl.event_type IN ('public','action')
        GROUP BY HOUR(cl.ts)
    });
    my @hours = (0) x 24;
    if ($sth_h && $sth_h->execute($channel, $target)) {
        while (my $r = $sth_h->fetchrow_hashref) { $hours[$r->{h}] = $r->{c}; }
        $sth_h->finish;
    }
    my $peak_h = 0; my $peak_c = 0;
    for my $h (0..23) { if ($hours[$h] > $peak_c) { $peak_c = $hours[$h]; $peak_h = $h; } }
    $stats{peak_hour}   = $peak_h;
    $stats{peak_count}  = $peak_c;

    # Mini sparkline 24h (4 blocs de 6h)
    my @blocks = (0) x 4;
    for my $h (0..23) { $blocks[ int($h/6) ] += $hours[$h]; }
    my $max_block = (sort { $b <=> $a } @blocks)[0] || 1;
    my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $spark = '';
    for my $b (@blocks) {
        my $ratio = $b / $max_block;
        my $idx   = int($ratio * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark .= $glyphs[$idx];
    }

    # 5. Trivia score
    my $sth_t = $dbh->prepare(q{
        SELECT ts.score
        FROM TRIVIA_SCORES ts
        JOIN CHANNEL c ON c.id_channel = ts.id_channel
        WHERE c.name = ? AND ts.nick = ?
    });
    if ($sth_t && $sth_t->execute($channel, $target)) {
        my $r = $sth_t->fetchrow_hashref; $sth_t->finish;
        $stats{trivia} = $r ? ($r->{score} // 0) : 0;
    }

    # 6. Achievements
    my $ach_count = 0;
    my $ach_total = 0;
    if ($self->{achievements}) {
        my $unl = $self->{achievements}->get_for_nick($target, $channel);
        $ach_count = scalar keys %$unl;
        $ach_total = scalar keys %{ $self->{achievements}->list_definitions };
    }

    # 7. Formats lisibles
    my $first_s = ($stats{first_ts} && $stats{first_ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $last_ago = '?';
    if ($stats{last_ts} && $stats{last_ts} =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
        require Time::Local;
        my $ep = eval { Time::Local::timelocal($6,$5,$4,$3,$2-1,$1-1900) };
        if ($ep) {
            my $diff = time() - $ep;
            $last_ago = $diff < 60        ? "${diff}s ago"
                      : $diff < 3600      ? sprintf('%dm ago',  int($diff/60))
                      : $diff < 86400     ? sprintf('%dh ago',  int($diff/3600))
                      :                     sprintf('%dd ago',  int($diff/86400));
        }
    }

    # 8. Karma sign (vert/rouge)
    my $karma_sign = '0';
    if (defined $stats{karma}) {
        $karma_sign = $stats{karma} > 0 ? "\x0303+$stats{karma}\x0f"
                    : $stats{karma} < 0 ? "\x0304$stats{karma}\x0f"
                    :                     '0';
    }

    # 9. Affichage final — 3 lignes condensées et stylées
    my $rank_str = $stats{rank} ? "#$stats{rank}" : '?';
    my $reply_to = $channel;

    botPrivmsg($self, $reply_to,
        "\x{2550}\x{2550}\x{2550} \x02$target\x02 on $channel \x{2550}\x{2550}\x{2550}  "
        . "joined $first_s \x{B7} last $last_ago");

    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F4AC} %s msgs (rank %s, %dd seen)  \x{B7}  \x{1F31F} karma %s  \x{B7}  \x{1F9E0} trivia %s",
            _fmt_n($stats{msgs}), $rank_str, $stats{days_seen} // 0,
            $karma_sign, $stats{trivia} // 0));

    my $peak_label = sprintf('%02dh-%02dh', $stats{peak_hour}, ($stats{peak_hour}+1)%24);
    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F4C8} 24h: %s  \x{B7}  peak %s (%d msgs)  \x{B7}  \x{1F3C6} %d/%d",
            $spark, $peak_label, $stats{peak_count} // 0,
            $ach_count, $ach_total));

    return 1;
}

# Helper : formate les grands nombres (1234 → 1.2k, 12345 → 12k)
sub _fmt_n {
    my ($n) = @_;
    return '?' unless defined $n;
    return $n          if $n < 1000;
    return sprintf('%.1fk', $n/1000)  if $n < 10_000;
    return sprintf('%dk',   int($n/1000)) if $n < 1_000_000;
    return sprintf('%.1fM', $n/1_000_000);
}

# ---------------------------------------------------------------------------
# mbRadar_ctx --- !radar
# Détecte les anomalies d'activité sur le canal :
#   - spike (activité dernière heure >> moyenne 24h)
#   - silence (canal très calme depuis >X min)
#   - newcomers (nicks vus pour la 1ère fois dans les dernières 24h)
#   - ghosts (nicks présents en nicklist mais silencieux > 6h)
#   - karma vortex (votes karma soudains)
#   - loudest talkers (top 3 dernière heure)
# ---------------------------------------------------------------------------
sub mbRadar_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !radar  [Nd]  (must be in a channel)'); return;
    }

    # mb116: mode étendu — !radar 7d  vue historique sur N jours
    my $hist_days;
    if (@args && $args[0] =~ /^(\d+)d$/i) {
        $hist_days = $1; $hist_days = 30 if $hist_days > 30; $hist_days = 1 if $hist_days < 1;
    }

    my $dbh = $self->{dbh};
    my @lines;

    if (defined $hist_days) {
        # Mode historique : sparkline d'activité quotidienne sur N jours + extrêmes
        my $sth_d = $dbh->prepare(qq{
            SELECT DATE(cl.ts) AS d, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= NOW() - INTERVAL $hist_days DAY
            GROUP BY DATE(cl.ts)
            ORDER BY d
        });
        my %by_day;
        if ($sth_d && $sth_d->execute($channel)) {
            while (my $r = $sth_d->fetchrow_hashref) { $by_day{$r->{d}} = $r->{c}; }
            $sth_d->finish;
        }
        unless (%by_day) {
            botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 $channel: no data in last ${hist_days}d");
            return 1;
        }
        my @sorted_days = sort keys %by_day;
        my @counts      = map { $by_day{$_} } @sorted_days;
        my $max = (sort { $b <=> $a } @counts)[0] || 1;
        my $sum = 0; $sum += $_ for @counts;
        my $avg = $sum / scalar(@counts);
        my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
        my $spark = '';
        for my $c (@counts) {
            my $idx = int(($c / $max) * 7);
            $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
            $spark .= $glyphs[$idx];
        }
        # Best & worst day
        my ($best_d) = sort { $by_day{$b} <=> $by_day{$a} } keys %by_day;
        my ($worst_d) = sort { $by_day{$a} <=> $by_day{$b} } keys %by_day;
        botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 $channel (last ${hist_days}d):");
        botPrivmsg($self, $channel,
            sprintf("  \x{1F4C8} %s  \x{B7}  total %s msgs  \x{B7}  avg %.0f/d",
                $spark, _fmt_n($sum), $avg));
        botPrivmsg($self, $channel,
            sprintf("  \x{1F389} best:  %s (%s msgs)  \x{B7}  \x{1F614} worst: %s (%s msgs)",
                $best_d, _fmt_n($by_day{$best_d}),
                $worst_d, _fmt_n($by_day{$worst_d})));
        return 1;
    }

    # Mode standard (par défaut) — diagnostic temps réel
    # 1. Activity rate — dernière heure vs moyenne 24h
    my $sth_r = $dbh->prepare(q{
        SELECT
            SUM(IF(cl.ts >= NOW() - INTERVAL  1 HOUR, 1, 0)) AS last_h,
            SUM(IF(cl.ts >= NOW() - INTERVAL 24 HOUR, 1, 0)) AS last_24h
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    });
    my ($last_h, $avg_h, $last_24h) = (0, 0, 0);
    if ($sth_r && $sth_r->execute($channel)) {
        my $r = $sth_r->fetchrow_hashref; $sth_r->finish;
        $last_h   = $r->{last_h}   // 0;
        $last_24h = $r->{last_24h} // 0;
        $avg_h    = $last_24h / 24;
    }

    my $rate_emoji = "\x{3030}\x{FE0F}";
    my $rate_msg   = "calm";
    if ($avg_h > 0) {
        my $ratio = $last_h / ($avg_h || 1);
        if    ($ratio >= 3.0) { $rate_emoji = "\x{1F525}"; $rate_msg = sprintf("SPIKE x%.1f", $ratio); }
        elsif ($ratio >= 2.0) { $rate_emoji = "\x{1F4C8}"; $rate_msg = sprintf("busy x%.1f", $ratio); }
        elsif ($ratio <= 0.2) { $rate_emoji = "\x{1F319}"; $rate_msg = sprintf("quiet x%.1f", $ratio); }
        else                  { $rate_emoji = "\x{3030}\x{FE0F}"; $rate_msg = sprintf("normal x%.1f", $ratio); }
    }

    push @lines, sprintf('%s rate: %d msgs/last-hour (avg %.0f/h over 24h) - %s',
        $rate_emoji, $last_h, $avg_h, $rate_msg);

    # 2. Last message ago
    my $sth_l = $dbh->prepare(q{
        SELECT TIMESTAMPDIFF(MINUTE, MAX(cl.ts), NOW()) AS m
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    });
    if ($sth_l && $sth_l->execute($channel)) {
        my $r = $sth_l->fetchrow_hashref; $sth_l->finish;
        my $m = $r->{m} // 0;
        if ($m > 30) {
            my $silent_emoji = $m > 360 ? "\x{1F997}" : "\x{1F634}";
            push @lines, sprintf('%s last public msg: %s ago',
                $silent_emoji,
                ($m < 60 ? "${m}m"
                 : $m < 1440 ? sprintf('%dh%dm', int($m/60), $m%60)
                 : sprintf('%dd%dh', int($m/1440), int(($m%1440)/60))));
        }
    }

    # 3. Newcomers — premières activités dans les dernières 24h
    my $sth_n = $dbh->prepare(q{
        SELECT cl.nick, MIN(cl.ts) AS first
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
        GROUP BY cl.nick
        HAVING first >= NOW() - INTERVAL 24 HOUR
        ORDER BY first ASC
        LIMIT 10
    });
    if ($sth_n && $sth_n->execute($channel)) {
        my @newbies;
        while (my $r = $sth_n->fetchrow_hashref) { push @newbies, $r->{nick}; }
        $sth_n->finish;
        if (@newbies) {
            my $list = join(', ', @newbies);
            $list = substr($list, 0, 200) . '...' if length($list) > 200;
            push @lines, sprintf("\x{1F195} newcomers (24h): %s", $list);
        }
    }

    # 4. Ghosts — nicks en nicklist mais silencieux > 6h
    my @nicks_on_chan = eval { $self->gethChannelsNicksOnChan($channel) };
    if (@nicks_on_chan) {
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        my @candidates = grep { lc($_) ne lc($bot_nick) } @nicks_on_chan;
        my @ghosts;
        if (@candidates) {
            my $ph = join(',', ('?') x scalar(@candidates));
            my $sth_g = $dbh->prepare(qq{
                SELECT cl.nick, MAX(cl.ts) AS last_ts,
                       TIMESTAMPDIFF(HOUR, MAX(cl.ts), NOW()) AS hours_silent
                FROM CHANNEL_LOG cl
                JOIN CHANNEL c ON c.id_channel = cl.id_channel
                WHERE c.name = ?
                  AND cl.nick IN ($ph)
                  AND cl.event_type IN ('public','action')
                GROUP BY cl.nick
            });
            my %last_seen;
            if ($sth_g && $sth_g->execute($channel, @candidates)) {
                while (my $r = $sth_g->fetchrow_hashref) {
                    $last_seen{lc($r->{nick})} = $r->{hours_silent} // 9999;
                }
                $sth_g->finish;
            }
            for my $n (@candidates) {
                my $h = $last_seen{lc($n)} // 9999;
                push @ghosts, "$n (${h}h)" if $h >= 6;
            }
            @ghosts = sort {
                my ($ah) = $a =~ /\((\d+)h\)/;
                my ($bh) = $b =~ /\((\d+)h\)/;
                ($bh // 0) <=> ($ah // 0)
            } @ghosts;
            @ghosts = @ghosts[0..4] if @ghosts > 5;
            push @lines, "\x{1F47B} silent ghosts: " . join(', ', @ghosts) if @ghosts;
        }
    }

    # 5. Karma vortex — récent karma activity > 5 votes dernière heure
    my $klog = $self->{_karma_log}{$channel} // [];
    my $now = time();
    my $recent_karma = scalar grep { ($_->{ts}//0) >= $now - 3600 } @$klog;
    if ($recent_karma >= 5) {
        my $kpos = scalar grep { ($_->{ts}//0) >= $now-3600 && ($_->{delta}//'') eq '+1' } @$klog;
        my $kneg = $recent_karma - $kpos;
        push @lines, sprintf("\x{26A1} karma vortex (1h): %d votes (+%d / -%d)",
            $recent_karma, $kpos, $kneg);
    }

    # 6. Top talkers dernière heure
    if ($last_h > 0) {
        my $sth_tp = $dbh->prepare(q{
            SELECT cl.nick, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.ts >= NOW() - INTERVAL 1 HOUR
              AND cl.event_type IN ('public','action')
            GROUP BY cl.nick
            ORDER BY c DESC
            LIMIT 3
        });
        if ($sth_tp && $sth_tp->execute($channel)) {
            my @talkers;
            while (my $r = $sth_tp->fetchrow_hashref) {
                push @talkers, "$r->{nick}:$r->{c}";
            }
            $sth_tp->finish;
            push @lines, sprintf("\x{1F399}\x{FE0F} loudest (1h): %s", join('  ', @talkers)) if @talkers;
        }
    }

    botPrivmsg($self, $channel, "\x{1F4E1} \x02Radar\x02 on $channel:");
    botPrivmsg($self, $channel, "  $_") for @lines;
    return 1;
}

# =============================================================================
# mb116: Dashboard / Duel / Horoscope
# =============================================================================

# ---------------------------------------------------------------------------
# mbDashboard_ctx --- !dashboard / !chanstats
# Tableau de bord complet du canal courant : activité, top contributeurs,
# top mots, sparkline 7 jours, karma vortex, ambiance globale.
# ---------------------------------------------------------------------------
sub mbDashboard_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !dashboard  (must be in a channel)'); return;
    }

    my $dbh = $self->{dbh};

    # 1. Vue globale — total msgs, distinct nicks, période
    my $sth = $dbh->prepare(q{
        SELECT COUNT(*) AS total,
               COUNT(DISTINCT cl.nick) AS nicks,
               MIN(cl.ts) AS since,
               TIMESTAMPDIFF(DAY, MIN(cl.ts), NOW()) AS days
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
    });
    my %g;
    if ($sth && $sth->execute($channel)) {
        my $r = $sth->fetchrow_hashref; $sth->finish;
        %g = %$r if $r;
    }
    my $total = $g{total} // 0;
    if ($total == 0) {
        botPrivmsg($self, $channel, "🚫 No public activity recorded on $channel yet.");
        return 1;
    }
    my $since_s = ($g{since} && $g{since} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $days    = $g{days} // 1; $days = 1 if $days < 1;
    my $msgs_per_day = sprintf('%.0f', $total / $days);

    # 2. Top 5 contributeurs
    my $sth_t = $dbh->prepare(q{
        SELECT cl.nick, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        GROUP BY cl.nick
        ORDER BY c DESC
        LIMIT 5
    });
    my @top5;
    if ($sth_t && $sth_t->execute($channel)) {
        while (my $r = $sth_t->fetchrow_hashref) {
            push @top5, sprintf('%s:%s', $r->{nick}, _fmt_n($r->{c}));
        }
        $sth_t->finish;
    }

    # 3. Activité par jour (sparkline 7 jours, jour le plus actif)
    my $sth_d = $dbh->prepare(q{
        SELECT DATE(cl.ts) AS d, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 7 DAY
        GROUP BY DATE(cl.ts)
        ORDER BY d
    });
    my @days7 = (0) x 7;
    my $today_epoch = time();
    if ($sth_d && $sth_d->execute($channel)) {
        while (my $r = $sth_d->fetchrow_hashref) {
            # offset depuis aujourd'hui
            if ($r->{d} =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                require Time::Local;
                my $ep = eval { Time::Local::timelocal(0,0,12,$3,$2-1,$1-1900) };
                next unless $ep;
                my $offset = int(($today_epoch - $ep) / 86400);
                $offset = 0 if $offset < 0; $offset = 6 if $offset > 6;
                $days7[6 - $offset] = $r->{c};   # oldest left, today right
            }
        }
        $sth_d->finish;
    }
    my $max7 = (sort { $b <=> $a } @days7)[0] || 1;
    my @glyphs = ("\x{2581}","\x{2582}","\x{2583}","\x{2584}","\x{2585}","\x{2586}","\x{2587}","\x{2588}");
    my $spark_d = '';
    for my $d (@days7) {
        my $idx = int(($d / $max7) * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark_d .= $glyphs[$idx];
    }

    # 4. Heatmap globale 24h
    my $sth_h = $dbh->prepare(q{
        SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 30 DAY
        GROUP BY HOUR(cl.ts)
    });
    my @hours = (0) x 24;
    if ($sth_h && $sth_h->execute($channel)) {
        while (my $r = $sth_h->fetchrow_hashref) { $hours[$r->{h}] = $r->{c}; }
        $sth_h->finish;
    }
    my $max_h = (sort { $b <=> $a } @hours)[0] || 1;
    my $spark_h = '';
    for my $h (0..23) {
        my $idx = int(($hours[$h] / $max_h) * 7);
        $idx = 0 if $idx < 0; $idx = 7 if $idx > 7;
        $spark_h .= $glyphs[$idx];
    }
    my $peak_h = 0; my $peak_c = 0;
    for my $h (0..23) { if ($hours[$h] > $peak_c) { $peak_c = $hours[$h]; $peak_h = $h; } }

    # 5. Karma vortex — top giver / top receiver des 7 derniers jours (ring buffer)
    my $klog = $self->{_karma_log}{$channel} // [];
    my $since_ts = time() - 7*86400;
    my %givers; my %receivers; my $kpos = 0; my $kneg = 0;
    for my $e (@$klog) {
        next unless ($e->{ts} // 0) >= $since_ts;
        $kpos++ if ($e->{delta} // '') eq '+1';
        $kneg++ if ($e->{delta} // '') eq '-1';
        $givers{ $e->{from} }++   if $e->{from};
        $receivers{ $e->{nick} }++ if $e->{nick};
    }
    my ($top_giver)    = sort { $givers{$b}    <=> $givers{$a} }    keys %givers;
    my ($top_receiver) = sort { $receivers{$b} <=> $receivers{$a} } keys %receivers;

    # 6. Achievements totaux unlock sur ce canal
    my $ach_unlocked = 0;
    if ($self->{achievements}) {
        for my $key (keys %{ $self->{achievements}{data} // {} }) {
            my ($n, $ch) = split /\x00/, $key, 2;
            # mb435-B3: achievement keys are canonical lowercase since
            # mb430; compare against the folded live channel as well.
            next unless defined $ch && $ch eq lc($channel // '');
            $ach_unlocked += scalar keys %{ $self->{achievements}{data}{$key} };
        }
    }

    # 7. Active right now (nicks ayant parlé dans les 60 dernières min)
    my $sth_n = $dbh->prepare(q{
        SELECT COUNT(DISTINCT cl.nick) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 60 MINUTE
    });
    my $active_now = 0;
    if ($sth_n && $sth_n->execute($channel)) {
        my $r = $sth_n->fetchrow_hashref; $sth_n->finish;
        $active_now = $r ? ($r->{c} // 0) : 0;
    }

    # 8. Affichage
    my $peak_label = sprintf('%02dh', $peak_h);
    botPrivmsg($self, $channel,
        "\x{2550}\x{2550}\x{2550} \x02Dashboard\x02 $channel \x{2550}\x{2550}\x{2550}  "
        . "since $since_s \x{B7} $days days \x{B7} avg ${msgs_per_day}/d");

    botPrivmsg($self, $channel,
        sprintf("  \x{1F4AC} %s msgs from %s nicks  \x{B7}  \x{1F50A} %d active in last 60min",
            _fmt_n($total), _fmt_n($g{nicks} // 0), $active_now));

    botPrivmsg($self, $channel,
        sprintf("  \x{1F451} top: %s", @top5 ? join("  ", @top5) : "n/a"));

    botPrivmsg($self, $channel,
        sprintf("  \x{1F4C5} 7d: %s  \x{B7}  \x{1F567} 24h: %s  peak %s (%s)",
            $spark_d, $spark_h, $peak_label, _fmt_n($peak_c)));

    if (%givers || %receivers) {
        botPrivmsg($self, $channel,
            sprintf("  \x{2728} karma 7d: +%d/-%d  \x{B7}  giver: %s  \x{B7}  receiver: %s",
                $kpos, $kneg,
                $top_giver    // 'n/a',
                $top_receiver // 'n/a'));
    }

    if ($self->{achievements}) {
        my $defs_count = scalar keys %{ $self->{achievements}->list_definitions };
        botPrivmsg($self, $channel,
            sprintf("  \x{1F3C6} achievements unlocked on $channel: %d  \x{B7}  catalogue: %d available",
                $ach_unlocked, $defs_count));
    }

    return 1;
}

# ---------------------------------------------------------------------------
# mbDuel_ctx --- !duel <nick>
# Mini-jeu : roll de d20 chacun, le gagnant prend +1 karma, le perdant -1.
# Cooldown 24h par paire de nicks (ordre indépendant). Égalité = redite.
# ---------------------------------------------------------------------------
sub mbDuel_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !duel <nick>  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games (default=1 backward compat)
    unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
        botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
        return;
    }

    # !duel stats [nick] — affichage des stats personnelles
    if (@args && lc($args[0]) eq 'stats') {
        shift @args;
        my $target = @args ? lc(shift @args) : lc($nick);
        my $stats = $self->{_duel_stats}{$channel}{$target} // {};
        my $w = $stats->{wins}   // 0;
        my $l = $stats->{losses} // 0;
        my $tot = $w + $l;
        my $wr = $tot > 0 ? sprintf('%.0f%%', 100*$w/$tot) : 'n/a';
        botPrivmsg($self, $channel,
            "\x{2694}\x{FE0F} $target duel record on $channel: $w win(s) / $l loss(es) (winrate $wr)");
        return 1;
    }

    # !duel top — classement des duellistes
    if (@args && lc($args[0]) eq 'top') {
        my $tbl = $self->{_duel_stats}{$channel} // {};
        unless (%$tbl) {
            botPrivmsg($self, $channel, 'No duels recorded on this channel yet.'); return 1;
        }
        my @sorted = sort {
            ($tbl->{$b}{wins} // 0) <=> ($tbl->{$a}{wins} // 0)
            || $a cmp $b
        } keys %$tbl;
        my @top = @sorted > 5 ? @sorted[0..4] : @sorted;
        my @parts;
        for my $n (@top) {
            my $w = $tbl->{$n}{wins}   // 0;
            my $l = $tbl->{$n}{losses} // 0;
            push @parts, "$n: ${w}W/${l}L";
        }
        botPrivmsg($self, $channel, "\x{2694}\x{FE0F} Top duellists: " . join('  |  ', @parts));
        return 1;
    }

    my $target = $args[0];
    unless (defined $target && $target ne '') {
        botNotice($self, $nick, 'Syntax: !duel <nick>  |  !duel stats [nick]  |  !duel top');
        return;
    }
    $target = lc($target);

    if (lc($nick) eq $target) {
        botPrivmsg($self, $channel, "$nick: you can't duel yourself \x{1F614}");
        return 1;
    }

    # Vérifier que le target est sur le canal
    my @nicks_on = eval { $self->gethChannelsNicksOnChan($channel) };
    my $bot_nick = eval { $self->{irc}->nick_folded } // '';
    unless (grep { lc($_) eq $target } @nicks_on) {
        botPrivmsg($self, $channel, "$nick: $target is not on $channel");
        return 1;
    }
    if (lc($target) eq lc($bot_nick)) {
        botPrivmsg($self, $channel,
            "\x{1F916} I don't duel mortals (I would always roll natural 20)");
        return 1;
    }

    # Cooldown 24h par paire — ordre indépendant
    my $pair_key = join("\x00", sort (lc($nick), $target));
    my $now = time();
    my $cooldown_until = $self->{_duel_cooldown}{$channel}{$pair_key} // 0;
    if ($cooldown_until > $now) {
        my $wait = $cooldown_until - $now;
        my $wait_str = $wait < 60 ? "${wait}s"
                     : $wait < 3600 ? sprintf('%dm', int($wait/60))
                     : sprintf('%dh%dm', int($wait/3600), int(($wait%3600)/60));
        botPrivmsg($self, $channel,
            "\x{1F570}\x{FE0F} $nick vs $target: cooldown active ($wait_str remaining)");
        return 1;
    }

    # Roll de d20
    my $r1 = int(rand(20)) + 1;
    my $r2 = int(rand(20)) + 1;

    # Critique 20 -> +5 bonus, fumble 1 -> -3 malus
    my $b1 = ''; my $b2 = '';
    if ($r1 == 20) { $r1 += 5; $b1 = " \x{1F525}CRIT"; }
    if ($r2 == 20) { $r2 += 5; $b2 = " \x{1F525}CRIT"; }
    if ($r1 == 1)  { $r1 -= 3; $b1 = " \x{1F4A5}FUMBLE"; }
    if ($r2 == 1)  { $r2 -= 3; $b2 = " \x{1F4A5}FUMBLE"; }

    botPrivmsg($self, $channel,
        "\x{2694}\x{FE0F} \x02$nick\x02 (\x{1F3B2}$r1$b1) vs \x02$target\x02 (\x{1F3B2}$r2$b2)");

    # Égalité
    if ($r1 == $r2) {
        botPrivmsg($self, $channel, "\x{1F91D} Draw! No cooldown applied, try again.");
        return 1;
    }

    my $winner = $r1 > $r2 ? lc($nick) : $target;
    my $loser  = $r1 > $r2 ? $target   : lc($nick);

    # Apply karma changes via in-DB update (sans passer par mbKarma_ctx → pour éviter double event)
    my $dbh = $self->{dbh};
    # mb414-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($self, $channel) // 0;

    if ($id_channel) {
        # +1 winner
        my $sth_w = $dbh->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, 1)
            ON DUPLICATE KEY UPDATE score = score + 1
        });
        $sth_w->execute($id_channel, $winner) if $sth_w;
        $sth_w->finish if $sth_w;

        # -1 loser
        my $sth_l = $dbh->prepare(q{
            INSERT INTO KARMA (id_channel, nick, score) VALUES (?, ?, -1)
            ON DUPLICATE KEY UPDATE score = score - 1
        });
        $sth_l->execute($id_channel, $loser) if $sth_l;
        $sth_l->finish if $sth_l;
    }

    # Update in-memory stats
    $self->{_duel_stats}{$channel}{$winner}{wins}++;
    $self->{_duel_stats}{$channel}{$loser}{losses}++;

    # mb120-B3: tracking streak corrigé.
    #
    # Avant : le test `if (last_result eq 'win')` était évalué APRÈS qu'on vient
    # de mettre 'win' dans cette variable -> toujours vrai (test mort). Et le
    # streak du loser était simplement décrementé sans tenir compte de la
    # transition (un loser qui sortait d'une série de wins gardait son streak+).
    #
    # Convention du streak :
    #   > 0  : nombre de victoires consecutives
    #   < 0  : nombre de defaites consecutives
    #
    # Detection underdog (gagner apres 5 defaites consecutives) :
    #   - on regarde le streak du winner *avant* l'update
    #   - si <= -5, c'est un underdog
    my $prev_winner_result = $self->{_duel_last_result}{$channel}{$winner};
    my $prev_loser_result  = $self->{_duel_last_result}{$channel}{$loser};
    my $prev_winner_streak = $self->{_duel_streak}{$channel}{$winner} // 0;

    # Calcul d'eligibilite underdog AVANT update
    my $underdog_streak = $prev_winner_streak < 0 ? -$prev_winner_streak : 0;

    # Update last_result
    $self->{_duel_last_result}{$channel}{$winner} = 'win';
    $self->{_duel_last_result}{$channel}{$loser}  = 'loss';

    # Update streak winner
    if (defined $prev_winner_result && $prev_winner_result eq 'win') {
        $self->{_duel_streak}{$channel}{$winner}++;
    } else {
        # Premier duel OU transition loss -> win
        $self->{_duel_streak}{$channel}{$winner} = 1;
    }

    # Update streak loser
    if (defined $prev_loser_result && $prev_loser_result eq 'loss') {
        $self->{_duel_streak}{$channel}{$loser}--;
    } else {
        # Premier duel OU transition win -> loss
        $self->{_duel_streak}{$channel}{$loser} = -1;
    }

    # Set cooldown 24h
    $self->{_duel_cooldown}{$channel}{$pair_key} = $now + 24*3600;

    # Annonce résultat
    botPrivmsg($self, $channel,
        sprintf("\x{1F3C6} \x02%s\x02 wins! (+1 karma to %s, -1 to %s)  \x{2022}  cooldown 24h",
            $winner, $winner, $loser));

    # Hooks achievements
    if ($self->{achievements}) {
        my $wins = $self->{_duel_stats}{$channel}{$winner}{wins} // 0;
        eval { $self->{achievements}->check_duel($winner, $channel, $wins, $underdog_streak) };
        if ($@) { $self->{logger}->log(1, "achievements check_duel error: $@") }
        # Karma achievements potentiellement aussi
        my $sth_s = $dbh->prepare("SELECT score FROM KARMA WHERE id_channel=? AND nick=?");
        if ($sth_s && $sth_s->execute($id_channel, $winner)) {
            my $r = $sth_s->fetchrow_hashref; $sth_s->finish;
            if ($r) {
                eval { $self->{achievements}->check_karma($winner, $channel, $r->{score}, undef, undef) };
            }
        }
    }

    # Metrics
    $self->{metrics}->inc('mediabot_duel_total', { channel => $channel }) if $self->{metrics};

    logBot($self, $ctx->message, $channel, 'duel', "$nick vs $target -> $winner");
    return 1;
}

# ---------------------------------------------------------------------------
# mbHoroscope_ctx --- !horoscope [nick]
# Horoscope IRC déterministe en français. Seed = nick + date.
# Compteur de consultations en mémoire (achievement star_gazer).
# ---------------------------------------------------------------------------
sub mbHoroscope_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target  = @args ? lc(shift @args) : lc($nick);

    my $reply_to = ($channel && $channel =~ /^#/) ? $channel : $nick;

    # mb118-IMP2: gate par chanset +Games sur canal public (PM toujours autorisé)
    if ($channel && $channel =~ /^#/) {
        unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
            botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
            return;
        }
    }

    # Seed déterministe : nick + date du jour
    my @lt = localtime(time);
    my $date_key = sprintf('%04d-%02d-%02d', $lt[5]+1900, $lt[4]+1, $lt[3]);
    my $seed = 0;
    $seed = ($seed * 31 + ord($_)) & 0xFFFFFFFF for split //, ($target . ':' . $date_key);

    # mb444-B1: PRNG LOCAL déterministe. Avant, srand($seed) reseedait le RNG
    # GLOBAL du process pour rendre l'horoscope déterministe, puis un srand()
    # final tentait de « restaurer » — mais srand() ne restaure PAS la séquence
    # précédente : il reseed depuis l'horloge. Ce reseed répété (un par
    # !horoscope) perturbe et dégrade le RNG partagé par tout le reste (dés
    # !roll, d20 des duels, 8ball, quote aléatoire, proba Hailo, sélection
    # trivia...). On tire désormais les index via un LCG local, sans jamais
    # toucher srand() ni le générateur global.
    my $rng  = $seed & 0x7FFFFFFF;
    my $next = sub { $rng = (($rng * 1103515245) + 12345) & 0x7FFFFFFF; return $rng; };
    my $pick = sub { my ($aref) = @_; return $aref->[ $next->() % scalar(@$aref) ]; };

    # Pools (FR — canal francophone, Christophe préfère le français)
    my @humeurs = (
        "lumineuse \x{1F31E}", "mystérieuse \x{1F315}", "espiègle \x{1F608}",
        "philosophe \x{1F914}", "tranchante \x{2694}\x{FE0F}", "rêveuse \x{2601}\x{FE0F}",
        "indomptable \x{1F981}", "fluide \x{1F30A}", "explosive \x{1F4A5}",
        "feutrée \x{1F436}", "stoïque \x{1F5FF}", "magnétique \x{1F9F2}",
    );

    my @evenements = (
        "Un café partagé deviendra mémorable.",
        "Quelqu'un te citera de travers, ne corrige pas.",
        "Un vieux fichier de conf répondra enfin à une question d'hier.",
        "Mefie-toi du backup que tu n'as pas vérifié.",
        "Une commande tapée trop vite t'apprendra quelque chose.",
        "Quelqu'un te demandera ton avis sur du Perl — résiste, parle de Tcl.",
        "Un nick que tu n'as pas vu depuis 2 ans dira bonjour.",
        "Un grep négligé révèlera une perle cachée dans tes logs.",
        "Une notification ignorée ce matin reviendra t'embêter ce soir.",
        "L'éditeur que tu fuis va finir par te séduire — c'est non.",
        "Un fail2ban silencieux te sauvera la mise.",
        "Le DNS aura ses humeurs : prévois un dig.",
        "Une fenêtre tmux oubliée contient une réponse précieuse.",
        "Quelqu'un fera un join sans saluer, mais te lira attentivement.",
        "Un /msg arrivé avant ton premier café sera mal interprété.",
        "Un cron jamais déclenché va exiger ton attention.",
        "Une typo glissée dans un README te suivra plus longtemps que de raison.",
    );

    my @recommandations = (
        "ne refuse pas le café qu'on te tend",
        "commit avant de partir manger",
        "fais un git pull avant d'ouvrir vi",
        "lance un htop : tu y verras quelque chose d'intéressant",
        "tape !active et lis attentivement les rangs",
        "envoie un sosreport pour le plaisir",
        "réponds à un ping que tu avais ignoré",
        "rejoins #boulets même si c'est calme",
        "écris dans BUGFIX_mb83.md au moins une ligne",
        "ne touche pas à iptables après 22h",
        "lis le man d'un outil que tu crois maîtriser",
        "salue Gwen en passant",
    );

    my @attentions = (
        "un cron qui s'emballe",
        "une regex un peu trop gourmande",
        "une PR qui dort depuis trop longtemps",
        "un disque /var qui grimpe en silence",
        "un certificat qui te lâche dans 3 jours",
        "une dépendance CPAN désuète",
        "un \"force push\" dont tu te souviendras",
        "un kill -9 qui paraissait nécessaire",
        "un sudo tapé trop vite",
        "un rollback que tu auras oublié de tester",
    );

    my @couleurs = qw(turquoise carmin indigo or pourpre ardoise émeraude saphir cuivre ivoire);
    my @chiffres = (3, 7, 11, 13, 17, 21, 23, 42, 47, 77, 100, 666);
    my @glyphs   = ("\x{2728}", "\x{1F31F}", "\x{1F319}", "\x{1F525}", "\x{2604}\x{FE0F}",
                    "\x{1F30C}", "\x{1F52E}", "\x{26A1}", "\x{1F300}");

    # Tirages (LCG local, mb444-B1)
    my $humeur   = $pick->(\@humeurs);
    my $event    = $pick->(\@evenements);
    my $reco     = $pick->(\@recommandations);
    my $attention = $pick->(\@attentions);
    my $couleur  = $pick->(\@couleurs);
    my $chiffre  = $pick->(\@chiffres);
    my $glyph    = $pick->(\@glyphs);
    # Pourcentage chance — biais positif léger
    my $chance   = 35 + ($next->() % 60);  # 35..94

    # (mb444-B1: plus de srand() — le RNG global n'est jamais touché.)

    # Affichage 3 lignes
    botPrivmsg($self, $reply_to,
        "$glyph \x02Horoscope du $date_key pour $target\x02 \x{2014} humeur $humeur");
    botPrivmsg($self, $reply_to,
        "  $event");
    botPrivmsg($self, $reply_to,
        sprintf("  Conseil : %s. Méfiance : %s.", $reco, $attention));
    botPrivmsg($self, $reply_to,
        sprintf("  \x{1F3B2} Chiffre %d \x{B7} \x{1F3A8} couleur %s \x{B7} \x{1F340} chance %d%%",
            $chiffre, $couleur, $chance));

    # Compteur consultations + hook achievement
    $self->{_horoscope_count}{$nick}++;
    if ($self->{achievements} && $channel =~ /^#/) {
        my $count = $self->{_horoscope_count}{$nick} // 0;
        eval { $self->{achievements}->check_horoscope($nick, $channel, $count) };
        if ($@) { $self->{logger}->log(1, "achievements check_horoscope error: $@") }
    }

    $self->{metrics}->inc('mediabot_horoscope_total') if $self->{metrics};
    return 1;
}

# =============================================================================
# mb117: Compat / Quotegame / Mood
# =============================================================================

# ---------------------------------------------------------------------------
# mbCompat_ctx --- !compat <nick1> <nick2>
# Calcul d'affinité IRC multi-dimensionnel.
#
# 4 dimensions :
#   1. Recouvrement horaire (intersection des heures actives)   - 30 pts
#   2. Vocabulaire commun (jaccard sur top 100 mots)           - 30 pts
#   3. Échanges karma mutuels (ring buffer)                     - 20 pts
#   4. Co-présence (msgs envoyés dans les 5min suivant l'autre) - 20 pts
#
# Score 0-100% avec interprétation textuelle.
# ---------------------------------------------------------------------------
sub mbCompat_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !compat <nick1> [nick2]  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games
    unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
        botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
        return;
    }

    unless (@args >= 1) {
        botNotice($self, $nick, 'Syntax: !compat <nick1> [nick2]');
        return;
    }

    my $n1 = lc($args[0]);
    my $n2 = @args >= 2 ? lc($args[1]) : lc($nick);

    if ($n1 eq $n2) {
        botPrivmsg($self, $channel, "$nick: a nick has 100% compatibility with itself \x{1F9D8}");
        return 1;
    }

    my $dbh = $self->{dbh};

    # === Dimension 1 : Recouvrement horaire (24 buckets) ====================
    my $sth_h = $dbh->prepare(q{
        SELECT cl.nick, HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?, ?)
          AND cl.event_type IN ('public','action')
        GROUP BY cl.nick, HOUR(cl.ts)
    });
    my %hours = ($n1 => [(0)x24], $n2 => [(0)x24]);
    my %total_msgs = ($n1 => 0, $n2 => 0);
    if ($sth_h && $sth_h->execute($channel, $n1, $n2)) {
        while (my $r = $sth_h->fetchrow_hashref) {
            my $who = lc($r->{nick});
            next unless exists $hours{$who};
            $hours{$who}[$r->{h}] = $r->{c};
            $total_msgs{$who} += $r->{c};
        }
        $sth_h->finish;
    }

    if ($total_msgs{$n1} == 0 || $total_msgs{$n2} == 0) {
        my $absent = $total_msgs{$n1} == 0 ? $n1 : $n2;
        botPrivmsg($self, $channel, "\x{1F50D} $absent: no activity recorded on $channel.");
        return 1;
    }

    # Normalise et calcule overlap (formule : 1 - 0.5*sum(|p1-p2|))
    my @p1 = map { $hours{$n1}[$_] / $total_msgs{$n1} } 0..23;
    my @p2 = map { $hours{$n2}[$_] / $total_msgs{$n2} } 0..23;
    my $diff = 0;
    $diff += abs($p1[$_] - $p2[$_]) for 0..23;
    my $hour_overlap = 1.0 - ($diff / 2.0);  # 0..1
    my $hour_score   = int($hour_overlap * 30);

    # === Dimension 2 : Vocabulaire commun (jaccard sur top 100 mots) =========
    # Fenêtre : derniers 50k msgs par nick pour rester rapide
    my %words;
    for my $who ($n1, $n2) {
        my $sth_w = $dbh->prepare(q{
            SELECT cl.publictext
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.nick = ?
              AND cl.event_type IN ('public','action')
            ORDER BY cl.ts DESC
            LIMIT 5000
        });
        my %w_counts;
        if ($sth_w && $sth_w->execute($channel, $who)) {
            while (my $r = $sth_w->fetchrow_arrayref) {
                my $txt = lc($r->[0] // '');
                # mb427-B1: tokenisation byte-safe (comme mb426). publictext est
                # en OCTETS UTF-8 (DBI ne décode pas) ; l'ancien
                # s/[^\w\s\x{00C0}-\x{017F}]/ /g gardait même un octet parasite
                # (café -> "caf\xC3"). Les octets >= 0x80 comptent comme lettres.
                for my $w (split /[^0-9A-Za-z_\x80-\xFF]+/, $txt) {
                    next unless length($w) >= 4;
                    $w_counts{$w}++;
                }
            }
            $sth_w->finish;
        }
        # Garder top 100 mots
        my @top = (sort { $w_counts{$b} <=> $w_counts{$a} } keys %w_counts)[0..99];
        @top = grep { defined } @top;
        $words{$who} = { map { $_ => 1 } @top };
    }
    my $intersect = 0;
    my $union     = 0;
    my %all_words = map { $_ => 1 } (keys %{$words{$n1}}, keys %{$words{$n2}});
    for my $w (keys %all_words) {
        $union++;
        $intersect++ if $words{$n1}{$w} && $words{$n2}{$w};
    }
    my $jaccard    = $union > 0 ? $intersect / $union : 0;
    my $vocab_score = int($jaccard * 30);

    # === Dimension 3 : Échanges karma mutuels (ring buffer) =================
    my $klog = $self->{_karma_log}{$channel} // [];
    my $karma_n1_to_n2 = 0; my $karma_n2_to_n1 = 0;
    my $karma_n1_to_n2_pos = 0; my $karma_n2_to_n1_pos = 0;
    for my $e (@$klog) {
        my $from = lc($e->{from} // '');
        my $to   = lc($e->{nick} // '');
        my $delta = $e->{delta} // '';
        if    ($from eq $n1 && $to eq $n2) { $karma_n1_to_n2++; $karma_n1_to_n2_pos++ if $delta eq '+1' }
        elsif ($from eq $n2 && $to eq $n1) { $karma_n2_to_n1++; $karma_n2_to_n1_pos++ if $delta eq '+1' }
    }
    my $karma_score = 0;
    if ($karma_n1_to_n2 + $karma_n2_to_n1 > 0) {
        # Réciprocité : si les deux donnent → bonus
        my $reciprocity = ($karma_n1_to_n2 > 0 && $karma_n2_to_n1 > 0) ? 1.0 : 0.5;
        my $positivity  = ($karma_n1_to_n2_pos + $karma_n2_to_n1_pos)
                        / ($karma_n1_to_n2 + $karma_n2_to_n1);
        my $volume      = ($karma_n1_to_n2 + $karma_n2_to_n1) >= 10 ? 1.0 : (($karma_n1_to_n2 + $karma_n2_to_n1) / 10);
        $karma_score = int(20 * $reciprocity * $positivity * $volume);
    }

    # === Dimension 4 : Co-présence (msgs dans 5min suivant l'autre) ==========
    # Requête : compter les paires de messages adjacents (n1 puis n2 dans 5min, et inversement)
    my $sth_co = $dbh->prepare(q{
        SELECT cl.nick, UNIX_TIMESTAMP(cl.ts) AS u
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?, ?)
          AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 90 DAY
        ORDER BY cl.ts ASC
    });
    my $copresence = 0;
    if ($sth_co && $sth_co->execute($channel, $n1, $n2)) {
        my $last_nick = '';
        my $last_ts   = 0;
        while (my $r = $sth_co->fetchrow_hashref) {
            my $cur = lc($r->{nick});
            if ($last_nick ne '' && $last_nick ne $cur && ($r->{u} - $last_ts) <= 300) {
                $copresence++;
            }
            $last_nick = $cur;
            $last_ts   = $r->{u};
        }
        $sth_co->finish;
    }
    # 100 paires d'échanges proches = 20 points max
    my $copres_score = $copresence >= 100 ? 20 : int($copresence / 5);

    # === Score final =========================================================
    my $total_score = $hour_score + $vocab_score + $karma_score + $copres_score;
    $total_score = 100 if $total_score > 100;
    $total_score = 0   if $total_score < 0;

    # Interprétation
    my ($verdict, $emoji) =
          $total_score >= 85 ? ('moitiés indissociables',       "\x{1F495}")
        : $total_score >= 70 ? ('âmes sœurs IRC',               "\x{1F49E}")
        : $total_score >= 55 ? ('complices solides',            "\x{1F91D}")
        : $total_score >= 40 ? ('complices à temps partiel',    "\x{1F60A}")
        : $total_score >= 25 ? ('interactions limitées',        "\x{1F44B}")
        : $total_score >= 10 ? ('chemins qui se croisent',      "\x{1F914}")
        :                       ('deux mondes parallèles',       "\x{1F30C}");

    # Barre de progression Unicode
    my $bar_filled = int($total_score / 5);   # 0..20
    my $bar = "\x{2588}" x $bar_filled . "\x{2591}" x (20 - $bar_filled);

    botPrivmsg($self, $channel,
        sprintf("%s \x02%s\x02 \x{2194} \x02%s\x02 : \x02%d%%\x02  %s",
            $emoji, $n1, $n2, $total_score, $verdict));
    botPrivmsg($self, $channel, "  [$bar]");
    botPrivmsg($self, $channel,
        sprintf("  \x{1F551} hours %d/30  \x{B7}  \x{1F4DD} vocab %d/30  \x{B7}  "
              . "\x{2728} karma %d/20  \x{B7}  \x{1F500} co-presence %d/20",
            $hour_score, $vocab_score, $karma_score, $copres_score));

    # Détails enrichis
    my @details;
    push @details, sprintf("%d common words", $intersect) if $intersect > 0;
    push @details, sprintf("%d karma exchanges", $karma_n1_to_n2 + $karma_n2_to_n1) if ($karma_n1_to_n2 + $karma_n2_to_n1) > 0;
    push @details, sprintf("%d adjacent msg pairs (90d)", $copresence) if $copresence > 0;
    botPrivmsg($self, $channel, "  " . join("  \x{B7}  ", @details)) if @details;

    # Hook achievement
    $self->{_compat_count}{$nick}++;
    if ($self->{achievements}) {
        my $cnt = $self->{_compat_count}{$nick} // 0;
        eval { $self->{achievements}->check_compat($nick, $channel, $cnt) };
        if ($@) { $self->{logger}->log(1, "achievements check_compat error: $@") }
    }

    $self->{metrics}->inc('mediabot_compat_total', { channel => $channel }) if $self->{metrics};
    logBot($self, $ctx->message, $channel, 'compat', "$n1 vs $n2 = $total_score%");
    return 1;
}

# ---------------------------------------------------------------------------
# _quotegame_cancel_timer / _quotegame_start_timer
# mb122: proactive quotegame timeout. The old lazy timeout still remains as a
# safety net in checkQuotegameAnswer(), but a real IO::Async countdown now
# announces the answer after 60 seconds even if nobody talks.
# ---------------------------------------------------------------------------
sub _quotegame_cancel_timer {
    my ($self, $channel) = @_;
    return unless $self && defined $channel;

    my $qg = $self->{_quotegame}{$channel} or return;

    my $timer = delete $qg->{timer};
    delete $qg->{timer_token};

    return unless $timer;

    my $loop = eval { $self->getLoop } || $self->{loop};
    eval { $timer->stop if $timer->can('stop') };
    eval { $loop->remove($timer) if $loop };
}

sub _quotegame_start_timer {
    my ($self, $channel, $token, $delay) = @_;
    return unless $self && defined $channel && defined $token;

    $delay ||= 60;

    my $loop = eval { $self->getLoop } || $self->{loop};
    unless ($loop) {
        eval {
            $self->{logger}->log(2, "Quotegame: no IO::Async loop available, keeping lazy timeout only");
        };
        return;
    }

    require IO::Async::Timer::Countdown;

    _quotegame_cancel_timer($self, $channel);

    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay => $delay,
        on_expire => sub {
            my $loop_now = eval { $self->getLoop } || $self->{loop};

            my $qg = $self->{_quotegame}{$channel};
            if ($qg && $qg->{active}
                    && defined($qg->{timer_token})
                    && $qg->{timer_token} eq $token) {

                $qg->{active} = 0;
                delete $qg->{timer};
                delete $qg->{timer_token};

                my $author = defined($qg->{author}) ? $qg->{author} : 'unknown';
                Mediabot::Helpers::botPrivmsg(
                    $self,
                    $channel,
                    "\x{23F0} Time's up! The answer was: \x02$author\x02"
                );
            }

            # mb326-B1: toujours libérer ce timer (retrait du loop + rupture du
            # cycle closure<->timer), y compris sur le chemin "stale/superseded"
            # (token remplacé par un nouveau round) qui faisait auparavant un
            # return sec et laissait le timer dans le loop ET dans le cycle.
            eval { $loop_now->remove($timer) if $loop_now && $timer };
            undef $timer;
        },
    );

    $self->{_quotegame}{$channel}{timer}       = $timer;
    $self->{_quotegame}{$channel}{timer_token} = $token;

    $loop->add($timer);
    $timer->start;
}


# ---------------------------------------------------------------------------
# mbQuotegame_ctx --- !quotegame [stop|top]
# Devine qui a dit la quote. État partagé en mémoire par canal.
# Réponses validées via checkQuotegameAnswer() appelé depuis on_message_PRIVMSG.
# ---------------------------------------------------------------------------
sub mbQuotegame_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !quotegame  (must be in a channel)'); return;
    }

    # mb118-IMP2: gate par chanset +Games (sauf stop/top: lecture toujours OK)
    if (!(@args && lc($args[0] // '') =~ /^(stop|top)$/)) {
        unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
            botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
            return;
        }
    }

    # !quotegame stop
    if (@args && lc($args[0]) eq 'stop') {
        my $qg = $self->{_quotegame}{$channel};
        if ($qg && $qg->{active}) {
            _quotegame_cancel_timer($self, $channel);
            $qg->{active} = 0;
            botPrivmsg($self, $channel,
                "\x{1F6D1} Quotegame stopped. Answer was: \x02$qg->{author}\x02");
        } else {
            botPrivmsg($self, $channel, 'No active quotegame.');
        }
        return 1;
    }

    # !quotegame top
    if (@args && lc($args[0]) eq 'top') {
        my $scores = $self->{_quotegame}{$channel}{scores} // {};
        unless (%$scores) {
            botPrivmsg($self, $channel, 'No quotegame scores yet on this channel.'); return 1;
        }
        my @sorted = sort { $scores->{$b} <=> $scores->{$a} || $a cmp $b } keys %$scores;
        my $top = scalar @sorted > 5 ? 5 : scalar @sorted;
        my @parts = map { "$_:" . $scores->{$_} } @sorted[0..$top-1];
        botPrivmsg($self, $channel, "\x{1F4DC} Quote detectives: " . join('  |  ', @parts));
        return 1;
    }

    # Vérifier qu'il n'y a pas déjà une question active
    my $qg = $self->{_quotegame}{$channel};
    if ($qg && $qg->{active}) {
        botPrivmsg($self, $channel,
            "\x{23F3} Quotegame already in progress (use \x02!quotegame stop\x02 to abort).");
        return 1;
    }

    # Récupérer une quote aléatoire qui n'est PAS de l'auteur du bot
    # Et idéalement d'un user encore actif (au moins 1 msg dans CHANNEL_LOG)
    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare(q{
        SELECT q.id_quotes, q.quotetext, u.nickname AS author
        FROM QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
        JOIN USER    u ON u.id_user    = q.id_user
        WHERE c.name = ? AND LENGTH(q.quotetext) >= 20
        ORDER BY RAND()
        LIMIT 1
    });
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }
    my $row = $sth->fetchrow_hashref; $sth->finish;
    unless ($row && $row->{quotetext}) {
        botPrivmsg($self, $channel, 'No quotes long enough for the game on this channel.');
        return 1;
    }

    # Préserver les scores cumulés
    my $prev_scores = ($qg && $qg->{scores}) ? $qg->{scores} : {};
    $self->{_quotegame}{$channel} = {
        active     => 1,
        id_quote   => $row->{id_quotes},
        author     => $row->{author},
        author_lc  => lc($row->{author}),
        started    => time(),
        deadline   => time() + 60,
        token      => join(':', $channel, ($row->{id_quotes} // 0), time(), int(rand(1_000_000))),
        scores     => $prev_scores,
    };

    # Masquer toute occurrence du nom de l'auteur dans la quote
    # mb121-B2: les nicks IRC peuvent contenir [ ] \ ^ _ ` { } | -
    # qui ne sont pas word chars Perl -> \b ne borde pas correctement
    # les nicks type [teuk], __user__, etc. On utilise des assertions
    # personnalisees basees sur le character class IRC (RFC 2812).
    my $masked = $row->{quotetext};
    my $author_lc = lc($row->{author});
    # nick chars IRC: lettres, chiffres, et certains specials. Les borders sont
    # "tout ce qui n'est PAS un nick char" (ou debut/fin de string).
    my $nick_char = qr/[A-Za-z0-9\[\]\\^_`{}|\-\x80-\xFF]/;  # mb445-B1: octets UTF-8 (>=0x80) font partie du mot
    $masked =~ s/(?<!$nick_char)\Q$row->{author}\E(?!$nick_char)/???/gi;
    # 2e passe sur la version lowercase au cas ou \Q...\E ne matche pas
    # case-insensitively pour des caracteres non-ASCII (defensif).
    $masked =~ s/(?<!$nick_char)\Q$author_lc\E(?!$nick_char)/???/gi;

    botPrivmsg($self, $channel,
        "\x{1F4DC} \x02Quotegame!\x02 Who said: \"\x02$masked\x02\"  \x{2014}  60s to answer with the nick");

    _quotegame_start_timer($self, $channel, $self->{_quotegame}{$channel}{token}, 60);

    return 1;
}

# ---------------------------------------------------------------------------
# checkQuotegameAnswer --- appelé depuis on_message_PRIVMSG (canal public)
# Validation déclenchée par tout message contenant un nick — peu coûteux.
# ---------------------------------------------------------------------------
sub checkQuotegameAnswer {
    my ($self, $sNick, $sChannel, $sMsg) = @_;
    return unless defined $sChannel && $sChannel =~ /^#/;
    my $qg = $self->{_quotegame}{$sChannel} or return;
    return unless $qg->{active};

    # Timeout passé
    if (time() > $qg->{deadline}) {
        _quotegame_cancel_timer($self, $sChannel);
        $qg->{active} = 0;
        Mediabot::Helpers::botPrivmsg($self, $sChannel,
            "\x{23F0} Time's up! The answer was: \x02$qg->{author}\x02");
        return;
    }

    return unless defined $sMsg && $sMsg ne '';

    # Le message contient-il le nick de l'auteur ?
    # On évite que l'auteur lui-même réponde "moi"
    return if lc($sNick) eq $qg->{author_lc};

    # mb121-B2: meme correction qu'a la creation de la quote -- les nicks IRC
    # contenant [ ] _ \ ^ { } | ne sont pas bornes correctement par \b.
    my $nick_char = qr/[A-Za-z0-9\[\]\\^_`{}|\-\x80-\xFF]/;  # mb445-B1: octets UTF-8 (>=0x80) font partie du mot
    my $msg_lc = lc($sMsg);
    if ($msg_lc =~ /(?<!$nick_char)\Q$qg->{author_lc}\E(?!$nick_char)/) {
        _quotegame_cancel_timer($self, $sChannel);
        $qg->{active} = 0;
        $qg->{scores}{$sNick}++;
        my $score = $qg->{scores}{$sNick};
        my $elapsed = time() - $qg->{started};
        Mediabot::Helpers::botPrivmsg($self, $sChannel,
            sprintf("\x{1F3AF} Correct, \x02%s\x02! It was \x02%s\x02 (in %ds, score: %d)",
                $sNick, $qg->{author}, $elapsed, $score));

        # Hook achievement
        if ($self->{achievements}) {
            eval { $self->{achievements}->check_quotegame($sNick, $sChannel, $score) };
        }
        $self->{metrics}->inc('mediabot_quotegame_correct_total') if $self->{metrics};
    }
}

# ---------------------------------------------------------------------------
# mbMood_ctx --- !mood
# Détection d'humeur du canal sur la dernière heure.
# Patterns FR + EN.
# ---------------------------------------------------------------------------
sub mbMood_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !mood  (must be in a channel)'); return;
    }

    # mb500: light per-nick cooldown — !mood now runs three CHANNEL_LOG scans
    # (sentiment + top talkers + peak hour), so guard against spam/DB load the
    # same way onthisday does.
    {
        my $cooldown_s = 15;
        my $now = time();
        $self->{_mood_cooldown} ||= {};
        my $lc_nick = lc($nick);
        my $last = $self->{_mood_cooldown}{$lc_nick};
        if (defined $last && ($now - $last) < $cooldown_s) {
            my $wait = $cooldown_s - ($now - $last);
            botNotice($self, $nick, "mood: please wait ${wait}s before asking again.");
            return;
        }
        $self->{_mood_cooldown}{$lc_nick} = $now;
        if (scalar(keys %{ $self->{_mood_cooldown} }) > 512) {
            for my $k (keys %{ $self->{_mood_cooldown} }) {
                delete $self->{_mood_cooldown}{$k}
                    if ($now - $self->{_mood_cooldown}{$k}) > 3600;
            }
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, 'mood: database unavailable.'); return; }
    my $sth = $dbh->prepare(q{
        SELECT cl.publictext
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
          AND cl.ts >= NOW() - INTERVAL 60 MINUTE
    });
    unless ($sth && $sth->execute($channel)) {
        botNotice($self, $nick, 'Database error.'); $sth->finish if $sth; return;
    }

    # Patterns FR/EN
    my @positive = qw(
        lol mdr ptdr xptdr haha hehe hihi yep ouais ouaip oui yes yep yeah
        merci thanks thx genial cool super excellent parfait nice top
        bravo felicitations clap kiff like love amour content heureux
        happy great awesome wonderful incroyable formidable bien sympa
    );
    my @negative = qw(
        putain merde chiant ridicule nul fail rate raté echec chiotte
        wtf wtf fuck fck damn shit hell hate deteste enfer pourri craignos
        catastrophe desastre horrible affreux relou pitié non nope nah ouch
        bof beurk dégueu degueu degu rage furieux furax énervé enerve
    );
    my @question = qw(qui quoi pourquoi pourquoi comment quand quand ou où);

    my %pos_h = map { $_ => 1 } @positive;
    my %neg_h = map { $_ => 1 } @negative;
    my %q_h   = map { $_ => 1 } @question;

    my $pos = 0; my $neg = 0; my $questions = 0;
    my $exclam = 0; my $total_msgs = 0;
    my %emoji_count;

    # Emoji regex Unicode — minimal set (les principaux)
    my $emoji_re = qr/[\x{1F600}-\x{1F64F}\x{1F300}-\x{1F5FF}\x{1F680}-\x{1F6FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}]/;

    while (my $r = $sth->fetchrow_arrayref) {
        my $txt = $r->[0] // '';
        $total_msgs++;
        $exclam += () = $txt =~ /!/g;
        $questions++ if $txt =~ /\?/;
        # mb446-B1: le comptage d'emojis doit porter sur des CARACTÈRES. publictext
        # arrive en OCTETS UTF-8 ; $emoji_re utilise des codepoints (\x{1F600}...)
        # qui ne peuvent JAMAIS matcher un octet (< 256) -> le détail « top emoji »
        # n'apparaissait jamais. On décode une copie (tolérant) pour ce scan ; la
        # tokenisation des mots reste byte-safe (mb427). L'emoji retenu est un
        # caractère, cohérent avec les \x{...} déjà émis dans la sortie mood.
        my $txt_chars = Encode::decode('UTF-8', $txt, Encode::FB_DEFAULT);
        while ($txt_chars =~ /($emoji_re)/g) { $emoji_count{$1}++ }
        # Tokeniser
        # mb427-B1: tokenisation byte-safe (comme mb426) — les mots accentués
        # (positifs/négatifs français) restent entiers et matchent les
        # dictionnaires de sentiment.
        my $lower = lc($txt);
        for my $w (split /[^0-9A-Za-z_\x80-\xFF]+/, $lower) {
            next unless length($w) >= 2;
            $pos++       if $pos_h{$w};
            $neg++       if $neg_h{$w};
            $questions++ if $q_h{$w};
        }
    }
    $sth->finish;

    if ($total_msgs == 0) {
        botPrivmsg($self, $channel,
            "\x{1F321}\x{FE0F} Mood $channel (last 60min): silence total \x{1F507}");
        return 1;
    }

    # Score : ratio positif - ratio négatif, normalisé sur (-1, +1) puis projeté en %
    my $total_sent = $pos + $neg;
    my $pos_ratio  = $total_sent > 0 ? $pos / $total_sent : 0.5;

    my ($mood_label, $mood_emoji);
    if    ($pos_ratio >= 0.80) { $mood_label = 'euphoric';    $mood_emoji = "\x{1F31F}"; }
    elsif ($pos_ratio >= 0.65) { $mood_label = 'joyful';      $mood_emoji = "\x{2600}\x{FE0F}"; }
    elsif ($pos_ratio >= 0.55) { $mood_label = 'positive';    $mood_emoji = "\x{1F600}"; }
    elsif ($pos_ratio >= 0.45) { $mood_label = 'balanced';    $mood_emoji = "\x{2696}\x{FE0F}"; }
    elsif ($pos_ratio >= 0.35) { $mood_label = 'tense';       $mood_emoji = "\x{1F62C}"; }
    elsif ($pos_ratio >= 0.20) { $mood_label = 'grumpy';      $mood_emoji = "\x{1F614}"; }
    else                        { $mood_label = 'apocalyptic'; $mood_emoji = "\x{1F4A2}"; }
    if ($total_sent == 0) { $mood_label = 'neutral'; $mood_emoji = "\x{1F636}"; }

    # Energy : volume + exclamations
    my $energy_label;
    if    ($total_msgs >= 200) { $energy_label = "very high \x{26A1}"; }
    elsif ($total_msgs >= 80)  { $energy_label = "high \x{1F525}"; }
    elsif ($total_msgs >= 30)  { $energy_label = 'medium'; }
    elsif ($total_msgs >= 5)   { $energy_label = "low \x{1F634}"; }
    else                        { $energy_label = "very low \x{1F636}"; }

    # Top emoji
    my $top_emoji = '';
    if (%emoji_count) {
        my ($e) = sort { $emoji_count{$b} <=> $emoji_count{$a} } keys %emoji_count;
        $top_emoji = sprintf("top emoji: %s\x{D7}%d", $e, $emoji_count{$e});
    }

    # Score 0-100%
    my $mood_pct = int($pos_ratio * 100);

    botPrivmsg($self, $channel,
        sprintf("\x{1F321}\x{FE0F} Mood %s (last 60min): %s \x02%s\x02 %d%%  \x{B7}  energy: %s (%d msgs)",
            $channel, $mood_emoji, $mood_label, $mood_pct, $energy_label, $total_msgs));

    my @details;
    push @details, "$pos positives"   if $pos > 0;
    push @details, "$neg negatives"   if $neg > 0;
    push @details, "$questions ?"     if $questions > 0;
    push @details, "$exclam !"        if $exclam > 0;
    push @details, $top_emoji         if $top_emoji;
    botPrivmsg($self, $channel, "  " . join(' | ', @details)) if @details;

    # mb498: "pulse" line — WHO is driving the last 60 min and WHEN the channel
    # peaked today. Turns mood (sentiment) into a fuller read of the room.
    # Best-effort: never blocks the mood answer.
    {
        my @pulse;

        # top talkers over the same 60-minute window as the mood scan
        my $sth_tt = $dbh->prepare(q{
            SELECT cl.nick AS nick, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= NOW() - INTERVAL 60 MINUTE
            GROUP BY cl.nick
            ORDER BY c DESC
            LIMIT 3
        });
        if ($sth_tt && eval { $sth_tt->execute($channel) }) {
            my @tt;
            while (my $r = $sth_tt->fetchrow_hashref) {
                push @tt, "$r->{nick} ($r->{c})";
            }
            $sth_tt->finish;
            push @pulse, "driven by: " . join(', ', @tt) if @tt;
        }

        # busiest hour of the current local day
        my $sth_pk = $dbh->prepare(q{
            SELECT HOUR(cl.ts) AS h, COUNT(*) AS c
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= CURDATE()
            GROUP BY HOUR(cl.ts)
            ORDER BY c DESC
            LIMIT 1
        });
        if ($sth_pk && eval { $sth_pk->execute($channel) }) {
            if (my $r = $sth_pk->fetchrow_hashref) {
                push @pulse, sprintf("peak today: %02dh-%02dh (%d msgs)",
                    $r->{h}, ($r->{h} + 1) % 24, $r->{c}) if defined $r->{h};
            }
            $sth_pk->finish;
        }

        botPrivmsg($self, $channel, "  " . join("  \x{B7}  ", @pulse)) if @pulse;
    }

    # Hook achievement
    $self->{_mood_count}{$nick}++;
    if ($self->{achievements}) {
        my $cnt = $self->{_mood_count}{$nick} // 0;
        eval { $self->{achievements}->check_mood($nick, $channel, $cnt) };
        if ($@) { $self->{logger}->log(1, "achievements check_mood error: $@") }
    }

    # Note: le check polyphony a été déplacé dans Achievements::check_msg (mb118)
    # pour ne plus dépendre d'un trigger explicite via !mood.

    $self->{metrics}->inc('mediabot_mood_total', { channel => $channel }) if $self->{metrics};
    return 1;
}

# =============================================================================
# mb118: Leaderboard / Chronos
# =============================================================================

# ---------------------------------------------------------------------------
# mbLeaderboard_ctx --- !leaderboard [msgs|karma|trivia|duels|achievs]
# Classement consolidé multi-métriques du canal courant.
# Par défaut : affiche le top 3 dans chaque catégorie.
# ---------------------------------------------------------------------------

sub mbLeaderboard_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !leaderboard [msgs|karma|trivia|duels|achievs] [24h|7d|30d]');
        return 1;
    }

    my %cat_alias = (
        msg          => 'msgs',
        msgs         => 'msgs',
        message      => 'msgs',
        messages     => 'msgs',
        karma        => 'karma',
        trivia       => 'trivia',
        duel         => 'duels',
        duels        => 'duels',
        achiev       => 'achievs',
        achievs      => 'achievs',
        achievement  => 'achievs',
        achievements => 'achievs',
        all          => '',
        alltime      => '',
        total        => '',
    );

    my $only = '';
    my $period_arg = '';

    for my $arg (@args) {
        next unless defined $arg && $arg ne '';
        my $a = lc($arg);

        if ($a =~ /^\d+[hdw]$/) {
            $period_arg = $a;
            next;
        }

        if (exists $cat_alias{$a}) {
            $only = $cat_alias{$a};
            next;
        }

        botNotice($self, $nick, 'Syntax: !leaderboard [msgs|karma|trivia|duels|achievs] [24h|7d|30d]');
        return 1;
    }

    my ($period_label, $period_num, $period_unit_sql) = ('', undef, undef);
    if ($period_arg ne '' && $period_arg =~ /^(\d+)([hdw])$/) {
        my ($n, $unit) = ($1, $2);
        if ($n < 1) {
            botNotice($self, $nick, 'Leaderboard period must be at least 1 unit.');
            return 1;
        }

        # mb121-B1: clamp on the converted value (hours or days), not on the
        # raw input. Without this, `100w` would generate INTERVAL 700 DAY which
        # bypasses the intended 365-day ceiling.
        my $max_units = $unit eq 'h' ? 365 * 24       # ~1 year in hours
                       : $unit eq 'd' ? 365           # 1 year in days
                       :                52;           # 1 year in weeks (52w = 364d)
        if ($n > $max_units) {
            botNotice($self, $nick,
                "Leaderboard period must be <= ${max_units}${unit} (1 year cap).");
            return 1;
        }

        if ($unit eq 'h') {
            $period_num      = $n;
            $period_unit_sql = 'HOUR';
            $period_label    = "${n}h";
        }
        elsif ($unit eq 'd') {
            $period_num      = $n;
            $period_unit_sql = 'DAY';
            $period_label    = "${n}d";
        }
        else {
            $period_num      = $n * 7;
            $period_unit_sql = 'DAY';
            $period_label    = "${n}w";
        }
    }

    if ($period_arg ne '' && $only && $only !~ /^(?:msgs|karma)$/) {
        botNotice($self, $nick, 'Period filters are currently supported for leaderboard msgs and karma only.');
        return 1;
    }

    my $dbh = $self->{dbh};

    my $period_suffix = $period_label ? " last $period_label" : '';
    my $cl_period_sql = $period_label ? " AND cl.ts >= NOW() - INTERVAL $period_num $period_unit_sql" : '';
    my $kl_period_sql = $period_label ? " AND kl.ts >= NOW() - INTERVAL $period_num $period_unit_sql" : '';

    # --- Top 3 messages -----------------------------------------------------
    my @msgs_top;
    if (!$only || $only eq 'msgs') {
        my $sth = $dbh->prepare(qq{
            SELECT cl.nick, COUNT(*) AS msg_count
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.event_type IN ('public','action')
              $cl_period_sql
            GROUP BY cl.nick
            ORDER BY msg_count DESC
            LIMIT 3
        });
        if ($sth && $sth->execute($channel)) {
            while (my $r = $sth->fetchrow_hashref) {
                push @msgs_top, [$r->{nick}, $r->{msg_count}];
            }
            $sth->finish;
        }
    }

    # --- Top 3 karma --------------------------------------------------------
    my @karma_top;
    if (!$only || $only eq 'karma') {
        if ($period_label) {
            my $sth = $dbh->prepare(qq{
                SELECT kl.nick, SUM(kl.delta) AS score
                FROM KARMA_LOG kl
                JOIN CHANNEL c ON c.id_channel = kl.id_channel
                WHERE c.name = ?
                  $kl_period_sql
                GROUP BY kl.nick
                HAVING score <> 0
                ORDER BY score DESC, kl.nick ASC
                LIMIT 3
            });
            if ($sth && $sth->execute($channel)) {
                while (my $r = $sth->fetchrow_hashref) {
                    push @karma_top, [$r->{nick}, sprintf('%+d', $r->{score} || 0)];
                }
                $sth->finish;
            }
        }
        else {
            my $sth = $dbh->prepare(q{
                SELECT k.nick, k.score
                FROM KARMA k
                JOIN CHANNEL c ON c.id_channel = k.id_channel
                WHERE c.name = ?
                ORDER BY k.score DESC
                LIMIT 3
            });
            if ($sth && $sth->execute($channel)) {
                while (my $r = $sth->fetchrow_hashref) {
                    push @karma_top, [$r->{nick}, $r->{score}];
                }
                $sth->finish;
            }
        }
    }

    # Period mode without an explicit category deliberately reports only sources
    # with reliable timestamps.
    my $show_alltime_sections = !$period_label;

    # --- Top 3 trivia -------------------------------------------------------
    my @trivia_top;
    if ($show_alltime_sections && (!$only || $only eq 'trivia')) {
        my $sth = $dbh->prepare(q{
            SELECT ts.nick, ts.score
            FROM TRIVIA_SCORES ts
            JOIN CHANNEL c ON c.id_channel = ts.id_channel
            WHERE c.name = ?
            ORDER BY ts.score DESC
            LIMIT 3
        });
        if ($sth && $sth->execute($channel)) {
            while (my $r = $sth->fetchrow_hashref) {
                push @trivia_top, [$r->{nick}, $r->{score}];
            }
            $sth->finish;
        }
    }

    # --- Top 3 duels (mémoire) ----------------------------------------------
    my @duel_top;
    if ($show_alltime_sections && (!$only || $only eq 'duels')) {
        my $dst = $self->{_duel_stats}{$channel} // {};
        my @sorted = sort {
            ($dst->{$b}{wins} // 0) <=> ($dst->{$a}{wins} // 0)
            || $a cmp $b
        } keys %$dst;
        for my $n (@sorted[0..2]) {
            next unless defined $n;
            push @duel_top, [$n, ($dst->{$n}{wins} // 0)];
        }
    }

    # --- Top 3 achievements -------------------------------------------------
    my @ach_top;
    if ($show_alltime_sections && (!$only || $only eq 'achievs')) {
        if ($self->{achievements}) {
            my %counts_on_chan;
            for my $key (keys %{ $self->{achievements}{data} // {} }) {
                my ($n, $ch) = split /\x00/, $key, 2;
                # mb435-B3: mb430 stores channel keys in lowercase. A
                # mixed-case IRC target must still see its leaderboard data.
                next unless defined $ch && $ch eq lc($channel // '');
                $counts_on_chan{$n} = scalar keys %{ $self->{achievements}{data}{$key} };
            }
            my @sorted = sort {
                $counts_on_chan{$b} <=> $counts_on_chan{$a}
                || $a cmp $b
            } keys %counts_on_chan;
            for my $n (@sorted[0..2]) {
                next unless defined $n;
                push @ach_top, [$n, $counts_on_chan{$n}];
            }
        }
    }

    # --- Format des médailles ----------------------------------------------
    my @medals = ("\x{1F947}", "\x{1F948}", "\x{1F949}");   # 🥇 🥈 🥉
    my $fmt_top = sub {
        my ($top, $label) = @_;
        return undef unless @$top;
        my @parts;
        for my $i (0..$#{$top}) {
            my ($n, $v) = @{$top->[$i]};
            push @parts, "$medals[$i] $n ($v)";
        }
        return "$label  " . join('  ', @parts);
    };

    botPrivmsg($self, $channel,
        "\x{1F3C5} \x02Leaderboard\x02 $channel"
        . ($only ? " [$only]" : '')
        . ($period_suffix ? " [$period_suffix]" : ''));

    my $any = 0;
    if (my $l = $fmt_top->(\@msgs_top,   "\x{1F4AC}  msgs$period_suffix   :")) { botPrivmsg($self, $channel, "  $l"); $any++; }
    if (my $l = $fmt_top->(\@karma_top,  "\x{1F31F}  karma$period_suffix  :")) { botPrivmsg($self, $channel, "  $l"); $any++; }
    if (my $l = $fmt_top->(\@trivia_top, "\x{1F9E0}  trivia :"))   { botPrivmsg($self, $channel, "  $l"); $any++; }
    if (my $l = $fmt_top->(\@duel_top,   "\x{2694}\x{FE0F}  duels  :")) { botPrivmsg($self, $channel, "  $l"); $any++; }
    if (my $l = $fmt_top->(\@ach_top,    "\x{1F3C6}  achievs:"))   { botPrivmsg($self, $channel, "  $l"); $any++; }

    if ($period_label && !$only) {
        botPrivmsg($self, $channel, "  \x{2139} Period mode shows timestamped categories only: msgs and karma.");
    }

    botPrivmsg($self, $channel, "  (no data yet)") unless $any;
    return 1;
}


# ---------------------------------------------------------------------------
# mbChronos_ctx --- !chronos
# Chronologie ASCII des événements marquants du canal :
#   - premier message du canal
#   - jour record (plus de messages)
#   - heure record (plus de messages dans une heure)
#   - dernier message
#   - karma all-time leader
#   - trivia all-time champion
#   - première mention de chaque "veteran" (top 5 messages)
# ---------------------------------------------------------------------------
sub mbChronos_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless ($channel && $channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: !chronos [short|full]  (must be in a channel)'); return;
    }

    my $mode = @args ? lc($args[0] // '') : 'full';
    if ($mode eq 'brief') { $mode = 'short'; }
    if ($mode ne '' && $mode ne 'short' && $mode ne 'full') {
        botNotice($self, $nick, 'Syntax: !chronos [short|full]');
        return 1;
    }

    my $dbh = $self->{dbh};

    # 1. Premier message du canal (avec auteur)
    my $sth1 = $dbh->prepare(q{
        SELECT cl.nick, cl.ts, cl.publictext
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.ts ASC
        LIMIT 1
    });
    my $first;
    if ($sth1 && $sth1->execute($channel)) {
        $first = $sth1->fetchrow_hashref; $sth1->finish;
    }
    unless ($first) {
        botPrivmsg($self, $channel, "\x{1F4DC} No history found on $channel.");
        return 1;
    }

    # 2. Dernier message
    my $sth2 = $dbh->prepare(q{
        SELECT cl.nick, cl.ts
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.ts DESC
        LIMIT 1
    });
    my $last;
    if ($sth2 && $sth2->execute($channel)) {
        $last = $sth2->fetchrow_hashref; $sth2->finish;
    }

    # 3. Jour record
    my $sth3 = $dbh->prepare(q{
        SELECT DATE(cl.ts) AS d, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        GROUP BY DATE(cl.ts)
        ORDER BY c DESC
        LIMIT 1
    });
    my $best_day;
    if ($sth3 && $sth3->execute($channel)) {
        $best_day = $sth3->fetchrow_hashref; $sth3->finish;
    }

    # 4. Heure record
    my $sth4 = $dbh->prepare(q{
        SELECT DATE_FORMAT(cl.ts, '%Y-%m-%d %H:00') AS h, COUNT(*) AS c
        FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        GROUP BY DATE_FORMAT(cl.ts, '%Y-%m-%d %H:00')
        ORDER BY c DESC
        LIMIT 1
    });
    my $best_hour;
    if ($sth4 && $sth4->execute($channel)) {
        $best_hour = $sth4->fetchrow_hashref; $sth4->finish;
    }

    # 5. Karma all-time leader
    my $sth5 = $dbh->prepare(q{
        SELECT k.nick, k.score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE c.name = ?
        ORDER BY k.score DESC
        LIMIT 1
    });
    my $karma_leader;
    if ($sth5 && $sth5->execute($channel)) {
        $karma_leader = $sth5->fetchrow_hashref; $sth5->finish;
    }

    # 6. Trivia champion
    my $sth6 = $dbh->prepare(q{
        SELECT ts.nick, ts.score
        FROM TRIVIA_SCORES ts
        JOIN CHANNEL c ON c.id_channel = ts.id_channel
        WHERE c.name = ?
        ORDER BY ts.score DESC
        LIMIT 1
    });
    my $trivia_champ;
    if ($sth6 && $sth6->execute($channel)) {
        $trivia_champ = $sth6->fetchrow_hashref; $sth6->finish;
    }

    # 7. Total quotes
    my $sth7 = $dbh->prepare(q{
        SELECT COUNT(*) AS c
        FROM QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
        WHERE c.name = ?
    });
    my $quote_count = 0;
    if ($sth7 && $sth7->execute($channel)) {
        my $r = $sth7->fetchrow_hashref; $sth7->finish;
        $quote_count = $r ? ($r->{c} // 0) : 0;
    }

    # === Affichage ASCII timeline ============================================
    my $first_d = ($first->{ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';
    my $last_d  = ($last && $last->{ts} =~ /^(\d{4}-\d{2}-\d{2})/) ? $1 : '?';

    if ($mode eq 'short') {
        my $genesis = $first->{nick} // '?';
        my $last_nick = ($last && $last->{nick}) ? $last->{nick} : '?';

        my @parts;
        push @parts, "genesis $first_d by $genesis";
        push @parts, "peak day $best_day->{d} (" . _fmt_n($best_day->{c}) . " msgs)" if $best_day;
        push @parts, "karma king $karma_leader->{nick} (" . sprintf('%+d', $karma_leader->{score}) . ")" if $karma_leader;
        push @parts, "trivia $trivia_champ->{nick} (" . _fmt_n($trivia_champ->{score}) . ")" if $trivia_champ && $trivia_champ->{score} > 0;
        push @parts, _fmt_n($quote_count) . " quote(s)" if $quote_count > 0;

        botPrivmsg($self, $channel,
            "\x{1F4DC} \x02Chronos\x02 $channel \x{2014} " . join('  |  ', @parts));
        botPrivmsg($self, $channel,
            "\x{1F4CD} now: last activity $last_d by $last_nick  |  use: chronos full");

        $self->{metrics}->inc('mediabot_chronos_total', { channel => $channel }) if $self->{metrics};
        return 1;
    }

    botPrivmsg($self, $channel,
        "\x{1F4DC} \x02Chronos\x02 $channel \x{2014} a saga in chapters");

    # Premier message (avec extrait tronqué)
    my $first_text = $first->{publictext} // '';
    # mb441-B1: troncature UTF-8-safe (publictext en octets UTF-8) via le helper
    # partagé mb429 — un substr brut à 60 octets coupait un accent en deux.
    $first_text = Mediabot::Helpers::truncate_utf8($first_text, 60);
    botPrivmsg($self, $channel,
        "  \x{1F30C}  \x02$first_d\x02  Genesis  \x{2014}  $first->{nick}: \"$first_text\"");

    # Jour record
    if ($best_day) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F389}  \x02%s\x02  Peak day  \x{2014}  %s messages in 24h",
                $best_day->{d}, _fmt_n($best_day->{c})));
    }

    # Heure record
    if ($best_hour) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F525}  \x02%s\x02  Peak hour  \x{2014}  %s messages in 60min",
                $best_hour->{h}, _fmt_n($best_hour->{c})));
    }

    # Karma leader
    if ($karma_leader) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F451}  \x02all-time\x02  Karma king  \x{2014}  %s (%+d)",
                $karma_leader->{nick}, $karma_leader->{score}));
    }

    # Trivia champion
    if ($trivia_champ && $trivia_champ->{score} > 0) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F9E0}  \x02all-time\x02  Trivia champion  \x{2014}  %s (%s correct)",
                $trivia_champ->{nick}, _fmt_n($trivia_champ->{score})));
    }

    # Quotes
    if ($quote_count > 0) {
        botPrivmsg($self, $channel,
            sprintf("  \x{1F4DD}  \x02all-time\x02  Quote vault  \x{2014}  %s quote(s) preserved",
                _fmt_n($quote_count)));
    }

    # Last message
    if ($last) {
        my $last_ago = '?';
        if ($last->{ts} =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
            require Time::Local;
            my $ep = eval { Time::Local::timelocal($6,$5,$4,$3,$2-1,$1-1900) };
            if ($ep) {
                my $diff = time() - $ep;
                $last_ago = $diff < 60        ? "${diff}s ago"
                          : $diff < 3600      ? sprintf('%dm ago',  int($diff/60))
                          : $diff < 86400     ? sprintf('%dh ago',  int($diff/3600))
                          :                     sprintf('%dd ago',  int($diff/86400));
            }
        }
        botPrivmsg($self, $channel,
            "  \x{1F4CD}  \x02$last_d\x02  Now  \x{2014}  last activity $last_ago ($last->{nick})");
    }

    $self->{metrics}->inc('mediabot_chronos_total', { channel => $channel }) if $self->{metrics};
    return 1;
}


# ---------------------------------------------------------------------------
# mbFeatures_ctx --- !features / !capabilities / !caps
# Compact channel capabilities view. No schema change: reads existing chansets,
# runtime objects and known modules.
# ---------------------------------------------------------------------------
sub _mbFeatures_chanset_state {
    my ($self, $channel, $name, %opts) = @_;

    my $default = exists $opts{default} ? $opts{default} : 0;
    my $id = eval { Mediabot::Helpers::getIdChansetList($self, $name) };

    return $default ? 'on (legacy default)' : 'missing'
        unless defined $id && $id ne '';

    my $set = eval { Mediabot::Helpers::getIdChannelSet($self, $channel, $id) };
    return $set ? 'on' : 'off';
}

sub mbFeatures_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: features  (must be used in a channel)');
        return 1;
    }

    my $ach_defs = 0;
    eval {
        $ach_defs = scalar keys %{ $self->{achievements}->list_definitions }
            if $self->{achievements};
        1;
    };

    my $ach_announce = _mbFeatures_chanset_state($self, $channel, 'AchievementAnnounce', default => 0);
    my $games        = _mbFeatures_chanset_state($self, $channel, 'Games', default => 1);
    my $urltitle     = _mbFeatures_chanset_state($self, $channel, 'UrlTitle', default => 0);
    my $youtube      = _mbFeatures_chanset_state($self, $channel, 'Youtube', default => 0);
    my $ytsearch     = _mbFeatures_chanset_state($self, $channel, 'YoutubeSearch', default => 0);
    my $randomquote  = _mbFeatures_chanset_state($self, $channel, 'RandomQuote', default => 0);
    my $claude       = _mbFeatures_chanset_state($self, $channel, 'Claude', default => 0);
    my $nocolors     = _mbFeatures_chanset_state($self, $channel, 'NoColors', default => 0);
    my $antiflood    = _mbFeatures_chanset_state($self, $channel, 'AntiFlood', default => 0);

    my $metrics = $self->{metrics} ? 'on' : 'off';
    my $radio = 'unknown';
    eval {
        my $enabled = $self->{conf}->get('radio.ENABLED');
        $radio = (defined $enabled && $enabled =~ /^(?:1|yes|true|on)$/i) ? 'on' : 'off';
        1;
    };

    my @lines = (
        "\x{1F52D} Capabilities for $channel",
        "  \x{1F3C6} achievements: " . ($self->{achievements} ? 'on' : 'off')
            . "  | announce: $ach_announce"
            . "  | catalogue: $ach_defs",
        "  \x{1F3B2} games: $games  | commands: duel, horoscope, compat, quotegame",
        "  \x{1F517} links: UrlTitle=$urltitle  Youtube=$youtube  YoutubeSearch=$ytsearch",
        "  \x{1F4AC} social memory: profil/radar/dashboard/leaderboard/chronos/mood available",
        "  \x{1F916} integrations: Claude=$claude  RandomQuote=$randomquote  Radio=$radio",
        "  \x{1F6E1} safety/output: AntiFlood=$antiflood  NoColors=$nocolors  Metrics=$metrics",
        "  Help: help social / help games / help chansets",
    );

    for my $line (@lines) {
        botNotice($self, $nick, $line);
    }

    return 1;
}


# ---------------------------------------------------------------------------
# mbObservatory_ctx --- !observatory / !obs
# A compact public state view for the current channel. No schema change.
# ---------------------------------------------------------------------------
sub _mbObservatory_uptime {
    my $seconds = time() - $^T;
    $seconds = 0 if $seconds < 0;

    my $days = int($seconds / 86400);
    $seconds %= 86400;
    my $hours = int($seconds / 3600);
    $seconds %= 3600;
    my $mins = int($seconds / 60);

    return sprintf('%dd %02dh', $days, $hours) if $days > 0;
    return sprintf('%dh %02dm', $hours, $mins) if $hours > 0;
    return sprintf('%dm', $mins);
}

sub _mbObservatory_energy_label {
    my ($msgs) = @_;
    $msgs ||= 0;

    return 'silent'   if $msgs == 0;
    return 'quiet'    if $msgs < 10;
    return 'awake'    if $msgs < 40;
    return 'lively'   if $msgs < 120;
    return 'storming';
}

sub mbObservatory_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: observatory  (must be used in a channel)');
        return 1;
    }

    my $dbh = $self->{dbh};

    my ($msgs_1h, $nicks_1h) = (0, 0);
    eval {
        my $sth = $dbh->prepare(q{
            SELECT COUNT(*) AS msgs, COUNT(DISTINCT cl.nick) AS nicks
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= NOW() - INTERVAL 60 MINUTE
        });
        if ($sth && $sth->execute($channel)) {
            my $r = $sth->fetchrow_hashref || {};
            $msgs_1h = $r->{msgs}  || 0;
            $nicks_1h = $r->{nicks} || 0;
            $sth->finish;
        }
        1;
    };

    my $ach_defs = 0;
    eval {
        $ach_defs = scalar keys %{ $self->{achievements}->list_definitions }
            if $self->{achievements};
        1;
    };

    my $games        = _mbFeatures_chanset_state($self, $channel, 'Games', default => 1);
    my $announce     = _mbFeatures_chanset_state($self, $channel, 'AchievementAnnounce', default => 0);
    my $urltitle     = _mbFeatures_chanset_state($self, $channel, 'UrlTitle', default => 0);
    my $claude       = _mbFeatures_chanset_state($self, $channel, 'Claude', default => 0);
    my $antiflood    = _mbFeatures_chanset_state($self, $channel, 'AntiFlood', default => 0);

    my $metrics = $self->{metrics} ? 'on' : 'off';
    my $energy  = _mbObservatory_energy_label($msgs_1h);
    my $uptime  = _mbObservatory_uptime();

    botPrivmsg($self, $channel,
        "\x{1F52D} \x02Observatory\x02 $channel \x{2014} process up $uptime"
      . "  | games $games"
      . "  | achievements " . ($self->{achievements} ? 'on' : 'off')
      . " ($ach_defs)"
      . "  | announce $announce"
    );

    botPrivmsg($self, $channel,
        "\x{1FAC0} last hour: " . _fmt_n($msgs_1h) . " msg(s) / " . _fmt_n($nicks_1h) . " nick(s)"
      . "  | energy $energy"
      . "  | UrlTitle $urltitle"
      . "  | Claude $claude"
      . "  | AntiFlood $antiflood"
      . "  | metrics $metrics"
    );

    $self->{metrics}->inc('mediabot_observatory_total', { channel => $channel }) if $self->{metrics};

    return 1;
}

# ===========================================================================
# mbRecap_ctx --- !recap [<window>] [ai]
# mb472 : résume en NOTICE privé ce qui s'est dit sur un canal pendant une
# fenêtre de temps. Fonctionnalité vitrine prévue par la direction 3.3 (§5).
#
# Fenêtre :
#   - !recap            -> depuis la dernière activité connue de l'appelant sur
#                          ce canal (USER_SEEN.seen_at), plafonnée à RECAP_MAX_H ;
#                          à défaut de seen, RECAP_DEFAULT_H heures.
#   - !recap 2h / 30m / 90m -> fenêtre explicite, plafonnée à RECAP_MAX_H.
#   - !recap ai         -> résumé en langage naturel via Claude (si configuré),
#                          sinon repli sur le résumé statistique.
#
# Sortie : statistique par défaut (nb messages, top parleurs, plage, échantillon),
# toujours en NOTICE privé pour ne pas flooder le canal.
#
# Garde-fous : fenêtre bornée (RECAP_MAX_H, défaut 24h), lignes lues bornées
# (RECAP_MAX_ROWS, défaut 2000), cooldown par nick (RECAP_COOLDOWN_S, défaut 30s).
# Lecture seule ; s'appuie sur l'index composite idx_channel_log_channel_ts (A4).
# ===========================================================================
sub mbRecap_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $channel = $ctx->channel;

    # !recap n'a de sens que dans un canal (le "quoi de neuf ICI").
    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: recap [<window>] [ai]  — use it in a channel (e.g. 30m, 2h).");
        return;
    }

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    my $want_ai = 0;
    my $window_arg;
    for my $a (@args) {
        if (lc($a) eq 'ai')      { $want_ai = 1; }
        elsif ($a =~ /^\d+[hm]$/i) { $window_arg = lc($a); }
    }

    # --- configuration (avec valeurs par défaut sûres) ---
    my $cfg = sub {
        my ($key, $default) = @_;
        my $v = eval { $self->{conf}->get("main.$key") };
        return (defined $v && $v ne '') ? $v : $default;
    };
    my $max_h      = int($cfg->('RECAP_MAX_H',       24));
    my $default_h  = int($cfg->('RECAP_DEFAULT_H',    6));
    my $max_rows   = int($cfg->('RECAP_MAX_ROWS',  2000));
    my $cooldown_s = int($cfg->('RECAP_COOLDOWN_S',   30));
    $max_h     = 24   if $max_h     <= 0;
    $default_h = 6    if $default_h <= 0;
    $max_rows  = 2000 if $max_rows  <= 0;

    # --- cooldown par nick (mémoire bornée, best-effort) ---
    my $now = time();
    $self->{_recap_cooldown} ||= {};
    my $lc_nick = lc($nick);
    if ($cooldown_s > 0) {
        my $last = $self->{_recap_cooldown}{$lc_nick};
        if (defined $last && ($now - $last) < $cooldown_s) {
            my $wait = $cooldown_s - ($now - $last);
            botNotice($self, $nick, "recap: please wait ${wait}s before asking again.");
            return;
        }
        $self->{_recap_cooldown}{$lc_nick} = $now;
        # purge opportuniste pour borner la mémoire
        if (scalar(keys %{ $self->{_recap_cooldown} }) > 512) {
            for my $k (keys %{ $self->{_recap_cooldown} }) {
                delete $self->{_recap_cooldown}{$k}
                    if ($now - $self->{_recap_cooldown}{$k}) > 3600;
            }
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, "recap: database unavailable.");
        return;
    }

    # --- résoudre id_channel ---
    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "recap: channel not known to the bot.");
        return;
    }

    # --- déterminer la fenêtre (en secondes) ---
    my $window_s;
    my $window_label;
    if (defined $window_arg) {
        if    ($window_arg =~ /^(\d+)h$/) { $window_s = $1 * 3600; }
        elsif ($window_arg =~ /^(\d+)m$/) { $window_s = $1 * 60;   }
        $window_label = $window_arg;
    }
    else {
        # depuis la dernière activité connue de l'appelant (USER_SEEN)
        my $seen_epoch;
        my $sth_seen = $dbh->prepare(
            'SELECT UNIX_TIMESTAMP(seen_at) FROM USER_SEEN WHERE nick = ? LIMIT 1');
        if ($sth_seen && $sth_seen->execute($lc_nick)) {
            ($seen_epoch) = $sth_seen->fetchrow_array;
            $sth_seen->finish;
        }
        if (defined $seen_epoch && $seen_epoch > 0 && $seen_epoch <= $now) {
            $window_s = $now - $seen_epoch;
            $window_label = "since you were last seen";
        }
        else {
            $window_s = $default_h * 3600;
            $window_label = "${default_h}h";
        }
    }

    # borne haute
    my $max_s = $max_h * 3600;
    if ($window_s > $max_s) {
        $window_s = $max_s;
        $window_label = "${max_h}h (capped)";
    }
    $window_s = 60 if $window_s < 60;   # au moins une minute

    # --- lire les messages de la fenêtre (index composite id_channel, ts) ---
    my $sth = $dbh->prepare(q{
        SELECT nick, publictext, UNIX_TIMESTAMP(ts) AS t
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND ts >= DATE_SUB(NOW(), INTERVAL ? SECOND)
          AND event_type IN ('public','action')
        ORDER BY ts ASC
        LIMIT ?
    });
    unless ($sth && $sth->execute($id_channel, $window_s, $max_rows)) {
        botNotice($self, $nick, "recap: could not read the channel log.");
        return;
    }

    my @rows;
    my %by_nick;
    my ($first_t, $last_t);
    while (my $r = $sth->fetchrow_hashref) {
        # ne pas recaper les propres messages de l'appelant
        next if lc($r->{nick}) eq $lc_nick;
        push @rows, $r;
        $by_nick{ $r->{nick} }++;
        $first_t //= $r->{t};
        $last_t = $r->{t};
    }
    $sth->finish;

    my $msg_count = scalar @rows;
    if ($msg_count == 0) {
        botNotice($self, $nick, "recap ($window_label): nothing much happened on $channel — no messages from others.");
        return;
    }

    # --- résumé IA optionnel ---
    if ($want_ai) {
        my $can_ai = 0;
        my $api_key = eval { $self->{conf}->get('anthropic.API_KEY') };
        $can_ai = 1 if defined $api_key && $api_key ne '';
        if ($can_ai && Mediabot::External::Claude->can('claudeAI')) {
            # Construire un transcript borné pour le prompt.
            my $transcript = '';
            for my $r (@rows) {
                my $line = "<$r->{nick}> " . ($r->{publictext} // '');
                $line = substr($line, 0, 300);
                last if length($transcript) + length($line) + 1 > 6000;
                $transcript .= $line . "\n";
            }
            my $prompt = "Summarize this IRC channel conversation in 3-5 concise bullet points, "
                       . "in the same language as the conversation. Only the summary, no preamble.\n\n"
                       . $transcript;
            my $ai_ok = eval {
                Mediabot::External::Claude::claudeAI(
                    $self, $prompt, $nick, undef,
                    sub {
                        my ($text) = @_;
                        return unless defined $text && $text ne '';
                        for my $line (split /\n/, $text) {
                            next if $line =~ /^\s*$/;
                            botNotice($self, $nick, $line);
                        }
                    },
                );
                1;
            };
            if ($ai_ok) {
                $self->{metrics}->inc('mediabot_recap_total', { channel => $channel, mode => 'ai' })
                    if $self->{metrics};
                return 1;
            }
            # sinon : repli sur le statistique ci-dessous
            botNotice($self, $nick, "recap: AI summary unavailable, showing stats instead.");
        }
        else {
            botNotice($self, $nick, "recap: AI not configured, showing stats instead.");
        }
    }

    # --- résumé statistique ---
    my $span_min = defined($first_t) && defined($last_t) && $last_t >= $first_t
        ? int(($last_t - $first_t) / 60) : 0;

    # top parleurs (jusqu'à 5)
    my @top = sort { $by_nick{$b} <=> $by_nick{$a} || lc($a) cmp lc($b) } keys %by_nick;
    my $ntalkers = scalar @top;
    @top = @top[0 .. 4] if @top > 5;
    my $top_str = join(', ', map { "$_ ($by_nick{$_})" } @top);

    botNotice($self, $nick,
        "recap $channel ($window_label): $msg_count message(s) from $ntalkers nick(s)"
        . ($span_min > 0 ? " over ~${span_min} min." : "."));
    botNotice($self, $nick, "Top: $top_str") if $top_str ne '';

    # échantillon : première et dernière lignes, tronquées
    if (@rows) {
        my $first = $rows[0];
        my $last  = $rows[-1];
        my $trim = sub { my $s = shift // ''; $s =~ s/[\r\n\0]+/ /g; length($s) > 200 ? substr($s,0,197)."..." : $s };
        botNotice($self, $nick, "First: <$first->{nick}> " . $trim->($first->{publictext}));
        if (@rows > 1) {
            botNotice($self, $nick, "Last:  <$last->{nick}> " . $trim->($last->{publictext}));
        }
        botNotice($self, $nick, "Tip: !recap ai for a natural-language summary.")
            if !$want_ai;
    }

    $self->{metrics}->inc('mediabot_recap_total', { channel => $channel, mode => 'stats' })
        if $self->{metrics};

    return 1;
}

# ===========================================================================
# Factoids — shared per-channel key/value facts (mb476).
#   !learn <keyword> = <value>   store or update a fact (anyone can)
#   !whatis <keyword>            recall it (also increments a hit counter)
#   !forget <keyword>            delete it (author or channel op/admin)
#   !factoids [pattern]          list keywords (optionally filtered)
#
# Backed by the FACTOID table (unique per channel+keyword). Channel only.
# Gated by the +Factoids chanset (default on). Values are length-capped and
# newline-sanitised. Keyword is normalised to lowercase.
# ===========================================================================

# helper: resolve id_channel for the ctx channel, or undef.
sub _factoid_id_channel {
    my ($self, $channel) = @_;
    return undef unless isIrcChannelTarget($channel);
    my $cid = eval { Mediabot::Helpers::channel_id_cached($self, $channel) };
    return $cid if $cid;
    my $obj = $self->{channels}{lc $channel};
    return $obj ? (eval { $obj->get_id } || undef) : undef;
}

# helper: is the factoids feature enabled on this channel?
sub _factoid_enabled {
    my ($self, $channel) = @_;
    return eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'Factoids', default => 1)
    } // 1;
}

sub mbLearn_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: learn <keyword> = <value>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $raw  = join(' ', @args);
    $raw =~ s/^\s+|\s+$//g;

    # Format: <keyword> = <value>
    unless ($raw =~ /^(.+?)\s*=\s*(.+)$/) {
        botNotice($self, $nick, "Syntax: learn <keyword> = <value>");
        return;
    }
    my ($keyword, $value) = ($1, $2);
    $keyword =~ s/^\s+|\s+$//g;
    $keyword = lc $keyword;
    $value   =~ s/[\r\n\0]+/ /g;
    $value   =~ s/^\s+|\s+$//g;

    unless ($keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "learn: keyword must be 1-64 chars of letters/digits/_.- (no spaces).");
        return;
    }
    if ($value eq '') {
        botNotice($self, $nick, "learn: value cannot be empty.");
        return;
    }
    $value = truncate_utf8($value, 400, '');

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "learn: database unavailable."); return; }

    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "learn: channel not known to the bot."); return; }

    my $uid = eval { my $u = $ctx->user; $u ? $u->id : undef };

    # UPSERT on (id_channel, keyword). On update, keep original author but
    # refresh value/updated_at (ON DUPLICATE preserves created_by/created_at).
    my $sth = $dbh->prepare(q{
        INSERT INTO FACTOID (id_channel, keyword, value, created_by, created_by_nick)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = CURRENT_TIMESTAMP
    });
    unless ($sth && $sth->execute($id_channel, $keyword, $value, $uid, $nick)) {
        botNotice($self, $nick, "learn: could not store the factoid.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Learned '$keyword' for $channel.");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'learn' })
        if $self->{metrics};
    return 1;
}

sub mbWhatis_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    # mb477: "?keyword" quick recall passes a leading __quiet__ sentinel so that
    # a spontaneous "?word" stays silent when nothing is known (no syntax/error
    # spam), while an explicit "!whatis word" still gives feedback.
    my $quiet = (@args && $args[0] eq '__quiet__') ? 1 : 0;
    shift @args if $quiet;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: whatis <keyword>  (use it in a channel)") unless $quiet;
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: whatis <keyword>") unless $quiet;
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "whatis: database unavailable.") unless $quiet; return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "whatis: channel not known to the bot.") unless $quiet; return; }

    my $sth = $dbh->prepare(q{
        SELECT value, created_by_nick FROM FACTOID
        WHERE id_channel = ? AND keyword = ? LIMIT 1
    });
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "whatis: lookup failed.") unless $quiet;
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'. Teach me: learn $keyword = ...") unless $quiet;
        return;
    }

    # increment hit counter (best-effort, non-fatal)
    eval {
        my $up = $dbh->prepare('UPDATE FACTOID SET hits = hits + 1 WHERE id_channel = ? AND keyword = ?');
        $up->execute($id_channel, $keyword) if $up;
        $up->finish if $up;
    };

    botPrivmsg($self, $channel, "$keyword: $row->{value}");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'whatis' })
        if $self->{metrics};
    return 1;
}

sub mbForget_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: forget <keyword>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: forget <keyword>");
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "forget: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "forget: channel not known to the bot."); return; }

    # who created it?
    my $sth = $dbh->prepare('SELECT created_by, created_by_nick FROM FACTOID WHERE id_channel = ? AND keyword = ? LIMIT 1');
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "forget: lookup failed.");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'.");
        return;
    }

    # permission: original author (by nick) OR a channel operator (by level).
    my $is_author = (defined $row->{created_by_nick} && lc($row->{created_by_nick}) eq lc($nick)) ? 1 : 0;
    my $is_op = 0;
    unless ($is_author) {
        my $handle = eval { my $u = $ctx->user; $u ? $u->nickname : undef };
        if (defined $handle && $handle ne '') {
            my (undef, $lvl) = eval { getIdUserChannelLevel($self, $handle, $channel) };
            # USER_CHANNEL.level is the per-channel scale; >=400 is operator+.
            $is_op = 1 if defined $lvl && $lvl >= 400;
        }
    }
    unless ($is_author || $is_op) {
        botNotice($self, $nick, "forget: only the author or a channel op can forget '$keyword'.");
        return;
    }

    my $del = $dbh->prepare('DELETE FROM FACTOID WHERE id_channel = ? AND keyword = ?');
    unless ($del && $del->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "forget: delete failed.");
        return;
    }
    $del->finish;

    botNotice($self, $nick, "Forgot '$keyword' on $channel.");
    $self->{metrics}->inc('mediabot_factoid_total', { channel => $channel, op => 'forget' })
        if $self->{metrics};
    return 1;
}

sub mbFactoids_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: factoids [pattern]  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $pattern = lc(join(' ', @args));
    $pattern =~ s/^\s+|\s+$//g;

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "factoids: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "factoids: channel not known to the bot."); return; }

    # mb478: "factoids top" — most consulted facts (uses the hits counter).
    if ($pattern eq 'top') {
        my $sth = $dbh->prepare(q{
            SELECT keyword, hits FROM FACTOID
            WHERE id_channel = ? AND hits > 0
            ORDER BY hits DESC, keyword ASC LIMIT 10
        });
        unless ($sth && $sth->execute($id_channel)) {
            botNotice($self, $nick, "factoids: listing failed.");
            return;
        }
        my @top;
        while (my ($k, $h) = $sth->fetchrow_array) { push @top, "$k ($h)"; }
        $sth->finish;
        unless (@top) {
            botNotice($self, $nick, "No factoids have been recalled yet on $channel.");
            return;
        }
        botNotice($self, $nick, "Top factoids on $channel: " . join(', ', @top));
        return 1;
    }

    my ($sql, @bind);
    if ($pattern ne '' && $pattern =~ /^[a-z0-9_.\-*?]{1,64}$/) {
        # translate glob to LIKE, escaping literal % and _
        my $like = '';
        for my $ch (split //, $pattern) {
            if    ($ch eq '*') { $like .= '%'; }
            elsif ($ch eq '?') { $like .= '_'; }
            elsif ($ch eq '%') { $like .= '\%'; }
            elsif ($ch eq '_') { $like .= '\_'; }
            else               { $like .= $ch; }
        }
        $sql  = 'SELECT keyword FROM FACTOID WHERE id_channel = ? AND keyword LIKE ? ORDER BY keyword ASC LIMIT 60';
        @bind = ($id_channel, $like);
    }
    else {
        $sql  = 'SELECT keyword FROM FACTOID WHERE id_channel = ? ORDER BY keyword ASC LIMIT 60';
        @bind = ($id_channel);
    }

    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute(@bind)) {
        botNotice($self, $nick, "factoids: listing failed.");
        return;
    }
    my @keys;
    while (my ($k) = $sth->fetchrow_array) { push @keys, $k; }
    $sth->finish;

    unless (@keys) {
        botNotice($self, $nick, $pattern ne ''
            ? "No factoids matching '$pattern' on $channel."
            : "No factoids on $channel yet. Add one: learn <keyword> = <value>");
        return;
    }
    botNotice($self, $nick, scalar(@keys) . " factoid(s) on $channel: " . join(', ', @keys));
    return 1;
}

# ---------------------------------------------------------------------------
# mbFactoid_ctx --- !factoid <keyword>
# mb478: detailed info about one factoid: value, author, created/updated dates,
# and how many times it has been recalled. Read-only, channel-gated.
# ---------------------------------------------------------------------------
sub mbFactoid_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: factoid <keyword>  (use it in a channel)");
        return;
    }
    return unless _factoid_enabled($self, $channel);

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $keyword = lc(join(' ', @args));
    $keyword =~ s/^\s+|\s+$//g;
    unless ($keyword ne '' && $keyword =~ /^[a-z0-9_.\-]{1,64}$/) {
        botNotice($self, $nick, "Syntax: factoid <keyword>");
        return;
    }

    my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "factoid: database unavailable."); return; }
    my $id_channel = _factoid_id_channel($self, $channel);
    unless ($id_channel) { botNotice($self, $nick, "factoid: channel not known to the bot."); return; }

    my $sth = $dbh->prepare(q{
        SELECT value, created_by_nick,
               DATE_FORMAT(created_at, '%Y-%m-%d') AS created_d,
               DATE_FORMAT(updated_at, '%Y-%m-%d') AS updated_d,
               hits
        FROM FACTOID
        WHERE id_channel = ? AND keyword = ? LIMIT 1
    });
    unless ($sth && $sth->execute($id_channel, $keyword)) {
        botNotice($self, $nick, "factoid: lookup failed.");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    unless ($row) {
        botNotice($self, $nick, "I don't know '$keyword'.");
        return;
    }

    my $author  = defined($row->{created_by_nick}) && $row->{created_by_nick} ne ''
                ? $row->{created_by_nick} : 'unknown';
    my $created = $row->{created_d} // '?';
    my $updated = $row->{updated_d} // '?';
    my $hits    = $row->{hits} // 0;
    my $date_part = ($updated ne $created)
                  ? "created $created by $author, updated $updated"
                  : "created $created by $author";

    botNotice($self, $nick, "factoid '$keyword': $date_part, $hits recall(s).");
    botNotice($self, $nick, "value: $row->{value}");
    return 1;
}

# ===========================================================================
# mbOnThisDay_ctx --- !onthisday  (alias !otd)
# mb489: "on this day" — resurface what happened on this channel on the same
# calendar day (month+day) in previous years/months. A nostalgia/engagement
# feature for long-lived channels, built entirely on CHANNEL_LOG (uses the
# composite (id_channel, ts) index). Read-only, channel-gated, throttled.
#
# Output (private NOTICE, no channel flood):
#   - which past date(s) had activity, how many messages, top talker;
#   - one representative message from that day (a longer line, to avoid "lol").
# ===========================================================================
sub mbOnThisDay_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: onthisday  (use it in a channel)");
        return;
    }
    # opt-out via the same flag as recap-style history features
    return unless eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'OnThisDay', default => 1)
    } // 1;

    # light per-nick cooldown (reuse a dedicated bucket)
    my $cooldown_s = 20;
    my $now = time();
    $self->{_otd_cooldown} ||= {};
    my $lc_nick = lc($nick);
    my $last = $self->{_otd_cooldown}{$lc_nick};
    if (defined $last && ($now - $last) < $cooldown_s) {
        my $wait = $cooldown_s - ($now - $last);
        botNotice($self, $nick, "onthisday: please wait ${wait}s before asking again.");
        return;
    }
    $self->{_otd_cooldown}{$lc_nick} = $now;
    if (scalar(keys %{ $self->{_otd_cooldown} }) > 512) {
        for my $k (keys %{ $self->{_otd_cooldown} }) {
            delete $self->{_otd_cooldown}{$k}
                if ($now - $self->{_otd_cooldown}{$k}) > 3600;
        }
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "onthisday: database unavailable."); return; }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "onthisday: channel not known to the bot.");
        return;
    }

    # mb499: optional explicit date argument. Accept MM-DD or MM/DD (also a
    # lone D/DD is not accepted — need both fields). Defaults to today.
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my %date_opts;
    if (@args && defined $args[0] && $args[0] ne '') {
        my $arg = $args[0];
        if ($arg =~ m{^\s*(\d{1,2})[-/.](\d{1,2})\s*$}) {
            my ($mm, $dd) = ($1 + 0, $2 + 0);
            # basic per-month day validation (29 Feb allowed: some year had it)
            my @maxd = (31,29,31,30,31,30,31,31,30,31,30,31);
            unless ($mm >= 1 && $mm <= 12 && $dd >= 1 && $dd <= $maxd[$mm - 1]) {
                botNotice($self, $nick, "onthisday: invalid date '$arg' (use MM-DD, e.g. 12-25).");
                return;
            }
            %date_opts = (month => $mm, day => $dd);
        }
        else {
            botNotice($self, $nick, "onthisday: unrecognized date '$arg' (use MM-DD, e.g. 01-01).");
            return;
        }
    }

    my @lines = Mediabot::UserCommands::_onthisday_lines($self, $id_channel, $channel, %date_opts);
    unless (@lines) {
        my $when = %date_opts ? "on that date" : "on this day";
        botNotice($self, $nick, "Nothing recorded on this channel $when in earlier years — yet.");
        return;
    }

    return queueBotNotices($self, $nick, @lines);
}

# ---------------------------------------------------------------------------
# _onthisday_lines($id_channel, $channel_label) -> @lines
# mb496: the pure computation behind !onthisday, factored out so both the
# command and the daily digest tick share ONE implementation. Read-only.
# Returns an empty list when there is no past activity on this calendar day.
# ---------------------------------------------------------------------------
sub _onthisday_lines {
    my ($self, $id_channel, $channel_label, %opts) = @_;
    my $dbh = $self->{dbh};
    return () unless $dbh && defined $id_channel;

    # mb499: optional explicit calendar date (month/day). When omitted, use
    # today (CURDATE) exactly as before — the daily digest relies on this.
    my $has_date = defined $opts{month} && defined $opts{day};
    my ($month, $day) = $has_date ? ($opts{month}, $opts{day}) : ();

    # Month/day SQL expression + bind values, shared by all three queries.
    my ($md_expr, @md_bind);
    if ($has_date) {
        $md_expr = 'MONTH(ts) = ? AND DAY(ts) = ?';
        @md_bind = ($month, $day);
    }
    else {
        $md_expr = 'MONTH(ts) = MONTH(CURDATE()) AND DAY(ts) = DAY(CURDATE())';
        @md_bind = ();
    }

    # "Historical only" bound. For today, exclude the current day. For an
    # explicit date, exclude the current year only when that date hasn't
    # occurred yet this year (a future MM-DD), so a past date this year counts.
    my $year_bound = '';
    if (!$has_date) {
        $year_bound = ' AND ts < CURDATE()';
    }
    else {
        # exclude current year if (month,day) is today or still ahead this year
        $year_bound = ' AND (YEAR(ts) < YEAR(CURDATE()) '
                    . 'OR (? < MONTH(CURDATE()) OR (? = MONTH(CURDATE()) AND ? < DAY(CURDATE()))))';
    }
    my @year_bound_bind = $has_date ? ($month, $month, $day) : ();

    my $sth = $dbh->prepare(qq{
        SELECT YEAR(ts)               AS y,
               COUNT(*)               AS msgs,
               COUNT(DISTINCT nick)   AS people
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND $md_expr$year_bound
        GROUP BY YEAR(ts)
        ORDER BY y DESC
    });
    return () unless $sth && $sth->execute($id_channel, @md_bind, @year_bound_bind);
    my @years;
    while (my $r = $sth->fetchrow_hashref) { push @years, $r; }
    $sth->finish;
    return () unless @years;

    # human label for the date being shown
    my $date_label = '';
    if ($has_date) {
        my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my $mname = ($month >= 1 && $month <= 12) ? $mon[$month - 1] : sprintf('%02d', $month);
        $date_label = sprintf(' (%s %d)', $mname, $day);
    }

    my @lines;
    my $total = 0; $total += $_->{msgs} for @years;
    my $span  = @years == 1 ? "$years[0]{y}" : "$years[-1]{y}-$years[0]{y}";
    push @lines, "On this day on $channel_label$date_label ($span): $total message(s) across " . scalar(@years) . " year(s).";

    my $shown = 0;
    for my $r (@years) {
        last if $shown >= 5;
        my $tt = $dbh->prepare(qq{
            SELECT nick, COUNT(*) AS c
            FROM CHANNEL_LOG
            WHERE id_channel = ?
              AND event_type IN ('public','action')
              AND YEAR(ts)  = ?
              AND $md_expr
            GROUP BY nick ORDER BY c DESC LIMIT 1
        });
        my $topnick = '?';
        if ($tt && $tt->execute($id_channel, $r->{y}, @md_bind)) {
            if (my $tr = $tt->fetchrow_hashref) { $topnick = $tr->{nick}; }
            $tt->finish;
        }
        push @lines, sprintf("  %d: %d msg, %d people, most active: %s",
            $r->{y}, $r->{msgs}, $r->{people}, $topnick);
        $shown++;
    }

    my $ry = $years[0]{y};
    my $rm = $dbh->prepare(qq{
        SELECT nick, publictext
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND YEAR(ts)  = ?
          AND $md_expr
          AND CHAR_LENGTH(publictext) BETWEEN 25 AND 300
        ORDER BY CHAR_LENGTH(publictext) DESC
        LIMIT 8
    });
    if ($rm && $rm->execute($id_channel, $ry, @md_bind)) {
        my @cand;
        while (my $mr = $rm->fetchrow_hashref) { push @cand, $mr; }
        $rm->finish;
        if (@cand) {
            my $pick = $cand[int(rand(scalar @cand))];
            my $text = $pick->{publictext} // '';
            $text =~ s/[\r\n\0]+/ /g;
            $text = Mediabot::Helpers::truncate_utf8($text, 200, '...') if length($text) > 200;
            push @lines, "From $ry — <$pick->{nick}> $text";
        }
    }

    return @lines;
}

# ===========================================================================
# mbMilestone_ctx --- !milestone
# mb502: channel milestones — total public messages logged, the next round
# milestone, progress toward it, and an ETA based on the recent daily rate.
# A celebratory, engagement-oriented read of how far the channel has come.
# Read-only against CHANNEL_LOG (uses the composite (id_channel, ts) index).
# ===========================================================================
sub mbMilestone_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    unless (isIrcChannelTarget($channel)) {
        botNotice($self, $nick, "Syntax: milestone  (use it in a channel)");
        return;
    }

    my $dbh = $self->{dbh};
    unless ($dbh) { botNotice($self, $nick, "milestone: database unavailable."); return; }

    my $channel_obj = $self->{channels}{lc $channel};
    my $id_channel  = $channel_obj ? eval { $channel_obj->get_id } : undef;
    unless (defined $id_channel) {
        botNotice($self, $nick, "milestone: channel not known to the bot.");
        return;
    }

    # total public messages + how long the channel has been logging
    my $sth = $dbh->prepare(q{
        SELECT COUNT(*) AS total,
               MIN(ts)  AS first_ts,
               UNIX_TIMESTAMP(MIN(ts)) AS first_uts
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND event_type IN ('public','action')
    });
    unless ($sth && $sth->execute($id_channel)) {
        botNotice($self, $nick, "milestone: lookup failed.");
        return;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    my $total = $row ? ($row->{total} // 0) : 0;
    if ($total <= 0) {
        botPrivmsg($self, $channel, "No messages logged yet on $channel — the journey starts now!");
        return 1;
    }

    # next round milestone: 1k steps below 100k, 100k steps at/above 1M-ish.
    my $next = _milestone_next($total);
    my $remaining = $next - $total;

    # recent daily rate over the last 30 days -> ETA
    my $rate_sth = $dbh->prepare(q{
        SELECT COUNT(*) AS c
        FROM CHANNEL_LOG
        WHERE id_channel = ?
          AND event_type IN ('public','action')
          AND ts >= NOW() - INTERVAL 30 DAY
    });
    my $per_day = 0;
    if ($rate_sth && $rate_sth->execute($id_channel)) {
        my $rr = $rate_sth->fetchrow_hashref;
        $rate_sth->finish;
        my $last30 = $rr ? ($rr->{c} // 0) : 0;
        $per_day = $last30 / 30 if $last30 > 0;
    }

    my $pct = $next > 0 ? int(($total / $next) * 100) : 0;

    my @bits;
    push @bits, sprintf("\x02%s\x02: %s public messages logged", $channel, _group_int($total));
    botPrivmsg($self, $channel, join('', @bits));

    my $line2 = sprintf("  next milestone: %s (%s to go, %d%%)",
        _group_int($next), _group_int($remaining), $pct);
    if ($per_day >= 0.5) {
        my $days = $remaining / $per_day;
        $line2 .= sprintf(" \x{B7} ~%s at %s msg/day",
            _humanize_days($days), _group_int(int($per_day + 0.5)));
    }
    botPrivmsg($self, $channel, $line2);

    # a touch of history: when did it all start
    if (defined $row->{first_uts}) {
        my $age_days = int((time() - $row->{first_uts}) / 86400);
        my $since = $row->{first_ts} // '';
        $since =~ s/ .*$//;   # keep the date part
        botPrivmsg($self, $channel,
            sprintf("  logging since %s (%s) \x{B7} lifetime average %s msg/day",
                $since, _humanize_days($age_days),
                _group_int($age_days > 0 ? int($total / $age_days + 0.5) : $total)));
    }
    return 1;
}

# next round milestone above $n (adaptive step)
sub _milestone_next {
    my ($n) = @_;
    my $step = $n < 10_000    ? 1_000
             : $n < 100_000   ? 5_000
             : $n < 1_000_000 ? 50_000
             :                  100_000;
    my $next = (int($n / $step) + 1) * $step;
    return $next;
}

# 1234567 -> "1,234,567"
sub _group_int {
    my ($n) = @_;
    $n = int($n // 0);
    1 while $n =~ s/^(-?\d+)(\d{3})/$1,$2/;
    return $n;
}

# a day count -> friendly "3 years", "5 months", "12 days"
sub _humanize_days {
    my ($d) = @_;
    $d = 0 if !defined $d || $d < 0;
    return sprintf("%d day%s", $d, $d == 1 ? '' : 's') if $d < 45;
    if ($d < 365) {
        my $m = int($d / 30 + 0.5);
        return sprintf("%d month%s", $m, $m == 1 ? '' : 's');
    }
    my $y = $d / 365;
    return sprintf("%.1f years", $y);
}

1;
