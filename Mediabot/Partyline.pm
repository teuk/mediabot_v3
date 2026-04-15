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
                    $self->_close_session($id);
                },
            );

            $loop->add($stream);
            $stream->write("=== Mediabot Partyline ===\r\nlogin <user> <password>\r\n");
            $self->{bot}->{logger}->log(2, "Partyline: new connection (fd=$id)");
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
    delete $self->{users}{$id};
    delete $self->{streams}{$id};
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
    if    ($line =~ /^\.help$/i)                         { $self->_cmd_help($stream, $id) }
    elsif ($line =~ /^\.stat$/i)                         { $self->_cmd_stat($stream, $id) }
    elsif ($line =~ /^\.say\s+(#\S+)\s+(.+)$/i)          { $self->_cmd_say($stream, $id, $1, $2) }
    elsif ($line =~ /^\.who\s+(#\S+)$/i)                 { $self->_cmd_who($stream, $id, $1) }
    elsif ($line =~ /^\.join\s+(#\S+)(?:\s+(\S+))?$/i)   { $self->_cmd_join($stream, $id, $1, $2) }
    elsif ($line =~ /^\.part\s+(#\S+)$/i)                { $self->_cmd_part($stream, $id, $1) }
    elsif ($line =~ /^\.nick\s+(\S+)$/i)                 { $self->_cmd_nick($stream, $id, $1) }
    elsif ($line =~ /^\.raw\s+(.+)$/i)                   { $self->_cmd_raw($stream, $id, $1) }
    elsif ($line =~ /^\.rehash$/i)                       { $self->_cmd_rehash($stream, $id) }
    elsif ($line =~ /^\.restart$/i)                      { $self->_cmd_restart($stream, $id) }
    elsif ($line =~ /^\.die(?:\s+(.*))?$/i)              { $self->_cmd_die($stream, $id, $1 // "Partyline requested termination") }
    elsif ($line =~ /^\.quit$/i) {
        $stream->write("Goodbye.\r\n");
        $stream->close_when_empty;
        $self->_close_session($id);
    }
    else {
        $stream->write("Unknown command. Type .help for available commands.\r\n");
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

    $bot->{logger}->log(2, "Partyline: '$login' authenticated (level=" . $row->{description} . ", fd=$id)");
    $stream->write("Authenticated as $login (" . $row->{description} . ").\r\nType .help for available commands.\r\n");
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
      . "  .say #chan <msg>    - send a message to a channel\r\n"
      . "  .who #chan          - list nicks present in a channel\r\n"
      . "  .join #chan [key]   - make the bot join a channel\r\n"
      . "  .part #chan         - make the bot part a channel\r\n"
      . "  .nick <newnick>     - change the bot's nick\r\n"
      . "  .raw <IRC command>  - send a raw IRC command (Owner only)\r\n"
      . "  .rehash             - reload configuration and runtime state\r\n"
      . "  .restart            - restart the bot (Owner only)\r\n"
      . "  .die                - terminate the bot (Owner only)\r\n"
      . "  .quit               - close this partyline session\r\n"
    );
}

# ---------------------------------------------------------------------------
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

    $bot->{irc}->send_message("PART", undef, $chan);
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
    my ($self, $stream, $id) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .restart requires Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested restart");
    $stream->write("Restarting bot...\r\n");

    my @restart_args = ('--daemon');

    if (defined $bot->{config_file} && $bot->{config_file} ne '') {
        push @restart_args, "--conf=" . $bot->{config_file};
    }

    if (defined $bot->{requested_server} && $bot->{requested_server} ne '') {
        push @restart_args, "--server=" . $bot->{requested_server};
    }

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            setsid;
            exec "./mb_restart.sh", @restart_args;
            exit 1;
        } else {
            $bot->{Quit} = 1;
            $bot->{irc}->send_message("QUIT", undef, "Partyline requested restart");
        }
    } else {
        $bot->{logger}->log(1, "Partyline restart failed: unable to fork");
        $stream->write("ERR restart failed\r\n");
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

    $bot->{Quit} = 1;
    $bot->{irc}->send_message("QUIT", undef, $msg);
}

1;
