package Mediabot::Hailo;

# =============================================================================
# Mediabot::Hailo — Hailo AI chatter integration
#
# Provides all Hailo-related commands and helpers:
#   init_hailo, get_hailo, is_hailo_excluded_nick,
#   hailo_ignore_ctx, hailo_unignore_ctx, hailo_status_ctx,
#   hailo_chatter_ctx, get_hailo_channel_ratio, set_hailo_channel_ratio
#
# All subs are called as methods on the Mediabot object ($self).
# External dependencies (botNotice, logBot, etc.) remain in Mediabot.pm
# and are called via $self->method() or as package functions.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use Mediabot::Helpers;
use Hailo;

our @EXPORT = qw(
    init_hailo
    get_hailo
    is_hailo_excluded_nick
    hailo_ignore_ctx
    hailo_unignore_ctx
    hailo_status_ctx
    hailo_chatter_ctx
    get_hailo_channel_ratio
    set_hailo_channel_ratio
);

sub init_hailo(@) {
	my ($self) = shift;
	$self->{logger}->log(0,"Initialize Hailo");
	my $hailo = Hailo->new(
		brain => 'mediabot_v3.brn',
		save_on_exit => 1,
	);
	$self->{hailo} = $hailo;
}

# Get the Hailo object
sub get_hailo(@) {
	my ($self) = shift;
	return $self->{hailo};
}

# Clean up and exit the program (with proper Net::Async::IRC QUIT)
sub is_hailo_excluded_nick(@) {
	my ($self,$nick) = @_;
	my $sQuery = "SELECT * FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($nick)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sOutput = "";
		if (my $ref = $sth->fetchrow_hashref()) {
			$sth->finish;
			return 1;
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

# hailo_ignore <nick>
# Add a nick to HAILO_EXCLUSION_NICK so Hailo will ignore it
# Requires: authenticated + Master
sub hailo_ignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user and permissions ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    # --- Syntax and arguments ---
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_ignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    # --- Check if nick is already ignored ---
    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL Error (SELECT): $DBI::errstr | Query: $sql");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        $sth->finish;
        botNotice($self, $caller, "Nick $target_nick is already ignored by Hailo (id $ref->{id_hailo_exclusion_nick}).");
        return;
    }
    $sth->finish;

    # --- Insert new ignore entry ---
    $sql = "INSERT INTO HAILO_EXCLUSION_NICK (nick) VALUES (?)";
    $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL Error (INSERT): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while adding Hailo ignore for $target_nick.");
        return;
    }
    $sth->finish;

    botNotice($self, $caller, "Hailo will now ignore nick $target_nick.");
    logBot($self, $message, $ctx->channel, "hailo_ignore", $target_nick);

    return 1;
}

# hailo_unignore <nick>
# Remove a nick from HAILO_EXCLUSION_NICK so Hailo will reply again
# Requires: authenticated + Master
sub hailo_unignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $chan    = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user and permissions ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    # --- Syntax and arguments ---
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_unignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    # --- Check if nick is currently ignored ---
    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL Error (SELECT): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botNotice($self, $caller, "Nick $target_nick is not ignored by Hailo.");
        return;
    }

    my $id_excl = $row->{id_hailo_exclusion_nick};

    # --- Delete ignore entry ---
    $sql = "DELETE FROM HAILO_EXCLUSION_NICK WHERE id_hailo_exclusion_nick = ?";
    $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($id_excl)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL Error (DELETE): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while removing Hailo ignore for $target_nick.");
        return;
    }
    $sth->finish;

    botNotice($self, $caller, "Hailo will no longer ignore nick $target_nick.");
    logBot($self, $message, $chan, "hailo_unignore", $target_nick);

    return 1;
}

# hailo_status
# Show Hailo brain statistics (tokens, expressions, links, etc.)
# Requires: authenticated + Master
sub hailo_status_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    # --- Auth check ---
    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (user $who is not logged in)";
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

    # --- Permission check: Master+ ---
    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Get Hailo object ---
    my $hailo = eval { get_hailo($self) };
    if ($@ || !$hailo) {
        $self->{logger}->log(1, "hailo_status_ctx(): failed to get Hailo object: $@");
        botNotice($self, $nick, "Internal error: could not access Hailo brain.");
        return;
    }

    # --- Get stats from Hailo ---
    my $stats_raw = eval { $hailo->stats };
    if ($@) {
        $self->{logger}->log(1, "hailo_status_ctx(): Hailo->stats died: $@");
        botNotice($self, $nick, "Internal error: Hailo stats() failed.");
        return;
    }
    unless (defined $stats_raw) {
        botNotice($self, $nick, "Hailo did not return any stats.");
        return;
    }

    my $summary;
    my $extra = "";

    if (ref $stats_raw eq 'HASH') {
        my $href = $stats_raw;

        # Generic listing of all available keys
        my @pairs;
        for my $k (sort keys %$href) {
            next unless defined $href->{$k};
            push @pairs, "$k=$href->{$k}";
        }
        $summary = join(", ", @pairs) || "No stats available";

        # Try to compute some useful derived metrics if we recognize keys
        my $tokens = $href->{tokens};
        my $prev   = $href->{previous_token_links} // $href->{previous_links};
        my $next   = $href->{next_token_links}     // $href->{next_links};

        if (defined $tokens && $tokens > 0 && defined $prev && defined $next) {
            my $total_links = $prev + $next;
            my $avg_links   = sprintf("%.2f", $total_links / $tokens);
            $extra = " | total_links=$total_links, avg_links_per_token=$avg_links";
        }
    }
    else {
        # Old behaviour: stats() returns a simple string like
        # "X tokens, Y expressions, Z previous links and W next links"
        $summary = $stats_raw;
    }

    my $msg_out = "Hailo stats: $summary$extra";

    if (defined $channel && $channel ne '') {
        botPrivmsg($self, $channel, $msg_out);
        logBot($self, $message, $channel, "hailo_status", undef);
    } else {
        botNotice($self, $nick, $msg_out);
        logBot($self, $message, undef, "hailo_status", undef);
    }

    return 1;
}

