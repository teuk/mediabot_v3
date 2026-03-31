package Mediabot::ChannelCommands;

# =============================================================================
# Mediabot::ChannelCommands — Channel management commands and helpers
#
# Provides all channel-related commands:
#   channel info/set/join/part/list, user op/deop/kick/voice,
#   badwords, antiflood, chanlog, topic, TMDB language, etc.
#
# External dependencies (botNotice, botPrivmsg, logBot, checkUserChannelLevel,
# noticeConsoleChan, etc.) remain in Mediabot.pm.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use List::Util qw(min);
use Mediabot::Helpers;

our @EXPORT = qw(
    getChannel
    getIdChannel
    get_channel_by_name
    getChannelById
    channelList_ctx
    registerChannel
    sayChannel_ctx
    actChannel_ctx
    mbChangeNick_ctx
    addChannel_ctx
    channelSetSyntax_ctx
    channelSet_ctx
    getIdChansetList
    getIdChannelSet
    purgeChannel_ctx
    channelPart_ctx
    channelJoin_ctx
    channelAddUser_ctx
    channelDelUser_ctx
    userOpChannel_ctx
    userDeopChannel_ctx
    userInviteChannel_ctx
    userVoiceChannel_ctx
    userDevoiceChannel_ctx
    userKickChannel_ctx
    userTopicChannel
    userShowcommandsChannel_ctx
    userChannelInfo_ctx
    channelStatLines_ctx
    mbDbChangeCategoryCommand_ctx
    mbDbCheckHostnameNickChan_ctx
    userAccessChannel_ctx
    channelNickList_ctx
    randomChannelNick_ctx
    channelAddBadword_ctx
    channelRemBadword_ctx
    setChannelAntiFloodParams_ctx
    getChannelOwner
    userTopicChannel_ctx
    mbChannelLog_ctx
    setTMDBLangChannel_ctx
    getTMDBLangChannel
);

sub getChannel {
    my ($self, $chan_name) = @_;
    return $self->{channels}{$chan_name};
}

# Get PID file path from configuration
sub getIdChannel {
    my ($self, $sChannel) = @_;
    $self->{logger}->log(1, "⚠️ getIdChannel() is deprecated. Use channel object instead.");
    return $self->{channels}{$sChannel} ? $self->{channels}{$sChannel}->get_id : undef;
}

# Get user nickname from user id
# Get user nickname/handle from user id
sub get_channel_by_name {
    my ($self, $name) = @_;
    my $sth = $self->{dbh}->prepare("SELECT id_channel FROM CHANNEL WHERE name = ?");
    return undef unless $sth->execute($name);
    if (my $ref = $sth->fetchrow_hashref) {
        require Mediabot::Channel;
        return Mediabot::Channel->new(
            dbh     => $self->{dbh},
            logger  => $self->{logger},
            id      => $ref->{id_channel},
            name    => $name,
        );
    }
    return undef;
}

# Get channel object by id
sub getChannelById {
	my ($self, $id_channel) = @_;
	foreach my $chan_name (keys %{ $self->{channels} }) {
		my $chan = $self->{channels}{$chan_name};
		return $chan if $chan->{id} == $id_channel;
	}
	return undef;
}


# Get console channel from description
sub channelList_ctx {
    my ($ctx) = @_;

    return unless $ctx->require_level('Master');

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $sql = q{
        SELECT
            C.name AS name,
            COUNT(UC.id_user) AS nbUsers
        FROM CHANNEL C
        LEFT JOIN USER_CHANNEL UC ON UC.id_channel = C.id_channel
        GROUP BY C.id_channel, C.name, C.creation_date
        ORDER BY C.creation_date
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "channelList_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    # Build a single-line response, truncated with "..." if too long
    my $prefix = "[#chan (users)] ";
    my $line   = $prefix;

    # Keep margin (IRC/notice overhead) — conservative
    my $max_len = 400;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $name    = $ref->{name}    // next;
        my $nbUsers = $ref->{nbUsers} // 0;

        my $chunk = "$name ($nbUsers) ";

        if (length($line) + length($chunk) + 3 > $max_len) {  # +3 for "..."
            $line =~ s/\s+$//;
            $line .= " ...";
            last;
        }

        $line .= $chunk;
    }

    $sth->finish;

    # If no channels, still show something clean
    $line = $prefix . "none" if $line eq $prefix;

    botNotice($self, $nick, $line);
    logBot($self, $ctx->message, undef, "chanlist");
    return 1;
}

# versionCheck() - sends version info in channel and alerts if update is available
sub registerChannel(@) {
	my ($self,$message,$sNick,$id_channel,$id_user) = @_;
	my $sQuery = "INSERT INTO USER_CHANNEL (id_user,id_channel,level) VALUES (?,?,500)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user,$id_channel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		$sth->finish;
		return 0;
	}
	else {
		logBot($self,$message,undef,"registerChannel","$sNick registered user : $id_user level 500 on channel : $id_channel");
		$sth->finish;
		return 1;
	}
}

# Context-based register command: allows first user creation: register <nickname_in_db> <password>
sub sayChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Administrator');

    # tolerate "nick injected as first arg"
    shift @args if @args && defined($args[0]) && lc($args[0]) eq lc($nick);

    my $chan = shift(@args) // '';
    my $text = join(' ', @args);

    for ($chan, $text) { $_ //= ''; s/^\s+|\s+$//g; }

    unless ($chan ne '' && $text ne '') {
        $self->botNotice($nick, "Syntax: say <#channel> <text>");
        return;
    }

    $chan = "#$chan" unless $chan =~ /^#/;

    botPrivmsg($self, $chan, $text);
    logBot($self, $ctx->message, undef, 'say', $chan, $text);
}

# Context-based: Allows an Administrator to send an /me action to a channel
sub actChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Administrator');

    # tolerate "nick injected as first arg"
    shift @args if @args && defined($args[0]) && lc($args[0]) eq lc($nick);

    my $chan = shift(@args) // '';
    my $text = join(' ', @args);

    for ($chan, $text) { $_ //= ''; s/^\s+|\s+$//g; }

    unless ($chan ne '' && $text ne '') {
        $self->botNotice($nick, "Syntax: act <#channel> <text>");
        return;
    }

    $chan = "#$chan" unless $chan =~ /^#/;

    botAction($self, $chan, $text);
    logBot($self, $ctx->message, undef, 'act', $chan, $text);
}

sub mbChangeNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $new_nick = $args[0];

    return unless $ctx->require_level('Owner');

    unless (defined $new_nick && $new_nick ne '') {
        $self->botNotice($nick, "Syntax: nick <new_nick>");
        return;
    }

    $self->{irc}->change_nick($new_nick);
    logBot($self, $ctx->message, undef, 'nick', $new_nick);
}

# Handle addtimer command (Owner only, Context-based)
sub addChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Administrator privilege
    $ctx->require_level('Administrator') or return;

    # Args: addchan <#channel> <user>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    $self->{logger}->log(3, "addChannel_ctx() raw args: " . join(' ', map { defined $_ ? $_ : '<undef>' } @args));

    # Take last 2 args to avoid any parser quirks
    my ($sChannel, $sUser) = @args >= 2 ? @args[-2, -1] : ('','');

    $sChannel //= '';
    $sUser    //= '';
    $sChannel =~ s/^\s+|\s+$//g;
    $sUser    =~ s/^\s+|\s+$//g;

    unless ($sChannel ne '' && $sUser ne '' && $sChannel =~ /^#/) {
        $self->{logger}->log(2, "addChannel_ctx() missing/malformed args: channel='$sChannel' user='$sUser'");
        botNotice($self, $nick, "Syntax: addchan <#channel> <user>");
        return;
    }

    $self->{logger}->log(0, "$nick issued addchan command: $sChannel $sUser");

    # Check if target user exists
    my $id_target_user = getIdUser($self, $sUser);
    unless ($id_target_user) {
        botNotice($self, $nick, "User $sUser does not exist");
        return;
    }

    # Build channel object
    my $channel = Mediabot::Channel->new({
        name => $sChannel,
        dbh  => $self->{dbh},
        irc  => $self->{irc},
    });

    # Already exists?
    if (my $existing_id = $channel->exists_in_db) {
        botNotice($self, $nick, "Channel $sChannel already exists");
        return;
    }

    # Create in DB
    my $id_channel = $channel->create_in_db;
    unless ($id_channel) {
        $self->{logger}->log(1, "addChannel_ctx() failed SQL insert for $sChannel");
        botNotice($self, $nick, "Error: failed to create channel $sChannel in DB.");
        return;
    }

    # Store object in channel hash
    $self->{channels}{lc($sChannel)} = $channel;

    # Join + register
    joinChannel($self, $sChannel, undef);

    my $registered = registerChannel($self, $ctx->message, $nick, $id_channel, $id_target_user);
    unless ($registered) {
        $self->{logger}->log(1, "registerChannel failed $sChannel $sUser");
        botNotice($self, $nick, "Channel created but registration with user $sUser failed.");
    } else {
        $self->{logger}->log(0, "registerChannel successful $sChannel $sUser");
        botNotice($self, $nick, "Channel $sChannel added and linked to $sUser.");
    }

    logBot($self, $ctx->message, undef, "addchan", $sChannel, $sUser);
    noticeConsoleChan($self, $ctx->message->prefix . " addchan command: added $sChannel (id_channel: $id_channel) linked to $sUser");

    return $id_channel;
}

