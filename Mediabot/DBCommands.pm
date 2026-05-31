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
    mbCalc_ctx
);

sub setMainTimerTick {
	my ($self,$timer) = @_;
	$self->{main_timer_tick} = $timer;
}

# Set refresh channel hashes
sub getMainTimerTick {
	my $self = shift;
	return $self->{maint_timer_tick};
}

# Set IRC object
# Set IRC object
sub onStartTimers {
    my $self = shift;

    my %hTimers;
    my $sQuery = "SELECT id_timers, name, duration, command FROM TIMERS";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "onStartTimers() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        %{$self->{hTimers}} = %hTimers;
        return 0;
    }

    unless ($sth->execute()) {
        $self->{logger}->log(1, "onStartTimers() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        %{$self->{hTimers}} = %hTimers;
        return 0;
    }

    $self->{logger}->log(1, "Checking timers to set at startup")
        if $self->{logger};

    my $i = 0;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $id_timers = $ref->{'id_timers'};
        my $name      = $ref->{'name'};
        my $duration  = $ref->{'duration'};
        my $command   = $ref->{'command'};

        next unless defined($name)     && $name ne '';
        next unless defined($duration) && $duration =~ /^\d+$/ && $duration > 0;
        next unless defined($command)  && $command ne '';

        my $sSecondText = ($duration > 1 ? "seconds" : "second");
        $self->{logger}->log(1, "Timer $name - id : $id_timers - every $duration $sSecondText - command $command")
            if $self->{logger};

        my $timer = IO::Async::Timer::Periodic->new(
            interval => $duration,
            on_tick  => sub {
                $self->{logger}->log(4, "Timer every $duration seconds : $command")
                    if $self->{logger};

                if ($self->{irc} && $self->{irc}->is_connected) {
                    $self->{irc}->write("$command\x0d\x0a");
                }
                else {
                    $self->{logger}->log(1, "Timer $name skipped: bot not connected to IRC")
                        if $self->{logger};
                }
            },
        );

        $hTimers{$name} = $timer;
        $self->{loop}->add($timer);
        $timer->start;
        $i++;
    }

    $sth->finish;

    if ($i) {
        my $sTimerText = ($i > 1 ? "timers" : "timer");
        $self->{logger}->log(1, "$i active $sTimerText set at startup")
            if $self->{logger};
    }
    else {
        $self->{logger}->log(1, "No timer to set at startup")
            if $self->{logger};
    }

    %{$self->{hTimers}} = %hTimers;
    return $i;
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
    unless ($self->{irc} && $self->{irc}->is_connected) {
        $self->botNotice($nick, "Not connected to IRC.");
        return;
    }
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
sub setLastRandomQuote {
	my ($self,$iLastRandomQuote) = @_;
	$self->{iLastRandomQuote} = $iLastRandomQuote;
}

sub getLastRandomQuote {
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

    # Validate timer name before using it as hash key and DB unique name.
    # TIMERS.name is VARCHAR(255), but keeping names short and predictable makes
    # live administration safer and avoids ugly output/log lines.
    unless ($name =~ /^[A-Za-z0-9_.-]{1,64}$/) {
        $self->botNotice($nick, "Timer name must be 1-64 chars: letters, numbers, underscore, dash or dot");
        return;
    }

    # Avoid accidental very tight loops and absurd intervals.
    if ($interval < 5 || $interval > 86400) {
        $self->botNotice($nick, "Timer interval must be between 5 and 86400 seconds");
        return;
    }

    my $cmd = join(' ', @raw);

    # TIMERS.command is VARCHAR(255). Refuse too-long commands explicitly instead
    # of relying on DB truncation/errors.
    if (length($cmd) > 255) {
        $self->botNotice($nick, "Timer command is too long (max 255 chars)");
        return;
    }

    # Validate IRC command: must start with a known safe IRC verb
    my @allowed_verbs = qw(PRIVMSG NOTICE JOIN PART TOPIC MODE KICK INVITE WHO WHOIS PING PONG);
    my ($verb) = ($cmd =~ /^(\S+)/);
    unless (defined $verb && grep { uc($verb) eq $_ } @allowed_verbs) {
        $self->botNotice($nick, "Timer command must start with a valid IRC verb (" . join(', ', @allowed_verbs) . ")");
        return;
    }

    $self->{hTimers} ||= {};
    if (exists $self->{hTimers}{$name}) {
        $self->botNotice($nick, "Timer $name already exists");
        return;
    }

    # Check DB too, not only runtime memory.
    my $sql_check = "SELECT 1 FROM TIMERS WHERE name = ? LIMIT 1";
    my $sth = $self->{dbh}->prepare($sql_check);

    unless ($sth) {
        $self->{logger}->log(1, "mbAddTimer_ctx() SQL prepare error: $DBI::errstr Query: $sql_check")
            if $self->{logger};
        $self->botNotice($nick, "DB error while checking timer");
        return;
    }

    unless ($sth->execute($name)) {
        $self->{logger}->log(1, "mbAddTimer_ctx() SQL execute error: $DBI::errstr Query: $sql_check")
            if $self->{logger};
        $sth->finish;
        $self->botNotice($nick, "DB error while checking timer");
        return;
    }

    if ($sth->fetchrow_array) {
        $sth->finish;
        $self->botNotice($nick, "Timer $name already exists in database");
        return;
    }

    $sth->finish;

    # Insert into DB before starting the runtime timer. This avoids a memory-only
    # timer if the database insert fails.
    my $sql_insert = "INSERT INTO TIMERS (name, duration, command) VALUES (?,?,?)";
    $sth = $self->{dbh}->prepare($sql_insert);

    unless ($sth) {
        $self->{logger}->log(1, "mbAddTimer_ctx() SQL insert prepare error: $DBI::errstr Query: $sql_insert")
            if $self->{logger};
        $self->botNotice($nick, "DB error while adding timer");
        return;
    }

    unless ($sth->execute($name, $interval, $cmd)) {
        $self->{logger}->log(1, "mbAddTimer_ctx() SQL insert execute error: $DBI::errstr Query: $sql_insert")
            if $self->{logger};
        $sth->finish;
        $self->botNotice($nick, "DB error while adding timer");
        return;
    }

    $sth->finish;

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            $self->{logger}->log(4, "Timer [$name] tick: $cmd")
                if $self->{logger};

            if ($self->{irc} && $self->{irc}->is_connected) {
                $self->{irc}->write("$cmd\x0d\x0a");
            }
            else {
                $self->{logger}->log(1, "Timer [$name] skipped: not connected to IRC")
                    if $self->{logger};
            }
        },
    );

    $self->{loop}->add($timer);
    $timer->start;
    $self->{hTimers}{$name} = $timer;

    # LL4: human-readable duration in confirmation
    my $dur_h = $interval >= 3600 ? sprintf("%dh%02dm", int($interval/3600), int(($interval%3600)/60))
              : $interval >= 60   ? sprintf("%dm%02ds", int($interval/60), $interval%60)
              :                     "${interval}s";
    $self->botNotice($nick, "Timer $name added (every $dur_h): $cmd");
    logBot($self, $ctx->message, undef, 'addtimer', $name);
    return 1;
}


