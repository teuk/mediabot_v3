package Mediabot::DBCommands;

# =============================================================================
# Mediabot::DBCommands
# =============================================================================

use strict;
use warnings;
use POSIX qw(strftime);
use List::Util qw(min);
use Exporter 'import';
use Mediabot::Helpers;

our @EXPORT = qw(
    IgnoresList_ctx
    Yomomma_ctx
    addIgnore_ctx
    addResponder_ctx
    checkResponder
    delIgnore_ctx
    delResponder_ctx
    doResponder
    dumpCmd_ctx
    getCommandCategory
    getLastRandomQuote
    getLastReponderTs
    getMainTimerTick
    lastCom_ctx
    mbAddTimer_ctx
    mbChownCommand_ctx
    mbCountCommand_ctx
    mbDbAddCategoryCommand_ctx
    mbDbAddCommand_ctx
    mbDbCommand
    mbDbHoldCommand_ctx
    mbDbModCommand
    mbDbModCommand_ctx
    mbDbMvCommand_ctx
    mbDbOwnersCommand_ctx
    mbDbRemCommand_ctx
    mbDbSearchCommand_ctx
    mbDbShowCommand_ctx
    mbLastCommand_ctx
    mbPopCommand_ctx
    mbRemTimer_ctx
    mbTimers_ctx
    mbTopCommand_ctx
    msgCmd_ctx
    onStartTimers
    setLastCommandTs
    setLastRandomQuote
    setLastReponderTs
    setMainTimerTick
);

sub setMainTimerTick(@) {
	my ($self,$timer) = @_;
	$self->{main_timer_tick} = $timer;
}

# Set refresh channel hashes
sub getMainTimerTick(@) {
	my $self = shift;
	return $self->{maint_timer_tick};
}

# Set IRC object
sub onStartTimers(@) {
	my $self = shift;
	my %hTimers;
	my $sQuery = "SELECT * FROM TIMERS";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		$self->{logger}->log(0,"Checking timers to set at startup");
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $id_timers = $ref->{'id_timers'};
			my $name = $ref->{'name'};
			my $duration = $ref->{'duration'};
			my $command = $ref->{'command'};
			my $sSecondText = ( $duration > 1 ? "seconds" : "second" );
			$self->{logger}->log(0,"Timer $name - id : $id_timers - every $duration $sSecondText - command $command");
			my $timer = IO::Async::Timer::Periodic->new(
			    interval => $duration,
			    on_tick => sub {
			    	$self->{logger}->log(4,"Timer every $duration seconds : $command");
  					$self->{irc}->write("$command\x0d\x0a");
					},
			);
			$hTimers{$name} = $timer;
			$self->{loop}->add( $timer );
			$timer->start;
			$i++;
		}
		if ( $i ) {
			my $sTimerText = ( $i > 1 ? "timers" : "timer" );
			$self->{logger}->log(0,"$i active $sTimerText set at startup");
		}
		else {
			$self->{logger}->log(0,"No timer to set at startup");
		}
	}
	$sth->finish;
	%{$self->{hTimers}} = %hTimers;
}

# Handle user join event
sub dumpCmd_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @raw = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Owner');

    unless (@raw) {
        $self->botNotice($nick, "Syntax: dump <raw irc command>");
        return;
    }

    my $cmd = join(' ', @raw);
    $self->{irc}->write("$cmd\x0d\x0a");

    logBot($self, $ctx->message, undef, 'dump', $cmd);
}

# Context-based msg command: Allows an Administrator to send a private message to a user or channel
sub msgCmd_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target = shift(@args) // '';
    my $text   = join(' ', @args);

    for ($target, $text) { $_ //= ''; s/^\s+|\s+$//g; }

    return unless $ctx->require_level('Administrator');

    unless ($target ne '' && $text ne '') {
        $self->botNotice($nick, "Syntax: msg <target> <text>");
        return;
    }

    botPrivmsg($self, $target, $text);
    logBot($self, $ctx->message, undef, 'msg', $target, $text);
}

# Context-based: Allows an Administrator to force the bot to say something in a given channel
sub setLastRandomQuote(@) {
	my ($self,$iLastRandomQuote) = @_;
	$self->{iLastRandomQuote} = $iLastRandomQuote;
}

sub getLastRandomQuote(@) {
	my $self = shift;
	return $self->{iLastRandomQuote};
}

sub mbAddTimer_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Owner');

    my ($name, $interval, @raw) = @args;

    unless (
        defined $name && $name ne '' &&
        defined $interval && $interval =~ /^\d+$/ &&
        @raw
    ) {
        $self->botNotice($nick, "Syntax: addtimer <name> <seconds> <raw>");
        return;
    }

    my $cmd = join(' ', @raw);

    $self->{hTimers} ||= {};
    if (exists $self->{hTimers}{$name}) {
        $self->botNotice($nick, "Timer $name already exists");
        return;
    }

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            $self->{logger}->log(4, "Timer [$name] tick: $cmd");
            $self->{irc}->write("$cmd\x0d\x0a");
        },
    );

    $self->{loop}->add($timer);
    $timer->start;
    $self->{hTimers}{$name} = $timer;

    eval {
        $self->{dbh}->do(
            "INSERT INTO TIMERS (name, duration, command) VALUES (?,?,?)",
            undef, $name, $interval, $cmd
        );
        1;
    } or do {
        $self->{logger}->log(1, "SQL Error: $@ (INSERT INTO TIMERS)");
        $self->botNotice($nick, "Timer $name added in memory, but DB insert failed");
    };

    $self->botNotice($nick, "Timer $name added");
    logBot($self, $ctx->message, undef, 'addtimer', $name);
}

# Handle remtimer command (Owner only, Context-based)
sub mbRemTimer_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $name = $args[0];

    return unless $ctx->require_level('Owner');

    $self->{hTimers} ||= {};

    unless (defined $name && $name ne '' && exists $self->{hTimers}{$name}) {
        $self->botNotice($nick, "Unknown timer " . (defined($name) ? $name : ''));
        return;
    }

    $self->{loop}->remove($self->{hTimers}{$name});
    delete $self->{hTimers}{$name};

    eval {
        $self->{dbh}->do("DELETE FROM TIMERS WHERE name=?", undef, $name);
        1;
    } or do {
        $self->{logger}->log(1, "SQL Error: $@ (DELETE FROM TIMERS)");
    };

    $self->botNotice($nick, "Timer $name removed");
    logBot($self, $ctx->message, undef, 'remtimer', $name);
}

# List all registered timers currently stored in the database (Owner only, Context-based)
sub mbTimers_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Owner');

    my $sth = $self->{dbh}->prepare("SELECT name, duration, command FROM TIMERS");
    unless ($sth && $sth->execute) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr - SELECT TIMERS");
        $self->botNotice($nick, "DB error while reading timers");
        return;
    }

    my $count = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $self->botNotice($nick, "$r->{name} - every $r->{duration}s - $r->{command}");
        $count++;
    }
    $sth->finish;

    $self->botNotice($nick, "No active timers") unless $count;
    logBot($self, $ctx->message, undef, 'timers', undef);
}