# Display syntax help for chanset command (Context-based)
sub channelSetSyntax_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    botNotice($self, $nick, "Syntax: chanset [#channel] key <key>");
    botNotice($self, $nick, "Syntax: chanset [#channel] chanmode <+chanmode>");
    botNotice($self, $nick, "Syntax: chanset [#channel] description <description>");
    botNotice($self, $nick, "Syntax: chanset [#channel] auto_join <on|off>");
    botNotice($self, $nick, "Syntax: chanset [#channel] <+value|-value>");
}

# Context-based chanset command (Administrator OR channel-level >= 450)
sub channelSet_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # If first arg is a channel, it overrides target channel (legacy syntax)
    my $target_channel = $ctx->channel // '';
    if (@args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    }

    # In private messages, ctx->channel is often the nick, so require explicit #channel
    unless (defined($target_channel) && $target_channel ne '' && $target_channel =~ /^#/) {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Must be logged in at least (require_level will enforce auth)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Permission: Administrator OR per-channel level >= 450
    my $is_admin = $user->has_level($self, 'Administrator') ? 1 : 0;
    my $is_chan  = checkUserChannelLevel($self, $ctx->message, $target_channel, $user->id, 450) ? 1 : 0;

    unless ($is_admin || $is_chan) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Must have at least: key/chanmode/auto_join/description <value...>
    # or a single +Something / -Something
    unless (
        (@args >= 2 && defined($args[0]) && $args[0] ne '' && defined($args[1]) && $args[1] ne '')
        || (@args >= 1 && defined($args[0]) && $args[0] =~ /^[+-]/)
    ) {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Resolve channel object (hash is usually keyed in lowercase)
    my $k = lc($target_channel);
    unless (exists $self->{channels}{$k} && $self->{channels}{$k}) {
        botNotice($self, $nick, "Unknown channel $target_channel");
        return;
    }

    my $channel    = $self->{channels}{$k};
    my $id_channel = eval { $channel->get_id } // undef;
    unless ($id_channel) {
        botNotice($self, $nick, "Internal error: channel id unavailable for $target_channel");
        return;
    }

    # --- command handling ---
    if ($args[0] eq 'key') {
        my $val = $args[1];
        $channel->set_key($val);
        botNotice($self, $nick, "Set $target_channel key $val");
    }
    elsif ($args[0] eq 'chanmode') {
        my $val = $args[1];
        $channel->set_chanmode($val);
        botNotice($self, $nick, "Set $target_channel chanmode $val");
    }
    elsif ($args[0] eq 'auto_join') {
        my $v = lc($args[1] // '');
        my $flag = ($v eq 'on') ? 1 : (($v eq 'off') ? 0 : undef);
        unless (defined $flag) {
            channelSetSyntax_ctx($ctx);
            return;
        }
        $channel->set_auto_join($flag);
        botNotice($self, $nick, "Set $target_channel auto_join $v");
    }
    elsif ($args[0] eq 'description') {
        shift @args; # remove "description"
        my $desc = join(' ', @args);
        if ($desc =~ /console/i) {
            botNotice($self, $nick, "You cannot set $target_channel description to $desc");
            return;
        }
        $channel->set_description($desc);
        botNotice($self, $nick, "Set $target_channel description $desc");
    }
    elsif ($args[0] =~ /^([+-])(\w+)$/) {
        my ($op, $chanset) = ($1, $2);

        my $id_chanset_list = getIdChansetList($self, $chanset);
        unless ($id_chanset_list) {
            botNotice($self, $nick, "Undefined chanset $chanset");
            return;
        }

        my $id_channel_set = getIdChannelSet($self, $target_channel, $id_chanset_list);

        if ($op eq '+') {
            if ($id_channel_set) {
                botNotice($self, $nick, "Chanset +$chanset is already set");
                return;
            }

            my $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL_SET (id_channel, id_chanset_list) VALUES (?, ?)");
            $sth->execute($id_channel, $id_chanset_list);
            $sth->finish if $sth;

            botNotice($self, $nick, "Chanset +$chanset applied to $target_channel");

            # Keep legacy side effects
            setChannelAntiFlood($self, $ctx->message, $nick, $target_channel, @args) if $chanset =~ /^AntiFlood$/i;
            set_hailo_channel_ratio($self, $target_channel, 97) if $chanset =~ /^HailoChatter$/i;
        }
        else {
            unless ($id_channel_set) {
                botNotice($self, $nick, "Chanset +$chanset is not set");
                return;
            }

            my $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL_SET WHERE id_channel_set=?");
            $sth->execute($id_channel_set);
            $sth->finish if $sth;

            botNotice($self, $nick, "Chanset -$chanset removed from $target_channel");
        }
    }
    else {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Log (keep legacy-ish payload)
    logBot($self, $ctx->message, $target_channel, "chanset", $target_channel, @args);
    return $id_channel;
}

# Retrieve the ID of a chanset from the CHANSET_LIST table
sub purgeChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    $self->{logger}->log(3, "🔍 purgeChannel_ctx() called by $nick with args: @args");

    # Privilege gate
    return unless $ctx->require_level('Administrator');

    # Validate channel argument
    my $sChannel = $args[0] // '';
    unless ($sChannel =~ /^#/) {
        Mediabot::botNotice($self, $nick, "Syntax: purge <#channel>");
        return;
    }

    # Normalize key (your channel hash may be stored lowercased)
    my $key = lc($sChannel);

    # Check if bot knows about this channel
    my $channel_obj = $self->{channels}{$sChannel} || $self->{channels}{$key};
    unless ($channel_obj) {
        Mediabot::botNotice($self, $nick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || eval { $channel_obj->id } || undef;
    unless ($id_channel) {
        $self->{logger}->log(1, "purgeChannel_ctx(): could not resolve id_channel for $sChannel");
        Mediabot::botNotice($self, $nick, "Internal error: cannot resolve channel id for $sChannel");
        return;
    }

    $self->{logger}->log(0, "🗑️ $nick issued a purge command on $sChannel (id=$id_channel)");

    # Retrieve channel info from DB
    my $sth = $self->{dbh}->prepare("SELECT * FROM CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while fetching channel info");
        Mediabot::botNotice($self, $nick, "SQL error while fetching channel info.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        Mediabot::botNotice($self, $nick, "Channel $sChannel does not exist in DB (id_channel=$id_channel)");
        return;
    }

    # Safe values for archiving
    my $desc      = defined $ref->{description} ? $ref->{description} : '';
    my $ckey      = defined $ref->{key}         ? $ref->{key}         : '';
    my $chanmode  = defined $ref->{chanmode}    ? $ref->{chanmode}    : '';
    my $auto_join = defined $ref->{auto_join}   ? $ref->{auto_join}   : 0;

    # Delete from CHANNEL
    $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while deleting CHANNEL");
        Mediabot::botNotice($self, $nick, "SQL error while deleting channel.");
        return;
    }

    # Delete links
    $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while deleting USER_CHANNEL");
        Mediabot::botNotice($self, $nick, "SQL error while deleting channel links.");
        return;
    }

    # Archive into CHANNEL_PURGED
    $sth = $self->{dbh}->prepare(q{
        INSERT INTO CHANNEL_PURGED
            (id_channel, name, description, `key`, chanmode, auto_join, purged_by, purged_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
    });
    unless ($sth && $sth->execute($id_channel, $sChannel, $desc, $ckey, $chanmode, $auto_join, $nick)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while inserting into CHANNEL_PURGED");
        Mediabot::botNotice($self, $nick, "SQL error while archiving channel purge.");
        return;
    }

    # PART + memory cleanup
    $self->{irc}->send_message("PART", $sChannel, "Channel purged by $nick");
    delete $self->{channels}{$sChannel};
    delete $self->{channels}{$key};

    # Log
    logBot($self, $ctx->message, undef, "purge", "$nick purged $sChannel (id_channel=$id_channel)");
    Mediabot::botNotice($self, $nick, "Channel $sChannel purged.");
}

# Part a channel (Administrator+ OR channel-level >= 500)
sub channelPart_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator here because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " part command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Target channel resolution:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: part <#channel>");
        return;
    }

    # Ensure the bot knows the channel BEFORE checking per-channel access
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        return;
    }

    # Check privileges:
    # - Administrator+ globally
    # - OR channel-level >= 500
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target, $user->id, 500) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "channelPart_ctx(): checkUserChannelLevel failed for $target: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " part command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Execute: call the LEGACY partChannel() that actually parts on IRC
    $self->{logger}->log(0, "$nick issued a part $target command");
    partChannel($self, $target, "At the request of " . ($user->nickname // $nick));
    logBot($self, $ctx->message, $target, "part", "At the request of " . ($user->nickname // $nick));
}

# Part a channel on IRC (network helper)
# NOTE: This is NOT a _ctx handler. It is a low-level helper.
sub channelJoin_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator here because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " join command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel
    my $target = $args[0] // '';
    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: join <#channel>");
        return;
    }

    # Ensure the bot knows the channel BEFORE checking per-channel access (avoids noisy SQL)
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        return;
    }

    # Privileges:
    # - Administrator+ globally
    # - OR channel-level >= 450
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target, $user->id, 450) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "channelJoin_ctx(): checkUserChannelLevel failed for $target: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " join command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Fetch channel key (DB truth)
    my $id_channel = eval { $channel_obj->get_id } || undef;
    my $key;

    if (defined $id_channel) {
        my $sth = $self->{dbh}->prepare("SELECT `key` FROM CHANNEL WHERE id_channel = ?");
        if ($sth && $sth->execute($id_channel)) {
            if (my $ref = $sth->fetchrow_hashref) {
                $key = $ref->{key};
            }
            $sth->finish;
        } else {
            $self->{logger}->log(1, "channelJoin_ctx(): SQL error while fetching key for $target: $DBI::errstr");
        }
    } else {
        $self->{logger}->log(1, "channelJoin_ctx(): could not resolve id_channel for $target (channel object missing get_id?)");
    }

    # Execute JOIN (with key if any)
    $self->{logger}->log(0, "$nick issued a join $target command");
    joinChannel($self, $target, (defined($key) && $key ne '' ? $key : undef));

    logBot($self, $ctx->message, $target, "join", "");
}

