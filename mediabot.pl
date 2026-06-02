#!/usr/bin/perl

# +---------------------------------------------------------------------------+
# !          MEDIABOT V3   (Net::Async::IRC bot)                              !
# +---------------------------------------------------------------------------+

# +---------------------------------------------------------------------------+
# !          MODULES                                                          !
# +---------------------------------------------------------------------------+
BEGIN {push @INC, '.';}
use strict;
use warnings;
use diagnostics;
use POSIX qw/setsid strftime/;
use Getopt::Long;
use File::Basename;
use Mediabot::Mediabot;
use Mediabot::Conf;
use Mediabot::Log;
use Mediabot::Metrics;
use Mediabot::Radio::Icecast;
use Mediabot::DB;
use Mediabot::Channel;
use Mediabot::Partyline;
use Mediabot::ChannelBan;
use Mediabot::DCC qw(parse_ctcp_payload parse_dcc_payload is_ctcp_chat is_dcc_chat
                      is_dcc_active is_dcc_passive ip_int_to_ipv4);
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Mediabot::Scheduler;
use IO::Async::Timer::Countdown;
use Net::Async::IRC;
use utf8;
use Encode qw(encode decode);

use open qw(:std :encoding(UTF-8));
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# +---------------------------------------------------------------------------+
# !          SETTINGS                                                         !
# +---------------------------------------------------------------------------+
my $CONFIG_FILE;
my $MAIN_PROG_VERSION;
my $MAIN_GIT_VERSION;
my $MAIN_PROG_CHECK_CONFIG = 0;
my $MAIN_PID_FILE;
my $MAIN_PROG_DAEMON = 0;

# +---------------------------------------------------------------------------+
# !          GLOBAL VARS                                                      !
# +---------------------------------------------------------------------------+
my $BOTNICK_WASNOT_TRIGGERED = 0;
my $BOTNICK_WAS_TRIGGERED = 1;

# +---------------------------------------------------------------------------+
# !          SUBS DECLARATION                                                 !
# +---------------------------------------------------------------------------+
sub usage;
sub log_message;
sub log_info;
sub log_warn;
sub log_error;
sub catch_hup;
sub catch_term;
sub catch_int;
sub reconnect;
sub getVersion;
sub _build_irc;

# +---------------------------------------------------------------------------+
# !          IRC FUNCTIONS                                                    !
# +---------------------------------------------------------------------------+
sub on_timer_tick;
sub on_login;
sub on_private;
sub on_motd;
sub on_message_INVITE;
sub on_message_KICK;
sub on_message_MODE;
sub on_message_NICK;
sub on_message_NOTICE;
sub on_message_QUIT;
sub on_message_PART;
sub on_message_PRIVMSG;
sub on_message_ctcp_DCC;
sub on_message_TOPIC;
sub on_message_LIST;
sub on_message_RPL_NAMEREPLY;
sub on_message_RPL_ENDOFNAMES;
sub on_message_WHO;
sub on_message_WHOIS;
sub on_message_WHOWAS;
sub on_message_JOIN;
sub on_message_001;
sub on_message_002;
sub on_message_003;
sub on_message_004;
sub on_message_005;
sub on_message_RPL_WHOISUSER;
sub on_message_PING;
sub on_message_PONG;
sub on_message_ERROR;
sub on_message_KILL;
sub on_message_SERVER;
sub on_message_RPL_TOPIC;
sub on_message_RPL_TOPICWHOTIME;
sub on_message_RPL_LIST;
sub on_message_RPL_LISTEND;
sub on_message_RPL_WHOREPLY;
sub on_message_RPL_ENDOFWHO;
sub on_message_RPL_WHOISCHANNELS;
sub on_message_RPL_WHOISSERVER;
sub on_message_RPL_WHOISIDLE;
sub on_message_ERR_NICKNAMEINUSE;
sub on_message_ERR_NOSUCHNICK;
sub on_message_ERR_NEEDMOREPARAMS;
sub on_message_RPL_INVITING;         # 341
sub on_message_RPL_INVITELIST;       # 346
sub on_message_RPL_ENDOFINVITELIST;  # 347

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+
my $sFullParams = join(" ",@ARGV);
my $sServer;

# Set UTF-8 output for STDOUT and STDERR
set_utf8_output();

# Check command line parameters
my $result = GetOptions (
"conf=s" => \$CONFIG_FILE,
"daemon" => \$MAIN_PROG_DAEMON,
"check" => \$MAIN_PROG_CHECK_CONFIG,
"server=s" => \$sServer,
);

unless ($result) {
    usage("Invalid command-line parameters");
}

# Check if config file is defined
unless (defined($CONFIG_FILE)) {
    usage("You must specify a config file");
}

# Create Mediabot instance
my $mediabot = Mediabot->new({
    config_file => $CONFIG_FILE,
    server      => $sServer,   # explicit requested server override, if any
});

# Load configuration before anything else
unless ($mediabot->readConfigFile()) {
    print "[FATAL] Could not load configuration, aborting.\n";
    exit 1;
}

# Now that we have the config, we can initialize the logger
$mediabot->init_log();

# Logger initialization
$mediabot->{logger} = Mediabot::Log->new(
    debug_level => $mediabot->{conf}->get('main.MAIN_PROG_DEBUG'),
    logfile     => $mediabot->{conf}->get('main.MAIN_LOG_FILE'),
);

# Trap signals
init_signals($mediabot->{logger});


# Check config
if ( $MAIN_PROG_CHECK_CONFIG != 0 ) {
    $mediabot->dumpConfig();
    $mediabot->clean_and_exit(0);
}

# Retrieve PID file path and stored PID
my $pidfile = $mediabot->getPidFile();
my $pid     = $mediabot->getPidFromFile();

if (defined $pid && $pid =~ /^\d+$/) {
    
    # kill 0 just tests "does this process exist and can I signal it?"
    if (kill 0, $pid) {
        # process is alive
        $mediabot->{logger}->log(0, "Mediabot is already running with PID $pid.");
        $mediabot->{logger}->log(0, "Either kill process $pid or remove stale PID file: $pidfile");
        $mediabot->clean_and_exit(1);
    }
    else {
        # PID file is stale; remove it so a new instance can start
        if (unlink $pidfile) {
            $mediabot->{logger}->log(1, "Removed stale PID file: $pidfile");
        }
        else {
            $mediabot->{logger}->log(0, "Could not remove stale PID file '$pidfile': $!");
            $mediabot->{logger}->log(0, "Please remove it manually before restarting.");
            $mediabot->clean_and_exit(1);
        }
    }
}


($MAIN_PROG_VERSION,$MAIN_GIT_VERSION) = $mediabot->getVersion();



log_info("mediabot_v3 Copyright (C) 2019-2026 teuk");
log_info("Mediabot v$MAIN_PROG_VERSION starting with config file $CONFIG_FILE");

# Daemon mode actions
if ($MAIN_PROG_DAEMON) {
    $mediabot->{logger}->log(0, "Starting in daemon mode...");
    $mediabot->{logger}->log(1, "Logfile: " . $mediabot->getLogFile());

    umask 0;

    # Redirect STDIN, STDOUT, STDERR to /dev/null
    open STDIN,  '<', '/dev/null' or do {
        $mediabot->{logger}->log(0, "Can't open /dev/null for STDIN: $!");
        $mediabot->clean_and_exit(1);
    };

    open STDOUT, '>', '/dev/null' or do {
        $mediabot->{logger}->log(0, "Can't open /dev/null for STDOUT: $!");
        $mediabot->clean_and_exit(1);
    };

    open STDERR, '>', '/dev/null' or do {
        $mediabot->{logger}->log(0, "Can't open /dev/null for STDERR: $!");
        $mediabot->clean_and_exit(1);
    };

    defined(my $pid = fork) or do {
        $mediabot->{logger}->log(0, "Can't fork process: $!");
        $mediabot->clean_and_exit(1);
    };

    if ($pid) {
        # Parent process exits quietly
        exit(0);
    }

    unless (setsid) {
        $mediabot->{logger}->log(0, "Can't start a new session with setsid: $!");
        $mediabot->clean_and_exit(1);
    }

    # Write the PID file
    if ($mediabot->writePidFile()) {
        $mediabot->{logger}->log(1, "PID file written to " . $mediabot->getPidFile());
    } else {
        $mediabot->{logger}->log(0, "Failed to write PID file, aborting.");
        $mediabot->clean_and_exit(1);
    }

    $mediabot->{logger}->log(1, "Daemon process started successfully.");
}

my $sStartedMode = ( $MAIN_PROG_DAEMON ? "background" : "foreground");
my $MAIN_PROG_DEBUG = $mediabot->getDebugLevel();
$mediabot->{logger}->log(0,"Mediabot v$MAIN_PROG_VERSION started in $sStartedMode with debug level $MAIN_PROG_DEBUG");

# Initialize Database instance
$mediabot->{db} = Mediabot::DB->new($mediabot->{conf}, $mediabot->{logger});
$mediabot->{dbh} = $mediabot->{db}->dbh;  # for compatibility with old code

if ($mediabot->{metrics}) {
    $mediabot->{metrics}->set('mediabot_db_connected', $mediabot->{dbh} ? 1 : 0);
}

# Initialize persistent channel ban helper
$mediabot->{channel_ban} = Mediabot::ChannelBan->new(
    bot    => $mediabot,
    dbh    => $mediabot->{dbh},
    logger => $mediabot->{logger},
);
$mediabot->{logger}->log(4, "ChannelBan helper initialized");

# Check USER table and fail if not present
$mediabot->dbCheckTables();

# Init authentication object
$mediabot->init_auth();

# Log out all user at start
$mediabot->dbLogoutUsers();

# Populate channels from database
$mediabot->populateChannels();

if ($mediabot->{metrics}) {
    $mediabot->{metrics}->set(
        'mediabot_channels_managed',
        scalar(keys %{ $mediabot->{channels} || {} })
    );
}

# Pick IRC Server
$mediabot->pickServer();

# Initialize last_responder_ts
$mediabot->setLastReponderTs(0);

# Initialize hailo
$mediabot->init_hailo();

# Initialize IO::Async loop
my $loop = IO::Async::Loop->new;
$mediabot->setLoop($loop);
$mediabot->setup_channel_nicklist_timers();

# Initialize Metrics
$mediabot->{metrics} = Mediabot::Metrics->new(
    enabled => $mediabot->{conf}->get('metrics.METRICS_ENABLED') || 0,
    bind    => $mediabot->{conf}->get('metrics.METRICS_BIND')    || '127.0.0.1',
    port    => $mediabot->{conf}->get('metrics.METRICS_PORT')    || 9108,
    loop    => $loop,
    logger  => $mediabot->{logger},
);

$mediabot->{metrics}->set_build_info(
    version => $MAIN_PROG_VERSION || 'unknown',
    network => $mediabot->{conf}->get('connection.CONN_SERVER_NETWORK') || 'unknown',
    nick    => $mediabot->{conf}->get('connection.CONN_NICK') || 'unknown',
);

if ($mediabot->{metrics}) {
    $mediabot->{metrics}->set_radio_status_provider(sub {
        my $conf = $mediabot->{conf};

        my $base_url      = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
        my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || $base_url;
        my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio.mp3';
        my $timeout       = $conf->get('radio.RADIO_ICECAST_TIMEOUT');

        $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

        my $radio = Mediabot::Radio::Icecast->new(
            base_url => $base_url,
            timeout  => $timeout,
            logger   => $mediabot->{logger},
        );

        return $radio->get_summary(
            primary_mount => $primary_mount,
            public_base   => $public_base,
        );
    });
}

$mediabot->{metrics}->start_http_server();

if ($mediabot->{metrics}) {
    $mediabot->{metrics}->set('mediabot_db_connected', $mediabot->{dbh} ? 1 : 0);
    $mediabot->{metrics}->set('mediabot_channels_managed', scalar(keys %{ $mediabot->{channels} || {} }));
    $mediabot->{metrics}->set('mediabot_users_known', scalar(keys %{ $mediabot->{users} || {} })) if ref $mediabot->{users} eq 'HASH';
    $mediabot->{metrics}->set('mediabot_timers_current',
        scalar(keys %{ $mediabot->{channel_nicklist_timers} || {} }));
}

# Initialize Partyline
my $partyline = Mediabot::Partyline->new(
    bot  => $mediabot,
    loop => $loop,
    port => $mediabot->{conf}->get("main.PARTYLINE_PORT"),
);
$mediabot->{partyline} = $partyline;
my $partyline_port = $mediabot->{partyline}->get_port;
$mediabot->{logger}->log(4, "Partyline port is: $partyline_port");

# ── Centralised scheduler ────────────────────────────────────────────────────
my $scheduler = Mediabot::Scheduler->new(
    loop   => $loop,
    logger => $mediabot->{logger},
);
$mediabot->{scheduler} = $scheduler;

