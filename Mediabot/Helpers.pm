package Mediabot::Helpers;

# =============================================================================
# Mediabot::Helpers — Shared utility functions
#
# This module exports all helper functions that are called as plain functions
# (not OO methods) from command modules (ChannelCommands, LoginCommands, etc.)
#
# Used by:
#   use Mediabot::Helpers;
# in every command module that needs these helpers.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use URI::Escape qw(uri_escape);
use JSON::MaybeXS;
use HTTP::Tiny;
use Try::Tiny;
use Socket;
use POSIX qw(strftime WNOHANG);
use Digest::SHA qw(sha1 sha1_hex);
use List::Util qw(min);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Async::Timer::Countdown;
use IO::Async::Stream;
use Encode qw(encode);

our @EXPORT = qw(
    botNotice
    botPrivmsg
    botAction
    clear_user_cache
    noticeConsoleChan
    logBot
    checkUserLevel
    checkUserChannelLevel
    getIdUser
    getIdUserChannelLevel
    getUserChannelLevelByName
    getUserhandle
    getMessageHostmask
    get_user_from_message
    joinChannel
    partChannel
    setChannelAntiFlood
    userAdd
    userCount
    getDetailedVersion
    getVersion
    getVersion_async
    make_password_hash
    checkAntiFlood
    checkNickFlood
    checkChanFlood
    checkCmdCooldown
    getIdChannelSet
    getIdChansetList
    evalAction
    mbWhereis_ctx
    displayBirthDate_ctx
    mbColors_ctx
    mbDbCheckNickHostname_ctx
    sethChannelsNicksOnChan
    gethChannelNicks
    updateUserSeen
    userAuthNick_ctx
    getWhoisVar
    gethChannelsNicksEndOnChan
    _bool_str
    mbDbCheckHostnameNick_ctx
    whoTalk_ctx
    make_colors_pretty
    displayDate_ctx
    mp3_ctx
    isIgnored
    sethChannelsNicksEndOnChan
    displayLeetString_ctx
    gethChannelsNicksOnChan
    mbEcho
    getRandomNick
    resolve_ctx
    _tz_exists
    userVerifyNick_ctx
    sethChannelNicks
    getLevel
    get_user_from_whois
    getNickInfoWhois
    channelNicksRemove
    whereis
    whereis_async
    getConsoleChan
    leet
    logBotAction
    versionCheck
);

# Get user object from message prefix (hostmask)
sub clear_user_cache {
    my ($self, $fullmask) = @_;
    if (defined $fullmask) {
        delete $self->{_user_cache}{$fullmask};
        delete $self->{_user_cache_ts}{$fullmask};
    } else {
        $self->{_user_cache}    = {};
        $self->{_user_cache_ts} = {};
    }
}

