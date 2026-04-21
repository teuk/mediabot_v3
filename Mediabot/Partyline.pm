package Mediabot::Partyline;

# +---------------------------------------------------------------------------+
# ! Mediabot::Partyline                                                       !
# ! TCP telnet-style partyline for bot administration                        !
# !                                                                           !
# ! Access : telnet <host> <PARTYLINE_PORT>  or  nc <host> <PARTYLINE_PORT>  !
# !                                                                           !
# ! Authentication : login <user> <password>                                 !
# ! Required global level : Master (or above)                                !
# !                                                                           !
# ! Commands :                                                                !
# !   .help                  — this help                                     !
# !   .stat                  — channel status (owner, chansets, nick count)  !
# !   .say #chan <message>   — send a PRIVMSG to a channel                   !
# !   .who #chan             — list nicks present in a channel               !
# !   .join #chan [key]      — make the bot join a channel                   !
# !   .part #chan            — make the bot part a channel                   !
# !   .nick <newnick>        — change the bot's nick                         !
# !   .raw <IRC command>     — send a raw IRC command (Owner only)           !
# !   .quit                  — close this session                            !
# +---------------------------------------------------------------------------+

use strict;
use warnings;
use POSIX qw(setsid);
use File::Basename qw(dirname);
use IO::Async::Listener;
use IO::Async::Stream;
use Scalar::Util qw(weaken);

our @EXPORT_OK = qw();

# +---------------------------------------------------------------------------+
# ! Constructor                                                               !
# +---------------------------------------------------------------------------+

sub new {
    my ($class, %args) = @_;

    my $self = {
        bot     => $args{bot},              # Mediabot object
        loop    => $args{loop},             # IO::Async::Loop
        port    => $args{port} || 23456,
        streams => {},                      # fd => IO::Async::Stream
        users   => {},                      # fd => { authenticated, login, level, level_desc }
        motd    => $args{motd} || [],       # MOTD lines shown after login
    };

    bless $self, $class;

    $self->_start_listener;

    return $self;
}

# +---------------------------------------------------------------------------+
# ! Accessors                                                                 !
# +---------------------------------------------------------------------------+

sub get_port {
    my ($self) = @_;
    return $self->{bot}->{conf}->get("main.PARTYLINE_PORT") || 23456;
}

# +---------------------------------------------------------------------------+
# ! Internal : start TCP listener                                             !
# +---------------------------------------------------------------------------+

sub _start_listener {
    my ($self) = @_;

    my $loop = $self->{loop};
    my $bot  = $self->{bot};
    weaken($bot);

    $loop->listen(
        service  => $self->{port},
        socktype => 'stream',
        on_stream => sub {
            my ($stream) = @_;
            my $id = fileno($stream->read_handle);

            $self->{users}{$id} = {
                authenticated  => 0,
                login          => '',
                level          => undef,
                level_desc     => '',
                # Rate limiting: max 10 commands per 5 seconds
                rate_window    => time(),
                rate_count     => 0,
                # Brute-force: max 5 failed login attempts before disconnect
                login_failures => 0,
                # Console: log level redirected to this session (undef = off)
                console_level  => undef,
            };
            $self->{streams}{$id} = $stream;

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;

                    while ($$buffref =~ s/^([^\n]*)\n//) {
                        my $line = $1;
                        $line =~ s/\r$//;
                        $self->{bot}->{logger}->log(3, "Partyline <- '$line' (fd=$id)");
                        eval {
                            $self->_handle_line($stream, $id, $line);
                        };
                        if ($@) {
                            $self->{bot}->{logger}->log(1, "Partyline exception: $@");
                            $stream->write("Internal error: $@\r\n");
                        }
                    }

                    if ($eof) {
                        $self->{bot}->{logger}->log(3, "Partyline EOF (fd=$id)");
                        $self->_close_session($id);
                    }

                    return 0;
                },
                on_closed => sub {
                    $self->{bot}->{logger}->log(3, "Partyline connection closed (fd=$id)");
                    my $nick = ($self->{users}{$id} && $self->{users}{$id}{authenticated})
                        ? ($self->{users}{$id}{login} // '')
                        : '';
                    $self->_broadcast("*** $nick left the partyline (disconnected). ***") if $nick;
                    $self->_close_session($id);
                },
            );

            $loop->add($stream);
            $stream->write("=== Mediabot Partyline ===\r\nlogin <user> <password>\r\n");
            $self->{bot}->{logger}->log(2, "Partyline: new connection (fd=$id)");

            if ($self->{bot}->{metrics}) {
                $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', 1);
            }
        },
        on_resolve_error => sub {
            $bot->{logger}->log(0, "Partyline: resolve error: $_[0]");
        },
        on_listen_error => sub {
            $bot->{logger}->log(0, "Partyline: listen error: $_[0]");
        },
    )->get;
}

