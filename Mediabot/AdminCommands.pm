package Mediabot::AdminCommands;

# =============================================================================
# Mediabot::AdminCommands — Bot administration commands
#   mbStatus, mbQuit, mbRehash, mbRestart, mbJump, mbExec, debug, update
# =============================================================================

use strict;
use warnings;
use File::Basename qw(dirname);
use POSIX qw(strftime setsid);
use Exporter 'import';
use List::Util qw(min);
use Sys::Hostname qw(hostname);
use Mediabot::Helpers;

use Mediabot::Context;
use Mediabot::Radio::Icecast;

our @EXPORT = qw(
    debug_ctx
    mbExec_ctx
    mbJump
    mbQuit_ctx
    mbRehash_ctx
    mbRestart
    mbStatus_ctx
    radioStatus_ctx
    radioMounts_ctx
    displayRadioListeners_ctx
    radioNext_ctx
    song_ctx
    update
    update_ctx
);

sub mbQuit_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $reason = @args ? join(' ', @args) : 'bye';

    logBot($self, $ctx->message, undef, 'die', $reason);

    $self->{Quit} = 1;
    $self->{irc}->send_message('QUIT', undef, $reason);
}

# Check if the user is logged in
sub debug_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;   # may be undef for private
    my @args    = @{ $ctx->args // [] };

    my $irc_nick = $self->{irc}->nick_folded;
    my $conf     = $self->{conf};  # Mediabot::Conf object

    # --- Auth / ACL ---
    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick)
            . " debug attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice($self, $nick, "You must be logged to use this command - /msg $irc_nick login username password");
        return;
    }

    unless (eval { $user->has_level('Owner') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick)
            . " debug attempt (Owner required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Show current debug level if no argument is given ---
    my $level = $args[0];
    unless (defined $level && $level ne '') {
        my $current = $conf->get("main.MAIN_PROG_DEBUG");
        $current = 0 unless defined $current && $current =~ /^\d+$/;
        botNotice($self, $nick, "Current debug level is $current (0-5)");
        return 1;
    }

    $level =~ s/^\s+|\s+$//g;

    # --- Validate new debug level (0..5) ---
    unless ($level =~ /^[0-5]$/) {
        botNotice($self, $nick, "Syntax: debug <debug_level>");
        botNotice($self, $nick, "debug_level must be between 0 and 5");
        return;
    }

    # --- Persist config + update runtime logger immediately ---
    $conf->set("main.MAIN_PROG_DEBUG", $level);
    $conf->save();

    # Keep backward compatibility with existing logger structure
    $self->{logger}->{debug_level} = $level;

    $self->{logger}->log(1, "Debug set to $level");
    botNotice($self, $nick, "Debug level set to $level");

    logBot($self, $ctx->message, $channel, "debug", "Debug set to $level");
    return 1;
}

# Restart bot
sub mbRestart {
	my ($self, $message, $sNick, @tArgs) = @_;
	my $conf = $self->{conf};

	my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " restart command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Owner")) {
        my $msg = $message->prefix . " restart command attempt (level [Owner] required for " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $full_params = $tArgs[0] // '';

    my @restart_args = grep {
        defined($_) && $_ ne '' && $_ !~ /^--server=/
    } split(/\s+/, $full_params);

    # Always pass --daemon (required by mb_restart.sh) and --conf
    unshift @restart_args, '--daemon'
        unless grep { $_ eq '--daemon' } @restart_args;
    if (defined $self->{config_file} && $self->{config_file} ne '') {
        push @restart_args, '--conf=' . $self->{config_file}
            unless grep { /^--conf=/ } @restart_args;
    }

    $self->{logger}->log(
        4,
        "Restart requested with args: " . join(' ', @restart_args)
    );

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            my $bot_dir     = dirname(dirname(__FILE__));
            my $restart_bin = "$bot_dir/mb_restart.sh";

            $self->{logger}->log(1, "Restart request from " . $user->nickname . " using $restart_bin");
            setsid;
            exec $restart_bin, @restart_args;
            exit 1;
        } else {
            botNotice($self, $sNick, "Restarting");
            $self->{metrics}->inc('mediabot_restart_total') if $self->{metrics};
            logBot($self, $message, undef, "restart", "");
            $self->{Quit} = 1;
            $self->{irc}->send_message("QUIT", undef, "Be right back");
        }
    } else {
        $self->{logger}->log(1, "Failed to fork for restart");
        botNotice($self, $sNick, "Restart failed: unable to fork.");
    }

    return;
}

