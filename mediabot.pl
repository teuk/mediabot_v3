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
use Mediabot::Channel;
use Mediabot::Partyline;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::IRC;
use Switch;
use Data::Dumper;
use Encode;

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

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

# Check command line parameters
my $result = GetOptions (
"conf=s" => \$CONFIG_FILE,
"daemon" => \$MAIN_PROG_DAEMON,
"check" => \$MAIN_PROG_CHECK_CONFIG,
"server=s" => \$sServer,
);

unless (defined($CONFIG_FILE)) {
    usage("You must specify a config file");
}

my $mediabot = Mediabot->new({
    config_file => $CONFIG_FILE,
    server => $sServer,
});

# Catch signal TERM
$SIG{TERM} = \&catch_term;

# Catch signal INT
$SIG{INT}  = \&catch_int;

# Load configuration
unless ( $mediabot->readConfigFile ) {
    log_error("ERROR: could not load configuration, aborting.");
    exit 1;
}

# Instantiate Mediabot configuration
$mediabot->{conf} = Mediabot::Conf->new($mediabot->getMainConf());

# Init log file
$mediabot->init_log();

# Instantiate logger
$mediabot->{logger} = Mediabot::Log->new(
    debug_level => $mediabot->{conf}->get('main.MAIN_PROG_DEBUG'),
    logfile     => $mediabot->{conf}->get('main.MAIN_LOG_FILE'),
);

# Display Partyline port in debug log
$mediabot->{logger}->log(3, "Partyline port is: " . $mediabot->{conf}->get("main.PARTYLINE_PORT"));

# === Single‐Instance Guard ===

# Retrieve PID file path and stored PID
my $pidfile = $mediabot->getPidFile();
my $pid     = $mediabot->getPidFromFile();