# +---------------------------------------------------------------------------+
# ! Internal : clean up a session                                             !
# +---------------------------------------------------------------------------+

sub _close_session {
    my ($self, $id) = @_;

    if ($self->{bot}->{metrics}) {
        my $current = $self->{bot}->{metrics}->get('mediabot_partyline_sessions_current');
        $current = 0 unless defined $current;
        if ($current > 0) {
            $self->{bot}->{metrics}->add('mediabot_partyline_sessions_current', -1);
        }
    }

    # Remove console hook from logger if active
    if ($self->{bot} && $self->{bot}->{logger}
        && $self->{bot}->{logger}->can('remove_console_hook')) {
        $self->{bot}->{logger}->remove_console_hook($id);
    }

    delete $self->{users}{$id};
    delete $self->{streams}{$id};
}

# ---------------------------------------------------------------------------
# _broadcast($msg, $exclude_id)
# Send a message to all authenticated partyline users, optionally skipping
# one session (typically the sender).
# ---------------------------------------------------------------------------
sub _broadcast {
    my ($self, $msg, $exclude_id) = @_;
    $exclude_id //= -1;

    for my $fid (keys %{ $self->{users} }) {
        next if $fid == $exclude_id;
        next unless $self->{users}{$fid}{authenticated};
        my $stream = $self->{streams}{$fid};
        next unless $stream;
        $stream->write($msg . "\r\n");
    }
}

# ---------------------------------------------------------------------------
# _broadcast_chat($nick, $text, $exclude_id)
# Broadcast a chat line in Eggdrop partyline style:
#   <nick> text
# ---------------------------------------------------------------------------
sub _broadcast_chat {
    my ($self, $nick, $text, $exclude_id) = @_;
    $self->_broadcast("<$nick> $text", $exclude_id);
    $self->{bot}->{logger}->log(2, "Partyline chat <$nick> $text");
}

# +---------------------------------------------------------------------------+
# ! Internal : dispatch an incoming line                                      !
# +---------------------------------------------------------------------------+