# Jump to another server (/jump <server>)
sub mbJump {
    my ($self, $message, $sNick, @tArgs) = @_;
    my $conf = $self->{conf};

    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " jump command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Owner")) {
        my $msg = $message->prefix . " jump command attempt (level [Owner] required for " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $full_params = $tArgs[0] // '';
    my $server      = $tArgs[1] // '';

    unless (defined($server) && $server ne '') {
        botNotice($self, $sNick, "Syntax: jump <server>");
        return;
    }

    my @restart_args = grep {
        defined($_) && $_ ne '' && $_ !~ /^--server=/
    } split(/\s+/, $full_params);

    # Always pass --daemon (required by mb_restart.sh) and --conf
    unshift @restart_args, '--daemon'
        unless grep { $_ eq '--daemon' } @restart_args;
    if (defined $self->{config_file} && $self->{config_file} ne '') {
        push @restart_args, '--conf=' . $self->{config_file}
            unless grep { /^--conf=/ } @restart_args;
    }

    $self->{logger}->log(
        4,
        "Jump requested to $server with restart args: " . join(' ', @restart_args)
    );

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            my $bot_dir     = dirname(dirname(__FILE__));
            my $restart_bin = "$bot_dir/mb_restart.sh";

            $self->{logger}->log(1, "Jump request from " . $user->nickname . " to $server using $restart_bin");
            setsid;
            exec $restart_bin, @restart_args, "--server=$server";
            exit 1;
        } else {
            botNotice($self, $sNick, "Jumping to $server");
            $self->{metrics}->inc('mediabot_jump_total') if $self->{metrics};
            logBot($self, $message, undef, "jump", $server);
            $self->{Quit} = 1;
            $self->{irc}->send_message("QUIT", undef, "Changing server");
        }
    } else {
        $self->{logger}->log(1, "Failed to fork for jump");
        botNotice($self, $sNick, "Jump failed: unable to fork.");
    }

    return;
}

# Make a colored string with a high-contrast palette (dark+light bg friendly)


# Display the last N entries from ACTIONS_LOG table
# Syntax:
#   lastcom [<count>]
# Notes:
#   - count defaults to 5, max is 8
#   - Master+ only
#   - Always private reply (NOTICE)
sub mbRehash_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $user  = $ctx->user;
    my $unick = eval { $user->nickname } // $nick;

    my $ok = $self->rehash_runtime_state();

    # A6: re-attach the logger to Conf so warn() redirects correctly after reload
    if ($ok && $self->{conf} && $self->{logger} && $self->{conf}->can('set_logger')) {
        $self->{conf}->set_logger($self->{logger});
    }

    if ($ok) {
        if (defined $channel && $channel ne '') {
            botPrivmsg($self, $channel, "($nick) Successfully rehashed");
        } else {
            botNotice($self, $nick, "Successfully rehashed");
        }
        logBot($self, $message, $channel, "rehash", @args);
        return 1;
    } else {
        if (defined $channel && $channel ne '') {
            botPrivmsg($self, $channel, "($nick) Rehash failed - check logs");
        } else {
            botNotice($self, $nick, "Rehash failed - check logs");
        }
        return;
    }
}

# Play a radio request
# ---------------------------------------------------------------------------
# Radio command wrappers — Context-based shims over legacy handlers.
# The legacy subs (playRadio, rplayRadio, etc.) keep their original
# signature ($self, $message, $sNick, $sChannel, @tArgs) unchanged.
# ---------------------------------------------------------------------------


