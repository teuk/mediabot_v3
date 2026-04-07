package Mediabot::UserCommands;

# =============================================================================
# Mediabot::UserCommands
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
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

sub dbLogoutUsers(@) {
	my ($self) = shift;
	my $LOG = $self->{LOG};
	my $dbh = $self->{dbh};
	my $sLogoutQuery = "UPDATE USER SET auth=0 WHERE auth=1";
	my $sth = $dbh->prepare($sLogoutQuery);
	unless ($sth->execute) {
		$self->{logger}->log(0,"dbLogoutUsers() SQL Error : " . $DBI::errstr . "(" . $DBI::err . ") Query : " . $sLogoutQuery);
	}
	else {	
		$self->{logger}->log(1,"Logged out all users");
	}
}

# Set server attribute
sub getUserName(@) {
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
        $self->{logger}->log(4, $sql);
        my $sth = $self->{dbh}->prepare($sql);

        if ($sth->execute($sChannel, $user->id)) {
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
        } else {
            $self->{logger}->log(1, "userOnJoin() SQL Error: " . $DBI::errstr . " Query: $sql");
        }
        $sth->finish;
    }

    # Now check if the channel has a default notice to send on join
    my $sql_channel = "SELECT id_channel, notice, id_user_level FROM CHANNEL WHERE name = ?";
    $self->{logger}->log(4, $sql_channel);
    my $sth = $self->{dbh}->prepare($sql_channel);

    if ($sth->execute($sChannel)) {
        if (my $ref = $sth->fetchrow_hashref()) {
            my $notice = $ref->{notice};
            if (defined $notice && $notice ne '') {
                botNotice($self, $sNick, $notice);
            }
        }
    } else {
        $self->{logger}->log(1, "userOnJoin() SQL Error: " . $DBI::errstr . " Query: $sql_channel");
    }

    $sth->finish;
}

# 🧙‍♂️ mbCommandPublic: The Sorting Hat of Mediabot – routes every incantation to the proper spell
sub getIdUserLevel(@) {
	my ($self,$sLevel) = @_;
	my $sQuery = "SELECT id_user_level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user_level = $ref->{'id_user_level'};
			$sth->finish;
			return $id_user_level;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

sub getLevelUser(@) {
	my ($self,$sUserHandle) = @_;
	my $sQuery = "SELECT USER_LEVEL.level FROM USER JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level WHERE USER.nickname LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle)) {
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
        ORDER BY USER_LEVEL.level
    };

    my $sth = $self->{dbh}->prepare($query);
    unless ($sth->execute) {
        $self->{logger}->log(1, "userCstat_ctx() SQL Error: $DBI::errstr");
        botNotice($self, $nick, 'Internal error (DB query failed).');
        return;
    }

    my @entries;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $u = $ref->{nickname}    // '';
        my $d = $ref->{description} // '';
        push @entries, "$u ($d)" if $u ne '';
    }
    $sth->finish;

    my $line = 'Authenticated users: ' . join(' ', @entries);

    # Keep it one line; truncate if too long
    my $max = 380;  # keep headroom under IRC 512 bytes
    if (length($line) > $max) {
        $line = substr($line, 0, $max - 3) . '...';
    }

    botNotice($self, $nick, $line);
    logBot($self, $ctx->message, undef, 'cstat', undef);
}

