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
use Try::Tiny;
use Socket;
use POSIX qw(strftime);
use List::Util qw(min);

our @EXPORT = qw(
    botNotice
    botPrivmsg
    botAction
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
    checkAntiFlood
    getIdChannelSet
    getIdChansetList
    evalAction
    mbWhereis_ctx
    displayBirthDate_ctx
    mbColors_ctx
    _yt_format_duration
    mbDbCheckNickHostname_ctx
    sethChannelsNicksOnChan
    gethChannelNicks
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
    _yt_badge
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
    getNickInfoWhois
    channelNicksRemove
    whereis
    getConsoleChan
    leet
    logBotAction
    versionCheck
);

sub get_user_from_message {
    my ($self, $message) = @_;

    my $fullmask = $message->prefix // '';
    my ($nick)   = $fullmask =~ /^([^!]+)/;
    $nick ||= '';

    $self->{logger}->log(3, "🔍 get_user_from_message() called with hostmask: '$fullmask'");

    my $sth = $self->{dbh}->prepare(q{
        SELECT u.*, uh.hostmask AS _matched_hostmask
        FROM USER u
        JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
    });
    unless ($sth->execute) {
        $self->{logger}->log(1, "❌ get_user_from_message() SQL Error: $DBI::errstr");
        return;
    }

    my $matched_user;
    while (my $row = $sth->fetchrow_hashref) {
        my @patterns = ($row->{_matched_hostmask} // '');
        foreach my $mask (@patterns) {
            my $orig_mask = $mask;
            $mask =~ s/^\s+|\s+$//g;
            my $regex = $mask; $regex =~ s/\./\\./g; $regex =~ s/\*/.*/g; $regex =~ s/\[/\\[/g; $regex =~ s/\]/\\]/g; $regex =~ s/\{/\\{/g; $regex =~ s/\}/\\}/g;

            if ($fullmask =~ /^$regex/) {
                require Mediabot::User;
                my $user = Mediabot::User->new($row);
                $user->load_level($self->{dbh});

                # DEBUG before autologin
                $self->_dbg_auth_snapshot('pre-auto', $user, $nick, $fullmask);

                # AUTOLOGIN (auth in DB)
                if ($user->can('maybe_autologin')) {
                    $user->maybe_autologin($self, $nick, $fullmask);
                }

                # DEBUG after autologin
                $self->_dbg_auth_snapshot('post-auto', $user, $nick, $fullmask);

                # Synchronise all caches if DB says auth=1
                $self->_ensure_logged_in_state($user, $nick, $fullmask);

                # DEBUG after synchronisation
                $self->_dbg_auth_snapshot('post-ensure', $user, $nick, $fullmask);

                $self->{logger}->log(3, "🎯 Matched user id=" . ($user->can('id') ? $user->id : $user->{id_user}) .
                                         ", nickname='" . $user->nickname .
                                         "', level='" . ($user->level_description // 'undef') . "'");

                $matched_user = $user;
                last;
            }
        }
        last if $matched_user;
    }

    $sth->finish;

    unless ($matched_user) {
        $self->{logger}->log(3, "🚫 No user matched hostmask '$fullmask'");
        return;
    }

    # DEBUG au retour
    $self->_dbg_auth_snapshot('return', $matched_user, $nick, $fullmask);

    return $matched_user;
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

# Get user autologin status
sub getIdUser(@) {
	my ($self,$sUserhandle) = @_;
	my $id_user = undef;
	my $sQuery = "SELECT id_user FROM USER WHERE nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserhandle) ) {
		$self->{logger}->log(1,"getIdUser() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_user = $ref->{'id_user'};
		}
	}
	$sth->finish;
	return $id_user;
}

# Get channel object by name
sub noticeConsoleChan {
    my ($self, $sMsg) = @_;

    $self->{logger}->log(4, "📢 noticeConsoleChan() called with message: $sMsg");

    my ($id_channel, $name, $chanmode, $key) = getConsoleChan($self);

    $self->{logger}->log(4, "ℹ️ getConsoleChan() returned: id_channel=$id_channel, name=" . 
        (defined $name ? $name : 'undef') . ", mode=" . 
        (defined $chanmode ? $chanmode : 'undef') . ", key=" . 
        (defined $key ? $key : 'undef'));

    if (defined $name && $name ne '') {
        $self->{logger}->log(4, "✅ Sending notice to console channel: $name");
        botNotice($self, $name, $sMsg);
    } else {
        $self->{logger}->log(1, "⚠️ No console channel defined! Run ./configure to set up the bot.");
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
        $self->{logger}->log(0, "logBot() SQL error: $DBI::errstr — Query: $sql");
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
sub botPrivmsg {
    my ($self, $sTo, $sMsg) = @_;

    return unless defined($sTo);

    my $eventtype = "public";

    if ($sTo =~ /^#/) {
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

        # Badword filtering
        my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel = BADWORDS.id_channel AND name = ?";
        my $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth->execute($sTo)) {
            $self->{logger}->log(1, "logBotAction() SQL Error : $DBI::errstr | Query : $sQuery");
        } else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $sBadwordDb = $ref->{badword};
                if (index(lc($sMsg), lc($sBadwordDb)) != -1) {
                    logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, "$sMsg (BADWORD : $sBadwordDb)");
                    noticeConsoleChan($self, "Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
                    $self->{logger}->log(3, "Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
                    $sth->finish;
                    return;
                }
            }
            logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, $sMsg);
        }
        $sth->finish;
    } else {
        # Private message
        $eventtype = "private";
        $self->{logger}->log(0, "-> *$sTo* $sMsg");
    }

    # Send actual message
    if (defined($sMsg) && $sMsg ne "") {
        # Forcer en UTF-8 et nettoyer les retours à la ligne
        if (utf8::is_utf8($sMsg)) {
            $sMsg = encode("UTF-8", $sMsg);
        }
        $sMsg =~ s/[\r\n]+/ /g;

        $self->{irc}->do_PRIVMSG(target => $sTo, text => $sMsg);
    } else {
        $self->{logger}->log(0, "botPrivmsg() ERROR no message specified to send to target");
    }
}



# Send a private message to a target (action)
sub botAction(@) {
	my ($self,$sTo,$sMsg) = @_;
	if (defined($sTo)) {
		my $eventtype = "public";
		if (substr($sTo, 0, 1) eq '#') {
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
				my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND name=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sTo) ) {
					$self->{logger}->log(1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					while (my $ref = $sth->fetchrow_hashref()) {
						my $sBadwordDb = $ref->{'badword'};
						my $sBadwordLc = lc $sBadwordDb;
						my $sMsgLc = lc $sMsg;
						if (index($sMsgLc, $sBadwordLc) != -1) {
							logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,"$sMsg (BADWORD : $sBadwordDb)");
							noticeConsoleChan($self,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$self->{logger}->log(3,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$sth->finish;
							return;
						}
					}
					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}
		}
		else {
			$eventtype = "private";
			$self->{logger}->log(0,"-> *$sTo* $sMsg");
		}
		if (defined($sMsg) && ($sMsg ne "")) {
			if (defined($sMsg) && utf8::is_utf8($sMsg)) {
				$sMsg = Encode::encode("UTF-8", $sMsg);
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $sMsg\1" );
			}
			else {
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $sMsg\1" );
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

use Encode qw(encode);

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

    # Nettoyer les retours à la ligne
    $text =~ s/[\r\n]+/ /g;

    # Encode en UTF-8 pour l'envoi IRC
    my $encoded_text = encode('UTF-8', $text);

    $self->{logger}->log(4, "[DEBUG] botNotice() sending encoded text length=" . length($encoded_text));

    # Envoi du NOTICE
    $self->{irc}->do_NOTICE(
        target => $target,
        text   => $encoded_text
    );

    # Log interne (version lisible)
    $self->{logger}->log(0, "-> -$target- $text");

    # Si c'est un channel NOTICE, log dans l'action log
    if ($target =~ /^#/) {
        $self->{logger}->log(4, "[DEBUG] botNotice() target is a channel, logging to action log");
        logBotAction($self, undef, "notice", $self->{irc}->nick_folded, $target, $text);
    }
}








# Join a channel with an optional key
sub joinChannel(@) {
	my ($self,$channel,$key) = @_;
	if (defined($key) && ($key ne "")) {
		$self->{logger}->log(0,"Trying to join $channel with key $key");
		$self->{irc}->send_message("JOIN", undef, ($channel,$key));
	}
	else {
		$self->{logger}->log(0,"Trying to join $channel");
		$self->{irc}->send_message("JOIN", undef, $channel);
	}
}

# Join channels with auto_join enabled, except console
sub checkUserLevel(@) {
	my ($self,$iUserLevel,$sLevelRequired) = @_;
	$self->{logger}->log(4,"isUserLevel() $iUserLevel vs $sLevelRequired");
	my $sQuery = "SELECT level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevelRequired)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $level = $ref->{'level'};
			if ( $iUserLevel <= $level ) {
				$sth->finish;
				return 1;
			}
			else {
				$sth->finish;
				return 0;
			}
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

# Count the number of users in the database
sub userCount(@) {
	my ($self) = @_;
	my $sQuery = "SELECT count(*) as nbUser FROM USER";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$self->{logger}->log(4,"userCount() " . $ref->{'nbUser'});
			my $nbUser = $ref->{'nbUser'};
			$sth->finish;
			return($nbUser);
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

sub getMessageHostmask(@) {
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
    my $pass_sql = defined $plain_password ? 'PASSWORD(?)' : 'NULL';

    my $sql = qq{
        INSERT INTO USER (creation_date, nickname, password, username, id_user_level, auth)
        VALUES (NOW(), ?, $pass_sql, ?, ?, 0)
    };

    my @bind = ($nickname);
    push @bind, $plain_password if defined $plain_password;
    push @bind, ($username, $level_id);

    my $sth = $dbh->prepare($sql);
    my $ok  = $sth->execute(@bind);
    $sth->finish;

    # Insert initial hostmask into USER_HOSTMASK if provided
    if ($ok && defined $hostmask && $hostmask ne '') {
        my $new_id = $dbh->last_insert_id(undef, undef, undef, undef);
        if ($new_id) {
            my $hm_sth = $dbh->prepare(
                "INSERT INTO USER_HOSTMASK (id_user, hostmask) VALUES (?, ?)"
            );
            $hm_sth->execute($new_id, $hostmask);
            $hm_sth->finish;
        }
    }

    unless ($ok) {
        $logger->log(1, "userAdd() INSERT failed: $DBI::errstr");
        return undef;
    }

    my $id = $dbh->last_insert_id(undef, undef, undef, undef);
    $logger->log(1, "✅ userAdd() created user '$nickname' (id_user=$id, level_id=$level_id)");
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
        $self->{irc}->send_message("PART", $channel, $reason);
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
sub checkUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user,$level) = @_;
	my $sQuery = "SELECT level FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $iLevel = $ref->{'level'};
			if ( $iLevel >= $level ) {
				$sth->finish;
				return 1;
			}
			else {
				$sth->finish;
				return 0;
			}
		}
		else {
			$sth->finish;
			return 0;
		}
	}	
}

# Join a channel (Administrator+ OR channel-level >= 450)
sub getIdUserChannelLevel(@) {
	my ($self,$sUserHandle,$sChannel) = @_;
	my $sQuery = "SELECT USER.id_user,USER_CHANNEL.level FROM CHANNEL,USER,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER.id_user=USER_CHANNEL.id_user AND USER.nickname=? AND CHANNEL.name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle,$sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user = $ref->{'id_user'};
			my $level = $ref->{'level'};
			$self->{logger}->log(4,"getIdUserChannelLevel() $id_user $level");
			$sth->finish;
			return ($id_user,$level);
		}
		else {
			$sth->finish;
			return (undef,undef);
		}
	}
}

# Give operator (+o) to a nick on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub getUserChannelLevelByName(@) {
	my ($self,$sChannel,$sHandle) = @_;
	my $iChannelUserLevel = 0;
	my $sQuery = "SELECT level FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND USER_CHANNEL.id_channel=CHANNEL.id_channel AND CHANNEL.name=? AND USER.nickname=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sHandle)) {
		$self->{logger}->log(1,"getUserChannelLevelByName() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$iChannelUserLevel = $ref->{'level'};
		}
		$self->{logger}->log(4,"getUserChannelLevelByName() iChannelUserLevel = $iChannelUserLevel");
	}
	$sth->finish;
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

	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		$sth->finish;
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
		$sth = $self->{dbh}->prepare($sQuery);

		unless ($sth->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			$sth->finish;
			return;
		}

		my $id_channel_flood = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
		$self->{logger}->log(4, "setChannelAntiFlood() AntiFlood record created, id_channel_flood : $id_channel_flood");

		$sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
		my $sth2 = $self->{dbh}->prepare($sQuery);

		unless ($sth2->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		} elsif (my $ref = $sth2->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $duration  = $ref->{'duration'};
			my $timetowait = $ref->{'timetowait'};

			botNotice($self, $sNick, "Chanset parameters for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
		} else {
			botNotice($self, $sNick, "Something funky happened, could not find record id_channel_flood : $id_channel_flood in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
		}

		$sth2->finish;
	}

	$sth->finish;
}

# Check the anti-flood status for a channel

sub getConsoleChan {
    my ($self) = @_;

    foreach my $chan (values %{ $self->{channels} }) {
        if ($chan->get_description eq 'console') {
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
sub logBotAction(@) {
    my ($self, $message, $eventtype, $sNick, $sChannel, $sText) = @_;

    my $sUserhost = "";
    $sUserhost = $message->prefix if defined $message;

    # Optional debug
    if (defined $sChannel) {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype chan = $sChannel nick = $sNick text = $sText");
    } else {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype nick = $sNick text = $sText");
    }

    $self->{logger}->log(5, "logBotAction() prefix=" . ($message->prefix // "?") . " command=" . ($message->command // "?")) if defined($self->{logger}->{debug}) && $self->{logger}->{debug} >= 5;

    my $id_channel;

    # Only look up channel ID if channel is defined (not for QUIT events)
    if (defined $sChannel) {
        my $sQuery = "SELECT id_channel FROM CHANNEL WHERE name = ?";
        my $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth->execute($sChannel)) {
            $self->{logger}->log(1, "logBotAction() SQL Error: $DBI::errstr Query: $sQuery");
            return;
        }

        my $ref = $sth->fetchrow_hashref();
        unless ($ref) {
            $self->{logger}->log(4, "logBotAction() channel not found: $sChannel");
            return;
        }

        $id_channel = $ref->{'id_channel'};
    }

    # Perform the actual insert — ts will be auto-filled by MariaDB
    my $insert_query = <<'SQL';
INSERT INTO CHANNEL_LOG (id_channel, event_type, nick, userhost, publictext)
VALUES (?, ?, ?, ?, ?)
SQL

    my $sth_insert = $self->{dbh}->prepare($insert_query);
    unless ($sth_insert->execute($id_channel, $eventtype, $sNick, $sUserhost, $sText)) {
        $self->{logger}->log(1, "logBotAction() SQL Insert Error: $DBI::errstr Query: $insert_query");
    } else {
        $self->{logger}->log(5, "logBotAction() inserted $eventtype event into CHANNEL_LOG");
    }
}


# Send a private message to a target
sub versionCheck {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $conf = $self->{conf};

    my ($local_version, $remote_version) = $self->getVersion();

    my $bot_name = $conf->get('main.MAIN_PROG_NAME');
    my $sMsg = "$bot_name version: $local_version";

    if ($remote_version ne "Undefined" && $remote_version ne $local_version) {
        $sMsg .= " (update available: $remote_version)";
    }

    $ctx->reply($sMsg);
    logBot($self, $ctx->message, undef, "version", undef);
}

# 🧙‍♂️ Handle private commands with centralized dispatching and full command set.
sub checkAntiFlood {
	my ($self, $sChannel) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "checkAntiFlood() unknown channel: $sChannel");
		return 0;
	}

	my $id_channel = $channel_obj->get_id;
	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		$sth->finish;
		return 0;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $nbmsg       = $ref->{'nbmsg'};
		my $nbmsg_max   = $ref->{'nbmsg_max'};
		my $duration    = $ref->{'duration'};
		my $first       = $ref->{'first'};
		my $latest      = $ref->{'latest'};
		my $timetowait  = $ref->{'timetowait'};
		my $notification = $ref->{'notification'};
		my $currentTs   = time;

		my $deltaDb = ($latest - $first);
		my $delta   = ($currentTs - $first);

		if ($nbmsg == 0) {
			$nbmsg++;
			$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=? WHERE id_channel=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($nbmsg, $currentTs, $currentTs, $id_channel)) {
				$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			} else {
				my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
				$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
				return 0;
			}
			$sth->finish if $sth;
		} else {
			if ($deltaDb <= $duration) {
				if ($nbmsg < $nbmsg_max) {
					$nbmsg++;
					$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, latest=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($nbmsg, $currentTs, $id_channel)) {
						$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
					} else {
						my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
						$self->{logger}->log(4, "checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max set latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds");
						return 0;
					}
					$sth->finish if $sth;
				} else {
					my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
					my $endTs = $latest + $timetowait;

					if ($currentTs > $endTs) {
						$nbmsg = 1;
						$self->{logger}->log(1, "checkAntiFlood() End of antiflood for channel $sChannel");
						$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=?, notification=? WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($nbmsg, $currentTs, $currentTs, 0, $id_channel)) {
							$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
						} else {
							my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
							$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
							return 0;
						}
						$sth->finish if $sth;
					} else {
						if (!$notification) {
							$sQuery = "UPDATE CHANNEL_FLOOD SET notification=? WHERE id_channel=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute(1, $id_channel)) {
								$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
							} else {
								$self->{logger}->log(4, "checkAntiFlood() Antiflood notification set to DB for $sChannel");
								noticeConsoleChan($self, "Anti flood activated on channel $sChannel $nbmsg messages in less than $duration seconds, waiting $timetowait seconds to deactivate");
							}
							$sth->finish if $sth;
						}
						$self->{logger}->log(4, "checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds endTs = $endTs " . ($endTs - $currentTs) . " seconds left");
						$self->{logger}->log(1, "checkAntiFlood() Antiflood is active for channel $sChannel wait " . ($endTs - $currentTs) . " seconds");
						return 1;
					}
				}
			} else {
				$nbmsg = 1;
				$self->{logger}->log(0, "checkAntiFlood() End of antiflood for channel $sChannel");
				$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=?, notification=? WHERE id_channel=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($nbmsg, $currentTs, $currentTs, 0, $id_channel)) {
					$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
				} else {
					my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
					$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
					return 0;
				}
				$sth->finish if $sth;
			}
		}
	} else {
		$self->{logger}->log(0, "checkAntiFlood() could not find record in CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
	}

	$sth->finish;
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

    $self->{logger}->log(0, "Reading local version from VERSION file...");

    # Read local VERSION file
    if (open my $fh, '<', 'VERSION') {
        chomp($local_version = <$fh>);
        close $fh;
        ($c_major, $c_minor, $c_type, $c_dev_info) = $self->getDetailedVersion($local_version);
    } else {
        $self->{logger}->log(0, "Unable to read local VERSION file.");
    }

    if (defined $c_major && defined $c_minor && defined $c_type) {
        my $suffix = $c_dev_info ? "($c_dev_info)" : '';
        $self->{logger}->log(0, "-> Mediabot $c_type version $c_major.$c_minor $suffix");
    } else {
        $self->{logger}->log(0, "-> Unknown local version format: $local_version");
    }

    # If we have a valid local version, try fetching the GitHub version
    if ($local_version ne "Undefined") {
        $self->{logger}->log(0, "Checking latest version from GitHub...");

        if (open my $gh, '-|', 'curl --connect-timeout 5 -f -s https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION') {
            chomp($remote_version = <$gh>);
            close $gh;
            ($r_major, $r_minor, $r_type, $r_dev_info) = $self->getDetailedVersion($remote_version);

            if (defined $r_major && defined $r_minor && defined $r_type) {
                my $suffix = $r_dev_info ? "($r_dev_info)" : '';
                $self->{logger}->log(0, "-> GitHub $r_type version $r_major.$r_minor $suffix");

                if ($local_version eq $remote_version) {
                    $self->{logger}->log(0, "Mediabot is up to date.");
                } else {
                    $self->{logger}->log(0, "Update available: $r_type version $r_major.$r_minor $suffix");
                }
            } else {
                $self->{logger}->log(0, "Unknown remote version format: $remote_version");
            }
        } else {
            $self->{logger}->log(0, "Failed to fetch version from GitHub.");
        }
    }

    $self->{main_prog_version} = $local_version;
    return ($local_version, $remote_version);
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

sub getIdChannelSet {
    my ($self, $sChannel, $id_chanset_list) = @_;

    # Basic sanity checks
    unless (defined $sChannel && $sChannel ne '') {
        $self->{logger}->log(2, "⚠️ getIdChannelSet() called without a channel name");
        return undef;
    }
    unless (defined $id_chanset_list && $id_chanset_list ne '') {
        $self->{logger}->log(2, "⚠️ getIdChannelSet() called without an id_chanset_list");
        return undef;
    }

    $self->{logger}->log(4, "🔍 getIdChannelSet() searching for chanset_list_id=$id_chanset_list in channel '$sChannel'");

    my $id_channel_set;
    my $sQuery = q{
        SELECT id_channel_set
        FROM CHANNEL_SET
        JOIN CHANNEL ON CHANNEL_SET.id_channel = CHANNEL.id_channel
        WHERE name = ? AND id_chanset_list = ?
    };

    my $sth = $self->{dbh}->prepare($sQuery);

    if (!$sth->execute($sChannel, $id_chanset_list)) {
        # SQL execution failed
        $self->{logger}->log(1, "❌ SQL Error in getIdChannelSet(): " . $DBI::errstr . " | Query: $sQuery");
    }
    else {
        if (my $ref = $sth->fetchrow_hashref()) {
            $id_channel_set = $ref->{id_channel_set};
            $self->{logger}->log(4, "✅ getIdChannelSet() found id_channel_set=$id_channel_set for channel '$sChannel' and chanset_list_id=$id_chanset_list");
        }
        else {
            $self->{logger}->log(4, "ℹ️ getIdChannelSet() no matching record for channel '$sChannel' and chanset_list_id=$id_chanset_list");
        }
    }

    $sth->finish;
    return $id_channel_set;
}

# Purge a channel from the bot: delete it and archive its data (Context-based) and Administrator only

sub getIdChansetList {
    my ($self, $sChansetValue) = @_;

    # Basic sanity check
    unless (defined $sChansetValue && $sChansetValue ne '') {
        $self->{logger}->log(2, "⚠️ getIdChansetList() called without a chanset value");
        return undef;
    }

    $self->{logger}->log(4, "🔍 getIdChansetList() looking up chanset: '$sChansetValue'");

    my $id_chanset_list;
    my $sQuery = "SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?";
    my $sth = $self->{dbh}->prepare($sQuery);

    if (!$sth->execute($sChansetValue)) {
        # Log SQL error
        $self->{logger}->log(1, "❌ SQL Error in getIdChansetList(): " . $DBI::errstr . " | Query: $sQuery");
    }
    else {
        if (my $ref = $sth->fetchrow_hashref()) {
            $id_chanset_list = $ref->{id_chanset_list};
            $self->{logger}->log(4, "✅ getIdChansetList() found id_chanset_list=$id_chanset_list for chanset '$sChansetValue'");
        }
        else {
            $self->{logger}->log(4, "ℹ️ getIdChansetList() no result found for chanset '$sChansetValue'");
        }
    }

    $sth->finish;
    return $id_chanset_list;
}


# Retrieve the ID of a channel set from CHANNEL_SET table for a given channel and chanset list ID

sub evalAction(@) {
	my ($self,$message,$sNick,$sChannel,$sCommand,$actionDo,@tArgs) = @_;
	$self->{logger}->log(4,"evalAction() $sCommand / $actionDo");
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
	unless ( $actionDo =~ /%b/ ) {
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
    my @args;
    if (ref($ctx->args) eq 'ARRAY') {
        @args = @{ $ctx->args };
    } elsif (defined $ctx->args) {
        @args = ($ctx->args);
    }

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

sub _yt_format_duration {
    my ($iso) = @_;
    return '' unless defined $iso && $iso =~ /^PT/i;

    my ($h,$m,$s) = (0,0,0);
    $h = $1 if $iso =~ /(\d+)H/;
    $m = $1 if $iso =~ /(\d+)M/;
    $s = $1 if $iso =~ /(\d+)S/;

    my @out;
    push @out, sprintf("%dh", $h) if $h;
    push @out, sprintf("%02dm", $m) if ($h || $m);
    push @out, sprintf("%02ds", $s) if ($h || $m || $s);

    # if no hours and minutes, show seconds even if zero
    my $txt = join(' ', @out);
    $txt =~ s/^00m\s+// if !$h; # “00m 12s” -> “12s”
    $txt =~ s/\b00s$// if ($h || $m) && $s == 0; # optionnel: “3m 00s” -> “3m”
    $txt =~ s/\s+$//;

    return $txt;
}

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

    # Optimization: use '=' when caller doesn't provide wildcards
    my $use_like = ($search =~ /[%_]/) ? 1 : 0;

    my $sql = $use_like ? <<'SQL' : <<'SQL';
SELECT userhost, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE nick LIKE ?
GROUP BY userhost
ORDER BY hits DESC
LIMIT 10
SQL
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

    my $resp;
    if (@rows) {
        my $list = join(' | ', map { "$_->[0] ($_->[1])" } @rows);
        $resp = "Hostmasks for $search: $list";
    } else {
        $resp = "No result found for nick: $search";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
    }

    logBot($self, $ctx->message, $dest_chan, "checknick", $search);
    return 1;
}

# greet [#channel] <nick>
# If called in private: greet #channel <nick>

sub sethChannelsNicksOnChan(@) {
	my ($self,$sChannel,@tNicklist) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	@{$hChannelsNicks{$sChannel}} = @tNicklist;
	%{$self->{hChannelsNicks}} = %hChannelsNicks;
}


sub gethChannelNicks(@) {
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

sub getWhoisVar(@) {
	my $self = shift;
	return $self->{WHOIS_VARS};
}

# access #channel <nickhandle>
# access #channel =<nick>

sub gethChannelsNicksEndOnChan(@) {
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
  AND userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 20
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx(): failed to prepare SQL");
        return;
    }

    my $mask = '%@' . $host;

    unless ($sth->execute($mask)) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx() SQL Error: $DBI::errstr Query: $sql");
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

    my $resp;
    if (@rows) {
        my $list = join(' | ', map { "$_->[0] ($_->[1])" } @rows);
        $resp = "Nicks for host $host: $list";
    } else {
        $resp = "No result found for hostname $host.";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
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

    # Build one-line summary with truncation
    my @talkers = map { "$_->[0] ($_->[1])" } @rows;
    my $prefix  = "Top talkers last hour on $target: ";

    my $max_len = 360; # conservative for NOTICE/PRIVMSG payload
    my $line = $prefix;
    for my $t (@talkers) {
        my $candidate = ($line eq $prefix) ? ($line . $t) : ($line . ", " . $t);
        if (length($candidate) > $max_len) {
            $line .= "..." if length($line) + 3 <= $max_len;
            last;
        }
        $line = $candidate;
    }

    $out_chan ? botPrivmsg($self, $out_chan, $line) : botNotice($self, $nick, $line);

    # Optional gentle warning, but only if we are already speaking in-channel
    if ($out_chan && $rows[0][1] >= 25) {
        botPrivmsg($self, $out_chan, "$rows[0][0]: please slow down a bit — you're flooding the channel.");
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
    #   - join with '%' so "foo bar" -> "%foo%bar%"
    #   - bind as param instead of interpolating raw
    my @tokens = grep { length } split(/\s+/, $text);
    my $pattern = '%' . join('%', @tokens) . '%';

    # 1) Count matching MP3s
    my $sql_count = "SELECT COUNT(*) AS nbMp3 FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ?";
    $self->{logger}->log(4, "mp3_ctx(): $sql_count (pattern=$pattern)");
    my $sth = $self->{dbh}->prepare($sql_count);

    my $nbMp3 = 0;
    unless ($sth && $sth->execute($pattern)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_count");
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
                    "WHERE CONCAT(artist, ' ', title) LIKE ? LIMIT 1";
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
                           "FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ? LIMIT 10";
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
                $sth2->finish;

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

    return;
}

# Execute a shell command and return (up to) the last 3 lines.
# Context-based version, restricted to Owner-level users.

sub isIgnored(@) {
	my ($self,$message,$sChannel,$sNick,$sMsg)	= @_;
	my $sCheckQuery = "SELECT * FROM IGNORES WHERE id_channel=0";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		$self->{logger}->log(1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = $ref->{'hostmask'};
			$sHostmask =~ s/\./\\./g;
			$sHostmask =~ s/\*/.*/g;
			$sHostmask =~ s/\[/\\[/g;
			$sHostmask =~ s/\]/\\]/g;
			$sHostmask =~ s/\{/\\{/g;
			$sHostmask =~ s/\}/\\}/g;
			if ( $message->prefix =~ /^$sHostmask/ ) {
				$self->{logger}->log(4,"isIgnored() (allchans/private) $sHostmask matches " . $message->prefix);
				$self->{logger}->log(0,"[IGNORED] " . $ref->{'hostmask'} . " (allchans/private) " . ((substr($sChannel,0,1) eq '#') ? "$sChannel:" : "") . "<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	$sCheckQuery = "SELECT * FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
	$sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = $ref->{'hostmask'};
			$sHostmask =~ s/\./\\./g;
			$sHostmask =~ s/\*/.*/g;
			$sHostmask =~ s/\[/\\[/g;
			$sHostmask =~ s/\]/\\]/g;
			$sHostmask =~ s/\{/\\{/g;
			$sHostmask =~ s/\}/\\}/g;
			if ( $message->prefix =~ /^$sHostmask/ ) {
				$self->{logger}->log(4,"isIgnored() $sHostmask matches " . $message->prefix);
				$self->{logger}->log(0,"[IGNORED] " . $ref->{'hostmask'} . " $sChannel:<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	return 0;
}

# List ignores

sub _yt_badge {
    my $plain = "[YouTube]";
    return $plain unless eval { String::IRC->can('new') };

    my $b = String::IRC->new('[')->bold;
    $b   .= String::IRC->new('You')->bold;                  # neutre
    $b   .= String::IRC->new('Tube')->bold->red;            # rouge (sans fond)
    $b   .= String::IRC->new(']')->bold;
    return "$b";
}

# Get the current song from the radio stream

sub sethChannelsNicksEndOnChan(@) {
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

sub gethChannelsNicksOnChan(@) {
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
    my $text = join(' ', @{ $ctx->args // [] });

    return unless length $text;

    botPrivmsg($self, $chan, $text);
}

# Context-based status (Master only)

sub getRandomNick(@) {
	my ($self,$sChannel) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	my @tChannelNicks = @{$hChannelsNicks{$sChannel}};
	my $sRandomNick = $tChannelNicks[rand @tChannelNicks];
	return $sRandomNick;
}


sub resolve_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = @{ $ctx->args // [] };

    # --- Syntax check ---
    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: resolve <hostname|IP>");
        return;
    }

    my $input = $args[0];

    # --- Case 1: Input is IPv4 → reverse DNS ---
    if ($input =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {

        my $packed = inet_aton($input);
        unless ($packed) {
            botPrivmsg($self, $channel, "($nick) Invalid IPv4 format: $input");
            return;
        }

        my $host = gethostbyaddr($packed, AF_INET);
        if ($host) {
            botPrivmsg($self, $channel, "($nick) Reverse DNS → $input = $host");
        } else {
            botPrivmsg($self, $channel, "($nick) No reverse DNS entry for $input");
        }

        logBot($self, $ctx->message, $channel, "resolve", $input);
        return;
    }

    # --- Case 2: hostname → IPv4 via open() pipe (non-blocking read) ---
    # We spawn a child perl process that does the blocking gethostbyname lookup
    # and sends the result back via a pipe. The parent reads with a short timeout
    # so the IRC event loop is not blocked indefinitely.
    my $msg = $ctx->message;

    my $child_pid = open(my $pipe, '-|', $^X, '-e',
        'use Socket; my $h=$ARGV[0]; my @a=gethostbyname($h); ' .
        'print @a ? join(",", map{Socket::inet_ntoa($_)}@a[4..$#a]) : ""',
        $input,
    );

    unless (defined $child_pid) {
        botPrivmsg($self, $channel, "($nick) resolve: could not spawn lookup process");
        return;
    }

    # Set pipe to non-blocking
    use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
    my $flags = fcntl($pipe, F_GETFL, 0) || 0;
    fcntl($pipe, F_SETFL, $flags | O_NONBLOCK);

    # Schedule result collection after 3s via timer
    my $loop = $self->getLoop;
    $loop->add(IO::Async::Timer::Countdown->new(
        delay     => 3,
        on_expire => sub {
            my $result = '';
            sysread($pipe, $result, 4096);
            close($pipe);
            waitpid($child_pid, 0) if $child_pid;

            my @ips = grep { /^\d/ } split /,/, ($result // '');
            if (@ips) {
                botPrivmsg($self, $channel, "($nick) $input → " . join(", ", @ips));
            } else {
                botPrivmsg($self, $channel, "($nick) Hostname could not be resolved: $input");
            }
            eval { logBot($self, $msg, $channel, "resolve", $input) };
        },
    )->start);

    return 1;
}

# set tmdb_lang for a channel (Administrator+ or channel owner)

sub _tz_exists {
    my ($self, $tz) = @_;
    my $sth = $self->{dbh}->prepare("SELECT tz FROM TIMEZONE WHERE tz LIKE ?");
    unless ($sth->execute($tz)) { $sth->finish; return undef; }
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

sub sethChannelNicks(@) {
	my ($self,$phChannelsNicks) = @_;
	%{$self->{hChannelsNicks}} = %$phChannelsNicks;
}


sub getLevel(@) {
	my ($self,$sLevel) = @_;
	my $sQuery = "SELECT level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $level = $ref->{'level'};
			$sth->finish;
			return $level;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}


sub getNickInfoWhois(@) {
	my ($self,$sWhoisHostmask) = @_;
	my $iMatchingUserId = undef;
	my $iMatchingUserLevel = undef;
	my $iMatchingUserLevelDesc = undef;
	my $iMatchingUserAuth = undef;
	my $sMatchingUserHandle = undef;
	my $sMatchingUserPasswd = undef;
	my $sMatchingUserInfo1 = undef;
	my $sMatchingUserInfo2 = undef;
	
	my $sCheckQuery = "SELECT * FROM USER";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		$self->{logger}->log(1,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my $hm_s = $self->{dbh}->prepare("SELECT hostmask FROM USER_HOSTMASK WHERE id_user=? ORDER BY id_user_hostmask");
			$hm_s->execute($ref->{id_user});
			my @tHostmasks;
			while (my $hr = $hm_s->fetchrow_hashref) { push @tHostmasks, $hr->{hostmask} }
			$hm_s->finish;
			foreach my $sHostmask (@tHostmasks) {
				$self->{logger}->log(4,"getNickInfoWhois() Checking hostmask : " . $sHostmask);
				$sHostmask =~ s/\./\\./g;
				$sHostmask =~ s/\*/.*/g;
				if ( $sWhoisHostmask =~ /^$sHostmask/ ) {
					$self->{logger}->log(4,"getNickInfoWhois() $sHostmask matches " . $sWhoisHostmask);
					$sMatchingUserHandle = $ref->{'nickname'};
					if (defined($ref->{'password'})) {
						$sMatchingUserPasswd = $ref->{'password'};
					}
					$iMatchingUserId = $ref->{'id_user'};
					my $iMatchingUserLevelId = $ref->{'id_user_level'};
					my $sGetLevelQuery = "SELECT * FROM USER_LEVEL WHERE id_user_level=?";
					my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);
	        unless ($sth2->execute($iMatchingUserLevelId)) {
          				$self->{logger}->log(0,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sGetLevelQuery);
  				}
  				else {
						while (my $ref2 = $sth2->fetchrow_hashref()) {
							$iMatchingUserLevel = $ref2->{'level'};
							$iMatchingUserLevelDesc = $ref2->{'description'};
						}
					}
					$iMatchingUserAuth = $ref->{'auth'};
					if (defined($ref->{'info1'})) {
						$sMatchingUserInfo1 = $ref->{'info1'};
					}
					if (defined($ref->{'info2'})) {
						$sMatchingUserInfo2 = $ref->{'info2'};
					}
					$sth2->finish;
				}
			}
		}
	}
	$sth->finish;
	if (defined($iMatchingUserId)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserId : $iMatchingUserId");
	}
	else {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserId is undefined with this host : " . $sWhoisHostmask);
		return (undef,undef,undef,undef,undef,undef,undef);
	}
	if (defined($iMatchingUserLevel)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserLevel : $iMatchingUserLevel");
	}
	if (defined($iMatchingUserLevelDesc)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserLevelDesc : $iMatchingUserLevelDesc");
	}
	if (defined($iMatchingUserAuth)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserAuth : $iMatchingUserAuth");
	}
	if (defined($sMatchingUserHandle)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserHandle : $sMatchingUserHandle");
	}
	if (defined($sMatchingUserPasswd)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserPasswd : $sMatchingUserPasswd");
	}
	if (defined($sMatchingUserInfo1)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserInfo1 : $sMatchingUserInfo1");
	}
	if (defined($sMatchingUserInfo2)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserInfo2 : $sMatchingUserInfo2");
	}
	return ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2);
}

# auth => sub { userAuthNick_ctx($ctx) },

# /auth <nick> — Triggers a WHOIS to identify if a user is known/authenticated

sub channelNicksRemove(@) {
	my ($self,$sChannel,$sNick) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
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


sub whereis(@) {
	my ($self,$sHostname) = @_;
	my $userIP;
	$self->{logger}->log(4,"whereis() $sHostname");
	if ( $sHostname =~ /users.undernet.org$/ ) {
		return "on an Undernet hidden host ;)";
	}
	unless ( $sHostname =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ ) {
		my $packed_ip = gethostbyname("$sHostname");
		if (defined $packed_ip) {
			$userIP = inet_ntoa($packed_ip);
		}
	}
	else {
		$userIP = $sHostname;
	}
	unless (defined($userIP) && ($userIP =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)) {
		return "N/A";
	}
	my $fh_whereis;
	unless (open $fh_whereis, "-|", "curl", "--connect-timeout", "3", "-f", "-s",
	        "https://api.country.is/$userIP") {
		return "N/A";
	}
	my $line;
	if (defined($line=<$fh_whereis>)) {
		close $fh_whereis;
		chomp($line);
		my $json = decode_json $line;
		my $country = $json->{'country'};
		if (defined($country)) {
			return $country;
		}
		else {
			return undef;
		}
	}
	else {
		return "N/A";
	}	
}

# whereis <nick>
# Triggers a WHOIS and lets the WHOIS handler call whereis() on the hostname/IP.

1;