sub get_user_from_message {
    my ($self, $message) = @_;

    return unless $message;

    my $fullmask = $message->prefix // '';
    my ($nick)   = $fullmask =~ /^([^!]+)/;
    $nick ||= '';

    my ($host) = $fullmask =~ /@(.+)$/;
    $host = lc($host // '');

    $self->{logger}->log(3, "🔍 get_user_from_message() called with hostmask: '$fullmask'");

    # ── Hostmask cache — avoid GROUP_CONCAT query on every PRIVMSG ──────
    my $cache_key = $fullmask;
    my $now       = time;
    my $TTL       = 5;    # seconds

    if (   defined $self->{_user_cache}{$cache_key}
        && ($now - ($self->{_user_cache_ts}{$cache_key} // 0)) < $TTL)
    {
        $self->{logger}->log(3, "🔍 get_user_from_message() cache hit for '$fullmask'");
        return $self->{_user_cache}{$cache_key};
    }
    # ─────────────────────────────────────────────────────────────────────

    require Mediabot::Auth;
    require Mediabot::User;

    $self->{auth} ||= Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
    );

    my $sth = $self->{dbh}->prepare(q{
        SELECT
            u.id_user,
            u.nickname,
            u.username,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ',') AS hostmasks
        FROM USER u
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        GROUP BY
            u.id_user,
            u.nickname,
            u.username,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2
        ORDER BY u.id_user
    });

    unless ($sth && $sth->execute) {
        $self->{logger}->log(1, " get_user_from_message() SQL Error: $DBI::errstr");
        return;
    }

    my $best_row;
    my $best_reason = '';
    my $best_score  = -1;

    while (my $row = $sth->fetchrow_hashref) {
        my $matched = 0;
        my $reason  = '';
        my $score   = -1;

        my ($mask_ok, $matched_mask, undef, $mask_score) = $self->{auth}->hostmask_matches($row, $fullmask);
        if ($mask_ok) {
            $matched = 1;
            $reason  = "hostmask:$matched_mask";
            $score   = $mask_score;
        }
        else {
            my $db_nick = lc($row->{nickname} // '');

            if ($host =~ /(^|\.)users\.undernet\.org\z/i) {
                my ($leftmost) = split(/\./, $host, 2);
                if (defined $leftmost && $leftmost ne '' && $db_nick ne '' && lc($leftmost) eq $db_nick) {
                    $matched = 1;
                    $reason  = "undernet_cloak";
                    $score   = 0;
                }
            }
        }

        next unless $matched;

        if ($score > $best_score) {
            $best_row    = { %$row };
            $best_reason = $reason;
            $best_score  = $score;
        }
    }

    $sth->finish;

    unless ($best_row) {
        $self->{logger}->log(3, "🚫 No user matched hostmask '$fullmask'");
        return;
    }

    my $user = Mediabot::User->new({
        %$best_row,
        dbh => $self->{dbh},
    });
    $user->load_level($self->{dbh});

    $self->_dbg_auth_snapshot('pre-auto', $user, $nick, $fullmask);

    if ($user->can('maybe_autologin')) {
        $user->maybe_autologin($self, $nick, $fullmask);
    }

    $self->_dbg_auth_snapshot('post-auto', $user, $nick, $fullmask);

    $self->_ensure_logged_in_state($user, $nick, $fullmask);

    $self->_dbg_auth_snapshot('post-ensure', $user, $nick, $fullmask);

    # Store in cache
    $self->{_user_cache}{$cache_key}    = $user;
    $self->{_user_cache_ts}{$cache_key} = $now;

    $self->{logger}->log(
        3,
        "🎯 Matched user id="
          . ($user->can('id') ? $user->id : $user->{id_user})
          . ", nickname='"
          . $user->nickname
          . "', level='"
          . ($user->level_description // 'undef')
          . "', reason='"
          . $best_reason
          . "', score='"
          . $best_score
          . "'"
    );

    $self->_dbg_auth_snapshot('return', $user, $nick, $fullmask);

    return $user;
}


# Log info with timestamp
sub getUserhandle {
    my ($self, $id_user) = @_;

    # unvalid user => undef
    return unless defined $id_user && $id_user =~ /^\d+$/ && $id_user > 0;

    my $logger = $self->{logger};

    # 1) If user already loaded in memory
    if (my $users = $self->{users}) {

        # a) hash indexed by id_user
        if (exists $users->{$id_user}) {
            my $user = $users->{$id_user};
            my $handle = eval { $user->handle } // eval { $user->nickname };
            return $handle if defined $handle && $handle ne '';
        }

        # b) Old-style : browse all users
        foreach my $k (keys %$users) {
            my $user = $users->{$k} or next;
            my $uid  = eval { $user->id } // $user->{id_user};
            next unless defined $uid && $uid =~ /^\d+$/;
            next unless $uid == $id_user;

            my $handle = eval { $user->handle } // eval { $user->nickname };
            return $handle if defined $handle && $handle ne '';
        }
    }

    # 2) Fallback DB direct
    my $dbh = $self->{dbh} // eval { $self->{db}->dbh };
    return unless $dbh;

    my $row = eval {
        $dbh->selectrow_hashref(
            "SELECT nickname FROM USER WHERE id_user = ?",
            undef, $id_user
        );
    };
    if ($@) {
        $logger->log(1, "SQL Error in getUserhandle(): $@") if $logger;
        return;
    }
    return unless $row;

    my $nickname = $row->{nickname} // '';
    return $nickname ne '' ? $nickname : undef;
}

# Get user ID from nickname (userhandle)
sub getIdUser {
    my ($self, $sUserhandle) = @_;

    return undef unless defined($sUserhandle) && $sUserhandle ne '';

    my $sQuery = "SELECT id_user FROM USER WHERE nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getIdUser() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUserhandle)) {
        $self->{logger}->log(1, "getIdUser() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $id_user;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_user = $ref->{id_user};
    }

    $sth->finish;
    return $id_user;
}


# Get channel object by name
sub noticeConsoleChan {
    my ($self, $sMsg) = @_;

    $self->{logger}->log(4, "noticeConsoleChan() called with message: $sMsg");

    my ($id_channel, $name, $chanmode, $key) = getConsoleChan($self);

    $self->{logger}->log(4, "getConsoleChan() returned: id_channel=" . ($id_channel // 'undef') . ", name=" . 
        (defined $name ? $name : 'undef') . ", mode=" . 
        (defined $chanmode ? $chanmode : 'undef') . ", key=" . 
        (defined $key ? $key : 'undef'));

    if (defined $name && $name ne '') {
        $self->{logger}->log(4, "Sending notice to console channel: $name");
        botNotice($self, $name, $sMsg);
    } else {
        $self->{logger}->log(1, "No console channel defined! Run ./configure to set up the bot.");
    }
}


# Log a bot command to the ACTIONS_LOG table, optionally linked to a user and/or channel
sub logBot {
    my ($self, $message, $channel, $action, @args) = @_;

    return unless $self->{dbh};  # Abort if the database handle is not available

    # Try to retrieve the User object from the message
    my $user = $self->get_user_from_message($message);

    my $user_id   = $user ? $user->id       : undef;
    my $user_name = $user ? $user->nickname : 'Unknown user';
    my $hostmask  = $message->prefix        // 'unknown';

    # Retrieve the channel ID from the channel object if available
    my $channel_id;
    if (defined $channel && exists $self->{channels}{$channel}) {
        $channel_id = $self->{channels}{$channel}->get_id;
    }

    # Normalize the argument string (handle undefined values)
    my $args_string = @args ? join(' ', map { defined($_) ? $_ : '' } @args) : '';

    # Prepare the SQL query
    my $sql = "INSERT INTO ACTIONS_LOG (ts, id_user, id_channel, hostmask, action, args) VALUES (?, ?, ?, ?, ?, ?)";
    my $sth = $self->{dbh}->prepare($sql) or do {
        $self->{logger}->log(0, "logBot() SQL prepare failed: $DBI::errstr");
        return;
    };

    # Generate current timestamp in SQL format
    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime(time));

    # Execute the insert with bound parameters
    unless ($sth->execute($timestamp, $user_id, $channel_id, $hostmask, $action, $args_string)) {
        $self->{logger}->log(0, "logBot() SQL error: $DBI::errstr  Query: $sql");
        $sth->finish;
        return;
    }

    # Format and display a console log message
    my $log_msg = "($user_name : $hostmask) command $action";
    $log_msg .= " $args_string" if $args_string ne '';
    $log_msg .= " on $channel"  if defined $channel;

    $self->noticeConsoleChan($log_msg);
    $self->{logger}->log(4, "logBot() $log_msg");

    $sth->finish;
}



# Log bot action into the CHANNEL_LOG table
# Handles JOIN, PART, PUBLIC, ACTION, NOTICE, KICK, QUIT, etc.
# ---------------------------------------------------------------------------
# _redact_irc_service_secret_for_log
# mb133-B7: keep outbound private-message logs safe across PRIVMSG/ACTION/NOTICE.
# The original message must remain unchanged for the IRC wire; only log copies
# are redacted.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _is_irc_channel_target
# mb135-B9: IRC channels are not only "#channel". RFC-style channel prefixes
# include #, &, ! and +. Keep outbound helper classification consistent.
# ---------------------------------------------------------------------------
sub _is_irc_channel_target {
    my ($target) = @_;
    return defined($target) && $target =~ /^[#&!+]/ ? 1 : 0;
}


sub _redact_irc_service_secret_for_log {
    my ($msg) = @_;

    return $msg unless defined($msg) && $msg ne '';

    my $log_msg = $msg;

    if ($log_msg =~ /^(identify|id|login|register|auth|ghost|recover|release|set\s+password)\b/i) {
        my @parts = split /\s+/, $log_msg;
        my $verb = lc($parts[0] // '');

        if ($verb eq 'identify' || $verb eq 'id') {
            if (@parts >= 3) { $parts[-1] = '****'; }
            elsif (@parts >= 2) { $parts[1] = '****'; }
        }
        elsif ($verb eq 'login' || $verb eq 'auth'
            || $verb eq 'ghost' || $verb eq 'recover' || $verb eq 'release')
        {
            $parts[2] = '****' if @parts >= 3;
        }
        elsif ($verb eq 'set' && lc($parts[1] // '') eq 'password') {
            $parts[2] = '****' if @parts >= 3;
        }
        else {
            # register <pass> <email> : pass is arg #1, email is not secret
            $parts[1] = '****' if @parts >= 2;
        }

        $log_msg = join(' ', @parts);
    }

    return $log_msg;
}


# mb325-B1: découpage de message sûr en octets pour PRIVMSG/NOTICE.
#
# botPrivmsg() et botNotice() découpaient tous deux à 400 *caractères* puis
# encodaient chaque chunk en UTF-8 juste avant l'envoi. Le commentaire affirmait
# que découper avant l'encodage évitait de couper un caractère multi-octets en
# deux — vrai, mais 400 caractères ≠ 400 octets : du texte accentué (é/è/à =
# 2 octets) ou des emojis (4 octets) produisaient un chunk de 500 à 1600 octets,
# dépassant la limite IRC d'environ 512 octets. Le serveur tronquait alors la
# ligne — et coupait, lui, en plein milieu d'une séquence UTF-8, exactement le
# défaut qu'on prétendait éviter. La logique était de plus dupliquée dans les
# deux chemins jumeaux (classe de bug récurrente « fix d'un côté, oublié de
# l'autre »).
#
# Ce helper partagé découpe sur des frontières de caractères (donc jamais au
# milieu d'un multi-octets) tout en garantissant que chaque chunk, une fois
# transmis, tient dans le budget d'octets. Il respecte le flag utf8 du scalaire :
#   - chaîne de caractères (is_utf8 vrai)  -> coût = longueur UTF-8 du codepoint
#   - chaîne d'octets déjà encodée (faux)  -> coût = 1 octet par élément
# ce qui correspond exactement à ce que font do_PRIVMSG/do_NOTICE en aval
# (encode("UTF-8", ...) seulement si utf8::is_utf8). Pour de l'ASCII, le résultat
# est identique octet pour octet à l'ancien découpage (équivalence vérifiée).
sub _split_text_for_irc {
    my ($text, $max_bytes) = @_;

    return () unless defined($text) && $text ne '';

    $max_bytes = 400
        unless defined($max_bytes) && $max_bytes =~ /^\d+$/ && $max_bytes >= 16;

    # Sanitise newlines defensively (callers already do this; idempotent here).
    $text =~ s/[\r\n]+/ /g;

    my $is_chars = utf8::is_utf8($text);
    my $cost = $is_chars
        ? sub { my $o = ord($_[0]); $o < 0x80 ? 1 : $o < 0x800 ? 2 : $o < 0x10000 ? 3 : 4 }
        : sub { 1 };

    my $wire_bytes = sub {
        return utf8::is_utf8($_[0]) ? length(encode("UTF-8", $_[0])) : length($_[0]);
    };

    # Fast path: whole message already fits on the wire.
    return ($text) if $wire_bytes->($text) <= $max_bytes;

    my @chunks;
    my $buf = $text;

    while ($wire_bytes->($buf) > $max_bytes) {
        # Largest leading character count whose encoded form fits the budget.
        my $bytes = 0;
        my $n     = 0;
        for my $ch (split //, $buf) {
            my $cb = $cost->($ch);
            last if $bytes + $cb > $max_bytes;
            $bytes += $cb;
            $n++;
        }
        $n = 1 if $n < 1;    # always make progress, even if one char > budget

        my $prefix = substr($buf, 0, $n);

        # Prefer breaking at the last whitespace, but not before half the prefix,
        # mirroring the historical .{200,399}\s word-wrap behaviour.
        if ($prefix =~ /^(.*\s)\S+\z/s) {
            my $ws = $1;
            $prefix = $ws if length($ws) >= int($n / 2) && length($ws) >= 1;
        }

        my $cut = length($prefix);
        $cut = $n if $cut < 1;

        push @chunks, substr($buf, 0, $cut);
        $buf = substr($buf, $cut);
        $buf =~ s/^\s+//;
    }

    push @chunks, $buf if length($buf);
    return @chunks;
}

sub botPrivmsg {
    my ($self, $sTo, $sMsg) = @_;

    return unless defined($sTo);

    # Guard before any formatting/chanset/badword work. Some callers may fail
    # upstream and pass an empty payload; do not let that create noisy
    # uninitialized warnings in NoColors/badword/log paths.
    unless (defined($sMsg) && $sMsg ne '') {
        $self->{logger}->log(0, "botPrivmsg() ERROR no message specified to send to target");
        return;
    }

    my $eventtype = "public";

    if (_is_irc_channel_target($sTo)) {
        # Channel mode

        # NoColors chanset check
        my $id_chanset_list = getIdChansetList($self, "NoColors");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset NoColors, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(4, "botPrivmsg() channel $sTo has chanset +NoColors");
                $sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
            }
        }

        # AntiFlood chanset check
        $id_chanset_list = getIdChansetList($self, "AntiFlood");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(4, "botPrivmsg() channel $sTo has chanset +AntiFlood");
                return undef if checkAntiFlood($self, $sTo);  # Already refactored
            }
        }

        # Log output to console
        $self->{logger}->log(0, "[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");

        # Badword filtering — B1/A1: cache per channel (TTL 5 min)
        # Avoids one SQL query per outgoing message on busy channels.
        {
            my $now     = time();
            my $ttl     = 300;   # 5 minutes
            my $cache   = $self->{_badword_cache}{$sTo};

            if (!$cache || ($now - ($cache->{ts} // 0)) > $ttl) {
                my $sth = $self->{dbh}->prepare(
                    "SELECT badword FROM CHANNEL"
                    . " JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel"
                    . " WHERE CHANNEL.name = ?"
                );
                my @words;
                if ($sth && $sth->execute($sTo)) {
                    while (my $ref = $sth->fetchrow_hashref) {
                        push @words, lc($ref->{badword}) if defined $ref->{badword};
                    }
                    $sth->finish;
                } else {
                    $self->{logger}->log(1, "botPrivmsg() Badword SQL Error: $DBI::errstr");
                    $self->{metrics}->inc('mediabot_db_query_errors_total') if $self->{metrics};
                    $sth->finish if $sth; # mb135-B10: match botAction cleanup on execute errors
                }
                $self->{_badword_cache}{$sTo} = { ts => $now, words => \@words };
                $cache = $self->{_badword_cache}{$sTo};
            }

            my $msg_lc = lc($sMsg);
            for my $bw (@{ $cache->{words} // [] }) {
                if (index($msg_lc, $bw) != -1) {
                    logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo,
                        "$sMsg (BADWORD : $bw)");
                    noticeConsoleChan($self, "Badword : $bw blocked on channel $sTo ($sMsg)");
                    $self->{logger}->log(3, "Badword : $bw blocked on channel $sTo ($sMsg)");
                    return;
                }
            }
            logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, $sMsg);
        }
    } else {
        # Private message
        $eventtype = "private";
        # mb130-B2: redact password in log for NickServ-like service commands.
        # Avant ce fix, on_login() faisait botPrivmsg("NickServ", "identify
        # mypass") ou botPrivmsg("X", "login user pass") qui etait loggue
        # textuellement au niveau 0 (toujours actif) -> password Undernet/
        # Libera/etc. en clair dans le log file. Tout admin avec acces
        # lecture au log pouvait recuperer les credentials.
        my $log_msg = _redact_irc_service_secret_for_log($sMsg);
        $self->{logger}->log(0, "-> *$sTo* $log_msg");
        # A5: encoding, sanitisation and truncation applied uniformly below
    }

    # Send actual message — shared path for channel and private (A5)
    if (defined($sMsg) && $sMsg ne "") {
        # Sanitise first while the string is still a Perl character string.
        # IMP5/fix: split before UTF-8 encoding so substr() never cuts a
        # multi-byte character in half (accents, emojis, █/░ bars, etc.).
        $sMsg =~ s/[\r\n]+/ /g;

        # IRC hard limit is ~512 bytes. mb325-B1: split on a byte budget (not a
        # character count) so accented text and emojis can never push a chunk
        # past the wire limit; the encode happens per chunk below. 400 bytes
        # keeps the historical headroom for prefix/target overhead.
        my @chunks = _split_text_for_irc($sMsg, 400);
        @chunks = ($sMsg) unless @chunks;

        # AA14: log when message was split for debug
        if (scalar(@chunks) > 1) {
            $self->{logger}->log(4, 'botPrivmsg: split into '
                . scalar(@chunks) . ' chunks for ' . ($sTo // '?'));
        }
        for my $chunk (@chunks) {
            next unless defined($chunk) && $chunk ne '';
            $chunk = encode("UTF-8", $chunk) if utf8::is_utf8($chunk);
            $self->{metrics}->inc('mediabot_privmsg_out_total') if $self->{metrics};
            $self->{irc}->do_PRIVMSG(target => $sTo, text => $chunk);
        }
    } else {
        $self->{logger}->log(0, "botAction() ERROR no message specified to send to target");
    }
}



# Send a private message to a target (action)
sub botAction {
	my ($self,$sTo,$sMsg) = @_;
	if (defined($sTo)) {
		unless (defined($sMsg) && $sMsg ne "") {
			$self->{logger}->log(0,"botAction() ERROR no message specified to send to target");
			return;
		}
		my $eventtype = "public";
		if (_is_irc_channel_target($sTo)) {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(4,"botAction() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(4,"botAction() channel $sTo has chanset +AntiFlood");
						if (checkAntiFlood($self,$sTo)) {
							return undef;
						}
					}
				}
				$self->{logger}->log(0,"[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");

				# mb134-B8: keep botAction aligned with botPrivmsg for outgoing
				# badword checks. The old path queried BADWORDS on every ACTION
				# and did not finish the statement handle on the no-badword path.
				# Reuse the same short-lived per-channel cache used by botPrivmsg.
				{
					my $now     = time();
					my $ttl     = 300;
					my $cache   = $self->{_badword_cache}{$sTo};

					if (!$cache || ($now - ($cache->{ts} // 0)) > $ttl) {
						my $sQuery = "SELECT badword FROM CHANNEL JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						my @words;

						if ($sth && $sth->execute($sTo)) {
							while (my $ref = $sth->fetchrow_hashref()) {
								push @words, lc($ref->{badword}) if defined $ref->{badword};
							}
							$sth->finish;
						}
						else {
							$self->{logger}->log(1,"botAction() Badword SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							$self->{metrics}->inc('mediabot_db_query_errors_total') if $self->{metrics};
							$sth->finish if $sth;
						}

						$self->{_badword_cache}{$sTo} = { ts => $now, words => \@words };
						$cache = $self->{_badword_cache}{$sTo};
					}

					my $sMsgLc = lc $sMsg;
					for my $bw (@{ $cache->{words} // [] }) {
						if (index($sMsgLc, $bw) != -1) {
							logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,"$sMsg (BADWORD : $bw)");
							noticeConsoleChan($self,"Badword : $bw blocked on channel $sTo ($sMsg)");
							$self->{logger}->log(3,"Badword : $bw blocked on channel $sTo ($sMsg)");
							return;
						}
					}

					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}
		}
		else {
			$eventtype = "private";
			my $log_msg = _redact_irc_service_secret_for_log($sMsg);
			$self->{logger}->log(0,"-> *$sTo* $log_msg");
		}
		if (defined($sMsg) && ($sMsg ne "")) {
			# mb344-B1: neutraliser les sauts de ligne AVANT l'envoi, comme le
			# font déjà botPrivmsg (mb325) et botNotice. Sans ça, un ACTION
			# contenant un CR/LF (p.ex. titre d'URL ou texte relayé) terminait la
			# ligne IRC prématurément : le reste devenait une commande IRC injectée
			# (\1ACTION x\r\nPRIVMSG #autre :... \1). Le commentaire mb134-B8 disait
			# pourtant "keep botAction aligned with botPrivmsg" — l'alignement CRLF
			# manquait. _split_text_for_irc ne retire pas les \r\n, d'où ce fix.
			$sMsg =~ s/[\r\n]+/ /g;

			# mb327-B1: découpe les ACTIONs longues sur le même budget d'octets que
			# botPrivmsg/botNotice (helper partagé _split_text_for_irc). Sans ça, un
			# /me accentué/emoji dépassait ~512 octets : le serveur tronquait la ligne
			# ET perdait le \1 final, corrompant le CTCP ACTION. Le budget texte est
			# réduit de l'overhead du wrapper "\1ACTION \1" (9 octets) pour que la
			# ligne émise reste dans la même enveloppe qu'un PRIVMSG. Chaque chunk est
			# ré-emballé en ACTION distinct. Le découpage se fait avant l'encodage
			# UTF-8 (sur la chaîne de caractères) pour ne jamais couper un multi-octets.
			my $action_overhead = length("\1ACTION \1");   # 9
			my @chunks = _split_text_for_irc($sMsg, 400 - $action_overhead);
			@chunks = ($sMsg) unless @chunks;
			for my $chunk (@chunks) {
				next unless defined($chunk) && $chunk ne "";
				my $payload = utf8::is_utf8($chunk) ? encode("UTF-8", $chunk) : $chunk;
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $payload\1" );
			}
		}
		else {
			$self->{logger}->log(0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		$self->{logger}->log(0,"botAction() ERROR no target specified to send $sMsg");
	}
}


# Send a notice to a target (user or channel)
sub botNotice {
    my ($self, $target, $text) = @_;

    # Sanity check: both target and message must be defined and non-empty
    unless (defined $target && $target ne '') {
        $self->{logger}->log(4, "[DEBUG] botNotice() aborted: target is undefined or empty");
        return;
    }
    unless (defined $text && $text ne '') {
        $self->{logger}->log(4, "[DEBUG] botNotice() aborted: text is undefined or empty");
        return;
    }

    $self->{logger}->log(4, "[DEBUG] botNotice() called with target='$target', text='$text'");

    # Keep NOTICE behavior aligned with botPrivmsg:
    # - sanitize newlines;
    # - split long messages instead of truncating them;
    # - split before UTF-8 encoding so accents, emojis and IRC bar chars are
    #   never cut in the middle of a multi-byte sequence.
    # mb325-B1: byte-aware split shared with botPrivmsg. Splitting on a 400-byte
    # budget (instead of 400 characters) keeps accents/emojis/IRC bar chars from
    # pushing a NOTICE past the ~512-byte wire limit; the per-chunk encode below
    # is unchanged. Char-boundary safety is preserved by the helper.
    $text =~ s/[\r\n]+/ /g;

    my @chunks = _split_text_for_irc($text, 400);
    @chunks = ($text) unless @chunks;

    for my $chunk (@chunks) {
        next unless defined($chunk) && $chunk ne '';

        my $encoded_text = utf8::is_utf8($chunk) ? encode('UTF-8', $chunk) : $chunk;

        $self->{logger}->log(4, "[DEBUG] botNotice() sending encoded text length=" . length($encoded_text));

        # Envoi du NOTICE
        $self->{metrics}->inc('mediabot_notice_out_total') if $self->{metrics};
        $self->{irc}->do_NOTICE(
            target => $target,
            text   => $encoded_text
        );

        # Log interne (version lisible). mb133-B7: redact private NOTICE logs
        # too, for consistency with PRIVMSG/ACTION service-secret handling.
        my $log_chunk = _is_irc_channel_target($target)
            ? $chunk
            : _redact_irc_service_secret_for_log($chunk);
        $self->{logger}->log(0, "-> -$target- $log_chunk");

        # Si c'est un channel NOTICE, log dans l'action log
        if (_is_irc_channel_target($target)) {
            $self->{logger}->log(4, "[DEBUG] botNotice() target is a channel, logging to action log");
            logBotAction($self, undef, "notice", $self->{irc}->nick_folded, $target, $chunk);
        }
    }
}

# Join a channel with an optional key
sub joinChannel {
	my ($self,$channel,$key) = @_;
	if (defined($key) && ($key ne "")) {
		$self->{logger}->log(1,"Trying to join $channel with key [redacted]");
		$self->{irc}->send_message("JOIN", undef, ($channel,$key));
	}
	else {
		$self->{logger}->log(1,"Trying to join $channel");
		$self->{irc}->send_message("JOIN", undef, $channel);
	}
}

# Join channels with auto_join enabled, except console
sub checkUserLevel {
    my ($self, $iUserLevel, $sLevelRequired) = @_;

    return 0 unless defined($iUserLevel);
    return 0 unless defined($sLevelRequired) && $sLevelRequired ne '';

    # mb111-IMP4: cache la table USER_LEVEL (statique — change jamais en runtime)
    unless ($self->{_user_level_cache}) {
        my $sth = $self->{dbh}->prepare("SELECT description, level FROM USER_LEVEL");
        if ($sth && $sth->execute) {
            while (my $r = $sth->fetchrow_hashref) {
                $self->{_user_level_cache}{lc($r->{description})} = $r->{level};
            }
            $sth->finish;
        }
    }

    my $required_level = $self->{_user_level_cache}{lc($sLevelRequired)};
    return 0 unless defined $required_level;

    $self->{logger}->log(4, "checkUserLevel() $iUserLevel vs $sLevelRequired ($required_level)")
        if $self->{logger};

    return ($iUserLevel <= $required_level) ? 1 : 0;
}


# Count the number of users in the database
# Count the number of users in the database
sub userCount {
    my ($self) = @_;

    my $sQuery = "SELECT count(*) as nbUser FROM USER";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "userCount() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute()) {
        $self->{logger}->log(1, "userCount() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $nbUser = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $nbUser = $ref->{nbUser} // 0;
        $self->{logger}->log(4, "userCount() $nbUser")
            if $self->{logger};
    }

    $sth->finish;
    return $nbUser;
}


sub getMessageHostmask {
	my ($self,$message) = @_;
	my $sHostmask = $message->prefix;
	$sHostmask =~ s/.*!//;
	if (substr($sHostmask,0,1) eq '~') {
		$sHostmask =~ s/.//;
	}
	return ("*" . $sHostmask);
}

sub userAdd {
    my ($self, $hostmask, $nickname, $plain_password, $level_name, $username) = @_;
    my $dbh    = $self->{dbh} || ($self->{db} && $self->{db}->dbh);
    my $logger = $self->{logger};

    return undef unless $dbh;

    my %LEVEL = ( owner => 1, master => 2, administrator => 3, user => 4 );
    my $level_id = $LEVEL{ lc($level_name // 'user') } // 4;

    # password: si undef => NULL (évite PASSWORD(NULL))
    my $hashed_pw  = defined $plain_password ? make_password_hash($plain_password) : undef;
    my $pass_sql   = defined $hashed_pw ? '?' : 'NULL';

    my $sql = qq{
        INSERT INTO USER (creation_date, nickname, password, username, id_user_level, auth)
        VALUES (NOW(), ?, $pass_sql, ?, ?, 0)
    };

    my @bind = ($nickname);
    push @bind, $hashed_pw if defined $hashed_pw;
    push @bind, ($username, $level_id);

    my $sth = $dbh->prepare($sql);
    # H3/fix: guard undef $sth
    my $ok  = ($sth && $sth->execute(@bind)) ? 1 : 0;
    $sth->finish if $sth;

    unless ($ok) {
        $logger->log(1, "userAdd() INSERT failed: $DBI::errstr");
        return undef;
    }

    # Capture id ONCE immediately after INSERT USER — before any other statement
    my $id = $dbh->last_insert_id(undef, undef, undef, undef);
    unless ($id) {
        $logger->log(1, "userAdd() last_insert_id returned undef after INSERT USER");
        return undef;
    }

    # Insert initial hostmask into USER_HOSTMASK if provided
    if (defined $hostmask && $hostmask ne '') {
        my $hm_sth = $dbh->prepare(
            "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)"
        );

        unless ($hm_sth && $hm_sth->execute($id, $hostmask)) {
            $logger->log(1, "userAdd() USER_HOSTMASK insert failed for id_user=$id: " . ($DBI::errstr || 'unknown DBI error'));
            $hm_sth->finish if $hm_sth;
        }
        else {
            $hm_sth->finish;
        }
    }

    $logger->log(1, "userAdd() created user '$nickname' (id_user=$id, level_id=$level_id)");
    return $id;
}





sub partChannel {
    my ($self, $channel, $reason) = @_;

    $channel //= '';
    $reason  //= '';

    return unless $channel =~ /^#/;

    # Default reason if empty
    $reason = "Leaving" if $reason eq '';

    # Send PART
    eval {
        # Net::Async::IRC style
        $self->{irc}->send_message("PART", undef, ($channel, $reason));
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "partChannel(): failed to PART $channel: $err");
        return;
    };

    $self->{logger}->log(4, "partChannel(): PART sent for $channel (reason='$reason')");
    return 1;
}

# Check if a user has a specific level on a channel
sub checkUserChannelLevel {
    my ($self, $message, $sChannel, $id_user, $level) = @_;

    return 0 unless defined($sChannel) && $sChannel ne '';
    return 0 unless defined($id_user)  && $id_user  ne '';
    return 0 unless defined($level);

    # mb328-B1: clé de cache normalisée en minuscules sur le nom de canal. Les
    # canaux IRC sont insensibles à la casse (et le SQL matche en collation _ci),
    # mais la clé brute "$id\x00$sChannel" différenciait #Foo et #foo. Les
    # invalidations par-utilisateur de channelAddUser/DelUser (match exact)
    # rataient alors l'entrée stockée sous une autre casse → niveau de privilège
    # périmé jusqu'à 60s (TTL). On canonicalise ici ET côté invalidation.
    my $cache_key = "$id_user\x00" . lc($sChannel);
    my $now       = time();
    my $ttl       = 60;
    my $cached_level;
    if (exists $self->{_uchan_level_cache}{$cache_key}) {
        my $entry = $self->{_uchan_level_cache}{$cache_key};
        if (($now - $entry->{ts}) < $ttl) {
            $cached_level = $entry->{val};
            return (defined $cached_level && $cached_level >= $level) ? 1 : 0;
        }
    }

    my $sQuery = "SELECT level FROM CHANNEL JOIN USER_CHANNEL ON USER_CHANNEL.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ? AND USER_CHANNEL.id_user = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "checkUserChannelLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sChannel, $id_user)) {
        $self->{logger}->log(1, "checkUserChannelLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $ok = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        my $iLevel = $ref->{level};
        # Stocker dans le cache
        $self->{_uchan_level_cache}{$cache_key} = { ts => $now, val => $iLevel };
        $ok = 1 if defined($iLevel) && $iLevel >= $level;
    } else {
        $self->{_uchan_level_cache}{$cache_key} = { ts => $now, val => undef };
    }

    $sth->finish;
    return $ok;
}


# Join a channel (Administrator+ OR channel-level >= 450)
sub getIdUserChannelLevel {
    my ($self, $sUserHandle, $sChannel) = @_;

    return (undef, undef) unless defined($sUserHandle) && $sUserHandle ne '';
    return (undef, undef) unless defined($sChannel)    && $sChannel    ne '';

    my $sQuery = "SELECT USER.id_user, USER_CHANNEL.level FROM CHANNEL JOIN USER_CHANNEL ON USER_CHANNEL.id_channel = CHANNEL.id_channel JOIN USER ON USER.id_user = USER_CHANNEL.id_user WHERE USER.nickname = ? AND CHANNEL.name = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getIdUserChannelLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return (undef, undef);
    }

    unless ($sth->execute($sUserHandle, $sChannel)) {
        $self->{logger}->log(1, "getIdUserChannelLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return (undef, undef);
    }

    my ($id_user, $level) = (undef, undef);
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_user = $ref->{id_user};
        $level   = $ref->{level};
        $self->{logger}->log(4, "getIdUserChannelLevel() $id_user $level")
            if $self->{logger};
    }

    $sth->finish;
    return ($id_user, $level);
}


# Give operator (+o) to a nick on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub getUserChannelLevelByName {
    my ($self, $sChannel, $sHandle) = @_;

    return 0 unless defined($sChannel) && $sChannel ne '';
    return 0 unless defined($sHandle)  && $sHandle  ne '';

    my $sQuery = "SELECT USER_CHANNEL.level FROM USER JOIN USER_CHANNEL ON USER_CHANNEL.id_user = USER.id_user JOIN CHANNEL ON CHANNEL.id_channel = USER_CHANNEL.id_channel WHERE CHANNEL.name = ? AND USER.nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getUserChannelLevelByName() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return 0;
    }

    unless ($sth->execute($sChannel, $sHandle)) {
        $self->{logger}->log(1, "getUserChannelLevelByName() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return 0;
    }

    my $iChannelUserLevel = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $iChannelUserLevel = $ref->{level} // 0;
    }

    $sth->finish;

    $self->{logger}->log(4, "getUserChannelLevelByName() iChannelUserLevel = $iChannelUserLevel")
        if $self->{logger};

    return $iChannelUserLevel;
}


sub setChannelAntiFlood {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		botNotice($self, $sNick, "Channel $sChannel is not registered to me");
		return;
	}

	my $id_channel = $channel_obj->get_id;

	my $sQuery = "SELECT duration, first, latest, nbmsg, nbmsg_max, notification, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth && $sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		$sth->finish if $sth;
		return;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $nbmsg_max = $ref->{'nbmsg_max'};
		my $duration  = $ref->{'duration'};
		my $timetowait = $ref->{'timetowait'};

		$self->{logger}->log(4, "setChannelAntiFlood() AntiFlood record exists (id_channel $id_channel) nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds");
		botNotice($self, $sNick, "Chanset parameters already exist and will be used for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");

	} else {
		$sQuery = "INSERT INTO CHANNEL_FLOOD (id_channel) VALUES (?)";
		$sth->finish if $sth;  # B26h/fix2: close 1st sth before reuse
		$sth = $self->{dbh}->prepare($sQuery);

		unless ($sth && $sth->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			$sth->finish if $sth;
			return;
		}

		my $id_channel_flood = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
		$self->{logger}->log(4, "setChannelAntiFlood() AntiFlood record created, id_channel_flood : $id_channel_flood");

		$sQuery = "SELECT duration, first, latest, nbmsg, nbmsg_max, notification, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?";
		my $sth2 = $self->{dbh}->prepare($sQuery);

		unless ($sth2 && $sth2->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		} elsif (my $ref = $sth2->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $duration  = $ref->{'duration'};
			my $timetowait = $ref->{'timetowait'};

			botNotice($self, $sNick, "Chanset parameters for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
		} else {
			botNotice($self, $sNick, "Something funky happened, could not find record id_channel_flood : $id_channel_flood in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
		}

		$sth2->finish if $sth2;
	}

	$sth->finish;
}

# Check the anti-flood status for a channel

# ---------------------------------------------------------------------------
# make_password_hash($plain)
# Reproduces MariaDB PASSWORD() without DB round-trip:
#   '*' . uc( sha1_hex( sha1($plain) ) )
# ---------------------------------------------------------------------------
sub make_password_hash {
    my ($plain) = @_;
    return undef unless defined $plain && length $plain;
    return '*' . uc(sha1_hex(sha1($plain)));
}


sub getConsoleChan {
    my ($self) = @_;

    foreach my $chan (values %{ $self->{channels} }) {
        if (defined $chan->get_description && $chan->get_description eq 'console') {
            return (
                $chan->get_id,
                $chan->get_name,
                $chan->get_chanmode,
                $chan->get_key,
            );
        }
    }

    # If no console channel is found
    return undef;
}

# Send a notice to the console channel
sub logBotAction {
    my ($self, $message, $eventtype, $sNick, $sChannel, $sText) = @_;

    my $sUserhost = "";
    $sUserhost = $message->prefix if defined $message;

    if (defined $sChannel) {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype chan = $sChannel nick = $sNick text = $sText");
    }
    else {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype nick = $sNick text = $sText");
    }

    $self->{logger}->log(5, "logBotAction() prefix=" . ($message->prefix // "?") . " command=" . ($message->command // "?"))
        if defined($message) && defined($self->{logger}->{debug}) && $self->{logger}->{debug} >= 5;

    my $id_channel;

    if (defined $sChannel) {
        my $sQuery = "SELECT id_channel FROM CHANNEL WHERE name = ?";
        my $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth) {
            $self->{logger}->log(1, "logBotAction() SQL prepare error: $DBI::errstr Query: $sQuery")
                if $self->{logger};
            return;
        }

        unless ($sth && $sth->execute($sChannel)) {
            $self->{logger}->log(1, "logBotAction() SQL execute error: $DBI::errstr Query: $sQuery")
                if $self->{logger};
            $sth->finish if $sth;
            return;
        }

        my $ref = $sth->fetchrow_hashref();
        $sth->finish;

        unless ($ref) {
            $self->{logger}->log(4, "logBotAction() channel not found: $sChannel")
                if $self->{logger};
            return;
        }

        $id_channel = $ref->{id_channel};
    }

    my $insert_query = <<'SQL';
INSERT INTO CHANNEL_LOG (id_channel, event_type, nick, userhost, publictext)
VALUES (?, ?, ?, ?, ?)
SQL

    my $sth_insert = $self->{dbh}->prepare($insert_query);

    unless ($sth_insert) {
        $self->{logger}->log(1, "logBotAction() SQL insert prepare error: $DBI::errstr Query: $insert_query")
            if $self->{logger};
        return;
    }

    unless ($sth_insert->execute($id_channel, $eventtype, $sNick, $sUserhost, $sText)) {
        $self->{logger}->log(1, "logBotAction() SQL insert execute error: $DBI::errstr Query: $insert_query")
            if $self->{logger};
        $sth_insert->finish;
        return;
    }

    $sth_insert->finish;
    $self->{logger}->log(5, "logBotAction() inserted $eventtype event into CHANNEL_LOG")
        if $self->{logger};
}



# Send a private message to a target
sub versionCheck {
    my ($ctx) = @_;

    my $self     = $ctx->bot;
    my $conf     = $self->{conf};
    my $bot_name = $conf->get('main.MAIN_PROG_NAME');
    my $message  = $ctx->message;

    # MB317: GitHub/DNS access must not run inside the IRC callback. Capture the
    # command context now and build the reply when the async worker completes.
    return getVersion_async(
        $self,
        sub {
            my ($local_version, $remote_version) = @_;

            $local_version  = 'Undefined'
                unless defined($local_version) && !ref($local_version) && $local_version ne '';
            $remote_version = 'Undefined'
                unless defined($remote_version) && !ref($remote_version) && $remote_version ne '';

            $self->{main_prog_version} = $local_version;

            my $sMsg = "$bot_name version: $local_version";
            if ($remote_version ne 'Undefined' && $remote_version ne $local_version) {
                $sMsg .= " (update available: $remote_version)";
            }

            $ctx->reply($sMsg);
            logBot($self, $message, undef, 'version', undef);
        },
    );
}

# 🧙‍♂️ Handle private commands with centralized dispatching and full command set.

# ---------------------------------------------------------------------------
# checkNickFlood($self, $nick) — per-nick rate limit
# Max 5 commands per 5 seconds, independent of channel AntiFlood.
# Returns 1 if the nick is flooding (caller should silently drop), 0 if ok.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# checkChanFlood($self, $channel) → 1 si le canal est en flood, 0 sinon  (AF4)
#
# Rate limiter GLOBAL par canal — compte toutes les commandes bot reçues
# sur ce canal, toutes sources confondues. Purement en mémoire, zéro DB.
#
# Paramètres (hardcodés, ajustables sans schéma) :
#   WINDOW    : 10s  — fenêtre glissante
#   MAX_CMDS  : 8    — commandes max toutes sources dans la fenêtre
#   SILENCE   : 30s  — durée du silencing du canal en cas de flood
#   NOTIFY    : 60s  — délai min entre deux notifications console
#
# Cas d'usage : #quebec — plusieurs nicks invoquent le bot en rafale,
# ce qui déclenche un burst de réponses. Ce guard bloque les ENTRÉES
# avant même que botPrivmsg soit appelé.
# ---------------------------------------------------------------------------
sub _af_conf_int {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = eval { $self->{conf}->get("antiflood.$key") };

    $value = $default
        if !defined $value || $value eq '' || $value !~ /^\d+$/;

    $value = int($value);

    $value = $min if defined $min && $value < $min;
    $value = $max if defined $max && $value > $max;

    return $value;
}

# ---------------------------------------------------------------------------
# checkCmdCooldown($self, $channel, $cmd, [$seconds]) → 0 OK, N secs restant (CC1)
#
# Per-command, per-channel cooldown for expensive commands (!ai, !trivia).
# Entirely in memory. Default cooldowns:
#   ai      → 10s per channel
#   trivia  → 5s per channel
#   poll    → 0s (no cooldown — managed by poll active flag)
#
# Operators (.chanset) can override via _cmd_cooldown config (CC2).
# ---------------------------------------------------------------------------
sub checkCmdCooldown {
    my ($self, $channel, $cmd, $override_secs) = @_;
    return 0 unless defined $channel && $channel =~ /^#/ && defined $cmd;

    # Default cooldowns per command (seconds)
    my %defaults = (
        ai      => 10,
        trivia  => 5,
        openai  => 10,
    );
    # CC2: per-channel override via .cmdcooldown takes priority
    my $chan_conf = defined $channel
        ? ($self->{_cmd_cooldown_conf}{$channel}{lc $cmd} // undef)
        : undef;
    my $cooldown = defined $override_secs ? $override_secs
                 : defined $chan_conf      ? $chan_conf
                 : ($defaults{lc $cmd} // 0);
    return 0 if $cooldown <= 0;

    my $now = time();
    my $key = lc($cmd) . ':' . lc($channel);
    my $last = $self->{_cmd_cooldown}{$key} // 0;
    my $elapsed = $now - $last;

    if ($elapsed < $cooldown) {
        # A-68-3: track cooldown blocks in Prometheus
        $self->{metrics}->inc('mediabot_cmdcooldown_blocks_total')
            if $self->{metrics};
        # CC16: debug log when cooldown blocks a command
        my $wait_cd = $cooldown - $elapsed;
        $self->{logger}->log(3,
            "checkCmdCooldown() blocking !$cmd on $channel — ${wait_cd}s remaining")
            if $self->{logger};
        return $wait_cd;
    }
    $self->{_cmd_cooldown}{$key} = $now;
    return 0;
}


sub checkChanFlood {
    my ($self, $channel) = @_;
    return 0 unless defined $channel && $channel =~ /^#/;

    my $now       = time();
    # CC2: per-channel overrides set by .floodset take priority
    my $conf_ov   = $self->{_chan_flood_conf}{$channel} // {};
    # B-68-3/fix: clamp CC2 overrides to sane minimums (0 would cause logic errors)
    my $window    = do { my $v = $conf_ov->{window};  defined($v) ? (int($v) >= 1 ? int($v) : 1) : _af_conf_int($self, 'CHANFLOOD_WINDOW', 10, 1, 3600) };
    my $max_cmds  = do { my $v = $conf_ov->{max};     defined($v) ? (int($v) >= 1 ? int($v) : 1) : _af_conf_int($self, 'CHANFLOOD_MAX_COMMANDS', 8, 1, 1000) };
    my $silence   = do { my $v = $conf_ov->{silence}; defined($v) ? (int($v) >= 1 ? int($v) : 1) : _af_conf_int($self, 'CHANFLOOD_SILENCE', 30, 1, 86400) };
    my $notify_cd = _af_conf_int($self, 'CHANFLOOD_NOTIFY_COOLDOWN', 60, 1, 86400);

    my $st = $self->{_chan_flood}{$channel} //= {
        hits          => [],
        silenced_until => 0,
        notified_at   => 0,
    };

    # Silenced?
    if ($st->{silenced_until} && $now < $st->{silenced_until}) {
        return 1;
    }
    # Silence lifted
    if ($st->{silenced_until} && $now >= $st->{silenced_until}) {
        $self->{logger}->log(1, "checkChanFlood/AF4: silence lifted on $channel");
        $st->{silenced_until} = 0;
        $st->{hits}           = [];
    }

    # Sliding window: push + prune
    push @{ $st->{hits} }, $now;
    @{ $st->{hits} } = grep { ($now - $_) < $window } @{ $st->{hits} };

    my $count = scalar @{ $st->{hits} };

    if ($count > $max_cmds) {
        # FF6: warn-only mode — notify but do not actually silence
        my $warn_only = $self->{_chan_flood_conf}{$channel}{warn_only} // 0;
        $st->{silenced_until} = $warn_only ? 0 : ($now + $silence);
        # B4/fix: log message reflects actual mode (warn-only vs silencing)
        $self->{logger}->log(1,
            "checkChanFlood/AF4: $channel — $count cmds in last ${window}s "
            . "(max $max_cmds) — " . ($warn_only ? 'warn-only' : "silencing ${silence}s"));
        if (($now - $st->{notified_at}) >= $notify_cd) {
            $st->{notified_at} = $now;
            noticeConsoleChan($self,
                "Chan flood detected on $channel ($count cmds/${window}s) "
                . ($warn_only ? '— warn-only (AF4)' : "— silencing ${silence}s (AF4)"));
        }
        $self->{metrics}->inc('mediabot_chanflood_blocks_total')
            if $self->{metrics};
        return $warn_only ? 0 : 1;  # FF6: warn-only returns 0 (allow command)
    }

    return 0;
}


sub checkNickFlood {
    # AF2: notify user once per throttle period (not silently drop)
    # AF3: sliding window (ring buffer of timestamps) instead of fixed window
    my ($self, $nick, $channel) = @_;
    return 0 unless defined $nick && $nick ne '';

    my $now     = time();

    # CC3/AF7: check temp mute (set by strike counter)
    my $mute_until = $self->{_nick_mute}{lc $nick} // 0;
    if ($mute_until > $now) {
        $self->{logger}->log(3, "NickFlood/AF7: " . lc($nick) . " is muted");
        return 1;  # silently drop — user was already notified
    } elsif ($mute_until) {
        delete $self->{_nick_mute}{lc $nick};  # expired, clean up
    }
    my $window  = _af_conf_int($self, 'NICKFLOOD_WINDOW', 5, 1, 3600);
    my $max_cmd = _af_conf_int($self, 'NICKFLOOD_MAX_COMMANDS', 5, 1, 1000);
    my $ttl     = _af_conf_int($self, 'NICKFLOOD_STATE_TTL', 120, 10, 86400);
    my $notify_cooldown = _af_conf_int($self, 'NICKFLOOD_NOTIFY_COOLDOWN', 30, 1, 86400);

    my $nick_key = lc($nick);

    $self->{_nick_flood} //= {};

    # Cheap periodic cleanup
    if (!defined($self->{_nick_flood_last_cleanup})
            || ($now - $self->{_nick_flood_last_cleanup}) >= $ttl) {
        for my $k (keys %{ $self->{_nick_flood} }) {
            my $st = $self->{_nick_flood}{$k};
            my $last = @{ $st->{hits} // [] } ? $st->{hits}[-1] : 0;
            delete $self->{_nick_flood}{$k} if ($now - $last) > $ttl;
        }
        $self->{_nick_flood_last_cleanup} = $now;
    }

    my $state = $self->{_nick_flood}{$nick_key} //= { hits => [], notified_at => 0 };

    # AF3: sliding window — push current ts, drop entries outside the window
    push @{ $state->{hits} }, $now;
    @{ $state->{hits} } = grep { ($now - $_) < $window } @{ $state->{hits} };

    my $count = scalar @{ $state->{hits} };

    if ($count > $max_cmd) {
        $self->{logger}->log(3,
            "NickFlood/AF3: $nick_key — $count cmds in last ${window}s (max $max_cmd)");
        $self->{metrics}->inc('mediabot_nickflood_blocks_total')
            if $self->{metrics};

        # CC3/AF7: consecutive strike counter — 3 strikes → temp ignore 5min
        $state->{strikes} = ($state->{strikes} // 0) + 1;
        if ($state->{strikes} >= 3) {
            my $mute_until = $now + 300;  # 5 minutes
            $self->{_nick_mute}{$nick_key} = $mute_until;
            $state->{strikes} = 0;
            $self->{logger}->log(1,
                "NickFlood/AF7: $nick_key auto-muted for 300s after 3 strikes");
            $self->{metrics}->inc('mediabot_nickflood_mutes_total')
                if $self->{metrics};
        }

        # AF2: notify the user — at most once per notify_cooldown
        if (defined $channel
                && ($now - ($state->{notified_at} // 0)) >= $notify_cooldown) {
            $state->{notified_at} = $now;
            my $wait = $window - ($now - $state->{hits}[0]);
            $wait = 1 if $wait < 1;
            botNotice($self, $nick,
                "You are sending commands too fast. Please wait ${wait}s.");
        }
        return 1;
    }

    return 0;
}

sub checkAntiFlood {
	my ($self, $sChannel) = @_;

    # IMP7: cross-channel global rate limit per bot-output
    # A bot could send to N channels at full per-channel speed — cap globally.
    {
        my $now_g = time();
        my $g     = $self->{_global_af} //= { hits => [], silenced_until => 0 };
        if ($g->{silenced_until} > $now_g) {
            my $wait = $g->{silenced_until} - $now_g;
            $self->{logger}->log(3, "checkAntiFlood() global silence ${wait}s remaining");
            return 1;
        }
        # IMP16: configurable global sliding window via OUTPUT_GLOBAL_* conf keys
        my $g_window  = _af_conf_int($self, 'OUTPUT_GLOBAL_WINDOW',  10, 5, 60);
        my $g_max     = _af_conf_int($self, 'OUTPUT_GLOBAL_MAX_MSG', 20, 5, 200);
        my $g_silence = _af_conf_int($self, 'OUTPUT_GLOBAL_SILENCE', 15, 5, 120);
        @{ $g->{hits} } = grep { ($now_g - $_) < $g_window } @{ $g->{hits} };
        push @{ $g->{hits} }, $now_g;
        # V4: debug log current hit count
        my $hit_count = scalar @{ $g->{hits} };
        $self->{logger}->log(4, "checkAntiFlood() global: $hit_count/$g_max msgs in ${g_window}s window")
            if $hit_count > int($g_max * 0.7);  # only log when >70% of threshold
        if ($hit_count > $g_max) {
            $g->{silenced_until} = $now_g + $g_silence;
            $self->{logger}->log(2, "checkAntiFlood() global flood — silencing ${g_silence}s");
            return 1;
        }
    }

    # AF1: in-memory antiflood — zero DB queries per outgoing message.
    # DB params (nbmsg_max, duration, timetowait) are cached for 60s.
    # Flood counters live entirely in $self->{_af}{$sChannel}.

    my $now = time();

    # --- Params cache ---
    # CHANNEL_FLOOD values remain DB-backed, but the refresh TTL is config-backed.
    my $params_ttl = _af_conf_int($self, 'OUTPUT_PARAMS_CACHE_TTL', 60, 5, 86400);
    my $pc = $self->{_af_params}{$sChannel} // {};
    if (!$pc->{ts} || ($now - $pc->{ts}) >= $params_ttl) {
        my $channel_obj = $self->{channels}{$sChannel};
        unless (defined $channel_obj) {
            $self->{logger}->log(1, "checkAntiFlood() unknown channel: $sChannel");
            return 0;
        }
        my $id_channel = $channel_obj->get_id;
        my $sth = $self->{dbh}->prepare(
            "SELECT nbmsg_max, duration, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?"
        );
        if ($sth && $sth->execute($id_channel)) {
            my $ref = $sth->fetchrow_hashref;
            $sth->finish;
            if ($ref) {
                $self->{_af_params}{$sChannel} = {
                    ts          => $now,
                    nbmsg_max   => $ref->{nbmsg_max}  // 5,
                    duration    => $ref->{duration}    // 30,
                    timetowait  => $ref->{timetowait}  // 300,
                    id_channel  => $id_channel,
                };
                $pc = $self->{_af_params}{$sChannel};
            } else {
                # No CHANNEL_FLOOD row — AntiFlood not configured, allow all
                return 0;
            }
        } else {
            $self->{logger}->log(1, "checkAntiFlood() DB error: $DBI::errstr");
            return 0;
        }
    }

    my $nbmsg_max  = $pc->{nbmsg_max}  // 5;
    my $duration   = $pc->{duration}   // 30;
    my $timetowait = $pc->{timetowait} // 300;

    # --- In-memory flood state ---
    my $st = $self->{_af}{$sChannel} //= { nbmsg => 0, first => $now, silenced_until => 0 };

    # Silenced? Check expiry
    if ($st->{silenced_until} && $now < $st->{silenced_until}) {
        $self->{logger}->log(3,
            "checkAntiFlood() silenced $sChannel until "
            . ($st->{silenced_until} - $now) . "s remaining");
        return 1;
    }

    # Silence lifted?
    if ($st->{silenced_until} && $now >= $st->{silenced_until}) {
        $self->{logger}->log(1, "checkAntiFlood() silence lifted on $sChannel");
        $st->{nbmsg}          = 0;
        $st->{first}          = $now;
        $st->{silenced_until} = 0;
        # EE5: notify channel that anti-flood silence has been lifted
        eval {
            botPrivmsg($self, $sChannel,
                'Anti-flood silence lifted — bot is responding again.');
        };
    }

    # Window expired? Reset
    if (($now - $st->{first}) >= $duration) {
        $st->{nbmsg} = 0;
        $st->{first} = $now;
    }

    $st->{nbmsg}++;

    if ($st->{nbmsg} > $nbmsg_max) {
        unless ($st->{silenced_until}) {
            $st->{silenced_until} = $now + $timetowait;
            $self->{logger}->log(1,
                "checkAntiFlood() AF1: flooding on $sChannel — "
                . "$st->{nbmsg} msgs in " . ($now - $st->{first})
                . "s (max $nbmsg_max/$duration s) — silencing ${timetowait}s");
            noticeConsoleChan($self,
                "Anti-flood activated on $sChannel ($st->{nbmsg} msgs in "
                . ($now - $st->{first}) . "s) — silenced for ${timetowait}s");
            $self->{metrics}->inc('mediabot_antiflood_blocks_total')
                if $self->{metrics};
        }
        return 1;
    }

    # A7: periodic cleanup of stale flood state
    {
        my $state_ttl       = _af_conf_int($self, 'OUTPUT_STATE_TTL', 300, 30, 86400);
        my $params_state_ttl = _af_conf_int($self, 'OUTPUT_PARAMS_STATE_TTL', 600, 30, 86400);

        if (!$self->{_antiflood_cleanup} || ($now - $self->{_antiflood_cleanup}) >= $state_ttl) {
            for my $chan (keys %{ $self->{_af} // {} }) {
                my $s = $self->{_af}{$chan};
                delete $self->{_af}{$chan}
                    if (!$s->{silenced_until} && ($now - ($s->{first} // 0)) > $state_ttl);
            }
            # Also clean params cache
            for my $chan (keys %{ $self->{_af_params} // {} }) {
                delete $self->{_af_params}{$chan}
                    if ($now - ($self->{_af_params}{$chan}{ts} // 0)) > $params_state_ttl;
            }
            $self->{_antiflood_cleanup} = $now;
        }
    }

    return 0;
}
# Set or display anti-flood parameters for a given channel (Context version)
sub leet {
    my ($maybe_self, @rest) = @_;

    # If called as leet($self, "text"), $maybe_self is the bot object.
    # Build the input string from everything after the first arg.
    my $input;
    if (@rest) {
        $input = join(' ', @rest);
    } else {
        $input = $maybe_self // '';
    }

    Encode::_utf8_on($input);

    my @english = (
        "ph", "i", "I", "l", "a", "e", "s", "S",
        "A", "o", "O", "t", "y", "H", "W", "M",
        "D", "V", "x",
    );
    my @leet = (
        "f",  "1", "1", "|", "4", "3", "5", "Z",
        "4", "0", "0", "7", "Y", "|-|", "\\/\\/", "|\\/|",
        "|)", "\\/", "><",
    );

    for my $i (0 .. $#english) {
        my $c = $english[$i];
        my $l = $leet[$i];
        # Use \Q...\E to avoid regex side-effects
        $input =~ s/\Q$c\E/$l/g;
    }

    return $input;
}

# /leet <string>
# Convert the given string to leet-speak and display it.

sub getVersion {
    my $self = shift;
    my ($local_version, $remote_version) = ("Undefined", "Undefined");
    my ($c_major, $c_minor, $c_type, $c_dev_info);
    my ($r_major, $r_minor, $r_type, $r_dev_info);

    $self->{logger}->log(1, "Reading local version from VERSION file...");

    # Read local VERSION file
    if (open my $fh, '<', 'VERSION') {
        chomp($local_version = <$fh>);
        close $fh;
        ($c_major, $c_minor, $c_type, $c_dev_info) = $self->getDetailedVersion($local_version);
    } else {
        $self->{logger}->log(1, "Unable to read local VERSION file.");
    }

    if (defined $c_major && defined $c_minor && defined $c_type) {
        my $suffix = $c_dev_info ? "($c_dev_info)" : '';
        $self->{logger}->log(1, "-> Mediabot $c_type version $c_major.$c_minor $suffix");
    } else {
        $self->{logger}->log(1, "-> Unknown local version format: $local_version");
    }

    # If we have a valid local version, try fetching the GitHub version
    if ($local_version ne "Undefined") {
        $self->{logger}->log(1, "Checking latest version from GitHub...");

        my $version_url = 'https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION';
        my $response = eval { HTTP::Tiny->new(timeout => 5)->get($version_url); }
                    // { success => 0, status => 0, reason => $@ };

        if ($response->{success}) {
            $remote_version = $response->{content} // '';
            $remote_version =~ s/\r?\n\z//;

            ($r_major, $r_minor, $r_type, $r_dev_info) = $self->getDetailedVersion($remote_version);

            if (defined $r_major && defined $r_minor && defined $r_type) {
                my $suffix = $r_dev_info ? "($r_dev_info)" : '';
                $self->{logger}->log(1, "-> GitHub $r_type version $r_major.$r_minor $suffix");

                if ($local_version eq $remote_version) {
                    $self->{logger}->log(1, "Mediabot is up to date.");
                } else {
                    $self->{logger}->log(1, "Update available: $r_type version $r_major.$r_minor $suffix");
                }
            } else {
                $self->{logger}->log(1, "Unknown remote version format: $remote_version");
            }
        } else {
            my $status = defined $response->{status} ? $response->{status} : 'unknown';
            $self->{logger}->log(1, "Failed to fetch version from GitHub: HTTP $status");
        }
    }

    $self->{main_prog_version} = $local_version;
    return ($local_version, $remote_version);
}

{
    package Mediabot::Helpers::_SilentLogger;
    sub log { return 1 }
}

# MB317: the public `version` command must not perform GitHub/DNS I/O inside
# the IRC callback. Keep getVersion() synchronous for startup and explicit
# callers, but expose a child-backed asynchronous wrapper for runtime commands.
sub getVersion_async {
    my ($self, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 7
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 20  if $timeout > 20;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    # Compatibility path for startup tests or callers without IO::Async.
    # It intentionally keeps the historical synchronous behavior only when
    # no usable event loop exists.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my ($local, $remote) = eval { getVersion($self) };
        $local  = 'Undefined' unless defined($local)  && !ref($local)  && $local ne '';
        $remote = 'Undefined' unless defined($remote) && !ref($remote) && $remote ne '';
        eval { $callback->($local, $remote); 1; };
        return 1;
    }

    my $child_pid = open(my $pipe, '-|');

    unless (defined $child_pid) {
        eval { $callback->('Undefined', 'Undefined'); 1; };
        return 1;
    }

    if ($child_pid == 0) {
        # Suppress duplicate version logs from the forked worker and avoid
        # inherited bot/DB/IRC destructors when the child finishes.
        local $self->{logger} = bless {}, 'Mediabot::Helpers::_SilentLogger';

        my ($local, $remote) = eval { getVersion($self) };
        $local  = 'Undefined' unless defined($local)  && !ref($local)  && $local ne '';
        $remote = 'Undefined' unless defined($remote) && !ref($remote) && $remote ne '';
        $local  = substr($local,  0, 256);
        $remote = substr($remote, 0, 256);

        my $payload = eval { encode_json([$local, $remote]) };
        $payload = '["Undefined","Undefined"]'
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

        my ($local, $remote) = ('Undefined', 'Undefined');

        unless ($state->{timed_out} || $state->{wait_failed}) {
            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if (!$signal && $exit == 0) {
                my $decoded = eval { decode_json($state->{output} // '') };
                if (!$@ && ref($decoded) eq 'ARRAY' && @$decoded >= 2) {
                    my ($candidate_local, $candidate_remote) = @$decoded[0, 1];
                    $local = $candidate_local
                        if defined($candidate_local)
                            && !ref($candidate_local)
                            && $candidate_local ne ''
                            && length($candidate_local) <= 256;
                    $remote = $candidate_remote
                        if defined($candidate_remote)
                            && !ref($candidate_remote)
                            && $candidate_remote ne ''
                            && length($candidate_remote) <= 256;
                }
            }
        }

        my $callback_ok = eval { $callback->($local, $remote); 1; };
        if (!$callback_ok && $self && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "getVersion_async callback failed: $error");
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

                my $waited = waitpid($child_pid, WNOHANG);

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

                    my $waited = waitpid($child_pid, WNOHANG);

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

            if (length $$buffref) {
                my $remaining = 1024 - length($state->{output});
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
# getDetailedVersion – parses a version string and returns its components

sub getDetailedVersion {
    my ($self, $version_string) = @_;

    # Expecting version format like: 3.0 or 3.0dev-20250614_192031
    if ($version_string =~ /^(\d+)\.(\d+)$/) {
        # Stable version
        return ($1, $2, "stable", undef);
    } elsif ($version_string =~ /^(\d+)\.(\d+)dev[-_]?([\d_]+)$/) {
        # Dev version like 3.0dev-20250614_192031
        return ($1, $2, "devel", $3);
    } else {
        return (undef, undef, undef, undef);
    }
}

# Get the debug level from the configuration

# ---------------------------------------------------------------------------
# mb118-IMP3: chanset_enabled($self, $channel, $chanset_name, %opts)
#
# Helper utilitaire pour vérifier de manière compacte si un chanset est actif
# sur un canal. Factorise le pattern :
#   getIdChansetList -> getIdChannelSet -> bool
#
# Options:
#   default      => 0|1   valeur si chanset absent de CHANSET_LIST
#                         (legacy/backward-compat). Défaut: 0.
#
# Retour: 1 si actif, 0 sinon.
#
# Exemples:
#   chanset_enabled($self, $chan, 'AchievementAnnounce', default => 1)
#   chanset_enabled($self, $chan, 'Games')
# ---------------------------------------------------------------------------
sub chanset_enabled {
    my ($self, $channel, $chanset_name, %opts) = @_;
    return 0 unless defined $channel && $channel =~ /^#/ && defined $chanset_name;

    my $default = exists $opts{default} ? $opts{default} : 0;

    my $id_chanset = getIdChansetList($self, $chanset_name);
    return $default unless defined $id_chanset && $id_chanset ne '';

    my $id_channel_set = getIdChannelSet($self, $channel, $id_chanset);
    return $id_channel_set ? 1 : 0;
}

sub getIdChannelSet {
    my ($self, $sChannel, $id_chanset_list) = @_;

    unless (defined $sChannel && $sChannel ne '') {
 $self->{logger}->log(2, " getIdChannelSet() called without a channel name")
            if $self->{logger};
        return undef;
    }

    unless (defined $id_chanset_list && $id_chanset_list ne '') {
 $self->{logger}->log(2, " getIdChannelSet() called without an id_chanset_list")
            if $self->{logger};
        return undef;
    }

    # mb110-IMP1: cache TTL 120s — évite 2 requêtes SQL par botPrivmsg sur canal actif
    my $cache_key = "$sChannel\x00$id_chanset_list";
    my $now       = time();
    my $ttl       = 120;
    if (exists $self->{_chanset_cache}{$cache_key}) {
        my $entry = $self->{_chanset_cache}{$cache_key};
        if (($now - $entry->{ts}) < $ttl) {
            return $entry->{val};
        }
    }

    $self->{logger}->log(4, "getIdChannelSet() DB lookup chan=$sChannel id_chanset=$id_chanset_list")
        if $self->{logger};

    my $sQuery = q{
        SELECT id_channel_set
        FROM CHANNEL_SET
        JOIN CHANNEL ON CHANNEL_SET.id_channel = CHANNEL.id_channel
        WHERE name = ? AND id_chanset_list = ?
    };

    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, " SQL prepare error in getIdChannelSet(): " . $DBI::errstr . " | Query: $sQuery")
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sChannel, $id_chanset_list)) {
        $self->{logger}->log(1, " SQL execute error in getIdChannelSet(): " . $DBI::errstr . " | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $id_channel_set;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_channel_set = $ref->{id_channel_set};
    }

    $sth->finish;

    # Stocker dans le cache (même si undef — canal sans ce chanset)
    $self->{_chanset_cache}{$cache_key} = { ts => $now, val => $id_channel_set };

    return $id_channel_set;
}


# Purge a channel from the bot: delete it and archive its data (Context-based) and Administrator only

sub getIdChansetList {
    my ($self, $sChansetValue) = @_;

    unless (defined $sChansetValue && $sChansetValue ne '') {
        $self->{logger}->log(2, "getIdChansetList() called without a chanset value")
            if $self->{logger};
        return undef;
    }

    # mb118-B1: cache statique — la table CHANSET_LIST ne change pas en runtime.
    # Chargement lazy au premier appel, puis hit mémoire pour les appels suivants.
    # `exists` au lieu de `defined` car on cache aussi les "not found" (= undef)
    # pour éviter le SELECT répété sur un chanset inexistant.
    my $cache_key = lc($sChansetValue);
    if (exists $self->{_chansetlist_cache}{$cache_key}) {
        return $self->{_chansetlist_cache}{$cache_key};
    }

    $self->{logger}->log(4, "getIdChansetList() looking up chanset: '$sChansetValue'")
        if $self->{logger};

    my $sQuery = "SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getIdChansetList() SQL prepare error: " . $DBI::errstr . " | Query: $sQuery")
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sChansetValue)) {
        $self->{logger}->log(1, "getIdChansetList() SQL execute error: " . $DBI::errstr . " | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $id_chanset_list;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_chanset_list = $ref->{id_chanset_list};
        $self->{logger}->log(4, "getIdChansetList() found id_chanset_list=$id_chanset_list for chanset '$sChansetValue'")
            if $self->{logger};
    }
    else {
        $self->{logger}->log(4, "getIdChansetList() no result found for chanset '$sChansetValue'")
            if $self->{logger};
    }

    $sth->finish;
    # Stocker dans le cache (même si undef — évite le SELECT répété)
    $self->{_chansetlist_cache}{$cache_key} = $id_chanset_list;
    return $id_chanset_list;
}


# Retrieve the ID of a channel set from CHANNEL_SET table for a given channel and chanset list ID

sub evalAction {
	my ($self,$message,$sNick,$sChannel,$sCommand,$actionDo,@tArgs) = @_;

	$actionDo = '' unless defined $actionDo;
	$sNick    = '' unless defined $sNick;
	$sChannel = '' unless defined $sChannel;
	$sCommand = '' unless defined $sCommand;

	$self->{logger}->log(4,"evalAction() $sCommand / $actionDo");

	# IMP21/fix: process long, explicit placeholders before legacy short
	# placeholders. Otherwise %nick% is partially consumed by %n and
	# %channel% is partially consumed by %c.
	if ( $actionDo =~ /%(?:nick|channel|date|time)%/ ) {
		my @t = localtime(time);
		my $date_str = sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]);
		my $time_str = sprintf('%02d:%02d', $t[2], $t[1]);

		$actionDo =~ s/%nick%/$sNick/g;
		$actionDo =~ s/%channel%/$sChannel/g;
		$actionDo =~ s/%date%/$date_str/g;
		$actionDo =~ s/%time%/$time_str/g;
	}

	if (defined($tArgs[0])) {
		my $sArgs = join(" ",@tArgs);
		$actionDo =~ s/%n/$sArgs/g;
	}
	else {
		$actionDo =~ s/%n/$sNick/g;
	}
	if ( $actionDo =~ /%r/ ) {
		my $sRandomNick = getRandomNick($self,$sChannel);
		$actionDo =~ s/%r/$sRandomNick/g;
	}
	if ( $actionDo =~ /%R/ ) {
		my $sRandomNick = getRandomNick($self,$sChannel);
		$actionDo =~ s/%R/$sRandomNick/g;
	}
	if ( $actionDo =~ /%s/ ) {
		my $sCommandWithSpaces = $sCommand;
		$sCommandWithSpaces =~ s/_/ /g;
		$actionDo =~ s/%s/$sCommandWithSpaces/g;
	}
	if ( $actionDo =~ /%b/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%b/true/g;
		}
		else {
			$actionDo =~ s/%b/false/g;
		}
	}
	if ( $actionDo =~ /%B/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%B/true/g;
		}
		else {
			$actionDo =~ s/%B/false/g;
		}
	}
	if ( $actionDo =~ /%on/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%on/oui/g;
		}
		else {
			$actionDo =~ s/%on/non/g;
		}
	}
	if ( $actionDo =~ /%c/ ) {
		$actionDo =~ s/%c/$sChannel/g;
	}
	if ( $actionDo =~ /%N/ ) {
		$actionDo =~ s/%N/$sNick/g;
	}
	my @tActionDo = split(/ /,$actionDo);
	my $pos;
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%d' ) {
			$tActionDo[$pos] = int(rand(10) + 1);
		}
	}
	$actionDo = join(" ",@tActionDo);
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%dd' ) {
			$tActionDo[$pos] = int(rand(90) + 10);
		}
	}
	$actionDo = join(" ",@tActionDo);
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%ddd' ) {
			$tActionDo[$pos] = int(rand(900) + 100);
		}
	}
	$actionDo = join(" ",@tActionDo);
	return $actionDo;
}

sub mbWhereis_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Normalize args
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: whereis <nick>");
        return;
    }

    my $target_nick = $args[0];

    # Prepare WHOIS context for the async handler
    my %whois = (
        nick    => $target_nick,
        sub     => 'mbWhereis',      # kept for compatibility with existing WHOIS handler
        caller  => $nick,
        channel => $channel,
        message => $message,
        ts      => time,
    );

    # Store in bot state (same semantics as before: re-use the existing hashref)
    %{$self->{WHOIS_VARS}} = %whois;

    # Send WHOIS to IRC server
    $self->{irc}->send_message("WHOIS", undef, $target_nick);

    $self->{logger}->log(3, "mbWhereis_ctx(): WHOIS requested for $target_nick by $nick"
                             . (defined $channel ? " on $channel" : " (private)"));

    return 1;
}

# birthday:
#   add user <username> <dd/mm|dd/mm/YYYY>
#   del user <username>
#   next
#   <username>

sub displayBirthDate_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Output destination: notice in private, privmsg in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    my $birth_ts = eval { $self->{conf}->get('main.MAIN_PROG_BIRTHDATE') };

    unless (defined $birth_ts && $birth_ts =~ /^\d+$/ && $birth_ts > 0) {
        my $msg = "Birthdate is not configured (main.MAIN_PROG_BIRTHDATE).";
        $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $dest_chan, $msg);
        return;
    }

    my $sBirthDate = "I was born on " . strftime("%d/%m/%Y at %H:%M:%S.", localtime($birth_ts));

    my $d = time() - $birth_ts;
    $d = 0 if $d < 0; # clock skew safety

    my @int = (
        [ 'second', 1                 ],
        [ 'minute', 60                ],
        [ 'hour',   60*60             ],
        [ 'day',    60*60*24          ],
        [ 'week',   60*60*24*7        ],
        [ 'month',  60*60*24*30.5     ],
        [ 'year',   60*60*24*30.5*12  ],
    );

    my $i = $#int;
    my @r;

    while ($i >= 0 && $d) {
        my $unit = $int[$i]->[0];
        my $sec  = $int[$i]->[1];

        if ($d / $sec >= 1) {
            my $n = int($d / $sec);
            push @r, sprintf("%d %s%s", $n, $unit, ($n > 1 ? 's' : ''));
        }
        $d %= $sec;
        $i--;
    }

    my $runtime = @r ? join(", ", @r) : "0 seconds";

    my $msg = "$sBirthDate I am $runtime old";
    $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $dest_chan, $msg);

    return 1;
}

# Rename a public command (Master+)
# Syntax: mvcmd <old_command> <new_command>

sub mbColors_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $text = join(' ', grep { defined && $_ ne '' } @args);

    unless (defined $text && $text ne '') {
        botNotice($self, $nick, "Syntax: colors <text>");
        return;
    }

    my $out = make_colors_pretty($self, $text);

    # In channel => privmsg ; in private => notice
    if (defined($ctx->channel) && $ctx->channel =~ /^#/) {
        botPrivmsg($self, $ctx->channel, $out);
    } else {
        botNotice($self, $nick, $out);
    }

    return 1;
}

# seen <nick> [#channel]
# - In channel: defaults to current channel for part checks, replies in channel
# - In private: you can pass an optional #channel; replies by notice

# YouTube badge with safe colors

sub mbDbCheckNickHostname_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx checknick attempt (unauthenticated)");
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx checknick attempt (Master required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    my $search = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $search =~ s/^\s+|\s+$//g;

    unless ($search ne '') {
        botNotice($self, $nick, "Syntax: checknick <nick>");
        return;
    }

    # If someone passes a full hostmask, keep only the nick part
    $search =~ s/!.*$//;

    # Reply destination
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Exact nick lookup.
    # checknick is not a wildcard search command: '%' and '_' must be treated
    # as literal nick characters, not SQL LIKE wildcards.
    my $sql = <<'SQL';
SELECT userhost, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE nick = ?
GROUP BY userhost
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckNickHostname_ctx(): failed to prepare SQL");
        return;
    }

    unless ($sth->execute($search)) {
        $self->{logger}->log(1, "mbDbCheckNickHostname_ctx() SQL Error: $DBI::errstr Query: $sql");
        $sth->finish;
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $uh = $ref->{userhost} // next;
        my $hits = $ref->{hits} // 0;

        # Display ident@host only (drop leading "nick!")
        $uh =~ s/^.*!//;

        push @rows, [$uh, $hits];
    }
    $sth->finish;

    if (!@rows) {
        my $resp = "No result found for nick: $search";

        if ($is_private) {
            botNotice($self, $nick, $resp);
        }
        else {
            botPrivmsg($self, $dest_chan, $resp);
        }

        logBot($self, $ctx->message, $dest_chan, "checknick", $search);
        return 1;
    }

    my @items = map { "$_->[0]($_->[1])" } @rows;
    my $count = scalar(@items);
    my $summary = "Hostmasks for $search: $count result(s), showing max 10";

    if ($is_private) {
        botNotice($self, $nick, $summary);
    }
    else {
        botPrivmsg($self, $dest_chan, "$summary - details sent by notice to $nick");
    }

    my $per_line    = 5;
    my $total_pages = int((scalar(@items) + $per_line - 1) / $per_line);
    my $page        = 1;

    while (@items) {
        my @chunk = splice(@items, 0, $per_line);
        my $line  = sprintf("checknick[%02d/%02d]: %s", $page, $total_pages, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    logBot($self, $ctx->message, $dest_chan, "checknick", $search);
    return 1;
}

# greet [#channel] <nick>
# If called in private: greet #channel <nick>

sub sethChannelsNicksOnChan {
	my ($self,$sChannel,@tNicklist) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	@{$hChannelsNicks{$sChannel}} = @tNicklist;
	%{$self->{hChannelsNicks}} = %hChannelsNicks;
}



# ---------------------------------------------------------------------------
# updateUserSeen($self, %args)
# UPSERT USER_SEEN for a nick. One row per nick (PK = nick).
# Safe to call from any IRC event handler — errors are logged silently.
# ---------------------------------------------------------------------------
sub updateUserSeen {
    my ($self, %args) = @_;

    my $nick       = lc($args{nick}   // return);
    my $channel    = $args{channel}    // '';
    my $userhost   = $args{userhost}   // '';
    my $event_type = $args{event_type} // 'message';
    my $last_msg   = $args{last_msg};
    my $new_nick   = $args{new_nick};

    # Trim to column sizes
    $nick     = substr($nick,     0,  64) if length($nick)     >  64;
    $channel  = substr($channel,  0,  64) if length($channel)  >  64;
    $userhost = substr($userhost, 0, 128) if length($userhost) > 128;
    $last_msg = substr($last_msg, 0, 512)
        if defined $last_msg && length($last_msg) > 512;
    $new_nick = substr($new_nick, 0,  64)
        if defined $new_nick && length($new_nick) > 64;

    my $dbh = $self->{dbh} or return;

    my $sth = $dbh->prepare(q{
        INSERT INTO USER_SEEN
            (nick, channel, userhost, event_type, last_msg, new_nick, seen_at)
        VALUES (?, ?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            channel    = VALUES(channel),
            userhost   = VALUES(userhost),
            event_type = VALUES(event_type),
            last_msg   = VALUES(last_msg),
            new_nick   = VALUES(new_nick),
            seen_at    = NOW()
    }) or return;

    eval {
        unless ($sth->execute($nick, $channel, $userhost, $event_type, $last_msg, $new_nick)) {
            die $DBI::errstr || 'unknown DBI error';
        }
    };
    $self->{logger}->log(3, "updateUserSeen: $@") if $@ && $self->{logger};
    $sth->finish;
}

sub gethChannelNicks {
	my $self = shift;
	return $self->{hChannelsNicks};
}


sub userAuthNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Administrator+ required (and must be logged in)
    $ctx->require_level('Administrator') or return;

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: auth <nick>");
        return;
    }

    my $targetNick = $args[0];

    # WHOIS tracking context (must match mediabot.pl expectations)
    $self->{WHOIS_VARS} = {
        nick    => $targetNick,
        sub     => 'userAuthNick',
        caller  => $nick,
        channel => undef,
        message => $ctx->message,
    };

    $self->{logger}->log(4, "Triggering WHOIS on $targetNick for $nick via userAuthNick_ctx()");
    $self->{irc}->send_message("WHOIS", undef, $targetNick);

    return;
}

# verify <nick> — Triggers a WHOIS to verify a user's existence

sub getWhoisVar {
	my $self = shift;
	return $self->{WHOIS_VARS};
}

# access #channel <nickhandle>
# access #channel =<nick>

sub gethChannelsNicksEndOnChan {
	my ($self,$Schannel) = @_;
	my %hChannelsNicksEnd;
	if (defined($self->{hChannelsNicksEnd})) {
		%hChannelsNicksEnd = %{$self->{hChannelsNicksEnd}};
	}
	if (defined($hChannelsNicksEnd{$Schannel})) {
		return $hChannelsNicksEnd{$Schannel};
	}
	else {
		return 0;
	}
}


sub _bool_str {  # affiche joliment undef/0/1
    return 'undef' if !defined $_[0];
    return $_[0] ? '1' : '0';
}

# Dump l'état d'auth partout (objet, DB, module Auth, caches)

sub mbDbCheckHostnameNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Require authentication
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx checkhost attempt (unauthenticated " . ($user->nickname // '?') . ")");
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
        noticeConsoleChan($self, "$pfx checkhost attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Argument
    my $raw = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $raw =~ s/^\s+|\s+$//g;

    unless ($raw ne '') {
        botNotice($self, $nick, "Syntax: checkhost <hostname>");
        return;
    }

    # Normalize input:
    # - nick!ident@host  -> host
    # - *@host           -> host
    # - ident@host       -> host
    # - host             -> host
    my $host = $raw;
    $host =~ s/^.*\@// if $host =~ /\@/;   # keep part after last '@'
    $host =~ s/^\*\@//;                    # strip leading '*@' if present
    $host =~ s/^\s+|\s+$//g;

    unless ($host ne '') {
        botNotice($self, $nick, "Syntax: checkhost <hostname>");
        return;
    }

    # Output destination:
    # - Private command => Notice
    # - Public command  => Privmsg in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Optimization:
    # - No JOIN
    # - Pattern matches the host part inside full userhost: 'nick!ident@host'
    # - LIMIT keeps it bounded
    #
    # Index hints (if logs are big):
    #   CHANNEL_LOG(userhost), CHANNEL_LOG(nick)
    my $sql = <<'SQL';
SELECT nick, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE userhost IS NOT NULL
  AND userhost LIKE ? ESCAPE '!'
GROUP BY nick
ORDER BY hits DESC
LIMIT 20
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx(): failed to prepare SQL");
        return;
    }

    my $host_like = $host;
    $host_like =~ s/!/!!/g;
    $host_like =~ s/%/!%/g;
    $host_like =~ s/_/!_/g;

    my $mask = '%@' . $host_like;

    unless ($sth && $sth->execute($mask)) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx() SQL Error: $DBI::errstr Query: $sql");
        $sth->finish if $sth;
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{nick};
        my $h = $ref->{hits} // 0;
        next unless defined $n && $n ne '';
        push @rows, [$n, $h];
    }
    $sth->finish;

    if (!@rows) {
        my $resp = "No result found for hostname $host.";

        if ($is_private) {
            botNotice($self, $nick, $resp);
        }
        else {
            botPrivmsg($self, $dest_chan, $resp);
        }

        logBot($self, $ctx->message, $dest_chan, "checkhost", $host);
        return 1;
    }

    my @items = map { "$_->[0]($_->[1])" } @rows;
    my $count = scalar(@items);
    my $summary = "Nicks for host $host: $count result(s), showing max 20";

    if ($is_private) {
        botNotice($self, $nick, $summary);
    }
    else {
        botPrivmsg($self, $dest_chan, "$summary - details sent by notice to $nick");
    }

    my $per_line    = 5;
    my $total_pages = int((scalar(@items) + $per_line - 1) / $per_line);
    my $page        = 1;

    while (@items) {
        my @chunk = splice(@items, 0, $per_line);
        my $line  = sprintf("checkhost[%02d/%02d]: %s", $page, $total_pages, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    logBot($self, $ctx->message, $dest_chan, "checkhost", $host);
    return 1;
}

# checknick <nick> - Show top 10 hostmasks for a given nickname
# Requires: authenticated + Master+

sub whoTalk_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Auth + level
    return unless $ctx->require_level("Administrator");
    my $user = $ctx->user;
    return unless $user;

    # Resolve target channel: first arg if #chan, else ctx->channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: whotalk <#channel>");
        return;
    }

    # Prefer our internal channel hash (avoid mismatches / useless SQL)
    my $chan_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($chan_obj) {
        botNotice($self, $nick, "Channel $target doesn't seem to be registered.");
        logBot($self, $ctx->message, undef, "whotalk", $target, "No such channel");
        return;
    }

    my $target_lc = lc($target);

    my $sql = q{
        SELECT CL.nick, COUNT(*) AS nbLines
        FROM CHANNEL_LOG CL
        JOIN CHANNEL C ON CL.id_channel = C.id_channel
        WHERE (CL.event_type = 'public' OR CL.event_type = 'action')
          AND LOWER(TRIM(C.name)) = ?
          AND CL.ts > (NOW() - INTERVAL 1 HOUR)
        GROUP BY CL.nick
        ORDER BY nbLines DESC
        LIMIT 20
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_lc)) {
        $self->{logger}->log(1, "whoTalk_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my @rows;
    while (my $r = $sth->fetchrow_hashref) {
        next unless defined $r->{nick} && $r->{nick} ne '';
        my $lines = $r->{nbLines} // 0;
        push @rows, [ $r->{nick}, $lines ];
    }
    $sth->finish;

    # Decide where to output:
    # - if command issued IN the same channel, we can post in-channel
    # - else: only NOTICE the requester (less noisy)
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    if ($ctx_chan =~ /^#/ && lc($ctx_chan) eq $target_lc) {
        $out_chan = $target;   # safe to speak in-channel
    }

    if (!@rows) {
        my $msg = "No messages recorded on $target during the last hour.";
        $out_chan ? botPrivmsg($self, $out_chan, $msg) : botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "whotalk", $target, "empty");
        return;
    }

    # Paginated output:
    # - in-channel call: short public summary, details by NOTICE
    # - private/off-channel call: summary and details by NOTICE
    my @talkers = map { "$_->[0]($_->[1])" } @rows;
    my $count   = scalar(@talkers);
    my $summary = "Top talkers last hour on $target: $count result(s), showing max 20";

    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
    }
    else {
        botNotice($self, $nick, $summary);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@talkers) {
        my @chunk = splice(@talkers, 0, $per_line);
        # KK5: @talkers contains strings like "nick(N)" — join directly
        my $line  = sprintf("whotalk[%02d]: %s", $page,
            join('  ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    # Optional gentle warning, but only if we are already speaking in-channel
    if ($out_chan && $rows[0][1] >= 25) {
 botPrivmsg($self, $out_chan, "$rows[0][0]: please slow down a bit -- you're flooding the channel.");
    }

    logBot($self, $ctx->message, undef, "whotalk", $target);
    return scalar(@rows);
}

# Check and execute a public command from the database

sub make_colors_pretty {
    my ($self, $string) = @_;

    # Keep UTF-8 flag (as you did)
    Encode::_utf8_on($string);

    # mIRC color codes (avoid 0/8/15/14: too bright/low-contrast on some themes)
    # 02 blue, 03 green, 04 red, 05 brown, 06 purple, 07 orange, 10 cyan, 13 pink
    my @palette = (2, 3, 4, 6, 7, 10, 13, 5);
    my $num = scalar(@palette);

    my $new = '';
    my $i   = 0;

    for my $char (split //, $string) {
        if ($char eq ' ') {
            $new .= ' ';
            next;
        }

        my $c = $palette[$i % $num];

        # \003 = mIRC color introducer, \017 = reset
        $new .= "\003" . sprintf("%02d", $c) . $char;
        $i++;
    }

    # Reset formatting at end
    $new .= "\017";

    return $new;
}

# colors <text>  (Context version)

sub displayDate_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel; # only when not private

    # Helper: send output to correct place
    my $say = sub {
        my ($txt) = @_;
        if ($is_private) { botNotice($self, $nick, $txt); }
        else             { botPrivmsg($self, $dest_chan, $txt); }
    };

    my $default_tz = 'America/New_York';

    # Aliases
    my %alias = (
        fr     => 'Europe/Paris',
        moscow => 'Europe/Moscow',
        la     => 'America/Los_Angeles',
        dk     => 'Europe/Copenhagen',
    );

    # No arg => default TZ
    if (!@args) {
        my $dt = DateTime->now(time_zone => $default_tz);
        $say->("$default_tz : " . $dt->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    my $arg0 = $args[0];

    # Easter egg
    if ($arg0 =~ /^me$/i) {
        my @answers = (
            "Ok $nick, I'll pick you up at eight ;>",
            "I have to ask my daddy first $nick ^^",
            "let's skip that $nick, and go to your place :P~",
        );
        $say->($answers[int(rand(@answers))]);
        return 1;
    }

    # List
    if ($arg0 =~ /^list$/i) {
        $say->("Available Timezones: https://pastebin.com/4p4pby3y");
        return 1;
    }

    # Admin subcommands: date user add <nick> <tz> | date user del <nick>
    if ($arg0 =~ /^user$/i) {
        my $user = $ctx->user;

        # Require authenticated + Administrator+
        unless ($user && $user->is_authenticated) {
            noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick) . " date user attempt (unauthenticated)");
            botNotice($self, $nick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
            return;
        }
        unless (eval { $user->has_level('Administrator') }) {
            my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
            noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick) . " date user attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
            botNotice($self, $nick, "Your level does not allow you to use this command.");
            return;
        }

        my $sub = $args[1] // '';
        if ($sub =~ /^add$/i) {
            my ($targetNick, $targetTZ) = @args[2, 3];

            unless (defined $targetNick && $targetNick ne '' && defined $targetTZ && $targetTZ ne '') {
                $say->("Usage:");
                $say->("  date user add <nick> <timezone>");
                return;
            }

            my $current = $self->_get_user_tz($targetNick);
            if (defined $current && $current ne '') {
                $say->("$targetNick already has timezone $current. Delete it first.");
                return;
            }

            # allow alias on tz too
            my $tz_in = $targetTZ;
            $tz_in = $alias{lc $tz_in} if exists $alias{lc $tz_in};

            unless ($self->_tz_exists($tz_in)) {
                $say->("Timezone $tz_in not found. See: https://pastebin.com/4p4pby3y");
                return;
            }

            if ($self->_set_user_tz($targetNick, $tz_in)) {
                my $now = DateTime->now(time_zone => $tz_in);
                $say->("Updated timezone for $targetNick: $tz_in " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
                logBot($self, $ctx->message, $ctx->channel, "date", @args);
            } else {
                $say->("Failed to update timezone for $targetNick.");
            }
            return 1;

        } elsif ($sub =~ /^del$/i) {
            my $targetNick = $args[2];

            unless (defined $targetNick && $targetNick ne '') {
                $say->("Usage:");
                $say->("  date user del <nick>");
                return;
            }

            my $tz = $self->_get_user_tz($targetNick);
            unless (defined $tz && $tz ne '') {
                $say->("$targetNick has no defined timezone.");
                return;
            }

            if ($self->_del_user_tz($targetNick)) {
                $say->("Deleted timezone for $targetNick.");
                logBot($self, $ctx->message, $ctx->channel, "date", @args);
            } else {
                $say->("Failed to delete timezone for $targetNick.");
            }
            return 1;

        } else {
            $say->("Usage:");
            $say->("  date user add <nick> <timezone>");
            $say->("  date user del <nick>");
            return 1;
        }
    }

    # Apply alias (for tz/user lookup too)
    $arg0 = $alias{lc $arg0} if exists $alias{lc $arg0};

    # If arg0 is a known user => show their tz
    my $user_tz = $self->_get_user_tz($arg0);
    if ($user_tz) {
        my $now = DateTime->now(time_zone => $user_tz);
        $say->("Current date for $arg0 ($user_tz): " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    # If arg0 is a valid timezone => show it
    if ($self->_tz_exists($arg0)) {
        my $now = DateTime->now(time_zone => $arg0);
        $say->("$arg0 : " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    $say->("Unknown user or timezone: $arg0");
    return 1;
}

# Responder functions

sub mp3_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user from context ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Must be authenticated
    unless ($user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        noticeConsoleChan($self, "$pfx mp3 command attempt (user $who is not logged in)");
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }



    # --- No arguments => syntax ---
    unless (@args) {
        botNotice($self, $nick, "Syntax: mp3 <title>");
        botNotice($self, $nick, "        mp3 count");
        botNotice($self, $nick, "        mp3 id <LibraryID>");
        return;
    }

    my $sub = lc $args[0];

    # =========================
    #  mp3 count
    # =========================
    if ($sub eq 'count') {
        my $sql = "SELECT COUNT(*) AS nbMp3 FROM MP3";
        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth && $sth->execute()) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
            botPrivmsg($self, $channel, "($nick mp3 count) unexpected error") if $channel;
            $sth->finish if $sth;
            return;
        }

        my $nb = 0;
        if (my $ref = $sth->fetchrow_hashref()) {
            $nb = $ref->{nbMp3} // 0;
        }
        $sth->finish;

        my $dst = $channel ? sub { botPrivmsg($self, $channel, @_) }
                           : sub { botNotice($self, $nick, @_) };

        $dst->("($nick mp3 count) $nb in local library");
        logBot($self, $message, $channel, "mp3", @args);
        return;
    }

    # =========================
    #  mp3 id <id>
    # =========================
    if ($sub eq 'id' && defined $args[1] && $args[1] =~ /^\d+$/) {
        my $id = int($args[1]);

        my $sql = "SELECT id_mp3, id_youtube, artist, title, folder, filename FROM MP3 WHERE id_mp3 = ?";
        $self->{logger}->log(4, "mp3_ctx(): $sql (id=$id)");

        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute($id)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
            $sth->finish if $sth;
            return;
        }

        if (my $ref = $sth->fetchrow_hashref()) {
            my $id_mp3    = $ref->{id_mp3};
            my $id_yt     = $ref->{id_youtube};
            my $artist    = defined($ref->{artist}) ? $ref->{artist} : "Unknown";
            my $title     = defined($ref->{title})  ? $ref->{title}  : "Unknown";
            my $sMsgSong  = "$artist - $title";
            my $duration  = 0;

            if (defined($id_yt) && $id_yt ne "") {
                # Reuse existing helper. It may override $sMsgSong with better info.
                ($duration, $sMsgSong) = getYoutubeDetails($self, "https://www.youtube.com/watch?v=$id_yt");
                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) (Library ID : $id_mp3 YTID : $id_yt) / $sMsgSong - https://www.youtube.com/watch?v=$id_yt"
                );
            } else {
                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) First result (Library ID : $id_mp3) / $artist - $title"
                );
            }

            logBot($self, $message, $channel, "mp3", @args);
        } else {
            botPrivmsg($self, $channel, "($nick mp3 search) ID $id not found");
        }

        $sth->finish;
        return;
    }

    # =========================
    #  mp3 <search string>
    # =========================

    my $text = join(' ', @args);
    unless (defined $text && $text ne '') {
        botNotice($self, $nick, "Syntax: mp3 <title>");
        return;
    }

    # Build a LIKE pattern safely:
    #   - split on spaces
    #   - escape SQL LIKE wildcards from user input
    #   - join with '%' so "foo bar" -> "%foo%bar%"
    #   - bind as param instead of interpolating raw
    #
    # Use ESCAPE '!' so literal %, _ and ! in the search are not treated as
    # SQL wildcards.
    my @tokens = grep { length } split(/\s+/, $text);
    my @safe_tokens = map {
        my $t = $_;
        $t =~ s/!/!!/g;
        $t =~ s/%/!%/g;
        $t =~ s/_/!_/g;
        $t;
    } @tokens;

    my $pattern = '%' . join('%', @safe_tokens) . '%';

    # 1) Count matching MP3s
    my $sql_count = "SELECT COUNT(*) AS nbMp3 FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ? ESCAPE '!'";
    $self->{logger}->log(4, "mp3_ctx(): $sql_count (pattern=$pattern)");
    my $sth = $self->{dbh}->prepare($sql_count);

    my $nbMp3 = 0;
    unless ($sth && $sth->execute($pattern)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_count");
        $sth->finish if $sth;
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        $nbMp3 = $ref->{nbMp3} // 0;
    }
    $sth->finish;

    unless ($nbMp3 > 0) {
        botPrivmsg($self, $channel, "($nick mp3 search) $text not found");
        return;
    }

    # 2) Fetch first matching result
    my $sql_first = "SELECT id_mp3, id_youtube, artist, title, folder, filename FROM MP3 ".
                    "WHERE CONCAT(artist, ' ', title) LIKE ? ESCAPE '!' LIMIT 1";
    $self->{logger}->log(4, "mp3_ctx(): $sql_first (pattern=$pattern)");
    $sth = $self->{dbh}->prepare($sql_first);

    unless ($sth && $sth->execute($pattern)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_first");
        $sth->finish if $sth;
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_mp3    = $ref->{id_mp3};
        my $id_yt     = $ref->{id_youtube};
        my $artist    = defined($ref->{artist}) ? $ref->{artist} : "Unknown";
        my $title     = defined($ref->{title})  ? $ref->{title}  : "Unknown";
        my $duration  = 0;
        my $sMsgSong  = "$artist - $title";
        my $word      = ($nbMp3 > 1 ? "matches" : "match");

        if (defined($id_yt) && $id_yt ne "") {
            ($duration, $sMsgSong) = getYoutubeDetails($self, "https://www.youtube.com/watch?v=$id_yt");
            botPrivmsg(
                $self,
                $channel,
                "($nick mp3 search) $nbMp3 $word, first result : ".
                "(Library ID : $id_mp3 YTID : $id_yt) / $sMsgSong - https://www.youtube.com/watch?v=$id_yt"
            );
        } else {
            botPrivmsg(
                $self,
                $channel,
                "($nick mp3 search) $nbMp3 $word, first result : ".
                "(Library ID : $id_mp3) / $artist - $title"
            );
        }

        # 3) If multiple matches, show up to 10 IDs
        if ($nbMp3 > 1) {
            my $sql_list = "SELECT id_mp3, id_youtube, artist, title, folder, filename ".
                           "FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ? ESCAPE '!' LIMIT 10";
            $self->{logger}->log(4, "mp3_ctx(): $sql_list (pattern=$pattern)");
            my $sth2 = $self->{dbh}->prepare($sql_list);

            unless ($sth2 && $sth2->execute($pattern)) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_list");
            } else {
                my $output = "";
                while (my $r = $sth2->fetchrow_hashref()) {
                    my $id2 = $r->{id_mp3};
                    $output .= "$id2 ";
                }
                # B26h/fix: execute failed — cursor not open

                if ($nbMp3 > 10) {
                    $output .= "And " . ($nbMp3 - 10) . " more...";
                }

                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) Next 10 Library IDs : $output"
                );
            }

            logBot($self, $message, $channel, "mp3", @args);
        }
    } else {
        # Extremely unlikely, because count>0, but keep a fallback
        botPrivmsg($self, $channel, "($nick mp3 search) unexpected error, please try again");
    }

    $sth->finish if $sth;  # B-68-1/fix: ensure sth_first cursor is closed
    return;
}