# Handle remtimer command (Owner only, Context-based)
# Handle remtimer command (Owner only, Context-based)
sub mbRemTimer_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $name = $args[0];

    return unless $ctx->require_level('Owner');

    $self->{hTimers} ||= {};

    unless (defined $name && $name ne '') {
        $self->botNotice($nick, "Syntax: remtimer <name>");
        return;
    }

    unless (exists $self->{hTimers}{$name}) {
        $self->botNotice($nick, "Unknown timer $name");
        return;
    }

    # Delete from DB first. If DB deletion fails, keep the runtime timer running
    # so runtime and restart state do not diverge.
    my $sql_delete = "DELETE FROM TIMERS WHERE name = ?";
    my $sth = $self->{dbh}->prepare($sql_delete);

    unless ($sth) {
        $self->{logger}->log(1, "mbRemTimer_ctx() SQL delete prepare error: $DBI::errstr Query: $sql_delete")
            if $self->{logger};
        $self->botNotice($nick, "DB error while removing timer");
        return;
    }

    unless ($sth->execute($name)) {
        $self->{logger}->log(1, "mbRemTimer_ctx() SQL delete execute error: $DBI::errstr Query: $sql_delete")
            if $self->{logger};
        $sth->finish;
        $self->botNotice($nick, "DB error while removing timer");
        return;
    }

    my $rows = $sth->rows;
    $sth->finish;

    if (!defined($rows) || $rows < 1) {
        $self->botNotice($nick, "Timer $name was running but not found in database");
        return;
    }

    $self->{loop}->remove($self->{hTimers}{$name});
    delete $self->{hTimers}{$name};

    $self->botNotice($nick, "Timer $name removed");
    logBot($self, $ctx->message, undef, 'remtimer', $name);
    return 1;
}