if (defined $pid && $pid =~ /^\d+$/) {
    
    # kill 0 just tests “does this process exist and can I signal it?”
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

# Check config
if ( $MAIN_PROG_CHECK_CONFIG != 0 ) {
    $mediabot->dumpConfig();
    $mediabot->clean_and_exit(0);
}

log_info("mediabot_v3 Copyright (C) 2019-2025 teuk");
log_info("Mediabot v$MAIN_PROG_VERSION starting with config file $CONFIG_FILE");

# Daemon mode actions
if ( $MAIN_PROG_DAEMON ) {
    $mediabot->{logger}->log(0,"Mediabot v$MAIN_PROG_VERSION starting in daemon mode, check " . $mediabot->getLogFile() . " for more details");
    umask 0;
    open STDIN, '/dev/null'   or die "Can't read /dev/null: $!";
    open STDOUT, '>/dev/null' or die "Can't write to /dev/null: $!";
    open STDERR, '>/dev/null' or die "Can't write to /dev/null: $!";
    defined(my $pid = fork)   or die "Can't fork: $!";
    exit if $pid;
    setsid                    or die "Can't start a new session: $!";
}

# Catch signal HUP
$SIG{HUP}  = \&catch_hup;

my $sStartedMode = ( $MAIN_PROG_DAEMON ? "background" : "foreground");
my $MAIN_PROG_DEBUG = $mediabot->getDebugLevel();
$mediabot->{logger}->log(0,"Mediabot v$MAIN_PROG_VERSION started in $sStartedMode with debug level $MAIN_PROG_DEBUG");

# Database connection
$mediabot->dbConnect();

# Check USER table and fail if not present
$mediabot->dbCheckTables();

# Init authentication object
$mediabot->init_auth();

# Log out all user at start
$mediabot->dbLogoutUsers();

# Populate channels from database
$mediabot->populateChannels();

# Pick IRC Server
$mediabot->pickServer();

# Initialize last_responder_ts
$mediabot->setLastReponderTs(0);

# Initialize hailo
$mediabot->init_hailo();

# Initialize IO::Async loop
my $loop = IO::Async::Loop->new;
$mediabot->setLoop($loop);

# Initialize partyline
my $partyline = Mediabot::Partyline->new(
    bot  => $mediabot,
    loop => $loop,
    port => $mediabot->{conf}->get("main.PARTYLINE_PORT"),
);
$mediabot->{partyline} = $partyline;  # ← optionnel : accès plus tard dans le bot

# Set up main timer
my $timer = IO::Async::Timer::Periodic->new(
interval => 5,
on_tick => \&on_timer_tick,
);
$mediabot->setMainTimerTick($timer);

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

# Set up IRC object
$mediabot->setIrc($irc);

# Add IRC object to the loop
$loop->add($irc);

my $sConnectionNick = $mediabot->getConnectionNick();
my $sServerPass = $mediabot->getServerPass();
my $sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : $sServerPass );
my $bNickTriggerCommand =$mediabot->getNickTrigger();
$mediabot->{logger}->log(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

my $login = $irc->login(
    pass => $sServerPass,
    nick => $sConnectionNick,
    host => $mediabot->getServerHostname(),
    service => $mediabot->getServerPort(),
    user => $mediabot->getUserName(),
    realname => $mediabot->getIrcName(),
    on_login => \&on_login,
);

$login->get;

# Start main loop
$loop->run;

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+
sub usage {
    my ($strErr) = @_;
    if (defined($strErr)) {
        log_error("Error : " . $strErr);
    }
    log_error("Usage: " . basename($0) . "--conf=<config_file> [--check] [--daemon] [--server=<hostname>]");
    exit 4;
}

sub log_timestamp {
    return strftime("[%d/%m/%Y %H:%M:%S]", localtime);
}

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
    
    my $dump = Dumper($message->args);
    $dump =~ s/^\$VAR1 = //;
    $dump =~ s/;\s*$//;
    $mediabot->{logger}->log(5, "$context args: $dump");
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

    $mediabot->{logger}->log(5, "on_timer_tick \@params (): " . Dumper(@params));
    $mediabot->{logger}->log(5,"on_timer_tick() tick");
    
    # Update pid file
    my $sPidFilename = $mediabot->{conf}->get('main.MAIN_PID_FILE');
    unless (open PID, ">$sPidFilename") {
        log_error("Could not open $sPidFilename for writing.");
    }
    else {
        print PID "$$";
        close PID;
    }
    
    # Check connection status and reconnect if not connected
    unless ($irc->is_connected) {
        if ($mediabot->getQuit()) {
            $mediabot->{logger}->log(0,"Disconnected from server");
            $mediabot->clean_and_exit(0);
        }
        else {
            $mediabot->setServer(undef);
            $loop->stop;
            $mediabot->{logger}->log(0,"Lost connection to server. Waiting 150 seconds to reconnect");
            sleep 150;
            reconnect();
        }
    }
    
    # Check channels with chanset +RadioPub
    if (defined($mediabot->{conf}->get('main.MAIN_PID_FILE'))) {
    my $radioPubDelay = defined($mediabot->{conf}->get('radio.RADIO_PUB')) ? $mediabot->{conf}->get('radio.RADIO_PUB') : 10800;
    unless ($radioPubDelay >= 900) {
        $mediabot->{logger}->log(0,"Mediabot was not designed to spam channels, please set RADIO_PUB to a value greater or equal than 900 seconds in [radio] section of $CONFIG_FILE");
    }
    elsif ((time - $mediabot->getLastRadioPub()) > $radioPubDelay ) {
        my $sQuery = "SELECT name FROM CHANNEL,CHANNEL_SET,CHANSET_LIST WHERE CHANNEL.id_channel=CHANNEL_SET.id_channel AND CHANNEL_SET.id_chanset_list=CHANSET_LIST.id_chanset_list AND CHANSET_LIST.chanset LIKE 'RadioPub'";
        my $sth = $mediabot->getDbh->prepare($sQuery);
        unless ($sth->execute()) {
            $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        }
        else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $curChannel = $ref->{'name'};
                $mediabot->{logger}->log(3,"RadioPub on $curChannel");
                my $currentTitle = $mediabot->getRadioCurrentSong();
                if ( $currentTitle ne "Unknown" ) {
                    $mediabot->displayRadioCurrentSong(undef,undef,$curChannel,undef);
                }
                else {
                    $mediabot->{logger}->log(3,"RadioPub skipped for $curChannel, title is $currentTitle");
                }
            }
        }
        $sth->finish;
        $mediabot->setLastRadioPub(time);
    }
}