sub _handle_line {
    my ($self, $stream, $id, $line) = @_;

    my $session = $self->{users}{$id};

    # ---- Rate limiting : max 10 commands per 5 seconds -------------------
    my $now = time();
    if ($now - ($session->{rate_window} // $now) >= 5) {
        $session->{rate_window} = $now;
        $session->{rate_count}  = 0;
    }
    $session->{rate_count}++;
    if ($session->{rate_count} > 10) {
        $self->{bot}->{logger}->log(2, "Partyline: rate limit hit for fd=$id login=" . ($session->{login} || 'anon'));
        $stream->write("Rate limit exceeded. Slow down.\r\n");
        return;
    }

    # ---- Not yet authenticated : only accept "login" ----------------------
    unless ($session->{authenticated}) {
        if ($line =~ /^login\s+(\S+)\s+(\S+)$/) {
            $self->_do_login($stream, $id, $1, $2);
        }
        else {
            $stream->write("Please authenticate first: login <user> <password>\r\n");
        }
        return;
    }

        # ---- Authenticated : dispatch commands --------------------------------
    if    ($line =~ /^\.help$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.help' }) if $self->{bot}->{metrics};
        $self->_cmd_help($stream, $id)
    }
    elsif ($line =~ /^\.stat$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.stat' }) if $self->{bot}->{metrics};
        $self->_cmd_stat($stream, $id)
    }
    elsif ($line =~ /^\.console(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.console' }) if $self->{bot}->{metrics};
        $self->_cmd_console($stream, $id, $1)
    }
    elsif ($line =~ /^\.whom$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.whom' }) if $self->{bot}->{metrics};
        $self->_cmd_whom($stream, $id)
    }
    elsif ($line =~ /^\.match\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.match' }) if $self->{bot}->{metrics};
        $self->_cmd_match($stream, $id, $1)
    }
    elsif ($line =~ /^\.boot\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.boot' }) if $self->{bot}->{metrics};
        $self->_cmd_boot($stream, $id, $1)
    }
    elsif ($line =~ /^\.motd(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.motd' }) if $self->{bot}->{metrics};
        $self->_cmd_motd($stream, $id, $1)
    }
    elsif ($line =~ /^\.say\s+(#\S+)\s+(.+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.say' }) if $self->{bot}->{metrics};
        $self->_cmd_say($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.who\s+(#\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.who' }) if $self->{bot}->{metrics};
        $self->_cmd_who($stream, $id, $1)
    }
    elsif ($line =~ /^\.join\s+(#\S+)(?:\s+(\S+))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.join' }) if $self->{bot}->{metrics};
        $self->_cmd_join($stream, $id, $1, $2)
    }
    elsif ($line =~ /^\.part\s+(#\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.part' }) if $self->{bot}->{metrics};
        $self->_cmd_part($stream, $id, $1)
    }
    elsif ($line =~ /^\.nick\s+(\S+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.nick' }) if $self->{bot}->{metrics};
        $self->_cmd_nick($stream, $id, $1)
    }
    elsif ($line =~ /^\.raw\s+(.+)$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.raw' }) if $self->{bot}->{metrics};
        $self->_cmd_raw($stream, $id, $1)
    }
    elsif ($line =~ /^\.rehash$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.rehash' }) if $self->{bot}->{metrics};
        $self->_cmd_rehash($stream, $id)
    }
    elsif ($line =~ /^\.restart(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.restart' }) if $self->{bot}->{metrics};
        $self->_cmd_restart($stream, $id, $1)
    }
    elsif ($line =~ /^\.die(?:\s+(.*))?$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.die' }) if $self->{bot}->{metrics};
        $self->_cmd_die($stream, $id, $1 // "Partyline requested termination")
    }
    elsif ($line =~ /^\.quit$/i) {
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => '.quit' }) if $self->{bot}->{metrics};
        my $nick = $self->{users}{$id}{login} // 'unknown';
        $self->_broadcast("*** $nick left the partyline. ***", $id);
        $stream->write("Goodbye.\r\n");
        $stream->close_when_empty;
        $self->_close_session($id);
    }
    elsif ($line =~ /^\./) {
        # Unknown dot-command
        $stream->write("Unknown command. Type .help for available commands.\r\n");
    }
    else {
        # Chat broadcast — anything not starting with '.' goes to everyone
        my $nick = $self->{users}{$id}{login} // 'unknown';
        $self->{bot}->{metrics}->inc('mediabot_commands_partyline_total', { command => 'chat' })
            if $self->{bot}->{metrics};
        # Echo back to sender with same format so they see their own message
        $stream->write("<$nick> $line\r\n");
        # Broadcast to all other authenticated users
        $self->_broadcast_chat($nick, $line, $id);
    }
}

# +---------------------------------------------------------------------------+
# ! Internal : authentication                                                 !
# +---------------------------------------------------------------------------+

sub _do_login {
    my ($self, $stream, $id, $login, $password) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    # Brute-force protection
    my $max_failures = 5;
    my $failures = $self->{users}{$id}{login_failures} // 0;
    if ($failures >= $max_failures) {
        $bot->{logger}->log(1, "Partyline: too many login failures for fd=$id — closing connection");
        $stream->write("Too many authentication failures. Disconnecting.\r\n");
        $stream->close_now;
        return;
    }

    my $sth = $dbh->prepare(
        "SELECT u.id_user, u.nickname, u.password, ul.level, ul.description
         FROM USER u
         JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
         WHERE u.nickname = ?"
    );

    unless ($sth->execute($login)) {
        $bot->{logger}->log(1, "Partyline: SQL error on login query: " . $DBI::errstr);
        $stream->write("Internal error during authentication.\r\n");
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $bot->{logger}->log(2, "Partyline: unknown user '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Authentication failed.\r\n");
        return;
    }

    unless ($bot->{auth}->verify_credentials($row->{id_user}, $login, $password)) {
        $bot->{logger}->log(2, "Partyline: bad password for '$login' (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Authentication failed.\r\n");
        return;
    }

    # Minimum level : Master (Owner=0, Master=1 => level <= 1)
    unless (defined($row->{level}) && $row->{level} <= 1) {
        $bot->{logger}->log(2, "Partyline: '$login' level=" . ($row->{level} // 'undef') . " insufficient (fd=$id)");
        $self->{users}{$id}{login_failures}++;
        $stream->write("Access denied: Master level or above required.\r\n");
        return;
    }

    # Reset counter on success
    $self->{users}{$id}{login_failures} = 0;

    $self->{users}{$id}{authenticated} = 1;
    $self->{users}{$id}{login}         = $login;
    $self->{users}{$id}{level}         = $row->{level};
    $self->{users}{$id}{level_desc}    = $row->{description};

    if ($bot->{metrics}) {
        $bot->{metrics}->inc('mediabot_partyline_logins_total');
    }

    $bot->{logger}->log(2, "Partyline: '$login' authenticated (level=" . $row->{description} . ", fd=$id)");
    $stream->write("Authenticated as $login (" . $row->{description} . ").\r\nType .help for available commands.\r\n");

    # Display MOTD if set
    $self->_send_motd($stream) if @{ $self->{motd} || [] };

    # Show who is on the partyline (Eggdrop-style auto .whom on join)
    $self->_cmd_whom($stream, $id);

    # Announce arrival to other partyline users
    $self->_broadcast("*** $login joined the partyline. ***", $id);
}

# +---------------------------------------------------------------------------+
# ! Commands                                                                  !
# +---------------------------------------------------------------------------+

# ---------------------------------------------------------------------------
# .help
# ---------------------------------------------------------------------------
sub _cmd_help {
    my ($self, $stream, $id) = @_;
    $stream->write(
        "Available commands:\r\n"
      . "  .help               - this help\r\n"
      . "  .stat               - channel status (owner, chansets, nick count)\r\n"
      . "  .whom               - list users currently on the partyline\r\n"
      . "  .match <handle>     - show user record (wildcards * ? allowed)\r\n"
      . "  .say #chan <msg>    - send a message to a channel\r\n"
      . "  .who #chan          - list nicks present in a channel\r\n"
      . "  .join #chan [key]   - make the bot join a channel\r\n"
      . "  .part #chan         - make the bot part a channel\r\n"
      . "  .nick <newnick>     - change the bot's nick\r\n"
      . "  .raw <IRC command>  - send a raw IRC command (Owner only)\r\n"
      . "  .rehash             - reload configuration and runtime state\r\n"
      . "  .restart            - reconnect IRC without killing process (Owner)\r\n"
      . "  .die                - terminate bot process entirely (Owner only)\r\n"
      . "  .console [0-5|off]  - redirect bot log to this session\r\n"
      . "  .boot <handle>      - kick a user off the partyline (Owner)\r\n"
      . "  .motd [text|clear]  - show or set message of the day (Owner)\r\n"
      . "  .quit               - close this partyline session\r\n"
      . "\r\n"
      . "Chat:\r\n"
      . "  <text>              - broadcast to all partyline users\r\n"
    );
}

# ---------------------------------------------------------------------------
# .console — display or change per-session log redirect level
# Usage : .console          → show current level
#         .console <0-5>    → set level (0=INFO … 5=DEBUG5)
#         .console off      → disable console
sub _cmd_console {
    my ($self, $stream, $id, $arg) = @_;

    my $bot    = $self->{bot};
    my $logger = $bot->{logger};

    unless ($logger && $logger->can('add_console_hook')) {
        $stream->write("Console hooks not supported by this logger.\r\n");
        return;
    }

    if (!defined $arg || $arg eq '') {
        my $cur = $self->{users}{$id}{console_level};
        if (defined $cur) {
            $stream->write("Console is ON at level $cur (0=INFO, 1=DEBUG1 … 5=DEBUG5).\r\n");
        } else {
            $stream->write("Console is OFF. Use .console <0-5> to enable.\r\n");
        }
        return;
    }

    if (lc($arg) eq 'off') {
        $logger->remove_console_hook($id);
        $self->{users}{$id}{console_level} = undef;
        $stream->write("Console disabled.\r\n");
        $bot->{logger}->log(2, "Partyline: " . ($self->{users}{$id}{login} // '?') . " disabled console (fd=$id)");
        return;
    }

    unless ($arg =~ /^[0-5]$/) {
        $stream->write("Usage: .console [0-5|off]  (0=INFO only, 5=all debug)\r\n");
        return;
    }

    my $level = int($arg);
    my $nick  = $self->{users}{$id}{login} // 'unknown';

    $logger->add_console_hook($id, $level, sub {
        my ($line) = @_;
        return unless $self->{streams}{$id};
        eval { $self->{streams}{$id}->write($line . "\r\n") };
    });

    $self->{users}{$id}{console_level} = $level;
    $stream->write("Console enabled at level $level.\r\n");
    $bot->{logger}->log(2, "Partyline: $nick set console level=$level (fd=$id)");
}

# .motd — display or set the partyline message of the day
# Usage : .motd              → display current MOTD
#         .motd <text>       → replace MOTD with a single line (Owner)
#         .motd clear        → clear MOTD (Owner)
sub _cmd_motd {
    my ($self, $stream, $id, $arg) = @_;

    my $nick = $self->{users}{$id}{login} // 'unknown';

    if (!defined $arg || $arg eq '') {
        $self->_send_motd($stream);
        return;
    }

    # Modification requires Owner level
    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: changing MOTD requires Owner level.\r\n");
        return;
    }

    if (lc($arg) eq 'clear') {
        $self->{motd} = [];
        $stream->write("MOTD cleared.\r\n");
        $self->{bot}->{logger}->log(2, "Partyline: $nick cleared MOTD");
        return;
    }

    $self->{motd} = [ $arg ];
    $stream->write("MOTD set.\r\n");
    $self->{bot}->{logger}->log(2, "Partyline: $nick set MOTD to: $arg");
}

# Internal helper — send MOTD lines to a stream
sub _send_motd {
    my ($self, $stream) = @_;

    my @lines = @{ $self->{motd} || [] };

    if (!@lines) {
        $stream->write("No MOTD set.\r\n");
        return;
    }

    $stream->write("--- MOTD ---\r\n");
    for my $line (@lines) {
        $stream->write("$line\r\n");
    }
    $stream->write("--- End of MOTD ---\r\n");
}

# .whom — list all authenticated partyline sessions (Eggdrop style)
sub _cmd_whom {
    my ($self, $stream, $id) = @_;

    my @lines;
    my $count = 0;

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} }) {
        my $u = $self->{users}{$fid};
        next unless $u && $u->{authenticated};

        my $nick       = $u->{login}        // '?';
        my $level_desc = $u->{level_desc}   // '?';
        my $con_level  = defined $u->{console_level}
            ? "console:" . $u->{console_level}
            : "console:off";
        my $is_me      = ($fid == $id) ? " *" : "";

        push @lines, sprintf("  %-14s  %-14s  fd=%-4d  %s%s",
            $nick, $level_desc, $fid, $con_level, $is_me);
        $count++;
    }

    if ($count == 0) {
        $stream->write("No users currently on the partyline.\r\n");
        return;
    }

    $stream->write(sprintf("Partyline users (%d):\r\n", $count));
    $stream->write("  Nick            Level           Socket  Console\r\n");
    $stream->write("  " . ("-" x 60) . "\r\n");
    $stream->write("$_\r\n") for @lines;
}

# .match <handle> — show user record from database (Eggdrop whois-style)
# Accepts exact handle or wildcard pattern (* and ?)
sub _cmd_match {
    my ($self, $stream, $id, $pattern) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    unless (defined $pattern && $pattern ne '') {
        $stream->write("Usage: .match <handle>  (wildcards * and ? allowed)\r\n");
        return;
    }

    # Convert Eggdrop-style wildcards to SQL LIKE wildcards
    my $sql_pat = $pattern;
    $sql_pat =~ s/\*/%/g;
    $sql_pat =~ s/\?/_/g;

    my $sth = $dbh->prepare(q{
        SELECT
            u.id_user,
            u.nickname,
            u.auth,
            u.info1,
            u.info2,
            ul.description  AS level_desc,
            ul.level        AS level_num,
            GROUP_CONCAT(uh.hostmask ORDER BY uh.id_user_hostmask SEPARATOR ' ')
                AS hostmasks
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
        WHERE u.nickname LIKE ?
        GROUP BY u.id_user, u.nickname, u.auth, u.info1, u.info2,
                 ul.description, ul.level
        ORDER BY u.nickname
        LIMIT 20
    });

    unless ($sth->execute($sql_pat)) {
        $bot->{logger}->log(1, "Partyline .match SQL error: $DBI::errstr");
        $stream->write("Database error.\r\n");
        return;
    }

    my $found = 0;
    while (my $row = $sth->fetchrow_hashref) {
        $found++;
        my $auth  = $row->{auth} ? "logged in" : "not logged in";
        my $masks = $row->{hostmasks} // "(none)";
        my $info1 = $row->{info1}     // "";
        my $info2 = $row->{info2}     // "";

        $stream->write("\r\n");
        $stream->write(sprintf("  Handle  : %s\r\n", $row->{nickname}));
        $stream->write(sprintf("  Level   : %s (%d)\r\n", $row->{level_desc}, $row->{level_num}));
        $stream->write(sprintf("  Status  : %s\r\n", $auth));
        $stream->write(sprintf("  Hosts   : %s\r\n", $masks));
        $stream->write(sprintf("  Info1   : %s\r\n", $info1)) if $info1 ne '';
        $stream->write(sprintf("  Info2   : %s\r\n", $info2)) if $info2 ne '';
    }
    $sth->finish;

    if ($found == 0) {
        $stream->write("No match for '$pattern'.\r\n");
    } elsif ($found > 1) {
        $stream->write(sprintf("\r\n%d match(es) for '%s'.\r\n", $found, $pattern));
    }
}

# .boot <handle> — kick a user off the partyline (Owner only)
sub _cmd_boot {
    my ($self, $stream, $id, $target_login) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .boot requires Owner level.\r\n");
        return;
    }

    unless (defined $target_login && $target_login ne '') {
        $stream->write("Usage: .boot <handle>\r\n");
        return;
    }

    # Find target session by login name
    my $target_id;
    for my $fid (keys %{ $self->{users} }) {
        next unless $self->{users}{$fid}{authenticated};
        if (lc($self->{users}{$fid}{login} // '') eq lc($target_login)) {
            $target_id = $fid;
            last;
        }
    }

    unless (defined $target_id) {
        $stream->write("No partyline session found for '$target_login'.\r\n");
        return;
    }

    if ($target_id == $id) {
        $stream->write("You cannot boot yourself. Use .quit instead.\r\n");
        return;
    }

    my $target_stream = $self->{streams}{$target_id};
    $bot->{logger}->log(2, "Partyline: $nick booted $target_login (fd=$target_id)");

    # Notify the victim
    if ($target_stream) {
        $target_stream->write("You have been booted by $nick.\r\n");
        $target_stream->close_when_empty;
    }

    # Announce to everyone else
    $self->_broadcast("*** $target_login was booted by $nick. ***", $target_id);
    $stream->write("Booted $target_login.\r\n");

    $self->_close_session($target_id);
}

# .stat — for each known channel: joined?, nick count, owner, chansets
# ---------------------------------------------------------------------------
sub _cmd_stat {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $irc = $bot->{irc};
    my $dbh = $bot->{dbh};

    unless ($irc && $irc->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    my $bot_nick = $irc->nick_folded // '';

    # Header
    $stream->write(sprintf("%-30s %-12s %-5s %-20s %s\r\n",
        "Channel", "Status", "Nicks", "Owner", "Chansets"));
    $stream->write(("-" x 90) . "\r\n");

    foreach my $chan_name (sort keys %{ $bot->{channels} }) {
        my $chan_obj   = $bot->{channels}{$chan_name};
        my $id_channel = eval { $chan_obj->get_id } // 0;

        # --- joined? + nick count ---
        my @nicks      = $bot->gethChannelsNicksOnChan($chan_name);
        my $joined     = grep { lc($_) eq lc($bot_nick) } @nicks;
        my $nick_count = scalar @nicks;
        my $status     = $joined ? "joined" : "NOT joined";

        # --- owner (USER_CHANNEL.level = 500) ---
        my $owner = 'none';
        if ($id_channel) {
            my $sth = $dbh->prepare(
                "SELECT u.nickname FROM USER u
                 JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
                 WHERE uc.id_channel = ? AND uc.level = 500
                 LIMIT 1"
            );
            if ($sth->execute($id_channel)) {
                if (my $row = $sth->fetchrow_hashref) {
                    $owner = $row->{nickname} if $row->{nickname};
                }
            }
            $sth->finish;
        }

        # --- chansets ---
        my $chansets = 'none';
        if ($id_channel) {
            my $sth = $dbh->prepare(
                "SELECT cl.chanset FROM CHANSET_LIST cl
                 JOIN CHANNEL_SET cs ON cs.id_chanset_list = cl.id_chanset_list
                 WHERE cs.id_channel = ?
                 ORDER BY cl.chanset"
            );
            if ($sth->execute($id_channel)) {
                my @flags;
                while (my $row = $sth->fetchrow_hashref) {
                    push @flags, '+' . $row->{chanset} if $row->{chanset};
                }
                $chansets = join(' ', @flags) if @flags;
            }
            $sth->finish;
        }

        $stream->write(sprintf("%-30s %-12s %-5d %-20s %s\r\n",
            $chan_name, $status, $nick_count, $owner, $chansets));
    }
}

# ---------------------------------------------------------------------------
# .say #chan <message>
# ---------------------------------------------------------------------------
sub _cmd_say {
    my ($self, $stream, $id, $chan, $msg) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    # Verify the bot is actually in that channel
    my $chan_lc = lc($chan);
    unless (exists $bot->{channels}{$chan} || exists $bot->{channels}{$chan_lc}) {
        $stream->write("Warning: bot does not appear to be in $chan (sending anyway).\r\n");
    }

    $bot->botPrivmsg($chan, $msg);
    $bot->{logger}->log(2, "Partyline: $nick sent to $chan: $msg");
    $stream->write("-> $chan: $msg\r\n");
}

# ---------------------------------------------------------------------------
# .who #chan — list nicks in a channel
# ---------------------------------------------------------------------------
sub _cmd_who {
    my ($self, $stream, $id, $chan) = @_;

    my $bot = $self->{bot};

    my @nicks = $bot->gethChannelsNicksOnChan($chan);
    unless (@nicks) {
        $stream->write("No nicks known for $chan (not joined or channel is empty).\r\n");
        return;
    }

    $stream->write(scalar(@nicks) . " nick(s) in $chan:\r\n");
    $stream->write(join(', ', sort @nicks) . "\r\n");
}

# ---------------------------------------------------------------------------
# .join #chan [key]
# ---------------------------------------------------------------------------
sub _cmd_join {
    my ($self, $stream, $id, $chan, $key) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

        $bot->joinChannel($chan, $key);

    if ($bot->can('refresh_channel_nicklist')) {
        eval { $bot->refresh_channel_nicklist($chan) };
    }

    $bot->{logger}->log(2, "Partyline: $nick requested JOIN $chan" . ($key ? " (key: $key)" : ""));
    $stream->write("Joining $chan" . ($key ? " with key $key" : "") . "...\r\n");
}

# ---------------------------------------------------------------------------
# .part #chan
# ---------------------------------------------------------------------------
sub _cmd_part {
    my ($self, $stream, $id, $chan) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    $bot->partChannel($chan, "Partyline requested part");

    if ($bot->can('stop_channel_nicklist_timer')) {
        $bot->stop_channel_nicklist_timer($chan);
    }

    $bot->sethChannelsNicksOnChan($chan, ());
    $bot->{logger}->log(2, "Partyline: $nick requested PART $chan");
    $stream->write("Parting $chan...\r\n");
}

# ---------------------------------------------------------------------------
# .nick <newnick>  — Master level required (already enforced by login,
#                    but validated explicitly here for clarity)
# ---------------------------------------------------------------------------
sub _cmd_nick {
    my ($self, $stream, $id, $newnick) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    # Validate nick: IRC nicks must not contain spaces or control chars
    unless ($newnick =~ /^[A-Za-z\[\]\\\`_\^\{\|\}][A-Za-z0-9\[\]\\\`_\-\^\{\|\}]{0,14}$/) {
        $stream->write("Invalid nick format.\r\n");
        return;
    }

    $bot->{irc}->change_nick($newnick);
    $bot->{logger}->log(2, "Partyline: $nick changed bot nick to $newnick");
    $stream->write("Nick change requested: $newnick\r\n");
}

# ---------------------------------------------------------------------------
# .raw <IRC command>  — Owner only
# ---------------------------------------------------------------------------
sub _cmd_raw {
    my ($self, $stream, $id, $raw) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .raw requires Owner level.\r\n");
        return;
    }

    $raw =~ s/[\r\n]//g;    # strip embedded CR/LF to prevent IRC command injection
    $bot->{irc}->write($raw . "\x0d\x0a");
    $bot->{logger}->log(2, "Partyline: $nick sent RAW: $raw");
    $stream->write("RAW -> $raw\r\n");
}

# ---------------------------------------------------------------------------
# .rehash
# ---------------------------------------------------------------------------
sub _cmd_rehash {
    my ($self, $stream, $id) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level <= 1) {   # Owner=0, Master=1
        $stream->write("Access denied: .rehash requires Master or Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested rehash");
    $stream->write("Rehashing...\r\n");

    my $result = eval { $bot->rehash_runtime_state() };
    if (!$result) {
        my $err = $@ || 'rehash failed';
        $bot->{logger}->log(1, "Partyline rehash failed for $nick: $err");
        $stream->write("ERR rehash failed\r\n");
        return;
    }

    $stream->write("OK rehash completed\r\n");
}

# ---------------------------------------------------------------------------
# .restart
# ---------------------------------------------------------------------------
sub _cmd_restart {
    my ($self, $stream, $id, $reason) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .restart requires Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested IRC restart");

    # In-process IRC restart: the Partyline stays alive.
    # restart_irc() sends QUIT best-effort, detaches the IRC object from the loop,
    # and on_timer_tick() will trigger reconnect() in the same process on the same loop.
    if ($bot->can('restart_irc')) {
        $stream->write("Restarting IRC connection (Partyline stays up)...\r\n");
        $self->_broadcast("*** IRC restarting — bot will reconnect shortly. ***");
        my $msg = (defined $reason && $reason ne '') ? $reason : "Partyline .restart by $nick";
        $bot->restart_irc(reason => $msg);
    } else {
        $stream->write("ERR: restart_irc() not available.\r\n");
    }
}

# ---------------------------------------------------------------------------
# .die
# ---------------------------------------------------------------------------
sub _cmd_die {
    my ($self, $stream, $id, $msg) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .die requires Owner level.\r\n");
        return;
    }

    $msg //= "Partyline requested termination";

    $bot->{logger}->log(2, "Partyline: $nick requested die ($msg)");
    $stream->write("Terminating bot...\r\n");

    $stream->close_when_empty;
    $self->_close_session($id);

    $bot->{Quit} = 1;
    $bot->{irc}->send_message("QUIT", undef, $msg);
}

1;