# List all registered timers currently stored in the database (Owner only, Context-based)
# List all registered timers currently stored in the database (Owner only, Context-based)
sub mbTimers_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Owner');

    my $sql = "SELECT name, duration, command FROM TIMERS ORDER BY name";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "mbTimers_ctx() SQL prepare error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $self->botNotice($nick, "DB error while reading timers");
        return;
    }

    unless ($sth->execute()) {
        $self->{logger}->log(1, "mbTimers_ctx() SQL execute error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $sth->finish;
        $self->botNotice($nick, "DB error while reading timers");
        return;
    }

    my @timer_lines;

    while (my $r = $sth->fetchrow_hashref) {
        my $name     = $r->{name}     // '';
        my $duration = $r->{duration} // 0;
        my $command  = $r->{command}  // '';

        next if $name eq '';

        # JJ1: human-readable duration
        my $dur_h = $duration >= 3600 ? sprintf("%dh%02dm", int($duration/3600), int(($duration%3600)/60))
                  : $duration >= 60   ? sprintf("%dm%02ds", int($duration/60), $duration%60)
                  :                     "${duration}s";
        push @timer_lines, sprintf("%s - every %s - %s", $name, $dur_h, $command);
    }

    $sth->finish;

    my $count = scalar(@timer_lines);

    if ($count) {
        $self->botNotice($nick, "DB timers: $count result(s)");

        my $page = 1;
        for my $line (@timer_lines) {
            my $out = sprintf("timer[%02d]: %s", $page, $line);

            if (length($out) > 360) {
                $out = substr($out, 0, 357) . '...';
            }

            $self->botNotice($nick, $out);
            $page++;
        }
    }
    else {
        $self->botNotice($nick, "No active timers");
    }

    # Also show Scheduler tasks when the runtime scheduler is available.
    if ($self->{scheduler} && $self->{scheduler}->can('all_info')) {
        my @tasks = $self->{scheduler}->all_info;

        if (@tasks) {
            # A5: tabular format for Scheduler tasks
            $self->botNotice($nick, sprintf("%-28s %-8s %-8s %s", "Task", "Every", "Status", "Last run"));
            $self->botNotice($nick, "-" x 58);

            my $page = 1;

            for my $t (@tasks) {
                my $last = $t->{last_tick}
                    ? do {
                        my @lt = localtime($t->{last_tick});
                        sprintf('%02d:%02d:%02d', $lt[2], $lt[1], $lt[0]);
                    }
                    : 'never';

                my $line = sprintf(
                    "schedule[%02d]: %-28s every %ds %-8s ticks=%d last=%s",
                    $page,
                    ($t->{name}     // ''),
                    ($t->{interval} // 0),
                    ($t->{started} ? 'running' : 'stopped'),
                    ($t->{ticks}    // 0),
                    $last,
                );

                if (length($line) > 360) {
                    $line = substr($line, 0, 357) . '...';
                }

                $self->botNotice($nick, $line);
                $page++;
            }
        }
    }

    logBot($self, $ctx->message, undef, 'timers', undef);
    return $count;
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

    # B3/A2: validate command name
    if (length($sCommand) > 64) {
        botNotice($self, $nick, "Command name too long (max 64 chars).");
        return;
    }
    if ($sCommand !~ /^[a-zA-Z0-9_-]+$/) {
        botNotice($self, $nick, "Command name must be alphanumeric (a-z, 0-9, - _).");
        return;
    }
    my $sType     = shift @args;
    my $sCategory = shift @args;

    # A3: validate action text AFTER sType and sCategory are removed from @args
    my $action_text_check = join(' ', @args);
    if (length($action_text_check) > 512) {
        botNotice($self, $nick, "Action text too long (max 512 chars).");
        return;
    }

    # Resolve category
    my $id_cat = getCommandCategory($self, $sCategory);
    unless (defined $id_cat) {
        botNotice($self, $nick, "Unknown category : $sCategory");
        return;
    }

    # Check duplicates
    my $query_check = "SELECT command FROM PUBLIC_COMMANDS WHERE command = ?";
    my $sth = $self->{dbh}->prepare($query_check);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query_check");
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }

    botNotice($self, $nick, "Command $sCommand added");
    logBot($self, $ctx->message, undef, "addcmd", ("Command $sCommand added"));

    $sth->finish;
    return;
}

# Get command category ID from description
# Get command category ID from description
sub getCommandCategory {
    my ($self, $sCategory) = @_;

    my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery);
        return undef;
    }

    unless ($sth->execute($sCategory)) {
        $self->{logger}->log(1, "SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        $sth->finish;
        return undef;
    }

    my $id_category;
    if (my $ref = $sth->fetchrow_hashref()) {
        $id_category = $ref->{id_public_commands_category};
    }

    $sth->finish;
    return $id_category;
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

    my $query = "SELECT id_user, id_public_commands FROM PUBLIC_COMMANDS WHERE command = ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        $sth->finish if $sth;
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
        $sth_del->finish if $sth_del;
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

    my $query = "SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command = ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        $sth->finish if $sth;
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_owner     = $ref->{id_user};
        my $id_command   = $ref->{id_public_commands};

        if ($id_owner == $user->id || $user->has_level("Master")) {
            my $id_cat = getCommandCategory($self, $sCategory);
            unless (defined $id_cat) {
                botNotice($self, $sNick, "Unknown category : $sCategory");
				$sth->finish;  # DM1/fix: finish before early return — prevent cursor leak
                return;
            }

            botNotice($self, $sNick, "Modifying command $sCommand [$sType] " . join(" ", @tArgs));

            my $sAction = $sType =~ /^message$/i ? "PRIVMSG %c " : "ACTION %c ";
            $sAction .= join(" ", @tArgs);

            my $update_query = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=?, action=? WHERE id_public_commands=?";
            my $sth_upd = $self->{dbh}->prepare($update_query);
            unless ($sth_upd && $sth_upd->execute($id_cat, $sAction, $id_command)) {
                $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
                $sth_upd->finish if $sth_upd;
				$sth->finish;  # DM1/fix: finish before early return — prevent cursor leak
                return;
            }

            botNotice($self, $sNick, "Command $sCommand modified");
            logBot($self, $message, undef, "modcmd", ("Command $sCommand modified"));
            $sth_upd->finish if $sth_upd;
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

    my $query = "SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command = ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        $sth->finish if $sth;
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

    # HH7: fetch current action before overwriting for informative log
    my $old_action = '';
    {
        my $sth_old = $self->{dbh}->prepare(
            "SELECT action FROM PUBLIC_COMMANDS WHERE command = ?");
        if ($sth_old && $sth_old->execute($sCommand)) {
            my $r = $sth_old->fetchrow_hashref;
            $old_action = $r->{action} // '' if $r;
            $sth_old->finish;
        }
    }
    my $old_str = $old_action ne '' ? " (was: $old_action)" : '';
    botNotice($self, $nick, "Modifying command $sCommand [$sType]$old_str");

    my $sAction = ($sType =~ /^message$/i) ? "PRIVMSG %c " : "ACTION %c ";
    $sAction .= join(" ", @args);

    my $update_query = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=?, action=? WHERE id_public_commands=?";
    my $sth_upd = $self->{dbh}->prepare($update_query);
    unless ($sth_upd && $sth_upd->execute($id_cat, $sAction, $id_command)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
        $sth_upd->finish if $sth_upd;
        return;
    }
    $sth_upd->finish if $sth_upd;

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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }
    $sth->finish if $sth;

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
            PC.active,
            PCC.description AS category
        FROM PUBLIC_COMMANDS PC
        JOIN PUBLIC_COMMANDS_CATEGORY PCC
          ON PC.id_public_commands_category = PCC.id_public_commands_category
        WHERE PC.command = ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $sQuery");
        $sth->finish if $sth;
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
        my $active        = defined $ref->{active} ? $ref->{active} : 1;
        my $status        = $active ? 'active' : 'on hold';
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

        # W8: show creation date age

        my $created_str = $ref->{creation_date} // '';

        if ($created_str =~ /^(\d{4})-(\d{2})-(\d{2})/) {

            require Time::Local;

            my ($y,$mo,$d) = ($1,$2,$3);

            my $ep = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };

            if ($ep) {

                my $diff = int((time()-$ep)/86400);

                $created_str .= $diff > 0 ? " (${diff}d ago)" : " (today)";

            }

        }

        botNotice($self, $nick, "Command : $sCommand Author : $sUserHandle Created : $created_str");
                botNotice($self, $nick, "$sHitsWord Category : $sCategory Status : $status Action : $sAction");
    } else {
        botNotice($self, $nick, "$sCommand command does not exist");
    }

    logBot($self, $ctx->message, undef, "showcmd", $sCommand);
    return;
}