# Check channels with chanset +RandomQuote
if (defined($mediabot->{conf}->get('main.RANDOM_QUOTE'))) {
    my $randomQuoteDelay = defined($mediabot->{conf}->get('main.RANDOM_QUOTE')) ? $mediabot->{conf}->get('main.RANDOM_QUOTE') : 10800;
    unless ($randomQuoteDelay >= 900) {
        $mediabot->{logger}->log(0,"Mediabot was not designed to spam channels, please set RANDOM_QUOTE to a value greater or equal than 900 seconds in [main] section of $CONFIG_FILE");
    }
    elsif ((time - $mediabot->getLastRandomQuote()) > $randomQuoteDelay ) {
        my $sQuery = "SELECT name FROM CHANNEL,CHANNEL_SET,CHANSET_LIST WHERE CHANNEL.id_channel=CHANNEL_SET.id_channel AND CHANNEL_SET.id_chanset_list=CHANSET_LIST.id_chanset_list AND CHANSET_LIST.chanset LIKE 'RandomQuote'";
        my $sth = $mediabot->getDbh->prepare($sQuery);
        unless ($sth->execute()) {
            $mediabot->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
        }
        else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $curChannel = $ref->{'name'};
                $mediabot->{logger}->log(3,"RandomQuote on $curChannel");
                my $sQuery = "SELECT * FROM QUOTES,CHANNEL,USER WHERE QUOTES.id_channel=CHANNEL.id_channel AND QUOTES.id_user=USER.id_user AND CHANNEL.name=? ORDER BY RAND() LIMIT 1";
                my $sth2 = $mediabot->getDbh->prepare($sQuery);
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
            }
        }
        elsif (defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ( $mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2 ) && defined($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD') ne "")) {
            if (($who eq "NickServ") && (($what =~ /This nickname is registered/) && defined($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE')) && ($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2))) {
                $mediabot->botPrivmsg("NickServ","identify " . $mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD'));
                $mediabot->joinChannels();
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
    $mediabot->setQuit(0);
    $mediabot->setConnectionTimestamp(time);
    $mediabot->setLastRadioPub(time);
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
        $mediabot->{logger}->log(0, "Joining console channel $name");
        $mediabot->joinChannel($name, $key);
    } else {
        $mediabot->{logger}->log(0, "Warning: no console channel found in database (description = 'console'). You may want to run configure script again.");
    }

    # Join other channels
    unless ((($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 1) && ($mediabot->{conf}->get('connection.CONN_USERMODE') =~ /x/)) || (($mediabot->{conf}->get('connection.CONN_NETWORK_TYPE') == 2) && defined($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD')) && ($mediabot->{conf}->get('freenode.FREENODE_NICKSERV_PASSWORD') ne ""))) {
        $mediabot->joinChannels();
    }
    $loop->add( $timer );
    $timer->start;
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
        $mediabot->{logger}->log(0,"* $inviter_nick invites you to join $target_name");
        $mediabot->logBotAction($message,"invite",$inviter_nick,undef,$target_name);
        my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = $mediabot->getNickInfo($message);
        if (defined($iMatchingUserId)) {
            if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
                #if (defined($iMatchingUserLevel) && checkUserLevel(\%MAIN_CONF,$LOG,$dbh,$iMatchingUserLevel,"Master")) {
                #	$mediabot->joinChannel($target_name);
                #	noticeConsoleChan(\%MAIN_CONF,$LOG,$dbh,$irc,"Joined $target_name after $inviter_nick invite (user $sMatchingUserHandle)");
                #}
            }
        }
    }
    else {
        $mediabot->{logger}->log(0,"$invited_nick has been invited to join $target_name");
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
        $mediabot->{logger}->log(0,"* Your nick is now $new_nick");
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
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_PART', $message);
    my ($target_name,$text) = @{$hints}{qw<target_name text>};
    unless(defined($text)) { $text="";}
    my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
    my @tArgs = $message->args;
    shift @tArgs;
    if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] <$target_name> * Parts: $sNick ($sIdent\@$sHost) (" . $tArgs[0] . ")");
        }
        $mediabot->logBotAction($message,"part",$sNick,$target_name,$tArgs[0]);
    }
    else {
        if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE') == 1)) {
            $mediabot->{logger}->log(0,"[LIVE] <$target_name> * Parts: $sNick ($sIdent\@$sHost)");
        }
        $mediabot->logBotAction($message,"part",$sNick,$target_name,"");
        $mediabot->channelNicksRemove($target_name,$sNick);
    }
}

sub on_message_PRIVMSG {
    my ($self, $message, $hints) = @_;

    log_debug_args('on_message_PRIVMSG', $message);
    my ($who, $where, $what) = @{$hints}{qw<prefix_nick targets text>};
    if ( $mediabot->isIgnored($message,$where,$who,$what)) {
        return undef;
    }
    if ( substr($where,0,1) eq '#' ) {
        # Message on channel
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
        elsif ( ( $what =~ /http.*:\/\/www\.youtube\..*\/watch/i ) || ( $what =~ /http.*:\/\/m\.youtube\..*\/watch/i ) || ( $what =~ /http.*:\/\/music\.youtube\..*\/watch/i ) || ( $what =~ /http.*:\/\/youtu\.be.*/i ) ) {
            my $id_chanset_list = $mediabot->getIdChansetList("Youtube");
            if (defined($id_chanset_list)) {
                my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
                if (defined($id_channel_set)) {
                    $mediabot->displayYoutubeDetails($message,$who,$where,$what);
                }
            }
        }
        elsif ( ( $what =~ /http.*:\/\//i ) ) {
            my $id_chanset_list = $mediabot->getIdChansetList("UrlTitle");
            if (defined($id_chanset_list)) {
                my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
                if (defined($id_channel_set)) {
                    $mediabot->displayUrlTitle($message,$who,$where,$what);
                }
            }
        }
        else {
            my $sCurrentNick = $self->nick_folded;
            my $luckyShot = rand(100);
            my $luckyShotHailoChatter = rand(100);
            if ( $luckyShot >= $mediabot->checkResponder($message,$who,$where,$what,@tArgs) ) {
                $mediabot->{logger}->log(3,"Found responder [$where] for $what with luckyShot : $luckyShot");
                $mediabot->{logger}->log(3,"I have a lucky shot to answer for $what");
                $mediabot->{logger}->log(3,"time : " . time . " getLastReponderTs() " . $mediabot->getLastReponderTs() . " delta " . (time - $mediabot->getLastReponderTs()));
                if ((time - $mediabot->getLastReponderTs()) >= 600 ) {
                    sleep int(rand(8)+2);
                    $mediabot->doResponder($message,$who,$where,$what,@tArgs)
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
        $mediabot->{logger}->log(3,"sCommands = $sCommand");
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

sub on_message_TOPIC(@) {
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

sub on_message_LIST(@) {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_LIST', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(2,"on_message_LIST() $target_name");
}

sub on_message_RPL_NAMEREPLY {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_RPL_NAMEREPLY', $message);
    my @args = $message->args;
    $args[3] =~ s/@//g;
    $args[3] =~ s/\+//g;
    my @tNicklist = split(" ",$args[3]);
    my ($target_name) = @{$hints}{qw<target_name>};
    my $bChannelsNicksEnd = $mediabot->gethChannelsNicksEndOnChan($target_name);
    unless ($bChannelsNicksEnd) {
        $mediabot->sethChannelsNicksEndOnChan($target_name,0);
    }
    my @tChannelNicklist = $mediabot->gethChannelsNicksOnChan($target_name);
    if ( $bChannelsNicksEnd ) {
        $mediabot->sethChannelsNicksEndOnChan($target_name,0);
        $mediabot->sethChannelsNicksOnChan($target_name,());
    }
    push(@tChannelNicklist, @tNicklist);
    $mediabot->sethChannelsNicksOnChan($target_name,@tChannelNicklist);
}

# Numeric 366 RPL_ENDOFNAMES
sub on_message_RPL_ENDOFNAMES {
    my ($self,$message,$hints) = @_;

    log_debug_args('on_message_RPL_ENDOFNAMES', $message);
    my @args = $message->args;
    my $channel = $args[1] // '<unknown>';
    $mediabot->{logger}->log(2,"on_message_RPL_ENDOFNAMES() $channel");
    if (defined($mediabot->{conf}->get('main.MAIN_PROG_LIVE')) && ($mediabot->{conf}->get('main.MAIN_PROG_LIVE')==1)) {
        $mediabot->{logger}->log(0,"[LIVE] * Now talking in $channel");
    }
    $mediabot->{logger}->log(2,"Joined channel: $channel");
}

sub on_message_WHO(@) {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHO', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(0,"on_message_WHO() $target_name");
}

sub on_message_WHOIS(@) {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHOIS', $message);
    $mediabot->{logger}->log(3,Dumper($message));
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(0,"on_message_WHOIS() $target_name");
}

sub on_message_WHOWAS {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_WHOWAS', $message);
    my ($target_name) = @{$hints}{qw<target_name>};
    $mediabot->{logger}->log(0,"on_message_WHOWAS() $target_name");
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
    $mediabot->{logger}->log(0,"001 $text");
}
        
sub on_message_002 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_002', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(0,"002 $text");
}
        
sub on_message_003 {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_003', $message);
    my ($text) = @{$hints}{qw<text>};
    $mediabot->{logger}->log(0,"003 $text");
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
    $mediabot->{logger}->log(0, "005 $features");
}
        
sub on_motd {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_motd', $message);
    my @motd_lines = @{$hints}{qw<motd>};
    foreach my $line (@{$motd_lines[0]}) {
        $mediabot->{logger}->log(0,"-motd- $line");
    }
}
    
sub on_message_RPL_WHOISUSER {
    my ($self,$message,$hints) = @_;
    log_debug_args('on_message_RPL_WHOISUSER', $message);
    my %WHOIS_VARS = %{$mediabot->getWhoisVar()};
    my @tArgs = $message->args;
    my $sHostname = $tArgs[3];
    my ($target_name,$ident,$host,$flags,$realname) = @{$hints}{qw<target_name ident host flags realname>};
    $mediabot->{logger}->log(0,"$target_name is $ident\@$sHostname $flags $realname");
    if (defined($WHOIS_VARS{'nick'}) && ($WHOIS_VARS{'nick'} eq $target_name) && defined($WHOIS_VARS{'sub'}) && ($WHOIS_VARS{'sub'} ne "")) {
        switch($WHOIS_VARS{'sub'}) {
            case "userVerifyNick" {
                $mediabot->{logger}->log(3,"WHOIS userVerifyNick");
                my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = $mediabot->getNickInfoWhois("$ident\@$sHostname");
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
                $mediabot->{logger}->log(3,"WHOIS userAuthNick");
                my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = $mediabot->getNickInfoWhois("$ident\@$sHostname");
                if (defined($WHOIS_VARS{'caller'}) && ($WHOIS_VARS{'caller'} ne "")) {
                    if (defined($iMatchingUserId)) {
                        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
                            $mediabot->botNotice($WHOIS_VARS{'caller'},"$target_name is already authenticated as $sMatchingUserHandle ($iMatchingUserLevelDesc)");
                        }
                        else {
                            my $sQuery = "UPDATE USER SET auth=1 WHERE nickname=?";
                            my $sth = $mediabot->getDbh->prepare($sQuery);
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
                $mediabot->{logger}->log(3,"WHOIS userAccessChannel");
                my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = $mediabot->getNickInfoWhois("$ident\@$sHostname");
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
                            my $sQuery = "SELECT automode,greet FROM USER,USER_CHANNEL,CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER.id_user=USER_CHANNEL.id_user AND nickname like ? AND CHANNEL.name=?";
                            my $sth = $mediabot->getDbh->prepare($sQuery);
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
                $mediabot->{logger}->log(3,"WHOIS mbWhereis");
                my $country = $mediabot->whereis($sHostname);
                if (defined($country)) {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
                else {
                    $mediabot->botPrivmsg($WHOIS_VARS{'channel'},"($WHOIS_VARS{'caller'} whereis $WHOIS_VARS{'nick'}) Country : $country");
                }
            }
        }
    }
}

sub on_message_ERROR(@) {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_ERROR', $message);
    $mediabot->{logger}->log(0, "ERROR from server: " . join(" ", @{ $message->args }));
    # optionally $mediabot->clean_and_exit(1);
}

sub on_message_KILL {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_KILL', $message);
    my ($killer, $victim, $reason) = @{ $message->args };
    $mediabot->{logger}->log(0, "Killed by $killer: $reason – will reconnect.");
    # reconnect logic if desired
}

sub on_message_SERVER {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_SERVER', $message);
    $mediabot->{logger}->log(0, "SERVER message: " . join(" ", @{ $message->args }));
}

# Numeric 332 RPL_TOPIC
sub on_message_RPL_TOPIC {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_TOPIC', $message);
    my @args = $message->args;
    my $channel = $args[1] // '<unknown>';
    my $topic   = $args[2] // '<none>';
    $mediabot->{logger}->log(0, "Topic for $channel: $topic");
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
    $mediabot->{logger}->log(0, "Topic for $channel set by $setter on $time");
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
    log_debug_args('on_message_RPL_WHOISCHANNELS', $message);
    my ($nick, $chans) = @{ $message->args };
    $mediabot->{logger}->log(0, "$nick on channels: $chans");
}

sub on_message_RPL_WHOISSERVER {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_WHOISSERVER', $message);
    my ($nick, $server, $info) = @{ $message->args };
    $mediabot->{logger}->log(0, "$nick server $server ($info)");
}

sub on_message_RPL_WHOISIDLE {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_WHOISIDLE', $message);
    my ($nick, $idle, $signon) = @{ $message->args };
    $mediabot->{logger}->log(0, "$nick idle for ${idle}s, signon: " . scalar localtime($signon));
}

sub on_message_ERR_NICKNAMEINUSE {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_ERR_NICKNAMEINUSE', $message);
    my $conflict = $message->args->[1] // '';
    my $new_nick = $self->nick_folded . "_";
    $self->change_nick($new_nick);
    $mediabot->{logger}->log(0, "Nick “$conflict” in use, switched to $new_nick");
}

sub on_message_RPL_MYINFO {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_MYINFO', $message);
    # args = [ servername, version, user_modes, chan_modes ]
    my @a = @{$message->args};
    $mediabot->{logger}->log(4,"Server info: host=$a[0], ver=$a[1], umodes=$a[2], cmodes=$a[3]");
}

sub on_message_RPL_ISUPPORT {
    my ($self, $message, $hints) = @_;
    log_debug_args('on_message_RPL_ISUPPORT', $message);
    # args = [ token1, token2, … ]
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
    # args = [ your_nick, command, "Not enough parameters" ]
    my ($me, $cmd) = @{$message->args}[0,1];
    $mediabot->{logger}->log(1, "ERR_NEEDMOREPARAMS for $cmd – vérifiez la syntaxe.");
}

sub reconnect {
    # Pick IRC Server
    $mediabot->pickServer();
        
    $loop = IO::Async::Loop->new;
    $mediabot->setLoop($loop);
        
    $timer = IO::Async::Timer::Periodic->new(
    interval => 5,
    on_tick => \&on_timer_tick,
    );
    $mediabot->setMainTimerTick($timer);
    
    $irc = Net::Async::IRC->new(
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

    $mediabot->setIrc($irc);
    
    $loop->add($irc);
    
    $sConnectionNick = $mediabot->getConnectionNick();
    $sServerPass = $mediabot->getServerPass();
    $sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : $sServerPass );
    $bNickTriggerCommand =$mediabot->getNickTrigger();
    $mediabot->{logger}->log(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");
    
    $login = $irc->login(
        pass => $sServerPass,
        nick => $sConnectionNick,
        host => $mediabot->getServerHostname(),
        service => $mediabot->getServerPort(),
        user => $mediabot->getUserName(),
        realname => $mediabot->getIrcName(),
        on_login => \&on_login,
    );

    $login->get;
    
    # Start main loop
    $loop->run;
}

sub catch_hup {
    my ($signal) = @_;    # you can inspect $signal if you like
    if ( $mediabot->readConfigFile ) {
        $mediabot->noticeConsoleChan("Caught SIGHUP - configuration reloaded successfully");
    }
    else {
        $mediabot->noticeConsoleChan("Caught SIGHUP - FAILED to reload configuration");
    }
}

sub catch_term {
    my ($signal) = @_;    # you can inspect $signal if you like
    log_message(0,"Received SIGTERM (Ctrl+C). Initiating clean shutdown.");
    $mediabot && $mediabot->clean_and_exit(0);
    exit 0;
}

sub catch_int {
    my ($signal) = @_;    # you can inspect $signal if you like
    log_message(0,"Received SIGINT (Ctrl+C). Initiating clean shutdown.");
    $mediabot && $mediabot->clean_and_exit(0);
    exit 0;
}