# Allows a user to set their IRC bot password.
# Syntax: /msg <botnick> pass <new_password>
sub mbDbAddCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Administrator+
    return unless $ctx->require_level("Administrator");
    my $user = $ctx->user;
    return unless $user;

    # Syntax:
    # addcmd <command> <message|action> <category> <text...>
    unless (
        defined $args[0] && $args[0] ne ''
        && defined $args[1] && $args[1] =~ /^(message|action)$/i
        && defined $args[2] && $args[2] ne ''
        && defined $args[3] && $args[3] ne ''
    ) {
        botNotice($self, $nick, "Syntax: addcmd <command> <message|action> <category> <text>");
        botNotice($self, $nick, "Ex: m addcmd Hello message general Hello %n !");
        return;
    }

    my $sCommand  = shift @args;
    my $sType     = shift @args;
    my $sCategory = shift @args;

    # Resolve category
    my $id_cat = getCommandCategory($self, $sCategory);
    unless (defined $id_cat) {
        botNotice($self, $nick, "Unknown category : $sCategory");
        return;
    }

    # Check duplicates
    my $query_check = "SELECT command FROM PUBLIC_COMMANDS WHERE command LIKE ?";
    my $sth = $self->{dbh}->prepare($query_check);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query_check");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $nick, "$sCommand command already exists");
        $sth->finish;
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Adding command $sCommand [$sType] " . join(" ", @args));

    # Build action (kept identical to legacy behavior)
    my $sAction = ($sType =~ /^message$/i) ? "PRIVMSG %c " : "ACTION %c ";
    $sAction   .= join(" ", @args);

    my $insert_query =
        "INSERT INTO PUBLIC_COMMANDS (id_user, id_public_commands_category, command, description, action) "
      . "VALUES (?, ?, ?, ?, ?)";

    $sth = $self->{dbh}->prepare($insert_query);
    unless ($sth && $sth->execute($user->id, $id_cat, $sCommand, $sCommand, $sAction)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $insert_query");
        return;
    }

    botNotice($self, $nick, "Command $sCommand added");
    logBot($self, $ctx->message, undef, "addcmd", ("Command $sCommand added"));

    $sth->finish;
    return;
}

# Get command category ID from description
sub getCommandCategory(@) {
	my ($self,$sCategory) = @_;
	my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sCategory)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			return ($ref->{'id_public_commands_category'});
		}
		else {
			return undef;
		}
	}
	$sth->finish;
}

# Remove a public command from the database (Administrator+)
# - Allowed if:
#   * caller is the owner of the command, OR
#   * caller is Master+ (stronger than Administrator in our hierarchy)
sub mbDbRemCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Administrator+
    return unless $ctx->require_level("Administrator");
    my $user = $ctx->user;
    return unless $user;

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: remcmd <command>");
        return;
    }

    my $sCommand = shift @args;

    my $query = "SELECT id_user, id_public_commands FROM PUBLIC_COMMANDS WHERE command LIKE ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "$sCommand command does not exist");
        return;
    }

    my $id_command_user    = $ref->{id_user};
    my $id_public_commands = $ref->{id_public_commands};

    # Authorization: owner OR Master+
    my $is_master_plus = eval { $user->has_level("Master") ? 1 : 0 } || 0;
    unless (($id_command_user // -1) == $user->id || $is_master_plus) {
        botNotice($self, $nick, "$sCommand command belongs to another user");
        return;
    }

    botNotice($self, $nick, "Removing command $sCommand");

    my $delete_query = "DELETE FROM PUBLIC_COMMANDS WHERE id_public_commands=?";
    my $sth_del = $self->{dbh}->prepare($delete_query);
    unless ($sth_del && $sth_del->execute($id_public_commands)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $delete_query");
        return;
    }
    $sth_del->finish;

    botNotice($self, $nick, "Command $sCommand removed");
    logBot($self, $ctx->message, undef, "remcmd", ("Command $sCommand removed"));

    return;
}

# Modify an existing public command (Administrator+)
sub mbDbModCommand {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " modcmd command attempt (user " . ($user ? $user->handle : 'unknown') . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->has_level("Administrator")) {
        my $notice = $message->prefix . " modcmd command attempt (command level [Administrator] for user " . $user->handle . "[" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (
        defined($tArgs[0]) && $tArgs[0] ne "" &&
        defined($tArgs[1]) && $tArgs[1] =~ /^(message|action)$/i &&
        defined($tArgs[2]) && $tArgs[2] ne "" &&
        defined($tArgs[3]) && $tArgs[3] ne ""
    ) {
        botNotice($self, $sNick, "Syntax: modcmd <command> <message|action> <category> <text>");
        return;
    }

    my $sCommand  = shift @tArgs;
    my $sType     = shift @tArgs;
    my $sCategory = shift @tArgs;

    my $query = "SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command LIKE ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_owner     = $ref->{id_user};
        my $id_command   = $ref->{id_public_commands};

        if ($id_owner == $user->id || $user->has_level("Master")) {
            my $id_cat = getCommandCategory($self, $sCategory);
            unless (defined $id_cat) {
                botNotice($self, $sNick, "Unknown category : $sCategory");
                return;
            }

            botNotice($self, $sNick, "Modifying command $sCommand [$sType] " . join(" ", @tArgs));

            my $sAction = $sType =~ /^message$/i ? "PRIVMSG %c " : "ACTION %c ";
            $sAction .= join(" ", @tArgs);

            my $update_query = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=?, action=? WHERE id_public_commands=?";
            my $sth_upd = $self->{dbh}->prepare($update_query);
            unless ($sth_upd->execute($id_cat, $sAction, $id_command)) {
                $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
                return;
            }

            botNotice($self, $sNick, "Command $sCommand modified");
            logBot($self, $message, undef, "modcmd", ("Command $sCommand modified"));
            $sth_upd->finish;
        } else {
            botNotice($self, $sNick, "$sCommand command belongs to another user");
        }
    } else {
        botNotice($self, $sNick, "$sCommand command does not exist");
    }

    $sth->finish;
}

# modcmd => sub { mbDbModCommand_ctx($ctx) },

