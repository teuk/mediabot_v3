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

# Engagement views have their own owners; historical commands/helpers stay here.
use Mediabot::Users::AchievementView qw(
    mbAchievements_ctx
    _ach_bar
    _ach_num
    _ach_goal_line
);
use Mediabot::Users::Horoscope qw(
    mbHoroscope_ctx
    _horoscope_slug_from_sign
    _horoscope_sign_from_slug
    _horoscope_zodiac_sign
    _horoscope_zodiac_from_birthday
    %HOROSCOPE_SLUG_OF
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
    userTopSay_ctx
);

use Mediabot::Stats::Affinity qw(mbCompat_ctx);
use Mediabot::Stats::Radar qw(mbRadar_ctx);
use Mediabot::Diagnostics::Commands qw(
    mbFeatures_ctx
    _mbFeatures_chanset_state
    mbObservatory_ctx
    _mbObservatory_uptime
    _mbObservatory_energy_label
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

# Achievement presentation: Mediabot::Users::AchievementView (imported above).

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


# Channel activity radar: Mediabot::Stats::Radar (imported above).

# =============================================================================
# mb116: Dashboard / Duel / Horoscope
# =============================================================================

# ---------------------------------------------------------------------------
# mbDashboard_ctx --- !dashboard / !chanstats
# Tableau de bord complet du canal courant : activité, top contributeurs,
# top mots, sparkline 7 jours, karma vortex, ambiance globale.
# ---------------------------------------------------------------------------
# mb670-B: implementation moved to Mediabot::SocialHistory (mbDashboard_ctx).

# Horoscope command and zodiac helpers: Mediabot::Users::Horoscope (imported above).

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
# Channel capability/state views: Mediabot::Diagnostics::Commands (imported above).

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