# Get the Hailo chatter ratio for a specific channel
sub get_hailo_channel_ratio(@) {
	my ($self,$sChannel) = @_;
	my $sQuery = "SELECT ratio FROM HAILO_CHANNEL,CHANNEL WHERE HAILO_CHANNEL.id_channel=CHANNEL.id_channel AND name like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $ratio = $ref->{'ratio'};
			$sth->finish;
			return $ratio;
		}
		else {
			$sth->finish;
			return -1;
		}
	}
}

# Set the Hailo chatter ratio for a specific channel
sub set_hailo_channel_ratio {
	my ($self, $sChannel, $ratio) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "set_hailo_channel_ratio() unknown channel: $sChannel");
		return undef;
	}

	my $id_channel = $channel_obj->get_id;

	# Check if HAILO_CHANNEL entry exists for this channel
	my $sQuery = "SELECT * FROM HAILO_CHANNEL WHERE id_channel = ?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		return undef;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		# Entry exists, update ratio
		$sQuery = "UPDATE HAILO_CHANNEL SET ratio = ? WHERE id_channel = ?";
		$sth = $self->{dbh}->prepare($sQuery);

		if ($sth->execute($ratio, $id_channel)) {
			$sth->finish;
			$self->{logger}->log(3, "set_hailo_channel_ratio updated hailo chatter ratio to $ratio for $sChannel");
			return 0;
		} else {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			return undef;
		}
	} else {
		# No entry yet, insert new one
		$sQuery = "INSERT INTO HAILO_CHANNEL (id_channel, ratio) VALUES (?, ?)";
		$sth = $self->{dbh}->prepare($sQuery);

		if ($sth->execute($id_channel, $ratio)) {
			$sth->finish;
			$self->{logger}->log(3, "set_hailo_channel_ratio set hailo chatter ratio to $ratio for $sChannel");
			return 0;
		} else {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			return undef;
		}
	}
}


# hailo_chatter
# Get or set Hailo chatter ratio for a given channel.
# - Query: hailo_chatter [#channel]
# - Set:   hailo_chatter [#channel] <ratio 0-100>
# Stored ratio is still "inverted" (100 - user_ratio) to keep legacy behaviour.
sub hailo_chatter_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = ();
    if (ref($ctx->args) eq 'ARRAY') {
        @args = @{ $ctx->args };
    } elsif (defined $ctx->args) {
        @args = ($ctx->args);
    }

    # --- Auth / permission checks (Master+) ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (user $who is not logged in)";
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

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Resolve target channel ---
    my $target_chan = undef;

    # First arg can be a channel name
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        $target_chan = $channel if defined $channel && $channel =~ /^#/;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }

    # --- If no numeric arg: just display current ratio ---
    my $is_query_only = 1;
    if (@args && defined $args[0] && $args[0] =~ /^\d+$/) {
        $is_query_only = 0;
    }

    if ($is_query_only) {
        my $stored_ratio = eval { get_hailo_channel_ratio($self, $target_chan) };
        if (!defined $stored_ratio || $stored_ratio == -1) {
            botNotice($self, $nick, "No Hailo chatter ratio set for $target_chan (using default behaviour).");
        } else {
            my $user_ratio = 100 - $stored_ratio;    # keep legacy inversion
            botNotice(
                $self,
                $nick,
                "Hailo chatter reply chance on $target_chan is currently ${user_ratio}%."
            );
        }
        logBot($self, $message, $target_chan, "hailo_chatter", "show $target_chan");
        return 1;
    }

    # --- Set mode: hailo_chatter [#channel] <ratio> ---
    my $ratio = $args[0];

    unless (defined $ratio && $ratio =~ /^\d+$/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }
    if ($ratio > 100) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        botNotice($self, $nick, "ratio must be between 0 and 100");
        return;
    }

    # Check that chanset +HailoChatter is enabled
    my $id_chanset_list = eval { getIdChansetList($self, "HailoChatter") };
    unless ($id_chanset_list) {
        botNotice($self, $nick, "Chanset list HailoChatter is not defined.");
        return;
    }

    my $id_channel_set = eval { getIdChannelSet($self, $target_chan, $id_chanset_list) };
    unless ($id_channel_set) {
        botNotice($self, $nick, "Chanset +HailoChatter is not set on $target_chan (use: chanset $target_chan +HailoChatter).");
        return;
    }

    # Legacy internal representation: store 100 - ratio
    my $internal_ratio = 100 - $ratio;

    my $ret = eval { set_hailo_channel_ratio($self, $target_chan, $internal_ratio) };
    if ($@) {
        $self->{logger}->log(1, "hailo_chatter_ctx(): set_hailo_channel_ratio died: $@");
        botNotice($self, $nick, "Internal error while setting Hailo chatter ratio.");
        return;
    }

    if ($ret) {
        botNotice($self, $nick, "HailoChatter's ratio is now set to ${ratio}% on $target_chan");
        logBot($self, $message, $target_chan, "hailo_chatter", "set $target_chan $ratio");
        return 1;
    } else {
        botNotice($self, $nick, "Failed to update HailoChatter ratio on $target_chan.");
        return;
    }
}

# whereis <hostname|IP>

1;
