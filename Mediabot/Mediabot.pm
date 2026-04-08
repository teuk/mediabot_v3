package Mediabot;
 
use strict;
use warnings;
use diagnostics;
use Mediabot::Auth;
use Mediabot::User;
use Mediabot::Channel;
use Mediabot::Conf;
use Mediabot::Log;
use Mediabot::Context;
use Mediabot::Command;
use Mediabot::Hailo;
use Mediabot::Quotes;
use Mediabot::LoginCommands;
use Mediabot::Helpers;
use Mediabot::ChannelCommands;
use Mediabot::UserCommands;
use Mediabot::Radio;
use Mediabot::External;
use Mediabot::DBCommands;
use Mediabot::AdminCommands;
use Time::HiRes qw(usleep);
use Config::Simple;
use Date::Parse;
use DBI;
use Switch;
use Memory::Usage;
use IO::Async::Timer::Periodic;
use String::IRC;
use POSIX qw(setsid strftime);
use DateTime;
use DateTime::TimeZone;
use utf8;
use HTML::Tree;
use URL::Encode qw(url_encode_utf8 url_encode url_decode_utf8);
use HTML::Entities '%entity2char';
# Let's comment this out for now (in case noone reads the README)
#use MP3::Tag;
use File::Basename;
use Encode;
use Moose;
use Hailo;
use Socket;
use Twitter::API;
use JSON::MaybeXS;
use Try::Tiny;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use List::Util qw/min/;
use Carp qw(croak);
use HTTP::Tiny;


# --- Top of Mediabot.pm (near other 'my' / 'our' declarations)
my $ALREADY_EXITING = 0;  # re-entrance guard for clean_and_exit

# Constructor for Mediabot object
sub new {
    my ($class, $args) = @_;

    my $self = bless {
        config_file => $args->{config_file} // undef,
        server      => $args->{server}      // undef,
        dbh         => $args->{dbh}         // undef,
        conf        => $args->{conf}        // undef,
        channels    => {},
        WHOIS_VARS  => {},
    }, $class;

    # Minimal logging setup
    require Mediabot::Log;
    $self->{logger} = Mediabot::Log->new(
        debug_level => 0,
        logfile     => undef
    );

    return $self;
}



# Log info with timestamp
sub my_log_info {
    my ($self, $msg) = @_;
    my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
    print STDOUT "$ts [INFO] $msg\n";
}

# Log error with timestamp
sub my_log_error {
    my ($self, $msg) = @_;
    my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
    print STDERR "$ts [ERROR] $msg\n";
}

# Read the configuration file and populate the $self->{conf} object
sub readConfigFile {
    my ($self, $file) = @_;

    $file //= $self->{config_file}
        or croak "No config file specified (\$self->{config_file} is empty)";

    unless (-e $file) {
        $self->my_log_error("Config file '$file' does not exist");
        return;
    }
    unless (-r $file) {
        $self->my_log_error("Cannot read config file '$file'");
        return;
    }

    $self->my_log_info("Loading configuration from '$file'");

    my $conf;
    eval {
        require Mediabot::Conf;
        $conf = Mediabot::Conf->new(undef, $file);
    };
    if ($@ or not $conf) {
        $self->my_log_error("Failed to load configuration: $@");
        return;
    }

    $self->{conf} = $conf;

    $self->my_log_info("Configuration loaded successfully");
    return 1;
}

# get debug level from configuration
sub getDebugLevel {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_PROG_DEBUG');
}

# Get the log file path from the configuration
sub getLogFile {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_LOG_FILE');
}

# Dump the configuration to STDERR
sub dumpConfig {
    my ($self) = @_;

    my %conf = $self->{conf}->all;
    return unless %conf;

    print STDERR "\e[1m=== Mediabot configuration dump ===\e[0m\n";

    foreach my $key (sort keys %conf) {
        my $val = $conf{$key};

        # Formattage section.clé en deux parties si souhaité
        if ($key =~ /^(.+?)\.(.+)$/) {
            my ($section, $subkey) = ($1, $2);
            printf STDERR "  \e[1;36m[%s]\e[0m \e[1;33m%-18s\e[0m : %s\n", $section, $subkey, _format_val($val);
        } else {
            printf STDERR "  \e[1;34m%-20s\e[0m : %s\n", $key, _format_val($val);
        }
    }

    print STDERR "\n\e[1m===================================\e[0m\n";
}

# Format a single value with color
sub _format_val {
    my ($val) = @_;
    return "\e[31m(undef)\e[0m" unless defined $val;
    return "\e[33m[empty]\e[0m" if $val eq '';
    return "\e[32m$val\e[0m";
}

# Get the main configuration object
sub getMainConfCfg {
    my $self = shift;
    return $self->{conf};
}

# Get pid file path from configuration
sub getPidFile {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_PID_FILE');
}