# Register and keep the main timer handle for setMainTimerTick compatibility
my $timer = IO::Async::Timer::Periodic->new(interval => 5, on_tick => \&on_timer_tick);
$mediabot->setMainTimerTick($timer);
$loop->add($timer);
$timer->start;

$scheduler->add(
    name      => 'channel_cache_refresh',
    interval  => 60,
    cb        => sub { $mediabot->refresh_channel_hashes },
    autostart => 1,
);

$scheduler->add(
    name      => 'channel_log_purge',
    interval  => 86400,
    cb        => sub { $mediabot->purge_channel_log() },
    autostart => 1,
);


$scheduler->add(
    name      => 'health_check',
    interval  => 21600,  # W6: every 6 hours
    cb        => sub {
        my $uptime = time() - ($mediabot->{metrics}->{started} // time());
        my $d = int($uptime/86400); my $h = int(($uptime%86400)/3600);
        my $m = int(($uptime%3600)/60);
        my $uptime_str = "${d}d ${h}h ${m}m";
        my $hist_count = scalar keys %{ $mediabot->{_claude_history} // {} };
        my $cd_count   = scalar keys %{ $mediabot->{_karma_cooldown}  // {} };
        my $db_ok = eval { $mediabot->{db}->ensure_connected; 1 } // 0;
        # FF10: update uptime gauge outside the log string construction.
        eval {
            my $up = time() - ($mediabot->{_start_time} // time());
            $mediabot->{metrics}->set('mediabot_uptime_seconds', $up)
                if $mediabot->{metrics} && $mediabot->{metrics}->can('set');
        };

        $mediabot->{logger}->log(3,
            "[health_check] uptime=$uptime_str db=" . ($db_ok ? 'ok' : 'FAIL')
            . " claude_sessions=$hist_count karma_cooldowns=$cd_count"
        ) if $mediabot->{logger};
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'karma_log_purge',
    interval  => 86400,  # V6: daily purge of KARMA_LOG older than 90 days
    cb        => sub {
        my $dbh = eval { $mediabot->{db}->ensure_connected } // $mediabot->{dbh};
        return unless $dbh;
        eval {
            my $sth = $dbh->prepare(
                'DELETE FROM KARMA_LOG WHERE ts < NOW() - INTERVAL 90 DAY');
            $sth->execute; $sth->finish;
            $mediabot->{logger}->log(3, 'karma_log_purge: old KARMA_LOG entries removed')
                if $mediabot->{logger};
        };  # graceful: table may not exist
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'claude_history_purge',
    interval  => 3600,  # N3: every hour, purge Claude history/persona for offline nicks
    cb        => sub {
        my %online_nicks;
        for my $chan (keys %{ $mediabot->{channels} // {} }) {
            my @nicks = eval { $mediabot->gethChannelsNicksOnChan($chan) } // ();
            $online_nicks{lc($_)} = 1 for @nicks;
        }
        my $purged_h = 0;
        for my $key (keys %{ $mediabot->{_claude_history} // {} }) {
            my ($nick_k) = split /\x00/, $key, 2;
            unless ($online_nicks{lc($nick_k)}) {
                delete $mediabot->{_claude_history}{$key};
                $purged_h++;
            }
        }
        my $purged_p = 0;
        for my $key (keys %{ $mediabot->{_claude_persona} // {} }) {
            my ($nick_k) = split /\x00/, $key, 2;
            unless ($online_nicks{lc($nick_k)}) {
                delete $mediabot->{_claude_persona}{$key};
                $purged_p++;
            }
        }
        # IMP12: also purge _ai_last_active and stale URL display cache
        for my $key (keys %{ $mediabot->{_ai_last_active} // {} }) {
            my ($nick_k) = split /\x00/, $key, 2;
            delete $mediabot->{_ai_last_active}{$key}
                unless $online_nicks{lc($nick_k)};
        }
        { my $c = $mediabot->{_url_display_cache} // {};
          my $ct = time();
          delete @{$c}{grep { ($c->{$_}//0) < $ct - 600 } keys %$c}; }
        $mediabot->{logger}->log(3, "claude_history_purge: $purged_h history, $purged_p persona orphan(s) removed")
            if $purged_h + $purged_p > 0;
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'weekly_channel_report',
    interval  => 604800,  # U7: every 7 days
    cb        => sub {
        for my $chan (sort keys %{ $mediabot->{channels} // {} }) {
            my $dbh = eval { $mediabot->{db}->ensure_connected } // $mediabot->{dbh};
            next unless $dbh;
            my (@top_msg, @top_karma);
            eval {
                my $sth = $dbh->prepare(q{
                    SELECT nick, COUNT(*) AS cnt FROM CHANNEL_LOG
                    JOIN CHANNEL c USING (id_channel)
                    WHERE c.name = ? AND ts >= NOW() - INTERVAL 7 DAY
                    GROUP BY nick ORDER BY cnt DESC LIMIT 3
                });
                if ($sth && $sth->execute($chan)) {
                    while (my $r = $sth->fetchrow_hashref) { push @top_msg, "$r->{nick}($r->{cnt})" }
                    $sth->finish;
                }
                my $sth2 = $dbh->prepare(q{
                    SELECT k.nick, k.score FROM KARMA k
                    JOIN CHANNEL c ON c.id_channel = k.id_channel
                    WHERE c.name = ? ORDER BY k.score DESC LIMIT 3
                });
                if ($sth2 && $sth2->execute($chan)) {
                    while (my $r = $sth2->fetchrow_hashref) {
                        my $sign = $r->{score} > 0 ? '+' : ''; push @top_karma, "$r->{nick}(${sign}$r->{score})"
                    }
                    $sth2->finish;
                }
            };
            next unless @top_msg || @top_karma;
            my $msg_str   = @top_msg   ? join(' | ', @top_msg)   : 'N/A';
            my $karma_str = @top_karma ? join(' | ', @top_karma) : 'N/A';
            Mediabot::Helpers::botPrivmsg($mediabot, $chan,
                "\x{2728} Weekly report — Top speakers (7d): $msg_str");
            Mediabot::Helpers::botPrivmsg($mediabot, $chan,
                "\x{2728} Weekly report — Top karma: $karma_str");
        }
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'daily_channel_report',
    interval  => 86400,   # I5: once per day — top 3 msgs + karma per channel
    cb        => sub {
        my $dbh = eval { $mediabot->{db}->ensure_connected } // $mediabot->{dbh};
        return unless $dbh;

        for my $chan (sort keys %{ $mediabot->{channels} // {} }) {
            # Top 3 speakers (last 24h)
            my $sth_msgs = $dbh->prepare(q{
                SELECT cl.nick, COUNT(*) AS cnt
                FROM CHANNEL_LOG cl
                JOIN CHANNEL c ON c.id_channel = cl.id_channel
                WHERE c.name = ?
                  AND cl.ts >= DATE_SUB(NOW(), INTERVAL 1 DAY)
                GROUP BY cl.nick ORDER BY cnt DESC LIMIT 3
            });
            my @top_msgs;
            if ($sth_msgs && $sth_msgs->execute($chan)) {
                my $rank = 1;
                while (my $r = $sth_msgs->fetchrow_hashref) {
                    push @top_msgs, "$rank. $r->{nick} ($r->{cnt})";
                    $rank++;
                }
                $sth_msgs->finish;
            }

            # Top 3 karma
            my $sth_chan = $dbh->prepare('SELECT id_channel FROM CHANNEL WHERE name = ?');
            my $id_chan;
            if ($sth_chan && $sth_chan->execute($chan)) {
                my $r = $sth_chan->fetchrow_hashref; $sth_chan->finish;
                $id_chan = $r->{id_channel} if $r;
            }
            my @top_karma;
            if ($id_chan) {
                my $sth_k = $dbh->prepare(q{
                    SELECT nick, score FROM KARMA
                    WHERE id_channel = ? AND score != 0
                    ORDER BY ABS(score) DESC LIMIT 3  -- DR1/fix: include negative scores
                });
                if ($sth_k && $sth_k->execute($id_chan)) {
                    while (my $r = $sth_k->fetchrow_hashref) {
                        my $sign = $r->{score} > 0 ? '+' : '';
                        push @top_karma, "$r->{nick} (${sign}$r->{score})";
                    }
                    $sth_k->finish;
                }
            }

            next unless @top_msgs || @top_karma;

            my $msg_str   = @top_msgs  ? join(' | ', @top_msgs)  : '(no activity)';
            my $karma_str = @top_karma ? join(' | ', @top_karma) : '(no karma)';
            Mediabot::Helpers::botPrivmsg($mediabot, $chan,
                "📊 Daily report — Top speakers: $msg_str  ·  Top karma: $karma_str");
            $mediabot->{logger}->log(2, "daily_channel_report sent to $chan");
        }
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'birthday_check',
    interval  => 86400,   # once per day
    cb        => sub { $mediabot->check_birthdays_today() },
    autostart => 1,
);

$scheduler->add(
    name      => 'reminder_purge',
    interval  => 86400,   # S6: once per day — delete delivered/cancelled reminders older than 7 days
    cb        => sub {
        my $dbh = eval { $mediabot->{db}->ensure_connected } // $mediabot->{dbh};
        return unless $dbh;
        my $sth = $dbh->prepare(q{
            DELETE FROM REMINDERS
            WHERE delivered > 0
              AND created_at < DATE_SUB(NOW(), INTERVAL 7 DAY)
        });
        if ($sth && $sth->execute()) {
            my $n = $sth->rows; $sth->finish;
            $mediabot->{logger}->log(2, "reminder_purge: deleted $n reminder(s) older than 7 days");
        }
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'auth_session_cleanup',
    interval  => 3600,   # hourly — purge sessions older than 24h
    cb        => sub {
        if ($mediabot->{auth} && $mediabot->{auth}->can('cleanup_stale_sessions')) {
            $mediabot->{auth}->cleanup_stale_sessions();
        }
    },
    autostart => 1,
);

$scheduler->add(
    name      => 'user_seen_purge',
    interval  => 86400,
    cb        => sub { $mediabot->purge_user_seen() },
    autostart => 1,
);

$scheduler->add(
    name      => 'channel_ban_expire',
    interval  => 60,
    cb        => sub {
        my $removed = eval { $mediabot->process_expired_channel_bans };
        if ($@) {
            (my $err = $@) =~ s/\s+/ /g;
            $mediabot->{logger}->log(1, "channelban: expiration timer failed: $err");
            return;
        }
        if ($removed && $removed > 0) {
            $mediabot->{logger}->log(2, "channelban: expiration timer removed $removed ban(s)");
        }
    },
    autostart => 1,
);

# Build IRC object and connect (initial connection)
my ($irc, $bind_ip) = _build_irc($loop);
$mediabot->setIrc($irc);

my $sConnectionNick = $mediabot->getConnectionNick();
my $sServerPass = $mediabot->getServerPass();
my $sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : "configured (hidden)" );
my $bNickTriggerCommand = $mediabot->getNickTrigger();
$mediabot->{logger}->log(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

my $login = _do_login($irc, $bind_ip);
eval { $login->get }; if ($@) { my $err = $@; $err =~ s/\n/ /g; $mediabot->{logger}->log(0, "Login Future failed: $err"); $mediabot->clean_and_exit(1); }

# Start main loop
$mediabot->{_start_time} = time();  # FF10: bot start time
$loop->run;

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+

# +---------------------------------------------------------------------------+
# ! _build_irc($loop)                                                        !
# ! Creates and registers a fresh Net::Async::IRC object into $loop.         !
# ! Returns ($irc, $bind_ip).                                                !
# +---------------------------------------------------------------------------+
sub _build_irc {
    my ($loop) = @_;

    my $bind_ip = $mediabot->{conf}->get('connection.CONN_BIND_IP');

    my $irc = Net::Async::IRC->new(
        on_message_text                  => \&on_private,
        on_message_motd                  => \&on_motd,
        on_message_INVITE                => \&on_message_INVITE,
        on_message_KICK                  => \&on_message_KICK,
        on_message_MODE                  => \&on_message_MODE,
        on_message_NICK                  => \&on_message_NICK,
        on_message_NOTICE                => \&on_message_NOTICE,
        on_message_QUIT                  => \&on_message_QUIT,
        on_message_PART                  => \&on_message_PART,
        on_message_PRIVMSG               => \&on_message_PRIVMSG,
        on_message_ctcp_DCC              => \&on_message_ctcp_DCC,
        on_message_TOPIC                 => \&on_message_TOPIC,
        on_message_LIST                  => \&on_message_LIST,
        on_message_RPL_NAMEREPLY         => \&on_message_RPL_NAMEREPLY,
        on_message_RPL_ENDOFNAMES        => \&on_message_RPL_ENDOFNAMES,
        on_message_WHO                   => \&on_message_WHO,
        on_message_WHOIS                 => \&on_message_WHOIS,
        on_message_WHOWAS                => \&on_message_WHOWAS,
        on_message_JOIN                  => \&on_message_JOIN,
        on_message_001                   => \&on_message_001,
        on_message_002                   => \&on_message_002,
        on_message_003                   => \&on_message_003,
        on_message_004                   => \&on_message_004,
        on_message_005                   => \&on_message_005,
        on_message_RPL_WHOISUSER         => \&on_message_RPL_WHOISUSER,
        on_message_ERROR                 => \&on_message_ERROR,
        on_message_KILL                  => \&on_message_KILL,
        on_message_SERVER                => \&on_message_SERVER,
        on_message_RPL_TOPIC             => \&on_message_RPL_TOPIC,
        on_message_RPL_TOPICWHOTIME      => \&on_message_RPL_TOPICWHOTIME,
        on_message_RPL_LIST              => \&on_message_RPL_LIST,
        on_message_RPL_LISTEND           => \&on_message_RPL_LISTEND,
        on_message_RPL_WHOREPLY          => \&on_message_RPL_WHOREPLY,
        on_message_RPL_ENDOFWHO          => \&on_message_RPL_ENDOFWHO,
        on_message_RPL_WHOISCHANNELS     => \&on_message_RPL_WHOISCHANNELS,
        on_message_RPL_WHOISSERVER       => \&on_message_RPL_WHOISSERVER,
        on_message_RPL_WHOISIDLE         => \&on_message_RPL_WHOISIDLE,
        on_message_RPL_ENDOFWHOIS        => \&on_message_RPL_ENDOFWHOIS,
        on_message_ERR_NICKNAMEINUSE     => \&on_message_ERR_NICKNAMEINUSE,
        on_message_ERR_NOSUCHNICK        => \&on_message_ERR_NOSUCHNICK,
        on_message_RPL_INVITING          => \&on_message_RPL_INVITING,
        on_message_RPL_INVITELIST        => \&on_message_RPL_INVITELIST,
        on_message_RPL_ENDOFINVITELIST   => \&on_message_RPL_ENDOFINVITELIST,
        on_message_ERR_NEEDMOREPARAMS    => \&on_message_ERR_NEEDMOREPARAMS,
    );

    $loop->add($irc);

    return ($irc, $bind_ip);
}

# +---------------------------------------------------------------------------+
# ! _do_login($irc, $bind_ip)                                                !
# ! Issues irc->login() with current server settings.                       !
# ! Returns the login Future.                                                !
# +---------------------------------------------------------------------------+
sub _do_login {
    my ($irc, $bind_ip) = @_;

    my $sConnectionNick = $mediabot->getConnectionNick();
    my $sServerPass     = $mediabot->getServerPass();

    return $irc->login(
        pass     => $sServerPass,
        nick     => $sConnectionNick,
        host     => $mediabot->getServerHostname(),
        service  => $mediabot->getServerPort(),
        user     => $mediabot->getUserName(),
        realname => $mediabot->getIrcName(),

        # Bind IP (optional - set CONN_BIND_IP in [connection] section)
        ( $bind_ip ? (
            local_host => $bind_ip,
            connect    => { local_host => $bind_ip },
            ( $bind_ip =~ /:/ ? ( family => 'inet6' ) : () ),
        ) : () ),

        on_login => \&on_login,
    );
}

# Display usage information
sub usage {
    my ($strErr) = @_;
    if (defined($strErr)) {
        log_error("Error : " . $strErr);
    }
    log_error("Usage: " . basename($0) . " --conf=<config_file> [--check] [--daemon] [--server=<hostname>]");
    exit 4;
}

# Initialize signals
sub init_signals {
    my ($logger) = @_;
    $logger->log(4, "Registering signal handler for TERM");
    $SIG{TERM} = \&catch_term;

    $logger->log(4, "Registering signal handler for INT");
    $SIG{INT}  = \&catch_int;

    $logger->log(4, "Registering signal handler for HUP");
    $SIG{HUP}  = \&catch_hup;
}


# Set UTF-8 output for STDOUT and STDERR
sub set_utf8_output {
    binmode STDOUT, ':utf8';
    binmode STDERR, ':utf8';
}

# Get timestamp for logging
sub log_timestamp {
    return strftime("[%d/%m/%Y %H:%M:%S]", localtime);
}

# Log a message with a specific level
sub log_message {
    my ($level, $msg) = @_;
    $level //= 0;
    
    if ($mediabot) {
        $mediabot->{logger}->log($level,$msg);
    } else {
        my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
        print "$ts $msg\n" if $level <= 0;
    }
}

sub log_debug_args {
    my ($context, $message) = @_;
    return unless defined $message && ref($message) && $mediabot;
    my @args = eval { @{ $message->args // [] } };
    my $args_str = join(', ', map { defined $_ ? "'$_'" : 'undef' } @args);
    $mediabot->{logger}->log(5, "$context args: [$args_str]");
}

sub log_info {
    my ($msg) = @_;
    print STDOUT log_timestamp() . " [INFO] $msg\n";
}

sub log_warn {
    my ($msg) = @_;
    print STDERR log_timestamp() . " [WARN] $msg\n";
}

sub log_error {
    my ($msg) = @_;
    print STDERR log_timestamp() . " [ERROR] $msg\n";
}

sub on_timer_tick {
    my @params = @_;

    $mediabot->{logger}->log(5, "on_timer_tick() params: " . scalar(@params) . " args");
    $mediabot->{logger}->log(5,"on_timer_tick() tick");
    
    # Update pid file
    my $sPidFilename = $mediabot->{conf}->get('main.MAIN_PID_FILE');
    if (open my $pid_fh, '>', $sPidFilename) {
        print $pid_fh "$$";
        close $pid_fh;
    } else {
        log_error("Could not open $sPidFilename for writing: $!");
    }
    
    # Sync $irc with $mediabot->{irc} in case restart_irc() cleared it
    $irc = undef if defined $irc && !defined $mediabot->{irc};
    $irc //= $mediabot->{irc};

    # A4: sync $mediabot->{dbh} if DB.pm reconnected since last tick
    if ($mediabot->{db}) {
        my $live_dbh = eval { $mediabot->{db}->ensure_connected() };
        if ($live_dbh && (!$mediabot->{dbh} || $live_dbh != $mediabot->{dbh})) {
            $mediabot->{dbh} = $live_dbh;
            $mediabot->{logger}->log(2, "on_timer_tick: dbh refreshed after DB reconnect");
        }
    }

    # Check connection status and reconnect if not connected
    # Grace period of 15s after login to let Net::Async::IRC finish CAP negotiation
    my $grace = (time - ($mediabot->getConnectionTimestamp() // 0)) < 15;
    my $irc_connected = (defined($irc) && $irc->is_connected) ? 1 : 0;
    my $reconnect_needed = !$mediabot->{irc_reconnect_in_progress} && ($mediabot->{irc_reconnect_requested} || (!$grace && !$irc_connected));

    $mediabot->{logger}->log(0,
        "on_timer_tick(): reconnect state "
        . "grace=$grace "
        . "irc_connected=$irc_connected "
        . "quit=" . ($mediabot->getQuit() // 'undef') . " "
        . "restart_in_progress=" . ($mediabot->{irc_restart_in_progress} // 'undef') . " "
        . "reconnect_requested=" . ($mediabot->{irc_reconnect_requested} // 'undef') . " "
        . "reconnect_in_progress=" . ($mediabot->{irc_reconnect_in_progress} // 'undef') . " "
        . "timer_present=" . ($mediabot->{irc_reconnect_timer} ? 1 : 0)
    ) if $mediabot->{irc_reconnect_requested};

    if ($reconnect_needed) {
        if ($mediabot->getQuit() && !$mediabot->{irc_reconnect_requested}) {
            $mediabot->{logger}->log(0,"Disconnected from server");
            $mediabot->clean_and_exit(0);
        }
        else {
            my $delay = int($mediabot->{conf}->get('main.RECONNECT_DELAY') // 30);
            $delay = 30 if $delay < 5 || $delay > 600;

            if (!$mediabot->{irc_reconnect_timer}) {
                $mediabot->setServer(undef);

                my $why = $mediabot->{irc_reconnect_requested}
                    ? "IRC restart requested"
                    : "Lost connection to server";

                $mediabot->{logger}->log(0, "$why. Scheduling reconnect in $delay seconds");

                if ($mediabot->{metrics}) {
                    $mediabot->{metrics}->set('mediabot_irc_connected', 0);
                    $mediabot->{metrics}->inc('mediabot_irc_reconnect_total');
                }

                my $reconnect_timer = IO::Async::Timer::Countdown->new(
                    delay => $delay,
                    on_expire => sub {
                        $mediabot->{logger}->log(0, "reconnect countdown expired");
                        $mediabot->{irc_reconnect_timer} = undef;
                        reconnect();
                    },
                );

                $mediabot->{irc_reconnect_timer} = $reconnect_timer;
                $loop->add($reconnect_timer);
                $reconnect_timer->start;
            }
        }
    }
}

# Check channels with chanset +RandomQuote
if (defined($mediabot->{conf}->get('main.RANDOM_QUOTE'))) {
    my $randomQuoteDelay = defined($mediabot->{conf}->get('main.RANDOM_QUOTE')) ? $mediabot->{conf}->get('main.RANDOM_QUOTE') : 10800;
    unless ($randomQuoteDelay >= 900) {
        $mediabot->{logger}->log(0,"Mediabot was not designed to spam channels, please set RANDOM_QUOTE to a value greater or equal than 900 seconds in [main] section of $CONFIG_FILE");
    }
    elsif ((time - $mediabot->getLastRandomQuote()) > $randomQuoteDelay ) {
        my $sQuery = "SELECT CHANNEL.name FROM CHANNEL JOIN CHANNEL_SET ON CHANNEL_SET.id_channel=CHANNEL.id_channel JOIN CHANSET_LIST ON CHANSET_LIST.id_chanset_list=CHANNEL_SET.id_chanset_list WHERE CHANSET_LIST.chanset = 'RandomQuote'";
        my $sth = $mediabot->{db}->ensure_connected()->prepare($sQuery);
        unless ($sth && $sth->execute()) {
            $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        }
        else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $curChannel = $ref->{'name'};
                $mediabot->{logger}->log(4,"RandomQuote on $curChannel");

                my $count_query = "
                    SELECT COUNT(*) AS quote_count
                    FROM QUOTES q
                    JOIN CHANNEL c ON c.id_channel = q.id_channel
                    WHERE c.name = ?
                ";
                my $sth_count = $mediabot->{db}->ensure_connected()->prepare($count_query);

                unless ($sth_count && $sth_count->execute($curChannel)) {
                    $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $count_query);
                    next;
                }

                my $count_ref = $sth_count->fetchrow_hashref();
                $sth_count->finish;

                my $quote_count = int($count_ref->{quote_count} // 0);
                next unless $quote_count > 0;

                my $offset = int(rand($quote_count));

                my $sQuery = "
                    SELECT q.id_quotes, q.quotetext, u.nickname
                    FROM QUOTES q
                    JOIN CHANNEL c ON c.id_channel = q.id_channel
                    JOIN USER u ON u.id_user = q.id_user
                    WHERE c.name = ?
                    ORDER BY q.id_quotes
                    LIMIT 1 OFFSET ?
                ";
                my $sth2 = $mediabot->{db}->ensure_connected()->prepare($sQuery);

                unless ($sth2 && $sth2->execute($curChannel, $offset)) {
                    $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                }
                else {
                    if (my $ref = $sth2->fetchrow_hashref()) {
                        my $sQuoteId = $ref->{'id_quotes'};
                        my $sQuote   = $ref->{'quotetext'};
                        my $id_q = String::IRC->new($sQuoteId)->bold;
                        $mediabot->botPrivmsg($curChannel,"[id: $id_q] $sQuote");
                    }
                }
                $sth2->finish if $sth2;
            }
        }
        $sth->finish;
        $mediabot->setLastRandomQuote(time);
    }
}

sub on_message_NOTICE {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_NOTICE', $message);
    my ($who, $what) = @{$hints}{qw<prefix_name text>};
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
    my @tArgs = $message->args;
    if (defined($who) && ($who ne "")) {
        if (defined($tArgs[0]) && (substr($tArgs[0],0,1) eq '#')) {
            $mediabot->{logger}->log(0,"-$who:" . $tArgs[0] . "- $what");
            $mediabot->logBotAction($message,"notice",$sNick,$tArgs[0],$what);
        }
        else {
            $mediabot->{logger}->log(0,"-$who- $what");
        }
        if (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1 ) && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN') ne "") && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME') ne "") && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_PASSWORD')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_PASSWORD') ne "")) {
            # Undernet CService login
            my $sSuccesfullLoginFrText = "AUTHENTIFICATION R.USSIE pour " . $mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME');
            my $sSuccesfullLoginEnText = "AUTHENTICATION SUCCESSFUL as " . $mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME');
            if (($who eq "X") && (($what =~ /USSIE/) || ($what eq $sSuccesfullLoginEnText)) && defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1) && ($mediabot->{conf}->get('connection.CONN_USERMODE') =~ /x/)) {
                $self->write("MODE " . $self->nick_folded . " +x\x0d\x0a");
                $self->change_nick( $mediabot->{conf}->get('connection.CONN_NICK') );
                $mediabot->joinChannels();
                $mediabot->{logger}->log(0, "on_login(): joinChannels() called");
            }
        }
        elsif (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2 ) && defined($mediabot->{conf}->get('libera.LIBERA_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('libera.LIBERA_NICKSERV_PASSWORD') ne "")) {
            if (($who eq "NickServ") && (($what =~ /This nickname is registered/) && defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2))) {
                $mediabot->botPrivmsg("NickServ","identify " . $mediabot->{conf}->get('libera.LIBERA_NICKSERV_PASSWORD'));
                $mediabot->joinChannels();
                $mediabot->{logger}->log(0, "on_login(): joinChannels() called");
            }
        }
    }
    else {
        $mediabot->{logger}->log(0,"$what");
    }
}

sub on_login {
    my ( $self, $message, $hints ) = @_;

    $mediabot->{logger}->log(0,"on_login() Connected to irc server " . $mediabot->getServerHostname());
    if ($mediabot->{metrics}) {
        $mediabot->{metrics}->inc('mediabot_irc_login_total');
        $mediabot->{metrics}->set('mediabot_irc_connected', 1);
    }
    $mediabot->setQuit(0);
    $mediabot->setConnectionTimestamp(time);
    $mediabot->setLastRandomQuote(time);
    $mediabot->onStartTimers();
    
    # Undernet: authentication to channel service if credentials are defined
    if (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1 ) && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN') ne "") && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME') ne "") && defined($mediabot->{conf}->get('undernet.UNET_CSERVICE_PASSWORD')) && ($mediabot->{conf}->get('undernet.UNET_CSERVICE_PASSWORD') ne "")) {
        $mediabot->{logger}->log(0,"on_login() Logging to " . $mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN'));
        $mediabot->botPrivmsg($mediabot->{conf}->get('undernet.UNET_CSERVICE_LOGIN'),"login " . $mediabot->{conf}->get('undernet.UNET_CSERVICE_USERNAME') . " "  . $mediabot->{conf}->get('undernet.UNET_CSERVICE_PASSWORD'));
    }

    # Set user modes
    if (defined($mediabot->{conf}->get('connection.CONN_USERMODE'))) {
        if ( substr($mediabot->{conf}->get('connection.CONN_USERMODE'),0,1) eq '+') {
            my $sUserMode = $mediabot->{conf}->get('connection.CONN_USERMODE');
            if (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1 )) {
                $sUserMode =~ s/x//;
            }
            $mediabot->{logger}->log(0,"on_login() Setting user mode $sUserMode");
            $self->write("MODE " . $mediabot->{conf}->get('connection.CONN_NICK') . " +" . $sUserMode . "\x0d\x0a");
        }
    }

    # First join the console channel from the populated channels
    my $console_channel;
    foreach my $chan (values %{ $mediabot->{channels} }) {
        my $desc = eval { $chan->get_description } // '';
        if ($desc eq 'console') {
            $console_channel = $chan;
            last;
        }
    }

    if (defined $console_channel) {
        my $name = $console_channel->get_name;
        my $key  = $console_channel->get_key;
        $mediabot->{logger}->log(1, "Joining console channel $name");
        $mediabot->joinChannel($name, $key);
    } else {
        $mediabot->{logger}->log(1, "Warning: no console channel found in database (description = 'console'). You may want to run configure script again.");
    }

    # Join other channels
    unless ((($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1) && ($mediabot->{conf}->get('connection.CONN_USERMODE') =~ /x/)) || (($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2) && defined($mediabot->{conf}->get('libera.LIBERA_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('libera.LIBERA_NICKSERV_PASSWORD') ne ""))) {
        # NS3: throttled JOIN flood prevention — stagger joins every 1.5s
        # Prevents server-side flood kick on large channel lists after a split.
        my @chans_to_join = sort grep {
            my $c = $mediabot->{channels}{$_};
            $c && $c->get_auto_join
            && (($c->get_description // '') ne 'console')
        } keys %{ $mediabot->{channels} // {} };
        my $join_delay = 0;
        for my $chan_name (@chans_to_join) {
            my $c = $mediabot->{channels}{$chan_name};
            my $key = $c->get_key // '';
            $join_delay += 1500;  # 1.5s between each JOIN
            my $jt = IO::Async::Timer::Countdown->new(
                delay => $join_delay / 1000,
                on_expire => sub {
                    $mediabot->{logger}->log(1, "NS3: joining $chan_name (throttled)");
                    eval { $mediabot->joinChannel($chan_name, $key) };
                    # NS4: schedule WHO after join to sync nicklist
                    my $who_t = IO::Async::Timer::Countdown->new(
                        delay     => 3,
                        on_expire => sub {
                            eval { $irc->send_message('WHO', undef, $chan_name) }
                                if $irc && $irc->is_connected;
                            $mediabot->{logger}->log(2, "NS4: WHO sent for $chan_name after join");
                        },
                    );
                    $loop->add($who_t);
                    $who_t->start;
                },
            );
            $loop->add($jt);
            $jt->start;
        }
        $mediabot->{logger}->log(1, 'NS3: scheduled ' . scalar(@chans_to_join) . ' throttled joins (' . ($join_delay/1000) . 's total)');
    }
}

sub on_private {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_private', $message);
    my ($who, $what) = @{$hints}{qw<prefix_name text>};
    $mediabot->{logger}->log(2,"on_private() -$who- $what");
}

sub on_message_INVITE {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_INVITE', $message);
    my ($inviter_nick,$invited_nick,$target_name) = @{$hints}{qw<inviter_nick invited_nick target_name>};
    unless ($self->is_nick_me($inviter_nick)) {
        $mediabot->{logger}->log(1,"* $inviter_nick invites you to join $target_name");
        $mediabot->logBotAction($message,"invite",$inviter_nick,undef,$target_name);
        my $inviter_user = $mediabot->get_user_from_message($message);
        my $is_auth      = $inviter_user && $inviter_user->is_authenticated ? 1 : 0;
        my $auth_label   = $is_auth ? 'authenticated' : 'not authenticated';
        $mediabot->{logger}->log(1,"$invited_nick has been invited to join $target_name by $inviter_nick ($auth_label)");
        # Auto-join disabled - uncomment to re-enable:
        # $mediabot->joinChannel($target_name) if $is_auth;
    }
    else {
        $mediabot->{logger}->log(1,"$invited_nick has been invited to join $target_name");
    }
}
    
sub on_message_KICK {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_KICK', $message);
    my ($kicker_nick,$target_name,$kicked_nick,$text) = @{$hints}{qw<kicker_nick target_name kicked_nick text>};
    if ($self->is_nick_me($kicked_nick)) {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] * you were kicked from $target_name by $kicker_nick ($text)");
        }
        $mediabot->joinChannel($target_name);
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] $target_name: $kicked_nick was kicked by $kicker_nick ($text)");
        }
        $mediabot->channelNicksRemove($target_name,$kicked_nick);
        # Clear in-memory auth session for the kicked nick
        eval { $mediabot->{auth}->logout($kicked_nick) } if $mediabot->{auth};
    }
    $mediabot->logBotAction($message,"kick",$kicker_nick,$target_name,"$kicked_nick ($text)");
}

sub on_message_MODE {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_MODE', $message);
    my ($target_name,$modechars,$modeargs) = @{$hints}{qw<target_name modechars modeargs>};
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
    my @tArgs = $message->args;
    if ( substr($target_name,0,1) eq '#' ) {
        shift @tArgs;
        my $sModes = $tArgs[0];
        shift @tArgs;
        my $sTargetNicks = join(" ",@tArgs);
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] <$target_name> $sNick sets mode $sModes $sTargetNicks");
        }
        $mediabot->logBotAction($message,"mode",$sNick,$target_name,"$sModes $sTargetNicks");
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] $target_name sets mode " . $tArgs[1]);
        }
    }
}

sub on_message_NICK {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_NICK', $message);
    my %hChannelsNicks = ();
    if (defined($mediabot->gethChannelNicks())) {
        %hChannelsNicks = %{$mediabot->gethChannelNicks()};
    }
    my ($old_nick,$new_nick) = @{$hints}{qw<old_nick new_nick>};
    if ($self->is_nick_me($old_nick)) {
        $mediabot->{logger}->log(1,"* Your nick is now $new_nick");
        $self->_set_nick($new_nick);
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] * $old_nick is now known as $new_nick");
        }
    }
    # Track last seen on NICK change + purge Claude history for old nick
    {
        my ($sNick_n, $sIdent_n, $sHost_n) = $mediabot->getMessageNickIdentHost($message);
        # Q2: purge Claude history for old nick on NICK change
        if (defined $sNick_n && $mediabot->{_claude_history}) {
            my $prefix = lc($sNick_n) . "\x00";
            delete $mediabot->{_claude_history}{$_}
                for grep { index($_, $prefix) == 0 } keys %{ $mediabot->{_claude_history} };
        }
        eval { $mediabot->updateUserSeen(
            nick       => $old_nick,
            channel    => '',
            userhost   => "$sIdent_n\@$sHost_n",
            event_type => 'nick',
            new_nick   => $new_nick,
        ) } if $old_nick;
    }

    # Change nick in %hChannelsNicks
    for my $sChannel (keys %hChannelsNicks) {
        my $index;
        for ($index=0;$index<=$#{$hChannelsNicks{$sChannel}};$index++ ) {
            my $currentNick = ${$hChannelsNicks{$sChannel}}[$index];
            if ( $currentNick eq $old_nick) {
                ${$hChannelsNicks{$sChannel}}[$index] = $new_nick;
                last;
            }
        }
    }
    $mediabot->sethChannelNicks(\%hChannelsNicks);
    $mediabot->logBotAction($message,"nick",$old_nick,undef,$new_nick);
}

sub on_message_QUIT {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_QUIT', $message);
    my %hChannelsNicks = ();
    if (defined($mediabot->gethChannelNicks())) {
        %hChannelsNicks = %{$mediabot->gethChannelNicks()};
    }
    my ($text) = @{$hints}{qw<text>};
    unless(defined($text)) { $text="";}
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);

    # NS1: detect netsplit QUIT — message matches "server1.net server2.net"
    # During a netsplit, dozens of QUITs arrive with this pattern.
    # Skip expensive DB operations (logBotAction, updateUserSeen) for these.
    my $is_netsplit = ($text =~ /^\S+\.\S+\s+\S+\.\S+$/);
    if ($is_netsplit) {
        $mediabot->{logger}->log(2, "NS1: netsplit QUIT suppressed for $sNick (msg: $text)");
        # NS5: do NOT purge Claude history on netsplit QUITs — user will rejoin
        # Only remove from in-memory nicklist (fast, no DB)
        for my $sChannel (keys %hChannelsNicks) {
            $mediabot->channelNicksRemove($sChannel, $sNick);
        }
        # Track netsplit counter
        $mediabot->{_netsplit_quit_count} = ($mediabot->{_netsplit_quit_count} // 0) + 1;
        $mediabot->{metrics}->inc('mediabot_netsplit_quits_total')
            if $mediabot->{metrics};
        return;
    }

    # NS5: only purge Claude history for genuine QUITs (not netsplits)
    # Q2: purge Claude conversation history on QUIT
    if (defined $sNick && $mediabot->{_claude_history}) {
        my $prefix = lc($sNick) . "\x00";
        delete $mediabot->{_claude_history}{$_}
            for grep { index($_, $prefix) == 0 } keys %{ $mediabot->{_claude_history} };
    }
    if (defined($text) && ($text ne "")) {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] * Quits: $sNick ($sIdent\@$sHost) ($text)");
        }
        $mediabot->logBotAction($message,"quit",$sNick,undef,$text);
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] * Quits: $sNick ($sIdent\@$sHost) ()");
        }
        $mediabot->logBotAction($message,"quit",$sNick,undef,"");
    }
    # Track last seen on genuine QUIT
    eval { $mediabot->updateUserSeen(
        nick       => $sNick,
        channel    => '',
        userhost   => "$sIdent\@$sHost",
        event_type => 'quit',
        last_msg   => $text,
    ) };

    for my $sChannel (keys %hChannelsNicks) {
        $mediabot->channelNicksRemove($sChannel,$sNick);
    }
    # Clear in-memory auth session on genuine QUIT
    eval { $mediabot->{auth}->logout($sNick) } if $mediabot->{auth};
}

sub on_message_PART {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_PART', $message);
    my ($target_name, $text) = @{$hints}{qw<target_name text>};
    unless (defined($text)) { $text = ""; }

    my ($sNick, $sIdent, $sHost) = $mediabot->getMessageNickIdentHost($message);
    my @tArgs = $message->args;
    shift @tArgs;

    if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0, "[LIVE] <$target_name> * Parts: $sNick ($sIdent\@$sHost) (" . $tArgs[0] . ")");
        }
        $mediabot->logBotAction($message, "part", $sNick, $target_name, $tArgs[0]);
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0, "[LIVE] <$target_name> * Parts: $sNick ($sIdent\@$sHost)");
        }
        $mediabot->logBotAction($message, "part", $sNick, $target_name, "");
    }

    $mediabot->channelNicksRemove($target_name, $sNick);

    # Track last seen on PART
    eval { $mediabot->updateUserSeen(
        nick       => $sNick,
        channel    => $target_name,
        userhost   => "$sIdent\@$sHost",
        event_type => 'part',
        last_msg   => '',
    ) };

    # Clear in-memory auth session on PART (only for other nicks, not the bot itself)
    eval { $mediabot->{auth}->logout($sNick) } if $mediabot->{auth} && $sNick ne $self->nick;
    if ($sNick eq $self->nick && $mediabot->{metrics}) {
        $mediabot->{metrics}->set('mediabot_channel_joined', 0, { channel => $target_name });
        $mediabot->{metrics}->set('mediabot_current_channels',
            scalar(keys %{ $mediabot->{channels} || {} }));
    }
}

sub on_message_PRIVMSG {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_PRIVMSG', $message);
    my ($who, $where, $what) = @{$hints}{qw<prefix_nick targets text>};
    if ( $mediabot->isIgnored($message,$where,$who,$what)) {
        return undef;
    }
    $mediabot->{metrics}->inc('mediabot_privmsg_in_total') if $mediabot->{metrics};
    if ( substr($where,0,1) eq '#' ) {
        # Message on channel
        # Track last seen on public message
        # mb85-B1 / mb86-port: bloc updateUserSeen fermé avant deliverReminders
        {
            my ($sn,$si,$sh) = $mediabot->getMessageNickIdentHost($message);
            eval { $mediabot->updateUserSeen(
                nick       => $sn,
                channel    => $where,
                userhost   => "$si\@$sh",
                event_type => 'message',
                last_msg   => $what,
            ) } if $sn;
        }
        # F13: deliver pending reminders on every public channel message
        eval { Mediabot::UserCommands::deliverReminders($mediabot, $who, $where) };
        if ($@) { $mediabot->{logger}->log(1, "deliverReminders error: $@"); }
        # F24: nick++/nick-- auto-detection DISABLED — use '!karma + <nick>' / '!karma - <nick>'
        # eval { Mediabot::UserCommands::processKarma($mediabot, $who, $where, $what) };
        # F38: check trivia answers on every public message — $@ distinct (mb85-B1)
        eval { Mediabot::UserCommands::checkTriviaAnswer($mediabot, $who, $where, $what) };
        if ($@) { $mediabot->{logger}->log(1, "checkTriviaAnswer error: $@"); }
        if ($mediabot->{metrics}) {
            $mediabot->{metrics}->inc(
                'mediabot_channel_lines_in_total',
                { channel => $where }
            );
        }

        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] $where: <$who> $what");
        }
        
        my $line = defined($what) ? $what : '';
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;

        # Ignore blank / whitespace-only IRC messages.
        # Without this guard, split() leaves $sCommand undefined and later
        # substr()/eq checks emit warnings in the daemon logs.
        return undef if $line eq '';

        my ($sCommand,@tArgs) = split(/\s+/,$line);
        if (defined($sCommand) && substr($sCommand, 0, 1) eq $mediabot->{conf}->get('main.MAIN_PROG_CMD_CHAR')){
            $sCommand = substr($sCommand,1);
            $sCommand =~ tr/A-Z/a-z/;
            if (defined($sCommand) && ($sCommand ne "")) {
                $mediabot->mbCommandPublic($message,$where,$who,$BOTNICK_WASNOT_TRIGGERED,$sCommand,@tArgs);
            }
        }
        elsif ((($sCommand eq $self->nick_folded) && $bNickTriggerCommand) || (($sCommand eq substr($self->nick_folded, 0, 1)) && (defined($mediabot->{conf}->get('main.MAIN_PROG_INITIAL_TRIGGER')) && $mediabot->{conf}->get('main.MAIN_PROG_INITIAL_TRIGGER')))) {
            my $botNickTriggered = (($sCommand eq $self->nick_folded) ? 1 : 0);
            $what =~ s/^\S+\s*//;
            ($sCommand,@tArgs) = split(/\s+/,$what);
            if (defined($sCommand) && ($sCommand ne "")) {
                $sCommand =~ tr/A-Z/a-z/;
                $mediabot->mbCommandPublic($message,$where,$who,$botNickTriggered,$sCommand,@tArgs);
            }
        }
        elsif (($sCommand eq $self->nick_folded . ":") || ($sCommand eq $self->nick_folded . ",")) {
            $what =~ s/^\S+\s*//;
            @tArgs = split(/\s+/,$what);
            if (defined($sCommand) && ($sCommand ne "")) {
                $sCommand =~ tr/A-Z/a-z/;
                $mediabot->chatGPT($message,$who,$where,@tArgs);
            }
        }
        elsif ( $what =~ /https?:\/\//i ) {
            # Single entry point for all URL types.
            # displayUrlTitle() handles routing internally:
            #   YouTube (watch/shorts/live/youtu.be) → chanset Youtube → YouTube Data API v3
            #   Instagram, Spotify                   → chanset UrlTitle
            #   Apple Music                          → chanset AppleMusic
            #   Generic pages                        → chanset UrlTitle → <title> scrape
            $mediabot->displayUrlTitle($message,$who,$where,$what);
        }
        else {
            my $sCurrentNick = $self->nick_folded;
            my $luckyShot = rand(100);
            my $luckyShotHailoChatter = rand(100);
            if ( $luckyShot >= $mediabot->checkResponder($message,$who,$where,$what,@tArgs) ) {
                $mediabot->{logger}->log(4,"Found responder [$where] for $what with luckyShot : $luckyShot");
                $mediabot->{logger}->log(4,"I have a lucky shot to answer for $what");
                $mediabot->{logger}->log(4,"time : " . time . " getLastReponderTs() " . $mediabot->getLastReponderTs() . " delta " . (time - $mediabot->getLastReponderTs()));
                if ((time - $mediabot->getLastReponderTs()) >= 600 ) {
                    # Non-blocking delay: schedule response via IO::Async timer
                    my $resp_delay = int(rand(8) + 2);
                    my $resp_timer = IO::Async::Timer::Countdown->new(
                        delay     => $resp_delay,
                        on_expire => sub {
                            $mediabot->doResponder($message,$who,$where,$what,@tArgs);
                        },
                    );
                    $loop->add($resp_timer);
                    $resp_timer->start;
                }
            }
            elsif ($what =~ /$sCurrentNick/i) {
                my $id_chanset_list = $mediabot->getIdChansetList("Hailo");
                if (defined($id_chanset_list)) {
                    my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
                    if (defined($id_channel_set)) {
                        unless ($mediabot->is_hailo_excluded_nick($who) || (substr($what, 0, 1) eq "!") || (substr($what, 0, 1) eq $mediabot->{conf}->get('main.MAIN_PROG_CMD_CHAR'))) {
                            my $hailo = $mediabot->get_hailo();
                            $what =~ s/$sCurrentNick//g;
                            $what =~ s/^\s+//g;
                            $what =~ s/\s+$//g;
                            $what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });
                            my $sAnswer = $hailo->learn_reply($what);
                            if (defined($sAnswer) && ($sAnswer ne "") && !($sAnswer =~ /^\Q$what\E\s*\.$/i)) {
                                $mediabot->{logger}->log(4,"Hailo current nick learn_reply $what from $who : $sAnswer");
                                $mediabot->botPrivmsg($where,$sAnswer);
                            }
                        }
                    }
                }
            }
            elsif ( ($mediabot->get_hailo_channel_ratio($where) != -1) && ($luckyShotHailoChatter >= $mediabot->get_hailo_channel_ratio($where)) ) {
                my $id_chanset_list = $mediabot->getIdChansetList("HailoChatter");
                if (defined($id_chanset_list)) {
                    my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
                    if (defined($id_channel_set)) {
                        unless ($mediabot->is_hailo_excluded_nick($who) || (substr($what, 0, 1) eq "!") || (substr($what, 0, 1) eq $mediabot->{conf}->get('main.MAIN_PROG_CMD_CHAR'))) {
                            my $hailo = $mediabot->get_hailo();
                            $what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });
                            my $sAnswer = $hailo->learn_reply($what);
                            if (defined($sAnswer) && ($sAnswer ne "") && !($sAnswer =~ /^\Q$what\E\s*\.$/i)) {
                                $mediabot->{logger}->log(4,"HailoChatter learn_reply $what from $who : $sAnswer");
                                $mediabot->botPrivmsg($where,$sAnswer);
                            }
                        }
                    }
                }
            }
            else {
                my $id_chanset_list = $mediabot->getIdChansetList("Hailo");
                if (defined($id_chanset_list)) {
                    my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
                    if (defined($id_channel_set)) {
                        unless ($mediabot->is_hailo_excluded_nick($who) || (substr($what, 0, 1) eq "!") || (substr($what, 0, 1) eq $mediabot->{conf}->get('main.MAIN_PROG_CMD_CHAR'))) {
                            my $min_words = (defined($mediabot->{conf}->get('hailo.HAILO_LEARN_MIN_WORDS')) ? $mediabot->{conf}->get('hailo.HAILO_LEARN_MIN_WORDS') : 3);
                            my $max_words = (defined($mediabot->{conf}->get('hailo.HAILO_LEARN_MAX_WORDS')) ? $mediabot->{conf}->get('hailo.HAILO_LEARN_MAX_WORDS') : 20);
                            my $num;
                            $num++ while $what =~ /\S+/g;
                            if (($num >= $min_words) && ($num <= $max_words)) {
                                my $hailo = $mediabot->get_hailo();
                                $what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });
                                $hailo->learn($what);
                                $mediabot->{logger}->log(4,"learnt $what from $who");
                            }
                            else {
                                $mediabot->{logger}->log(4,"word count is out of range to learn $what from $who");
                            }
                        }
                    }
               }
           }
        }
        if ((ord(substr($what,0,1)) == 1) && ($what =~ /^.ACTION /)) {
            $what =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;
            $what =~ s/^ACTION //;
            $mediabot->logBotAction($message,"action",$who,$where,$what);
        }
        else {
            $mediabot->logBotAction($message,"public",$who,$where,$what);
        }
    }
    else {
        # DCC/CTCP DEBUG - visible only at high debug level
        my $what_for_hex = defined($what) ? $what : '';
        $mediabot->{logger}->log(4, sprintf(
            "[DCC_DEBUG] what_hex='%s' where='%s' who='%s'",
            unpack('H*', $what_for_hex), $where, $who
        ));

        # DCC/CTCP parser module path.
        #
        # Handles fragile CTCP/DCC payloads before the private command parser
        # can mistake raw DCC CHAT for a private command named "dcc":
        #   \x01CHAT\x01
        #   \x01DCC CHAT chat <ip_int> <port>\x01
        #   \x01DCC CHAT chat 0 0 <token>\x01
        #   CHAT chat <ip_int> <port>
        if ($where !~ /^#/ && defined($what)) {
            my $dcc_parse = parse_ctcp_payload($what);

            if (is_ctcp_chat($dcc_parse)) {
                $mediabot->{logger}->log(2, "CTCP CHAT request from $who via Mediabot::DCC parser");
                $mediabot->_handle_ctcp_chat_request($message, $who);
                return undef;
            }

            if (is_dcc_chat($dcc_parse)) {
                my $ip_int = $dcc_parse->{ip_int};
                my $port   = $dcc_parse->{port};
                my $token  = $dcc_parse->{token};

                $mediabot->{logger}->log(
                    2,
                    "DCC CHAT request from $who via Mediabot::DCC parser ip=$ip_int port=$port"
                    . (defined $token ? " token_present=1" : "")
                );

                $mediabot->_handle_dcc_chat_request($message, $who, $ip_int, $port, $token);
                return undef;
            }
        }



        # Private message hide passwords
        unless ( $what =~ /^login|^register|^pass|^newpass|^ident/i) {
            if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
                $mediabot->{logger}->log(0,"[LIVE] $where: <$who> $what");
            }
        }
        my $private_line = defined($what) ? $what : '';
        $private_line =~ s/^\s+//;
        $private_line =~ s/\s+$//;

        # Ignore blank / whitespace-only private IRC messages.
        return undef if $private_line eq '';

        my ($sCommand,@tArgs) = split(/\s+/,$private_line);
        $sCommand =~ tr/A-Z/a-z/;
        $mediabot->{logger}->log(4,"sCommands = $sCommand");
        if (defined($sCommand) && ($sCommand ne "")) {
            if ($sCommand =~ /restart/i) {
                    if ($MAIN_PROG_DAEMON) {
                        $mediabot->mbRestart($message,$who,($sFullParams));
                    }
                    else {
                        $mediabot->botNotice($who,"restart command can only be used in daemon mode (use --daemon to launch the bot)");
                    }
                }
                elsif ($sCommand =~ /jump/i) {
                    if ($MAIN_PROG_DAEMON) {
                        $mediabot->mbJump($message,$who,($sFullParams,$tArgs[0]));
                    }
                    else {
                        $mediabot->botNotice($who,"jump command can only be used in daemon mode (use --daemon to launch the bot)");
                    }
                }
                else {
                    $mediabot->mbCommandPrivate($message,$who,$sCommand,@tArgs);
                }
        }
    }
}