sub mbExec_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Where to send output:
    # - In channel if command was issued in a channel
    # - By notice if command was issued in private
    my $is_private = !defined($channel) || $channel eq '';
    my $send = $is_private
        ? sub { my ($msg) = @_; botNotice($self, $nick, $msg) }
        : sub { my ($msg) = @_; botPrivmsg($self, $channel, $msg) };

    # Retrieve user object (from context if available)
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    # Authentication check
    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx exec command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged in to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    # Privilege check: Owner only
    unless (eval { $user->has_level("Owner") }) {
        my $lvl = eval { $user->level } // 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;

        my $msg = "$pfx exec command attempt (command level [Owner] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Build command string
    my $command = join(" ", @args);
    $command =~ s/^\s+|\s+$//g if defined $command;

    unless (defined($command) && $command ne "") {
        botNotice($self, $nick, "Syntax: exec <command>");
        return;
    }

    # B1/A1: limit command length to prevent abuse
    if (length($command) > 512) {
        botNotice($self, $nick, "Command too long (max 512 chars).");
        return;
    }

    # Very basic safety guard for obviously destructive commands
    # B1/A1: expanded safety blacklist — Owner-only but defence-in-depth
    if (
        $command =~ /\brm\s+-rf\b/i                        # rm -rf
        || $command =~ /\brm\s+-r\s+\//i                  # rm -r /
        || $command =~ /:()\s*{\s*:|:&};:/                  # bash fork bomb
        || $command =~ /\bshutdown\b|\breboot\b/i
        || $command =~ /\bmkfs\b/i
        || $command =~ /\bdd\s+if=/i
        || $command =~ />\s*\/dev\/sd/i
        || $command =~ /(?:curl|wget)\b.*\|\s*(?:bash|sh)\b/i  # download+exec
        || $command =~ />\s*\/etc\/(?:passwd|shadow|sudoers)/i  # clobber system files
    ) {
        botNotice($self, $nick, "Don't be that evil!");
        return;
    }

    # Log the attempt in console (owner-only, so it is fine to log full command)
    my $pfx = eval { $message->prefix } // $nick;
    noticeConsoleChan($self, "$pfx exec: $command");

    # Execute command with a hard timeout and sanitized output.
    #
    # This remains an Owner-only shell command, but the bot must not hang forever
    # if the command blocks. Output is still limited to 3 lines, with IRC-hostile
    # control characters stripped and long lines shortened.
    my $exec_timeout = eval { $self->{conf}->get('main.EXEC_TIMEOUT_SECONDS') } || 8;
    $exec_timeout = 8 unless defined($exec_timeout) && $exec_timeout =~ /^\d+$/;
    $exec_timeout = 1  if $exec_timeout < 1;
    $exec_timeout = 30 if $exec_timeout > 30;

    my $timeout_bin = '/usr/bin/timeout';

    unless (-x $timeout_bin) {
        $self->{logger}->log(1, "mbExec_ctx: refusing to run exec without $timeout_bin");
        $send->("Execution unavailable: $timeout_bin not found.");
        return;
    }

    my $shell = "$command 2>&1 | tail -n 3";
    my @runner = ($timeout_bin, '--kill-after=2s', "${exec_timeout}s", 'sh', '-c', $shell);

    open my $cmd_fh, "-|", @runner or do {
        $self->{logger}->log(3, "mbExec_ctx: Failed to execute: $command");
        $send->("Execution failed.");
        return;
    };

    my $i          = 0;
    my $has_output = 0;

    while (my $line = <$cmd_fh>) {
        chomp $line;
        $line =~ s/\r//g;

        # Strip ASCII control characters except horizontal tab.
        $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;

        if (length($line) > 350) {
            $line = substr($line, 0, 347) . '...';
        }

        $send->("$i: $line");
        $has_output = 1;

        if (++$i >= 3) {
            # B1/A1: /usr/bin/timeout handles child lifetime;
            # just break — close() will return quickly once the pipe is drained
            last;
        }
    }

    close $cmd_fh;
    my $exit_status = $? >> 8;

    if (-x $timeout_bin && ($exit_status == 124 || $exit_status == 137)) {
        $send->("Command timed out after ${exec_timeout}s.");
        $self->{logger}->log(2, "mbExec_ctx: command timed out after ${exec_timeout}s: $command");
    }
    elsif (!$has_output) {
        $send->("No output.");
    }

    # Log to ACTIONS_LOG as usual
    logBot($self, $message, ($channel // "(private)"), "exec", $command);

    return 1;
}

# Get the harbor ID from LIQUIDSOAP telnet server
sub mbStatus_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Master only
    return unless $ctx->require_level('Master');

    # --- Bot Uptime ---
    my $uptime = time - ($self->{iConnectionTimestamp} // time);
    my $days    = int($uptime / 86400);
    my $hours   = sprintf('%02d', int(($uptime % 86400) / 3600));
    my $minutes = sprintf('%02d', int(($uptime % 3600) / 60));
    my $seconds = sprintf('%02d', $uptime % 60);

    my $uptime_str = '';
    $uptime_str .= "$days days, "  if $days > 0;
    $uptime_str .= "${hours}h "    if $hours > 0;
    $uptime_str .= "${minutes}mn " if $minutes > 0;
    $uptime_str .= "${seconds}s";
    $uptime_str ||= 'Unknown';

    # --- Server uptime ---
    my $server_uptime = 'Unavailable';
    if (open my $fh_uptime, '<', '/proc/uptime') {
        if (defined(my $line = <$fh_uptime>)) {
            my ($uptime_seconds) = split /\s+/, $line;
            if (defined $uptime_seconds && $uptime_seconds =~ /^\d+(?:\.\d+)?$/) {
                my $sys_uptime = int($uptime_seconds);
                my $sys_days   = int($sys_uptime / 86400);
                my $sys_hours  = int(($sys_uptime % 86400) / 3600);
                my $sys_mins   = int(($sys_uptime % 3600) / 60);

                $server_uptime = sprintf(
                    'up %d days, %02d:%02d',
                    $sys_days,
                    $sys_hours,
                    $sys_mins,
                );
            }
        }
        close $fh_uptime;
    } else {
        $self->{logger}->log(1, "Could not read /proc/uptime");
    }

    # --- OS Info ---
    my $uname = 'Unknown';
    my @uname_parts = eval { POSIX::uname() };

    if (@uname_parts >= 5) {
        my ($sysname, undef, $release, $version, $machine) = @uname_parts;
        my $host = eval { hostname() } || 'unknown-host';

        $uname = join ' ', grep { defined $_ && $_ ne '' } (
            $sysname,
            $host,
            $release,
            $version,
            $machine,
        );
    } else {
        $self->{logger}->log(1, "POSIX::uname failed while building status output");
    }

    # --- Memory usage ---
    my ($vm, $rss, $shared, $data) = ('?', '?', '?', '?');
    eval {
        require Memory::Usage;
        my $mu = Memory::Usage->new();
        $mu->record('Memory stats');
        my @mem_state = $mu->state();
        if (@mem_state && ref $mem_state[0][0] eq 'ARRAY') {
            my @values = @{ $mem_state[0][0] };
            $vm     = sprintf('%.2f', $values[2] / 1024) if defined $values[2];
            $rss    = sprintf('%.2f', $values[3] / 1024) if defined $values[3];
            $shared = sprintf('%.2f', $values[4] / 1024) if defined $values[4];
            $data   = sprintf('%.2f', $values[6] / 1024) if defined $values[6];
        }
        1;
    } or do {
        $self->{logger}->log(1, "Memory::Usage failed: $@");
    };

    botNotice(
        $self, $nick,
        $self->{conf}->get('main.MAIN_PROG_NAME') . " v" . $self->{main_prog_version} . " Uptime: $uptime_str"
    );
    botNotice($self, $nick, "Memory usage (VM ${vm}MB) (Resident ${rss}MB) (Shared ${shared}MB) (Data+Stack ${data}MB)");
    botNotice($self, $nick, "Server: $uname");
    botNotice($self, $nick, "Server uptime: $server_uptime");

    logBot($self, $ctx->message, undef, 'status', undef);
}

sub radioStatus_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $conf = $self->{conf};

    return unless $ctx->require_level('Master');

    my $base_url      = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
    my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || $base_url;
    my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio160.mp3';
    my $timeout       = $conf->get('radio.RADIO_ICECAST_TIMEOUT');

    $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => $base_url,
        timeout  => $timeout,
        logger   => $self->{logger},
    );

    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        botNotice($self, $nick, "Radio status error: " . ($info->{error} || 'unknown error'));
        logBot($self, $ctx->message, undef, 'radiostatus', 'error');
        return;
    }

    my $host            = $info->{host}            || '?';
    my $server_id       = $info->{server_id}       || '?';
    my $sources         = defined $info->{sources}         ? $info->{sources}         : '?';
    my $total_listeners = defined $info->{total_listeners} ? $info->{total_listeners} : '?';
    my $mount           = $info->{primary_mount}   || '?';
    my $bitrate         = defined $info->{bitrate}         ? $info->{bitrate}         : '?';
    my $mount_listeners = defined $info->{mount_listeners} ? $info->{mount_listeners} : 0;
    my $title           = defined $info->{title} && $info->{title} ne '' ? $info->{title} : 'unknown';
    my $listen_url      = $info->{listen_url}      || '?';

    botNotice($self, $nick, "Icecast $host | $server_id | sources=$sources | listeners=$total_listeners");
    botNotice($self, $nick, "Primary mount: $mount (${bitrate}k, ${mount_listeners} listeners)");
    botNotice($self, $nick, "Now playing: $title");
    botNotice($self, $nick, "Listen: $listen_url");

    logBot($self, $ctx->message, undef, 'radiostatus', undef);
}