# Write the current process ID to the PID file
sub writePidFile {
    my ($self) = @_;
    my $pidfile = $self->getPidFile();
    open my $fh, '>', $pidfile or do {
        $self->{logger}->log(0, "Failed to write PID file '$pidfile': $!");
        return 0;
    };
    print $fh $$;
    close $fh;
    return 1;
}

# Get PID from the PID file
sub getPidFromFile {
    my $self = shift;
    my $pidfile = $self->{conf}->get('main.MAIN_PID_FILE');

    my $fh_pid;
    unless (open $fh_pid, '<', $pidfile) {
        return undef;
    }
    my $line;
    if (defined($line = <$fh_pid>)) {
        chomp($line);
        close $fh_pid;
        return $line;
    }
    else {
        $self->{logger}->log(1, "getPidFromFile() couldn't read PID from $pidfile");
        close $fh_pid;
        return undef;
    }
}

# Initialize the log file for Mediabot
sub init_log {
    my ($self) = @_;

    my $log_path = $self->{conf}->get('main.MAIN_LOG_FILE');
    unless (defined $log_path && $log_path ne '') {
        print STDERR "[ERROR] Log file path not defined in config.\n";
        clean_and_exit($self, 1);
    }

    open(my $LOG, ">>", $log_path) or do {
        print STDERR "[ERROR] Could not open log file '$log_path' for writing: $!\n";
        clean_and_exit($self, 1);
    };

    # Autoflush enabled
    select((select($LOG), $| = 1)[0]);

    # Optional: timestamp or header
    print $LOG "+--------------------------------------------------------------------------------+\n";
    print $LOG "| Mediabot log started at " . scalar(localtime) . "\n";
    print $LOG "+--------------------------------------------------------------------------------+\n";

    # Store filehandle in object
    $self->{LOG} = $LOG;
}


# Populate the channels from the database and create Channel objects
sub populateChannels {
    my ($self) = @_;

    $self->{logger}->log( 3, "populateChannels: Populating channels from database");

    my $sQuery = "SELECT id_channel, name, description, topic, tmdb_lang, `key`, auto_join FROM CHANNEL";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute()) {
        $self->{logger}->log( 1, "SQL Error: " . $DBI::errstr . " Query: $sQuery");
        return;
    }

    my $i = 0;
    while (my $ref = $sth->fetchrow_hashref()) {
        $i++ == 0 and $self->{logger}->log( 0, "Populating channel objects");

        my $channel_obj = Mediabot::Channel->new({
            id          => $ref->{id_channel},
            name        => $ref->{name},
            description => $ref->{description},
            topic       => $ref->{topic},
            tmdb_lang   => $ref->{tmdb_lang},
            key         => $ref->{key},
            dbh         => $self->{dbh},
            irc         => $self->{irc},
            logger      => $self->{logger},
            auto_join   => $ref->{auto_join},
        });

        $self->{channels}{ $ref->{name} } = $channel_obj;
    }

    $sth->finish;

    if ($i == 0) {
        $self->{logger}->log( 0, "No channel found in database.");
    }
}

# Clean up resources and exit the program with the given return value
sub clean_and_exit {
    my ($self, $iRetValue) = @_;
    $iRetValue = 0 unless defined $iRetValue;

    # Re-entrance guard without 'state'
    if ($ALREADY_EXITING) { CORE::exit($iRetValue); }
    $ALREADY_EXITING = 1;

    # Log if possible (best-effort)
    eval {
        $self->{logger}->log(1, "Cleaning and exiting...")
            if $self->{logger} && $self->{logger}->can('log');
        1;
    };

    # --- Graceful IRC QUIT via Net::Async::IRC ---
    eval {
        my $irc = $self->{irc};
        if ($irc) {
            my $quit_msg = "Mediabot shutting down";
            if ($self->{conf} && $self->{conf}->can('get')) {
                my $cfg = eval { $self->{conf}->get('IRC_QUIT_MESSAGE') };
                $quit_msg = $cfg if defined($cfg) && $cfg ne '';
            }
            $irc->can('do_QUIT') ? $irc->do_QUIT( reason => $quit_msg )
                                 : 0;
        }
        1;
    };

    # --- DB: safe disconnect ---
    eval {
        if (defined $self->{dbh} && $self->{dbh}) {
            if ($iRetValue != 1146) { } # keep original no-op
            my $dbh = $self->{dbh};
            if (ref($dbh) && eval { $dbh->{Active} }) {
                eval { $dbh->disconnect(); 1 };
            }
        }
        1;
    };

    # --- Raw LOG filehandle: safe close ---
    eval {
        if (defined $self->{LOG}) {
            my $fh = $self->{LOG};
            if (defined(fileno($fh))) {
                eval { local $| = 1; 1; }; # opportunistic flush
                close $fh;
            }
        }
        1;
    };

    # --- Flush object logger if available ---
    eval {
        $self->{logger}->flush()
            if $self->{logger} && $self->{logger}->can('flush');
        1;
    };

    CORE::exit($iRetValue);
}