# Add a user to a channel with a specific level
# Requires: authenticated + (Administrator+ OR channel-level >= 400)
sub channelAddUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " add user command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    # Syntax: add <#channel> <handle> <level>
    my ($target_handle, $target_level) = @args;
    unless (defined($target_handle) && $target_handle ne '' && defined($target_level) && $target_level =~ /^\d+$/) {
        botNotice($self, $nick, "Syntax: add <#channel> <handle> <level>");
        return;
    }
    $target_level = int($target_level);

    # Ensure the bot knows the channel BEFORE doing any DB access checks
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "channelAddUser_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Resolve target user id
    my $id_target_user = getIdUser($self, $target_handle);
    unless ($id_target_user) {
        botNotice($self, $nick, "User $target_handle does not exist");
        return;
    }

    # Admin check (uses your has_level hierarchy)
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Channel-level checks WITHOUT ambiguous SQL (query USER_CHANNEL only)
    my $caller_chan_level = 0;
    my $target_chan_level = 0;

    eval {
        my $sth = $self->{dbh}->prepare(q{
            SELECT level
            FROM USER_CHANNEL
            WHERE id_channel = ? AND id_user = ?
            LIMIT 1
        });

        # caller
        $sth->execute($id_channel, $user->id);
        ($caller_chan_level) = $sth->fetchrow_array;
        $caller_chan_level ||= 0;

        # target
        $sth->execute($id_channel, $id_target_user);
        ($target_chan_level) = $sth->fetchrow_array;
        $target_chan_level ||= 0;

        $sth->finish;
        1;
    } or do {
        $self->{logger}->log(1, "channelAddUser_ctx(): USER_CHANNEL lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

    # Privileges:
    # - Administrator+ globally
    # - OR caller channel-level >= 400
    my $has_chan_priv = ($caller_chan_level >= 400) ? 1 : 0;

    unless ($is_admin || $has_chan_priv) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " add user command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$caller_chan_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Already registered on this channel?
    if ($target_chan_level != 0) {
        botNotice($self, $nick, "User $target_handle is already on $channel with level $target_chan_level");
        return;
    }

    # Prevent assigning a level equal or higher than caller's (unless admin)
    if (!$is_admin && !($target_level < $caller_chan_level)) {
        botNotice($self, $nick, "You can't assign a level equal or higher than yours.");
        return;
    }

    # Insert
    my $sth = $self->{dbh}->prepare("INSERT INTO USER_CHANNEL (id_user, id_channel, level) VALUES (?, ?, ?)");
    unless ($sth && $sth->execute($id_target_user, $id_channel, $target_level)) {
        $self->{logger}->log(1, "channelAddUser_ctx(): SQL Error: $DBI::errstr while inserting USER_CHANNEL");
        botNotice($self, $nick, "Internal error (DB insert failed).");
        return;
    }
    $sth->finish if $sth;

    $self->{logger}->log(0, "$nick added $target_handle to $channel at level $target_level");
    logBot($self, $ctx->message, $channel, "add", $channel, $target_handle, $target_level);

    botNotice($self, $nick, "Added $target_handle to $channel at level $target_level");
}

# Get a user's level on a specific channel
sub channelDelUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " del user command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    # Syntax: del <#channel> <handle>
    my ($target_handle) = @args;
    unless ($channel =~ /^#/ && defined($target_handle) && $target_handle ne '') {
        botNotice($self, $nick, "Syntax: del <#channel> <handle>");
        return;
    }

    # Ensure the bot knows the channel BEFORE doing per-channel logic
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "channelDelUser_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Resolve target user id
    my $id_target = getIdUser($self, $target_handle);
    unless ($id_target) {
        botNotice($self, $nick, "User $target_handle does not exist");
        return;
    }

    # Admin check (uses your has_level hierarchy)
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Channel-level checks WITHOUT ambiguous SQL (query USER_CHANNEL only)
    my $issuer_level = 0;
    my $target_level = 0;

    eval {
        my $sth = $self->{dbh}->prepare(q{
            SELECT level
            FROM USER_CHANNEL
            WHERE id_channel = ? AND id_user = ?
            LIMIT 1
        });

        # issuer
        $sth->execute($id_channel, $user->id);
        ($issuer_level) = $sth->fetchrow_array;
        $issuer_level ||= 0;

        # target
        $sth->execute($id_channel, $id_target);
        ($target_level) = $sth->fetchrow_array;
        $target_level ||= 0;

        $sth->finish;
        1;
    } or do {
        $self->{logger}->log(1, "channelDelUser_ctx(): USER_CHANNEL lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

    # Permission: admin OR issuer channel-level >= 400
    my $has_chan_priv = ($issuer_level >= 400) ? 1 : 0;
    unless ($is_admin || $has_chan_priv) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " del user command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$issuer_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target must actually be on the channel
    unless ($target_level) {
        botNotice($self, $nick, "User $target_handle does not appear to have access on $channel");
        return;
    }

    # Prevent deleting someone with level equal or greater than issuer (unless admin)
    if (!$is_admin && !($target_level < $issuer_level)) {
        botNotice($self, $nick, "You can't del a user with a level equal or greater than yours");
        return;
    }

    # Delete from USER_CHANNEL
    my $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_user=? AND id_channel=?");
    unless ($sth && $sth->execute($id_target, $id_channel)) {
        $self->{logger}->log(1, "channelDelUser_ctx(): SQL Error: $DBI::errstr");
        botNotice($self, $nick, "Internal error (DB delete failed).");
        return;
    }
    $sth->finish if $sth;

    logBot($self, $ctx->message, $channel, "del", $channel, $target_handle);
    botNotice($self, $nick, "User $target_handle removed from $channel");
}

# User modinfo syntax notification
sub userOpChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " op command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: op [#channel] <nick>");
        return;
    }

    # Ensure bot knows the channel BEFORE per-channel level checks (avoids noisy SQL on unknown channel)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            # Safe deny on failure
            $self->{logger}->log(1, "userOpChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " op command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick to +o (default to caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE +o
    $self->{irc}->send_message("MODE", undef, ($target_chan, "+o", $target_nick));
    logBot($self, $ctx->message, $target_chan, "op", $target_chan, $target_nick);

    return $channel_obj->get_id;
}

# Remove operator (-o) from a nick on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub userDeopChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " deop command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: deop [#channel] <nick>");
        return;
    }

    # Ensure bot knows the channel BEFORE per-channel level checks (avoids noisy SQL on unknown channel)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            # Safe deny on failure
            $self->{logger}->log(1, "userDeopChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " deop command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick to -o (default to caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE -o
    $self->{irc}->send_message("MODE", undef, ($target_chan, "-o", $target_nick));
    logBot($self, $ctx->message, $target_chan, "deop", $target_chan, $target_nick);

    return $channel_obj->get_id;
}

# Invite a nick to a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub userInviteChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " invite command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: invite [#channel] <nick>");
        return;
    }

    # Ensure the bot knows the channel BEFORE per-channel checks (avoid noisy SQL)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "userInviteChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0; # safe deny
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " invite command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Who to invite (default: caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute INVITE
    $self->{irc}->send_message("INVITE", undef, ($target_nick, $target_chan));
    logBot($self, $ctx->message, $target_chan, "invite", $target_chan, $target_nick);

    return $id_channel;
}

