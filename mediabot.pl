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
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Timer::Countdown;
use Net::Async::IRC;
use Switch;
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
        my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || 'http://teuk.org:8000';
        my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio160.mp3';
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

# Set up main timer
my $timer = IO::Async::Timer::Periodic->new(
    interval => 5,
    on_tick  => \&on_timer_tick,
);
$mediabot->setMainTimerTick($timer);
$loop->add($timer);
$timer->start;

# Set up channel hash refresh timer
my $channel_hash_timer = IO::Async::Timer::Periodic->new(
    interval => 60, # toutes les 60 secondes
    on_tick  => sub {
        $mediabot->refresh_channel_hashes;
    },
);
$channel_hash_timer->start;
$loop->add($channel_hash_timer);

# Build IRC object and connect (initial connection)
my ($irc, $bind_ip) = _build_irc($loop);
$mediabot->setIrc($irc);

my $sConnectionNick = $mediabot->getConnectionNick();
my $sServerPass = $mediabot->getServerPass();
my $sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : $sServerPass );
my $bNickTriggerCommand = $mediabot->getNickTrigger();
$mediabot->{logger}->log(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

my $login = _do_login($irc, $bind_ip);
eval { $login->get }; if ($@) { my $err = $@; $err =~ s/\n/ /g; $mediabot->{logger}->log(0, "Login Future failed: $err"); $mediabot->clean_and_exit(1); }

# Start main loop
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
        on_message_ERR_NICKNAMEINUSE     => \&on_message_ERR_NICKNAMEINUSE,
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

        # Bind IP (optional — set CONN_BIND_IP in [connection] section)
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
    log_error("Usage: " . basename($0) . "--conf=<config_file> [--check] [--daemon] [--server=<hostname>]");
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
        unless ($sth->execute()) {
            $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        }
        else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $curChannel = $ref->{'name'};
                $mediabot->{logger}->log(4,"RandomQuote on $curChannel");
                my $sQuery = "SELECT QUOTES.* FROM QUOTES JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel JOIN USER ON USER.id_user = QUOTES.id_user WHERE CHANNEL.name = ? ORDER BY RAND() LIMIT 1";
                my $sth2 = $mediabot->{db}->ensure_connected()->prepare($sQuery);
                unless ($sth2->execute($curChannel)) {
                    $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                }
                else {
                    if (my $ref = $sth2->fetchrow_hashref()) {
                        my $sQuoteId = $ref->{'id_quotes'};
                        my $sQuoteNick = $ref->{'nickname'};
                        my $sQuote = $ref->{'quotetext'};
                        my $id_q = String::IRC->new($sQuoteId)->bold;
                        $mediabot->botPrivmsg($curChannel,"[id: $id_q] $sQuote");
                    }
                }
                $sth2->finish;
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
        elsif (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2 ) && defined($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD') ne "")) {
            if (($who eq "NickServ") && (($what =~ /This nickname is registered/) && defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2))) {
                $mediabot->botPrivmsg("NickServ","identify " . $mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD'));
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
    
    # Undernet : authentication to channel service if credentials are defined
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
        if ($chan->get_description eq 'console') {
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
    unless ((($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1) && ($mediabot->{conf}->get('connection.CONN_USERMODE') =~ /x/)) || (($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2) && defined($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD') ne ""))) {
        $mediabot->joinChannels();
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
        # Auto-join disabled — uncomment to re-enable:
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
    for my $sChannel (keys %hChannelsNicks) {
        $mediabot->channelNicksRemove($sChannel,$sNick);
    }
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
        if ($mediabot->{metrics}) {
            $mediabot->{metrics}->inc(
                'mediabot_channel_lines_in_total',
                { channel => $where }
            );
        }

        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] $where: <$who> $what");
        }
        
        my $line = $what;
        $line =~ s/^\s+//;
        my ($sCommand,@tArgs) = split(/\s+/,$line);
        if (substr($sCommand, 0, 1) eq $mediabot->{conf}->get('main.MAIN_PROG_CMD_CHAR')){
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
        # Private message hide passwords
        unless ( $what =~ /^login|^register|^pass|^newpass|^ident/i) {
            if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
                $mediabot->{logger}->log(0,"[LIVE] $where: <$who> $what");
            }
        }
        my ($sCommand,@tArgs) = split(/\s+/,$what);
        $sCommand =~ tr/A-Z/a-z/;
        $mediabot->{logger}->log(4,"sCommands = $sCommand");
        if (defined($sCommand) && ($sCommand ne "")) {
            switch($sCommand) {
                case /restart/i		{
                    if ($MAIN_PROG_DAEMON) {
                        $mediabot->mbRestart($message,$who,($sFullParams));
                    }
                    else {
                        $mediabot->botNotice($who,"restart command can only be used in daemon mode (use --daemon to launch the bot)");
                    }
                }
                case /jump/i		{
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
    $mediabot->{logger}->log(2,"on_message_LIST() $target_name");
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
        push @{$hChannelsNicks{$target_name}}, $sNick;
        $mediabot->sethChannelNicks(\%hChannelsNicks);
    }
    $mediabot->logBotAction($message,"join",$sNick,$target_name,"");
}
        
sub on_message_001 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_001', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(2,"001 $text");
}
        
sub on_message_002 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_002', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(2,"002 $text");
}
        
sub on_message_003 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_003', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(2,"003 $text");
}
        
# Numeric 004 – Server version/info
sub on_message_004 {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_004', $message);
    my @args = $message->args;
    my $server = $args[0] // '<unknown>';
    my $version = $args[1] // '<unknown>';
    my $user_modes = $args[2] // '';
    my $chan_modes = $args[3] // '';
    $mediabot->{logger}->log(0, "004 server=$server version=$version user_modes=$user_modes chan_modes=$chan_modes");
}
        
# Numeric 005 – ISUPPORT
sub on_message_005 {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_005', $message);
    my @args = $message->args;
    shift @args; # Remove nickname (first arg)
    my $features = join(" ", @args);
    $mediabot->{logger}->log(2, "005 $features");
}
        
sub on_motd {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_motd', $message);
    my @motd_lines = @{$hints}{qw<motd>};
    foreach my $line (@{$motd_lines[0]}) {
        $mediabot->{logger}->log(2,"-motd- $line");
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
    if (defined($WHOIS_VARS{'nick'}) && ($WHOIS_VARS{'nick'} eq $target_name) && defined($WHOIS_VARS{'sub'}) && ($WHOIS_VARS{'sub'} ne "")) {
        switch($WHOIS_VARS{'sub'}) {
            case "userVerifyNick" {
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
            case "userAuthNick" {
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
                            unless ($sth->execute($sMatchingUserHandle)) {
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
            case "userAccessChannel" {
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
                            my $sQuery = "SELECT automode, greet FROM USER JOIN USER_CHANNEL ON USER_CHANNEL.id_user = USER.id_user JOIN CHANNEL ON CHANNEL.id_channel = USER_CHANNEL.id_channel WHERE USER.nickname LIKE ? AND CHANNEL.name = ?";
                            my $sth = $mediabot->{db}->ensure_connected()->prepare($sQuery);
                            unless ($sth->execute($sMatchingUserHandle,$WHOIS_VARS{'channel'})) {
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
            case "mbWhereis" {
                $mediabot->{logger}->log(4,"WHOIS mbWhereis");
                my $country = $mediabot->whereis($sHostname);
                if (defined($country)) {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
                else {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
            }
            case "statPartyline" {
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
    # via IO::Async::Timer::Countdown — let it handle this.
    $mediabot->setServer(undef);

    if ($mediabot->{metrics}) {
        $mediabot->{metrics}->set('mediabot_irc_connected', 0);
        $mediabot->{metrics}->inc('mediabot_irc_reconnect_total');
    }

    $mediabot->{logger}->log(0, "on_message_ERROR: IRC connection lost — on_timer_tick will reconnect");
}

sub on_message_KILL {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_KILL', $message);
    my ($killer, $victim, $reason) = @{ $message->args };
    $mediabot->{logger}->log(0, "Killed by $killer: $reason – will reconnect.");

    if ($mediabot->getQuit()) {
        $mediabot->clean_and_exit(0);
        return;
    }

    # Same as on_message_ERROR: do NOT call $loop->stop.
    # on_timer_tick will detect is_connected=false and schedule reconnect().
    $mediabot->setServer(undef);
    $mediabot->{logger}->log(0, "on_message_KILL: IRC connection lost — on_timer_tick will reconnect");
}

sub on_message_SERVER {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_SERVER', $message);
    $mediabot->{logger}->log(1, "SERVER message: " . join(" ", @{ $message->args }));
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
    my ($chan, $users, $topic) = @{ $message->args };
    $mediabot->{logger}->log(2, "Channel $chan ($users users): $topic");
}

sub on_message_RPL_LISTEND {
    $mediabot->{logger}->log(2, "End of channel list.");
}

sub on_message_RPL_WHOREPLY {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_WHOREPLY', $message);
    $mediabot->{logger}->log(2, "WHO reply: " . join(" ", @{ $message->args }));
}

sub on_message_RPL_ENDOFWHO {
    $mediabot->{logger}->log(2, "End of WHO list.");
}

sub on_message_RPL_WHOISCHANNELS {
    my ($self, $message, $hints) = @_;

    my @args = $message->args;
    my $nick  = $args[1] // '<undef>';
    my $chans = $args[2] // '';

    $mediabot->{logger}->log(2, "$nick on channels: $chans");
}

sub on_message_RPL_WHOISSERVER {
    my ($self, $message, $hints) = @_;

    my @args   = $message->args;
    my $nick   = $args[1] // '';
    my $server = $args[2] // '';
    my $info   = $args[3] // '';
    $mediabot->{logger}->log(2, "$nick server $server ($info)");
}

sub on_message_RPL_WHOISIDLE {
    my ($self, $message, $hints) = @_;

    my @args   = $message->args;
    my $nick   = $args[1] // '';
    my $idle   = $args[2] // 0;
    my $signon = $args[3] // time;
    $mediabot->{logger}->log(2, "$nick idle for ${idle}s, signon: " . scalar localtime($signon));
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
    my @a = @{$message->args};
    $mediabot->{logger}->log(4,"Server info: host=$a[0], ver=$a[1], umodes=$a[2], cmodes=$a[3]");
}

sub on_message_RPL_ISUPPORT {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_ISUPPORT', $message);
    $mediabot->{logger}->log(5, "ISUPPORT tokens: " . join(' ', @{$message->args}));
}

sub on_message_RPL_INVITING {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_INVITING', $message);
    my ($nick, $channel) = @{$message->args}[1,2];
    $mediabot->{logger}->log(2, "You have been invited: $nick -> $channel");
}

sub on_message_RPL_INVITELIST {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_INVITELIST', $message);
    my ($channel, $nick) = @{$message->args}[1,2];
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
    my ($me, $cmd) = @{$message->args}[0,1];
    $mediabot->{logger}->log(1, "ERR_NEEDMOREPARAMS for $cmd – vérifiez la syntaxe.");
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

    # Reuse the existing IO::Async loop — do NOT create a new one.
    # This keeps the Partyline listener alive across IRC reconnects.

    # Remove the old IRC object from the loop before adding a fresh one.
    if ($irc) {
        eval { $loop->remove($irc) };
        $irc = undef;
    }

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
    $sServerPassDisplay  = ( $sServerPass eq "" ? "none defined" : $sServerPass );
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