# Context-based: Add a new user with a specified hostmask and optional level
sub addUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = @{ $ctx->args // [] };

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

sub getUserLevelDesc(@) {
	my ($self,$level) = @_;
	my $sQuery = "SELECT description FROM USER_LEVEL WHERE level=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($level)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sDescription = $ref->{'description'};
			$sth->finish;
			return $sDescription;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
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

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Master privilege
    $ctx->require_level('Master') or return;

    # Expected: userinfo <username>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target = $args[0] // '';
    if ($target eq '') {
        botNotice($self, $nick, "Syntax: userinfo <username>");
        return;
    }

    my $sQuery = q{
        SELECT *
        FROM USER JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level
        WHERE USER.nickname LIKE ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target)) {
        $self->{logger}->log(1, "userInfo_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_user     = $ref->{id_user}        // '?';
        my $nickname    = $ref->{nickname}       // '?';
        my $created     = $ref->{creation_date}  // 'N/A';
        my $last_login  = $ref->{last_login}     // 'never';
        # Fetch hostmasks from USER_HOSTMASK
        my $hm_sth = $self->{dbh}->prepare(
            "SELECT GROUP_CONCAT(hostmask ORDER BY id_user_hostmask SEPARATOR ', ') AS hm FROM USER_HOSTMASK WHERE id_user=?"
        );
        my $hostmasks = 'none';
        if ($hm_sth && $hm_sth->execute($id_user)) {
            my $hm_ref = $hm_sth->fetchrow_hashref;
            $hostmasks = $hm_ref->{hm} // 'none';
            $hm_sth->finish;
        }
        my $password    = $ref->{password};
        my $info1       = $ref->{info1}          // 'N/A';
        my $info2       = $ref->{info2}          // 'N/A';
        my $desc        = $ref->{description}    // 'Unknown';
        my $auth        = $ref->{auth}           // 0;
        my $username    = $ref->{username}       // 'N/A';

        my $sAuthStatus = $auth ? "logged in" : "not logged in";
        my $sPassStatus = (defined($password) && $password ne '') ? "Password set" : "Password is not set";
        my $sAutoLogin  = ($username eq "#AUTOLOGIN#") ? "ON" : "OFF";

        botNotice($self, $nick, "User: $nickname (Id: $id_user - $desc)");
        botNotice($self, $nick, "Created: $created | Last login: $last_login");
        botNotice($self, $nick, "$sPassStatus | Status: $sAuthStatus | AUTOLOGIN: $sAutoLogin");
        botNotice($self, $nick, "Hostmasks: $hostmasks");
        botNotice($self, $nick, "Info: $info1 | $info2");
    } else {
        botNotice($self, $nick, "User '$target' does not exist.");
    }

    my $sNoticeMsg = $ctx->message->prefix . " userinfo on $target";
    $self->{logger}->log(0, $sNoticeMsg);
    noticeConsoleChan($self, $sNoticeMsg);
    logBot($self, $ctx->message, undef, "userinfo", $sNoticeMsg);

    $sth->finish if $sth;
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
sub getUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user) = @_;
	my $sQuery = "SELECT USER_CHANNEL.level FROM CHANNEL JOIN USER_CHANNEL ON USER_CHANNEL.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ? AND USER_CHANNEL.id_user = ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $iLevel = $ref->{'level'};
			$sth->finish;
			return $iLevel;
		}
		else {
			$sth->finish;
			return 0;
		}
	}	
}