# Give +v (voice) to a user on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 25)
sub userVoiceChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " voice command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - first argument if it is a #channel
    # - otherwise fallback to ctx->channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: voice [#channel] <nick>");
        return;
    }

    # Ensure the channel exists in bot memory (avoid useless SQL errors)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 25
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 25
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userVoiceChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " voice command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick (+v); default is the caller
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE +v
    $self->{irc}->send_message("MODE", undef, ($target_chan, "+v", $target_nick));
    logBot($self, $ctx->message, $target_chan, "voice", $target_chan, $target_nick);

    return $id_channel;
}

# Remove +v (voice) from a user on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 25)
sub userDevoiceChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " devoice command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - first argument if it is a #channel
    # - otherwise fallback to ctx->channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: devoice [#channel] <nick>");
        return;
    }

    # Ensure the channel exists in bot memory (avoid useless SQL errors)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 25
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 25
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userDevoiceChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " devoice command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick (-v); default is the caller
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE -v
    $self->{irc}->send_message("MODE", undef, ($target_chan, "-v", $target_nick));
    logBot($self, $ctx->message, $target_chan, "devoice", $target_chan, $target_nick);

    return $id_channel;
}

# Kick a user from a channel, with an optional reason.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 50)
sub userKickChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " kick command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: kick [#channel] <nick> [reason]");
        return;
    }

    # Ensure the bot knows the channel BEFORE doing per-channel privilege checks
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Target nick is mandatory
    my $kick_nick = shift @args;
    unless (defined $kick_nick && $kick_nick ne '') {
        botNotice($self, $nick, "Syntax: kick [#channel] <nick> [reason]");
        return;
    }

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 50
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 50
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userKickChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " kick command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Optional reason
    my $reason = join(' ', @args);
    my $issuer = eval { $user->nickname } || $nick;
    my $final  = "(" . $issuer . ")" . (length($reason) ? " $reason" : "");

    # Execute KICK
    $self->{logger}->log(0, "$nick issued a kick $target_chan command");
    $self->{irc}->send_message("KICK", undef, ($target_chan, $kick_nick, $final));

    logBot($self, $ctx->message, $target_chan, "kick", $target_chan, $kick_nick, $reason);

    return $id_channel;
}

# Set the topic of a channel if the user has the appropriate privileges
sub userTopicChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $prefix = eval { $message->prefix } // '';
    my $user   = eval { $self->get_user_from_message($message) };

    unless ($user) {
        $self->noticeConsoleChan("$prefix topic: no user object from get_user_from_message()");
        botNotice($self, $sNick, "Internal error: no user");
        return;
    }

    # --- Safe getters (compat champs/méthodes) ---
    my $uid        = eval { $user->id }                // eval { $user->{id_user} }       // 0;
    my $handle     = eval { $user->nickname }          // eval { $user->{nickname} }      // $sNick;
    my $auth       = eval { $user->auth }              // eval { $user->{auth} }          // 0;
    my $level      = eval { $user->level }             // eval { $user->{level} }         // undef;
    my $level_desc = eval { $user->level_description } // eval { $user->{level_desc} }    // 'unknown';

    $self->noticeConsoleChan("$prefix AUTH[topic-enter] uid=$uid nick=$handle auth=$auth level=$level_desc");

    # ---------- tentative d'auto-login si auth=0 ----------
    if (!$auth) {
        my ($username, $masks) = ('','');
        eval {
            my $sth = $self->{dbh}->prepare("SELECT username FROM USER WHERE id_user=?");
            $sth->execute($uid);
            ($username) = $sth->fetchrow_array;
            $sth->finish;
            # Fetch hostmasks from USER_HOSTMASK
            my $hm_sth = $self->{dbh}->prepare(
                "SELECT GROUP_CONCAT(hostmask ORDER BY id_user_hostmask SEPARATOR ',') FROM USER_HOSTMASK WHERE id_user=?"
            );
            $hm_sth->execute($uid);
            ($masks) = $hm_sth->fetchrow_array;
            $hm_sth->finish;
            $masks //= '';
        };

        my $userhost = $prefix; $userhost =~ s/^.*?!(.+)$/$1/;
        my $matched_mask;
        for my $mask (grep { length } map { my $x=$_; $x =~ s/^\s+|\s+$//g; $x } split /,/, ($masks//'') ) {
            my $re = do {
                my $q = quotemeta($mask);
                $q =~ s/\\\*/.*/g; # '*' -> '.*'
                $q =~ s/\\\?/./g;  # '?' -> '.'
                qr/^$q$/i;
            };
            if ($userhost =~ $re) { $matched_mask = $mask; last; }
        }

        $self->noticeConsoleChan("$prefix topic: auth=0; username='".($username//'')."'; mask check => ".($matched_mask ? "matched '$matched_mask'" : "no match"));

        if (defined $username && $username eq '#AUTOLOGIN#' && $matched_mask) {
            my ($ok,$why) = eval { $self->{auth}->maybe_autologin($user, $prefix) };
            $ok //= 0; $why //= ($@ ? "exception: $@" : "unknown");
            $self->noticeConsoleChan("$prefix topic: maybe_autologin => ".($ok?'OK':'NO')." ($why)");

            # rafraîchir l’état utilisateur
            $user  = eval { $self->get_user_from_message($message) } || $user;
            $auth  = eval { $user->auth } // eval { $user->{auth} } // 0;
            $level = eval { $user->level } // eval { $user->{level} } // $level;
            $level_desc = eval { $user->level_description } // eval { $user->{level_desc} } // $level_desc;
            $self->noticeConsoleChan("$prefix topic: after autologin => auth=$auth level=$level_desc");
        } else {
            $self->noticeConsoleChan("$prefix topic: autologin not eligible");
        }
    }

    # Abort if still not authenticated
    unless ($auth) {
        my $notice = "$prefix topic command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        return;
    }

    # Extract channel from arguments if provided
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    # Check permissions: Administrator or per-channel level >= 50
    my $user_id_for_check = eval { $user->id } // $uid;
    unless (
        checkUserLevel($self, $level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user_id_for_check, 50)
    ) {
        my $notice = "$prefix topic command attempt by $handle [level: $level_desc]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Ensure a topic is provided
    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    # Get channel object and verify existence
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    my $new_topic  = join(" ", @tArgs);

    # Log and send IRC topic command
    $self->{logger}->log(0, "$sNick issued a topic $sChannel command");
    $self->{irc}->send_message("TOPIC", undef, ($sChannel, $new_topic));
    logBot($self, $message, $sChannel, "topic", @tArgs);

    return $id_channel;
}

# Show available commands to the user for a specific channel (Context-based)
sub userShowcommandsChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Always-available public commands line
    my $public_line = "Level   0: access chaninfo login pass newpass ident showcommands";

    # If we can't resolve a user, show only public commands
    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, $public_line);
        return;
    }

    # Require authentication to show level-dependent commands
    unless ($user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " showcommands attempt (user "
                   . (eval { $user->nickname } || eval { $user->handle } || $nick)
                   . " is not logged in)";
        noticeConsoleChan($self, $notice);
        logBot($self, $ctx->message, $ctx->channel, "showcommands", @args);

        botNotice(
            $self, $nick,
            "You must be logged to see available commands for your level - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        botNotice($self, $nick, $public_line);
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: showcommands #channel");
        return;
    }

    # If the bot doesn't know this channel, don't try DB lookups (avoid noisy SQL)
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        botNotice($self, $nick, $public_line);
        return;
    }

    # Global admin?
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $header = "Available commands on $target";
    $header .= " (because you are a global admin)" if $is_admin;

    noticeConsoleChan($self, ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick) . " showcommands on $target");
    logBot($self, $ctx->message, $target, "showcommands", $target);

    botNotice($self, $nick, $header);

    # Get user handle for channel-level lookup
    my $handle = eval { $user->handle }
              || eval { $user->nickname }
              || $nick;

    # Get user level on the channel (safe default 0)
    my (undef, $level) = eval { getIdUserChannelLevel($self, $handle, $target) };
    $level //= 0;

    # Show commands by channel level (admin bypasses)
    botNotice($self, $nick, "Level 500: part")            if ($is_admin || $level >= 500);
    botNotice($self, $nick, "Level 450: join chanset")    if ($is_admin || $level >= 450);
    botNotice($self, $nick, "Level 400: add del modinfo") if ($is_admin || $level >= 400);
    botNotice($self, $nick, "Level 100: op deop invite")  if ($is_admin || $level >= 100);
    botNotice($self, $nick, "Level  50: kick topic")      if ($is_admin || $level >= 50);
    botNotice($self, $nick, "Level  25: voice devoice")   if ($is_admin || $level >= 25);

    # Always show public commands
    botNotice($self, $nick, $public_line);

    return 1;
}