# Connect to the database
sub dbConnect {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $LOG  = $self->{LOG};

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME');
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') // 'localhost';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') // 3306;
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER');
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS');

    my $connectionInfo = "DBI:MariaDB:database=$dbname;host=$dbhost;port=$dbport";

    $self->{logger}->log( 1, "dbConnect() Connecting to Database: $dbname");

    my $dbh;
    unless ($dbh = DBI->connect($connectionInfo, $dbuser, $dbpass, { RaiseError => 0, PrintError => 0 })) {
        $self->{logger}->log( 0, "dbConnect() DBI Error: " . $DBI::errstr);
        $self->{logger}->log( 0, "dbConnect() DBI Native error code: " . ($DBI::err // 'undef'));
        clean_and_exit($self, 3) if defined $DBI::err;
    }

    $dbh->{mariadb_auto_reconnect} = 1;
    $self->{logger}->log( 1, "dbConnect() Connected to $dbname.");

    foreach my $sql (
        "SET NAMES 'utf8'",
        "SET CHARACTER SET utf8",
        "SET COLLATION_CONNECTION = 'utf8_general_ci'"
    ) {
        my $sth = $dbh->prepare($sql);
        unless ($sth->execute()) {
            $self->{logger}->log( 1, "dbConnect() SQL Error: $DBI::errstr Query: $sql");
        }
        $sth->finish;
    }

    $self->{dbh} = $dbh;
}

# Get the database handle
sub getDbh {
	my $self = shift;
	return $self->{dbh};
}

# Check if the USER table exists in the database
sub dbCheckTables {
    my ($self) = shift;
    my $LOG = $self->{LOG};
    my $dbh = $self->{dbh};

    $self->{logger}->log(4, "Checking database schema");

    unless (defined $dbh) {
        $self->{logger}->log(0, "❌ No DBI handle found (dbh is undef). Aborting DB check.");
        $self->{logger}->log(0, "Check your database credentials in mediabot.conf and ensure the user has proper access.");
        clean_and_exit($self, 1);
    }

    # Check USER table exists
    my $sth = $dbh->prepare("SELECT 1 FROM USER LIMIT 1");
    unless ($sth->execute) {
        $self->{logger}->log(0, "dbCheckTables() SQL Error: $DBI::errstr ($DBI::err)");
        if (defined($DBI::err) && $DBI::err == 1146) {
            $self->{logger}->log(0, "USER table does not exist. Check your database installation.");
            clean_and_exit($self, 1146);
        }
    }
    else {
        $self->{logger}->log(4, "USER table exists");
    }
    $sth->finish;

    # Check USER_HOSTMASK table exists — required since schema migration
    # If missing, the bot cannot match user hostmasks and auth will be broken.
    my $hm_sth = $dbh->prepare(
        "SELECT 1 FROM INFORMATION_SCHEMA.TABLES " .
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER_HOSTMASK' LIMIT 1"
    );
    $hm_sth->execute;
    my $hm_exists = $hm_sth->fetchrow_arrayref;
    $hm_sth->finish;

    unless ($hm_exists) {
        $self->{logger}->log(0, "");
        $self->{logger}->log(0, "═" x 65);
        $self->{logger}->log(0, "  DATABASE MIGRATION REQUIRED");
        $self->{logger}->log(0, "═" x 65);
        $self->{logger}->log(0, "  The USER_HOSTMASK table is missing.");
        $self->{logger}->log(0, "  Your database schema needs to be migrated before");
        $self->{logger}->log(0, "  the bot can start.");
        $self->{logger}->log(0, "");
        $self->{logger}->log(0, "  Run as root:");
        $self->{logger}->log(0, "    sudo ./install/db_migrate.sh -c mediabot.conf");
        $self->{logger}->log(0, "═" x 65);
        $self->{logger}->log(0, "");
        clean_and_exit($self, 1);
    }

    $self->{logger}->log(4, "USER_HOSTMASK table exists — schema OK");

    # Check USER.hostmasks column is gone (renamed to hostmasks_legacy)
    # This is a soft warning only — the bot can still run.
    my $col_sth = $dbh->prepare(
        "SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS " .
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER' AND COLUMN_NAME = 'hostmasks' LIMIT 1"
    );
    $col_sth->execute;
    if ($col_sth->fetchrow_arrayref) {
        $self->{logger}->log(0, "⚠ USER.hostmasks column still present (not yet renamed to hostmasks_legacy).");
        $self->{logger}->log(0, "  Run sudo ./install/db_migrate.sh -c mediabot.conf to complete migration.");
    }
    $col_sth->finish;
}

# Set the server hostname
sub setServer {
	my ($self,$sServer) = @_;
	$self->{server} = $sServer;
}

# Pick a server from the database based on the configured network
sub pickServer {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $dbh  = $self->{dbh};

    if (!defined($self->{server}) || $self->{server} eq "") {
        my $network_name = $conf->get('connection.CONN_SERVER_NETWORK');

        unless ($network_name) {
            $self->{logger}->log(0, "No CONN_SERVER_NETWORK defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        my $sQuery = "SELECT SERVERS.server_hostname FROM NETWORK JOIN SERVERS ON SERVERS.id_network = NETWORK.id_network WHERE NETWORK.network_name = ? ORDER BY RAND() LIMIT 1";
        my $sth = $dbh->prepare($sQuery);
        if ($sth->execute($network_name)) {
            if (my $ref = $sth->fetchrow_hashref()) {
                $self->{server} = $ref->{server_hostname};
            }
            $sth->finish;
        } else {
            $self->{logger}->log(0, "Startup select SERVER, SQL Error: " . $DBI::errstr . " Query: $sQuery");
        }

        unless ($self->{server}) {
            $self->{logger}->log(0, "No server found for network $network_name defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        $self->{logger}->log(1, "Picked $self->{server} from Network $network_name");
    } else {
        $self->{logger}->log(1, "Picked $self->{server} from command line");
    }

    # Parse hostname[:port]
    if ($self->{server} =~ /:/) {
        ($self->{server_hostname}, $self->{server_port}) = split(/:/, $self->{server}, 2);
    } else {
        $self->{server_hostname} = $self->{server};
        $self->{server_port} = 6667;
    }

    $self->{logger}->log(4, "Using host $self->{server_hostname}, port $self->{server_port}");
}

# Log a hint to run ./configure if no server is set
sub _log_configure_hint {
    my ($self) = @_;
    $self->{logger}->log(1, "Run ./configure at first use or ./configure -s to set it properly");
}

# Get server hostname 
sub getServerHostname {
	my $self = shift;
	return $self->{server_hostname};
}

# Get server port
sub getServerPort {
	my $self = shift;
	return $self->{server_port};
}

# Set loop
sub setLoop {
	my ($self,$loop) = @_;
	$self->{loop} = $loop;
}

# Get loop
sub getLoop {
	my $self = shift;
	return $self->{loop};
}

# Refresh channel information from the database and update the Channel objects
sub refresh_channel_hashes {
    my ($self) = @_;

    $self->{logger}->log(4, "Refreshing channel information from database");

    my $sQuery = "SELECT name, description, topic, tmdb_lang, `key` FROM CHANNEL";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute()) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " Query: $sQuery");
        return;
    }

    my %db_info;
    while (my $ref = $sth->fetchrow_hashref()) {
        $db_info{ $ref->{name} } = $ref;
    }
    $sth->finish;

    foreach my $chan_name (keys %{ $self->{channels} }) {
        my $chan_obj = $self->{channels}{$chan_name};

        if (exists $db_info{$chan_name}) {
            my $ref = $db_info{$chan_name};

            # fields to update
            $chan_obj->{description} = $ref->{description};
            $chan_obj->{topic}       = $ref->{topic};
            $chan_obj->{tmdb_lang}   = $ref->{tmdb_lang};
            $chan_obj->{key}         = $ref->{key};

            $self->{logger}->log(4, "Refreshed data for $chan_name");
        } else {
            $self->{logger}->log(1, "Channel $chan_name not found in DB during refresh");
        }
    }
}

# Set IRC object
sub setIrc {
	my ($self,$irc) = @_;
	$self->{irc} = $irc;
}

# Get IRC object
sub getIrc {
	my $self = shift;
	return $self->{irc};
}

# Get connection nick
sub getConnectionNick {
	my $self = shift;
	my $conf = $self->{conf};

	my $sConnectionNick = $conf->get('connection.CONN_NICK');
	my $network_type    = $conf->get('connection.CONN_NETWORK_TYPE');
	my $usermode        = $conf->get('connection.CONN_USERMODE');

	if (defined($network_type) && $network_type == 1 && defined($usermode) && $usermode =~ /x/) {
		my @chars = ("A".."Z", "a".."z");
		my $string;
		$string .= $chars[rand @chars] for 1..8;
		$sConnectionNick = $string . (int(rand(100)) + 10);
	}

	$self->{logger}->log( 0, "Connection nick: $sConnectionNick");
	return $sConnectionNick;
}

# Get server password
sub getServerPass {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_PASS') // "";
}

# Get nick trigger status
sub getNickTrigger {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('main.NICK_TRIGGER') // 0;
}

# Get IRC username from configuration
sub getIrcName {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_IRCNAME');
}

# Get nick info from a message
sub getMessageNickIdentHost {
	my ($self,$message) = @_;
	my $sNick = $message->prefix;
	$sNick =~ s/!.*$//;
	my $sIdent = $message->prefix;
	$sIdent =~ s/^.*!//;
	$sIdent =~ s/@.*$//;
	my $sHost = $message->prefix;
	$sHost =~ s/^.*@//;
	return ($sNick,$sIdent,$sHost);
}

# DEPRECATED: use $self->{channels}{$name}->get_id instead
sub joinChannels {
    my ($self) = @_;

    my $i = 0;
    foreach my $chan (values %{ $self->{channels} }) {
        next unless $chan->get_auto_join;
        next if ($chan->get_description // '') eq 'console';

        $i++ == 0 and $self->{logger}->log( 0, "Auto join channels");

        my $name = $chan->get_name;
        my $key  = $chan->get_key;

        joinChannel($self, $name, $key);
        $self->{logger}->log( 2, "Joining channel $name");
    }

    $i == 0 and $self->{logger}->log( 0, "No channel to auto join");
}

# Handle public commands
sub mbCommandPublic {
    my ($self, $message, $sChannel, $sNick, $botNickTriggered, $sCommand, @tArgs) = @_;

    # Normalize command once
    my $cmd = lc $sCommand;

    # Build Context once for all handlers
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => $cmd,
        args    => \@tArgs,
    );

    # Attach a Command object to the Context for handlers that want it
    $ctx->{command_obj} = Mediabot::Command->new(
        name    => $cmd,
        args    => \@tArgs,
        raw     => join(" ", $sCommand, @tArgs),
        context => $ctx,
        source  => 'public',
    );

    # ---------------------------------------------------------------------------
    # Command dispatch table
    # All handlers receive a Mediabot::Context object
    # ---------------------------------------------------------------------------
    my %command_map = (
        die          => sub { mbQuit_ctx($ctx) },
        nick         => sub { mbChangeNick_ctx($ctx) },
        addtimer     => sub { mbAddTimer_ctx($ctx) },
        remtimer     => sub { mbRemTimer_ctx($ctx) },
        timers       => sub { mbTimers_ctx($ctx) },
        msg          => sub { msgCmd_ctx($ctx) },
        say          => sub { sayChannel_ctx($ctx) },
        act          => sub { actChannel_ctx($ctx) },
        cstat        => sub { userCstat_ctx($ctx) },
        status       => sub { mbStatus_ctx($ctx) },
        echo         => sub { mbEcho($ctx) },
        adduser      => sub { addUser_ctx($ctx) },
        deluser      => sub { delUser_ctx($ctx) },
        users        => sub { userStats_ctx($ctx) },
        userinfo     => sub { userInfo_ctx($ctx) },
        addhost      => sub { addUserHost_ctx($ctx) },
        addchan      => sub { addChannel_ctx($ctx) },
        chanset      => sub { channelSet_ctx($ctx) },
        purge        => sub { purgeChannel_ctx($ctx) },
        part         => sub { channelPart_ctx($ctx) },
        join         => sub { channelJoin_ctx($ctx) },
        add          => sub { channelAddUser_ctx($ctx) },
        del          => sub { channelDelUser_ctx($ctx) },
        modinfo      => sub { userModinfo_ctx($ctx) },
        op           => sub { userOpChannel_ctx($ctx) },
        deop         => sub { userDeopChannel_ctx($ctx) },
        invite       => sub { userInviteChannel_ctx($ctx) },
        voice        => sub { userVoiceChannel_ctx($ctx) },
        devoice      => sub { userDevoiceChannel_ctx($ctx) },
        kick         => sub { userKickChannel_ctx($ctx) },
        showcommands => sub { userShowcommandsChannel_ctx($ctx) },
        chaninfo     => sub { userChannelInfo_ctx($ctx) },
        chanlist     => sub { channelList_ctx($ctx) },
        whoami       => sub { userWhoAmI_ctx($ctx) },
        auth         => sub { userAuthNick_ctx($ctx) },
        verify       => sub { userVerifyNick_ctx($ctx) },
        access       => sub { userAccessChannel_ctx($ctx) },
        addcmd       => sub { mbDbAddCommand_ctx($ctx) },
        remcmd       => sub { mbDbRemCommand_ctx($ctx) },
        modcmd       => sub { mbDbModCommand_ctx($ctx) },
        mvcmd        => sub { mbDbMvCommand_ctx($ctx) },
        chowncmd     => sub { mbChownCommand_ctx($ctx) },
        showcmd      => sub { mbDbShowCommand_ctx($ctx) },
        chanstatlines => sub { channelStatLines_ctx($ctx) },
        whotalk      => sub { whoTalk_ctx($ctx) },
        whotalks     => sub { whoTalk_ctx($ctx) },
        countcmd     => sub { mbCountCommand_ctx($ctx) },
        topcmd       => sub { mbTopCommand_ctx($ctx) },
        popcmd       => sub { mbPopCommand_ctx($ctx) },
        searchcmd    => sub { mbDbSearchCommand_ctx($ctx) },
        lastcmd      => sub { mbLastCommand_ctx($ctx) },
        owncmd       => sub { mbDbOwnersCommand_ctx($ctx) },
        holdcmd      => sub { mbDbHoldCommand_ctx($ctx) },
        addcatcmd    => sub { mbDbAddCategoryCommand_ctx($ctx) },
        chcatcmd     => sub { mbDbChangeCategoryCommand_ctx($ctx) },
        topsay       => sub { userTopSay_ctx($ctx) },
        checkhostchan => sub { mbDbCheckHostnameNickChan_ctx($ctx) },
        checkhost    => sub { mbDbCheckHostnameNick_ctx($ctx) },
        checknick    => sub { mbDbCheckNickHostname_ctx($ctx) },
        greet        => sub { userGreet_ctx($ctx) },
        nicklist     => sub { channelNickList_ctx($ctx) },
        rnick        => sub { randomChannelNick_ctx($ctx) },
        birthdate    => sub { displayBirthDate_ctx($ctx) },
        colors       => sub { mbColors_ctx($ctx) },
        seen         => sub { mbSeen_ctx($ctx) },
        date         => sub { displayDate_ctx($ctx) },
        weather      => sub { displayWeather_ctx($ctx) },
        meteo        => sub { displayWeather_ctx($ctx) },
        addbadword   => sub { channelAddBadword_ctx($ctx) },
        rembadword   => sub { channelRemBadword_ctx($ctx) },
        ignores      => sub { IgnoresList_ctx($ctx) },
        ignore       => sub { addIgnore_ctx($ctx) },
        unignore     => sub { delIgnore_ctx($ctx) },
        yt           => sub { youtubeSearch_ctx($ctx) },
        song         => sub { displayRadioCurrentSong_ctx($ctx) },
        listeners    => sub { displayRadioListeners_ctx($ctx) },
        nextsong     => sub { radioNext_ctx($ctx) },
        addresponder => sub { addResponder_ctx($ctx) },
        delresponder => sub { delResponder_ctx($ctx) },
        lastcom      => sub { lastCom_ctx($ctx) },
        q            => sub { mbQuotes_ctx($ctx) },
        moduser      => sub { mbModUser_ctx($ctx) },
        antifloodset => sub { setChannelAntiFloodParams_ctx($ctx) },
        leet         => sub { displayLeetString_ctx($ctx) },
        rehash       => sub { mbRehash_ctx($ctx) },
        mp3          => sub { mp3_ctx($ctx) },
        exec         => sub { mbExec_ctx($ctx) },
        qlog         => sub { mbChannelLog_ctx($ctx) },
        hailo_ignore   => sub { hailo_ignore_ctx($ctx) },
        hailo_unignore => sub { hailo_unignore_ctx($ctx) },
        hailo_status   => sub { hailo_status_ctx($ctx) },
        hailo_chatter  => sub { hailo_chatter_ctx($ctx) },
        whereis      => sub { mbWhereis_ctx($ctx) },
        birthday     => sub { userBirthday_ctx($ctx) },
        f            => sub { fortniteStats_ctx($ctx) },
        xlogin       => sub { xLogin_ctx($ctx) },
        tellme       => sub { chatGPT_ctx($ctx) },
        yomomma      => sub { Yomomma_ctx($ctx) },
        resolve      => sub { mbResolver_ctx($ctx) },
        tmdb         => sub { mbTMDBSearch_ctx($ctx) },
        tmdblangset  => sub { setTMDBLangChannel_ctx($ctx) },
        debug        => sub { debug_ctx($ctx) },
        version      => sub { versionCheck($ctx) },
        help         => sub { mbHelp_ctx($ctx) },
        spike        => sub { $ctx->reply("https://teuk.org/In_Spike_Memory.jpg") },
        update       => sub { update_ctx($ctx) },
        play         => sub { playRadio_ctx($ctx) },
        rplay        => sub { rplayRadio_ctx($ctx) },
        queue        => sub { queueRadio_ctx($ctx) },
        next         => sub { nextRadio_ctx($ctx) },
    );

    # Dispatch known command
    if (my $handler = $command_map{$cmd}) {
        $self->{logger}->log(4, "PUBLIC: $sNick triggered $sCommand on $sChannel");
        $handler->();
        return;
    }

    # Check database for custom commands
    my $bFound = mbDbCommand($self, $message, $sChannel, $sNick, $sCommand, @tArgs);
    return if $bFound;

    # Bot nick triggered — natural language / Hailo fallback
    if ($botNickTriggered) {
        mbHandleNickTriggered($ctx, join(" ", $sCommand, @tArgs));
    } else {
        $self->{logger}->log(4, "Public command '$sCommand' not found");
    }
}

# Handle help command
sub mbHelp_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $channel = $ctx->channel;
    my @args    = @{ $ctx->args };

    if (defined $args[0] && $args[0] ne "") {
        botPrivmsg($self, $channel,
            "Help on command $args[0] is not available (unknown command ?). "
            . "Please visit https://github.com/teuk/mediabot_v3/wiki");
    } else {
        botPrivmsg($self, $channel,
            "Please visit https://github.com/teuk/mediabot_v3/wiki for full documentation on mediabot");
    }
}

# Handle bot nick triggered messages — natural patterns + Hailo fallback
sub mbHandleNickTriggered {
    my ($ctx, $what) = @_;

    my $self     = $ctx->bot;
    my $sNick    = $ctx->nick;
    my $sChannel = $ctx->channel;

    if ($what =~ /how\s+old\s+(are|r)\s+(you|u)/i) {
        displayBirthDate_ctx($ctx);
    }
    elsif ($what =~ /who.*(your daddy|is your daddy)/i) {
        my $owner = getChannelOwner($self, $sChannel);
        my $reply = defined $owner && $owner ne ""
            ? "Well I'm registered to $owner on $sChannel, but Te[u]K's my daddy"
            : "I have no clue of who is $sChannel\'s owner, but Te[u]K's my daddy";
        botPrivmsg($self, $sChannel, $reply);
    }
    elsif ($what =~ /^(thx|thanx|thank you|thanks)$/i) {
        botPrivmsg($self, $sChannel, "you're welcome $sNick");
    }
    elsif ($what =~ /who.*StatiK/i) {
        botPrivmsg($self, $sChannel, "StatiK is my big brother $sNick, he's awesome !");
    }
    else {
        # 🧠 Hailo fallback
        my $id_chanset_list = getIdChansetList($self, "Hailo");
        my $id_channel_set  = getIdChannelSet($self, $sChannel, $id_chanset_list);

        unless (
            is_hailo_excluded_nick($self, $sNick)
            || $what =~ /^[!]/
            || $what =~ /^@{[$self->{conf}->get('main.MAIN_PROG_CMD_CHAR')]}/
        ) {
            my $hailo        = get_hailo($self);
            my $sCurrentNick = $self->{irc}->nick_folded;
            $what =~ s/\Q$sCurrentNick\E//g;

            $what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });

            my $sAnswer = $hailo->learn_reply($what);

            if (defined $sAnswer && $sAnswer ne "" && $sAnswer !~ /^\Q$what\E\s*\.$/i) {
                $self->{logger}->log(4, "learn_reply $what from $sNick : $sAnswer");
                botPrivmsg($self, $sChannel, $sAnswer);
            }
        }
    }
}