# Modify an existing public command (Administrator+)
# Syntax: modcmd <command> <message|action> <category> <text>
# - Allowed if:
#   * caller owns the command, OR
#   * caller is Master+
sub mbDbModCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Administrator+
    return unless $ctx->require_level("Administrator");
    my $user = $ctx->user;
    return unless $user;

    unless (
        defined($args[0]) && $args[0] ne "" &&
        defined($args[1]) && $args[1] =~ /^(message|action)$/i &&
        defined($args[2]) && $args[2] ne "" &&
        defined($args[3]) && $args[3] ne ""
    ) {
        botNotice($self, $nick, "Syntax: modcmd <command> <message|action> <category> <text>");
        return;
    }

    my $sCommand  = shift @args;
    my $sType     = shift @args;
    my $sCategory = shift @args;

    my $query = "SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command LIKE ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "$sCommand command does not exist");
        return;
    }

    my $id_owner   = $ref->{id_user};
    my $id_command = $ref->{id_public_commands};

    my $is_master_plus = eval { $user->has_level("Master") ? 1 : 0 } || 0;
    unless (($id_owner // -1) == $user->id || $is_master_plus) {
        botNotice($self, $nick, "$sCommand command belongs to another user");
        return;
    }

    my $id_cat = getCommandCategory($self, $sCategory);
    unless (defined $id_cat) {
        botNotice($self, $nick, "Unknown category : $sCategory");
        return;
    }

    botNotice($self, $nick, "Modifying command $sCommand [$sType] " . join(" ", @args));

    my $sAction = ($sType =~ /^message$/i) ? "PRIVMSG %c " : "ACTION %c ";
    $sAction .= join(" ", @args);

    my $update_query = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=?, action=? WHERE id_public_commands=?";
    my $sth_upd = $self->{dbh}->prepare($update_query);
    unless ($sth_upd && $sth_upd->execute($id_cat, $sAction, $id_command)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
        return;
    }
    $sth_upd->finish;

    botNotice($self, $nick, "Command $sCommand modified");
    logBot($self, $ctx->message, undef, "modcmd", ("Command $sCommand modified"));

    return;
}

# Change the owner of a public command (Master+)
# Syntax: chowncmd <command> <username>
sub mbChownCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Master+
    return unless $ctx->require_level("Master");
    my $user = $ctx->user;
    return unless $user;

    unless (defined($args[0]) && $args[0] ne "" && defined($args[1]) && $args[1] ne "") {
        botNotice($self, $nick, "Syntax: chowncmd <command> <username>");
        return;
    }

    my ($sCommand, $sTargetUser) = @args[0,1];

    # Step 1: Get command info (current owner)
    my $cmd_query = q{
        SELECT PC.id_public_commands,
               PC.id_user AS old_user,
               U.nickname AS old_nick
        FROM PUBLIC_COMMANDS PC
        JOIN USER U ON PC.id_user = U.id_user
        WHERE PC.command = ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($cmd_query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $cmd_query");
        return;
    }

    my $cmd_info = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($cmd_info) {
        botNotice($self, $nick, "$sCommand command does not exist");
        return;
    }

    my $id_cmd       = $cmd_info->{id_public_commands};
    my $old_nickname = $cmd_info->{old_nick} // '?';

    # Step 2: Resolve new owner user id
    my $user_query = q{
        SELECT id_user
        FROM USER
        WHERE nickname = ?
        LIMIT 1
    };

    $sth = $self->{dbh}->prepare($user_query);
    unless ($sth && $sth->execute($sTargetUser)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $user_query");
        return;
    }

    my $target_user = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($target_user) {
        botNotice($self, $nick, "$sTargetUser user does not exist");
        return;
    }

    my $id_new_user = $target_user->{id_user};

    # Step 3: Update owner
    my $update_query = "UPDATE PUBLIC_COMMANDS SET id_user=? WHERE id_public_commands=?";

    $sth = $self->{dbh}->prepare($update_query);
    unless ($sth && $sth->execute($id_new_user, $id_cmd)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
        return;
    }
    $sth->finish;

    my $msg = "Changed owner of command $sCommand ($old_nickname -> $sTargetUser)";
    botNotice($self, $nick, $msg);
    logBot($self, $ctx->message, undef, "chowncmd", $msg);

    return;
}

# Show info about a public command
# Syntax: showcmd <command>
sub mbDbShowCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (defined($args[0]) && $args[0] ne "") {
        botNotice($self, $nick, "Syntax: showcmd <command>");
        return;
    }

    my $sCommand = $args[0];

    my $sQuery = q{
        SELECT
            PC.hits,
            PC.id_user,
            PC.creation_date,
            PC.action,
            PCC.description AS category
        FROM PUBLIC_COMMANDS PC
        JOIN PUBLIC_COMMANDS_CATEGORY PCC
          ON PC.id_public_commands_category = PCC.id_public_commands_category
        WHERE PC.command LIKE ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $sQuery");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    if ($ref) {
        my $id_user       = $ref->{id_user};
        my $sCategory     = $ref->{category} // 'Unknown';
        my $sCreationDate = $ref->{creation_date} // 'Unknown';
        my $sAction       = $ref->{action} // '';
        my $hits          = $ref->{hits} // 0;
        my $sHitsWord     = ($hits > 1) ? "$hits hits" : ($hits == 1 ? "1 hit" : "0 hit");

        my $sUserHandle = "Unknown";
        if (defined $id_user) {
            my $q2 = "SELECT nickname FROM USER WHERE id_user=? LIMIT 1";
            my $sth2 = $self->{dbh}->prepare($q2);
            if ($sth2 && $sth2->execute($id_user)) {
                my $ref2 = $sth2->fetchrow_hashref();
                $sUserHandle = $ref2->{nickname} if $ref2 && defined $ref2->{nickname};
            } else {
                $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $q2");
            }
            $sth2->finish if $sth2;
        }

        botNotice($self, $nick, "Command : $sCommand Author : $sUserHandle Created : $sCreationDate");
        botNotice($self, $nick, "$sHitsWord Category : $sCategory Action : $sAction");
    } else {
        botNotice($self, $nick, "$sCommand command does not exist");
    }

    logBot($self, $ctx->message, undef, "showcmd", $sCommand);
    return;
}

# chanstatlines => sub { channelStatLines_ctx($ctx) },

# Show the number of lines sent on a channel during the last hour (Administrator+)
sub mbDbCommand(@) {
	my ($self,$message,$sChannel,$sNick,$sCommand,@tArgs) = @_;
	$self->{logger}->log(2,"Check SQL command : $sCommand");
	my $sQuery = "SELECT * FROM PUBLIC_COMMANDS WHERE command like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sCommand)) {
		$self->{logger}->log(1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_public_commands = $ref->{'id_public_commands'};
			my $description = $ref->{'description'};
			my $action = $ref->{'action'};
			my $hits = $ref->{'hits'};
			$hits++;
			$sQuery = "UPDATE PUBLIC_COMMANDS SET hits=? WHERE id_public_commands=?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($hits,$id_public_commands)) {
				$self->{logger}->log(1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$self->{logger}->log(2,"SQL command found : $sCommand description : $description action : $action");
				my ($actionType,$actionTo,$actionDo) = split(/ /,$action,3);
				if (( $actionType eq 'PRIVMSG' ) || ( $actionType eq 'ACTION' )){
					if ( $actionTo eq '%c' ) {
						$actionDo = evalAction($self,$message,$sNick,$sChannel,$sCommand,$actionDo,@tArgs);
						if ( $actionType eq 'PRIVMSG' ) {
							botPrivmsg($self,$sChannel,$actionDo);
						}
						else {
							botAction($self,$sChannel,$actionDo);
						}
					}
					return 1;
				}
				else {
					$self->{logger}->log(2,"Unknown actionType : $actionType");
					return 0;
				}
			}
		}
		else {
			return 0;
		}
	}
	$sth->finish;
}