sub radioMounts_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $conf = $self->{conf};

    return unless $ctx->require_level('Master');

    my $base_url = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
    my $timeout  = $conf->get('radio.RADIO_ICECAST_TIMEOUT');
    $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => $base_url,
        timeout  => $timeout,
        logger   => $self->{logger},
    );

    my $mounts = $radio->get_mounts();
    unless ($mounts->{ok}) {
        botNotice($self, $nick, "Radio mounts error: " . ($mounts->{error} || 'unknown error'));
        logBot($self, $ctx->message, undef, 'radiomounts', 'error');
        return;
    }

    my $list = $mounts->{mounts} || [];
    if (!@$list) {
        botNotice($self, $nick, "No Icecast mounts found.");
        logBot($self, $ctx->message, undef, 'radiomounts', undef);
        return;
    }

    for my $m (@$list) {
        my $mount       = $m->{mount}       || '?';
        my $bitrate     = defined $m->{bitrate}   ? $m->{bitrate}   : '?';
        my $listeners   = defined $m->{listeners} ? $m->{listeners} : '?';
        my $title       = defined $m->{title} && $m->{title} ne '' ? $m->{title} : 'n/a';
        my $description = defined $m->{description} && $m->{description} ne '' ? $m->{description} : 'n/a';
        my $listenurl   = defined $m->{listenurl} && $m->{listenurl} ne '' ? $m->{listenurl} : 'n/a';

        botNotice(
            $self, $nick,
            "$mount | ${bitrate}k | listeners=$listeners | title=$title | desc=$description | url=$listenurl"
        );
    }

    logBot($self, $ctx->message, undef, 'radiomounts', undef);
}