# chanstatlines => sub { channelStatLines_ctx($ctx) },

# Show the number of lines sent on a channel during the last hour (Administrator+)
sub mbDbCommand {
	my ($self,$message,$sChannel,$sNick,$sCommand,@tArgs) = @_;
	# CC19: log command dispatch with context
	$self->{logger}->log(3,"mbDbCommand: !$sCommand on $sChannel by $sNick");

	my $sQuery = "SELECT id_public_commands, action, description, hits FROM PUBLIC_COMMANDS WHERE command = ? AND active = 1";
	my $sth_sel = $self->{dbh}->prepare($sQuery);
	unless ($sth_sel && $sth_sel->execute($sCommand)) {
		$self->{logger}->log(1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		$sth_sel->finish if $sth_sel;
		return 0;
	}

	my $ref = $sth_sel->fetchrow_hashref();
	$sth_sel->finish;
	return 0 unless $ref;

	my $id_public_commands = $ref->{'id_public_commands'};
	my $description        = $ref->{'description'};
	my $action             = $ref->{'action'};
	my $hits               = $ref->{'hits'} + 1;

	$sQuery = "UPDATE PUBLIC_COMMANDS SET hits=? WHERE id_public_commands=?";
	my $sth_upd = $self->{dbh}->prepare($sQuery);
	unless ($sth_upd && $sth_upd->execute($hits,$id_public_commands)) {
		$self->{logger}->log(1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		$sth_upd->finish if $sth_upd;
		return 0;
	}
	$sth_upd->finish if $sth_upd;

	$self->{logger}->log(2,"SQL command found : $sCommand description : $description action : $action");
	my ($actionType,$actionTo,$actionDo) = split(/ /,$action,3);
	if (( $actionType eq 'PRIVMSG' ) || ( $actionType eq 'ACTION' )) {
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }
    $sth->finish if $sth;

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

    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    my $sql_total = "SELECT COUNT(*) AS nbCommands FROM PUBLIC_COMMANDS";
    my $sth = $self->{dbh}->prepare($sql_total);

    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbCountCommand_ctx() SQL Error: $DBI::errstr Query: $sql_total");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my $nb_total = 0;
    if (my $ref = $sth->fetchrow_hashref()) {
        $nb_total = $ref->{nbCommands} // 0;
    }
    $sth->finish;

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
        $sth->finish if $sth;
        return;
    }

    my @parts;
    while (my $r = $sth->fetchrow_hashref()) {
        my $cat = $r->{category}   // next;
        my $nb  = $r->{nbCommands} // 0;
        push @parts, "$cat($nb)";
    }
    $sth->finish;

    unless ($nb_total) {
        my $line = "No command in database";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "countcmd", undef);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "countcmd", undef);
        }

        return 0;
    }

    my $summary = "$nb_total command(s) in database";

    if (@parts) {
        $summary .= ", " . scalar(@parts) . " categor(y/ies)";
    }

    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "countcmd", undef);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "countcmd", undef);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@parts) {
        my @chunk = splice(@parts, 0, $per_line);
        # KK3: show page number and count in header
        my $line  = sprintf("countcmd[%02d/%02d]: %s",
            $page, int(scalar(@parts)/$per_line)+1, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
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

    # Prefer output where the command was invoked.
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    # IMP26: fetch total hits to compute percentages
    my $total_hits = 0;
    {
        my $sth_tot = $self->{dbh}->prepare(q{SELECT SUM(hits) AS t FROM PUBLIC_COMMANDS});
        if ($sth_tot && $sth_tot->execute) {
            my $r = $sth_tot->fetchrow_hashref; $total_hits = $r->{t} // 0;
            $sth_tot->finish;
        }
    }
    my $sql = "SELECT command, hits FROM PUBLIC_COMMANDS ORDER BY hits DESC LIMIT 20";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbTopCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my @items;
    my $rank = 0;

    while (my $r = $sth->fetchrow_hashref()) {
        my $cmd  = $r->{command} // next;
        my $hits = $r->{hits}    // 0;
        $rank++;

        my $pct_str = $total_hits > 0
            ? sprintf(", %.1f%%", 100 * $hits / $total_hits) : "";
        push @items, $rank . ") " . $cmd . "(" . $hits . $pct_str . ")";
    }

    $sth->finish;

    unless (@items) {
        my $line = "No top commands in database";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "topcmd", undef);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "topcmd", undef);
        }

        return 0;
    }

    my $count = scalar(@items);
    my $summary = "Top commands: $count result(s), showing max 20";

    # Avoid flooding public channels with multi-line output.
    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "topcmd", undef);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "topcmd", undef);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@items) {
        my @chunk = splice(@items, 0, $per_line);
        my $line  = sprintf("topcmd[%02d]: %s", $page, join(' | ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    return $count;
}


# lastcmd — show last 10 public commands added (by creation_date desc)
# Improvements:
# - single-line output, truncated with "..." if too long
# - outputs to channel if invoked in-channel, else NOTICE
sub mbLastCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    # IMP27: also fetch creation_date to show 'X ago'
    my $sql = q{
        SELECT command, creation_date
        FROM PUBLIC_COMMANDS
        ORDER BY creation_date DESC
        LIMIT 10
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbLastCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my @cmds;
    while (my $r = $sth->fetchrow_hashref()) {
        if (defined $r->{command} && $r->{command} ne '') {
            # IMP27/polish: compute readable age from creation_date.
            # Avoid unhelpful output such as "0h ago" for recent commands.
            my $age_s = '';
            if ($r->{creation_date} && $r->{creation_date} =~ /^(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{2}):(\d{2}):(\d{2}))?/) {
                require Time::Local;
                my ($y,$mo,$d,$h,$mi,$sec) = ($1,$2,$3,$4,$5,$6);
                $h //= 12; $mi //= 0; $sec //= 0;
                my $ep = eval { Time::Local::timelocal($sec,$mi,$h,$d,$mo-1,$y-1900) };
                if ($ep) {
                    my $diff = time() - $ep;
                    if ($diff >= 86400) {
                        $age_s = sprintf(' (%dd ago)', int($diff/86400));
                    }
                    elsif ($diff >= 3600) {
                        $age_s = sprintf(' (%dh ago)', int($diff/3600));
                    }
                    elsif ($diff >= 60) {
                        $age_s = sprintf(' (%dm ago)', int($diff/60));
                    }
                    elsif ($diff >= 0) {
                        $age_s = ' (just now)';
                    }
                }
            }
            push @cmds, $r->{command} . $age_s;
        }
    }
    $sth->finish;

    unless (@cmds) {
        my $line = "No command found in database";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "lastcmd", undef);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "lastcmd", undef);
        }

        return 0;
    }

    my $count   = scalar(@cmds);
    my $summary = "Last commands in database: $count result(s), showing max 10";

    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "lastcmd", undef);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "lastcmd", undef);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@cmds) {
        my @chunk = splice(@cmds, 0, $per_line);
        my $line  = sprintf("lastcmd[%02d]: %s", $page, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    return $count;
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

    # Prefer output where the command was invoked.
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    unless (defined($args[0]) && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: searchcmd <keyword> [limit=5]");
        return;
    }

    # A5: optional numeric limit as last arg (default 5, max 20)
    my $search_limit = 5;
    if (@args >= 2 && $args[-1] =~ /^\d+$/) {
        $search_limit = int(pop @args);
        $search_limit = 1  if $search_limit < 1;
        $search_limit = 20 if $search_limit > 20;
    }

    my $kw = $args[0];

    # Escape SQL LIKE wildcards so the keyword is treated literally.
    # Use ESCAPE '!' instead of backslash because ESCAPE '\' is fragile with
    # MariaDB/MySQL SQL string quoting.
    my $like = $kw;
    $like =~ s/!/!!/g;
    $like =~ s/%/!%/g;
    $like =~ s/_/!_/g;
    $like = '%' . $like . '%';

    my $sql = q{
        SELECT command, hits
        FROM PUBLIC_COMMANDS
        WHERE action LIKE ? ESCAPE '!'
        ORDER BY hits DESC, command ASC
        LIMIT ?
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($like, $search_limit)) {  # B1/A1: use $search_limit
        $self->{logger}->log(1, "mbDbSearchCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my @cmds;
    while (my $r = $sth->fetchrow_hashref()) {
        if (defined $r->{command} && $r->{command} ne '') {
            # X10: show hits alongside command name
            my $h = $r->{hits} // 0;
            push @cmds, $h > 0 ? "$r->{command}($h)" : $r->{command};
        }
    }
    $sth->finish;

    my $count = scalar(@cmds);

    if (!$count) {
        my $line = "keyword '$kw' not found in commands";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "searchcmd", $kw);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "searchcmd", $kw);
        }

        return 0;
    }

    my $summary = "Commands containing '$kw': $count result(s), showing max $search_limit";

    # Avoid flooding the channel with multi-line results. If searchcmd is called
    # from a channel, keep a short summary there and send details by NOTICE.
    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "searchcmd", $kw);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "searchcmd", $kw);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@cmds) {
        my @chunk = splice(@cmds, 0, $per_line);
        my $line  = sprintf("searchcmd[%02d]: %s", $page, join(' ', @chunk));

        # Conservative IRC payload limit.
        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    return $count;
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

    # KK4: get total command count for % display
    my $total_cmds = 0;
    { my $sth_t = $self->{dbh}->prepare('SELECT COUNT(*) FROM PUBLIC_COMMANDS');
      if ($sth_t && $sth_t->execute) { ($total_cmds) = $sth_t->fetchrow_array; $sth_t->finish; } }
    my $sql = q{
        SELECT U.nickname AS nickname, COUNT(PC.command) AS nbCommands
        FROM PUBLIC_COMMANDS PC
        JOIN USER U ON PC.id_user = U.id_user
        GROUP BY U.nickname
        ORDER BY nbCommands DESC, U.nickname ASC
        LIMIT 50
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "mbDbOwnersCommand_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        $sth->finish if $sth;
        return;
    }

    my @items;
    while (my $r = $sth->fetchrow_hashref()) {
        my $u  = $r->{nickname};
        my $nb = $r->{nbCommands} // 0;
        next unless defined $u && $u ne '';

        my $ownpct = $total_cmds > 0 ? sprintf(',%.0f%%', 100*$nb/$total_cmds) : '';
        push @items, "$u($nb$ownpct)";  # KK4
    }
    $sth->finish;

    unless (@items) {
        my $line = "No command owner found";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "owncmd", undef);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "owncmd", undef);
        }

        return 0;
    }

    my $count   = scalar(@items);
    my $summary = "Command owners: $count result(s), showing max 50";

    # Avoid flooding public channels with multi-line output.
    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "owncmd", undef);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "owncmd", undef);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@items) {
        my @chunk = splice(@items, 0, $per_line);
        my $line  = sprintf("owncmd[%02d]: %s", $page, join(' ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    return $count;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }
    $sth->finish if $sth;

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

    # A3: validate category name
    if (length($category) > 64 || $category !~ /^[\w\s-]+$/) {
        botNotice($self, $nick, "Category name invalid (max 64 chars, alphanumeric/spaces/hyphens).");
        return;
    }

    # Check exists
    my $sth = $self->{dbh}->prepare(
        "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?"
    );
    unless ($sth && $sth->execute($category)) {
        $self->{logger}->log(1, "mbDbAddCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $nick, "Database error while checking category.");
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }
    $sth->finish if $sth;

    botNotice($self, $nick, "Category '$category' successfully added.");
    logBot($self, $ctx->message, $ctx->channel, "addcatcmd", "Category '$category' added");

    return 1;
}

# Change the category of an existing public command
# Requires: authenticated + Administrator+
# Change the category of an existing public command
# Requires: authenticated + Administrator+
sub mbPopCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Prefer output where the command was invoked.
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    $out_chan = $ctx_chan if defined($ctx_chan) && $ctx_chan =~ /^#/;

    unless (defined($args[0]) && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: popcmd <nickhandle>");
        return;
    }

    my $target = $args[0];

    # Exact user handle lookup.
    # popcmd is not a wildcard search command: '%' and '_' must be literal.
    my $sql = q{
        SELECT PC.command, PC.hits
        FROM USER U
        JOIN PUBLIC_COMMANDS PC ON U.id_user = PC.id_user
        WHERE U.nickname = ?
        ORDER BY PC.hits DESC
        LIMIT 20
    };

    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "mbPopCommand_ctx() SQL prepare error: $DBI::errstr Query: $sql")
            if $self->{logger};
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    unless ($sth->execute($target)) {
        $self->{logger}->log(1, "mbPopCommand_ctx() SQL execute error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $sth->finish;
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

    unless (@items) {
        my $line = "No popular commands for $target";

        if ($out_chan) {
            botPrivmsg($self, $out_chan, $line);
            logBot($self, $ctx->message, $out_chan, "popcmd", $target);
        }
        else {
            botNotice($self, $nick, $line);
            logBot($self, $ctx->message, undef, "popcmd", $target);
        }

        return 0;
    }

    my $count = scalar(@items);
    my $summary = "Popular commands for $target: $count result(s), showing max 20";

    # Avoid flooding public channels with multi-line output.
    if ($out_chan) {
        botPrivmsg($self, $out_chan, "$summary - details sent by notice to $nick");
        logBot($self, $ctx->message, $out_chan, "popcmd", $target);
    }
    else {
        botNotice($self, $nick, $summary);
        logBot($self, $ctx->message, undef, "popcmd", $target);
    }

    my $per_line = 5;
    my $page     = 1;

    while (@items) {
        my @chunk = splice(@items, 0, $per_line);
        my $line  = sprintf("popcmd[%02d]: %s", $page, join(' | ', @chunk));

        if (length($line) > 360) {
            $line = substr($line, 0, 357) . '...';
        }

        botNotice($self, $nick, $line);
        $page++;
    }

    return $count;
}



# Check if a timezone exists
sub checkResponder {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my $sQuery = "SELECT RESPONDERS.answer, RESPONDERS.chance FROM RESPONDERS LEFT JOIN CHANNEL ON CHANNEL.id_channel = RESPONDERS.id_channel WHERE ((CHANNEL.name = ? AND CHANNEL.id_channel IS NOT NULL) OR RESPONDERS.id_channel = 0) AND RESPONDERS.responder = ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth && $sth->execute($sChannel,$sMsg)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sAnswer = $ref->{'answer'};
			my $iChance = $ref->{'chance'};
			$self->{logger}->log(4,"checkResponder() Found answer $sAnswer for $sMsg with chance " . (100-$iChance) ." %");
			$sth->finish;  # CR1/fix: finish before early return
			return $iChance;
		}
	}
	$sth->finish if $sth;
	return 100;
}

sub doResponder {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my $sQuery = "SELECT RESPONDERS.id_responders, RESPONDERS.answer, RESPONDERS.hits FROM RESPONDERS LEFT JOIN CHANNEL ON CHANNEL.id_channel = RESPONDERS.id_channel WHERE ((CHANNEL.name = ? AND CHANNEL.id_channel IS NOT NULL) OR RESPONDERS.id_channel = 0) AND RESPONDERS.responder = ?";
	my $sth_sel = $self->{dbh}->prepare($sQuery);
	unless ($sth_sel && $sth_sel->execute($sChannel,$sMsg)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		$sth_sel->finish if $sth_sel;
		return 0;
	}

	my $ref = $sth_sel->fetchrow_hashref();
	$sth_sel->finish;
	return 0 unless $ref;

	my $sAnswer       = $ref->{'answer'};
	my $id_responders = $ref->{'id_responders'};
	my $hits          = $ref->{'hits'} + 1;
	my $actionDo = evalAction($self,$message,$sNick,$sChannel,$sMsg,$sAnswer);
	$self->{logger}->log(4,"checkResponder() Found answer $sAnswer");
	botPrivmsg($self,$sChannel,$actionDo);

	$sQuery = "UPDATE RESPONDERS SET hits=? WHERE id_responders=?";
	my $sth_upd = $self->{dbh}->prepare($sQuery);
	unless ($sth_upd && $sth_upd->execute($hits,$id_responders)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		$self->{logger}->log(4,"$hits hits for $sMsg");
	}
	$sth_upd->finish if $sth_upd;
	setLastReponderTs($self,time);
	return 1;
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
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

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
        "SELECT answer, chance, hits FROM RESPONDERS WHERE id_channel = ? AND responder = ?"
    );

    unless ($sth && $sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        $sth->finish if $sth;
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

    unless ($sth && $sth->execute($id_channel, (100 - $chance), $responder, $answer)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        $sth->finish if $sth;
        return;
    }

    $sth->finish if $sth;

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
# - Match is done on responder text exactly, same as addResponder()
sub delResponder_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $message = $ctx->message;

    # Extract arguments
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

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
         WHERE id_channel = ? AND responder = ?"
    );
    unless ($sth && $sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "delResponder_ctx() SQL Error (SELECT): $DBI::errstr");
        $sth->finish if $sth;
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
         WHERE id_channel = ? AND responder = ?"
    );
    unless ($sth && $sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "delResponder_ctx() SQL Error (DELETE): $DBI::errstr");
        botNotice($self, $nick, "Failed to delete responder '$responder' in $scope.");
        $sth->finish if $sth;
        return;
    }

    my $deleted = $sth->rows;
    $sth->finish if $sth;

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
sub setLastReponderTs {
	my ($self,$ts) = @_;
	$self->{last_responder_ts} = $ts;
}