use POSIX qw(strftime);

# Display the bot birth date and its age (Context version)
sub mbDbMvCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Master+
    return unless $ctx->require_level("Master");
    my $user = $ctx->user;
    return unless $user;

    unless (defined $args[0] && $args[0] ne "" && defined $args[1] && $args[1] ne "") {
        botNotice($self, $nick, "Syntax: mvcmd <old_command> <new_command>");
        return;
    }

    my ($old_cmd, $new_cmd) = @args[0,1];

    # 1) New name must not already exist
    my $sth = $self->{dbh}->prepare("SELECT 1 FROM PUBLIC_COMMANDS WHERE command = ? LIMIT 1");
    unless ($sth && $sth->execute($new_cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT exists(new_cmd)");
        return;
    }
    if (my $existing = $sth->fetchrow_arrayref) {
        $sth->finish;
        botNotice($self, $nick, "Command $new_cmd already exists. Please choose another name.");
        return;
    }
    $sth->finish;

    # 2) Load old command
    $sth = $self->{dbh}->prepare("SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command = ? LIMIT 1");
    unless ($sth && $sth->execute($old_cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT for $old_cmd");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "Command $old_cmd does not exist.");
        return;
    }

    my $id_cmd   = $ref->{id_public_commands};
    my $id_owner = $ref->{id_user};

    # 3) Ownership check (Master+ can rename anything, but keep explicit)
    my $is_master_plus = eval { $user->has_level("Master") ? 1 : 0 } || 0;
    unless (($id_owner // -1) == $user->id || $is_master_plus) {
        botNotice($self, $nick, "You do not own $old_cmd and are not Master.");
        return;
    }

    # 4) Rename
    $sth = $self->{dbh}->prepare("UPDATE PUBLIC_COMMANDS SET command = ? WHERE id_public_commands = ?");
    unless ($sth && $sth->execute($new_cmd, $id_cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: UPDATE to $new_cmd");
        botNotice($self, $nick, "Failed to rename $old_cmd to $new_cmd. Does $new_cmd already exist?");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Command $old_cmd has been renamed to $new_cmd.");
    logBot($self, $ctx->message, undef, "mvcmd", "Command $old_cmd renamed to $new_cmd");

    return;
}

# countcmd — show total public commands + breakdown by category
# Context-based migration:
# - Uses ctx for bot/nick/channel/message/args
# - Stays one-line (safe truncation with "...")
# - Sends to channel if invoked in-channel, otherwise NOTICE
sub mbCountCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Prefer output where the command was invoked
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    # Total commands
    my $sql_total = "SELECT COUNT(*) AS nbCommands FROM PUBLIC_COMMANDS";
    my $sth = $self->{dbh}->prepare($sql_total);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbCountCommand_ctx() SQL Error: $DBI::errstr Query: $sql_total");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my $nb_total = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $nb_total = $ref->{nbCommands} // 0;
    }
    $sth->finish;

    # Breakdown by category
    my $sql_cat = q{
        SELECT PCC.description AS category, COUNT(*) AS nbCommands
        FROM PUBLIC_COMMANDS PC
        JOIN PUBLIC_COMMANDS_CATEGORY PCC
          ON PC.id_public_commands_category = PCC.id_public_commands_category
        GROUP BY PCC.description
        ORDER BY PCC.description
    };

    $sth = $self->{dbh}->prepare($sql_cat);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbCountCommand_ctx() SQL Error: $DBI::errstr Query: $sql_cat");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @parts;
    while (my $r = $sth->fetchrow_hashref()) {
        my $cat = $r->{category}  // next;
        my $nb  = $r->{nbCommands} // 0;
        push @parts, "($cat $nb)";
    }
    $sth->finish;

    my $prefix = "$nb_total Commands in database: ";
    my $line;

    if (@parts) {
        # Build one-line summary with truncation
        my $max_len = 360; # conservative for PRIVMSG/NOTICE payload
        $line = $prefix;

        for my $p (@parts) {
            my $candidate = ($line eq $prefix) ? ($line . $p) : ($line . " " . $p);
            if (length($candidate) > $max_len) {
                $line .= "..." if length($line) + 3 <= $max_len;
                last;
            }
            $line = $candidate;
        }
    } else {
        $line = "No command in database";
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $line);
        logBot($self, $ctx->message, $out_chan, "countcmd", undef);
    } else {
        botNotice($self, $nick, $line);
        logBot($self, $ctx->message, undef, "countcmd", undef);
    }

    return $nb_total;
}

# topcmd — show top 20 public commands by hits
# Context-based migration:
# - Uses ctx for bot/nick/channel/message/args
# - Better display: "#rank command (hits)" one-line, truncated with "..."
# - Sends to channel if invoked in-channel, otherwise NOTICE
sub mbTopCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Prefer output where the command was invoked
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    my $sql = "SELECT command, hits FROM PUBLIC_COMMANDS ORDER BY hits DESC LIMIT 20";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbTopCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @items;
    my $rank = 0;
    while (my $r = $sth->fetchrow_hashref()) {
        my $cmd  = $r->{command} // next;
        my $hits = $r->{hits}    // 0;
        $rank++;

        # Pretty compact: "1) hello(42)"
        push @items, $rank . ") " . $cmd . "(" . $hits . ")";
    }
    $sth->finish;

    my $line;
    if (@items) {
        # Single line, safe truncation
        my $prefix = "Top commands: ";
        my $max_len = 360; # conservative for IRC payload
        $line = $prefix;

        for my $it (@items) {
            my $candidate = ($line eq $prefix) ? ($line . $it) : ($line . " | " . $it);
            if (length($candidate) > $max_len) {
                $line .= "..." if length($line) + 3 <= $max_len;
                last;
            }
            $line = $candidate;
        }
    } else {
        $line = "No top commands in database";
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $line);
        logBot($self, $ctx->message, $out_chan, "topcmd", undef);
    } else {
        botNotice($self, $nick, $line);
        logBot($self, $ctx->message, undef, "topcmd", undef);
    }

    return scalar(@items);
}

# lastcmd — show last 10 public commands added (by creation_date desc)
# Improvements:
# - single-line output, truncated with "..." if too long
# - outputs to channel if invoked in-channel, else NOTICE
sub mbLastCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Prefer output where the command was invoked
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    my $sql = q{
        SELECT command
        FROM PUBLIC_COMMANDS
        ORDER BY creation_date DESC
        LIMIT 10
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbLastCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @cmds;
    while (my $r = $sth->fetchrow_hashref()) {
        push @cmds, $r->{command} if defined $r->{command} && $r->{command} ne '';
    }
    $sth->finish;

    my $prefix = "Last commands in database: ";
    my $line;

    if (!@cmds) {
        $line = "No command found in database";
    } else {
        my $max_len = 360; # conservative for IRC payload
        $line = $prefix;

        for my $c (@cmds) {
            my $candidate = ($line eq $prefix) ? ($line . $c) : ($line . " " . $c);
            if (length($candidate) > $max_len) {
                $line .= "..." if length($line) + 3 <= $max_len;
                last;
            }
            $line = $candidate;
        }
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $line);
        logBot($self, $ctx->message, $out_chan, "lastcmd", undef);
    } else {
        botNotice($self, $nick, $line);
        logBot($self, $ctx->message, undef, "lastcmd", undef);
    }

    return scalar(@cmds);
}