sub displayRadioListeners_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $conf = $self->{conf};

    my $base_url      = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
    my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || $base_url;
    my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio160.mp3';
    my $timeout       = $conf->get('radio.RADIO_ICECAST_TIMEOUT');

    $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => $base_url,
        timeout  => $timeout,
        logger   => $self->{logger},
    );

    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        my $msg = "Radio listeners error: " . ($info->{error} || 'unknown error');

        if ($ctx->is_private) {
            $ctx->reply_private($msg);
        } else {
            $ctx->reply($msg);
        }

        logBot($self, $ctx->message, undef, 'listeners', 'error');
        return;
    }

    my $total           = defined $info->{total_listeners} ? $info->{total_listeners} : '?';
    my $mount           = $info->{primary_mount} || $primary_mount;
    my $mount_listeners = defined $info->{mount_listeners} ? $info->{mount_listeners} : '?';

    my $msg = "Radio listeners: total=$total | $mount=$mount_listeners";

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'listeners', undef);
    return 1;
}

sub radioNext_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;

    my $msg = "nextsong is not wired to a radio scheduler yet; current song follows.";

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'nextsong', 'not_implemented');
    return song_ctx($ctx);
}

sub update_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $script = 'install/deploy_update.sh';
    my $msg = "The IRC update command is disabled for safety. Use ./$script manually from the mediabot_v3 directory.";

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        botNotice($self, $nick, $msg);
    }

    logBot($self, $ctx->message, undef, 'update', 'disabled');
    return 1;
}

sub update {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => 'update',
        args    => \@tArgs,
    );

    return update_ctx($ctx);
}

sub song_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $conf = $self->{conf};

    my $base_url      = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
    my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || $base_url;
    my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio160.mp3';
    my $timeout       = $conf->get('radio.RADIO_ICECAST_TIMEOUT');

    $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => $base_url,
        timeout  => $timeout,
        logger   => $self->{logger},
    );

    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        my $msg = "Radio error: " . ($info->{error} || 'unknown error');
        if ($ctx->is_private) {
            $ctx->reply_private($msg);
        } else {
            $ctx->reply($msg);
        }
        logBot($self, $ctx->message, undef, 'song', 'error');
        return;
    }

    my $title      = defined $info->{title} && $info->{title} ne '' ? $info->{title} : 'unknown';
    my $listen_url = $info->{listen_url} || ($public_base . $primary_mount);

    my $msg =
          String::IRC->new('[ ')->white
        . String::IRC->new($listen_url)->blue->underline
        . String::IRC->new(' ] - [ ')->white
        . String::IRC->new($title)->yellow
        . String::IRC->new(' ]')->white;

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'song', undef);
}

1;

