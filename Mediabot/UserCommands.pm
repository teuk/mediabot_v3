package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use POSIX qw(strftime);
use Time::Local qw(timegm timelocal);
use Time::Piece;
use List::Util qw(min);
use Encode ();   # mb630-B1: _irc_bytes appelle Encode::encode directement.
use Exporter 'import';

# mb348-B1: les statistiques basees sur CHANNEL_LOG filtrent les VRAIS messages
# via event_type IN ('public','action'), et non l'ancien faux proxy
# publictext IS NOT NULL (qui comptait aussi join/part/kick/mode/topic/notice).
# Le viewer de log brut .logs (_cmd_chanlog) reste volontairement non filtre.
use Try::Tiny;
use Mediabot::Helpers;
use Mediabot::AsyncWorker;
# mb670-A: the newest channel-history implementations live in a dedicated
# module while their historical UserCommands symbols remain imported here.
# This keeps dispatch and plugin/test call sites stable during the staged split.
use Mediabot::SocialHistory qw(
    _fmt_n
    _awards_add
    _awards_pick
    mbAwards_ctx
    _yearbook_best_key
    _yearbook_month_label
    _yearbook_day_label
    _yearbook_collect
    mbYearbook_ctx
    mbMemory_ctx
    _memory_rand_bounded
    _memory_lines
    _profile_community_footprint
    mbProfil_ctx
    mbDashboard_ctx
    mbMood_ctx
    mbLeaderboard_ctx
    mbChronos_ctx
    _recap_text
    _recap_parse
    _ach_progress
    mbRecap_ctx
    mbOnThisDay_ctx
    _onthisday_lines
    mbMilestone_ctx
    _milestone_next
    _milestone_last
    _group_int
    _humanize_days
);
use Mediabot::Karma qw(
    mbKarma_ctx
    processKarma
    mbKarmaHist_ctx
    _karma_current_score
    mbKarmaWatch_ctx
    mbKarmaInfo_ctx
    mbKarmaGraph_ctx
    mbKarmaReset_ctx
    mbKarmaDiff_ctx
    mbKarmaTop_ctx
);
use Mediabot::CommunityState qw(
    mbRemind_ctx
    mbRemindList_ctx
    mbRemindCancel_ctx
    mbRemindSnooze_ctx
    deliverReminders
    mbPoll_ctx
    mbVote_ctx
    mbPollResult_ctx
    mbPollStop_ctx
    mbPollExtend_ctx
    mbPollStatus_ctx
    mbPollVoters_ctx
    mbUnvote_ctx
    _notes_ensure_loaded
    mbNote_ctx
    mbNotes_ctx
    _factoid_id_channel
    _factoid_enabled
    mbLearn_ctx
    mbWhatis_ctx
    mbForget_ctx
    mbFactoids_ctx
    mbFactoid_ctx
);

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
    mbAwards_ctx
    mbYearbook_ctx
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
    mbMemory_ctx

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
        # mb576-B1: pre-USER_SEEN history may already live in the archive.
        my $id_channel = 0;

        if (defined $chan_for_part) {
            my $channel_obj = $self->{channels}{lc $chan_for_part}
                           || $self->{channels}{lc($chan_for_part)};
            $id_channel = eval { $channel_obj->get_id } || 0;
        }

        if (defined($chan_for_part) && $id_channel) {
            # mb576-B1: LIMIT 1 par table, la fusion garde la plus recente
            # (le dernier passage d'un ancien vit dans l'archive).
            my $seen_best;
            my $seen_chan_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext, event_type
                 FROM __CLSRC__ cl
                 WHERE id_channel = ?
                   AND nick = ?
                   AND event_type IN ('message', 'public', 'action', 'join', 'part', 'quit')
                 ORDER BY ts DESC LIMIT 1",
                [ $id_channel, $targetNick ], sub {
                    my ($r) = @_;
                    $seen_best = $r
                        if !$seen_best
                        || (($r->{uts} // 0) > ($seen_best->{uts} // 0));
                }, 'all');
            # mb578-B1: panne LIVE = echec franc — sans quoi seen pourrait
            # repondre depuis une archive ancienne seule.
            unless ($seen_chan_g->{live_ok}) {
                botNotice($self, $nick, 'Database error.');
                return;
            }
            {
                if (my $r = $seen_best) {
                    $chanlog = {
                        ts    => $r->{ts},
                        uts   => $r->{uts} // 0,
                        host  => $r->{userhost} // '',
                        text  => $r->{publictext} // '',
                        event => (($r->{event_type} // 'message') =~ /\A(?:public|action)\z/
                            ? 'message' : ($r->{event_type} // 'message')),
                    };
                }
            }
        }
        else {
            # mb576-B1: LIMIT 1 par table, fusion = le quit le plus recent.
            my $quit_best;
            my $seen_quit_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
                "SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
                 FROM __CLSRC__ cl
                 WHERE nick = ? AND event_type = 'quit'
                 ORDER BY ts DESC LIMIT 1",
                [ $targetNick ], sub {
                    my ($r) = @_;
                    $quit_best = $r
                        if !$quit_best
                        || (($r->{uts} // 0) > ($quit_best->{uts} // 0));
                }, 'presence');
            unless ($seen_quit_g->{live_ok}) {
                botNotice($self, $nick, 'Database error.');
                return;
            }
            if (my $r = $quit_best) {
                $quit = {
                    ts   => $r->{ts},
                    uts  => $r->{uts} // 0,
                    host => $r->{userhost} // '',
                    text => $r->{publictext} // '',
                };
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
    # mb576-B1: compteurs carriere -> vif + archive par requetes par table.
    # mb576-B1: une petite requete PAR TABLE + fusion Perl — jamais de
    # UNION ALL derive (WHERE pousses mais pas ORDER/LIMIT ; les COUNT
    # materialisent). Comparaisons de ts au format fixe -> gt/lt suffisent.
    # mb577-B1: scope content (l'archive n'est jointe que si CONTENT_DAYS>0),
    # event_type explicite (des « msg » ne comptent pas la presence), et le
    # succes se lit sur live_ok — zero ligne est un succes valide.
    # mb578-B1: msg_count et last_msg restent des MESSAGES (public/action,
    # scope content) ; first_seen redevient la PREMIERE TRACE du nick —
    # tout event_type, scope 'all' (un JOIN archive anterieur au premier
    # message fait foi). La revue avait raison : mb577 avait change
    # « join date » en « date du premier message ».
    my ($msg_count, $last_msg, $first_seen) = (0, undef, undef);
    my $stats_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*)  AS msg_count,
               MAX(ts)  AS last_msg
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE LOWER(cl.nick) = LOWER(?)
          AND c.name = ?
          AND cl.event_type IN ('public','action')
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
    }, [ $target, $channel ], sub {
        my ($r) = @_;
        $msg_count += $r->{msg_count} // 0;
        $last_msg = $r->{last_msg}
            if defined $r->{last_msg}
            && (!defined $last_msg || $r->{last_msg} gt $last_msg);
    }, 'content');
    unless ($stats_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my $stats_first_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT MIN(cl.ts) AS first_seen
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE LOWER(cl.nick) = LOWER(?)
          AND c.name = ?
    }, [ $target, $channel ], sub {
        $first_seen = $_[0]->{first_seen}
            if defined $_[0]->{first_seen}
            && (!defined $first_seen || $_[0]->{first_seen} lt $first_seen);
    }, 'all');
    unless ($stats_first_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    $last_msg //= 'never';

    # A1: total messages on channel for percentage (global, no period filter)
    # Keep the denominator aligned with the user aggregate above.
    # mb578-B1: gather indispensable (les pourcentages en dependent) —
    # panne LIVE = echec franc, jamais un pct calcule sur un total absent.
    my $total = 0;
    my $stats_tot_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*) AS total
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ?
          AND cl.event_type IN ('public','action')
          AND NOT (
              LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^m[[:space:]]+stats([[:space:]]|$)'
              OR LOWER(TRIM(COALESCE(cl.publictext, ''))) REGEXP '^!stats([[:space:]]|$)'
          )
    }, [ $channel ], sub { $total += $_[0]->{total} // 0 }, 'content');
    unless ($stats_tot_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
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
    # mb579-B1: un nick deja apparu mais encore silencieux a bien une
    # premiere apparition. Le compteur a zero ne doit plus masquer la date.
    $out .= " | first seen: $first_seen" . $_ago->($first_seen) if $first_seen;
    $out .= " | last msg: $last_msg" . $_ago->($last_msg)       if $msg_count > 0;

    # MB75-S1: when a user asks for their own stats, USER_SEEN may already
    # have been updated by the current command, so it is misleading and always
    # reads as "0h ago". Keep it for stats about another nick.
    my $show_seen = (lc($target // '') ne lc($nick // '')) ? 1 : 0;
    $out .= " | last seen: $seen_at ($seen_type)" . $_ago->($seen_at)
        if $show_seen && $seen_at ne 'never';

    $out .= $karma_str if $karma_str;
    $out .= " | not in database" unless $id_user || $msg_count || $first_seen;

    # CC17: add global rank on channel
    if ($msg_count > 0 && $total > 0) {
        # mb576-B1: les comptes par nick des deux tables sont fusionnes
        # AVANT le seuil — un nick a cheval vif/archive compte sa somme.
        # Chaque requete par table est un index scan groupe, sans HAVING.
        my %rank_counts;
        my $stats_rank_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
            "SELECT cl2.nick AS nick, COUNT(*) AS cnt"
          . " FROM __CLSRC__ cl2 JOIN CHANNEL c2 ON c2.id_channel=cl2.id_channel"
          . " WHERE c2.name=? AND cl2.event_type IN ('public','action')"
          . " GROUP BY cl2.nick",
            # mb577-B1: cle lc — la collation SQL est insensible a la casse,
            # les tables peuvent rendre SlaY et slay pour la meme identite.
            [ $channel ], sub { $rank_counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0 },
            'content');
        # mb578-B1: sans live_ok, un rang calcule sur une fusion vide
        # afficherait #1 — panne LIVE = echec franc.
        unless ($stats_rank_g->{live_ok}) {
            botNotice($self, $nick, "Database error.");
            return;
        }
        my $rank = 1 + scalar grep { $rank_counts{$_} > $msg_count } keys %rank_counts;
        $out .= " | rank: #" . $rank;
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
            $period_sql   = "AND cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
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
    # mb574-B1: carriere -> vif + archive.
    # mb576-B1: une requete par table, somme Perl.
    # mb578-B1: indispensable (les % de chaque ligne en dependent).
    my $total = 0;
    my $top_tot_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        "SELECT COUNT(*) AS total"
        . " FROM __CLSRC__ cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? AND cl.event_type IN ('public','action')"
        . " $bots_filter $period_sql",
        [ @bind_base ], sub { $total += $_[0]->{total} // 0 }, 'content');
    unless ($top_tot_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }

    # mb576-B1: GROUP BY complet par table + fusion par nick + tri/LIMIT
    # Perl (un LIMIT par branche fausserait le classement d'un nick a
    # cheval vif/archive).
    # mb577-B1: event_type explicite, cle lc (casse d'affichage memorisee a
    # la premiere rencontre, vif d'abord), scope content, succes via live_ok.
    my (%top_counts, %top_display);
    my $top_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        "SELECT cl.nick AS nick, COUNT(*) AS msg_count"
        . " FROM __CLSRC__ cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? AND cl.event_type IN ('public','action')"
        . " $bots_filter $period_sql"
        . " GROUP BY cl.nick",
        [ @bind_base ], sub {
            my $k = lc $_[0]->{nick};
            $top_display{$k} //= $_[0]->{nick};
            $top_counts{$k} += $_[0]->{msg_count} // 0;
        }, 'content');
    unless ($top_g->{live_ok}) {
        botNotice($self, $nick, "Database error.");
        return;
    }
    my @top_nicks = sort { $top_counts{$b} <=> $top_counts{$a} || $a cmp $b }
        keys %top_counts;
    splice(@top_nicks, $n) if @top_nicks > $n;
    my @rows = map { { nick => $top_display{$_}, msg_count => $top_counts{$_} } } @top_nicks;

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

    # V10 / mb576-B1: caller rank uses the exact same live+archive source.
    my $chan_ok = defined $channel && $channel =~ /^#/;
    if ($total > 0 && $chan_ok && $bots_mode != 1) {
        # mb578-B1: gather OPTIONNEL documente — la ligne bonus « your
        # rank » est simplement omise si ce comptage echoue ($mine reste 0,
        # le classement principal deja affiche n'est pas invalide). Teste.
        my $mine = 0;
        my $top_mine_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
            "SELECT COUNT(*) AS mine FROM __CLSRC__ cl"
          . " JOIN CHANNEL c ON c.id_channel=cl.id_channel"
          . " WHERE c.name=? AND cl.event_type IN ('public','action')"
          . " $bots_filter $period_sql AND LOWER(cl.nick)=LOWER(?)",
            [ $channel, @bot_list, lc($nick) ],
            sub { $mine += $_[0]->{mine} // 0 }, 'content');
        $mine = 0 unless $top_mine_g->{live_ok};
        if ($mine > 0) {
            # mb576-B1: la fusion complete par nick est deja en memoire
            # (%top_counts porte le meme filtre) — zero requete de plus.
            {
                my $my_rank = 1 + scalar grep { $top_counts{$_} > $mine }
                    keys %top_counts;
                if ($my_rank > $n) {
                    my $pct_me = $total > 0 ? sprintf('%.1f%%', 100*$mine/$total) : '0%';
                    botPrivmsg($self, $channel,
                        "  (your rank: #$my_rank — $mine msg(s), $pct_me)");
                }
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
    # mb563-B1: per-channel override via chansets +LangFR/+LangES
    # (Helpers::channel_lang); PM and unflagged channels keep main.LANG.
    # mb562-B1: FR/ES pools were double-encoded (accents shipped broken on
    # IRC); re-encoded once. Guard 753 forbids mojibake file-wide.
    my $lang_8b = Mediabot::Helpers::channel_lang($self, $channel);

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
        'C\'est absolument ça.',
        'Sans aucun doute.',
        'Oui, définitivement.',
        'Tu peux compter dessus.',
        'Comme je le vois, oui.',
        'Très probablement.',
        'Les perspectives sont bonnes.',
        'Oui.',
        'Les signes indiquent que oui.',
        'Flou, essaie encore.',
        'Demande plus tard.',
        'Mieux vaut ne pas te le dire maintenant.',
        'Je ne peux pas prédire ça.',
        'Concentre-toi et redemande.',
        'N\'y compte pas.',
        'Ma réponse est non.',
        'Mes sources disent non.',
        'Les perspectives ne sont pas bonnes.',
        'Très douteux.',
    );
    @answers = @answers_fr if $lang_8b eq 'fr';

    # L2: Spanish answers if main.LANG = es
    my @answers_es = (
        'Definitivamente sí.',
        'Por supuesto.',
        'Sin ninguna duda.',
        'Sí, definitivamente.',
        'Puedes contar con ello.',
        'Las perspectivas son buenas.',
        'Muy probablemente.',
        'Sí.',
        'Los indicios apuntan que sí.',
        'Como yo lo veo, sí.',
        'La respuesta es incierta, intenta de nuevo.',
        'Pregunta más tarde.',
        'Mejor no responderte ahora.',
        'No puedo predecirlo.',
        'Concéntrate y pregunta de nuevo.',
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

# mb677: reminders implementation moved to Mediabot::CommunityState.

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
            $period_sql   = "AND cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $period_label = " (today)";
        } elsif ($p eq 'yesterday') {
            $period_sql   = "AND cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
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
    # mb575-B1: carriere -> vif + archive (les PK sont preservees au
    # deplacement, l'ORDER BY id_channel_log reste globalement coherent).
    # mb576-B1: LIMIT par table (index scans), le comptage de mots agrege
    # les deux flux — l'ordre entre tables est indifferent pour un total,
    # et le plafond global est applique dans la boucle de lecture.
    # mb577-B1: en mode all, les textes sont STREAMES dans les compteurs
    # (jamais accumules — un canal Undernet en compterait des millions) ;
    # en mode plafonne, l'accumulation reste bornee a 2 x ROW_LIMIT avant
    # le splice qui garde les plus recents. Succes via live_ok.
    my %words;
    my $rows_read = 0;
    my @wc_texts;
    my $wc_count_text = sub {
        my ($text) = @_;
        $rows_read++;
        # mb426-B1: la connexion DBI ne décode pas l'UTF-8 (pas de mariadb_utf8,
        # seulement SET NAMES) -> publictext arrive en OCTETS UTF-8. Un split
        # sur \W+ coupait sur chaque octet d'accent (café -> caf, réponse ->
        # r+ponse), faussant le comptage sur un canal francophone. On splitte
        # de façon byte-safe : les octets >= 0x80 (continuation/amorce des
        # séquences UTF-8 multi-octets) comptent comme des lettres, donc les
        # mots accentués restent entiers.
        $words{lc $_}++ for split /[^0-9A-Za-z_\x80-\xFF]+/, ($text // '');
    };
    my $wc_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT publictext FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ? AND event_type IN ('public','action')
        $period_sql
        ORDER BY cl.id_channel_log DESC
        $limit_clause
    }, [ $target, $channel ], $no_limit
        ? sub { $wc_count_text->($_[0]->{publictext}) }
        : sub { push @wc_texts, $_[0]->{publictext} },
    'content');
    unless ($wc_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    unless ($no_limit) {
        splice(@wc_texts, $ROW_LIMIT) if @wc_texts > $ROW_LIMIT;
        $wc_count_text->($_) for @wc_texts;
    }
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
        # mb576-B1: comptes par nick fusionnes AVANT le seuil (meme patron
        # que le rank de stats) — un nick a cheval compte sa somme.
        my %wc_rank_counts;
        my $wc_rank_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
            SELECT cl2.nick AS nick, COUNT(*) AS cnt
            FROM __CLSRC__ cl2
            JOIN CHANNEL c2 ON c2.id_channel = cl2.id_channel
            WHERE c2.name = ?
              AND cl2.nick != ?
              AND cl2.event_type IN ('public','action')
            GROUP BY cl2.nick
        }, [ $channel, $target ], sub {
            $wc_rank_counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0;
        }, 'content');
        # mb578-B1: suffixe OPTIONNEL documente — sans live_ok, pas de
        # « activity rank » (un rang sur l'archive seule serait faux) ;
        # le comptage principal deja calcule reste affiche. Teste.
        if ($wc_rank_g->{live_ok} && %wc_rank_counts) {
            my $rank_pos = 1 + scalar grep { $wc_rank_counts{$_} > $rows_read }
                keys %wc_rank_counts;
            $rank_str = "  | activity rank: #" . $rank_pos;
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

    # mb574-B1: le streak est une carriere -> vif + archive.
    # mb576-B1: LIMIT par table (chaque branche sert son index), puis
    # dedup + tri + tronque en Perl — jamais d'ORDER/LIMIT sur une derivee.
    # mb577-B1: event_type explicite (le streak mesure des jours de PAROLE,
    # pas des join/quit), scope content, succes via live_ok (vide = valide).
    my %seen_days;
    my $streak_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT DISTINCT DATE(ts) AS day
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action')
        ORDER BY day DESC
        LIMIT 365
    }, [ $target, $channel ], sub {
        $seen_days{ $_[0]->{day} } = 1 if defined $_[0]->{day};
    }, 'content');
    unless ($streak_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
    }
    my @days = sort { $b cmp $a } keys %seen_days;
    splice(@days, 365) if @days > 365;

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

    # mb655: checking one's own streak also records the already-computed best
    # run in the persistent Achievement registry.  Looking up somebody else's
    # streak stays read-only: a third party must never create/touch that person's
    # durable Achievement profile merely by inspecting it.
    if ($self->{achievements} && lc($target) eq lc($nick)) {
        eval { $self->{achievements}->check_streak($nick, $channel, $streak, $best) };
        if ($@) {
            eval { $self->{logger}->log(1, "achievements check_streak error: $@") };
        }
    }

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
                      -- mb627-B1: plage indexable. DATE(ts) >= D equivaut a
                      -- ts >= D (DATE() tronque vers le bas), mais la fonction
                      -- autour de la colonne interdisait l'index (id_channel, ts).
                      AND cl.ts >= CURDATE() - INTERVAL 365 DAY
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

    # mb575-B1: le vrai « last » d'un nick parti depuis longtemps vit dans
    # l'archive — union vif + annexe.
    # mb576-B1: le cas d'ecole de l'analyse — ORDER/LIMIT ne se poussent
    # pas dans une derivee UNION : chaque table repond ses $limit dernieres
    # lignes via SON index, la fusion triee garde les plus recentes.
    # mb577-B1: succes via live_ok — un nick inconnu (zero ligne) recoit la
    # reponse fonctionnelle, plus jamais « Database error ».
    my @rows;
    my $last_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT cl.publictext, cl.ts,
               TIMESTAMPDIFF(MINUTE, cl.ts, NOW()) AS minutes_ago
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action') AND cl.publictext != ''
        ORDER BY cl.ts DESC
        LIMIT $limit
    }, [ $target, $channel ], sub { push @rows, $_[0] }, 'content');
    unless ($last_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    @rows = sort { ($b->{ts} // '') cmp ($a->{ts} // '') } @rows;
    splice(@rows, $limit) if @rows > $limit;

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

# mb677: polls implementation moved to Mediabot::CommunityState.

# mb677: notes implementation moved to Mediabot::CommunityState.


# ---------------------------------------------------------------------------
# mbKarmaReset_ctx --- !karmareset <nick>  (V3)
# Reset a nick's karma to 0. Requires Admin level.
# ---------------------------------------------------------------------------



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
            $date_filter     = "cl.ts >= CURDATE() AND cl.ts < CURDATE() + INTERVAL 1 DAY";  # mb577-B1: plage indexable
            $use_date_filter = 1;
            $label           = 'today';
        } elsif ($p eq 'yesterday') {
            $date_filter     = "cl.ts >= CURDATE() - INTERVAL 1 DAY AND cl.ts < CURDATE()";  # mb577-B1: plage indexable
            $use_date_filter = 1;
            $label           = 'yesterday';
        } elsif ($p eq 'week') {
            $date_filter     = "cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $use_date_filter = 1;
            $label           = 'this week';
        } elsif ($p eq 'month') {
            # mb627-B1: mb577 avait converti today/yesterday en plages mais
            # OUBLIE le mois courant, juste au-dessous. Meme mois, meme
            # resultat, index utilisable.
            $date_filter     = "cl.ts >= DATE_FORMAT(CURDATE(), '%Y-%m-01')"
                             . " AND cl.ts < DATE_FORMAT(CURDATE(), '%Y-%m-01') + INTERVAL 1 MONTH";
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
    # mb576-B1: first appearance and total span live + archive.
    # mb576-B1: MIN/COUNT par table, fusion Perl (min lexical, somme).
    # mb578-B1: « when » = PREMIERE APPARITION (revue pre-commit) — la
    # sur-application mb577 du filtre public/action l'avait transformee en
    # « premier message » : un nick ayant rejoint sans parler etait declare
    # absent, et l'archive de presence (qui contient precisement les vieux
    # JOIN) n'etait plus consultee. Deux gathers aux scopes distincts :
    #   1) premiere apparition : TOUT event_type, scope 'all' ;
    #   2) compteur de messages : public/action, scope 'content'.
    my $row = { first_seen => undef, total_msgs => 0 };
    my $when_first_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT MIN(cl.ts) AS first_seen FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
    }, [ $target, $channel ], sub {
        my ($r) = @_;
        $row->{first_seen} = $r->{first_seen}
            if defined $r->{first_seen}
            && (!defined $row->{first_seen} || $r->{first_seen} lt $row->{first_seen});
    }, 'all');
    unless ($when_first_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
    my $when_msgs_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, q{
        SELECT COUNT(*) AS total_msgs FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE cl.nick = ? AND c.name = ?
          AND cl.event_type IN ('public','action')
    }, [ $target, $channel ], sub {
        $row->{total_msgs} += $_[0]->{total_msgs} // 0;
    }, 'content');
    unless ($when_msgs_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }

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
        # mb578-B1: un nick apparu sans jamais parler affiche « 0 msg(s) »
        # au lieu de masquer l'information.
        my $msgs_str = ", $tot_msgs msg(s)";
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

    # mb576-B1: une requete par table, comptes additionnes en Perl.
    # mb577-B1: event_type explicite, cle lc (t1/t2 sont deja lc — la
    # collation SQL peut rendre une autre casse), scope content, live_ok.
    my %counts;
    my $cmp_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh}, qq{
        SELECT cl.nick AS nick, COUNT(*) AS cnt
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?,?)
          AND cl.event_type IN ('public','action')
        $period_sql
        GROUP BY cl.nick
    }, [ $channel, $t1, $t2 ], sub {
        $counts{ lc $_[0]->{nick} } += $_[0]->{cnt} // 0;
    }, 'content');
    unless ($cmp_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
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
    # mb576-B1: GROUP BY horaire par table, buckets additionnes en Perl.
    # mb577-B1: event_type explicite (activite = paroles), scope content,
    # succes via live_ok (heatmap vide = reponse fonctionnelle).
    my @hours = (0) x 24;
    my $hm_g = Mediabot::Helpers::channel_log_gather($self, $self->{dbh},
        'SELECT HOUR(cl.ts) AS h, COUNT(*) AS cnt'
        . ' FROM __CLSRC__ cl'
        . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
        . ' WHERE cl.nick = ? AND c.name = ?'
        . " AND cl.event_type IN ('public','action')"
        . ' GROUP BY HOUR(cl.ts) ORDER BY h',
        [ $target, $channel ], sub {
            $hours[ $_[0]->{h} ] += $_[0]->{cnt} // 0;
        }, 'content');
    unless ($hm_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.'); return;
    }
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
    require JSON::PP;

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

    my $clean_trace_value = sub {
        my ($value, $limit) = @_;
        $limit ||= 120;
        return '' unless defined($value) && !ref($value);
        $value =~ s/[\r\n\0]+/ /g;
        $value =~ s/\s{2,}/ /g;
        $value =~ s/^\s+|\s+$//g;
        return substr($value, 0, $limit);
    };

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    my $fallback = {
        ok    => 0,
        error => 'fetch',
        stage => 'async_fallback',
    };

    # Compatibility path for lightweight tests or emergency callers without a
    # usable event loop. Normal runtime uses the shared forked AsyncWorker.
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

    # MB653: AsyncWorker now owns pipe/fork, watch_process, bounded transport,
    # timeout TERM/KILL escalation and callback-once semantics. Trivia retains
    # only its fetch protocol, stage diagnostics and IRC-specific error shape.
    my $worker_started = Time::HiRes::time();
    my $last_stage = 'worker_started';
    my $adapter_done = 0;
    my $worker;

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

    my $progress = sub {
        my ($event, $worker_handle) = @_;
        return unless ref($event) eq 'HASH';

        my $stage = $clean_trace_value->($event->{stage}, 64);
        return unless $stage =~ /\A[a-z_]+\z/;
        $last_stage = $stage;

        my $pid = eval { $worker_handle->pid };
        $pid = eval { $worker->pid } unless defined $pid;
        $pid = '-' unless defined $pid;

        my @trace = (
            'progress',
            'label=' . ($debug_label ne '' ? $debug_label : '-'),
            "pid=$pid",
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
    };

    my $done = sub {
        my ($shared) = @_;
        return if $adapter_done;
        $adapter_done = 1;

        my $elapsed = int(
            (Time::HiRes::time() - $worker_started) * 1000 + 0.5
        );

        my $pid = ref($shared) eq 'HASH' ? $shared->{pid} : undef;
        $pid = eval { $worker->pid } unless defined $pid;
        $pid = '-' unless defined $pid;

        my $result;
        if (ref($shared) eq 'HASH' && $shared->{ok}) {
            if (ref($shared->{value}) eq 'HASH') {
                $result = { %{ $shared->{value} } };
            }
            else {
                $result = {
                    ok     => 0,
                    error  => 'worker_decode',
                    stage  => 'missing_result',
                    detail => 'worker returned no trivia result hash',
                };
            }
        }
        else {
            my $error = ref($shared) eq 'HASH'
                && defined($shared->{error})
                && !ref($shared->{error})
                    ? $shared->{error}
                    : 'worker_failed';
            my $stage = ref($shared) eq 'HASH'
                && defined($shared->{stage})
                && !ref($shared->{stage})
                    ? $shared->{stage}
                    : 'process_exit';
            my $detail = ref($shared) eq 'HASH'
                && defined($shared->{detail})
                && !ref($shared->{detail})
                    ? $shared->{detail}
                    : undef;

            if ($error eq 'worker_timeout') {
                $stage = 'async_timeout';
            }
            elsif ($error eq 'worker_signal' || $error eq 'worker_exit') {
                $error = 'worker_failed';
                $stage = 'process_exit';
            }
            elsif ($error eq 'worker_output_limit') {
                $error = 'worker_payload';
                $stage = 'payload_limit';
            }
            elsif ($error eq 'worker_empty') {
                $error = 'worker_decode';
                $stage = 'missing_result';
            }

            $result = {
                ok    => 0,
                error => $error,
                stage => $stage,
            };
            $result->{detail} = substr($detail, 0, 240)
                if defined($detail) && length($detail);
        }

        if (ref($shared) eq 'HASH') {
            $result->{worker_exit} = defined($shared->{exit})
                ? int($shared->{exit}) : 0;
            $result->{worker_signal} = defined($shared->{signal})
                ? int($shared->{signal}) : 0;
            $result->{worker_output_bytes} = int($shared->{bytes} // 0);
            $result->{worker_elapsed_ms} = int(
                1000 * ($shared->{elapsed_s} // 0) + 0.5
            );
            $result->{forced_completion} = $shared->{forced} ? 1 : 0;
        }
        else {
            $result->{worker_exit} = 0;
            $result->{worker_signal} = 0;
            $result->{worker_output_bytes} = 0;
            $result->{worker_elapsed_ms} = $elapsed;
            $result->{forced_completion} = 0;
        }

        $result->{last_stage} = $last_stage
            unless exists $result->{last_stage};

        my @trace = (
            'complete',
            'label=' . ($debug_label ne '' ? $debug_label : '-'),
            "pid=$pid",
            'result=' . ($result->{ok} ? 'ok' : ($result->{error} // 'unknown')),
            'stage=' . ($result->{stage} // '-'),
            'last_stage=' . ($result->{last_stage} // '-'),
            'elapsed_ms=' . ($result->{worker_elapsed_ms} // $elapsed),
            'output_bytes=' . ($result->{worker_output_bytes} // 0),
            'exit=' . ($result->{worker_exit} // 0),
            'signal=' . ($result->{worker_signal} // 0),
            'forced=' . ($result->{forced_completion} ? 1 : 0),
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
    };

    my $launch_ok = eval {
        $worker = Mediabot::AsyncWorker->start(
            loop        => $loop,
            label       => 'trivia fetch',
            timeout     => $timeout,
            term_grace  => 0.5,
            force_grace => 1.5,
            max_output  => 64 * 1024,
            on_progress => $progress,
            child       => sub {
                my ($emit_progress) = @_;

                my $result = eval {
                    _trivia_fetch_sync(
                        $category_id,
                        $difficulty,
                        progress_cb => sub {
                            my ($event) = @_;
                            return unless ref($event) eq 'HASH';
                            return unless ref($emit_progress) eq 'CODE';

                            # Preserve MB396's per-record 20 KiB safety bound
                            # before handing the event to the shared transport.
                            my $probe = eval { JSON::PP::encode_json($event) };
                            return if !defined($probe) || ref($probe);
                            return if length($probe) > 20 * 1024;
                            $emit_progress->($event);
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

                # Preserve the old 20 KiB bound for the terminal Trivia result.
                my $probe = eval { JSON::PP::encode_json($result) };
                if (!defined($probe) || ref($probe)) {
                    $result = {
                        ok     => 0,
                        error  => 'worker_encode',
                        stage  => 'json_encode',
                        detail => 'could not encode final worker record',
                    };
                }
                elsif (length($probe) > 20 * 1024) {
                    $result = {
                        ok            => 0,
                        error         => 'worker_payload',
                        stage         => 'payload_limit',
                        payload_bytes => length($probe),
                    };
                }

                return $result;
            },
            on_done => $done,
        );
        1;
    };

    # AsyncWorker normally reports setup failures through on_done. Keep a final
    # adapter guard so a launcher exception can never make Trivia silently hang.
    if (!$launch_ok && !$adapter_done) {
        my $error = $@ || 'unknown AsyncWorker launch failure';
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => $error,
        });
    }
    elsif (!$worker && !$adapter_done) {
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => 'AsyncWorker refused launch without a completion result',
        });
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
        # mb610-B1: $score est le score de la PARTIE en cours. Un palier
        # « 100 bonnes reponses » exigeait donc 100 reponses dans une seule
        # session — inatteignable. Le hook recoit desormais le total
        # cumule persistant ; l'affichage du jeu, lui, ne bouge pas.
        my $total = _ach_progress($self, 'trivia_correct', $nick, $channel) // $score;
        eval {
            $self->{achievements}->check_trivia($nick, $channel, $total, $response_time);
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
# mb612-B1: barre de progression compacte, sûre pour IRC (12 cases, pas de
# caractere large qui casse l'alignement selon le client).
sub _ach_bar {
    my ($pct) = @_;
    $pct = 0   unless defined $pct && $pct =~ /\A\d+\z/;
    $pct = 100 if $pct > 100;
    my $filled = int(($pct * 12) / 100);
    return "\x02[\x02" . ('=' x $filled) . ('.' x (12 - $filled)) . "\x02]\x02";
}

# Nombres lisibles : 137, 1.2k, 45k, 150k.
sub _ach_num {
    my ($n) = @_;
    return 0 unless defined $n;
    return $n if $n < 1000;
    return sprintf('%.1fk', $n / 1000) =~ s/\.0k\z/k/r if $n < 100_000;
    return int($n / 1000) . 'k';
}

# Une ligne d'objectif : emoji, nom colore par rarete, valeurs, pourcentage.
sub _ach_goal_line {
    my ($ach, $defs, $g) = @_;
    my $a   = $defs->{ $g->{id} } or return '';
    my $col = $ach->rarity_color($a->{rarity});
    my $rst = $col ? "\x0f" : '';
    return sprintf('%s %s%s%s %s/%s (%d%%)',
        $a->{emoji}, $col, $a->{name}, $rst,
        _ach_num($g->{current}), _ach_num($g->{threshold}), $g->{pct});
}

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
            next if $defs->{$id}{hidden};   # mb658: secrets reveal themselves only on unlock
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
        my $visible_total = scalar grep { !$defs->{$_}{hidden} } keys %$defs;
        botPrivmsg($self, $nick,
            "Total: $visible_total visible achievements available. "
          . "🔒 Secret achievements are revealed only when unlocked.");
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

    # mb612-B1: !achievements progress [nick] → la grille MESURABLE, du plus
    # proche au plus lointain. Repond en notice (c'est une vue detaillee),
    # sauf si l'appelant demande explicitement le canal.
    if (@args && lc($args[0]) =~ /\A(?:progress|prog)\z/) {
        shift @args;
        my $who = @args ? lc(shift @args) : lc($nick);
        unless ($channel && $channel =~ /^#/) {
            botNotice($self, $nick, 'Syntax: !achievements progress [nick]  (in a channel)');
            return 1;
        }
        my $snap = $ach->progress_snapshot($who, $channel);
        # mb658: locked secrets must not leak through names, conditions,
        # thresholds, percentages or even a progress-bar row. Once unlocked,
        # they become ordinary visible achievements.
        my @visible = grep { !$snap->{$_}{hidden} || $snap->{$_}{unlocked} }
                      keys %$snap;
        my @locked = grep {
            !$snap->{$_}{unlocked}
            && !$snap->{$_}{hidden}
            && $snap->{$_}{measurable}
        } keys %$snap;
        my $done = grep { $snap->{$_}{unlocked} } @visible;
        unless (@locked) {
            botNotice($self, $nick,
                "$who has unlocked every visible measurable achievement on $channel. Nothing left to chase.");
            return 1;
        }
        my @sorted = sort {
            ($snap->{$b}{pct} <=> $snap->{$a}{pct})
            || ($snap->{$a}{threshold} <=> $snap->{$b}{threshold})
            || ($a cmp $b)
        } @locked;
        # Emoji litteral, comme partout ailleurs dans ce fichier : un
        # \x{...} rend la chaine « wide » et l'accent du tiret cadratin
        # ressortait alors en mojibake sur le canal.
        botNotice($self, $nick, sprintf('📊 %s on %s — %d/%d visible unlocked, %d in progress:',
            "\x02$who\x02", $channel, $done, scalar(@visible), scalar @sorted));
        my $shown = 0;
        for my $id (@sorted) {
            last if $shown >= 12;   # une notice par ligne : on borne le flood
            my $g = { id => $id, %{ $snap->{$id} } };
            botNotice($self, $nick,
                '  ' . _ach_bar($g->{pct}) . ' ' . _ach_goal_line($ach, $defs, $g));
            $shown++;
        }
        botNotice($self, $nick, sprintf('  ... and %d more (never started).',
            scalar(@sorted) - $shown)) if @sorted > $shown;
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
        # mb612-B1: « rien de debloque » est justement le moment ou montrer
        # ce qui est a portee — sinon la commande ne dit rien d'utile.
        if (!$cross && $channel =~ /^#/) {
            my $goals = eval { $ach->next_goals($target, $channel, 3) } || [];
            my @lines = grep { length } map { _ach_goal_line($ach, $defs, $_) } @$goals;
            botPrivmsg($self, $reply_to, '  Closest: ' . join('  |  ', @lines)) if @lines;
        }
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
    my $visible_total = scalar grep {
        !$defs->{$_}{hidden} || exists $unlocked->{$_}
    } keys %$defs;
    botPrivmsg($self, $reply_to,
        "🏆 \x02$target\x02 — " . scalar(@sorted_ids) . " / " . $visible_total
        . " visible achievements$scope_str:");

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

    # mb612-B1: et la suite ? Les 3 objectifs verrouilles les plus proches,
    # sur une seule ligne. Vue cross-canal exclue : la progression se compte
    # par canal, l'afficher a cote d'un total cross-canal serait trompeur.
    if (!$cross && $channel =~ /^#/) {
        my $goals = eval { $ach->next_goals($target, $channel, 3) } || [];
        my @lines = grep { length } map { _ach_goal_line($ach, $defs, $_) } @$goals;
        if (@lines) {
            botPrivmsg($self, $reply_to, '  Next: ' . join('  |  ', @lines));
            botPrivmsg($self, $reply_to,
                "  (\x02!achievements progress\x02 for the full ladder)");
        }
    }
    return 1;
}

# ---------------------------------------------------------------------------
# mbProfil_ctx --- !profil [nick]
# Fiche d'identité complète d'un nick sur le canal courant.
# ---------------------------------------------------------------------------
# mb665: compact contribution counters from existing community tables.
# Keep this outside mbProfil_ctx so the profile's historical/SQL contract stays
# easy to audit: no additional CHANNEL_LOG gather and one isolated, fail-soft
# read for QUOTES + FACTOID only.
# mb670-B: implementation moved to Mediabot::SocialHistory (_profile_community_footprint).
# mb670-B: implementation moved to Mediabot::SocialHistory (mbProfil_ctx).
# Helper : formate les grands nombres (1234 → 1.2k, 12345 → 12k)
# mb629-B1: poids RÉEL d'une ligne sur le fil IRC. Ce fichier declare
# « use utf8 » : ses chaines sont des CARACTERES, or la limite IRC est en
# OCTETS. Un emoji pese 4 octets pour une seule case de largeur — compter
# avec length() surestimerait la place disponible d'un cote et la
# sous-estimerait de l'autre, et une ligne tronquee par le serveur couperait
# une sequence de couleur en deux.
sub _irc_bytes {
    my ($text) = @_;
    return 0 unless defined $text;
    # Le drapeau utf8 ne suffit PAS : un caractere < 256 (« point median »,
    # « e accent ») peut etre stocke sans drapeau et pese pourtant 2 octets
    # une fois encode. On mesure donc des qu'il y a du non-ASCII.
    return length($text) unless $text =~ /[^\x00-\x7F]/;
    return length(Encode::encode('UTF-8', $text));
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
# mb670-B: implementation moved to Mediabot::SocialHistory (mbDashboard_ctx).
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
        # mb610-B1: victoires cumulees persistantes (la table memoire
        # servait de compteur et repartait a zero a chaque redemarrage).
        my $wins = _ach_progress($self, 'duel_win', $winner, $channel)
                // ($self->{_duel_stats}{$channel}{$winner}{wins} // 0);
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
# mb561-B1: (jour, mois) -> (nom, glyphe, element) du signe, bornes standard.
# Retourne () si la date est invalide. Testable unitairement (test 752).
# mb620-B1: passerelles entre le tableau canonique FR (historique, verrouille
# par le test 752) et les slugs anglais que veut l'API. Deux fonctions plutot
# qu'une table de plus : la source de verite reste _horoscope_zodiac_sign.
our %HOROSCOPE_SLUG_OF = (
    'Verseau' => 'aquarius', 'Poissons' => 'pisces', 'Bélier' => 'aries',
    'Taureau' => 'taurus', 'Gémeaux' => 'gemini', 'Cancer' => 'cancer',
    'Lion' => 'leo', 'Vierge' => 'virgo', 'Balance' => 'libra',
    'Scorpion' => 'scorpio', 'Sagittaire' => 'sagittarius',
    'Capricorne' => 'capricorn',
);

sub _horoscope_slug_from_sign {
    my ($fr_name) = @_;
    return undef unless defined $fr_name;
    return $HOROSCOPE_SLUG_OF{$fr_name};
}

# Rend [ nom_fr, glyphe, element ] pour un slug anglais, en RELISANT le
# tableau canonique : si une date de bascule change un jour, rien a resynchroniser.
sub _horoscope_sign_from_slug {
    my ($slug) = @_;
    return undef unless defined $slug;
    my %date_of = (
        aquarius => [ 20, 1 ], pisces => [ 19, 2 ], aries => [ 21, 3 ],
        taurus   => [ 20, 4 ], gemini => [ 21, 5 ], cancer => [ 21, 6 ],
        leo      => [ 23, 7 ], virgo  => [ 23, 8 ], libra  => [ 23, 9 ],
        scorpio  => [ 23, 10 ], sagittarius => [ 22, 11 ], capricorn => [ 22, 12 ],
    );
    my $d = $date_of{$slug} or return undef;
    my @sign = _horoscope_zodiac_sign(@$d);
    return @sign ? \@sign : undef;
}

sub _horoscope_zodiac_sign {
    my ($d, $m) = @_;
    return () unless defined $d && defined $m;
    return () unless $d =~ /^\d+$/ && $m =~ /^\d+$/;
    return () unless $d >= 1 && $d <= 31 && $m >= 1 && $m <= 12;
    return () unless _birthday_valid_date(2000, $m, $d);
    # Trié par date de début CROISSANTE : on garde le DERNIER signe dont la
    # date de début est <= (mois,jour) demandé. Capricorne (début 22/12) est
    # le défaut : il couvre aussi le début d'année (01/01 - 19/01), avant le
    # premier début de la liste (Verseau 20/01).
    my @zodiac = (
        [ 'Verseau',    "♒", 'air',    1, 20 ],
        [ 'Poissons',   "♓", 'eau',    2, 19 ],
        [ 'Bélier',     "♈", 'feu',    3, 21 ],
        [ 'Taureau',    "♉", 'terre',  4, 20 ],
        [ 'Gémeaux',    "♊", 'air',    5, 21 ],
        [ 'Cancer',     "♋", 'eau',    6, 21 ],
        [ 'Lion',       "♌", 'feu',    7, 23 ],
        [ 'Vierge',     "♍", 'terre',  8, 23 ],
        [ 'Balance',    "♎", 'air',    9, 23 ],
        [ 'Scorpion',   "♏", 'eau',   10, 23 ],
        [ 'Sagittaire', "♐", 'feu',   11, 22 ],
        [ 'Capricorne', "♑", 'terre', 12, 22 ],
    );
    my $md = $m * 100 + $d;
    my $found = [ 'Capricorne', "♑", 'terre' ];   # 01/01 - 19/01
    for my $z (@zodiac) {
        my $z_md = $z->[3] * 100 + $z->[4];
        $found = $z if $md >= $z_md;
    }
    return @$found[0, 1, 2];
}

# mb565-R1: USER.birthday is stored by the birthday command as MM-DD or
# YYYY-MM-DD. Accept those canonical DB formats and legacy dd/mm variants,
# validate the real calendar date, then delegate the zodiac boundaries to the
# tested helper above.
sub _horoscope_zodiac_from_birthday {
    my ($birthday) = @_;
    return () unless defined $birthday && !ref($birthday);

    my $raw = "$birthday";
    $raw =~ s/^\s+|\s+$//g;
    return () unless length $raw;

    my ($year, $month, $day) = (2000, undef, undef);
    if ($raw =~ /\A(\d{4})-(\d{2})-(\d{2})\z/) {
        ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);
    }
    elsif ($raw =~ /\A(\d{2})-(\d{2})\z/) {
        ($month, $day) = ($1 + 0, $2 + 0);
    }
    elsif ($raw =~ m{\A(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\z}) {
        ($day, $month) = ($1 + 0, $2 + 0);
        $year = $3 + 0 if defined $3;
    }
    else {
        return ();
    }

    return () unless _birthday_valid_date($year, $month, $day);
    return _horoscope_zodiac_sign($day, $month);
}

sub mbHoroscope_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb620-B1: l'argument est SOIT un signe (dans n'importe laquelle des
    # trois langues, accentue ou non, glyphe ou abrege), SOIT un pseudo. On
    # teste le signe d'abord : « m horoscope lion » doit donner le Lion, pas
    # l'horoscope d'un utilisateur hypothetique nomme lion. Les trois cas
    # demandes sont ainsi couverts : signe donne, pseudo donne, rien donne.
    my $forced_sign;
    if (@args) {
        my $joined = join ' ', @args;
        $forced_sign = Mediabot::External::Horoscope::normalize_sign($joined)
                    || Mediabot::External::Horoscope::normalize_sign($args[0]);
    }
    my $target = (!$forced_sign && @args) ? lc($args[0]) : lc($nick);

    my $reply_to = ($channel && $channel =~ /^#/) ? $channel : $nick;

    # mb118-IMP2: gate par chanset +Games sur canal public (PM toujours autorisé)
    if ($channel && $channel =~ /^#/) {
        unless (Mediabot::Helpers::chanset_enabled($self, $channel, 'Games', default => 1)) {
            botNotice($self, $nick, "Games are disabled on $channel (chanset -Games)");
            return;
        }
    }

    # mb561-B1 + mb565-R1: signe astrologique depuis USER.birthday, avec
    # les formats réellement stockés par la commande birthday (MM-DD ou
    # YYYY-MM-DD) et compatibilité legacy dd/mm[/YYYY]. Même clé d'accès :
    # USER.nickname = cible. Best-effort : sans base, sans user ou sans date
    # valide -> horoscope complet quand même, simplement sans signe.
    my ($sign_name, $sign_glyph, $sign_element);
    {
        my $bday;
        eval {
            my $sth_b = $self->{dbh}->prepare(
                "SELECT birthday FROM USER WHERE nickname = ?");
            if ($sth_b && $sth_b->execute($target)) {
                my $row_b = $sth_b->fetchrow_hashref;
                $bday = $row_b->{birthday} if $row_b;
                $sth_b->finish;
            }
            1;
        };
        if (defined $bday) {
            ($sign_name, $sign_glyph, $sign_element) =
                _horoscope_zodiac_from_birthday($bday);
        }
    }

    # mb620-B1: un signe donne a la main gagne sur la date de naissance
    # stockee — c'est le cas « on me donne le signe ».
    my $api_slug;
    if ($forced_sign) {
        $api_slug = $forced_sign;
        my ($fr_name) = _horoscope_sign_from_slug($forced_sign);
        if (defined $fr_name) {
            ($sign_name, $sign_glyph, $sign_element) = @{ $fr_name };
        }
    }
    elsif (defined $sign_name) {
        $api_slug = _horoscope_slug_from_sign($sign_name);
    }

    # Seed déterministe : nick + date du jour
    my @lt = localtime(time);
    my $date_key = sprintf('%04d-%02d-%02d', $lt[5]+1900, $lt[4]+1, $lt[3]);
    my $seed = 0;
    # mb620-B1: quand un signe est demande explicitement, il entre dans la
    # graine — sinon « !horoscope lion » et « !horoscope vierge » rendraient
    # la meme saveur au meme utilisateur le meme jour. Sans signe force, la
    # graine est identique a l'historique (contrat mb444/test 659 intact).
    my $seed_src = $target . ':' . $date_key
                 . (defined $forced_sign ? ':' . $forced_sign : '');
    $seed = ($seed * 31 + ord($_)) & 0xFFFFFFFF for split //, $seed_src;

    # mb444-B1: PRNG LOCAL déterministe — le RNG global (dés, duels, 8ball,
    # trivia, Hailo) n'est JAMAIS touché. Contrat verrouillé par le test 659.
    my $rng  = $seed & 0x7FFFFFFF;
    my $next = sub { $rng = (($rng * 1103515245) + 12345) & 0x7FFFFFFF; return $rng; };
    my $pick = sub { my ($aref) = @_; return $aref->[ $next->() % scalar(@$aref) ]; };

    # mb572-B1: la langue du canal choisit les pools (Helpers::channel_lang,
    # mb563) — 'fr' garde les textes historiques, tout le reste (en, es tant
    # qu'aucun pool ES n'existe) recoit la version anglaise. CHAQUE pool EN a
    # EXACTEMENT la meme taille que son jumeau FR : un meme tirage LCG tombe
    # sur la meme "carte" dans les deux langues, et le contrat mb444 (ordre
    # des tirages, LCG local) est strictement inchange.
    my $horo_lang = Mediabot::Helpers::channel_lang($self, $channel);
    my $horo_fr = ($horo_lang eq 'fr') ? 1 : 0;

    # mb561-B1: pools entierement generiques — aucune personne, aucun projet,
    # aucun evenement interne. Teinte legerement IRC/tech assumee (c'est un
    # bot), mais rien de nominatif.
    my @humeurs = (
        "lumineuse 🌞", "mystérieuse 🌕", "espiègle 😈",
        "philosophe 🤔", "conquérante ⚔️", "rêveuse ☁️",
        "indomptable 🦁", "fluide 🌊", "électrique ⚡",
        "feutrée 🐾", "sereine 🧘", "magnétique 🧲",
    );

    # Accroches par élément (utilisées seulement si le signe est connu)
    my %elans = (
        feu   => [ "ton énergie ouvre les portes avant que tu frappes",
                   "l'étincelle du jour t'appartient, ne la prête pas",
                   "ce qui résiste aujourd'hui cédera par enthousiasme" ],
        terre => [ "ta constance vaut mieux que trois coups d'éclat",
                   "bâtis petit mais bâtis vrai, le reste suivra",
                   "un pas mesuré t'emmènera plus loin qu'un sprint" ],
        air   => [ "une conversation légère portera une idée sérieuse",
                   "ta curiosité est le bon outil, laisse-la ouvrir les onglets",
                   "les mots justes te viendront au moment exact" ],
        eau   => [ "ton intuition lit entre les lignes, fais-lui confiance",
                   "la marée du jour ramène quelque chose que tu croyais perdu",
                   "écoute deux fois, réponds une fois : magie garantie" ],
    );

    my @climats_social = (
        "Une attention discrète te fera plus de bien qu'un long discours",
        "Quelqu'un pense à toi sans te le dire",
        "Un échange anodin cachera une vraie complicité",
        "On te lira plus attentivement que tu ne le crois",
        "Un ancien contact refera surface au bon moment",
        "Ta bonne humeur sera contagieuse, dose-la avec malice",
        "Un silence bien placé vaudra une réponse brillante",
    );

    my @climats_projets = (
        "une tâche repoussée se révélera plus courte que prévu",
        "la solution viendra en expliquant le problème à voix haute",
        "un détail négligé mérite une seconde lecture",
        "ce que tu ranges aujourd'hui te sauvera demain",
        "une idée notée à la va-vite contient l'essentiel",
        "termine avant d'améliorer : l'ordre compte",
        "la version simple est la bonne",
    );

    my @evenements = (
        "Un café partagé deviendra mémorable.",
        "Quelqu'un te citera de travers : souris, ne corrige pas.",
        "Une question d'hier trouvera sa réponse toute seule.",
        "Une notification ignorée ce matin reviendra ce soir.",
        "Un air de musique te suivra toute la journée.",
        "Une coïncidence te fera lever un sourcil.",
        "Un objet perdu réapparaîtra à l'endroit évident.",
        "Une fenêtre oubliée contient encore une réponse précieuse.",
        "Un message tapé trop vite t'apprendra la patience.",
        "Une promesse faite à la légère te rattrapera gentiment.",
    );

    my @recommandations = (
        "ne refuse pas le café qu'on te tend",
        "lis le mode d'emploi d'un outil que tu crois maîtriser",
        "réponds à un message que tu avais laissé filer",
        "range une seule chose, mais range-la vraiment",
        "note l'idée avant qu'elle ne s'évapore",
        "fais une sauvegarde, tu sais pourquoi",
        "prends l'escalier, les astres y voient plus clair",
        "offre un compliment sans raison",
        "éteins un écran une heure avant de dormir",
        "goûte quelque chose de nouveau, même en pensée",
    );

    my @attentions = (
        "une promesse faite trop vite",
        "un détail qui grossit dans l'ombre",
        "une certitude qui mériterait vérification",
        "un raccourci qui coûtera plus qu'il ne rapporte",
        "une réponse envoyée sous le coup de l'agacement",
        "un oubli minuscule aux grandes conséquences",
        "une rumeur plus rapide que les faits",
        "un « ça peut attendre » de trop",
    );

    my @couleurs = qw(turquoise carmin indigo or pourpre ardoise émeraude saphir cuivre ivoire);
    my @chiffres = (3, 7, 11, 13, 17, 21, 23, 42, 47, 77, 100, 666);
    my @glyphs   = ("✨", "🌟", "🌙", "🔥", "☄️",
                    "🌌", "🔮", "⚡", "🌀");
    my @autres_signes = ('Bélier', 'Taureau', 'Gémeaux', 'Cancer', 'Lion', 'Vierge',
                         'Balance', 'Scorpion', 'Sagittaire', 'Capricorne', 'Verseau', 'Poissons');


    # mb572-B1: jumeaux anglais (tailles identiques aux pools FR).
    my @moods_en = (
        "radiant 🌞", "mysterious 🌕", "mischievous 😈",
        "philosophical 🤔", "conquering ⚔️", "dreamy ☁️",
        "untamable 🦁", "fluid 🌊", "electric ⚡",
        "hushed 🐾", "serene 🧘", "magnetic 🧲",
    );
    my %elans_en = (
        feu   => [ "your energy opens doors before you knock",
                   "today's spark is yours, don't lend it out",
                   "what resists today will yield to enthusiasm" ],
        terre => [ "your steadiness beats three flashy moves",
                   "build small but build true, the rest will follow",
                   "one measured step will carry you further than a sprint" ],
        air   => [ "a light conversation will carry a serious idea",
                   "your curiosity is the right tool, let it open the tabs",
                   "the right words will come at the exact moment" ],
        eau   => [ "your intuition reads between the lines, trust it",
                   "today's tide brings back something you thought lost",
                   "listen twice, answer once: guaranteed magic" ],
    );
    my @social_en = (
        "A quiet gesture will do you more good than a long speech",
        "Someone is thinking of you without saying it",
        "A casual exchange will hide a real bond",
        "You will be read more carefully than you think",
        "An old contact will resurface at the right time",
        "Your good mood will be contagious, dose it with mischief",
        "A well-placed silence will be worth a brilliant reply",
    );
    my @projets_en = (
        "a postponed task will turn out shorter than expected",
        "the answer will come while explaining the problem out loud",
        "an overlooked detail deserves a second read",
        "what you tidy today will save you tomorrow",
        "an idea scribbled in haste holds the essential",
        "finish before improving: order matters",
        "the simple version is the right one",
    );
    my @events_en = (
        "A shared coffee will become memorable.",
        "Someone will misquote you: smile, don't correct.",
        "Yesterday's question will answer itself.",
        "A notification ignored this morning will return tonight.",
        "A tune will follow you all day long.",
        "A coincidence will raise one of your eyebrows.",
        "A lost object will reappear in the obvious place.",
        "A forgotten window still holds a precious answer.",
        "A message typed too fast will teach you patience.",
        "A promise made lightly will gently catch up with you.",
    );
    my @recos_en = (
        "don't refuse the coffee you're offered",
        "read the manual of a tool you think you master",
        "answer a message you had let slip",
        "tidy one single thing, but tidy it truly",
        "write the idea down before it evaporates",
        "make a backup, you know why",
        "take the stairs, the stars see clearer there",
        "give a compliment for no reason",
        "turn off a screen one hour before sleep",
        "taste something new, even in thought",
    );
    my @attentions_en = (
        "a promise made too fast",
        "a detail growing in the shadows",
        "a certainty that deserves a check",
        "a shortcut that will cost more than it saves",
        "a reply sent in irritation",
        "a tiny oversight with big consequences",
        "a rumor faster than the facts",
        "one 'it can wait' too many",
    );
    my @colours_en = qw(turquoise crimson indigo gold purple slate emerald sapphire copper ivory);
    my %sign_en = (
        'Bélier' => 'Aries', 'Taureau' => 'Taurus', 'Gémeaux' => 'Gemini',
        'Cancer' => 'Cancer', 'Lion' => 'Leo', 'Vierge' => 'Virgo',
        'Balance' => 'Libra', 'Scorpion' => 'Scorpio', 'Sagittaire' => 'Sagittarius',
        'Capricorne' => 'Capricorn', 'Verseau' => 'Aquarius', 'Poissons' => 'Pisces',
    );
    my %element_en = (feu => 'fire', terre => 'earth', air => 'air', eau => 'water');

    # Selection par langue (les tailles jumelles garantissent la parite LCG).
    unless ($horo_fr) {
        @humeurs         = @moods_en;
        %elans           = %elans_en;
        @climats_social  = @social_en;
        @climats_projets = @projets_en;
        @evenements      = @events_en;
        @recommandations = @recos_en;
        @attentions      = @attentions_en;
        @couleurs        = @colours_en;
        @autres_signes   = map { $sign_en{$_} } @autres_signes;
    }

    # Tirages (LCG local, mb444-B1) — ordre FIXE pour la stabilité du jour
    my $humeur    = $pick->(\@humeurs);
    my $social    = $pick->(\@climats_social);
    my $projets   = $pick->(\@climats_projets);
    my $event     = $pick->(\@evenements);
    my $reco      = $pick->(\@recommandations);
    my $attention = $pick->(\@attentions);
    my $couleur   = $pick->(\@couleurs);
    my $chiffre   = $pick->(\@chiffres);
    my $glyph     = $pick->(\@glyphs);
    my $chance    = 35 + ($next->() % 60);  # 35..94, biais positif léger

    # Affichage — meme gabarit avec ou sans signe (mb561-B1)
    # mb572-B1: le nom/element du signe se traduit A L'AFFICHAGE seulement —
    # _horoscope_zodiac_sign reste canonique FR (test 752 intact), la cle
    # d'element des elans reste FR des deux cotes.
    my ($disp_sign, $disp_element) = ($sign_name, $sign_element);
    if (defined $sign_name && !$horo_fr) {
        $disp_sign    = $sign_en{$sign_name}       // $sign_name;
        $disp_element = $element_en{$sign_element} // $sign_element;
    }

    # mb620-B1: la prevision REELLE du jour pour ce signe. Best-effort de bout
    # en bout : API muette, lente ou changee, traduction indisponible -> undef,
    # et l'horoscope local s'affiche seul, exactement comme avant. L'utilisateur
    # ne voit jamais un message d'echec pour un horoscope.
    my $api_line;
    if (defined $api_slug) {
        $api_line = eval {
            Mediabot::External::Horoscope::daily_line(
                $self, $api_slug, ($horo_fr ? 'fr' : $horo_lang), $nick);
        };
    }

    if (defined $sign_name) {
        my $elan = $pick->($elans{$sign_element});
        my @complices = grep { $_ ne $disp_sign } @autres_signes;
        my $complice = $pick->(\@complices);
        if ($horo_fr) {
            botPrivmsg($self, $reply_to,
                "$glyph \x02Horoscope du $date_key\x02 — $target, $sign_glyph \x02$disp_sign\x02 ($disp_element) · humeur $humeur");
            botPrivmsg($self, $reply_to,
                "  🔮 $elan.");
            botPrivmsg($self, $reply_to, "  ✨ $api_line") if defined $api_line;
            botPrivmsg($self, $reply_to,
                "  Climat : $social. Côté projets : $projets. $event");
            botPrivmsg($self, $reply_to,
                sprintf("  Conseil : %s. Méfiance : %s.", $reco, $attention));
            botPrivmsg($self, $reply_to,
                sprintf("  🎲 Chiffre %d · 🎨 couleur %s · 🍀 chance %d%% · 💫 signe complice : %s",
                    $chiffre, $couleur, $chance, $complice));
        }
        else {
            botPrivmsg($self, $reply_to,
                "$glyph \x02Horoscope for $date_key\x02 — $target, $sign_glyph \x02$disp_sign\x02 ($disp_element) · mood: $humeur");
            botPrivmsg($self, $reply_to,
                "  🔮 $elan.");
            botPrivmsg($self, $reply_to, "  ✨ $api_line") if defined $api_line;
            botPrivmsg($self, $reply_to,
                "  Vibe: $social. On the work front: $projets. $event");
            botPrivmsg($self, $reply_to,
                sprintf("  Advice: %s. Beware of: %s.", $reco, $attention));
            botPrivmsg($self, $reply_to,
                sprintf("  🎲 Number %d · 🎨 colour %s · 🍀 luck %d%% · 💫 kindred sign: %s",
                    $chiffre, $couleur, $chance, $complice));
        }
    }
    else {
        if ($horo_fr) {
            botPrivmsg($self, $reply_to,
                "$glyph \x02Horoscope du $date_key pour $target\x02 — humeur $humeur");
            botPrivmsg($self, $reply_to,
                "  Climat : $social. Côté projets : $projets. $event");
            botPrivmsg($self, $reply_to,
                sprintf("  Conseil : %s. Méfiance : %s.", $reco, $attention));
            botPrivmsg($self, $reply_to,
                sprintf("  🎲 Chiffre %d · 🎨 couleur %s · 🍀 chance %d%% · 💡 %s",
                    $chiffre, $couleur, $chance,
                    "signe inconnu : essaie \x02!horoscope lion\x02 ou \x02!birthday set\x02"));
        }
        else {
            botPrivmsg($self, $reply_to,
                "$glyph \x02Horoscope for $date_key — $target\x02 — mood: $humeur");
            botPrivmsg($self, $reply_to,
                "  Vibe: $social. On the work front: $projets. $event");
            botPrivmsg($self, $reply_to,
                sprintf("  Advice: %s. Beware of: %s.", $reco, $attention));
            botPrivmsg($self, $reply_to,
                sprintf("  🎲 Number %d · 🎨 colour %s · 🍀 luck %d%% · 💡 %s",
                    $chiffre, $couleur, $chance,
                    "sign unknown: try \x02!horoscope leo\x02 or \x02!birthday set\x02"));
        }
    }

    # mb610-B1: le compteur passe au registre PERSISTANT des achievements
    # (le compteur memoire reste pour les instances sans systeme
    # d'achievements, et pour ne rien changer au reste du code).
    $self->{_horoscope_count}{$nick}++;
    if ($self->{achievements} && $channel =~ /^#/) {
        my $count = _ach_progress($self, 'horoscope', $nick, $channel)
                 // ($self->{_horoscope_count}{$nick} // 0);
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
    # mb576-B1: GROUP BY par table, les buckets s'additionnent en Perl.
    my %hours = ($n1 => [(0)x24], $n2 => [(0)x24]);
    my %total_msgs = ($n1 => 0, $n2 => 0);
    my $compat_h_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
        SELECT cl.nick AS nick, HOUR(cl.ts) AS h, COUNT(*) AS c
        FROM __CLSRC__ cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.nick IN (?, ?)
          AND cl.event_type IN ('public','action')
        GROUP BY cl.nick, HOUR(cl.ts)
    }, [ $channel, $n1, $n2 ], sub {
        my $r = $_[0];
        my $who = lc($r->{nick});
        return unless exists $hours{$who};
        # += : les buckets des deux tables s'additionnent (fusion mb576).
        $hours{$who}[$r->{h}] += $r->{c};
        $total_msgs{$who} += $r->{c};
    }, 'content');
    # mb578-B1: panne LIVE = echec franc — sans quoi compat pretendrait
    # qu'un nick n'a aucune activite.
    unless ($compat_h_g->{live_ok}) {
        botNotice($self, $nick, 'Database error.');
        return;
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
        # mb576-B1: LIMIT par table puis fusion triee — l'echantillon reste
        # « les 5000 plus recents » tous volumes confondus.
        my @w_rows;
        my $compat_w_g = Mediabot::Helpers::channel_log_gather($self, $dbh, q{
            SELECT cl.publictext, cl.ts
            FROM __CLSRC__ cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ? AND cl.nick = ?
              AND cl.event_type IN ('public','action')
            ORDER BY cl.ts DESC
            LIMIT 5000
        }, [ $channel, $who ], sub { push @w_rows, $_[0] }, 'content');
        # mb578-B1: le score jaccard serait faux sur un vocabulaire ampute.
        unless ($compat_w_g->{live_ok}) {
            botNotice($self, $nick, 'Database error.');
            return;
        }
        @w_rows = sort { ($b->{ts} // '') cmp ($a->{ts} // '') } @w_rows;
        splice(@w_rows, 5000) if @w_rows > 5000;
        my %w_counts;
        for my $wr (@w_rows) {
            my $txt = lc($wr->{publictext} // '');
            # mb427-B1: tokenisation byte-safe (comme mb426). publictext est
            # en OCTETS UTF-8 (DBI ne décode pas) ; l'ancien
            # s/[^\w\s\x{00C0}-\x{017F}]/ /g gardait même un octet parasite
            # (café -> "caf\xC3"). Les octets >= 0x80 comptent comme lettres.
            for my $w (split /[^0-9A-Za-z_\x80-\xFF]+/, $txt) {
                next unless length($w) >= 4;
                $w_counts{$w}++;
            }
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

    # Hook achievement (mb610-B1: progression persistante)
    $self->{_compat_count}{$nick}++;
    if ($self->{achievements}) {
        my $cnt = _ach_progress($self, 'compat', $nick, $channel)
               // ($self->{_compat_count}{$nick} // 0);
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

        # Hook achievement (mb610-B1: total cumule, pas le score de la partie)
        if ($self->{achievements}) {
            my $qg_total = _ach_progress($self, 'quotegame_solved', $sNick, $sChannel)
                        // $score;
            eval { $self->{achievements}->check_quotegame($sNick, $sChannel, $qg_total) };
        }
        $self->{metrics}->inc('mediabot_quotegame_correct_total') if $self->{metrics};
    }
}

# ---------------------------------------------------------------------------
# mbMood_ctx --- !mood
# Détection d'humeur du canal sur la dernière heure.
# Patterns FR + EN.
# ---------------------------------------------------------------------------
# mb670-B: implementation moved to Mediabot::SocialHistory (mbMood_ctx).
# =============================================================================
# mb118: Leaderboard / Chronos
# =============================================================================

# ---------------------------------------------------------------------------
# mbLeaderboard_ctx --- !leaderboard [msgs|karma|trivia|duels|achievs]
# Classement consolidé multi-métriques du canal courant.
# Par défaut : affiche le top 3 dans chaque catégorie.
# ---------------------------------------------------------------------------

# mb670-B: implementation moved to Mediabot::SocialHistory (mbLeaderboard_ctx).
# ---------------------------------------------------------------------------
# mbAwards_ctx --- !awards [7d|30d]
# mb666: compact cross-feature channel awards. This is deliberately NOT a
# second leaderboard: each category names one role from a bounded recent
# window. Heavy reads run under CommandAsync from the public dispatcher.
# ---------------------------------------------------------------------------





# ---------------------------------------------------------------------------
# mbYearbook_ctx --- !yearbook [YYYY]
# mb667: one bounded annual portrait of the current channel. Historical data
# is merged through channel_log_gather(), so a year split between live and the
# archive is counted exactly once per source. No random scan, no persistence.
# ---------------------------------------------------------------------------






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
# mb670-B: implementation moved to Mediabot::SocialHistory (mbChronos_ctx).
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
        "  \x{1F4AC} social memory: profil/radar/dashboard/leaderboard/awards/yearbook/chronos/mood/memory available",
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
# mb609-B1: texte de service localise, avec repli sur la formulation
# historique anglaise si le module Claude n'est pas charge.
# mb670-B: implementation moved to Mediabot::SocialHistory (_recap_text).
# mb624-B1: LA syntaxe de recap, ecrite UNE fois — l'aide et les messages
# d'erreur la lisent au meme endroit (meme discipline que 'ai summary', mb623).
our @RECAP_USAGE_LINES = (
    'Syntaxe: recap [fenetre] [ai] [en|fr|es]   (l\'ordre est libre)',
    'Fenetre: <N>m (minutes) ou <N>h (heures), ex. 30m, 2h. Defaut: la fenetre du canal.',
    'Options: ai = resume par l\'IA au lieu des statistiques | en|fr|es ou lang=fr = langue du resume.',
    'Exemples: recap | recap 2h | recap 2h ai | recap ai fr | recap 45m ai lang=en',
);
our @RECAP_KEYWORDS = qw(ai);

# mb624-B1: lecture STRICTE des arguments de recap. Meme maladie que celle
# corrigee dans 'ai summary' : ici, tout jeton non reconnu etait IGNORE EN
# SILENCE — « recap 2h ia » (faute de frappe sur 'ai') rendait les
# statistiques au lieu du resume, sans un mot, et « recap 30min » retombait
# sur la fenetre par defaut sans le dire. Un utilisateur ne peut pas deviner
# qu'il s'est trompe si le bot repond quelque chose de plausible.
# mb670-B: implementation moved to Mediabot::SocialHistory (_recap_parse).
# mb610-B1: increment du registre de progression persistant des
# achievements, avec repli silencieux si le systeme n'est pas la (rend
# undef, l'appelant garde alors sa valeur historique).
# mb670-B: implementation moved to Mediabot::SocialHistory (_ach_progress).
# mb670-B: implementation moved to Mediabot::SocialHistory (mbRecap_ctx).
# mb677: factoids implementation moved to Mediabot::CommunityState.

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
# mb670-B: implementation moved to Mediabot::SocialHistory (mbOnThisDay_ctx).
# ---------------------------------------------------------------------------
# _onthisday_lines($id_channel, $channel_label) -> @lines
# mb496: the pure computation behind !onthisday, factored out so both the
# command and the daily digest tick share ONE implementation. Read-only.
# Returns an empty list when there is no past activity on this calendar day.
# ---------------------------------------------------------------------------
# mb670-B: implementation moved to Mediabot::SocialHistory (_onthisday_lines).
# ===========================================================================
# mbMemory_ctx --- !memory
# mb664: take the user somewhere in the channel's history rather than looking
# at one fixed calendar date. The expensive/history work runs through
# CommandAsync at dispatch level; this command body stays read-only and reuses
# the existing +OnThisDay opt-out contract.
# ===========================================================================

# ===========================================================================
# _memory_lines($self, $id_channel, $channel_label, %opts) -> @lines
# mb664 step 1: bounded random channel-memory selector.
#
# This deliberately reuses channel_log_gather() as the live/archive source of
# truth. Selection is an indexed timestamp seek; all follow-up work is limited
# to one concrete day. No ORDER BY RAND(), no schema change, read-only only.
# ===========================================================================


# ===========================================================================
# mbMilestone_ctx --- !milestone
# mb502: channel milestones — total public messages logged, the next round
# milestone, progress toward it, and an ETA based on the recent daily rate.
# A celebratory, engagement-oriented read of how far the channel has come.
# Read-only against CHANNEL_LOG (uses the composite (id_channel, ts) index).
# ===========================================================================
# mb670-B: implementation moved to Mediabot::SocialHistory (mbMilestone_ctx).
# next round milestone above $n (adaptive step)
# mb670-B: implementation moved to Mediabot::SocialHistory (_milestone_next).
# last round milestone already reached at or below $n (same adaptive steps).
# Returns 0 when the channel hasn't reached its first step yet.
# mb670-B: implementation moved to Mediabot::SocialHistory (_milestone_last).
# 1234567 -> "1,234,567"
# mb670-B: implementation moved to Mediabot::SocialHistory (_group_int).
# a day count -> friendly "3 years", "5 months", "12 days"
# mb670-B: implementation moved to Mediabot::SocialHistory (_humanize_days).
1;