# searchcmd <keyword> — list public commands whose action contains <keyword>
# Improvements vs legacy:
# - Does NOT SELECT * + scan in Perl (uses SQL filtering)
# - Escapes LIKE wildcards so user input can't skew results
# - One-line output, truncated with "..." if too long
# - Outputs to channel if invoked in-channel, else NOTICE
sub mbDbSearchCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Prefer output where the command was invoked
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    unless (defined($args[0]) && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: searchcmd <keyword>");
        return;
    }

    my $kw = $args[0];

    # Escape LIKE wildcards so the keyword is treated literally
    my $like = $kw;
    $like =~ s/([\\%_])/\\$1/g;
    $like = '%' . $like . '%';

    my $sql = q{
        SELECT command
        FROM PUBLIC_COMMANDS
        WHERE action LIKE ? ESCAPE '\\'
        ORDER BY hits DESC, command ASC
        LIMIT 50
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($like)) {
        $self->{logger}->log(1, "mbDbSearchCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @cmds;
    while (my $r = $sth->fetchrow_hashref()) {
        push @cmds, $r->{command} if defined $r->{command} && $r->{command} ne '';
    }
    $sth->finish;

    my $line;
    if (!@cmds) {
        $line = "keyword '$kw' not found in commands";
    } else {
        my $prefix  = "Commands containing '$kw': ";
        my $max_len = 360; # conservative for IRC payload
        $line = $prefix;

        for my $c (@cmds) {
            my $candidate = ($line eq $prefix) ? ($line . $c) : ($line . " " . $c);
            if (length($candidate) > $max_len) {
                $line .= "..." if length($line) + 3 <= $max_len;
                last;
            }
            $line = $candidate;
        }
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $line);
        logBot($self, $ctx->message, $out_chan, "searchcmd", $kw);
    } else {
        botNotice($self, $nick, $line);
        logBot($self, $ctx->message, undef, "searchcmd", $kw);
    }

    return scalar(@cmds);
}

# Display the number of commands owned by each user
# Improvements:
# - single-line output, truncated with "..." if too long
# - explicit JOIN, predictable ordering
# - outputs to channel if invoked in-channel, else NOTICE
sub mbDbOwnersCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    my $sql = q{
        SELECT U.nickname AS nickname, COUNT(PC.command) AS nbCommands
        FROM PUBLIC_COMMANDS PC
        JOIN USER U ON PC.id_user = U.id_user
        GROUP BY U.nickname
        ORDER BY nbCommands DESC, U.nickname ASC
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbDbOwnersCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @items;
    while (my $r = $sth->fetchrow_hashref()) {
        my $u  = $r->{nickname};
        my $nb = $r->{nbCommands} // 0;
        next unless defined $u && $u ne '';
        push @items, "$u($nb)";
    }
    $sth->finish;

    my $msg;
    if (!@items) {
        $msg = "not found";
    } else {
        my $prefix  = "Number of commands by user: ";
        my $max_len = 360;
        $msg = $prefix;

        for my $it (@items) {
            my $candidate = ($msg eq $prefix) ? ($msg . $it) : ($msg . " " . $it);
            if (length($candidate) > $max_len) {
                $msg .= "..." if length($msg) + 3 <= $max_len;
                last;
            }
            $msg = $candidate;
        }
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $msg);
        logBot($self, $ctx->message, $out_chan, "owncmd", undef);
    } else {
        botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "owncmd", undef);
    }

    return scalar(@items);
}

# Temporarily disable (hold) a public command
# Requires: authenticated + Administrator+
sub mbDbHoldCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx holdcmd attempt (not logged in)");
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') } ) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx holdcmd attempt (requires Administrator for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Args
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: holdcmd <command>");
        return;
    }

    my $cmd = $args[0];

    # Lookup command
    my $sth = $self->{dbh}->prepare("SELECT id_public_commands, active FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth && $sth->execute($cmd)) {
        $self->{logger}->log(1, "mbDbHoldCommand_ctx() SQL Error: $DBI::errstr Query: SELECT for holdcmd");
        botNotice($self, $nick, "Database error while checking command.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "Command '$cmd' does not exist.");
        return;
    }

    unless ($ref->{active}) {
        botNotice($self, $nick, "Command '$cmd' is already on hold.");
        return;
    }

    my $id = $ref->{id_public_commands};

    # Put on hold
    $sth = $self->{dbh}->prepare("UPDATE PUBLIC_COMMANDS SET active = 0 WHERE id_public_commands = ?");
    unless ($sth && $sth->execute($id)) {
        $self->{logger}->log(1, "mbDbHoldCommand_ctx() SQL Error: $DBI::errstr Query: UPDATE holdcmd");
        botNotice($self, $nick, "Failed to put command '$cmd' on hold.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Command '$cmd' has been placed on hold.");
    logBot($self, $ctx->message, $ctx->channel, "holdcmd", "Command '$cmd' deactivated");

    return $id;
}

# Add a new public command category - Requires: authenticated + Administrator+
sub mbDbAddCategoryCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx addcatcmd attempt (not logged in)");
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx addcatcmd attempt (requires Administrator for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Args
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: addcatcmd <new_category>");
        return;
    }

    my $category = $args[0];

    # Check exists
    my $sth = $self->{dbh}->prepare(
        "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?"
    );
    unless ($sth && $sth->execute($category)) {
        $self->{logger}->log(1, "mbDbAddCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $nick, "Database error while checking category.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        $sth->finish;
        botNotice($self, $nick, "Category '$category' already exists.");
        return;
    }
    $sth->finish;

    # Insert
    $sth = $self->{dbh}->prepare("INSERT INTO PUBLIC_COMMANDS_CATEGORY (description) VALUES (?)");
    unless ($sth && $sth->execute($category)) {
        $self->{logger}->log(1, "mbDbAddCategoryCommand_ctx() SQL Error: $DBI::errstr Query: INSERT category");
        botNotice($self, $nick, "Failed to add category '$category'.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Category '$category' successfully added.");
    logBot($self, $ctx->message, $ctx->channel, "addcatcmd", "Category '$category' added");

    return 1;
}

# Change the category of an existing public command
# Requires: authenticated + Administrator+
sub mbPopCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Prefer output where the command was invoked
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    unless (defined($args[0]) && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: popcmd <nickhandle>");
        return;
    }

    my $target = $args[0];

    my $sql = q{
        SELECT PC.command, PC.hits
        FROM USER U
        JOIN PUBLIC_COMMANDS PC ON U.id_user = PC.id_user
        WHERE U.nickname LIKE ?
        ORDER BY PC.hits DESC
        LIMIT 20
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target)) {
        $self->{logger}->log(1, "mbPopCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @items;
    my $rank = 0;
    while (my $r = $sth->fetchrow_hashref()) {
        my $cmd  = $r->{command} // next;
        my $hits = $r->{hits}    // 0;
        $rank++;
        push @items, $rank . ") " . $cmd . "(" . $hits . ")";
    }
    $sth->finish;

    my $line;
    if (@items) {
        my $prefix  = "Popular commands for $target: ";
        my $max_len = 360; # conservative for IRC payload
        $line = $prefix;

        for my $it (@items) {
            my $candidate = ($line eq $prefix) ? ($line . $it) : ($line . " | " . $it);
            if (length($candidate) > $max_len) {
                $line .= "..." if length($line) + 3 <= $max_len;
                last;
            }
            $line = $candidate;
        }
    } else {
        $line = "No popular commands for $target";
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, $line);
        logBot($self, $ctx->message, $out_chan, "popcmd", $target);
    } else {
        botNotice($self, $nick, $line);
        logBot($self, $ctx->message, undef, "popcmd", $target);
    }

    return scalar(@items);
}

# Check if a timezone exists
sub checkResponder(@) {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my $sQuery = "SELECT answer,chance FROM RESPONDERS,CHANNEL WHERE ((CHANNEL.id_channel=RESPONDERS.id_channel AND CHANNEL.name like ?) OR (RESPONDERS.id_channel=0)) AND responder like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sMsg)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sAnswer = $ref->{'answer'};
			my $iChance = $ref->{'chance'};
			$self->{logger}->log(4,"checkResponder() Found answer $sAnswer for $sMsg with chance " . (100-$iChance) ." %");
			return $iChance;
		}
	}
	$sth->finish;
	return 100;
}

