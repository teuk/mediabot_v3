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
use JSON::MaybeXS;
use Try::Tiny;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use List::Util qw/min/;
use Carp qw(croak);
use IO::Socket::SSL;
use HTTP::Tiny;


# --- Top of Mediabot.pm (near other 'my' / 'our' declarations)
my $ALREADY_EXITING = 0;  # re-entrance guard for clean_and_exit

# Constructor for Mediabot object
sub new {
    my ($class, $args) = @_;

        my $self = bless {
        config_file             => $args->{config_file}      // undef,
        requested_server        => $args->{server}           // undef,
        server                  => $args->{server}           // undef,
        server_hostname         => undef,
        server_port             => undef,
        server_source           => undef,
        network_name            => undef,
        dbh                     => $args->{dbh}              // undef,
        conf                    => $args->{conf}             // undef,
        channels                => {},
        channel_nicklist_timers => {},
        WHOIS_VARS              => {},
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

sub reload_logger_from_config {
    my ($self) = @_;

    my $conf = $self->{conf};
    unless ($conf) {
        $self->my_log_error("reload_logger_from_config() called without loaded config");
        return;
    }

    my $debug_level = $conf->get('main.MAIN_PROG_DEBUG');
    $debug_level = 0 unless defined $debug_level && $debug_level =~ /^\d+$/;

    my $log_path = $conf->get('main.MAIN_LOG_FILE');
    unless (defined $log_path && $log_path ne '') {
        $self->my_log_error("reload_logger_from_config() MAIN_LOG_FILE is empty");
        return;
    }

    # Reopen raw LOG handle used by some legacy code paths
    eval {
        if (defined $self->{LOG}) {
            my $oldfh = $self->{LOG};
            close $oldfh if defined(fileno($oldfh));
        }
        1;
    };

    open(my $LOG, ">>", $log_path) or do {
        $self->my_log_error("Could not reopen log file '$log_path': $!");
        return;
    };
    select((select($LOG), $| = 1)[0]);
    $self->{LOG} = $LOG;

    # Recreate object logger with fresh config values
    my $new_logger;
    eval {
        require Mediabot::Log;
        $new_logger = Mediabot::Log->new(
            debug_level => $debug_level,
            logfile     => $log_path,
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->my_log_error("Failed to recreate logger from config: $err");
        return;
    };
    
    if ($self->{logger} && $self->{logger}->{_console_hooks}) {
        $new_logger->{_console_hooks} = $self->{logger}->{_console_hooks};
    }
    
    $self->{logger} = $new_logger;
    $self->{logger}->log(1, "Logger reloaded from config (debug=$debug_level, logfile=$log_path)");

    return 1;
}

sub rebuild_channel_cache {
    my ($self) = @_;

    $self->{logger}->log(1, "Rebuilding channel cache from database");
    $self->{channels} = {};
    
    # Populate channels from DB
	$self->populateChannels();

	# Start per-channel nicklist refresh timers
	$self->setup_channel_nicklist_timers();

    my $count = scalar keys %{ $self->{channels} };
    $self->{logger}->log(1, "Channel cache rebuilt ($count channel objects)");

    return 1;
}

sub refresh_channel_nicklist {
    my ($self, $channel_name) = @_;
    return unless defined $channel_name && $channel_name ne '';

    unless ($self->{irc}) {
        $self->{logger}->log(4, "refresh_channel_nicklist() skipped for $channel_name: no IRC object");
        return;
    }

    $self->{logger}->log(4, "Refreshing nicklist for $channel_name via NAMES");
    eval {
        $self->{irc}->send_message('NAMES', undef, $channel_name);
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "Failed to refresh nicklist for $channel_name: $err");
    };

    return 1;
}

sub stop_all_channel_nicklist_timers {
    my ($self) = @_;

    my $timers = $self->{channel_nicklist_timers} || {};
    foreach my $channel_name (keys %$timers) {
        my $timer = $timers->{$channel_name};
        next unless $timer;

        eval {
            if ($self->{loop}) {
                $self->{loop}->remove($timer);
            }
            $timer->stop if $timer->can('stop');
            1;
        };
    }

    $self->{channel_nicklist_timers} = {};
    $self->{logger}->log(1, "Stopped all channel nicklist timers");

    return 1;
}

sub stop_channel_nicklist_timer {
    my ($self, $channel_name) = @_;

    return unless defined $channel_name && $channel_name ne '';

    my $timer = $self->{channel_nicklist_timers}{$channel_name};
    return unless $timer;

    eval {
        if ($self->{loop}) {
            $self->{loop}->remove($timer);
        }
        $timer->stop if $timer->can('stop');
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "Failed to stop nicklist timer for $channel_name: $err");
    };

    delete $self->{channel_nicklist_timers}{$channel_name};
    $self->{logger}->log(1, "Stopped nicklist timer for $channel_name");

    return 1;
}

sub setup_channel_nicklist_timers {
    my ($self) = @_;

    my $conf = $self->{conf};
    unless ($conf) {
        $self->{logger}->log(1, "setup_channel_nicklist_timers() called without config");
        return;
    }

    unless ($self->{loop}) {
        $self->{logger}->log(1, "setup_channel_nicklist_timers() called without IO::Async loop");
        return;
    }

    $self->stop_all_channel_nicklist_timers();

    my $interval = $conf->get('main.MAIN_CHANNEL_NICKLIST_REFRESH_INTERVAL');
    $interval = 300 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;

    foreach my $channel_name (sort keys %{ $self->{channels} || {} }) {
        my $channel_obj = $self->{channels}{$channel_name};
        next unless $channel_obj;

        my $timer = IO::Async::Timer::Periodic->new(
            interval => $interval,
            first_interval => $interval,
            on_tick => sub {
                $self->refresh_channel_nicklist($channel_name);
            },
        );

        $self->{loop}->add($timer);
        $timer->start;
        $self->{channel_nicklist_timers}{$channel_name} = $timer;

        $self->{logger}->log(1, "Started nicklist refresh timer for $channel_name (interval=${interval}s)");
    }

    my $count = scalar keys %{ $self->{channel_nicklist_timers} || {} };
    $self->{logger}->log(1, "Nicklist timer setup complete ($count timers)");

    return 1;
}

sub rehash_runtime_state {
    my ($self) = @_;

    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_rehash_total');
    }

    my @done;

    unless ($self->readConfigFile()) {
        return;
    }
    push @done, 'config';

    unless ($self->reload_logger_from_config()) {
        return;
    }
    push @done, 'logger';

    # F4: update debug_level at runtime if logger supports it
    my $new_level = $self->{conf}->get('main.MAIN_PROG_DEBUG') // 0;
    if ($self->{logger} && $self->{logger}->can('set_level')) {
        $self->{logger}->set_level(int($new_level));
        $self->{logger}->log(2, "Rehash: debug_level updated to $new_level");
    }

    unless ($self->rebuild_channel_cache()) {
        return;
    }
    push @done, 'channels';

    $self->{logger}->log(1, "Rehash runtime state completed: " . join(', ', @done));
    return 1;
}
# ---------------------------------------------------------------------------
# restart_irc() - reconnect to IRC without killing the process
# The Partyline stays alive. Called from Partyline .restart command.
# ---------------------------------------------------------------------------
sub restart_irc {
    my ($self, %opts) = @_;

    my $reason = $opts{reason} // "Restarting IRC connection";
    my $server = $opts{server} // undef;   # optional jump target

    if ($self->{irc_restart_in_progress}) {
        $self->{logger}->log(1, "restart_irc(): restart already in progress, ignoring duplicate request");
        return 0;
    }

    $self->{irc_restart_in_progress} = 1;

    $self->{logger}->log(1, "restart_irc(): initiating IRC restart ($reason)");

    # Override server if jumping
    if (defined $server && $server ne '') {
        $self->{requested_server} = $server;
        $self->{logger}->log(1, "restart_irc(): will connect to $server after restart");
    }

    # This is NOT a final exit.
    $self->{Quit} = 0;

    if (my $pending = delete $self->{irc_reconnect_timer}) {
        my $loop = $self->can('getLoop') ? $self->getLoop : undef;
        eval {
            $pending->stop if $pending->can('stop');
            $loop->remove($pending) if $loop;
        };
    }

    # Ask for an IRC reconnect through the normal runtime path.
    # We do NOT stop the main loop and we do NOT tear down the Partyline.
    $self->{irc_reconnect_requested} = 1;

    $self->{logger}->log(0,
        "restart_irc(): flags set "
        . "restart_in_progress=" . ($self->{irc_restart_in_progress} // 'undef')
        . " reconnect_requested=" . ($self->{irc_reconnect_requested} // 'undef')
        . " reconnect_in_progress=" . ($self->{irc_reconnect_in_progress} // 'undef')
    );

    # Invalidate connection timestamp so the reconnect grace period does not block us.
    $self->setConnectionTimestamp(0) if $self->can('setConnectionTimestamp');

    # Best-effort QUIT.
    # Do not remove the IRC object from the loop immediately: that can prevent
    # the QUIT from being flushed and also defeats the goal of keeping the process alive cleanly.
    eval {
        if ($self->{irc} && $self->{irc}->is_connected) {
            $self->{irc}->send_message("QUIT", undef, $reason);
            $self->{logger}->log(0, "restart_irc(): QUIT sent (best effort)");
        }
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "restart_irc(): QUIT send failed: $err");
    };

    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_restart_total');
    }

    $self->{logger}->log(1, "restart_irc(): reconnect requested - Partyline remains active");

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

    # Check USER_HOSTMASK table exists - required since schema migration
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

    $self->{logger}->log(4, "USER_HOSTMASK table exists - schema OK");

    # Check USER.hostmasks column is gone (renamed to hostmasks_legacy)
    # This is a soft warning only - the bot can still run.
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
	my ($self, $sServer) = @_;
	$self->{requested_server} = $sServer;
	$self->{server} = $sServer;
}

sub getRequestedServer {
    my ($self) = @_;
    return $self->{requested_server};
}

sub getServerSource {
    my ($self) = @_;
    return $self->{server_source};
}

sub getNetworkName {
    my ($self) = @_;
    return $self->{network_name};
}

sub getServerHostPort {
    my ($self) = @_;
    return ($self->{server_hostname}, $self->{server_port});
}

# Pick a server from the database based on the configured network
sub pickServer {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $dbh  = $self->{dbh};

    $self->{network_name}  = undef;
    $self->{server_source} = undef;

    my $requested_server = $self->{requested_server};

    if (!defined($requested_server) || $requested_server eq "") {
        my $network_name = $conf->get('connection.CONN_SERVER_NETWORK');
        $self->{network_name} = $network_name;

        unless ($network_name) {
            $self->{logger}->log(0, "No CONN_SERVER_NETWORK defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        my $count_query = "
            SELECT COUNT(*) AS server_count
            FROM NETWORK
            JOIN SERVERS ON SERVERS.id_network = NETWORK.id_network
            WHERE NETWORK.network_name = ?
        ";
        my $sth_count = $dbh->prepare($count_query);

        if ($sth_count && $sth_count->execute($network_name)) {
            my $count_ref = $sth_count->fetchrow_hashref();
            $sth_count->finish;

            my $server_count = int($count_ref->{server_count} // 0);

            if ($server_count > 0) {
                my $offset = int(rand($server_count));

                my $sQuery = "
                    SELECT SERVERS.server_hostname
                    FROM NETWORK
                    JOIN SERVERS ON SERVERS.id_network = NETWORK.id_network
                    WHERE NETWORK.network_name = ?
                    ORDER BY SERVERS.id_server
                    LIMIT 1 OFFSET $offset
                ";
                my $sth = $dbh->prepare($sQuery);

                if ($sth && $sth->execute($network_name)) {
                    if (my $ref = $sth->fetchrow_hashref()) {
                        $self->{server} = $ref->{server_hostname};
                        $self->{server_source} = 'network-db';
                    }
                    $sth->finish;
                } else {
                    $self->{logger}->log(0, "Startup select SERVER, SQL Error: " . $DBI::errstr . " Query: " . $sQuery);
                }
            }
        }
        else {
            $self->{logger}->log(0, "Startup count SERVER, SQL Error: " . $DBI::errstr . " Query: " . $count_query);
        }

        unless ($self->{server}) {
            $self->{logger}->log(0, "No server found for network $network_name defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        $self->{logger}->log(1, "Picked $self->{server} from network '$network_name'");
    } else {
        $self->{server} = $requested_server;
        $self->{server_source} = 'requested-server';
        $self->{network_name} = $conf->get('connection.CONN_SERVER_NETWORK');

        $self->{logger}->log(1, "Picked $self->{server} from requested server override");
    }

    # Parse hostname[:port]
    if ($self->{server} =~ /:/) {
        ($self->{server_hostname}, $self->{server_port}) = split(/:/, $self->{server}, 2);
    } else {
        $self->{server_hostname} = $self->{server};
        $self->{server_port} = 6667;
    }

    $self->{logger}->log(
        4,
        "Using host $self->{server_hostname}, port $self->{server_port}, source=$self->{server_source}, network=" .
        (defined $self->{network_name} ? $self->{network_name} : '<undef>')
    );
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

        if ($self->{metrics}) {
            $self->{metrics}->set('mediabot_channel_autojoin', 1, { channel => $name });
        }

        joinChannel($self, $name, $key);
        $self->{logger}->log( 2, "Joining channel $name");
    }

    $i == 0 and $self->{logger}->log( 0, "No channel to auto join");
}

# Handle public commands
sub mbCommandPublic {
    my ($self, $message, $sChannel, $sNick, $botNickTriggered, $sCommand, @tArgs) = @_;

    # Per-nick flood protection — silently drop if flooding
    return if checkNickFlood($self, $sNick);

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

    if ($self->{metrics} && defined $cmd && length $cmd) {
        $self->{metrics}->inc(
            'mediabot_commands_public_total',
            { command => $cmd }
        );

        if (defined $sChannel && $sChannel =~ /^#/) {
            $self->{metrics}->inc(
                'mediabot_channel_commands_total',
                { channel => $sChannel }
            );

            $self->{metrics}->inc(
                'mediabot_channel_commands_by_name_total',
                { channel => $sChannel, command => $cmd }
            );
        }
    }

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
        ban          => sub { channelBan_ctx($ctx) },
        kickban      => sub { channelKickBan_ctx($ctx) },
        kb           => sub { channelKickBan_ctx($ctx) },
        unban        => sub { channelUnban_ctx($ctx) },
        bans         => sub { channelBans_ctx($ctx) },
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
        song         => sub { song_ctx($ctx) },
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
        resolve      => sub { resolve_ctx($ctx) },
        tmdb         => sub { mbTMDBSearch_ctx($ctx) },
        tmdblangset  => sub { setTMDBLangChannel_ctx($ctx) },
        debug        => sub { debug_ctx($ctx) },
        version      => sub { versionCheck($ctx) },
        uptime       => sub { mbUptime_ctx($ctx) },
        help         => sub { mbHelp_ctx($ctx) },
        spike        => sub { $ctx->reply("https://teuk.org/In_Spike_Memory.jpg") },
        update       => sub { update_ctx($ctx) },
    );

    # A4: track per-command usage in Prometheus
    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_commands_by_name_total', { command => $cmd });
    }

    # Dispatch known command
    if (my $handler = $command_map{$cmd}) {
        $self->{logger}->log(4, "PUBLIC: $sNick triggered $sCommand on $sChannel");
        eval { $handler->() };
        if ($@) {
            $self->{logger}->log(1, "PUBLIC command '$cmd' error: $@");
            $self->{metrics}->inc('mediabot_command_errors_total', { command => $cmd })
                if $self->{metrics};
        }
        return;
    }

    # Check database for custom commands
    my $bFound = mbDbCommand($self, $message, $sChannel, $sNick, $sCommand, @tArgs);
    return if $bFound;

    # Bot nick triggered - natural language / Hailo fallback
    if ($botNickTriggered) {
        mbHandleNickTriggered($ctx, join(" ", $sCommand, @tArgs));
    } else {
        $self->{logger}->log(4, "Public command '$sCommand' not found");
    }
}

# Handle help command

# ---------------------------------------------------------------------------
# mbUptime_ctx — !uptime
# ---------------------------------------------------------------------------
sub mbUptime_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $channel = $ctx->channel;

    my $start = eval { $self->{metrics}->{started} }
             // eval { $self->{conf}->get('main.MAIN_PROG_BIRTHDATE') }
             // 0;

    my $uptime_secs = time() - $start;
    my $d = int($uptime_secs / 86400);
    my $h = int(($uptime_secs % 86400) / 3600);
    my $m = int(($uptime_secs % 3600) / 60);
    my $s = $uptime_secs % 60;

    my $uptime_str = '';
    $uptime_str .= "${d}d " if $d;
    $uptime_str .= "${h}h " if $h;
    $uptime_str .= "${m}m " if $m;
    $uptime_str .= "${s}s";
    $uptime_str =~ s/\s+$//;

    my $nick = eval { $self->{irc}->nick_folded } // 'mediabotv3';
    botPrivmsg($self, $channel, "$nick has been up for $uptime_str.");
}

sub mbHelp_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $wiki = "https://github.com/teuk/mediabot_v3/wiki";

    # Explicit wiki request: keep the external documentation easy to find.
    if (@args && defined($args[0]) && $args[0] =~ /^(wiki|doc|docs|documentation)$/i) {
        botNotice($self, $nick, "Mediabot documentation: $wiki");
        return 1;
    }

    # If a channel is provided, reuse showcommands against that channel.
    # Example:
    #   !help #teuk
    if (@args && defined($args[0]) && $args[0] =~ /^#/) {
        return userShowcommandsChannel_ctx($ctx);
    }

    # No args: show level-filtered commands for the current channel when possible.
    # This reuses the existing showcommands implementation, including auth and
    # channel-level filtering.
    unless (@args) {
        if ($channel =~ /^#/) {
            return userShowcommandsChannel_ctx($ctx);
        }

        botNotice($self, $nick, "Syntax: help #channel");
        botNotice($self, $nick, "Documentation: $wiki");
        return 1;
    }

    # Command-specific help is not fully documented inline yet. Provide useful
    # pointers instead of pretending the command is unknown.
    my $cmd = lc($args[0] // '');
    $cmd =~ s/^\Q$self->{command_char}\E// if defined($self->{command_char}) && $self->{command_char} ne '';

    botNotice($self, $nick, "Inline help for '$cmd' is not available yet.");
    botNotice($self, $nick, "Try: showcmd $cmd");
    botNotice($self, $nick, "Try: searchcmd $cmd");
    botNotice($self, $nick, "Documentation: $wiki");

    return 1;
}


# Handle bot nick triggered messages - natural patterns + Hailo fallback
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

    # Per-nick flood protection — silently drop if flooding
    return if checkNickFlood($self, $sNick);

    # Normalize command - q and Q are the same
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

    if ($self->{metrics} && defined $sCommand && length $sCommand) {
        $self->{metrics}->inc(
            'mediabot_commands_private_total',
            { command => $sCommand }
        );
    }

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
        debug       => sub { debug_ctx($ctx) },

        # --- Context-based handlers ---
        status      => sub { mbStatus_ctx($ctx) },
        radiostatus => sub { radioStatus_ctx($ctx) },
        radiomounts => sub { radioMounts_ctx($ctx) },
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
        song        => sub { song_ctx($ctx) },
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


# ---------------------------------------------------------------------------
# process_expired_channel_bans()
#
# Called periodically by the main event loop.
#
# For each active CHANNEL_BAN whose expires_at is in the past:
#   - resolve channel id -> channel name
#   - send MODE #channel -b mask
#   - mark the ban inactive in DB
#
# This method is deliberately conservative:
#   - if the IRC object is not ready, it does nothing
#   - if a channel cannot be resolved, it logs and skips
#   - if MODE -b fails, it keeps the ban active for a later retry
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# purge_channel_log() — delete CHANNEL_LOG entries older than N days
# ---------------------------------------------------------------------------
sub purge_channel_log {
    my ($self) = @_;
    my $days = int(eval { $self->{conf}->get('main.CHANNEL_LOG_RETENTION_DAYS') } // 90);
    return if $days <= 0;
    my $sth = $self->{dbh}->prepare(
        "DELETE FROM CHANNEL_LOG WHERE ts < DATE_SUB(NOW(), INTERVAL ? DAY)"
    ) or return;
    eval { $sth->execute($days) };
    if ($@) { $self->{logger}->log(1, "purge_channel_log: $@"); return; }
    my $rows = $sth->rows // 0;
    $sth->finish;

    if ($rows) {
        my $msg = "purge_channel_log: $rows row(s) deleted (>${days}d)";
        $self->{logger}->log(2, $msg);
        noticeConsoleChan($self, $msg);
    }

    return $rows;
}

# ---------------------------------------------------------------------------
# purge_user_seen() — delete USER_SEEN nicks not seen for N days
# ---------------------------------------------------------------------------
sub purge_user_seen {
    my ($self) = @_;
    my $days = int(eval { $self->{conf}->get('main.USER_SEEN_RETENTION_DAYS') } // 180);
    return if $days <= 0;
    my $sth = $self->{dbh}->prepare(
        "DELETE FROM USER_SEEN WHERE seen_at < DATE_SUB(NOW(), INTERVAL ? DAY)"
    ) or return;
    eval { $sth->execute($days) };
    if ($@) { $self->{logger}->log(1, "purge_user_seen: $@"); return; }
    my $rows = $sth->rows // 0;
    $sth->finish;

    if ($rows) {
        my $msg = "purge_user_seen: $rows stale nick(s) purged (>${days}d)";
        $self->{logger}->log(2, $msg);
        noticeConsoleChan($self, $msg);
    }

    return $rows;
}

sub process_expired_channel_bans {
    my ($self) = @_;

    return 0 unless $self->{channel_ban};
    return 0 unless $self->{irc};

    my @expired = eval { $self->{channel_ban}->expired_bans };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+/ /g;
        $self->{logger}->log(1, "channelban: failed to fetch expired bans: $err");
        return 0;
    }

    return 0 unless @expired;

    my $done = 0;

    BAN:
    for my $ban (@expired) {
        my $id_channel = $ban->{id_channel};
        my $mask       = $ban->{mask};
        my $id_ban     = $ban->{id_channel_ban};

        unless ($id_channel && $mask && $id_ban) {
            $self->{logger}->log(1, "channelban: invalid expired ban row, skipping");
            next BAN;
        }

        my $channel_name = '';

        for my $name (sort keys %{ $self->{channels} || {} }) {
            my $ch = $self->{channels}{$name} || next;
            my $ch_id = eval { $ch->get_id };
            if (defined $ch_id && $ch_id == $id_channel) {
                $channel_name = eval { $ch->get_name } || $name;
                last;
            }
        }

        unless ($channel_name) {
            $self->{logger}->log(1, "channelban: expired ban #$id_ban references unknown channel id=$id_channel");
            next BAN;
        }

        $self->{logger}->log(2, "channelban: expiring ban #$id_ban on $channel_name mask=$mask");

        # Verify the bot is actually present in the channel before sending MODE -b.
        # If not, skip the IRC command but still mark the ban removed in DB so it
        # does not pile up — the IRC ban either expired naturally or the bot was
        # absent when it was set.
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        my @chan_nicks = $self->gethChannelsNicksOnChan($channel_name);
        my $bot_on_chan = grep { lc($_) eq lc($bot_nick) } @chan_nicks;

        my $mode_ok;
        if ($bot_on_chan) {
            $mode_ok = eval {
                $self->{irc}->send_message("MODE", undef, ($channel_name, "-b", $mask));
                1;
            };

            unless ($mode_ok) {
                my $err = $@ || 'unknown error';
                $err =~ s/\s+/ /g;
                $self->{logger}->log(1, "channelban: MODE -b failed for expired ban #$id_ban on $channel_name $mask: $err");
                next BAN;
            }
        }
        else {
            $self->{logger}->log(2, "channelban: bot not on $channel_name — skipping MODE -b for expired ban #$id_ban, marking removed in DB");
            $mode_ok = 1;   # proceed to DB cleanup
        }

        my ($rows, $err) = eval {
            $self->{channel_ban}->mark_removed(
                id_channel      => $id_channel,
                selector        => $id_ban,
                removed_by      => undef,
                removed_by_nick => 'system',
                remove_reason   => 'expired',
            );
        };

        if ($@) {
            my $e = $@;
            $e =~ s/\s+/ /g;
            $self->{logger}->log(1, "channelban: DB mark_removed failed for expired ban #$id_ban: $e");
            next BAN;
        }

        if ($err) {
            $self->{logger}->log(1, "channelban: DB mark_removed error for expired ban #$id_ban: $err");
            next BAN;
        }

        $done++;
        if ($self->{metrics}) {
            $self->{metrics}->inc('mediabot_channel_bans_expired_total');
        }
        $self->{logger}->log(2, "channelban: expired ban #$id_ban removed from $channel_name ($mask)");
    }

    return $done;
}


# ---------------------------------------------------------------------------
# _fetch_user_for_dcc($nick)
#
# Shared DB lookup for DCC CHAT validation.
# Returns hashref {id_user, nickname, level, description} or undef.
# ---------------------------------------------------------------------------
sub _fetch_user_for_dcc {
    my ($self, $nick) = @_;

    my $sth = $self->{dbh}->prepare(q{
        SELECT u.id_user, u.nickname, ul.level, ul.description
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE u.nickname = ?
        LIMIT 1
    });

    unless ($sth && $sth->execute($nick)) {
        $self->{logger}->log(1, "DCC: DB error for nick '$nick' — " . ($DBI::errstr // 'unknown'));
        return undef;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row;
}

# ---------------------------------------------------------------------------
# _handle_ctcp_chat_request($message, $nick)
#
# Called when a simple Eggdrop-style CTCP CHAT request is received:
#   /ctcp <botnick> CHAT
#
# The requester must be a known Mediabot user with global level <= 1
# before we offer a DCC CHAT Partyline session.
# ---------------------------------------------------------------------------
sub _handle_ctcp_chat_request {
    my ($self, $message, $nick) = @_;

    my $logger = $self->{logger};
    my $dbh    = $self->{dbh};

    unless ($self->{partyline} && $self->{partyline}->can('offer_dcc_chat')) {
        $logger->log(1, "CTCP CHAT from $nick: Partyline not available - ignored");
        return;
    }

    my $row = $self->_fetch_user_for_dcc($nick);

    unless ($row) {
        $logger->log(2, "CTCP CHAT from $nick: unknown user or DB error - ignored");
        return;
    }

    unless (defined($row->{level}) && $row->{level} <= 1) {
        $logger->log(2, sprintf(
            "CTCP CHAT from %s: insufficient level (%s=%d) - ignored",
            $nick, $row->{description} // '?', $row->{level} // -1
        ));
        return;
    }

    $logger->log(2, sprintf(
        "CTCP CHAT from %s (level=%s): offering DCC CHAT",
        $nick, $row->{description}
    ));

    $self->{partyline}->offer_dcc_chat($nick);
}

# ---------------------------------------------------------------------------
# _handle_dcc_chat_request($message, $nick, $ip_int, $port)
#
# Called when a CTCP DCC CHAT request is received as a private PRIVMSG.
# Validates the requesting user (must be known in DB with level <= 1),
# then delegates the actual TCP connection to Partyline->accept_dcc_chat().
# ---------------------------------------------------------------------------
sub _handle_dcc_chat_request {
    my ($self, $message, $nick, $ip_int, $port, $token) = @_;

    my $logger = $self->{logger};
    my $dbh    = $self->{dbh};

    # ── Detect passive DCC CHAT (ip=0 port=0 token=N) ───────────────────────
    my $is_passive = (defined $ip_int && $ip_int == 0
                   && defined $port   && $port   == 0
                   && defined $token  && $token  =~ /^\d+$/);

    # ── Sanity check on port (active mode only) ──────────────────────────────
    unless ($is_passive || (defined $port && $port >= 1024 && $port <= 65535)) {
        $logger->log(1, "DCC CHAT from $nick: invalid port $port - ignored");
        return;
    }

    # ── Partyline must be available ──────────────────────────────────────────
    unless ($self->{partyline} && $self->{partyline}->can('accept_dcc_chat')) {
        $logger->log(1, "DCC CHAT from $nick: Partyline not available - ignored");
        return;
    }

    # ── Look up user in DB - must exist and have level <= 1 ─────────────────
    my $row = $self->_fetch_user_for_dcc($nick);

    unless ($row) {
        $logger->log(2, "DCC CHAT from $nick: unknown user or DB error - ignored");
        return;
    }

    unless (defined($row->{level}) && $row->{level} <= 1) {
        $logger->log(2, sprintf(
            "DCC CHAT from %s: insufficient level (%s=%d) - ignored",
            $nick, $row->{description} // '?', $row->{level} // -1
        ));
        return;
    }

    # ── Delegate to Partyline ────────────────────────────────────────────────
    if ($is_passive) {
        $logger->log(2, sprintf(
            "DCC CHAT from %s (level=%s): passive mode - token=%s",
            $nick, $row->{description}, $token
        ));
        $self->{partyline}->accept_dcc_chat_passive($nick, $token);
    }
    else {
        $logger->log(2, sprintf(
            "DCC CHAT from %s (level=%s): active mode - ip_int=%d port=%d",
            $nick, $row->{description}, $ip_int, $port
        ));
        $self->{partyline}->accept_dcc_chat($nick, $ip_int, $port);
    }
}

1;