# Delete a user from a channel
# Requires: authenticated + (Administrator+ OR channel-level >= 400)
sub userModinfoSyntax(@) {
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
    } else {
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
        $self->{logger}->log(1, "userModinfo_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Minimal syntax: <type> <handle> <value...>
    unless (defined $args[0] && $args[0] ne '' && defined $args[1] && $args[1] ne '' && defined $args[2] && $args[2] ne '') {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }

    my $type              = lc($args[0]);
    my $target_handle     = $args[1];

    # Admin check via User.pm hierarchy
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Determine issuer handle (best effort)
    my $issuer_handle = eval { $user->handle } || eval { $user->nickname } || $nick;

    # Fetch issuer channel level + target channel level + target id_user (no ambiguous SQL)
    my ($issuer_level, $target_level, $id_user_target) = (0, 0, undef);

    eval {
        my $sth_issuer = $self->{dbh}->prepare(q{
            SELECT uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        });
        $sth_issuer->execute($id_channel, $issuer_handle);
        ($issuer_level) = $sth_issuer->fetchrow_array;
        $issuer_level ||= 0;
        $sth_issuer->finish;

        my $sth_target = $self->{dbh}->prepare(q{
            SELECT u.id_user, uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        });
        $sth_target->execute($id_channel, $target_handle);
        ($id_user_target, $target_level) = $sth_target->fetchrow_array;
        $target_level ||= 0;
        $sth_target->finish;

        1;
    } or do {
        $self->{logger}->log(1, "userModinfo_ctx(): DB lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

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
    } elsif ($type eq 'greet') {
        $has_access = ($issuer_level >= 1) ? 1 : 0;
    } else {
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

    # Prevent modifying a user with equal/higher access than caller (unless admin)
    # For greet: allow if issuer_level > 0 (matches your original intent)
    unless (
        $is_admin
        || ($issuer_level > $target_level)
        || ($type eq 'greet' && $issuer_level > 0)
    ) {
        botNotice($self, $nick, "Cannot modify a user with equal or higher access than your own.");
        return;
    }

    my $sth;

    # SWITCH
    if ($type eq 'automode') {

        my $mode = uc($args[2] // '');
        unless ($mode =~ /^(OP|VOICE|NONE)$/i) {
            userModinfoSyntax($self, $ctx->message, $nick, @args);
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($mode, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set automode $mode on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;

    } elsif ($type eq 'greet') {

        # Keep your extra restriction:
        # If caller < 400, they can only set THEIR OWN greet unless admin
        if (!$is_admin && $issuer_level < 400 && lc($target_handle) ne lc($issuer_handle)) {
            botNotice($self, $nick, "Your level does not allow you to perform this command.");
            return;
        }

        # greet text is everything after: greet <handle> ...
        my @greet_parts = @args[ 2 .. $#args ];
        my $greet_msg = (scalar(@greet_parts) == 1 && defined($greet_parts[0]) && $greet_parts[0] =~ /none/i)
            ? undef
            : join(" ", @greet_parts);

        my $query = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($greet_msg, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set greet (" . (defined $greet_msg ? $greet_msg : "none") . ") on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", ("greet", $target_handle, @greet_parts));
        return $id_channel;

    } elsif ($type eq 'level') {

        my $new_level = $args[2];
        unless (defined($new_level) && $new_level =~ /^\d+$/ && $new_level <= 500) {
            botNotice($self, $nick, "Cannot set user access higher than 500.");
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($new_level, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set level $new_level on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;

    } else {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }
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
  AND CHANNEL_LOG.nick LIKE ?
GROUP BY publictext
ORDER BY hit DESC
LIMIT 30
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($chan, $target_nick)) {
        $self->{logger}->log(1, "userTopSay_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $response  = "$target_nick: ";
    my $fullLine  = $response;
    my $maxLength = 300;
    my $i         = 0;

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
            ? String::IRC->new("$text ($count) ")->bold
            : "$text ($count) ";

        my $new_len = length($fullLine) + length($entry);
        last if $new_len >= $maxLength;

        $response .= $entry;
        $fullLine .= $entry;
        $i++;
    }

    if ($i > 0) {
        if ($is_private) {
            botNotice($self, $nick, $response);
        } else {
            botPrivmsg($self, $dest_chan, $response);
        }
    } else {
        my $msg = "No results.";
        if ($is_private) {
            botNotice($self, $nick, $msg);
        } else {
            botPrivmsg($self, $dest_chan, $msg);
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

    my $targetNick = shift @args;

    # Channel context:
    # - If caller gave a #channel as next arg => use it for part checks
    # - Else if command issued in a channel => use ctx->channel
    # - Else (private) => no channel part check unless provided
    my $chan_for_part;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan_for_part = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan_for_part = ($cc =~ /^#/) ? $cc : undef;
    }

    # Output destination
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel; # only used when not private

    # Resolve id_channel if we want a part check
    my $id_channel = 0;
    if (defined $chan_for_part && $chan_for_part =~ /^#/) {
        my $channel_obj = $self->{channels}{$chan_for_part} || $self->{channels}{lc($chan_for_part)};
        $id_channel = eval { $channel_obj->get_id } || 0;
        # If channel not known in-memory, we just skip the part check (no noisy SQL)
        $id_channel = 0 unless $id_channel;
    }

    # --- Latest QUIT (global) ---
    my $quit;
    my $sql_quit = <<'SQL';
SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
FROM CHANNEL_LOG
WHERE nick = ? AND event_type = 'quit'
ORDER BY ts DESC
LIMIT 1
SQL

    my $sth_quit = $self->{dbh}->prepare($sql_quit);
    if ($sth_quit && $sth_quit->execute($targetNick)) {
        if (my $r = $sth_quit->fetchrow_hashref()) {
            $quit = {
                ts   => $r->{ts},
                uts  => $r->{uts}  // 0,
                host => $r->{userhost}   // '',
                text => $r->{publictext} // '',
            };
        }
    } else {
        $self->{logger}->log(1, "mbSeen_ctx() SQL quit error: $DBI::errstr");
    }
    $sth_quit->finish if $sth_quit;

    # --- Latest PART (channel-scoped, only if we have an id_channel) ---
    my $part;
    if ($id_channel) {
        my $sql_part = <<'SQL';
SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
FROM CHANNEL_LOG
WHERE id_channel = ? AND nick = ? AND event_type = 'part'
ORDER BY ts DESC
LIMIT 1
SQL
        my $sth_part = $self->{dbh}->prepare($sql_part);
        if ($sth_part && $sth_part->execute($id_channel, $targetNick)) {
            if (my $r = $sth_part->fetchrow_hashref()) {
                $part = {
                    ts   => $r->{ts},
                    uts  => $r->{uts}  // 0,
                    host => $r->{userhost}   // '',
                    text => $r->{publictext} // '',
                };
            }
        } else {
            $self->{logger}->log(1, "mbSeen_ctx() SQL part error: $DBI::errstr");
        }
        $sth_part->finish if $sth_part;
    }

    # Helper: prettify host (strip "nick!")
    my $fmt_host = sub {
        my ($h) = @_;
        $h //= '';
        $h =~ s/^.*!//;
        return $h;
    };

    # Decide what to report
    my $msg;
    my $quit_uts = $quit ? ($quit->{uts} // 0) : 0;
    my $part_uts = $part ? ($part->{uts} // 0) : 0;

    if (!$quit_uts && !$part_uts) {
        $msg = "I don't remember seeing nick $targetNick.";
    }
    elsif ($part_uts && $part_uts >= $quit_uts && $chan_for_part) {
        my $host = $fmt_host->($part->{host});
        my $txt  = $part->{text} // '';
        $msg = "$targetNick ($host) was last seen parting $chan_for_part : $part->{ts}" . ($txt ne '' ? " ($txt)" : "");
    }
    else {
        my $host = $fmt_host->($quit->{host});
        my $txt  = $quit->{text} // '';
        $msg = "$targetNick ($host) was last seen quitting : $quit->{ts}" . ($txt ne '' ? " ($txt)" : "");
    }

    # Send output
    if ($is_private) {
        botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "seen", $targetNick);
    } else {
        botPrivmsg($self, $dest_chan, $msg);
        logBot($self, $ctx->message, $dest_chan, "seen", $targetNick);
    }

    return 1;
}

# popcmd — show top 20 public commands (by hits) created by a given user
# Context-based migration:
# - Uses ctx for bot/nick/channel/message/args
# - Better display: one-line, truncated with "..."
# - Sends to channel if invoked in-channel, otherwise NOTICE
sub _get_user_tz {
    my ($self, $nick) = @_;
    my $sth = $self->{dbh}->prepare("SELECT tz FROM USER WHERE nickname LIKE ?");
    unless ($sth->execute($nick)) { $sth->finish; return undef; }
    my $ref = $sth->fetchrow_hashref();
    $sth->finish;
    return $ref ? $ref->{tz} : undef;
}

# Set timezone for a user
sub _set_user_tz {
    my ($self, $nick, $tz) = @_;
    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=? WHERE nickname LIKE ?");
    my $ok = $sth->execute($tz, $nick);
    $sth->finish;
    return $ok;
}

# Clear timezone for a user
sub _del_user_tz {
    my ($self, $nick) = @_;
    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=NULL WHERE nickname LIKE ?");
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

        my $target_level   = getLevel($self, $target_level_str);
        my $current_level  = getLevelUser($self, $target_nick);

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
            } else {
                if (setUserLevel($self, $target_nick, getIdUserLevel($self, $target_level_str))) {
                    botNotice($self, $nick, "User $target_nick is now a global $target_level_str.");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                } else {
                    botNotice($self, $nick, "Could not set $target_nick as global $target_level_str.");
                }
            }
        } else {
            my $target_desc = getUserLevelDesc($self, $current_level);
            if ($target_level == $current_level) {
                botNotice($self, $nick, "You can't set $target_nick to $target_level_str: they're already $target_desc.");
            } else {
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

        my $sth;

        if ($arg eq 'on') {
            $sth = $self->{dbh}->prepare("SELECT 1 FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
            $sth->execute($target_nick);
            my $already_on = $sth->fetchrow_hashref();
            $sth->finish;

            if ($already_on) {
                botNotice($self, $nick, "Autologin is already ON for $target_nick");
            } else {
                $sth = $self->{dbh}->prepare("UPDATE USER SET username = '#AUTOLOGIN#' WHERE nickname = ?");
                if ($sth->execute($target_nick)) {
                    botNotice($self, $nick, "Set autologin ON for $target_nick");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                }
            }
        } else {    # off
            $sth = $self->{dbh}->prepare("SELECT 1 FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
            $sth->execute($target_nick);
            my $is_on = $sth->fetchrow_hashref();
            $sth->finish;

            if ($is_on) {
                $sth = $self->{dbh}->prepare("UPDATE USER SET username = NULL WHERE nickname = ?");
                if ($sth->execute($target_nick)) {
                    botNotice($self, $nick, "Set autologin OFF for $target_nick");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                }
            } else {
                botNotice($self, $nick, "Autologin is already OFF for $target_nick");
            }
        }

        $sth->finish if $sth;
        return;
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

        my $sth = $self->{dbh}->prepare("SELECT 1 FROM USER WHERE nickname = ? AND fortniteid = ?");
        $sth->execute($target_nick, $fortniteid);
        my $already_set = $sth->fetchrow_hashref();
        $sth->finish;

        if ($already_set) {
            botNotice($self, $nick, "fortniteid is already $fortniteid for $target_nick");
        } else {
            $sth = $self->{dbh}->prepare("UPDATE USER SET fortniteid = ? WHERE nickname = ?");
            if ($sth->execute($fortniteid, $target_nick)) {
                botNotice($self, $nick, "Set fortniteid $fortniteid for $target_nick");
                logBot($self, $message, $channel, "fortniteid", @original_args_for_log);
            }
        }

        $sth->finish;
        return;
    }

    # =========================================================
    # Unknown subcommand
    # =========================================================
    else {
        botNotice($self, $nick, "Unknown moduser command: $subcmd");
        return;
    }
}

# Helper: print moduser usage
sub _sendModUserSyntax {
    my ($self, $sNick) = @_;
    botNotice($self, $sNick, "moduser <user> level <Owner|Master|Administrator|User>");
    botNotice($self, $sNick, "moduser <user> autologin <on|off>");
    botNotice($self, $sNick, "moduser <user> fortniteid <id>");
}



sub setUserLevel(@) {
	my ($self,$sUser,$id_user_level) = @_;
	my $sQuery = "UPDATE USER SET id_user_level=? WHERE nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user_level,$sUser)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		return 0;
	}
	else {
		return 1;
	}
}

# Set the anti-flood parameters for a channel
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

        my $sth = $self->{dbh}->prepare("SELECT birthday FROM USER WHERE nickname LIKE ?");
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
    my @args    = @{ $ctx->args // [] };

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

    $self->{dbh}->do("DELETE FROM USER_CHANNEL  WHERE id_user=?", undef, $id_user);
    $self->{dbh}->do("DELETE FROM USER_HOSTMASK WHERE id_user=?", undef, $id_user);
    $self->{dbh}->do("DELETE FROM USER          WHERE id_user=?", undef, $id_user);

    my $msg = "User $target (id_user: $id_user) has been deleted";
    botNotice($self, $nick, $msg);
    logBot($self, $message, undef, "deluser", $msg);
}

# Get Fortnite ID for a user

1;