sub doResponder(@) {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my $sQuery = "SELECT id_responders,answer,hits FROM RESPONDERS,CHANNEL WHERE ((CHANNEL.id_channel=RESPONDERS.id_channel AND CHANNEL.name like ?) OR (RESPONDERS.id_channel=0)) AND responder like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sMsg)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sAnswer = $ref->{'answer'};
			my $id_responders = $ref->{'id_responders'};
			my $hits = $ref->{'hits'} + 1;
			my $actionDo = evalAction($self,$message,$sNick,$sChannel,$sMsg,$sAnswer);
			$self->{logger}->log(4,"checkResponder() Found answer $sAnswer");
			botPrivmsg($self,$sChannel,$actionDo);
			my $sQuery = "UPDATE RESPONDERS SET hits=? WHERE id_responders=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($hits,$id_responders)) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$self->{logger}->log(4,"$hits hits for $sMsg");
			}
			setLastReponderTs($self,time);
			return 1;
		}
	}
	$sth->finish;
	return 0;
}

# Add a text responder (Context version)
# Usage:
#   addresponder [#channel] <chance> <responder> | <answer>
#
# Notes:
# - If #channel is omitted → global responder
# - chance must be integer 0–100
sub addResponder_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $message = $ctx->message;

    # Extract arguments from Context
    my @args = (ref $ctx->args eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------
    # User object + permissions
    # ---------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick,
            "You must be logged in - /msg " . $self->{irc}->nick_folded . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') } || $user->level eq 'Master') {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---------------------------------------
    # Detect channel scope
    # id_channel = 0 → global
    # ---------------------------------------
    my $target_chan;
    my $id_channel = 0;

    if (@args && $args[0] =~ /^#/) {
        $target_chan = shift @args;
        my $chan_obj = $self->{channels}{$target_chan} || $self->{channels}{lc $target_chan};

        unless ($chan_obj) {
            botNotice($self, $nick, "$target_chan is not registered.");
            return;
        }

        $id_channel = $chan_obj->get_id;
    }

    # ---------------------------------------
    # Syntax + validation
    # ---------------------------------------
    my $syntax_msg = "Syntax: addresponder [#channel] <chance> <responder> | <answer>";

    my $chance = shift @args;
    unless (defined $chance && $chance =~ /^[0-9]+$/ && $chance >= 0 && $chance <= 100) {
        botNotice($self, $nick, $syntax_msg);
        return;
    }

    my $joined = join(' ', @args);
    my ($responder, $answer) = split(/\s*\|\s*/, $joined, 2);
    unless ($responder && $answer) {
        botNotice($self, $nick, $syntax_msg);
        return;
    }

    # ---------------------------------------
    # Check if the responder already exists
    # ---------------------------------------
    my $sth = $self->{dbh}->prepare(
        "SELECT * FROM RESPONDERS WHERE id_channel=? AND responder LIKE ?"
    );

    unless ($sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice(
            $self,
            $nick,
            "Responder '$responder' already exists with answer '$ref->{answer}' ($ref->{chance}%) [hits: $ref->{hits}]"
        );
        $sth->finish;
        return;
    }
    $sth->finish;

    # ---------------------------------------
    # Insert new responder
    # Chance storage logic kept identical:
    # Database stores (100 - $chance)
    # ---------------------------------------
    $sth = $self->{dbh}->prepare(
        "INSERT INTO RESPONDERS (id_channel, chance, responder, answer)
         VALUES (?, ?, ?, ?)"
    );

    unless ($sth->execute($id_channel, (100 - $chance), $responder, $answer)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    $sth->finish;

    # ---------------------------------------
    # Display + log
    # ---------------------------------------
    my $scope = ($id_channel == 0) ? "global" : "channel $target_chan";

    botNotice(
        $self,
        $nick,
        "Added $scope responder: '$responder' ($chance%) → '$answer'"
    );

    logBot(
        $self,
        $message,
        $target_chan // "(private)",
        "addresponder",
        "$responder → $answer"
    );

    return 1;
}

# Delete an existing text responder
# Usage:
#   delresponder [#channel] <responder>
#
# Notes:
# - If #channel is omitted → global responder scope (id_channel = 0)
# - Match is done on responder text (LIKE), same as addResponder()
sub delResponder_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $message = $ctx->message;

    # Extract arguments
    my @args = (ref $ctx->args eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------
    # User object + permissions (Master only)
    # ---------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self,
            $nick,
            "You must be logged in - /msg " . $self->{irc}->nick_folded . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') } || ($user->level // '') eq 'Master') {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---------------------------------------
    # Resolve scope: global or per-channel
    # id_channel = 0 → global responder
    # ---------------------------------------
    my $id_channel = 0;
    my $scope      = 'global';
    my $target_chan;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;

        my $chan_obj = $self->{channels}{$target_chan} || $self->{channels}{lc $target_chan};
        unless ($chan_obj) {
            botNotice($self, $nick, "$target_chan is not registered.");
            return;
        }

        $id_channel = $chan_obj->get_id;
        $scope      = "channel $target_chan";
    }

    # ---------------------------------------
    # Responder name to delete
    # ---------------------------------------
    my $syntax = "Syntax: delresponder [#channel] <responder>";

    my $responder = join(' ', @args);
    $responder =~ s/^\s+|\s+$//g if defined $responder;

    unless (defined $responder && $responder ne '') {
        botNotice($self, $nick, $syntax);
        return;
    }

    # ---------------------------------------
    # Check if responder exists in that scope
    # ---------------------------------------
    my $sth = $self->{dbh}->prepare(
        "SELECT responder, answer, chance, hits
         FROM RESPONDERS
         WHERE id_channel = ? AND responder LIKE ?"
    );
    unless ($sth && $sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "delResponder_ctx() SQL Error (SELECT): $DBI::errstr");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref) {
        push @rows, $ref;
    }
    $sth->finish;

    unless (@rows) {
        botNotice($self, $nick, "No responder '$responder' found in $scope.");
        return;
    }

    # ---------------------------------------
    # Delete all matching responders in that scope
    # (Usually only one, but we clean all duplicates if any)
    # ---------------------------------------
    $sth = $self->{dbh}->prepare(
        "DELETE FROM RESPONDERS
         WHERE id_channel = ? AND responder LIKE ?"
    );
    unless ($sth && $sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "delResponder_ctx() SQL Error (DELETE): $DBI::errstr");
        botNotice($self, $nick, "Failed to delete responder '$responder' in $scope.");
        return;
    }

    my $deleted = $sth->rows;
    $sth->finish;

    my $extra = '';
    if (@rows == 1) {
        my $r = $rows[0];
        $extra = " (answer: '$r->{answer}', chance: $r->{chance}%, hits: $r->{hits})";
    }

    botNotice(
        $self,
        $nick,
        "Deleted responder '$responder' in $scope" . ($deleted > 1 ? " ($deleted entries)" : "") . "$extra"
    );

    # Log the action
    my $log_chan = $target_chan // "(global/private)";
    logBot($self, $message, $log_chan, "delresponder", "$scope: $responder");

    return 1;
}