# Show detailed info about a registered channel (Context-based)
sub userChannelInfo_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $sChannel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $sChannel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $sChannel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($sChannel =~ /^#/) {
        botNotice($self, $nick, "Syntax: chaninfo #channel");
        return;
    }

    # Require the channel to exist in the bot cache/hash first
    my $channel_obj = $self->{channels}{$sChannel} || $self->{channels}{lc($sChannel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $sChannel does not exist");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Internal error: channel object has no id for $sChannel");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    # --- Main SQL query: channel info + owner (level 500) ---
    my $sql1 = q{
        SELECT
            U.nickname       AS nickname,
            U.last_login     AS last_login,
            C.creation_date  AS creation_date,
            C.description    AS description,
            C.`key`          AS c_key,
            C.chanmode       AS chanmode,
            C.auto_join      AS auto_join
        FROM USER_CHANNEL UC
        JOIN `USER`  U ON U.id_user    = UC.id_user
        JOIN CHANNEL C ON C.id_channel = UC.id_channel
        WHERE UC.id_channel = ? AND UC.level = 500
        LIMIT 1
    };

    my $sth1 = $self->{dbh}->prepare($sql1);
    unless ($sth1 && $sth1->execute($id_channel)) {
        $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql1");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    my $ref = $sth1->fetchrow_hashref();
    $sth1->finish;

    unless ($ref) {
        botNotice($self, $nick, "The channel $sChannel doesn't appear to be registered");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    my $sUsername     = $ref->{nickname}       // '?';
    my $sLastLogin    = defined $ref->{last_login}    ? $ref->{last_login}    : "Never";
    my $creation_date = defined $ref->{creation_date} ? $ref->{creation_date} : "Unknown";
    my $description   = defined $ref->{description}   ? $ref->{description}   : "No description";

    my $sKey      = defined $ref->{c_key}    ? $ref->{c_key}    : "Not set";
    my $chanmode  = defined $ref->{chanmode} ? $ref->{chanmode} : "Not set";
    my $sAutoJoin = ($ref->{auto_join} ? "True" : "False");

    botNotice($self, $nick, "$sChannel is registered by $sUsername - last login: $sLastLogin");
    botNotice($self, $nick, "Creation date : $creation_date - Description : $description");

    # Optional Master+ info (no legacy checkUserLevel)
    my $user = $ctx->user;
    if ($user && $user->is_authenticated && eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Chan modes : $chanmode - Key : $sKey - Auto join : $sAutoJoin");
    }

    # --- List CHANSET flags (by channel id) ---
    my $sql2 = q{
        SELECT CL.chanset
        FROM CHANNEL_SET  CS
        JOIN CHANSET_LIST CL ON CL.id_chanset_list = CS.id_chanset_list
        WHERE CS.id_channel = ?
    };

    my $sth2 = $self->{dbh}->prepare($sql2);
    if ($sth2 && $sth2->execute($id_channel)) {
        my $flags = '';
        my $hasFlags = 0;
        my $hasAntiFlood = 0;

        while (my $r = $sth2->fetchrow_hashref()) {
            my $chanset = $r->{chanset};
            next unless defined $chanset && $chanset ne '';
            $flags .= "+$chanset ";
            $hasFlags = 1;
            $hasAntiFlood = 1 if $chanset =~ /AntiFlood/i;
        }
        $sth2->finish;

        botNotice($self, $nick, "Channel flags $flags") if $hasFlags;

        # If AntiFlood flag is present, fetch flood parameters
        if ($hasAntiFlood) {
            my $sql3 = q{
                SELECT nbmsg_max, nbmsg, duration, timetowait, notification
                FROM CHANNEL_FLOOD
                WHERE id_channel = ?
                LIMIT 1
            };
            my $sth3 = $self->{dbh}->prepare($sql3);
            if ($sth3 && $sth3->execute($id_channel)) {
                if (my $rf = $sth3->fetchrow_hashref()) {
                    my $nbmsg_max  = $rf->{nbmsg_max};
                    my $duration   = $rf->{duration};
                    my $timetowait = $rf->{timetowait};
                    my $notif      = ($rf->{notification} ? "ON" : "OFF");

                    botNotice(
                        $self, $nick,
                        "Antiflood parameters : $nbmsg_max messages in $duration seconds, wait for $timetowait seconds, notification : $notif"
                    );
                } else {
                    botNotice($self, $nick, "Antiflood parameters : not set ?");
                }
                $sth3->finish;
            } else {
                $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql3");
            }
        }
    } else {
        $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql2");
    }

    logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
    return 1;
}

# Return detailed information about the currently authenticated user (Context-based)
sub channelStatLines_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Auth + level (Context handles the deny messaging cleanly)
    return unless $ctx->require_level("Administrator");
    my $user = $ctx->user;
    return unless $user;

    # Resolve target channel: first arg if #chan, else ctx->channel
    my $target_channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_channel =~ /^#/) {
        botNotice($self, $nick, "Usage: chanstatlines <#channel>");
        return;
    }

    # (small improvement) If we don't know the channel internally, say it early (no pointless SQL)
    my $chan_obj = $self->{channels}{$target_channel} || $self->{channels}{lc($target_channel)};
    unless ($chan_obj) {
        botNotice($self, $nick, "Channel $target_channel doesn't seem to be registered.");
        logBot($self, $ctx->message, undef, "chanstatlines", $target_channel, "No such channel");
        return;
    }

    my $sql = q{
        SELECT COUNT(*) AS nb_lines
        FROM CHANNEL_LOG CL
        JOIN CHANNEL C ON CL.id_channel = C.id_channel
        WHERE C.name = ?
          AND CL.ts > (NOW() - INTERVAL 1 HOUR)
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my ($count) = $sth->fetchrow_array;
    $sth->finish;

    $count ||= 0;

    # (small improvement) Do NOT talk in-channel by default; report to the requester.
    # Avoids spamming the channel / leaking admin activity.
    my $msg =
        ($count == 0)
            ? "Last hour on $target_channel: 0 lines."
            : "Last hour on $target_channel: $count " . ($count == 1 ? "line" : "lines") . ".";

    botNotice($self, $nick, $msg);
    logBot($self, $ctx->message, undef, "chanstatlines", $target_channel, $count);

    return $count;
}

# Display top talkers in a channel during the last hour (Administrator+)
# Improvements:
# - Uses Context (auth/deny handled centrally)
# - Avoids spamming/embarrassing users: sends result to requester by NOTICE (and only posts in-channel if invoked in that channel)
# - Truncates to stay within a safe IRC line length (adds "...")
# - Early exit if channel not known by the bot (avoid noisy SQL / mismatched channel names)
sub mbDbChangeCategoryCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx chcatcmd attempt (not logged in)");
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx chcatcmd attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Args
    unless (defined $args[0] && $args[0] ne '' && defined $args[1] && $args[1] ne '') {
        botNotice($self, $nick, "Syntax: chcatcmd <new_category> <command>");
        return;
    }

    my ($category_name, $command_name) = @args[0,1];

    # 1) Resolve category id
    my $sth = $self->{dbh}->prepare(
        "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?"
    );
    unless ($sth && $sth->execute($category_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $nick, "Database error while checking category.");
        return;
    }

    my $cat = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($cat && defined $cat->{id_public_commands_category}) {
        botNotice($self, $nick, "Category '$category_name' does not exist.");
        return;
    }

    my $category_id = $cat->{id_public_commands_category};

    # 2) Ensure command exists
    $sth = $self->{dbh}->prepare("SELECT id_public_commands FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth && $sth->execute($command_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT command");
        botNotice($self, $nick, "Database error while checking command.");
        return;
    }

    my $cmd = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($cmd && defined $cmd->{id_public_commands}) {
        botNotice($self, $nick, "Command '$command_name' does not exist.");
        return;
    }

    # 3) Update category
    $sth = $self->{dbh}->prepare(
        "UPDATE PUBLIC_COMMANDS SET id_public_commands_category = ? WHERE command = ?"
    );
    unless ($sth && $sth->execute($category_id, $command_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: UPDATE command category");
        botNotice($self, $nick, "Failed to update category for '$command_name'.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Category changed to '$category_name' for command '$command_name'.");
    logBot($self, $ctx->message, $ctx->channel, "chcatcmd", "Changed category to '$category_name' for '$command_name'");

    return 1;
}

# Show the most frequently used phrases by a given nick on a given channel
# Requires: authenticated + Administrator+
sub mbDbCheckHostnameNickChan_ctx {
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
        noticeConsoleChan($self, "$pfx checkhostchan attempt (unauthenticated " . ($user->nickname // '?') . ")");
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
        noticeConsoleChan($self, "$pfx checkhostchan attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel
    my $target_chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: checkhostchan [#channel] <hostname>");
        return;
    }

    # Hostname argument
    my $hostname = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $hostname =~ s/^\s+|\s+$//g;

    unless ($hostname ne '') {
        botNotice($self, $nick, "Syntax: checkhostchan [#channel] <hostname>");
        return;
    }

    # Ensure the bot knows this channel (avoid noisy SQL / ambiguous errors elsewhere)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Output destination:
    # - If command issued in private, reply by notice
    # - Else reply in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel // $target_chan;

    # Optimization:
    # - Avoid JOIN on CHANNEL.name, use id_channel directly
    # - Avoid SUBSTRING_INDEX (it forces computation per row)
    #   Use LIKE on userhost tail: '%@hostname' (still wildcard, but cheaper than SUBSTRING_INDEX)
    #
    # Best real optimization long-term:
    #   store host separately (or generated column) + index it.
    my $sql = <<'SQL';
SELECT nick, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE id_channel = ?
  AND userhost IS NOT NULL
  AND userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckHostnameNickChan_ctx(): failed to prepare SQL");
        return;
    }

    # Match host suffix inside full userhost like 'nick!ident@host'
    my $mask = '%@' . $hostname;

    unless ($sth->execute($id_channel, $mask)) {
        $self->{logger}->log(1, "mbDbCheckHostnameNickChan_ctx() SQL Error: $DBI::errstr Query: $sql");
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
        $resp = "Nicks for host $hostname on $target_chan: $list";
    } else {
        $resp = "No result found for hostname $hostname on $target_chan.";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
    }

    logBot($self, $ctx->message, $dest_chan, "checkhostchan", $hostname);
    return 1;
}

# checkhost <hostname|*@host|nick!ident@host>
# Show nicknames seen for a given host (global, across all channels)
# Requires: authenticated + Administrator+
sub userAccessChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Resolve channel:
    # - If first arg is a #channel, use it and shift it out
    # - Else fallback to ctx->channel (if it looks like a channel)
    my $chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($chan) {
        botNotice($self, $nick, "Syntax: access #channel [=]<nick>");
        return;
    }

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: access #channel [=]<nick>");
        return;
    }

    my $target = $args[0];

    # "=nick" => WHOIS path (kept identical to legacy behavior)
    if (substr($target, 0, 1) eq '=') {
        $target = substr($target, 1);

        $self->{WHOIS_VARS} = {
            nick    => $target,
            sub     => 'userAccessChannel',   # keep legacy sub name for WHOIS handler routing
            caller  => $nick,
            channel => $chan,
            message => $ctx->message,
        };

        $self->{logger}->log(3, "Triggering WHOIS on $target for $nick via userAccessChannel_ctx() channel=$chan");
        $self->{irc}->send_message("WHOIS", undef, $target);
        return;
    }

    # Direct DB handle path
    my $iAccess = getUserChannelLevelByName($self, $chan, $target);

    if (!$iAccess || $iAccess == 0) {
        botNotice($self, $nick, "No Match!");
        logBot($self, $ctx->message, $chan, "access", ($chan, $target));
        return;
    }

    botNotice($self, $nick, "USER: $target ACCESS: $iAccess");

    my $sQuery = "SELECT automode,greet FROM USER,USER_CHANNEL,CHANNEL "
               . "WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel "
               . "AND USER.id_user=USER_CHANNEL.id_user "
               . "AND nickname like ? AND CHANNEL.name=?";

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target, $chan)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $greet = defined($ref->{greet})    ? $ref->{greet}    : "None";
        my $mode  = defined($ref->{automode}) ? $ref->{automode} : "None";

        botNotice($self, $nick, "CHANNEL: $chan -- Automode: $mode");
        botNotice($self, $nick, "GREET MESSAGE: $greet");
        logBot($self, $ctx->message, $chan, "access", ($chan, $target));
    }

    $sth->finish;
    return;
}