sub on_message_ctcp_CHAT {
    my ($self, $message, $hints) = @_;

    my $who = $hints->{prefix_nick}        // return;
    my $to  = ($hints->{targets} // [])->[0] // '';

    # Only handle CTCP CHAT directed to the bot, not a channel.
    return if $to =~ /^#/;

    $mediabot->{logger}->log(2, "CTCP CHAT request from $who");

    $mediabot->_handle_ctcp_chat_request($message, $who);

    return undef;
}

sub on_message_ctcp_DCC {
    my ($self, $message, $hints) = @_;

    my $dcc_debug_hints = eval { $mediabot->{conf}->get('main.DCC_DEBUG_HINTS') } || 0;

    # High-level CTCP DCC diagnostics.
    # Disabled by default; enable main.DCC_DEBUG_HINTS=1 when debugging client payloads.
    if ($dcc_debug_hints) {
        my $who_dbg = (ref($hints) eq 'HASH' ? ($hints->{prefix_nick} // '?') : '?');
        $mediabot->{logger}->log(4, "[CTCP_DCC_DEBUG] handler called from $who_dbg");

        for my $k (sort keys %{ $hints || {} }) {
            my $v = $hints->{$k} // 'undef';
            if (ref($v) eq 'ARRAY') {
                $v = '[' . join(',', @$v) . ']';
            } elsif (ref($v)) {
                $v = ref($v);
            }
            $mediabot->{logger}->log(4, "[CTCP_DCC_DEBUG] hint $k=" . unpack('H*', "$v"));
        }

        my $raw = eval { $message->as_string } // '';
        $mediabot->{logger}->log(4, "[CTCP_DCC_DEBUG] raw_message_hex=" . unpack('H*', $raw));
    }

    my $who  = $hints->{prefix_nick}        // return;
    my $to   = ($hints->{targets} // [])->[0] // '';

    # Try both known hint key names — Net::Async::IRC version-dependent.
    # Parsing itself is centralized in Mediabot::DCC.
    my $args = $hints->{ctcp_args}
            // $hints->{text}
            // $hints->{ctcp_data}
            // '';

    # Only handle DCC CHAT directed to the bot (not to a channel)
    return if $to =~ /^#/;

    my $dcc_parse = parse_dcc_payload($args);
    my $payload   = $dcc_parse->{payload} // $args;

    $mediabot->{logger}->log(3, "CTCP DCC from $who: '$payload'");

    if (is_dcc_chat($dcc_parse)) {
        my $ip_int = $dcc_parse->{ip_int};
        my $port   = $dcc_parse->{port};
        my $token  = $dcc_parse->{token};

        $mediabot->{logger}->log(
            2,
            "CTCP DCC CHAT request from $who via Mediabot::DCC parser ip=$ip_int port=$port"
            . (defined $token ? " token_present=1" : "")
        );

        $mediabot->_handle_dcc_chat_request($message, $who, $ip_int, $port, $token);
    }
    else {
        $mediabot->{logger}->log(2, "DCC from $who: unhandled DCC type '$payload' - ignored");
    }

    return undef;
}

sub on_message_TOPIC {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_TOPIC', $message);
    my ($target_name,$text) = @{$hints}{qw<target_name text>};
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
    unless(defined($text)) { $text="";}
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
        $mediabot->{logger}->log(0,"[LIVE] <$target_name> * $sNick changes topic to '$text'");
    }
    $mediabot->logBotAction($message,"topic",$sNick,$target_name,$text);
}

sub on_message_LIST {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_LIST', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(4,"on_message_LIST() $target_name");
}

sub on_message_RPL_NAMEREPLY {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_RPL_NAMEREPLY', $message);

    my @args = $message->args;
    my ($target_name) = @{$hints}{qw<target_name>};

    return unless defined $target_name && $target_name ne '';
    return unless defined $args[3] && $args[3] ne '';

    my $names_blob = $args[3];

    # Remove common IRC prefix modes from nick list entries
    $names_blob =~ s/[@+%&~]//g;

    my @tNicklist = grep { defined($_) && $_ ne '' } split(/\s+/, $names_blob);

    my %tmp_nicklists = ();
    if (defined($mediabot->{hChannelsNicksTmp})) {
        %tmp_nicklists = %{ $mediabot->{hChannelsNicksTmp} };
    }

    push @{ $tmp_nicklists{$target_name} }, @tNicklist;
    %{ $mediabot->{hChannelsNicksTmp} } = %tmp_nicklists;

    $mediabot->sethChannelsNicksEndOnChan($target_name, 0);
    $mediabot->{logger}->log(4, "Buffered NAMES chunk for $target_name (" . scalar(@tNicklist) . " nicks)");
}

# Numeric 366 RPL_ENDOFNAMES
sub on_message_RPL_ENDOFNAMES {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_RPL_ENDOFNAMES', $message);

    my @args = $message->args;
    my $channel = $args[1] // '<unknown>';

    $mediabot->{logger}->log(4, "on_message_RPL_ENDOFNAMES() $channel");

    if (defined($channel) && $channel ne '' && $channel ne '<unknown>') {
        my %tmp_nicklists = ();
        if (defined($mediabot->{hChannelsNicksTmp})) {
            %tmp_nicklists = %{ $mediabot->{hChannelsNicksTmp} };
        }

        my @buffered = ();
        if (defined($tmp_nicklists{$channel})) {
            @buffered = @{ $tmp_nicklists{$channel} };
        }

        my %seen;
        my @deduped = grep { defined($_) && $_ ne '' && !$seen{$_}++ } @buffered;

        $mediabot->sethChannelsNicksOnChan($channel, @deduped);
        delete $tmp_nicklists{$channel};
        %{ $mediabot->{hChannelsNicksTmp} } = %tmp_nicklists;

        $mediabot->sethChannelsNicksEndOnChan($channel, 1);
        if ($mediabot->{metrics}) {
            $mediabot->{metrics}->set('mediabot_channel_nick_count',
                scalar(@deduped), { channel => $channel });
        }
        $mediabot->{logger}->log(4, "Finalized NAMES for $channel (" . scalar(@deduped) . " unique nicks)");
    }
}

sub on_message_WHO {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHO', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(3,"on_message_WHO() $target_name");
}

sub on_message_WHOIS {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHOIS', $message);
    $mediabot->{logger}->log(4, "on_message_WHOIS() prefix=" . ($message->prefix // "?") . " command=" . ($message->command // "?"));
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(3,"on_message_WHOIS() $target_name");
}

sub on_message_WHOWAS {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHOWAS', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(3,"on_message_WHOWAS() $target_name");
}
                
sub on_message_JOIN {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_JOIN', $message);
    my %hChannelsNicks = ();
    if (defined($mediabot->gethChannelNicks())) {
        %hChannelsNicks = %{$mediabot->gethChannelNicks()};
    }
    my ($target_name) = @{$hints}{qw<target_name>};
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
    if ( $sNick eq $self->nick ) {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] * Now talking in $target_name");
        }
        if ($mediabot->{metrics}) {
            $mediabot->{metrics}->set('mediabot_channel_joined', 1, { channel => $target_name });
            $mediabot->{metrics}->set('mediabot_current_channels',
                scalar(keys %{ $mediabot->{channels} || {} }));
        }
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] <$target_name> * Joins $sNick ($sIdent\@$sHost)");
        }
        $mediabot->userOnJoin($message,$target_name,$sNick);

        # Track last seen on JOIN
        eval { $mediabot->updateUserSeen(
            nick       => $sNick,
            channel    => $target_name,
            userhost   => "$sIdent\@$sHost",
            event_type => 'join',
        ) };

        # Enforce active ChannelBans on JOIN: MODE +b + KICK if mask matches.
        if ($mediabot->{channel_ban} && $sIdent && $sHost) {
            my $cb       = $mediabot->{channel_ban};
            my $chan_obj = $mediabot->{channels}{$target_name}
                        // $mediabot->{channels}{lc($target_name)};
            my $id_channel = eval { $chan_obj->get_id } // 0;
            if ($id_channel) {
                my $norm_mask = $cb->mask_from_hostmask("$sNick!$sIdent\@$sHost");
                if ($norm_mask) {
                    my $ban = $cb->active_ban_for_mask($id_channel, $norm_mask);
                    if ($ban) {
                        $mediabot->{logger}->log(2,
                            "ChannelBan: $sNick matches ban #$ban->{id_channel_ban} on $target_name - enforcing");
                        eval {
                            $mediabot->{irc}->send_message('MODE', undef, $target_name, '+b', $norm_mask);
                            $mediabot->{irc}->send_message('KICK', undef, $target_name, $sNick,
                                $ban->{reason} // 'Banned');
                        };
                    }
                }
            }
        }

        push @{$hChannelsNicks{$target_name}}, $sNick;
        $mediabot->sethChannelNicks(\%hChannelsNicks);
    }
    $mediabot->logBotAction($message,"join",$sNick,$target_name,"");
}
        
sub on_message_001 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_001', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(4,"001 $text");
}
        
sub on_message_002 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_002', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(4,"002 $text");
}
        