# Evaluate action string for responders and commands
sub setLastReponderTs(@) {
	my ($self,$ts) = @_;
	$self->{last_responder_ts} = $ts;
}

sub getLastReponderTs(@) {
	my $self = shift;
	return $self->{last_responder_ts};
}

sub setLastCommandTs(@) {
	my ($self,$ts) = @_;
	$self->{last_command_ts} = $ts;
}

# Add a badword to a channel
sub IgnoresList_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx ignores command attempt (unauthenticated)");
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx ignores command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Scope: global (id_channel=0) OR a specific channel passed as first arg
    my $id_channel = 0;
    my $label      = "allchans/private";
    my $log_chan   = undef;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        my $target = shift @args;

        my $chan_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
        unless ($chan_obj) {
            botNotice($self, $nick, "Channel $target is not registered");
            return;
        }

        $id_channel = eval { $chan_obj->get_id } || 0;
        unless ($id_channel) {
            botNotice($self, $nick, "Channel $target is not registered");
            return;
        }

        $label    = $target;
        $log_chan = $target;
    }

    my $sql = "SELECT id_ignores, hostmask FROM IGNORES WHERE id_channel = ? ORDER BY id_ignores";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "IgnoresList_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref) {
        next unless $ref && defined $ref->{id_ignores};
        push @rows, $ref;
    }
    $sth->finish;

    my $count = scalar @rows;
    if ($count == 0) {
        botNotice($self, $nick, "Ignores ($label): none.");
        logBot($self, $ctx->message, $log_chan, "ignores", $label);
        return 0;
    }

    botNotice($self, $nick, "Ignores ($label): $count entr" . ($count > 1 ? "ies" : "y") . " found");

    # Avoid flooding: send in chunks
    my $chunk = 10;
    for (my $i = 0; $i < @rows; $i += $chunk) {
        my @slice = @rows[$i .. (($i + $chunk - 1) < $#rows ? ($i + $chunk - 1) : $#rows)];
        for my $r (@slice) {
            my $hm = defined($r->{hostmask}) ? $r->{hostmask} : '';
            botNotice($self, $nick, "ID: $r->{id_ignores} : $hm");
        }
    }

    logBot($self, $ctx->message, $log_chan, "ignores", $label);
    return 1;
}

# Add an ignore
sub addIgnore_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx ignore command attempt (unauthenticated)");
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx ignore command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Scope: global (id_channel=0) OR a specific channel passed as first arg
    my $id_channel = 0;
    my $label      = "(allchans/private)";
    my $log_chan   = undef;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        my $chan_name = shift @args;

        my $chan_obj = $self->{channels}{$chan_name} || $self->{channels}{lc($chan_name)};
        unless ($chan_obj) {
            botNotice($self, $nick, "Channel $chan_name is not registered");
            return;
        }

        $id_channel = eval { $chan_obj->get_id } || 0;
        unless ($id_channel) {
            botNotice($self, $nick, "Channel $chan_name is not registered");
            return;
        }

        $label    = $chan_name;
        $log_chan = $chan_name;
    }

    # Hostmask (allow IRC wildcards; require at least "!" and "@")
    my $hostmask = join(" ", @args);
    $hostmask =~ s/^\s+|\s+$//g;

    unless ($hostmask && $hostmask =~ /!/ && $hostmask =~ /\@/) {
        botNotice($self, $nick, "Syntax: ignore [#channel] <hostmask>");
        botNotice($self, $nick, "Example: nick*!*ident\@*.example.org");
        return;
    }

    # Check existing (exact match; avoids LIKE surprises)
    my $sql_chk = "SELECT id_ignores FROM IGNORES WHERE id_channel = ? AND hostmask = ? LIMIT 1";
    my $sth = $self->{dbh}->prepare($sql_chk);
    unless ($sth && $sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "addIgnore_ctx() SQL Error: $DBI::errstr Query: $sql_chk");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        botNotice($self, $nick, "$hostmask is already ignored on $label (ID $ref->{id_ignores})");
        $sth->finish;
        logBot($self, $ctx->message, $log_chan, "ignore", "exists $label $hostmask");
        return;
    }
    $sth->finish;

    # Insert
    my $sql_ins = "INSERT INTO IGNORES (id_channel, hostmask) VALUES (?, ?)";
    $sth = $self->{dbh}->prepare($sql_ins);
    unless ($sth && $sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "addIgnore_ctx() SQL Error: $DBI::errstr Query: $sql_ins");
        return;
    }

    my $new_id = eval { $sth->{mysql_insertid} } // "?";
    $sth->finish;

    botNotice($self, $nick, "Added ignore ID $new_id $hostmask on $label");
    logBot($self, $ctx->message, $log_chan, "ignore", "add $label $hostmask");

    return 1;
}

