package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use Mediabot::IRC::TextBudget qw(_utf8_text_bytes);
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use POSIX qw(strftime);
use Time::Local qw(timegm timelocal);
use Time::Piece;
use Time::HiRes ();
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
# MB888: keep legacy synchronous symbols while remote source code has its own owner.
use Mediabot::External::Wiktionary qw(_define_pick_entry _define_lookup_sync);
use Mediabot::External::OpenTriviaDB qw(_trivia_parse_api_content _trivia_fetch_sync);
# Account-level readers and profile views keep their historical facade names.
use Mediabot::Users::Levels qw(
    getIdUserLevel
    getLevelUser
    getUserLevelDesc
    getUserChannelLevel
);
use Mediabot::Users::Profiles qw(
    userStats_ctx
    userInfo_ctx
    userGreet_ctx
);

# User-facing calendar and presence commands have dedicated source owners.
use Mediabot::Users::Birthdays qw(
    userBirthday_ctx
    _birthday_add_ctx
    _birthday_del_ctx
    _birthday_valid_date
    _birthday_mmdd_from_value
    _birthday_days_ahead
    _birthday_next_ctx
);
use Mediabot::Users::Seen qw(mbSeen_ctx);

# Game implementations have dedicated owners; legacy command and helper names
# stay available here for dispatch, plugins and existing callers.
use Mediabot::Games::Trivia qw(
    _trivia_fetch_async
    mbTrivia_ctx
    checkTriviaAnswer
    mbTriviaTop_ctx
    mbTriviaReset_ctx
    mbTriviaStop_ctx
    mbTriviaScore_ctx
);
use Mediabot::Games::QuoteGame qw(
    _quotegame_cancel_timer
    _quotegame_start_timer
    mbQuotegame_ctx
    checkQuotegameAnswer
);

use Mediabot::Games::Chance qw(
    mb8ball_ctx
    mbSlap_ctx
    mbRoll_ctx
    mbFlip_ctx
    mbChoose_ctx
);
use Mediabot::Games::Duel qw(
    mbDuel_ctx
);

# Channel statistics have dedicated owners; imported legacy names keep the
# registry, bot methods and existing integrations stable.
use Mediabot::Stats::Activity qw(
    mbStats_ctx
    mbTop_ctx
    mbActive_ctx
    mbWhen_ctx
    mbCompare_ctx
    mbHeatmap_ctx
    mbMonthStats_ctx
);
use Mediabot::Stats::History qw(
    mbWordCount_ctx
    mbStreak_ctx
    mbLast_ctx
);

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

    # A stored hostmask can resolve to a privileged user object even when the
    # caller is not authenticated.  Every moduser branch mutates account state,
    # so enforce both authentication and the documented Administrator level at
    # the command boundary before looking up a target or touching the database.
    $ctx->require_level('Administrator') or return;

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



# Delete a registered account and its channel relations after authorization.
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
    # MB928: DBI normally returns failure with RaiseError disabled. Check
    # every step, and roll back only a transaction started by this command.
    my $transaction_started = 0;
    my $ok = eval {
        $dbh->begin_work or die "begin_work failed: " . $dbh->errstr . "\n";
        $transaction_started = 1;
        $dbh->do("DELETE FROM USER_CHANNEL  WHERE id_user=?", undef, $id_user)
            or die "delete USER_CHANNEL failed: " . $dbh->errstr . "\n";
        $dbh->do("DELETE FROM USER_HOSTMASK WHERE id_user=?", undef, $id_user)
            or die "delete USER_HOSTMASK failed: " . $dbh->errstr . "\n";
        $dbh->do("DELETE FROM USER_SEEN     WHERE nick = ?",  undef, lc($target))
            or die "delete USER_SEEN failed: " . $dbh->errstr . "\n";
        $dbh->do("DELETE FROM USER          WHERE id_user=?", undef, $id_user)
            or die "delete USER failed: " . $dbh->errstr . "\n";
        $dbh->commit or die "commit failed: " . $dbh->errstr . "\n";
        1;
    };
    if (!$ok) {
        my $error = $@;
        eval { $dbh->rollback } if $transaction_started;
        $self->{logger}->log(0, "delUser_ctx: transaction failed for $target: $error");
 botNotice($self, $nick, "Database error -- user not deleted.");
        return;
    }

    my $msg = "User $target (id_user: $id_user) has been deleted";
    $self->{logger}->log(0, "delUser_ctx: $msg (by $nick)");
    botNotice($self, $nick, $msg);
    logBot($self, $message, undef, "deluser", $msg);
}







# mb677: reminders implementation moved to Mediabot::CommunityState.


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


# mb677: polls implementation moved to Mediabot::CommunityState.

# mb677: notes implementation moved to Mediabot::CommunityState.


# ---------------------------------------------------------------------------
# mbKarmaReset_ctx --- !karmareset <nick>  (V3)
# Reset a nick's karma to 0. Requires Admin level.
# ---------------------------------------------------------------------------







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
        # MB900: EOF must not close a Perl '-|' pipe before async reaping.
        close_on_read_eof => 0,
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


# Game implementation: Mediabot::Games::Trivia (imported above).

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
    return _utf8_text_bytes(@_);
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
# mbHoroscope_ctx --- !horoscope [nick]
# Horoscope IRC compact, FR/EN selon le canal. Seed = nick + date.
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

    # MB817: two bounded lines. Keep the historical local draws and their
    # order, so compacting the reply does not reshuffle daily lucky details.
    my $complice;
    if (defined $sign_name) {
        $pick->($elans{$sign_element});
        my @complices = grep { $_ ne $disp_sign } @autres_signes;
        $complice = $pick->(\@complices);
    }
    my $forecast = Mediabot::External::Horoscope::clean_text($api_line);
    $forecast //= Mediabot::External::Horoscope::local_forecast(
        $api_slug, $date_key, ($horo_fr ? 'fr' : 'en')) if defined $api_slug;
    my $lines = Mediabot::External::Horoscope::compact_lines(
        lang => ($horo_fr ? 'fr' : 'en'), target => $target, date => $date_key,
        sign => $disp_sign, glyph => $sign_glyph, forecast => $forecast,
        number => $chiffre, colour => $couleur, luck => $chance,
        companion => $complice);
    botPrivmsg($self, $reply_to, $_) for @$lines;

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

# Game implementation: Mediabot::Games::QuoteGame (imported above).

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
    my $gemini       = _mbFeatures_chanset_state($self, $channel, 'Gemini', default => 0);
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
        "  \x{1F916} integrations: Claude=$claude  Gemini=$gemini  RandomQuote=$randomquote  Radio=$radio",
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
    my $gemini       = _mbFeatures_chanset_state($self, $channel, 'Gemini', default => 0);
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
      . "  | Gemini $gemini"
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