sub getLastReponderTs {
	my $self = shift;
	return $self->{last_responder_ts};
}

sub setLastCommandTs {
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }

    my $new_id = eval { $sth->{mysql_insertid} } // "?";
    $sth->finish if $sth;

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
        $sth->finish if $sth;
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
        $sth->finish if $sth;
        return;
    }
    $sth->finish if $sth;

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
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

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
        $sth->finish if $sth;
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

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # If the first argument is a positive integer, interpret it as an ID
    my $id;
    if (@args && defined $args[0] && $args[0] =~ /^\d+$/) {
        $id = int($args[0]);
    }

    my ($sql, @bind, $row);

    if (defined $id && $id > 0) {
        # Specific joke by ID
        $sql  = "SELECT id_yomomma, yomomma FROM YOMOMMA WHERE id_yomomma = ?";
        @bind = ($id);

        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute(@bind)) {
            $self->{logger}->log(1, "Yomomma_ctx() SQL Error: $DBI::errstr | Query: $sql");
            botPrivmsg($self, $channel, "Not found");
            $sth->finish if $sth;
            return;
        }

        $row = $sth->fetchrow_hashref();
        $sth->finish;
    }
    else {
        # Random joke without random SQL sorting.
        my $count_sql = "SELECT COUNT(*) AS joke_count FROM YOMOMMA";
        my $sth_count = $self->{dbh}->prepare($count_sql);

        unless ($sth_count && $sth_count->execute()) {
            $self->{logger}->log(1, "Yomomma_ctx() SQL Error: $DBI::errstr | Query: $count_sql");
            botPrivmsg($self, $channel, "Not found");
            $sth_count->finish if $sth_count;
            return;
        }

        my $count_ref = $sth_count->fetchrow_hashref();
        $sth_count->finish;

        my $joke_count = int($count_ref->{joke_count} // 0);
        unless ($joke_count > 0) {
            botPrivmsg($self, $channel, "Not found");
            return;
        }

        my $offset = int(rand($joke_count));

        $sql = "SELECT id_yomomma, yomomma FROM YOMOMMA ORDER BY id_yomomma LIMIT 1 OFFSET ?";
        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth && $sth->execute($offset)) {
            $self->{logger}->log(1, "Yomomma_ctx() SQL Error: $DBI::errstr | Query: $sql");
            botPrivmsg($self, $channel, "Not found");
            $sth->finish if $sth;
            return;
        }

        $row = $sth->fetchrow_hashref();
        $sth->finish;
    }

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