# Handle private commands (same as public but with channel = nick)
sub mbCommandPrivate {
    my ($self, $message, $sNick, $sCommand, @tArgs) = @_;

    # Normalize command — q and Q are the same
    $sCommand = lc $sCommand;

    # Build Context once, used by all handlers
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sNick,   # private context: reply target is the nick
        command => $sCommand,
        args    => \@tArgs,
    );

    # Attach a Command object to the Context for handlers that want it
    $ctx->{command_obj} = Mediabot::Command->new(
        name    => $sCommand,
        args    => \@tArgs,
        raw     => join(" ", $sCommand, @tArgs),
        context => $ctx,
        source  => 'private',
    );

    # ---------------------------------------------------------------------------
    # Command dispatch table
    # All handlers receive a Mediabot::Context object.
    # Legacy handlers (pass, ident, topic, update, play, radiopub, debug) still
    # receive the old signature ($self, $message, $sNick, $sChannel, @tArgs)
    # and are wrapped in closures for forward compatibility.
    # ---------------------------------------------------------------------------
    my %command_table = (

        # --- Legacy handlers (not yet migrated to Context) ---
        pass        => sub { userPass_ctx($ctx) },
        ident       => sub { userIdent_ctx($ctx) },
        topic       => sub { userTopicChannel_ctx($ctx) },
        update      => sub { update_ctx($ctx) },
        play        => sub { playRadio_ctx($ctx) },
        radiopub    => sub { radioPub_ctx($ctx) },
        debug       => sub { debug_ctx($ctx) },

        # --- Context-based handlers ---
        status      => sub { mbStatus_ctx($ctx) },
        echo        => sub { mbEcho($ctx) },
        die         => sub { mbQuit_ctx($ctx) },
        nick        => sub { mbChangeNick_ctx($ctx) },
        addtimer    => sub { mbAddTimer_ctx($ctx) },
        remtimer    => sub { mbRemTimer_ctx($ctx) },
        timers      => sub { mbTimers_ctx($ctx) },
        register    => sub { mbRegister_ctx($ctx) },
        msg         => sub { msgCmd_ctx($ctx) },
        dump        => sub { dumpCmd_ctx($ctx) },
        say         => sub { sayChannel_ctx($ctx) },
        act         => sub { actChannel_ctx($ctx) },
        song        => sub { displayRadioCurrentSong_ctx($ctx) },
        metadata    => sub { setRadioMetadata_ctx($ctx) },
        adduser     => sub { addUser_ctx($ctx) },
        deluser     => sub { delUser_ctx($ctx) },
        users       => sub { userStats_ctx($ctx) },
        cstat       => sub { userCstat_ctx($ctx) },
        login       => sub { userLogin_ctx($ctx) },
        logout      => sub { userLogout_ctx($ctx) },
        userinfo    => sub { userInfo_ctx($ctx) },
        addhost     => sub { addUserHost_ctx($ctx) },
        addchan     => sub { addChannel_ctx($ctx) },
        chanset     => sub { channelSet_ctx($ctx) },
        purge       => sub { purgeChannel_ctx($ctx) },
        part        => sub { channelPart_ctx($ctx) },
        join        => sub { channelJoin_ctx($ctx) },
        add         => sub { channelAddUser_ctx($ctx) },
        del         => sub { channelDelUser_ctx($ctx) },
        modinfo     => sub { userModinfo_ctx($ctx) },
        op          => sub { userOpChannel_ctx($ctx) },
        deop        => sub { userDeopChannel_ctx($ctx) },
        invite      => sub { userInviteChannel_ctx($ctx) },
        voice       => sub { userVoiceChannel_ctx($ctx) },
        devoice     => sub { userDevoiceChannel_ctx($ctx) },
        kick        => sub { userKickChannel_ctx($ctx) },
        showcommands => sub { userShowcommandsChannel_ctx($ctx) },
        chaninfo    => sub { userChannelInfo_ctx($ctx) },
        chanlist    => sub { channelList_ctx($ctx) },
        whoami      => sub { userWhoAmI_ctx($ctx) },
        auth        => sub { userAuthNick_ctx($ctx) },
        verify      => sub { userVerifyNick_ctx($ctx) },
        access      => sub { userAccessChannel_ctx($ctx) },
        addcmd      => sub { mbDbAddCommand_ctx($ctx) },
        remcmd      => sub { mbDbRemCommand_ctx($ctx) },
        modcmd      => sub { mbDbModCommand_ctx($ctx) },
        mvcmd       => sub { mbDbMvCommand_ctx($ctx) },
        chowncmd    => sub { mbChownCommand_ctx($ctx) },
        showcmd     => sub { mbDbShowCommand_ctx($ctx) },
        chanstatlines => sub { channelStatLines_ctx($ctx) },
        whotalk     => sub { whoTalk_ctx($ctx) },
        whotalks    => sub { whoTalk_ctx($ctx) },
        countcmd    => sub { mbCountCommand_ctx($ctx) },
        topcmd      => sub { mbTopCommand_ctx($ctx) },
        popcmd      => sub { mbPopCommand_ctx($ctx) },
        searchcmd   => sub { mbDbSearchCommand_ctx($ctx) },
        lastcmd     => sub { mbLastCommand_ctx($ctx) },
        owncmd      => sub { mbDbOwnersCommand_ctx($ctx) },
        holdcmd     => sub { mbDbHoldCommand_ctx($ctx) },
        addcatcmd   => sub { mbDbAddCategoryCommand_ctx($ctx) },
        chcatcmd    => sub { mbDbChangeCategoryCommand_ctx($ctx) },
        topsay      => sub { userTopSay_ctx($ctx) },
        checkhostchan => sub { mbDbCheckHostnameNickChan_ctx($ctx) },
        checkhost   => sub { mbDbCheckHostnameNick_ctx($ctx) },
        checknick   => sub { mbDbCheckNickHostname_ctx($ctx) },
        greet       => sub { userGreet_ctx($ctx) },
        nicklist    => sub { channelNickList_ctx($ctx) },
        rnick       => sub { randomChannelNick_ctx($ctx) },
        birthdate   => sub { displayBirthDate_ctx($ctx) },
        ignores     => sub { IgnoresList_ctx($ctx) },
        ignore      => sub { addIgnore_ctx($ctx) },
        unignore    => sub { delIgnore_ctx($ctx) },
        lastcom     => sub { lastCom_ctx($ctx) },
        moduser     => sub { mbModUser_ctx($ctx) },
        antifloodset => sub { setChannelAntiFloodParams_ctx($ctx) },
        rehash      => sub { mbRehash_ctx($ctx) },
    );

    if (my $handler = $command_table{$sCommand}) {
        $self->{logger}->log(4, "PRIVATE: $sNick triggered $sCommand");
        return $handler->();
    }

    $self->{logger}->log(4, $message->prefix . " Private command '$sCommand' not found");
    return undef;
}

# Set connection timestamp (used for uptime calculation)
sub setConnectionTimestamp {
	my ($self,$iConnectionTimestamp) = @_;
	$self->{iConnectionTimestamp} = $iConnectionTimestamp;
}

# Get connection timestamp
sub getConnectionTimestamp {
	my $self = shift;
	return $self->{iConnectionTimestamp};
}

# Set quit flag (used to signal shutdown)
sub setQuit {
	my ($self,$iQuit) = @_;
	$self->{Quit} = $iQuit;
}

# Get quit flag
sub getQuit {
	my $self = shift;
	return $self->{Quit};
}

1;