# Delete an ignore
sub delIgnore_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx unignore command attempt (unauthenticated)");
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
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx unignore command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Scope: global (id_channel=0) OR a specific channel passed as first arg
    my $id_channel = 0;
    my $label      = "(allchans/private)";
    my $log_chan   = undef;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        my $chan_name = shift @args;

        my $chan_obj = $self->{channels}{$chan_name} || $self->{channels}{lc($chan_name)};
        unless ($chan_obj) {
            botNotice($self, $nick, "Channel $chan_name is undefined");
            return;
        }

        $id_channel = eval { $chan_obj->get_id } || 0;
        unless ($id_channel) {
            botNotice($self, $nick, "Channel $chan_name is undefined");
            return;
        }

        $label    = $chan_name;
        $log_chan = $chan_name;
    }

    # Hostmask
    my $hostmask = join(" ", @args);
    $hostmask =~ s/^\s+|\s+$//g;

    unless ($hostmask && $hostmask =~ /!/ && $hostmask =~ /\@/) {
        botNotice($self, $nick, "Syntax: unignore [#channel] <hostmask>");
        botNotice($self, $nick, "Example: nick*!*ident\@*.example.org");
        return;
    }

    # Lookup exact match
    my $sql_chk = "SELECT id_ignores FROM IGNORES WHERE id_channel = ? AND hostmask = ? LIMIT 1";
    my $sth = $self->{dbh}->prepare($sql_chk);
    unless ($sth && $sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "delIgnore_ctx() SQL Error: $DBI::errstr Query: $sql_chk");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $nick, "$hostmask is not ignored on $label");
        logBot($self, $ctx->message, $log_chan, "unignore", "notfound $label $hostmask");
        return;
    }

    # Delete exact match (safer than LIKE)
    my $sql_del = "DELETE FROM IGNORES WHERE id_channel = ? AND hostmask = ? LIMIT 1";
    $sth = $self->{dbh}->prepare($sql_del);
    unless ($sth && $sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "delIgnore_ctx() SQL Error: $DBI::errstr Query: $sql_del");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Deleted ignore ID $ref->{id_ignores} $hostmask on $label");
    logBot($self, $ctx->message, $log_chan, "unignore", "del $label $hostmask");

    return 1;
}

# YouTube search command
sub lastCom_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $message = $ctx->message;
    my @args    = (ref $ctx->args eq 'ARRAY') ? @{ $ctx->args } : ();

    # ----------------------------------------
    # Resolve current user from Context
    # ----------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $notice = ($message && $message->can('prefix'))
            ? $message->prefix . " lastcom attempt (unauthenticated user)"
            : "lastcom attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);

        botNotice(
            $self,
            $nick,
            "You must be logged in - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # ----------------------------------------
    # Permission check (Master+)
    # ----------------------------------------
    unless (eval { $user->has_level('Master') } || ($user->level // '') eq 'Master') {
        my $prefix = ($message && $message->can('prefix')) ? $message->prefix : $nick;
        noticeConsoleChan(
            $self,
            "$prefix lastcom attempt rejected (Master required for "
            . ($user->nickname // '?') . " [" . ($user->level // '?') . "])"
        );

        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ----------------------------------------
    # Determine number of lines to show
    # ----------------------------------------
    my $max_lines = 8;
    my $nb_lines  = 5;

    if (@args && defined $args[0] && $args[0] =~ /^\d+$/ && $args[0] > 0) {
        $nb_lines = $args[0] > $max_lines ? $max_lines : int($args[0]);
        $nb_lines = 1 if $nb_lines < 1;

        if ($args[0] > $max_lines) {
            botNotice($self, $nick, "lastcom: max lines $max_lines");
        }
    }

    # ----------------------------------------
    # SQL query (LIMIT must be literal, no bind)
    # ----------------------------------------
    my $sql = qq{
        SELECT ts, id_user, id_channel, hostmask, action, args
        FROM ACTIONS_LOG
        ORDER BY ts DESC
        LIMIT $nb_lines
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "lastCom_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botNotice($self, $nick, "Database error during lastcom query.");
        return;
    }

    # ----------------------------------------
    # Output each row as NOTICE
    # ----------------------------------------
    while (my $row = $sth->fetchrow_hashref) {

        # Timestamp
        my $ts = $row->{ts} // '';

        # User
        my $id_user = $row->{id_user};
        my $userhandle = getUserhandle($self, $id_user);
        $userhandle = (defined $userhandle && $userhandle ne "") ? $userhandle : "Unknown";

        # Hostmask
        my $hostmask = $row->{hostmask} // "";

        # Action + args
        my $action = $row->{action} // "";
        my $args   = defined $row->{args} ? $row->{args} : "";

        # Channel name lookup
        my $channel_str = "";
        if (defined $row->{id_channel}) {
            my $chan_obj = $self->getChannelById($row->{id_channel});
            if ($chan_obj) {
                my $chan_name;
                if (ref($chan_obj) && eval { $chan_obj->can('get_name') }) {
                    $chan_name = $chan_obj->get_name;
                } elsif (ref($chan_obj) eq 'HASH') {
                    $chan_name = $chan_obj->{name};
                }
                $channel_str = defined $chan_name ? " $chan_name" : "";
            }
        }

        # Final output line
        botNotice(
            $self,
            $nick,
            "$ts ($userhandle)$channel_str $hostmask $action $args"
        );
    }

    $sth->finish;

    # ----------------------------------------
    # Logging
    # ----------------------------------------
    my $dest = $ctx->channel // "(private)";
    logBot($self, $message, $dest, "lastcom", @args);

    return 1;
}

# Handle all quote-related commands (Context version).
# Subcommands:
#   q add|a <...>
#   q del|d <id>
#   q view|v [id|nick]
#   q search|s <keyword>
#   q random|r
#   q stats
#
# Rules:
# - Authenticated + level >= "User" => all subcommands allowed
# - Unauthenticated or level < "User" => only view/search/random/stats,
#   BUT "add" is still allowed in anonymous/legacy mode (uid/handle undef)
sub Yomomma_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my @args = ();
    @args = @{ $ctx->args } if ref($ctx->args) eq 'ARRAY';

    # If the first argument is a positive integer, interpret it as an ID
    my $id;
    if (@args && defined $args[0] && $args[0] =~ /^\d+$/) {
        $id = int($args[0]);
    }

    my ($sql, @bind);
    if (defined $id && $id > 0) {
        # Specific joke by ID
        $sql  = "SELECT id_yomomma, yomomma FROM YOMOMMA WHERE id_yomomma = ?";
        @bind = ($id);
    } else {
        # Random joke
        $sql  = "SELECT id_yomomma, yomomma FROM YOMOMMA ORDER BY RAND() LIMIT 1";
        @bind = ();
    }

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute(@bind)) {
        $self->{logger}->log(1, "Yomomma_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botPrivmsg($self, $channel, "Not found");
        return;
    }

    my $row = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($row) {
        botPrivmsg($self, $channel, "Not found");
        return;
    }

    my $joke_id  = $row->{id_yomomma};
    my $joke_txt = $row->{yomomma} // '';

    if ($joke_txt ne '') {
        botPrivmsg($self, $channel, "[$joke_id] $joke_txt");
    } else {
        botPrivmsg($self, $channel, "Not found");
    }

    # Log action (id or "random")
    my $log_arg = defined($id) ? $id : 'random';
    logBot($self, $ctx->message, $channel, "yomomma", $log_arg);

    return 1;
}

# resolve <hostname|IP>
# Resolve hostname → IP or reverse-resolve IP → hostname.
# Improved:
#   - Multiple IP output for hostname
#   - Clear bot responses
#   - Full Context API

1;