# Check if a message should be ignored based on the IGNORES table
# (both channel-specific and global ignores).
sub isIgnored {
    my ($self,$message,$sChannel,$sNick,$sMsg) = @_;

    return 0 unless $message;

    require Mediabot::Auth;
    $self->{auth} ||= Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
    );

    my $now = time();
    my $ttl = 30; # mb131-B4: short TTL, invalidated explicitly by ignore/unignore

    $self->{_ignore_cache} ||= {};

    my $load_ignores = sub {
        my ($cache_key, $sql, @bind) = @_;

        my $cached = $self->{_ignore_cache}{$cache_key};
        if ($cached && ($now - ($cached->{ts} // 0)) < $ttl) {
            return @{ $cached->{masks} || [] };
        }

        my @masks;
        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute(@bind)) {
            $self->{logger}->log(1, "isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sql);
            $sth->finish if $sth;
            return ();
        }

        while (my $ref = $sth->fetchrow_hashref()) {
            push @masks, ($ref->{hostmask} // '');
        }
        $sth->finish if $sth;

        $self->{_ignore_cache}{$cache_key} = {
            ts    => $now,
            masks => \@masks,
        };

        return @masks;
    };

    my @global_masks = $load_ignores->(
        'global',
        'SELECT hostmask FROM IGNORES WHERE id_channel = 0'
    );

    for my $stored (@global_masks) {
        my ($ok, $matched_mask) = $self->{auth}->hostmask_matches({ hostmasks => $stored }, $message->prefix);

        if ($ok) {
            $self->{logger}->log(4,"isIgnored() (allchans/private) $matched_mask matches " . $message->prefix);
            my $chan_label = (defined($sChannel) && $sChannel =~ /^[#&!+]/) ? "$sChannel:" : "";
            $self->{logger}->log(1,"[IGNORED] " . $stored . " (allchans/private) " . $chan_label . "<$sNick> $sMsg");
            return 1;
        }
    }

    # mb132-B6: channel-scoped ignores are meaningful only for real IRC
    # channels. Private messages already use global ignores above. Avoid an
    # unnecessary CHANNEL join with undef/empty channel and avoid noisy warnings.
    return 0 unless defined($sChannel) && $sChannel =~ /^[#&!+]/;

    my $channel_key = lc($sChannel);
    my @channel_masks = $load_ignores->(
        "chan\x00$channel_key",
        'SELECT IGNORES.hostmask FROM IGNORES JOIN CHANNEL ON CHANNEL.id_channel = IGNORES.id_channel WHERE CHANNEL.name = ?',
        $sChannel
    );

    for my $stored (@channel_masks) {
        my ($ok, $matched_mask) = $self->{auth}->hostmask_matches({ hostmasks => $stored }, $message->prefix);

        if ($ok) {
            $self->{logger}->log(4,"isIgnored() $matched_mask matches " . $message->prefix);
            $self->{logger}->log(1,"[IGNORED] " . $stored . " $sChannel:<$sNick> $sMsg");
            return 1;
        }
    }

    return 0;
}


# List ignores

# Get the current song from the radio stream

sub sethChannelsNicksEndOnChan {
	my ($self,$sChannel,$end) = @_;
	my %hChannelsNicksEnd;
	if (defined($self->{hChannelsNicksEnd})) {
		%hChannelsNicksEnd = %{$self->{hChannelsNicksEnd}};
	}
	$hChannelsNicksEnd{$sChannel} = $end;
	%{$self->{hChannelsNicksEnd}} = %hChannelsNicksEnd;
}


sub displayLeetString_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require a non-empty argument
    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: leet <string>");
        return;
    }

    my $raw_text = join(' ', @args);

    # Safety: avoid flooding if someone pastes a book
    my $max_len = 300;
    if (length($raw_text) > $max_len) {
        $raw_text = substr($raw_text, 0, $max_len) . '...';
    }

    my $leet_text = leet($self, $raw_text);

    my $prefix = "l33t($nick) : ";

    if (defined $channel && $channel ne '') {
        # Called from a channel -> reply in channel
        botPrivmsg($self, $channel, $prefix . $leet_text);
    } else {
        # Called in private -> reply by notice
        botNotice($self, $nick, $prefix . $leet_text);
    }

    return 1;
}

# Reload the bot configuration file (rehash), restricted to Master-level users.
# Context-based version.

sub gethChannelsNicksOnChan {
	my ($self,$sChannel) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	if (defined($hChannelsNicks{$sChannel})) {
		return @{$hChannelsNicks{$sChannel}};
	}
	else {
		return ();
	}
}


sub mbEcho {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $chan = $ctx->channel;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $text = join(' ', @args);

    return unless length $text;

    botPrivmsg($self, $chan, $text);
}

# Context-based status (Master only)

sub getRandomNick {
	my ($self,$sChannel) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
    # mb106-B1: guard contre canal inexistant ou liste vide
    my $nicks_ref = $hChannelsNicks{$sChannel};
    return '' unless defined $nicks_ref && ref($nicks_ref) eq 'ARRAY' && @$nicks_ref;
	my @tChannelNicks = @$nicks_ref;
	my $sRandomNick = $tChannelNicks[rand @tChannelNicks];
	return $sRandomNick;
}


sub resolve_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: resolve <hostname|IP>");
        return;
    }

    my $input = $args[0];
    $input =~ s/^\s+|\s+$//g;

    unless ($input ne '') {
        botNotice($self, $nick, "Syntax: resolve <hostname|IP>");
        return;
    }

    if (length($input) > 253) {
        botPrivmsg($self, $channel, "($nick) Invalid hostname/IP: input is too long");
        return;
    }

    my $mode;

    if ($input =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
        my @octets = split /\./, $input;

        unless (@octets == 4 && !grep { $_ > 255 } @octets) {
            botPrivmsg($self, $channel, "($nick) Invalid IPv4 format: $input");
            return;
        }

        $mode = 'reverse';
    }
    else {
        unless ($input =~ /\A(?=.{1,253}\z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.?\z/) {
            botPrivmsg($self, $channel, "($nick) Invalid hostname: $input");
            return;
        }

        $mode = 'forward';
    }

    # MB311: both forward and reverse DNS are potentially blocking libc calls.
    # Run either lookup in a child and consume its pipe as soon as data arrives,
    # rather than blocking the IRC loop or waiting a fixed three seconds before
    # checking a lookup that may already have completed.
    my $resolver_code = q{
        use Socket;

        my ($mode, $value) = @ARGV;

        if ($mode eq 'reverse') {
            my $packed = inet_aton($value);
            my $host = $packed ? gethostbyaddr($packed, AF_INET) : undef;
            print defined($host) ? $host : '';
            exit 0;
        }

        my @answer = gethostbyname($value);
        if (@answer) {
            my %seen;
            my @ips = grep { !$seen{$_}++ }
                map { Socket::inet_ntoa($_) } @answer[4 .. $#answer];
            print join(',', @ips);
        }
    };

    my $child_pid = open(
        my $pipe,
        '-|',
        $^X,
        '-e',
        $resolver_code,
        $mode,
        $input,
    );

    unless (defined $child_pid) {
        botPrivmsg($self, $channel, "($nick) resolve: could not spawn lookup process");
        return;
    }

    my $loop = $self->getLoop;
    my $msg  = $ctx->message;

    my $state = {
        output       => '',
        pipe_eof     => 0,
        child_done   => 0,
        finalized    => 0,
        timed_out    => 0,
        wait_status  => undef,
        term_sent    => 0,
        kill_sent    => 0,
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

        my $reply;

        if ($state->{timed_out}) {
            $reply = "($nick) DNS lookup timed out for: $input";
        }
        else {
            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if ($signal || $exit != 0) {
                $reply = "($nick) DNS lookup failed for: $input";
            }
            elsif ($mode eq 'reverse') {
                my $host = $state->{output} // '';
                $host =~ s/[\r\n]+\z//;
                $host =~ s/^\s+|\s+$//g;

                $reply = length($host)
                    ? "($nick) $input => $host"
                    : "($nick) No reverse DNS entry for $input";
            }
            else {
                my %seen;
                my @ips = grep {
                    /^\d{1,3}(?:\.\d{1,3}){3}\z/ && !$seen{$_}++
                } split /,/, ($state->{output} // '');

                $reply = @ips
                    ? "($nick) $input => " . join(', ', @ips)
                    : "($nick) Hostname could not be resolved: $input";
            }
        }

        botPrivmsg($self, $channel, $reply);
        eval { logBot($self, $msg, $channel, "resolve", $input) };

        # Break lexical callback cycles once the request is complete.
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

                my $waited = waitpid($child_pid, WNOHANG);

                if ($waited == $child_pid) {
                    $state->{wait_status} = $?;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                if ($waited == -1) {
                    # The child was already collected elsewhere. Preserve any
                    # pipe output and finish without treating this as success
                    # or failure solely from an unavailable wait status.
                    $state->{wait_status} = 0;
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
        delay     => 3,
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

                    my $waited = waitpid($child_pid, WNOHANG);

                    if ($waited == $child_pid) {
                        $state->{wait_status} = $?;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    if ($waited == -1) {
                        $state->{wait_status} = 0;
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

            if (length $$buffref) {
                my $remaining = 4096 - length($state->{output});

                if ($remaining > 0) {
                    $state->{output} .= substr($$buffref, 0, $remaining);
                }

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

# set tmdb_lang for a channel (Administrator+ or channel owner)

sub _tz_exists {
    my ($self, $tz) = @_;

    return undef unless defined($tz) && $tz ne '';

    my $sql = "SELECT tz FROM TIMEZONE WHERE tz = ?";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "_tz_exists() SQL prepare error: $DBI::errstr Query: $sql")
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($tz)) {
        $self->{logger}->log(1, "_tz_exists() SQL execute error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    return $ref;
}


# Get a user's timezone

sub userVerifyNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # NOTE: original code had no auth/level restriction, so we keep it open.
    # If you later want to restrict it, add: $ctx->require_level('Administrator') or return;

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: verify <nick>");
        return;
    }

    my $targetNick = $args[0];

    # WHOIS tracking context (must match mediabot.pl expectations)
    $self->{WHOIS_VARS} = {
        nick    => $targetNick,
        sub     => 'userVerifyNick',
        caller  => $nick,
        channel => undef,
        message => $ctx->message,
    };

    $self->{logger}->log(4, "Triggering WHOIS on $targetNick for $nick via userVerifyNick_ctx()");
    $self->{irc}->send_message("WHOIS", undef, $targetNick);

    return;
}

# /nicklist [#channel]
# Shows the list of known users on a specific channel from memory (hChannelsNicks)
# Requires: authenticated + Administrator+

sub sethChannelNicks {
	my ($self,$phChannelsNicks) = @_;
	%{$self->{hChannelsNicks}} = %$phChannelsNicks;
}


sub getLevel {
    my ($self, $sLevel) = @_;

    return undef unless defined($sLevel) && $sLevel ne '';

    my $sQuery = "SELECT level FROM USER_LEVEL WHERE description = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getLevel() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sLevel)) {
        $self->{logger}->log(1, "getLevel() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
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


# Get user info by matching hostmask (for WHOIS response)
# ---------------------------------------------------------------------------
# get_user_from_whois($hostmask) — like get_user_from_message but for WHOIS
# Returns a Mediabot::User object (or undef) from a bare "ident\@host" mask.
# Used in on_message_311 WHOIS handlers (userVerifyNick, userAuthNick, etc.)
# ---------------------------------------------------------------------------
sub get_user_from_whois {
    my ($self, $whois_hostmask) = @_;

    return undef unless defined $whois_hostmask && $whois_hostmask ne '';

    require Mediabot::User;
    require Mediabot::Auth;

    $self->{auth} ||= Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
    );

    my $sQuery = q{
        SELECT
            u.id_user,
            u.nickname,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ',') AS hostmasks
        FROM USER u
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        GROUP BY u.id_user, u.nickname, u.id_user_level, u.auth, u.info1, u.info2
        ORDER BY u.id_user
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth) {
        $self->{logger}->log(1, "get_user_from_whois() SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute) {
        $self->{logger}->log(1, "get_user_from_whois() SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $best_ref   = undef;
    my $best_mask  = undef;
    my $best_score = -1;

    while (my $ref = $sth->fetchrow_hashref()) {
        my ($ok, $matched_mask, undef, $score) = $self->{auth}->hostmask_matches($ref, $whois_hostmask);
        next unless $ok;
        if ($score > $best_score) {
            $best_ref   = { %$ref };
            $best_mask  = $matched_mask;
            $best_score = $score;
        }
    }
    $sth->finish;

    return undef unless $best_ref;

    $self->{logger}->log(4, "get_user_from_whois() matched '$whois_hostmask' -> '$best_ref->{nickname}' (mask=$best_mask score=$best_score)");

    # Resolve level + description
    my $level     = undef;
    my $level_desc = undef;
    if (defined $best_ref->{id_user_level}) {
        my $sth2 = $self->{dbh}->prepare(
            "SELECT level, description FROM USER_LEVEL WHERE id_user_level = ?"
        );

        unless ($sth2) {
            $self->{logger}->log(1, "get_user_from_whois() level SQL prepare error: $DBI::errstr")
                if $self->{logger};
        }
        elsif ($sth2->execute($best_ref->{id_user_level})) {
            if (my $r2 = $sth2->fetchrow_hashref) {
                $level      = $r2->{level};
                $level_desc = $r2->{description};
            }
            $sth2->finish;
        }
        else {
            $self->{logger}->log(1, "get_user_from_whois() level SQL execute error: $DBI::errstr")
                if $self->{logger};
            $sth2->finish;
        }
    }

    my $user = Mediabot::User->new({
        id_user       => $best_ref->{id_user},
        nickname      => $best_ref->{nickname},
        username      => $best_ref->{nickname},
        hostmasks     => $best_ref->{hostmasks},
        info1         => $best_ref->{info1},
        info2         => $best_ref->{info2},
        id_user_level => $best_ref->{id_user_level},
        auth          => $best_ref->{auth},
    });

    $user->{level}      = $level;
    $user->{level_desc} = $level_desc;
    $user->{dbh}        = $self->{dbh};

    return $user;
}


sub getNickInfoWhois {
    my ($self, $sWhoisHostmask) = @_;

    my $iMatchingUserId        = undef;
    my $iMatchingUserLevel     = undef;
    my $iMatchingUserLevelDesc = undef;
    my $iMatchingUserAuth      = undef;
    my $sMatchingUserHandle    = undef;
    my $sMatchingUserPasswd    = undef; # legacy return slot, intentionally not populated
    my $sMatchingUserInfo1     = undef;
    my $sMatchingUserInfo2     = undef;

    require Mediabot::Auth;
    $self->{auth} ||= Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
    );

    my $sCheckQuery = q{
        SELECT
            u.id_user,
            u.nickname,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ',') AS hostmasks
        FROM USER u
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        GROUP BY
            u.id_user,
            u.nickname,
            u.id_user_level,
            u.auth,
            u.info1,
            u.info2
        ORDER BY u.id_user
    };

    my $sth = $self->{dbh}->prepare($sCheckQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getNickInfoWhois() SQL prepare error : " . $DBI::errstr . " Query : " . $sCheckQuery)
            if $self->{logger};
        return (undef, undef, undef, undef, undef, undef, undef, undef);
    }

    unless ($sth->execute) {
        $self->{logger}->log(1, "getNickInfoWhois() SQL execute error : " . $DBI::errstr . " Query : " . $sCheckQuery)
            if $self->{logger};
        $sth->finish;
        return (undef, undef, undef, undef, undef, undef, undef, undef);
    }
    else {
        my $best_ref;
        my $best_mask;
        my $best_score = -1;

        while (my $ref = $sth->fetchrow_hashref()) {
            my ($ok, $matched_mask, undef, $score) = $self->{auth}->hostmask_matches($ref, $sWhoisHostmask);
            next unless $ok;

            if ($score > $best_score) {
                $best_ref   = { %$ref };
                $best_mask  = $matched_mask;
                $best_score = $score;
            }
        }

        if ($best_ref) {
            $self->{logger}->log(
                4,
                "getNickInfoWhois() matched hostmask '$sWhoisHostmask' with stored mask '$best_mask' for nick '$best_ref->{nickname}' score=$best_score"
            );

            $sMatchingUserHandle = $best_ref->{nickname};
            $iMatchingUserId     = $best_ref->{id_user};
            $iMatchingUserAuth   = $best_ref->{auth};
            $sMatchingUserInfo1  = $best_ref->{info1} if defined $best_ref->{info1};
            $sMatchingUserInfo2  = $best_ref->{info2} if defined $best_ref->{info2};

            my $iMatchingUserLevelId = $best_ref->{id_user_level};
            my $sGetLevelQuery = "SELECT level, description FROM USER_LEVEL WHERE id_user_level = ?";
            my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);

            unless ($sth2) {
                $self->{logger}->log(1, "getNickInfoWhois() level SQL prepare error : " . $DBI::errstr . " Query : " . $sGetLevelQuery)
                    if $self->{logger};
            }
            elsif ($sth2->execute($iMatchingUserLevelId)) {
                while (my $ref2 = $sth2->fetchrow_hashref()) {
                    $iMatchingUserLevel     = $ref2->{level};
                    $iMatchingUserLevelDesc = $ref2->{description};
                }
                $sth2->finish;
            }
            else {
                $self->{logger}->log(1, "getNickInfoWhois() level SQL execute error : " . $DBI::errstr . " Query : " . $sGetLevelQuery)
                    if $self->{logger};
                $sth2->finish;
            }
        }
    }

    $sth->finish;

    if (defined($iMatchingUserId)) {
        $self->{logger}->log(4, "getNickInfoWhois() iMatchingUserId : $iMatchingUserId");
    }
    else {
        $self->{logger}->log(4, "getNickInfoWhois() iMatchingUserId is undefined with this host : " . $sWhoisHostmask);
        return (undef, undef, undef, undef, undef, undef, undef, undef);
    }

    if (defined($iMatchingUserLevel)) {
        $self->{logger}->log(4, "getNickInfoWhois() iMatchingUserLevel : $iMatchingUserLevel");
    }
    if (defined($iMatchingUserLevelDesc)) {
        $self->{logger}->log(4, "getNickInfoWhois() iMatchingUserLevelDesc : $iMatchingUserLevelDesc");
    }
    if (defined($iMatchingUserAuth)) {
        $self->{logger}->log(4, "getNickInfoWhois() iMatchingUserAuth : $iMatchingUserAuth");
    }
    if (defined($sMatchingUserHandle)) {
        $self->{logger}->log(4, "getNickInfoWhois() sMatchingUserHandle : $sMatchingUserHandle");
    }
    if (defined($sMatchingUserInfo1)) {
        $self->{logger}->log(4, "getNickInfoWhois() sMatchingUserInfo1 : $sMatchingUserInfo1");
    }
    if (defined($sMatchingUserInfo2)) {
        $self->{logger}->log(4, "getNickInfoWhois() sMatchingUserInfo2 : $sMatchingUserInfo2");
    }

    return (
        $iMatchingUserId,
        $iMatchingUserLevel,
        $iMatchingUserLevelDesc,
        $iMatchingUserAuth,
        $sMatchingUserHandle,
        $sMatchingUserPasswd,
        $sMatchingUserInfo1,
        $sMatchingUserInfo2
    );
}

# auth => sub { userAuthNick_ctx($ctx) },

# /auth <nick> — Triggers a WHOIS to identify if a user is known/authenticated

sub channelNicksRemove {
	my ($self,$sChannel,$sNick) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
    # mb107-B1: guard contre canal inexistant ou liste vide
    return unless defined $hChannelsNicks{$sChannel}
               && ref($hChannelsNicks{$sChannel}) eq 'ARRAY'
               && @{$hChannelsNicks{$sChannel}};
	my $index;
	for ($index=0;$index<=$#{$hChannelsNicks{$sChannel}};$index++ ) {
		my $currentNick = @{$hChannelsNicks{$sChannel}}[$index];
		if ( $currentNick eq $sNick) {
			splice(@{$hChannelsNicks{$sChannel}}, $index, 1);
			last;
		}
	}
	%{$self->{hChannelsNicks}} = %hChannelsNicks;
}


sub whereis {
    my ($self, $sHostname) = @_;

    $self->{logger}->log(4, "whereis() " . (defined($sHostname) && !ref($sHostname) ? $sHostname : ''))
        if $self->{logger};

    # MB314: whereis() is consumed directly by the WHOIS callback, so it must
    # always return a defined printable value. Reject references and blank input
    # before they can stringify into ARRAY(...)/HASH(...) hostnames.
    return 'N/A' unless defined($sHostname) && !ref($sHostname);

    $sHostname =~ s/^\s+|\s+$//g;
    return 'N/A' if $sHostname eq '';

    if ($sHostname =~ /(?:^|\.)users\.undernet\.org\z/i) {
        return 'on an Undernet hidden host ;)';
    }

    my $userIP;

    if ($sHostname =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/) {
        # inet_aton validates each octet and canonicalizes the IPv4 address.
        my $packed_ip = inet_aton($sHostname);
        return 'N/A' unless defined $packed_ip;
        $userIP = inet_ntoa($packed_ip);
    }
    else {
        my $packed_ip = gethostbyname($sHostname);
        return 'N/A' unless defined $packed_ip;
        $userIP = inet_ntoa($packed_ip);
    }

    return 'N/A'
        unless defined($userIP)
            && $userIP =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/;

    my $whereis_url = "https://api.country.is/$userIP";
    my $response = eval { HTTP::Tiny->new(timeout => 3)->get($whereis_url); }
                // { success => 0, status => 0, reason => $@ };

    return "N/A" unless ref($response) eq 'HASH';
    return "N/A" unless $response->{success};

    my $line = $response->{content} // '';
    return 'N/A' unless $line ne '';

    my $json = eval { decode_json $line };
    return 'N/A'
        if $@ || !defined($json) || ref($json) ne 'HASH';

    my $country = $json->{country};
    return 'N/A' unless defined($country) && !ref($country);

    $country =~ s/^\s+|\s+$//g;
    return $country ne '' ? $country : 'N/A';
}


# MB316: run the potentially blocking hostname lookup and country.is request in
# a child process. The parent consumes the tiny result pipe through IO::Async so
# a slow resolver or remote API cannot freeze IRC processing.
sub whereis_async {
    my ($self, $sHostname, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 5
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 15  if $timeout > 15;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self) eq 'HASH' || ref($self);

    # Lightweight tests and emergency callers may not have an IO::Async loop.
    # Keep compatibility without introducing a sleep or an unbounded wait.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $country = whereis($self, $sHostname);
        $country = 'N/A'
            unless defined($country) && !ref($country) && $country ne '';
        eval { $callback->($country); 1; };
        return 1;
    }

    my $child_pid = open(my $pipe, '-|');

    unless (defined $child_pid) {
        eval { $callback->('N/A'); 1; };
        return 1;
    }

    if ($child_pid == 0) {
        # Do not run inherited bot/DB/IRC destructors in the forked child.
        # The synchronous helper needs no bot state beyond an optional logger.
        my $country = eval { whereis({}, $sHostname) };
        $country = 'N/A'
            unless defined($country) && !ref($country) && $country ne '';
        $country = substr($country, 0, 128);

        my $payload = Encode::encode('UTF-8', $country);
        my $offset  = 0;
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

        my $country = 'N/A';

        unless ($state->{timed_out} || $state->{wait_failed}) {
            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if (!$signal && $exit == 0) {
                my $candidate = $state->{output} // '';
                $candidate =~ s/[\r\n]+\z//;
                $candidate =~ s/^\s+|\s+$//g;
                $country = $candidate
                    if $candidate ne '' && length($candidate) <= 128;
            }
        }

        my $callback_ok = eval { $callback->($country); 1; };
        if (!$callback_ok && $self && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "whereis_async callback failed: $error");
        }

        # Break lexical callback cycles after completion.
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

                my $waited = waitpid($child_pid, WNOHANG);

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

                    my $waited = waitpid($child_pid, WNOHANG);

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

            if (length $$buffref) {
                my $remaining = 256 - length($state->{output});
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
# whereis <nick>
# Triggers a WHOIS and lets the WHOIS handler call whereis() on the hostname/IP.

1;