# Get user channel level by channel name and nick handle
sub channelNickList_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "Unable to identify you.");
        return;
    }

    # Auth required
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx nicklist attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Admin required
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx nicklist attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel, use it
    # - Else fallback to ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: nicklist #channel");
        return;
    }

    # Normalize
    $target_chan =~ s/^\s+|\s+$//g;
    my $target_lc = lc($target_chan);

    # Fetch from memory (try exact, then lc)
    my $nicklist_ref = $self->{hChannelsNicks}{$target_chan}
                    || $self->{hChannelsNicks}{$target_lc};

    unless ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY') {
        $self->{logger}->log(2, "nicklist requested for unknown channel $target_chan");
        botNotice($self, $nick, "No nicklist known for $target_chan.");
        logBot($self, $ctx->message, undef, "nicklist", $target_chan);
        return;
    }

    my @nicks = grep { defined($_) && $_ ne '' } @$nicklist_ref;
    unless (@nicks) {
        botNotice($self, $nick, "Nicklist for $target_chan is empty.");
        logBot($self, $ctx->message, undef, "nicklist", $target_chan);
        return;
    }

    # Avoid flooding / max line length: send in chunks
    my $header = "Users on $target_chan (" . scalar(@nicks) . "): ";
    my $maxlen = 380; # conservative for IRC
    my $line   = $header;

    for my $n (@nicks) {
        my $add = $n . " ";
        if (length($line) + length($add) > $maxlen) {
            botNotice($self, $nick, $line);
            $line = $header . $add;
        } else {
            $line .= $add;
        }
    }
    botNotice($self, $nick, $line) if $line ne $header;

    $self->{logger}->log(3, "nicklist $target_chan => " . scalar(@nicks) . " users");
    logBot($self, $ctx->message, undef, "nicklist", $target_chan);

    return 1;
}