# ---------------------------------------------------------------------------
# mbCalc_ctx — !calc <expression>
# Evaluate a safe arithmetic expression and reply with the result.
# ---------------------------------------------------------------------------
sub mbCalc_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $expr = join(' ', @args);
    $expr =~ s/^\s+|\s+$//g;

    unless ($expr ne '') {
        botNotice($self, $nick, "Syntax: calc <expression>  (e.g. calc 2+2, calc sqrt(16))");
        return;
    }

    if (length($expr) > 128) {
        botNotice($self, $nick, "Expression too long (max 128 chars).");
        return;
    }

    # A3/fix2: substitute named constants before eval so 'pi' -> literal
    $expr =~ s/\bpi\b/3.14159265358979/g;
    $expr =~ s/\btau\b/6.28318530717959/g;
    $expr =~ s/\be\b/2.71828182845905/g;

    # Whitelist: digits, operators, parens, spaces, common math functions, pi/e
    unless ($expr =~ m{^[0-9+\-*/().\s%^,a-z_]+$}i) {
        botNotice($self, $nick, "Invalid characters in expression.");
        return;
    }

    # Blacklist dangerous keywords
    if ($expr =~ /\b(?:system|exec|open|require|use|print|die|exit|eval|qw|sprintf|chr|ord)\b/i) {
        botNotice($self, $nick, "Expression not allowed.");
        return;
    }

    # Evaluate in a sandboxed sub with safe math
    my $result = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(3);
        my $res = do {
            no strict;
            # A3: extended math — trig + rounding functions
            use POSIX qw(floor ceil);
            my $pi  = 3.14159265358979;
            my $e   = 2.71828182845905;
            my $tau = 6.28318530717959;

            # C1/fix: suppress 'redefined' warning — inner subs re-declared each call
            no warnings 'redefine';
            sub round   { int($_[0] + 0.5 * ($_[0] >= 0 ? 1 : -1)) }
            sub tan     { sin($_[0]) / cos($_[0]) }
            sub asin    { atan2($_[0], sqrt(1 - $_[0] * $_[0])) }
            sub acos    { atan2(sqrt(1 - $_[0] * $_[0]), $_[0]) }
            sub pow     { $_[0] ** $_[1] }
            sub fmod    { $_[0] % $_[1] }
            sub deg2rad { $_[0] * 3.14159265358979 / 180 }
            sub rad2deg { $_[0] * 180 / 3.14159265358979 }
            ## no critic
            eval $expr;  ## safe: expression is already whitelist-validated
        };
        alarm(0);
        $res;
    };
    alarm(0);

    if ($@) {
        my $err = $@;
        $err =~ s/ at .* line \d+.*//s;
        botPrivmsg($self, $channel, "calc error: $err");
        return;
    }

    unless (defined $result) {
        botPrivmsg($self, $channel, "calc: undefined result.");
        return;
    }

    # Format nicely: integer if whole, 6 decimal places otherwise
    my $formatted = ($result == int($result) && abs($result) < 1e15)
        ? sprintf("%d", $result)
        : sprintf("%g", $result);

    # A5: store in per-nick history (last 3)
    $self->{_calc_history}{$nick} //= [];
    unshift @{ $self->{_calc_history}{$nick} }, "$expr = $formatted";
    splice @{ $self->{_calc_history}{$nick} }, 3;

    botPrivmsg($self, $channel, "$expr = $formatted");
    logBot($self, $ctx->message, $channel, "calc", $expr);
    return 1;
}


1;