sub on_message_003 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_003', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(4,"003 $text");
}
        
# Numeric 004 - Server version/info
sub on_message_004 {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_004', $message);
    my @args = $message->args;
    my $server = $args[0] // '<unknown>';
    my $version = $args[1] // '<unknown>';
    my $user_modes = $args[2] // '';
    my $chan_modes = $args[3] // '';
    $mediabot->{logger}->log(4, "004 server=$server version=$version user_modes=$user_modes chan_modes=$chan_modes");
}
        
# Numeric 005 - ISUPPORT
sub on_message_005 {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_005', $message);
    my @args = $message->args;
    shift @args; # Remove nickname (first arg)
    my $features = join(" ", @args);
    $mediabot->{logger}->log(4, "005 $features");
}
        
sub on_motd {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_motd', $message);
    my @motd_lines = @{$hints}{qw<motd>};
    foreach my $line (@{$motd_lines[0]}) {
        $mediabot->{logger}->log(4,"-motd- $line");
    }
}
    
sub on_message_RPL_WHOISUSER {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_RPL_WHOISUSER', $message);
    my $whois_ref = $mediabot->getWhoisVar();
    my %WHOIS_VARS = (ref($whois_ref) eq 'HASH') ? %{$whois_ref} : ();
    my @tArgs = $message->args;
    my $sHostname = $tArgs[3];
    my ($target_name,$ident,$host,$flags,$realname) = @{$hints}{qw<target_name ident host flags realname>};
    $mediabot->{logger}->log(2,"$target_name is $ident\@$sHostname $flags $realname");
    # B1/A1: route to Partyline if .whois was issued from a session
    _partyline_whois_write($target_name, "[311] $target_name $ident\@$sHostname * :$realname");
    if (defined($WHOIS_VARS{'nick'}) && ($WHOIS_VARS{'nick'} eq $target_name) && defined($WHOIS_VARS{'sub'}) && ($WHOIS_VARS{'sub'} ne "")) {
        if ($WHOIS_VARS{'sub'} eq "userVerifyNick") {
                $mediabot->{logger}->log(4,"WHOIS userVerifyNick");
                my $_whois_user = $mediabot->get_user_from_whois("$ident\@$sHostname");
                my $iMatchingUserId        = $_whois_user ? eval { $_whois_user->id }                              : undef;
                my $iMatchingUserLevel     = $_whois_user ? $_whois_user->{level}                                  : undef;
                my $iMatchingUserLevelDesc = $_whois_user ? $_whois_user->{level_desc}                             : undef;
                my $iMatchingUserAuth      = $_whois_user ? (eval { $_whois_user->is_authenticated } ? 1 : ($_whois_user->{auth} // 0)) : undef;
                my $sMatchingUserHandle    = $_whois_user ? eval { $_whois_user->nickname }                        : undef;
                my $sMatchingUserPasswd    = $_whois_user ? $_whois_user->{password}                               : undef;
                my $sMatchingUserInfo1     = $_whois_user ? $_whois_user->{info1}                                  : undef;
                my $sMatchingUserInfo2     = $_whois_user ? $_whois_user->{info2}                                  : undef;
                if (defined($WHOIS_VARS{'caller'}) && ($WHOIS_VARS{'caller'} ne "")) {
                    if (defined($iMatchingUserId)) {
                        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is authenticated as $sMatchingUserHandle ($iMatchingUserLevelDesc)");
                        }
                        else {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is not authenticated. User $sMatchingUserHandle ($iMatchingUserLevelDesc)");
                        }
                    }
                    else {
                        $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is not a known user with this hostmask : $ident\@$sHostname");
                    }
                    $mediabot->logBot($WHOIS_VARS{'message'},undef,"verify",($target_name));
                }
            }
        elsif ($WHOIS_VARS{'sub'} eq "userAuthNick") {
                $mediabot->{logger}->log(4,"WHOIS userAuthNick");
                my $_whois_user = $mediabot->get_user_from_whois("$ident\@$sHostname");
                my $iMatchingUserId        = $_whois_user ? eval { $_whois_user->id }                              : undef;
                my $iMatchingUserLevel     = $_whois_user ? $_whois_user->{level}                                  : undef;
                my $iMatchingUserLevelDesc = $_whois_user ? $_whois_user->{level_desc}                             : undef;
                my $iMatchingUserAuth      = $_whois_user ? (eval { $_whois_user->is_authenticated } ? 1 : ($_whois_user->{auth} // 0)) : undef;
                my $sMatchingUserHandle    = $_whois_user ? eval { $_whois_user->nickname }                        : undef;
                my $sMatchingUserPasswd    = $_whois_user ? $_whois_user->{password}                               : undef;
                my $sMatchingUserInfo1     = $_whois_user ? $_whois_user->{info1}                                  : undef;
                my $sMatchingUserInfo2     = $_whois_user ? $_whois_user->{info2}                                  : undef;
                if (defined($WHOIS_VARS{'caller'}) && ($WHOIS_VARS{'caller'} ne "")) {
                    if (defined($iMatchingUserId)) {
                        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is already authenticated as $sMatchingUserHandle ($iMatchingUserLevelDesc)");
                        }
                        else {
                            my $sQuery = "UPDATE USER SET auth=1 WHERE nickname=?";
                            my $sth = $mediabot->{db}->ensure_connected()->prepare($sQuery);
                            unless ($sth && $sth->execute($sMatchingUserHandle)) {
                                $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                            }
                            else {
                                $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name has been authenticated. User $sMatchingUserHandle ($iMatchingUserLevelDesc)");
                            }
                            $sth->finish;
                       }
                    }
                    else {
                        $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is not a known user with this hostmask : $ident\@$sHostname");
                    }
                        $mediabot->logBot($WHOIS_VARS{'message'},undef,"auth",($target_name));
                }
            }
        elsif ($WHOIS_VARS{'sub'} eq "userAccessChannel") {
                $mediabot->{logger}->log(4,"WHOIS userAccessChannel");
                my $_whois_user = $mediabot->get_user_from_whois("$ident\@$sHostname");
                my $iMatchingUserId        = $_whois_user ? eval { $_whois_user->id }                              : undef;
                my $iMatchingUserLevel     = $_whois_user ? $_whois_user->{level}                                  : undef;
                my $iMatchingUserLevelDesc = $_whois_user ? $_whois_user->{level_desc}                             : undef;
                my $iMatchingUserAuth      = $_whois_user ? (eval { $_whois_user->is_authenticated } ? 1 : ($_whois_user->{auth} // 0)) : undef;
                my $sMatchingUserHandle    = $_whois_user ? eval { $_whois_user->nickname }                        : undef;
                my $sMatchingUserPasswd    = $_whois_user ? $_whois_user->{password}                               : undef;
                my $sMatchingUserInfo1     = $_whois_user ? $_whois_user->{info1}                                  : undef;
                my $sMatchingUserInfo2     = $_whois_user ? $_whois_user->{info2}                                  : undef;
                if (defined($WHOIS_VARS{'caller'}) && ($WHOIS_VARS{'caller'} ne "")) {
                    unless (defined($sMatchingUserHandle)) {
                        $mediabot->botNotice($WHOIS_VARS{'caller'},"No Match!");
                        $mediabot->logBot($WHOIS_VARS{'message'},undef,"access",($WHOIS_VARS{'channel'},"=".$target_name));
                    }
                    else {
                        my $iChannelUserLevelAccess = $mediabot->getUserChannelLevelByName($WHOIS_VARS{'channel'},$sMatchingUserHandle);
                        if ( $iChannelUserLevelAccess == 0 ) {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"No Match!");
                            $mediabot->logBot($WHOIS_VARS{'message'},undef,"access",($WHOIS_VARS{'channel'},"=".$target_name));
                        }
                        else {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"USER: $sMatchingUserHandle ACCESS: $iChannelUserLevelAccess");
                            my $sQuery = "SELECT automode, greet FROM USER JOIN USER_CHANNEL ON USER_CHANNEL.id_user = USER.id_user JOIN CHANNEL ON CHANNEL.id_channel = USER_CHANNEL.id_channel WHERE USER.nickname = ? AND CHANNEL.name = ?";
                            my $sth = $mediabot->{db}->ensure_connected()->prepare($sQuery);
                            unless ($sth && $sth->execute($sMatchingUserHandle,$WHOIS_VARS{'channel'})) {
                                $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                            }
                            else {
                                my $sAuthUserStr;
                                if (my $ref = $sth->fetchrow_hashref()) {
                                    my $sGreetMsg = $ref->{'greet'};
                                    my $sAutomode = $ref->{'automode'};
                                    unless (defined($sGreetMsg)) {
                                        $sGreetMsg = "None";
                                    }
                                    unless (defined($sAutomode)) {
                                        $sAutomode = "None";
                                    }
                                    $mediabot->botNotice($WHOIS_VARS{'caller'},"CHANNEL: " . $WHOIS_VARS{'channel'} . " -- Automode: $sAutomode");
                                    $mediabot->botNotice($WHOIS_VARS{'caller'},"GREET MESSAGE: $sGreetMsg");
                                    $mediabot->logBot($WHOIS_VARS{'message'},undef,"access",($WHOIS_VARS{'channel'},"=".$target_name));
                                }
                           }
                           $sth->finish;
                       }
                   }
                }  
            }
        elsif ($WHOIS_VARS{'sub'} eq "mbWhereis") {
                $mediabot->{logger}->log(4,"WHOIS mbWhereis");
                my $country = $mediabot->whereis($sHostname);
                if (defined($country)) {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
                else {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
            }
        elsif ($WHOIS_VARS{'sub'} eq "statPartyline") {
               $mediabot->{logger}->log(4, "WHOIS statPartyline");

               my $fd = $WHOIS_VARS{'caller'};
               my $stream = $mediabot->{partyline}->{streams}{$fd};
               unless ($stream) {
                   $mediabot->{logger}->log(1, "statPartyline: stream $fd not found");
                   return;
               }

               my $args_ref = $message->args;
               my @args = ref($args_ref) eq 'ARRAY' ? @$args_ref : ();
               my $channels_str = $args[2] // "";

               my %joined = map { $_ => 1 } grep { /^#/ } split /\s+/, $channels_str;

               my $txt = "Mediabot channel status:\n";
               foreach my $chan (sort keys %{ $mediabot->{channels} }) {
                   if ($joined{$chan}) {
                       $txt .= " - $chan : joined\n";
                   } else {
                       $txt .= " - $chan : not joined\n";
                   }
               }
               $stream->write($txt);
           }
        elsif ($WHOIS_VARS{'sub'} eq "partylineBan") {
            $mediabot->{logger}->log(4, "WHOIS partylineBan");

            my $fd        = $WHOIS_VARS{'caller'};
            my $stream    = $mediabot->{partyline} ? $mediabot->{partyline}->{streams}{$fd} : undef;
            my $session   = $mediabot->{partyline} ? $mediabot->{partyline}->{users}{$fd} : undef;

            # Guard against concurrent .ban calls overwriting WHOIS_VARS.
            # Both the global WHOIS context and the Partyline session must carry
            # the same one-shot token before we apply the ban.
            my $whois_token   = $WHOIS_VARS{'token'} // '';
            my $session_token = ($session && ref($session) eq 'HASH')
                ? ($session->{pending_whois_token} // '')
                : '';

            unless ($whois_token ne '' && $session_token ne '' && $whois_token eq $session_token) {
                $mediabot->{logger}->log(
                    1,
                    "partylineBan: WHOIS token mismatch for fd="
                    . (defined($fd) ? $fd : 'undef')
                    . " target=$target_name"
                );

                if ($stream) {
                    $stream->write("WHOIS context changed before ban could be applied; please retry .ban.\r\n");
                }

                return;
            }

            delete $session->{pending_whois_token} if $session;
            delete $session->{pending_whois_sub}   if $session;

            my $chan      = $WHOIS_VARS{'channel'}  // '';
            my $duration  = $WHOIS_VARS{'duration'} // 0;
            my $dur_label = $WHOIS_VARS{'dur_label'} // 'permanent';
            my $reason    = $WHOIS_VARS{'reason'}   // '';
            my $actor     = $WHOIS_VARS{'actor'}    // 'partyline';

            unless ($stream) {
                $mediabot->{logger}->log(1, "partylineBan: stream $fd not found");
                return;
            }

            my $fullmask = "$ident\@$sHostname";
            my $cb = $mediabot->{channel_ban};

            unless ($cb) {
                $stream->write("ChannelBan module not available.\r\n");
                return;
            }

            my $norm_mask = $cb->mask_from_hostmask("$target_name!$fullmask");
            unless ($norm_mask) {
                $stream->write("Could not derive ban mask from hostmask $fullmask.\r\n");
                return;
            }

            my $err_val = $cb->validate_mask($norm_mask);
            if ($err_val) {
                $stream->write("Invalid mask $norm_mask: $err_val\r\n");
                return;
            }

            my $chan_obj   = $mediabot->{channels}{$chan} // $mediabot->{channels}{lc($chan)};
            my $id_channel = eval { $chan_obj->get_id } // 0;
            unless ($id_channel) {
                $stream->write("Channel $chan not found in bot state.\r\n");
                return;
            }

            my $expires_at = $duration > 0 ? $cb->expires_sql_from_seconds($duration) : undef;

            my ($id_ban, $ban_err) = $cb->add_ban(
                id_channel      => $id_channel,
                mask            => $norm_mask,
                ban_level       => 75,
                reason          => $reason,
                created_by_nick => $actor,
                expires_at      => $expires_at,
                source          => 'partyline',
            );

            if ($ban_err) {
                $stream->write("Ban failed: $ban_err\r\n");
                return;
            }

            eval {
                $mediabot->{irc}->send_message('MODE', undef, $chan, '+b', $norm_mask);
            };

            my $exp_txt = $duration > 0 ? $dur_label : 'permanent';
            $stream->write("Banned $norm_mask on $chan (expires: $exp_txt, ban #$id_ban).\r\n");
            $mediabot->{logger}->log(2, "Partyline: $actor banned $norm_mask on $chan ($exp_txt)");
        }
    }
}

sub on_message_ERROR {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_ERROR', $message);
    my $err_msg = join(" ", @{ $message->args // [] });
    $mediabot->{logger}->log(0, "ERROR from server: $err_msg");

    if ($mediabot->getQuit()) {
        $mediabot->clean_and_exit(0);
        return;
    }

    # Do NOT call $loop->stop here.
    # Stopping the loop from a callback kills the main $loop->run,
    # which terminates the process (and the Partyline) entirely.
    # on_timer_tick detects is_connected=false and schedules reconnect()
    # via IO::Async::Timer::Countdown - let it handle this.
    $mediabot->setServer(undef);

    if ($mediabot->{metrics}) {
        $mediabot->{metrics}->set('mediabot_irc_connected', 0);
        $mediabot->{metrics}->inc('mediabot_irc_reconnect_total');
    }

    $mediabot->{logger}->log(0, "on_message_ERROR: IRC connection lost - on_timer_tick will reconnect");
}

sub on_message_KILL {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_KILL', $message);
    my @kill_args = eval { @{ $message->args // [] } } // ();
    my ($killer, $victim, $reason) = @kill_args;
    $mediabot->{logger}->log(0, "Killed by $killer: $reason - will reconnect.");

    if ($mediabot->getQuit()) {
        $mediabot->clean_and_exit(0);
        return;
    }

    # Same as on_message_ERROR: do NOT call $loop->stop.
    # on_timer_tick will detect is_connected=false and schedule reconnect().
    $mediabot->setServer(undef);
    $mediabot->{logger}->log(0, "on_message_KILL: IRC connection lost - on_timer_tick will reconnect");
}

sub on_message_SERVER {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_SERVER', $message);
    my @srv_args = eval { @{ $message->args // [] } } // ();
    $mediabot->{logger}->log(1, "SERVER message: " . join(" ", @srv_args));
}

# Numeric 332 RPL_TOPIC
sub on_message_RPL_TOPIC {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_TOPIC', $message);
    my @args = $message->args;
    my $channel = $args[1] // '<unknown>';
    my $topic   = $args[2] // '<none>';
    $mediabot->{logger}->log(1, "Topic for $channel: $topic");
}

# Numeric 333 RPL_TOPICWHOTIME
sub on_message_RPL_TOPICWHOTIME {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_TOPICWHOTIME', $message);
    my @args = $message->args;
    my $channel = $args[1] // '<unknown>';
    my $setter  = $args[2] // '<unknown>';
    my $ts      = $args[3] // time;
    my $time    = scalar localtime($ts);
    $mediabot->{logger}->log(1, "Topic for $channel set by $setter on $time");
}

sub on_message_RPL_LIST {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_LIST', $message);
    my @list_args = eval { @{ $message->args // [] } } // ();
    my ($chan, $users, $topic) = @list_args;
    $mediabot->{logger}->log(2, "Channel $chan ($users users): $topic");
}

sub on_message_RPL_LISTEND {
    $mediabot->{logger}->log(4, "End of channel list.");
}

sub on_message_RPL_WHOREPLY {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_WHOREPLY', $message);

    my @who_args = eval { @{ $message->args // [] } } // ();

    # WHO replies can be very noisy during joins/reconnects. They are useful
    # when debugging presence/userhost state, but not at DEBUG2. Also avoid
    # logging a useless "WHO reply:" line when the IRC library exposes no
    # parsed args for this numeric.
    if (@who_args) {
        $mediabot->{logger}->log(4, "WHO reply: " . join(" ", @who_args));
    }
    else {
        $mediabot->{logger}->log(5, "WHO reply received without parsed args.");
    }
}

sub on_message_RPL_ENDOFWHO {
    # End-of-WHO is routine IRC noise; keep it out of DEBUG2.
    $mediabot->{logger}->log(4, "End of WHO list.");
}


# ---------------------------------------------------------------------------
# _partyline_whois_clear() — internal
# Clear pending Partyline WHOIS state.
# ---------------------------------------------------------------------------
sub _partyline_whois_clear {
    delete $mediabot->{$_} for qw(
        _partyline_whois_fd
        _partyline_whois_nick
        _partyline_whois_ts
    );
}

# ---------------------------------------------------------------------------
# _partyline_whois_write($nick, $line, %opts) — internal
# Write a WHOIS reply line to the active Partyline session, if it matches
# the nick requested by that session.
#
# Options:
#   clear => 1   clear pending state after writing
#
# This prevents an unrelated WHOIS reply from leaking into the Partyline
# session that requested a different nick.
# ---------------------------------------------------------------------------
sub _partyline_whois_write {
    my ($nick, $line, %opts) = @_;

    my $fd      = $mediabot->{_partyline_whois_fd}   // return 0;
    my $wanted  = $mediabot->{_partyline_whois_nick} // '';
    my $ts      = $mediabot->{_partyline_whois_ts}   // 0;

    # Timeout: clean up stale state.
    if (time() - $ts > 30) {
        $mediabot->{logger}->log(3, "Partyline .whois: timed out, clearing state");
        _partyline_whois_clear();
        return 0;
    }

    $nick //= '';

    if ($wanted ne '' && lc($nick) ne lc($wanted)) {
        $mediabot->{logger}->log(
            4,
            "Partyline .whois: ignoring WHOIS line for $nick while waiting for $wanted"
        );
        return 0;
    }

    my $stream = eval { $mediabot->{partyline}->{streams}{$fd} };

    unless ($stream) {
        $mediabot->{logger}->log(3, "Partyline .whois: stream fd=$fd disappeared, clearing state");
        _partyline_whois_clear();
        return 0;
    }

    eval { $stream->write($line . "\r\n") };

    if ($@) {
        my $err = $@;
        chomp $err;
        $mediabot->{logger}->log(1, "Partyline .whois: failed to write to fd=$fd: $err");
        _partyline_whois_clear();
        return 0;
    }

    _partyline_whois_clear() if $opts{clear};

    return 1;
}

sub on_message_RPL_WHOISCHANNELS {
    my ($self, $message, $hints) = @_;

    my @args = $message->args;
    my $nick  = $args[1] // '<undef>';
    my $chans = $args[2] // '';

    # A5: log at DEBUG4 to avoid leaking secret/private channel names
    $mediabot->{logger}->log(4, "$nick on channels: $chans");
    # B1/A1: route to Partyline
    _partyline_whois_write($nick, "[319] $nick :$chans") if $chans ne '';
}

sub on_message_RPL_WHOISSERVER {
    my ($self, $message, $hints) = @_;

    my @args   = $message->args;
    my $nick   = $args[1] // '';
    my $server = $args[2] // '';
    my $info   = $args[3] // '';
    $mediabot->{logger}->log(2, "$nick server $server ($info)");
    _partyline_whois_write($nick, "[312] $nick $server :$info");
}

sub on_message_RPL_WHOISIDLE {
    my ($self, $message, $hints) = @_;

    my @args   = $message->args;
    my $nick   = $args[1] // '';
    my $idle   = $args[2] // 0;
    my $signon = $args[3] // time;
    $mediabot->{logger}->log(2, "$nick idle for ${idle}s, signon: " . scalar localtime($signon));
    _partyline_whois_write($nick, "[317] $nick idle=${idle}s signon=" . scalar localtime($signon));
}

sub on_message_RPL_ENDOFWHOIS {
    my ($self, $message, $hints) = @_;
    my $nick = ($message->args)[1] // '';
    $mediabot->{logger}->log(3, "WHOIS end for $nick");
    # B1/A1: send closing line and clear Partyline whois state
    _partyline_whois_write($nick, "[318] $nick :End of WHOIS", clear => 1);
}


sub on_message_ERR_NOSUCHNICK {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_ERR_NOSUCHNICK', $message);

    my @args = $message->args;

    # Typical numeric 401 shape:
    #   <me> <nick> :No such nick/channel
    my $nick   = $args[1] // '';
    my $reason = $args[2] // 'No such nick/channel';

    my $wanted = $mediabot->{_partyline_whois_nick};

    # Only report loudly when the 401 belongs to an active Partyline .whois.
    # Other ERR_NOSUCHNICK messages can happen during startup/service probing
    # and should not look like operator-facing WHOIS failures.
    if (defined($wanted) && lc($nick) eq lc($wanted)) {
        $mediabot->{logger}->log(3, "Partyline WHOIS no such nick: $nick ($reason)");
        _partyline_whois_write($nick, "[401] $nick :$reason", clear => 1);
        return;
    }

    $mediabot->{logger}->log(4, "Ignoring unrelated ERR_NOSUCHNICK for $nick ($reason)");
}



sub on_message_ERR_NICKNAMEINUSE {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_ERR_NICKNAMEINUSE', $message);
    my $conflict = $message->args->[1] // '';
    my $new_nick = $self->nick_folded . "_";
    $self->change_nick($new_nick);
    $mediabot->{logger}->log(0, "Nick \"$conflict\" in use, switched to $new_nick");
}

sub on_message_RPL_MYINFO {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_MYINFO', $message);
    my @a = eval { @{ $message->args // [] } } // ();
    $mediabot->{logger}->log(4,"Server info: host=$a[0], ver=$a[1], umodes=$a[2], cmodes=$a[3]");
}

sub on_message_RPL_ISUPPORT {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_ISUPPORT', $message);
    $mediabot->{logger}->log(5, "ISUPPORT tokens: " . join(' ', (eval { @{ $message->args // [] } } // ())));
}

sub on_message_RPL_INVITING {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_INVITING', $message);
    my @_margs_2172 = eval { @{ $message->args // [] } } // ();
    my ($nick, $channel) = @_margs_2172[1,2];
    $mediabot->{logger}->log(2, "You have been invited: $nick -> $channel");
}

sub on_message_RPL_INVITELIST {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_INVITELIST', $message);
    my @_margs_2179 = eval { @{ $message->args // [] } } // ();
    my ($channel, $nick) = @_margs_2179[1,2];
    $mediabot->{logger}->log(4, "Invite list for $channel: $nick");
}

sub on_message_RPL_ENDOFINVITELIST {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_ENDOFINVITELIST', $message);
    my $channel = $message->args->[1];
    $mediabot->{logger}->log(4, "End of invite list for $channel");
}

sub on_message_ERR_NEEDMOREPARAMS {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_ERR_NEEDMOREPARAMS', $message);
    my @_margs_2193 = eval { @{ $message->args // [] } } // ();
    my ($me, $cmd) = @_margs_2193[0,1];
    $mediabot->{logger}->log(1, "ERR_NEEDMOREPARAMS for $cmd - vérifiez la syntaxe.");
}

sub reconnect {
    return if $mediabot->{irc_reconnect_in_progress};

    $mediabot->{irc_reconnect_in_progress} = 1;
    $mediabot->{logger}->log(0, "reconnect(): entered");

    # Clear pending async reconnect marker first
    if (my $pending = delete $mediabot->{irc_reconnect_timer}) {
        eval {
            $pending->stop if $pending->can('stop');
            $loop->remove($pending);
        };
    }

    # Pick a (possibly different) IRC server
    $mediabot->pickServer();

    $mediabot->{logger}->log(0, "reconnect(): picked server " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort());

    # Reuse the existing IO::Async loop - do NOT create a new one.
    # This keeps the Partyline listener alive across IRC reconnects.

    # Remove the old IRC object from the loop before adding a fresh one.
    if ($irc) {
        eval { $loop->remove($irc) };
        $irc = undef;
    }

    # NS2: clear in-memory antiflood/cooldown state on reconnect
    # Silenced channels must be reset — they may be joinable again after the split.
    $mediabot->{_af}              = {};  # AF1: outgoing flood state
    $mediabot->{_af_params}       = {};  # AF1: params cache
    $mediabot->{_chan_flood}       = {};  # AF4: input flood state
    $mediabot->{_nick_flood}       = {};  # AF3: per-nick flood state
    $mediabot->{_nick_mute}        = {};  # CC3: auto-mutes
    $mediabot->{_cmd_cooldown}     = {};  # CC1: command cooldowns
    $mediabot->{_netsplit_quit_count} = 0;  # NS1: counter
    $mediabot->{logger}->log(1, 'NS2: antiflood/cooldown state cleared on reconnect');

    # Rebuild nicklist timers on the current loop
    $mediabot->setup_channel_nicklist_timers();

    # Remove old main timer from loop before creating a new one.
    # Without this, each reconnect adds a new timer while the old one
    # stays in the loop -> on_timer_tick fires N times per tick after N restarts.
    my $old_timer = $mediabot->getMainTimerTick();
    if ($old_timer) {
        eval {
            $old_timer->stop if $old_timer->can('stop');
            $loop->remove($old_timer);
        };
    }

    # Fresh timer
    $timer = IO::Async::Timer::Periodic->new(
        interval => 5,
        on_tick  => \&on_timer_tick,
    );
    $mediabot->setMainTimerTick($timer);
    $loop->add($timer);
    $timer->start;

    $mediabot->{logger}->log(0, "reconnect(): building fresh IRC object");

    # Build a fresh IRC object and add it to the existing loop
    my ($new_irc, $new_bind_ip) = _build_irc($loop);
    $irc = $new_irc;
    $mediabot->setIrc($irc);

    $mediabot->{logger}->log(0, "reconnect(): fresh IRC object installed");

    # Refresh connection-related variables from config
    $sConnectionNick     = $mediabot->getConnectionNick();
    $sServerPass         = $mediabot->getServerPass();
    $sServerPassDisplay  = ( $sServerPass eq "" ? "none defined" : "configured (hidden)" );
    $bNickTriggerCommand = $mediabot->getNickTrigger();

    $mediabot->{logger}->log(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

    my $login = _do_login($irc, $new_bind_ip);
    eval { $login->get };
    if ($@) {
        my $err = $@;
        $err =~ s/\n/ /g;
        $mediabot->{logger}->log(0, "Login Future failed: $err");

        # Allow another reconnect attempt later
        $mediabot->{irc_restart_in_progress} = 0;
        $mediabot->{irc_reconnect_requested} = 0;
        $mediabot->{irc_reconnect_in_progress} = 0;

        $mediabot->{logger}->log(0, "reconnect(): completed");
        return;
    }

    $mediabot->{irc_restart_in_progress} = 0;
    $mediabot->{irc_reconnect_requested} = 0;

    $mediabot->{logger}->log(0, "reconnect(): completed");

    return 1;
}

sub catch_hup {
    my ($signal) = @_;
    if ( $mediabot->readConfigFile ) {
        $mediabot->noticeConsoleChan("Caught SIGHUP - configuration reloaded successfully");
    }
    else {
        $mediabot->noticeConsoleChan("Caught SIGHUP - FAILED to reload configuration");
    }
}

sub catch_term {
    my ($signal) = @_;
    log_message(0,"Received SIGTERM (Ctrl+C). Initiating clean shutdown.");
    $mediabot && $mediabot->clean_and_exit(0);
    exit 0;
}

sub catch_int {
    my ($signal) = @_;
    log_message(0,"Received SIGINT (Ctrl+C). Initiating clean shutdown.");
    $mediabot && $mediabot->clean_and_exit(0);
    exit 0;
}