# /rnick [#channel]
# Returns a random nick from the bot's memory list for a given channel (hChannelsNicks)
# Requires: authenticated + Administrator+
sub randomChannelNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "Unable to identify you.");
        return;
    }

    # Auth required
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx rnick attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Admin required
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx rnick attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel, use it
    # - Else fallback to ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: rnick #channel");
        return;
    }

    # Normalize
    $target_chan =~ s/^\s+|\s+$//g;
    my $target_lc = lc($target_chan);

    # Fetch from memory (try exact, then lc)
    my $nicklist_ref = $self->{hChannelsNicks}{$target_chan}
                    || $self->{hChannelsNicks}{$target_lc};

    unless ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY') {
        botNotice($self, $nick, "No known nicklist for $target_chan.");
        $self->{logger}->log(2, "rnick: no nicklist for $target_chan");
        logBot($self, $ctx->message, undef, "rnick", $target_chan);
        return;
    }

    # Sanitize list (avoid empty/undef)
    my @pool = grep { defined($_) && $_ ne '' } @$nicklist_ref;

    unless (@pool) {
        botNotice($self, $nick, "Nicklist for $target_chan is empty.");
        $self->{logger}->log(2, "rnick: empty nicklist for $target_chan");
        logBot($self, $ctx->message, undef, "rnick", $target_chan);
        return;
    }

    my $random_nick = $pool[ int(rand(@pool)) ];

    botNotice($self, $nick, "Random nick on $target_chan: $random_nick");
    $self->{logger}->log(3, "rnick $target_chan => $random_nick");
    logBot($self, $ctx->message, undef, "rnick", $target_chan);

    return 1;
}

# Get a random nick from a channel's nick list
sub channelAddBadword_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx addbadword command attempt (unauthenticated)");
        return;
    }

    # Master only
    unless (eval { $user->has_level('Master') } ) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx addbadword command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel use it
    # - else fallback to ctx->channel
    my $chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    # Channel must be registered in memory
    my $channel_obj = $self->{channels}{$chan} || $self->{channels}{lc($chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    # Badword text
    my $badword = join(" ", grep { defined && $_ ne '' } @args);
    $badword =~ s/^\s+|\s+$//g;

    unless ($badword ne '') {
        botNotice($self, $nick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    # Already exists?
    my $sth = $self->{dbh}->prepare(
        "SELECT id_badwords, badword FROM BADWORDS WHERE id_channel=? AND badword=?"
    );
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelAddBadword_ctx() SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $nick, "Badword [$ref->{id_badwords}] '$ref->{badword}' is already defined on $chan");
        logBot($self, $ctx->message, $chan, "addbadword", "$chan $badword");
        $sth->finish;
        return;
    }
    $sth->finish;

    # Insert
    $sth = $self->{dbh}->prepare("INSERT INTO BADWORDS (id_channel, badword) VALUES (?, ?)");
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelAddBadword_ctx() SQL Error: $DBI::errstr");
        return;
    }

    botNotice($self, $nick, "Added badword '$badword' to $chan");
    logBot($self, $ctx->message, $chan, "addbadword", "$chan $badword");
    $sth->finish;

    return 1;
}

# Remove a badword from a channel
sub channelRemBadword_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx rembadword command attempt (unauthenticated)");
        return;
    }

    # Master only
    unless (eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx rembadword command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Resolve target channel
    my $chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    # Channel must be registered in memory
    my $channel_obj = $self->{channels}{$chan} || $self->{channels}{lc($chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    # Badword text
    my $badword = join(" ", grep { defined && $_ ne '' } @args);
    $badword =~ s/^\s+|\s+$//g;

    unless ($badword ne '') {
        botNotice($self, $nick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    # Find badword id
    my $sql_sel = "SELECT id_badwords FROM BADWORDS WHERE id_channel = ? AND badword = ?";
    my $sth = $self->{dbh}->prepare($sql_sel);
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelRemBadword_ctx() SQL Error: $DBI::errstr Query: $sql_sel");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref && $ref->{id_badwords}) {
        botNotice($self, $nick, "Badword '$badword' is not set on $chan");
        return 0;
    }

    my $id_badwords = $ref->{id_badwords};

    # Delete
    my $sql_del = "DELETE FROM BADWORDS WHERE id_badwords = ?";
    $sth = $self->{dbh}->prepare($sql_del);
    unless ($sth && $sth->execute($id_badwords)) {
        $self->{logger}->log(1, "channelRemBadword_ctx() SQL Error: $DBI::errstr Query: $sql_del");
        return;
    }

    botNotice($self, $nick, "Removed badword '$badword' from $chan");
    logBot($self, $ctx->message, $chan, "rembadword", "$chan $badword");
    $sth->finish;

    return 1;
}

# Check if a message is from an ignored user
sub setChannelAntiFloodParams_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;        # caller IRC nick
    my $channel = $ctx->channel;     # may be undef in private
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $user   = $ctx->user;
    my $handle = eval { $user->nickname } || $nick;



    # ---------------------------------------------------------
    # Resolve target channel
    # - If first argument is a #channel, use it
    # - Else fallback to context channel
    # ---------------------------------------------------------
    my $target_channel = undef;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    } else {
        my $cc = $channel // '';
        $target_channel = ($cc =~ /^#/) ? $cc : undef;
    }

    unless ($target_channel) {
        botNotice($self, $nick, "Undefined channel.");
        botNotice($self, $nick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
        return;
    }

    # ---------------------------------------------------------
    # Resolve channel object from in-memory map
    # ---------------------------------------------------------
    my $channel_obj = $self->{channels}{$target_channel}
                   || $self->{channels}{lc $target_channel};

    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_channel is not registered.");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $target_channel is not registered.");
        return;
    }

    # ---------------------------------------------------------
    # If no args: display current antiflood parameters
    # ---------------------------------------------------------
    if (@args == 0) {
        $self->{logger}->log(3, "Fetching antiflood settings for $target_channel");

        my $sql = q{
            SELECT CHANNEL_FLOOD.nbmsg_max,
                   CHANNEL_FLOOD.duration,
                   CHANNEL_FLOOD.timetowait
            FROM CHANNEL
            JOIN CHANNEL_FLOOD ON CHANNEL.id_channel = CHANNEL_FLOOD.id_channel
            WHERE CHANNEL.name LIKE ?
        };

        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute($target_channel)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr");
            return;
        }

        if (my $row = $sth->fetchrow_hashref()) {
            my $max    = $row->{nbmsg_max}  // 0;
            my $period = $row->{duration}   // 0;
            my $wait   = $row->{timetowait} // 0;

            my $msg = "antifloodset for $target_channel: "
                    . "$max message"  . ($max    == 1 ? "" : "s")
                    . " max in $period second" . ($period == 1 ? "" : "s")
                    . ", wait $wait second"    . ($wait   == 1 ? "" : "s")
                    . " if breached";

            botNotice($self, $nick, $msg);
        } else {
            botNotice($self, $nick, "No antiflood settings found for $target_channel");
        }

        $sth->finish if $sth;
        return 0;
    }

    # ---------------------------------------------------------
    # We expect 3 numeric arguments: <max_msg> <period_sec> <wait_sec>
    # ---------------------------------------------------------
    for my $i (0..2) {
        unless (defined($args[$i]) && $args[$i] =~ /^\d+$/) {
            botNotice($self, $nick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
            return;
        }
    }

    my ($max_msg, $period_sec, $wait_sec) = @args[0..2];

    # ---------------------------------------------------------
    # Check that AntiFlood is enabled via chanset
    # ---------------------------------------------------------
    my $id_chanset    = getIdChansetList($self, "AntiFlood");
    my $id_channelset = $id_chanset ? getIdChannelSet($self, $target_channel, $id_chanset) : undef;

    unless ($id_chanset && $id_channelset) {
        botNotice($self, $nick, "You must enable AntiFlood first: chanset $target_channel +AntiFlood");
        return;
    }

    # ---------------------------------------------------------
    # Update CHANNEL_FLOOD values for this channel
    # ---------------------------------------------------------
    my $sql_update = q{
        UPDATE CHANNEL_FLOOD
        SET nbmsg_max = ?, duration = ?, timetowait = ?
        WHERE id_channel = ?
    };

    my $sth = $self->{dbh}->prepare($sql_update);
    unless ($sth) {
        $self->{logger}->log(1, "SQL Error (prepare): $DBI::errstr");
        return;
    }

    if ($sth->execute($max_msg, $period_sec, $wait_sec, $id_channel)) {
        $sth->finish;
        botNotice(
            $self,
            $nick,
            "Antiflood parameters set for $target_channel: "
              . "$max_msg messages max in $period_sec sec, wait $wait_sec sec"
        );
        return 0;
    } else {
        $self->{logger}->log(1, "SQL Error (execute): $DBI::errstr");
        $sth->finish;
        return;
    }
}

# Get the owner of a channel
sub getChannelOwner {
	my ($self, $sChannel) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "getChannelOwner() unknown channel: $sChannel");
		return undef;
	}

	my $id_channel = $channel_obj->get_id;

	my $sQuery = "SELECT nickname FROM USER,USER_CHANNEL WHERE USER.id_user = USER_CHANNEL.id_user AND id_channel = ? AND USER_CHANNEL.level = 500";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		return undef;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		return $ref->{nickname};
	}

	return undef;
}

# Convert a string to leet-speak.
# Backward compatible: leet($self, "text") or leet("text")
sub userTopicChannel_ctx {
    my ($ctx) = @_;
    userTopicChannel($ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @{ $ctx->args });
}

sub mbChannelLog_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---- Resolve user and permissions ----
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx qlog command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level("Administrator") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx qlog command attempt (command level [Administrator] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---- Optional #channel as first arg (allows: qlog #chan foo bar) ----
    my $target_chan = $channel;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
        return;
    }

    # ---- Optional -n nickname filter ----
    my $target_nick;
    if (@args && defined $args[0] && $args[0] eq '-n') {
        shift @args; # remove -n
        $target_nick = shift @args; # nickname
        unless (defined $target_nick && $target_nick ne '') {
            botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
            return;
        }
    }

    # Remaining args = search terms
    my @terms = @args;

    # If no terms and no nick => nothing to search
    unless (@terms || $target_nick) {
        botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
        return;
    }

    # ---- Output routing: chan vs private ----
    my $is_private = !defined($channel) || $channel eq '';
    my $dest       = $target_chan; # we always display in the target channel when it exists

    my $send = $is_private
        ? sub { my ($msg) = @_; botNotice($self, $nick, $msg) }
        : sub { my ($msg) = @_; botPrivmsg($self, $dest, $msg) };

    # ---- Build SQL grep-like query ----
    # We search in CHANNEL_LOG / CHANNEL for the target channel,
    # optional nick, and optional pattern in publictext.
    my @where = (
        'c.name = ?',                  # channel
        'cl.publictext NOT LIKE ?',    # avoid matching qlog itself
    );
    my @bind  = ($target_chan, '%qlog%');

    if (defined $target_nick) {
        push @where, 'cl.nick LIKE ?';
        push @bind,  $target_nick;
    }

    if (@terms) {
        # Build a LIKE pattern: word1%word2%word3 ...
        my $pattern = '%' . join('%', @terms) . '%';
        push @where, 'cl.publictext LIKE ?';
        push @bind,  $pattern;
    }

    my $where_sql = join(' AND ', @where);

    my $limit = 5;    # show up to 5 matches
    $limit = 1 if $limit < 1;

    my $sql = <<"SQL";
SELECT cl.ts, cl.nick, cl.publictext
FROM CHANNEL_LOG cl
JOIN CHANNEL c ON c.id_channel = cl.id_channel
WHERE $where_sql
ORDER BY cl.ts DESC
LIMIT $limit
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute(@bind)) {
        $self->{logger}->log(1, "mbChannelLog_ctx() SQL Error: $DBI::errstr | Query: $sql");
        return;
    }

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }
    $sth->finish;

    unless (@rows) {
        $send->("($nick qlog) No result.");
        logBot($self, $message, $dest, "qlog", @args);
        return;
    }

    my $total = scalar @rows;

    # ---- Display results, first match highlighted as "main" ----
    my $idx = 0;
    for my $row (@rows) {
        my $ts   = $row->{ts}        // '';
        my $n    = $row->{nick}      // '';
        my $text = $row->{publictext} // '';

        # Compact whitespace and truncate to avoid flooding
        $text =~ s/\s+/ /g;
        if (length($text) > 300) {
            $text = substr($text, 0, 297) . '...';
        }

        my $pos = $idx + 1;
        my $tag = ($pos == 1)
            ? "[1/$total] latest match"
            : "[$pos/$total]";

        $send->("($nick qlog $tag) $ts <$n> $text");
        $idx++;
    }

    logBot($self, $message, $dest, "qlog", @args);
    return 1;
}

# Check if a nick is in the HAILO_EXCLUSION_NICK table
sub setTMDBLangChannel_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = @{ $ctx->args };

    # Syntax: tmdblangset [#channel] <lang>
    # Si le premier arg commence par #, c'est un channel cible explicite
    my ($target_channel, $lang);
    if (defined($args[0]) && $args[0] =~ /^#/) {
        $target_channel = shift @args;
        $lang           = shift @args;
    } else {
        $target_channel = $channel;
        $lang           = shift @args;
    }

    unless (defined($lang) && $lang ne "") {
        botNotice($self, $nick, "Syntax: tmdblangset [#channel] <lang>  (ex: fr-FR, en-US)");
        return;
    }

    # Vérification d'authentification
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Administrator+ bypasse tout ; sinon il faut être owner du channel cible (level 500)
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    unless ($is_admin) {
        my $has_chan_level = eval {
            checkUserChannelLevel($self, $message, $target_channel, $user->id, 500) ? 1 : 0;
        } || 0;
        unless ($has_chan_level) {
            botNotice($self, $nick, "Your level does not allow you to use this command.");
            return;
        }
    }

    my $id_channel = getIdChannel($self, $target_channel);
    unless (defined($id_channel)) {
        botNotice($self, $nick, "Unknown channel: $target_channel");
        return;
    }

    my $sQuery = "UPDATE CHANNEL SET tmdb_lang = ? WHERE id_channel = ?";
    my $sth    = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute($lang, $id_channel)) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " Query: " . $sQuery);
        botNotice($self, $nick, "Database error while updating tmdb_lang.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "tmdb_lang set to '$lang' for $target_channel");
    logBot($self, $message, $target_channel, "tmdblangset", ($target_channel, $lang));
}

sub getTMDBLangChannel (@) {
	my ($self, $sChannel) = @_;
	my $sQuery = "SELECT tmdb_lang FROM CHANNEL WHERE name LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $tmdb_lang = $ref->{'tmdb_lang'};
			$sth->finish;
			return $tmdb_lang || 'en-US';
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

# Get detailed TMDB info for the first matching result

1;
