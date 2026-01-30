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
use Time::HiRes qw(usleep);
use Config::Simple;
use Date::Parse;
use Data::Dumper;
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
use HTML::Entities qw(decode_entities);
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
use URI::Escape qw(uri_escape_utf8);
use List::Util qw/min/;
use File::Temp qw/tempfile/;
use Carp qw(croak);
use Encode qw(encode);
use HTTP::Tiny;


# --- Top of Mediabot.pm (near other 'my' / 'our' declarations)
my $ALREADY_EXITING = 0;  # re-entrance guard for clean_and_exit


sub new {
    my ($class, $args) = @_;

    my $self = bless {
        config_file => $args->{config_file} // undef,
        server      => $args->{server}      // undef,
        dbh         => $args->{dbh}         // undef,
        conf        => $args->{conf}        // undef,
        channels    => {},
    }, $class;

    # Minimal logging setup
    require Mediabot::Log;
    $self->{logger} = Mediabot::Log->new(
        debug_level => 0,
        logfile     => undef
    );

    return $self;
}



# Return a Mediabot::User object matching the message prefix, or undef if none matched
sub get_user_from_message {
    my ($self, $message) = @_;

    my $fullmask = $message->prefix // '';
    my ($nick)   = $fullmask =~ /^([^!]+)/;
    $nick ||= '';

    $self->{logger}->log(3, "🔍 get_user_from_message() called with hostmask: '$fullmask'");

    my $sth = $self->{dbh}->prepare("SELECT * FROM USER");
    unless ($sth->execute) {
        $self->{logger}->log(1, "❌ get_user_from_message() SQL Error: $DBI::errstr");
        return;
    }

    my $matched_user;
    while (my $row = $sth->fetchrow_hashref) {
        my @patterns = split(/,/, ($row->{hostmasks} // ''));
        foreach my $mask (@patterns) {
            my $orig_mask = $mask;
            $mask =~ s/^\s+|\s+$//g;
            my $regex = $mask; $regex =~ s/\./\\./g; $regex =~ s/\*/.*/g; $regex =~ s/\[/\\[/g; $regex =~ s/\]/\\]/g; $regex =~ s/\{/\\{/g; $regex =~ s/\}/\\}/g;

            if ($fullmask =~ /^$regex/) {
                require Mediabot::User;
                my $user = Mediabot::User->new($row);
                $user->load_level($self->{dbh});

                # DEBUG before autologin
                $self->_dbg_auth_snapshot('pre-auto', $user, $nick, $fullmask);

                # AUTOLOGIN (auth in DB)
                if ($user->can('maybe_autologin')) {
                    $user->maybe_autologin($self, $nick, $fullmask);
                }

                # DEBUG after autologin
                $self->_dbg_auth_snapshot('post-auto', $user, $nick, $fullmask);

                # Synchronise all caches if DB says auth=1
                $self->_ensure_logged_in_state($user, $nick, $fullmask);

                # DEBUG after synchronisation
                $self->_dbg_auth_snapshot('post-ensure', $user, $nick, $fullmask);

                $self->{logger}->log(3, "🎯 Matched user id=" . ($user->can('id') ? $user->id : $user->{id_user}) .
                                         ", nickname='" . $user->nickname .
                                         "', level='" . ($user->level_description // 'undef') . "'");

                $matched_user = $user;
                last;
            }
        }
        last if $matched_user;
    }

    $sth->finish;

    unless ($matched_user) {
        $self->{logger}->log(3, "🚫 No user matched hostmask '$fullmask'");
        return;
    }

    # DEBUG au retour
    $self->_dbg_auth_snapshot('return', $matched_user, $nick, $fullmask);

    return $matched_user;
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

# getVersion – retrieves the current local version and compares it to the latest GitHub version
sub getVersion {
    my $self = shift;
    my ($local_version, $remote_version) = ("Undefined", "Undefined");
    my ($c_major, $c_minor, $c_type, $c_dev_info);
    my ($r_major, $r_minor, $r_type, $r_dev_info);

    $self->{logger}->log(0, "Reading local version from VERSION file...");

    # Read local VERSION file
    if (open my $fh, '<', 'VERSION') {
        chomp($local_version = <$fh>);
        close $fh;
        ($c_major, $c_minor, $c_type, $c_dev_info) = $self->getDetailedVersion($local_version);
    } else {
        $self->{logger}->log(0, "Unable to read local VERSION file.");
    }

    if (defined $c_major && defined $c_minor && defined $c_type) {
        my $suffix = $c_dev_info ? "($c_dev_info)" : '';
        $self->{logger}->log(0, "-> Mediabot $c_type version $c_major.$c_minor $suffix");
    } else {
        $self->{logger}->log(0, "-> Unknown local version format: $local_version");
    }

    # If we have a valid local version, try fetching the GitHub version
    if ($local_version ne "Undefined") {
        $self->{logger}->log(0, "Checking latest version from GitHub...");

        if (open my $gh, '-|', 'curl --connect-timeout 5 -f -s https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION') {
            chomp($remote_version = <$gh>);
            close $gh;
            ($r_major, $r_minor, $r_type, $r_dev_info) = $self->getDetailedVersion($remote_version);

            if (defined $r_major && defined $r_minor && defined $r_type) {
                my $suffix = $r_dev_info ? "($r_dev_info)" : '';
                $self->{logger}->log(0, "-> GitHub $r_type version $r_major.$r_minor $suffix");

                if ($local_version eq $remote_version) {
                    $self->{logger}->log(0, "Mediabot is up to date.");
                } else {
                    $self->{logger}->log(0, "Update available: $r_type version $r_major.$r_minor $suffix");
                }
            } else {
                $self->{logger}->log(0, "Unknown remote version format: $remote_version");
            }
        } else {
            $self->{logger}->log(0, "Failed to fetch version from GitHub.");
        }
    }

    $self->{main_prog_version} = $local_version;
    return ($local_version, $remote_version);
}

# getDetailedVersion – parses a version string and returns its components
sub getDetailedVersion {
    my ($self, $version_string) = @_;

    # Expecting version format like: 3.0 or 3.0dev-20250614_192031
    if ($version_string =~ /^(\d+)\.(\d+)$/) {
        # Stable version
        return ($1, $2, "stable", undef);
    } elsif ($version_string =~ /^(\d+)\.(\d+)dev[-_]?([\d_]+)$/) {
        # Dev version like 3.0dev-20250614_192031
        return ($1, $2, "devel", $3);
    } else {
        return (undef, undef, undef, undef);
    }
}

# Get the debug level from the configuration
sub getDebugLevel {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_PROG_DEBUG');
}

# Get the log file path from the configuration
sub getLogFile(@) {
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
sub getMainConfCfg(@) {
	my $self = shift;
	return $self->{cfg};
}

# Get channel object by name
sub getChannel {
    my ($self, $chan_name) = @_;
    return $self->{channels}{$chan_name};
}

# Get PID file path from configuration
sub getPidFile(@) {
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
sub getPidFromFile(@) {
    my $self = shift;
    my $pidfile = $self->{conf}->get('main.MAIN_PID_FILE');

    unless (open PIDFILE, $pidfile) {
        return undef;
    }
    else {
        my $line;
        if (defined($line = <PIDFILE>)) {
            chomp($line);
            close PIDFILE;
            return $line;
        }
        else {
            $self->{logger}->log( 1, "getPidFromFile() couldn't read PID from $pidfile");
            return undef;
        }
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


# Initialize the authentication module
sub init_auth {
    my ($self) = @_;

    $self->{auth} = Mediabot::Auth->new(
        dbh    => $self->{dbh},
        logger => $self->{logger},
    );

    $self->{logger}->log(1, "Authentication module initialized");
}


# Populate all CHANNEL entries into $self->{channels}
sub populateChannels {
    my ($self) = @_;

    $self->{logger}->log( 3, "populateChannels: Populating channels from database");

    my $sQuery = "SELECT id_channel, name, description, topic, tmdb_lang, `key` FROM CHANNEL";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute()) {
        $self->{logger}->log( 1, "SQL Error: " . $DBI::errstr . " Query: $sQuery");
        return;
    }

    my $i = 0;
    while (my $ref = $sth->fetchrow_hashref()) {
        $i++ == 0 and $self->{logger}->log( 0, "Populating channel objects");

        my $channel_obj = Mediabot::Channel->new({
            id         => $ref->{id_channel},
            name       => $ref->{name},
			description => $ref->{description},
            topic      => $ref->{topic},
            tmdb_lang  => $ref->{tmdb_lang},
            key        => $ref->{key},
            dbh        => $self->{dbh},
			irc		   => $self->{irc},
        });

        $self->{channels}{ $ref->{name} } = $channel_obj;
    }

    $sth->finish;

    if ($i == 0) {
        $self->{logger}->log( 0, "No channel found in database.");
    }
}

# Initialize Hailo object
sub init_hailo(@) {
	my ($self) = shift;
	$self->{logger}->log(0,"Initialize Hailo");
	my $hailo = Hailo->new(
		brain => 'mediabot_v3.brn',
		save_on_exit => 1,
	);
	$self->{hailo} = $hailo;
}

# Get the Hailo object
sub get_hailo(@) {
	my ($self) = shift;
	return $self->{hailo};
}

# Clean up and exit the program (with proper Net::Async::IRC QUIT)
sub clean_and_exit(@) {
    my ($self, $iRetValue) = @_;
    $iRetValue = 0 unless defined $iRetValue;

    # Re-entrance guard without 'state'
    if ($ALREADY_EXITING) { CORE::exit($iRetValue); }
    $ALREADY_EXITING = 1;

    # Log if possible (best-effort)
    eval {
        $self->{logger}->log(0, "Cleaning and exiting...")
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
sub dbConnect(@) {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $LOG  = $self->{LOG};

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME');
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') // 'localhost';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') // 3306;
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER');
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS');

    my $connectionInfo = "DBI:mysql:database=$dbname;host=$dbhost;port=$dbport";

    $self->{logger}->log( 1, "dbConnect() Connecting to Database: $dbname");

    my $dbh;
    unless ($dbh = DBI->connect($connectionInfo, $dbuser, $dbpass, { RaiseError => 0, PrintError => 0 })) {
        $self->{logger}->log( 0, "dbConnect() DBI Error: " . $DBI::errstr);
        $self->{logger}->log( 0, "dbConnect() DBI Native error code: " . ($DBI::err // 'undef'));
        clean_and_exit($self, 3) if defined $DBI::err;
    }

    $dbh->{mysql_auto_reconnect} = 1;
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
sub getDbh(@) {
	my $self = shift;
	return $self->{dbh};
}

# Check if the USER table exists in the database
sub dbCheckTables(@) {
    my ($self) = shift;
    my $LOG = $self->{LOG};
    my $dbh = $self->{dbh};

    $self->{logger}->log(3, "Checking USER table");

    unless (defined $dbh) {
        $self->{logger}->log(0, "❌ No DBI handle found (dbh is undef). Aborting DB check.");
        $self->{logger}->log(0, "Check your database credentials in mediabot.conf and ensure the user has proper access.");
        clean_and_exit($self, 1);
    }

    my $sLogoutQuery = "SELECT * FROM USER";
    my $sth = $dbh->prepare($sLogoutQuery);

    unless ($sth->execute) {
        $self->{logger}->log(0, "dbCheckTables() SQL Error: $DBI::errstr ($DBI::err) Query: $sLogoutQuery");

        if (defined($DBI::err) && $DBI::err == 1146) {
            $self->{logger}->log(3, "USER table does not exist. Check your database installation.");
            clean_and_exit($self, 1146);
        }
    }
    else {
        $self->{logger}->log(3, "USER table exists");
    }
}

# Logout all users in the USER table
sub dbLogoutUsers(@) {
	my ($self) = shift;
	my $LOG = $self->{LOG};
	my $dbh = $self->{dbh};
	my $sLogoutQuery = "UPDATE USER SET auth=0 WHERE auth=1";
	my $sth = $dbh->prepare($sLogoutQuery);
	unless ($sth->execute) {
		$self->{logger}->log(0,"dbLogoutUsers() SQL Error : " . $DBI::errstr . "(" . $DBI::err . ") Query : " . $sLogoutQuery);
	}
	else {	
		$self->{logger}->log(0,"Logged out all users");
	}
}

# Set server attribute
sub setServer(@) {
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

        my $sQuery = "SELECT SERVERS.server_hostname FROM NETWORK,SERVERS WHERE NETWORK.id_network=SERVERS.id_network AND NETWORK.network_name LIKE ? ORDER BY RAND() LIMIT 1";
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

        $self->{logger}->log(0, "Picked $self->{server} from Network $network_name");
    } else {
        $self->{logger}->log(0, "Picked $self->{server} from command line");
    }

    # Parse hostname[:port]
    if ($self->{server} =~ /:/) {
        ($self->{server_hostname}, $self->{server_port}) = split(/:/, $self->{server}, 2);
    } else {
        $self->{server_hostname} = $self->{server};
        $self->{server_port} = 6667;
    }

    $self->{logger}->log(3, "Using host $self->{server_hostname}, port $self->{server_port}");
}

# Log a hint to run ./configure if no server is set
sub _log_configure_hint {
    my ($self) = @_;
    $self->{logger}->log(0, "Run ./configure at first use or ./configure -s to set it properly");
}

# Get server hostname 
sub getServerHostname(@) {
	my $self = shift;
	return $self->{server_hostname};
}

# Get server port
sub getServerPort(@) {
	my $self = shift;
	return $self->{server_port};
}

# Set loop
sub setLoop(@) {
	my ($self,$loop) = @_;
	$self->{loop} = $loop;
}

# Get loop
sub getLoop(@) {
	my $self = shift;
	return $self->{loop};
}

# Set main timer tick
sub setMainTimerTick(@) {
	my ($self,$timer) = @_;
	$self->{main_timer_tick} = $timer;
}

# Set refresh channel hashes
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

# Get main timer tick
sub getMainTimerTick(@) {
	my $self = shift;
	return $self->{maint_timer_tick};
}

# Set IRC object
sub setIrc(@) {
	my ($self,$irc) = @_;
	$self->{irc} = $irc;
}

# Get IRC object
sub getIrc(@) {
	my $self = shift;
	return $self->{irc};
}

# Get connection nick
sub getConnectionNick(@) {
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
sub getServerPass(@) {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_PASS') // "";
}

# Get nick trigger status
sub getNickTrigger(@) {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('main.NICK_TRIGGER') // 0;
}

# Get IRC username from configuration
sub getUserName(@) {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_USERNAME');
}

# Get IRC real name from configuration
sub getIrcName(@) {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_IRCNAME');
}

# Get nick info from a message
sub getMessageNickIdentHost(@) {
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
sub getIdChannel {
    my ($self, $sChannel) = @_;
    $self->{logger}->log(1, "⚠️ getIdChannel() is deprecated. Use channel object instead.");
    return $self->{channels}{$sChannel} ? $self->{channels}{$sChannel}->get_id : undef;
}

# Get user nickname from user id
# Get user nickname/handle from user id
sub getUserhandle {
    my ($self, $id_user) = @_;

    # unvalid user => undef
    return unless defined $id_user && $id_user =~ /^\d+$/ && $id_user > 0;

    my $logger = $self->{logger};

    # 1) If user already loaded in memory
    if (my $users = $self->{users}) {

        # a) hash indexed by id_user
        if (exists $users->{$id_user}) {
            my $user = $users->{$id_user};
            my $handle = eval { $user->handle } // eval { $user->nickname };
            return $handle if defined $handle && $handle ne '';
        }

        # b) Old-style : browse all users
        foreach my $k (keys %$users) {
            my $user = $users->{$k} or next;
            my $uid  = eval { $user->id } // $user->{id_user};
            next unless defined $uid && $uid =~ /^\d+$/;
            next unless $uid == $id_user;

            my $handle = eval { $user->handle } // eval { $user->nickname };
            return $handle if defined $handle && $handle ne '';
        }
    }

    # 2) Fallback DB direct
    my $dbh = $self->{dbh} // eval { $self->{db}->dbh };
    return unless $dbh;

    my $row = eval {
        $dbh->selectrow_hashref(
            "SELECT nickname FROM USER WHERE id_user = ?",
            undef, $id_user
        );
    };
    if ($@) {
        $logger->log(1, "SQL Error in getUserhandle(): $@") if $logger;
        return;
    }
    return unless $row;

    my $nickname = $row->{nickname} // '';
    return $nickname ne '' ? $nickname : undef;
}

# Get user autologin status
sub getUserAutologin(@) {
	my ($self,$sMatchingUserHandle) = @_;
	my $sQuery = "SELECT * FROM USER WHERE nickname like ? AND username='#AUTOLOGIN#'";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sMatchingUserHandle) ) {
		$self->{logger}->log(1,"getUserAutologin() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$sth->finish;
			return 1;
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

# Get user id from user handle
sub getIdUser(@) {
	my ($self,$sUserhandle) = @_;
	my $id_user = undef;
	my $sQuery = "SELECT id_user FROM USER WHERE nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserhandle) ) {
		$self->{logger}->log(1,"getIdUser() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_user = $ref->{'id_user'};
		}
	}
	$sth->finish;
	return $id_user;
}

# Get channel object by name
sub get_channel_by_name {
    my ($self, $name) = @_;
    my $sth = $self->{dbh}->prepare("SELECT id_channel FROM CHANNEL WHERE name = ?");
    return undef unless $sth->execute($name);
    if (my $ref = $sth->fetchrow_hashref) {
        require Mediabot::Channel;
        return Mediabot::Channel->new(
            dbh     => $self->{dbh},
            logger  => $self->{logger},
            id      => $ref->{id_channel},
            name    => $name,
        );
    }
    return undef;
}

# Get channel object by id
sub getChannelById {
	my ($self, $id_channel) = @_;
	foreach my $chan_name (keys %{ $self->{channels} }) {
		my $chan = $self->{channels}{$chan_name};
		return $chan if $chan->{id} == $id_channel;
	}
	return undef;
}


# Get console channel from description
sub getConsoleChan {
    my ($self) = @_;

    foreach my $chan (values %{ $self->{channels} }) {
        if ($chan->get_description eq 'console') {
            return (
                $chan->get_id,
                $chan->get_name,
                $chan->get_chanmode,
                $chan->get_key,
            );
        }
    }

    # If no console channel is found
    return undef;
}

# Send a notice to the console channel
sub noticeConsoleChan {
    my ($self, $sMsg) = @_;

    $self->{logger}->log(3, "📢 noticeConsoleChan() called with message: $sMsg");

    my ($id_channel, $name, $chanmode, $key) = getConsoleChan($self);

    $self->{logger}->log(3, "ℹ️ getConsoleChan() returned: id_channel=$id_channel, name=" . 
        (defined $name ? $name : 'undef') . ", mode=" . 
        (defined $chanmode ? $chanmode : 'undef') . ", key=" . 
        (defined $key ? $key : 'undef'));

    if (defined $name && $name ne '') {
        $self->{logger}->log(3, "✅ Sending notice to console channel: $name");
        botNotice($self, $name, $sMsg);
    } else {
        $self->{logger}->log(1, "⚠️ No console channel defined! Run ./configure to set up the bot.");
    }
}


# Log a bot command to the ACTIONS_LOG table, optionally linked to a user and/or channel
sub logBot {
    my ($self, $message, $channel, $action, @args) = @_;

    return unless $self->{dbh};  # Abort if the database handle is not available

    # Try to retrieve the User object from the message
    my $user = $self->get_user_from_message($message);

    my $user_id   = $user ? $user->id       : undef;
    my $user_name = $user ? $user->nickname : 'Unknown user';
    my $hostmask  = $message->prefix        // 'unknown';

    # Retrieve the channel ID from the channel object if available
    my $channel_id;
    if (defined $channel && exists $self->{channels}{$channel}) {
        $channel_id = $self->{channels}{$channel}->get_id;
    }

    # Normalize the argument string (handle undefined values)
    my $args_string = @args ? join(' ', map { defined($_) ? $_ : '' } @args) : '';

    # Prepare the SQL query
    my $sql = "INSERT INTO ACTIONS_LOG (ts, id_user, id_channel, hostmask, action, args) VALUES (?, ?, ?, ?, ?, ?)";
    my $sth = $self->{dbh}->prepare($sql) or do {
        $self->{logger}->log(0, "logBot() SQL prepare failed: $DBI::errstr");
        return;
    };

    # Generate current timestamp in SQL format
    my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime(time));

    # Execute the insert with bound parameters
    unless ($sth->execute($timestamp, $user_id, $channel_id, $hostmask, $action, $args_string)) {
        $self->{logger}->log(0, "logBot() SQL error: $DBI::errstr — Query: $sql");
        return;
    }

    # Format and display a console log message
    my $log_msg = "($user_name : $hostmask) command $action";
    $log_msg .= " $args_string" if $args_string ne '';
    $log_msg .= " on $channel"  if defined $channel;

    $self->noticeConsoleChan($log_msg);
    $self->{logger}->log(3, "logBot() $log_msg");

    $sth->finish;
}



# Log bot action into the CHANNEL_LOG table
# Handles JOIN, PART, PUBLIC, ACTION, NOTICE, KICK, QUIT, etc.
sub logBotAction(@) {
    my ($self, $message, $eventtype, $sNick, $sChannel, $sText) = @_;

    my $sUserhost = "";
    $sUserhost = $message->prefix if defined $message;

    # Optional debug
    if (defined $sChannel) {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype chan = $sChannel nick = $sNick text = $sText");
    } else {
        $self->{logger}->log(5, "logBotAction() eventtype = $eventtype nick = $sNick text = $sText");
    }

    $self->{logger}->log(5, "logBotAction() " . Dumper($message)) if defined($self->{logger}->{debug}) && $self->{logger}->{debug} >= 5;

    my $id_channel;

    # Only look up channel ID if channel is defined (not for QUIT events)
    if (defined $sChannel) {
        my $sQuery = "SELECT id_channel FROM CHANNEL WHERE name = ?";
        my $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth->execute($sChannel)) {
            $self->{logger}->log(1, "logBotAction() SQL Error: $DBI::errstr Query: $sQuery");
            return;
        }

        my $ref = $sth->fetchrow_hashref();
        unless ($ref) {
            $self->{logger}->log(3, "logBotAction() channel not found: $sChannel");
            return;
        }

        $id_channel = $ref->{'id_channel'};
    }

    # Perform the actual insert — ts will be auto-filled by MariaDB
    my $insert_query = <<'SQL';
INSERT INTO CHANNEL_LOG (id_channel, event_type, nick, userhost, publictext)
VALUES (?, ?, ?, ?, ?)
SQL

    my $sth_insert = $self->{dbh}->prepare($insert_query);
    unless ($sth_insert->execute($id_channel, $eventtype, $sNick, $sUserhost, $sText)) {
        $self->{logger}->log(1, "logBotAction() SQL Insert Error: $DBI::errstr Query: $insert_query");
    } else {
        $self->{logger}->log(5, "logBotAction() inserted $eventtype event into CHANNEL_LOG");
    }
}


use Encode qw(encode);

# Send a private message to a target
sub botPrivmsg {
    my ($self, $sTo, $sMsg) = @_;

    return unless defined($sTo);

    my $eventtype = "public";

    if ($sTo =~ /^#/) {
        # Channel mode

        # NoColors chanset check
        my $id_chanset_list = getIdChansetList($self, "NoColors");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset NoColors, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(3, "botPrivmsg() channel $sTo has chanset +NoColors");
                $sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
            }
        }

        # AntiFlood chanset check
        $id_chanset_list = getIdChansetList($self, "AntiFlood");
        if (defined($id_chanset_list) && $id_chanset_list ne "") {
            $self->{logger}->log(4, "botPrivmsg() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sTo, $id_chanset_list);
            if (defined($id_channel_set) && $id_channel_set ne "") {
                $self->{logger}->log(3, "botPrivmsg() channel $sTo has chanset +AntiFlood");
                return undef if checkAntiFlood($self, $sTo);  # Already refactored
            }
        }

        # Log output to console
        $self->{logger}->log(0, "[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");

        # Badword filtering
        my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel = BADWORDS.id_channel AND name = ?";
        my $sth = $self->{dbh}->prepare($sQuery);

        unless ($sth->execute($sTo)) {
            $self->{logger}->log(1, "logBotAction() SQL Error : $DBI::errstr | Query : $sQuery");
        } else {
            while (my $ref = $sth->fetchrow_hashref()) {
                my $sBadwordDb = $ref->{badword};
                if (index(lc($sMsg), lc($sBadwordDb)) != -1) {
                    logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, "$sMsg (BADWORD : $sBadwordDb)");
                    noticeConsoleChan($self, "Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
                    $self->{logger}->log(3, "Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
                    $sth->finish;
                    return;
                }
            }
            logBotAction($self, undef, $eventtype, $self->{irc}->nick_folded, $sTo, $sMsg);
        }
        $sth->finish;
    } else {
        # Private message
        $eventtype = "private";
        $self->{logger}->log(0, "-> *$sTo* $sMsg");
    }

    # Send actual message
    if (defined($sMsg) && $sMsg ne "") {
        # Forcer en UTF-8 et nettoyer les retours à la ligne
        if (utf8::is_utf8($sMsg)) {
            $sMsg = encode("UTF-8", $sMsg);
        }
        $sMsg =~ s/[\r\n]+/ /g;

        $self->{irc}->do_PRIVMSG(target => $sTo, text => $sMsg);
    } else {
        $self->{logger}->log(0, "botPrivmsg() ERROR no message specified to send to target");
    }
}



# Send a private message to a target (action)
sub botAction(@) {
	my ($self,$sTo,$sMsg) = @_;
	if (defined($sTo)) {
		my $eventtype = "public";
		if (substr($sTo, 0, 1) eq '#') {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(3,"botAction() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botAction() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(3,"botAction() channel $sTo has chanset +AntiFlood");
						if (checkAntiFlood($self,$sTo)) {
							return undef;
						}
					}
				}
				$self->{logger}->log(0,"[LIVE] $sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
				my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND name=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sTo) ) {
					$self->{logger}->log(1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					while (my $ref = $sth->fetchrow_hashref()) {
						my $sBadwordDb = $ref->{'badword'};
						my $sBadwordLc = lc $sBadwordDb;
						my $sMsgLc = lc $sMsg;
						if (index($sMsgLc, $sBadwordLc) != -1) {
							logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,"$sMsg (BADWORD : $sBadwordDb)");
							noticeConsoleChan($self,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$self->{logger}->log(3,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$sth->finish;
							return;
						}
					}
					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}
		}
		else {
			$eventtype = "private";
			$self->{logger}->log(0,"-> *$sTo* $sMsg");
		}
		if (defined($sMsg) && ($sMsg ne "")) {
			if (defined($sMsg) && utf8::is_utf8($sMsg)) {
				$sMsg = Encode::encode("UTF-8", $sMsg);
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $sMsg\1" );
			}
			else {
				$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $sMsg\1" );
			}
		}
		else {
			$self->{logger}->log(0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		$self->{logger}->log(0,"botAction() ERROR no target specified to send $sMsg");
	}
}

use Encode qw(encode);

# Send a notice to a target (user or channel)
sub botNotice {
    my ($self, $target, $text) = @_;

    # Sanity check: both target and message must be defined and non-empty
    unless (defined $target && $target ne '') {
        $self->{logger}->log(3, "[DEBUG] botNotice() aborted: target is undefined or empty");
        return;
    }
    unless (defined $text && $text ne '') {
        $self->{logger}->log(3, "[DEBUG] botNotice() aborted: text is undefined or empty");
        return;
    }

    $self->{logger}->log(3, "[DEBUG] botNotice() called with target='$target', text='$text'");

    # Nettoyer les retours à la ligne
    $text =~ s/[\r\n]+/ /g;

    # Encode en UTF-8 pour l'envoi IRC
    my $encoded_text = encode('UTF-8', $text);

    $self->{logger}->log(4, "[DEBUG] botNotice() sending encoded text length=" . length($encoded_text));

    # Envoi du NOTICE
    $self->{irc}->do_NOTICE(
        target => $target,
        text   => $encoded_text
    );

    # Log interne (version lisible)
    $self->{logger}->log(0, "-> -$target- $text");

    # Si c'est un channel NOTICE, log dans l'action log
    if ($target =~ /^#/) {
        $self->{logger}->log(4, "[DEBUG] botNotice() target is a channel, logging to action log");
        logBotAction($self, undef, "notice", $self->{irc}->nick_folded, $target, $text);
    }
}








# Join a channel with an optional key
sub joinChannel(@) {
	my ($self,$channel,$key) = @_;
	if (defined($key) && ($key ne "")) {
		$self->{logger}->log(0,"Trying to join $channel with key $key");
		$self->{irc}->send_message("JOIN", undef, ($channel,$key));
	}
	else {
		$self->{logger}->log(0,"Trying to join $channel");
		$self->{irc}->send_message("JOIN", undef, $channel);
	}
}

# Join channels with auto_join enabled, except console
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

# Set timers at startup
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
			    	$self->{logger}->log(3,"Timer every $duration seconds : $command");
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
sub userOnJoin {
    my ($self, $message, $sChannel, $sNick) = @_;

    # Try to match user from the IRC message
    my $user = $self->get_user_from_message($message);

    if ($user) {
        # Check for channel-specific user settings (auto mode and greet)
        my $sql = "SELECT uc.*, c.* FROM USER_CHANNEL AS uc JOIN CHANNEL AS c ON c.id_channel = uc.id_channel WHERE c.name = ? AND uc.id_user = ?;";
        $self->{logger}->log(4, $sql);
        my $sth = $self->{dbh}->prepare($sql);

        if ($sth->execute($sChannel, $user->id)) {
            if (my $ref = $sth->fetchrow_hashref()) {

                # Apply auto mode if defined
                my $auto_mode = $ref->{automode};
                if (defined $auto_mode && $auto_mode ne '') {
                    if ($auto_mode eq 'OP') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+o", $sNick));
                    }
                    elsif ($auto_mode eq 'VOICE') {
                        $self->{irc}->send_message("MODE", undef, ($sChannel, "+v", $sNick));
                    }
                }

                # Send greet message to channel if defined
                my $greet = $ref->{greet};
                if (defined $greet && $greet ne '') {
                    botPrivmsg($self, $sChannel, "($user->{nickname}) $greet");
                }
            }
        } else {
            $self->{logger}->log(1, "userOnJoin() SQL Error: " . $DBI::errstr . " Query: $sql");
        }
        $sth->finish;
    }

    # Now check if the channel has a default notice to send on join
    my $sql_channel = "SELECT * FROM CHANNEL WHERE name = ?";
    $self->{logger}->log(4, $sql_channel);
    my $sth = $self->{dbh}->prepare($sql_channel);

    if ($sth->execute($sChannel)) {
        if (my $ref = $sth->fetchrow_hashref()) {
            my $notice = $ref->{notice};
            if (defined $notice && $notice ne '') {
                botNotice($self, $sNick, $notice);
            }
        }
    } else {
        $self->{logger}->log(1, "userOnJoin() SQL Error: " . $DBI::errstr . " Query: $sql_channel");
    }

    $sth->finish;
}

# 🧙‍♂️ mbCommandPublic: The Sorting Hat of Mediabot – routes every incantation to the proper spell
sub mbCommandPublic(@) {
    my ($self,$message,$sChannel,$sNick,$botNickTriggered,$sCommand,@tArgs) = @_;
    my $conf = $self->{conf};

    # --- NEW: build a Context object for this invocation ---
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => $sCommand,
        args    => \@tArgs,
    );

    # Command dispatch table
    my %command_map = (
        die         => sub { mbQuit_ctx($ctx) },
        nick        => sub { mbChangeNick_ctx($ctx) },
        addtimer    => sub { mbAddTimer_ctx($ctx) },
        remtimer    => sub { mbRemTimer_ctx($ctx) },
        timers      => sub { mbTimers_ctx($ctx) },
        msg         => sub { msgCmd_ctx($ctx) },
        say         => sub { sayChannel_ctx($ctx) },
        act         => sub { actChannel_ctx($ctx) },
        cstat       => sub { userCstat_ctx($ctx) },
        status      => sub { mbStatus_ctx($ctx) },

        # --- NEW: test command using Context only ---
        echo        => sub { mbEcho($ctx) },

        adduser     => sub { addUser_ctx($ctx) },
        deluser     => sub { delUser_ctx($ctx) },
        users       => sub { userStats_ctx($ctx) },
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
        showcommands=> sub { userShowcommandsChannel_ctx($ctx) },
        chaninfo    => sub { userChannelInfo_ctx($ctx) },
        chanlist    => sub { channelList_ctx($ctx) },
        whoami      => sub { userWhoAmI_ctx($ctx) },
        auth        => sub { userAuthNick_ctx($ctx,) },
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
        colors      => sub { mbColors_ctx($ctx) },
        seen        => sub { mbSeen_ctx($ctx) },
        date        => sub { displayDate_ctx($ctx) },
        weather     => sub { displayWeather_ctx($ctx) },
        meteo       => sub { displayWeather_ctx($ctx) },
        addbadword  => sub { channelAddBadword_ctx($ctx) },
        rembadword  => sub { channelRemBadword_ctx($ctx) },
        ignores     => sub { IgnoresList_ctx($ctx) },
        ignore      => sub { addIgnore_ctx($ctx) },
        unignore    => sub { delIgnore_ctx($ctx) },
        yt          => sub { youtubeSearch_ctx($ctx) },
        song        => sub { displayRadioCurrentSong_ctx($ctx) },
        listeners   => sub { displayRadioListeners_ctx($ctx) },
        nextsong    => sub { radioNext_ctx($ctx) },
        addresponder=> sub { addResponder_ctx($ctx) },
        delresponder=> sub { delResponder_ctx($ctx) },
        update      => sub { update($self,$message,$sNick,$sChannel,@tArgs) },
        lastcom     => sub { lastCom_ctx($ctx) },
        q           => sub { mbQuotes_ctx($ctx) },
        Q           => sub { mbQuotes_ctx($ctx) },
        moduser     => sub { mbModUser_ctx($ctx) },
        antifloodset=> sub { setChannelAntiFloodParams_ctx($ctx) },
        leet        => sub { displayLeetString_ctx($ctx) },
        rehash      => sub { mbRehash_ctx($ctx) },
        play        => sub { playRadio($self,$message,$sNick,$sChannel,@tArgs) },
        rplay       => sub { rplayRadio($self,$message,$sNick,$sChannel,@tArgs) },
        queue       => sub { queueRadio($self,$message,$sNick,$sChannel,@tArgs) },
        next        => sub { nextRadio($self,$message,$sNick,$sChannel,@tArgs) },
        mp3         => sub { mp3_ctx($ctx) },
        exec        => sub { mbExec_ctx($ctx) },
        qlog        => sub { mbChannelLog_ctx($ctx) },
        hailo_ignore => sub { hailo_ignore_ctx($ctx) },
        hailo_unignore => sub { hailo_unignore_ctx($ctx) },
        hailo_status => sub { hailo_status_ctx($ctx) },
        hailo_chatter => sub { hailo_chatter_ctx($ctx) },
        whereis     => sub { mbWhereis_ctx($ctx) },
        birthday    => sub { userBirthday_ctx($ctx) },
        f           => sub { fortniteStats_ctx($ctx) },
        xlogin      => sub { xLogin_ctx($ctx) },
        yomomma     => sub { Yomomma_ctx($ctx) },
        spike       => sub { botPrivmsg($self,$sChannel,"https://teuk.org/In_Spike_Memory.jpg") },
        resolve     => sub { mbResolver_ctx($ctx) },
#        tmdb        => sub { mbTMDBSearch($self,$message,$sNick,$sChannel,@tArgs) },
        tmdblangset => sub { setTMDBLangChannel($self,$message,$sNick,$sChannel,@tArgs) },
        debug       => sub { debug_ctx($ctx) },
        version     => sub { $self->versionCheck($message,$sChannel,$sNick) },
        help        => sub {
            if (defined($tArgs[0]) && $tArgs[0] ne "") {
                botPrivmsg($self,$sChannel,"Help on command $tArgs[0] is not available (unknown command ?). Please visit https://github.com/teuk/mediabot_v3/wiki");
            } else {
                botPrivmsg($self,$sChannel,"Please visit https://github.com/teuk/mediabot_v3/wiki for full documentation on mediabot");
            }
        }
    );

    if (exists $command_map{lc($sCommand)}) {
        $self->{logger}->log(3, "✅ PUBLIC: $sNick triggered .$sCommand on $sChannel");
    }

    # Direct command mapping
    if (exists $command_map{lc($sCommand)}) {
        $command_map{lc($sCommand)}->();
        return;
    }

    # Or check in the database for custom commands
    my $bFound = mbDbCommand($self,$message,$sChannel,$sNick,$sCommand,@tArgs);
    return if $bFound;

    if ($botNickTriggered) {
        my $what = join(" ", $sCommand, @tArgs);

		# 🎯 Special hardcoded patterns for natural replies
		if ($what =~ /how\s+old\s+(are|r)\s+(you|u)/i) {
			# User asks for the bot's age
			displayBirthDate_ctx($ctx);
		} 
		elsif ($what =~ /who.*(your daddy|is your daddy)/i) {
			# User asks who is the bot's owner
			my $owner = getChannelOwner($self, $sChannel);
			my $reply = defined $owner && $owner ne ""
				? "Well I'm registered to $owner on $sChannel, but Te[u]K's my daddy"
				: "I have no clue of who is $sChannel\'s owner, but Te[u]K's my daddy";
			botPrivmsg($self, $sChannel, $reply);
		} 
		elsif ($what =~ /^(thx|thanx|thank you|thanks)$/i) {
			# Gratitude detected
			botPrivmsg($self, $sChannel, "you're welcome $sNick");
		} 
		elsif ($what =~ /who.*StatiK/i) {
			# Reference to StatiK
			botPrivmsg($self, $sChannel, "StatiK is my big brother $sNick, he's awesome !");
		} 
		else {
			# 🧠 Hailo fallback if allowed
			my $id_chanset_list = getIdChansetList($self, "Hailo");
			my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);

			unless (
				is_hailo_excluded_nick($self, $sNick) ||        # Ignore if nick excluded
				$what =~ /^[!]/ ||                              # Ignore if starts with !
				$what =~ /^@{[$self->{conf}->get('main.MAIN_PROG_CMD_CHAR')]}/  # Ignore if starts with bot command prefix
			) {
				my $hailo = get_hailo($self);
				my $sCurrentNick = $self->{irc}->nick_folded;
				$what =~ s/\Q$sCurrentNick\E//g;  # Remove bot name from query

				# Decode user input (fallback to ISO-8859-2 if needed)
				$what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });

				# Get reply from Hailo
				my $sAnswer = $hailo->learn_reply($what);

				# Send if answer is valid and not redundant
				if (defined($sAnswer) && $sAnswer ne "" && $sAnswer !~ /^\Q$what\E\s*\.$/i) {
					$self->{logger}->log(4, "learn_reply $what from $sNick : $sAnswer");
					botPrivmsg($self, $sChannel, $sAnswer);
				}
			}
		}
	} else {
		# Command not recognized and bot not directly triggered
		$self->{logger}->log(3, "Public command '$sCommand' not found");
	}
}

# List all known channels and user count (Master only, Context-based)
sub channelList_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $u   = $user ? (eval { $user->nickname } || eval { $user->handle } || 'unknown') : 'unknown';

        my $msg = "$pfx chanlist command attempt (user $u is not logged in)";
        noticeConsoleChan($self, $msg);

        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Master only (Owner passes because hierarchy is Owner(0) > Master(1) ...)
    unless (eval { $user->has_level('Master') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $u   = eval { $user->nickname } || eval { $user->handle } || 'unknown';

        my $msg = "$pfx chanlist command attempt (Master required; user $u [$lvl])";
        noticeConsoleChan($self, $msg);

        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    my $sql = q{
        SELECT
            C.name AS name,
            COUNT(UC.id_user) AS nbUsers
        FROM CHANNEL C
        LEFT JOIN USER_CHANNEL UC ON UC.id_channel = C.id_channel
        GROUP BY C.id_channel, C.name, C.creation_date
        ORDER BY C.creation_date
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "channelList_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    # Build a single-line response, truncated with "..." if too long
    my $prefix = "[#chan (users)] ";
    my $line   = $prefix;

    # Keep margin (IRC/notice overhead) — conservative
    my $max_len = 400;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $name    = $ref->{name}    // next;
        my $nbUsers = $ref->{nbUsers} // 0;

        my $chunk = "$name ($nbUsers) ";

        if (length($line) + length($chunk) + 3 > $max_len) {  # +3 for "..."
            $line =~ s/\s+$//;
            $line .= " ...";
            last;
        }

        $line .= $chunk;
    }

    $sth->finish;

    # If no channels, still show something clean
    $line = $prefix . "none" if $line eq $prefix;

    botNotice($self, $nick, $line);
    logBot($self, $ctx->message, undef, "chanlist");
    return 1;
}

# versionCheck() - sends version info in channel and alerts if update is available
sub versionCheck {
    my ($self, $message, $sChannel, $sNick) = @_;
    my $conf = $self->{conf};

    # Fetch versions
    my ($local_version, $remote_version) = $self->getVersion();
    
    # Compose base output
    my $bot_name = $conf->get('main.MAIN_PROG_NAME');
    my $sMsg = "$bot_name version: $local_version";

    # Compare and warn if outdated
    if ($remote_version ne "Undefined" && $remote_version ne $local_version) {
        $sMsg .= " (update available: $remote_version)";
    }

    botPrivmsg($self, $sChannel, $sMsg);
    logBot($self, $message, undef, "version", undef);
}

# Extracts reply target from a message (either channel or sender nick)
sub getReplyTarget {
    my ($self, $message, $nick) = @_;
    my $target = $message->{params}[0] // '';
    return ($target =~ /^#/) ? $target : $nick;
}


# 🧙‍♂️ Handle private commands with centralized dispatching and full command set.
sub mbCommandPrivate {
    my ($self, $message, $sNick, $sCommand, @tArgs) = @_;

    # Normalize command
    $sCommand = lc $sCommand;

    # Command dispatch table (legacy handlers + new Context-based ones)
    my %command_table = (
        'pass'              => \&userPass,
        'ident'             => \&userIdent,
        'topic'             => \&userTopicChannel,
        'metadata'          => \&setRadioMetadata,
        'update'            => \&update,
        'play'              => \&playRadio,
        'radiopub'          => \&radioPub,
        'song'              => \&displayRadioCurrentSong_ctx,
        'debug'             => \&mbDebug,

        # New style (Context-based) commands:
        'status'            => \&mbStatus_ctx,
        'echo'              => \&mbEcho,
        'die'               => \&mbQuit_ctx,
        'nick'              => \&mbChangeNick_ctx,
        'addtimer'          => \&mbAddTimer_ctx,
        'remtimer'          => \&mbRemTimer_ctx,
        'timers'            => \&mbTimers_ctx,
        'register'          => \&mbRegister_ctx,
        'msg'               => \&msgCmd_ctx,
        'dump'              => \&dumpCmd_ctx,
        'say'               => \&sayChannel_ctx,
        'act'               => \&actChannel_ctx,
        'adduser'           => \&addUser_ctx,
        'deluser'           => \&delUser_ctx,
        'users'             => \&userStats_ctx,
        'cstat'             => \&userCstat_ctx,
        'login'             => \&userLogin_ctx,
        'userinfo'          => \&userInfo_ctx,
        'addhost'           => \&addUserHost_ctx,
        'addchan'           => \&addChannel_ctx,
        'chanset'           => \&channelSet_ctx,
        'purge'             => \&purgeChannel_ctx,
        'part'              => \&channelPart_ctx,
        'join'              => \&channelJoin_ctx,
        'add'               => \&channelAddUser_ctx,
        'del'               => \&channelDelUser_ctx,
        'modinfo'           => \&userModinfo_ctx,
        'op'                => \&userOpChannel_ctx,
        'deop'              => \&userDeopChannel_ctx,
        'invite'            => \&userInviteChannel_ctx,
        'voice'             => \&userVoiceChannel_ctx,
        'devoice'           => \&userDevoiceChannel_ctx,
        'kick'              => \&userKickChannel_ctx,
        'showcommands'      => \&userShowcommandsChannel_ctx,
        'chaninfo'          => \&userChannelInfo_ctx,
        'whoami'            => \&userWhoAmI_ctx,
        'auth'              => \&userAuthNick_ctx,
        'verify'            => \&userVerifyNick_ctx,
        'access'            => \&userAccessChannel_ctx,
        'addcmd'            => \&mbDbAddCommand_ctx,
        'remcmd'            => \&mbDbRemCommand_ctx,
        'modcmd'            => \&mbDbModCommand_ctx,
        'mvcmd'             => \&mbDbMvCommand_ctx,
        'chowncmd'          => \&mbChownCommand_ctx,
        'showcmd'           => \&mbDbShowCommand_ctx,
        'chanstatlines'     => \&channelStatLines_ctx,
        'whotalk'           => \&whoTalk_ctx,
        'countcmd'          => \&mbCountCommand_ctx,
        'topcmd'            => \&mbTopCommand_ctx,
        'popcmd'            => \&mbPopCommand_ctx,
        'searchcmd'         => \&mbDbSearchCommand_ctx,
        'lastcmd'           => \&mbLastCommand_ctx,
        'owncmd'            => \&mbDbOwnersCommand_ctx,
        'holdcmd'           => \&mbDbHoldCommand_ctx,
        'addcatcmd'         => \&mbDbAddCategoryCommand_ctx,
        'chcatcmd'          => \&mbDbChangeCategoryCommand_ctx,
        'topsay'            => \&userTopSay_ctx,
        'checkhostchan'     => \&mbDbCheckHostnameNickChan_ctx,
        'checkhost'         => \&mbDbCheckHostnameNick_ctx,
        'checknick'         => \&mbDbCheckNickHostname_ctx,
        'greet'             => \&userGreet_ctx,
        'nicklist'          => \&channelNickList_ctx,
        'rnick'             => \&randomChannelNick_ctx,
        'birthdate'         => \&displayBirthDate_ctx,
        'ignores'           => \&IgnoresList_ctx,
        'ignore'            => \&addIgnore_ctx,
        'unignore'          => \&delIgnore_ctx,
        'lastcom'           => \&lastCom_ctx,
        'moduser'           => \&mbModUser_ctx,
        'antifloodset'      => \&setChannelAntiFloodParams_ctx,
        'rehash'            => \&mbRehash_ctx,
    );

    # Commands that expect a Mediabot::Context object
    my %ctx_commands = map { $_ => 1 } qw(
        status
        echo
        die
        nick
        addtimer
        remtimer
        timers
        register
        msg
        dump
        say
        act
        adduser
        deluser
        users
        cstat
        login
        userinfo
        addhost
        addchan
        chanset
        purge
        part
        join
        add
        del
        modinfo
        op
        deop
        invite
        voice
        devoice
        kick
        showcommands
        chaninfo
        chanlist
        whoami
        auth
        verify
        access
        addcmd
        remcmd
        modcmd
        mvcmd
        chowncmd
        showcmd
        chanstatlines
        whotalk
        countcmd
        topcmd
        popcmd
        searchcmd
        lastcmd
        owncmd
        holdcmd
        addcatcmd
        chcatcmd
        topsay
        checkhostchan
        checkhost
        checknick
        greet
        nicklist
        rnick
        birthdate
        ignores
        ignore
        unignore
        moduser
        lastcom
        antifloodset
        rehash
    );

    # Dispatch the command if found
    if (my $handler = $command_table{$sCommand}) {

        my $reply_target = $self->getReplyTarget($message, $sNick);

        # Context-based path
        if ($ctx_commands{$sCommand}) {

            my $ctx = Mediabot::Context->new(
                bot     => $self,
                message => $message,
                nick    => $sNick,
                channel => $reply_target,
                command => $sCommand,
                args    => \@tArgs,
            );

            return $handler->($ctx);
        }

        # Legacy path: keep old signature for now
        return $handler->($self, $message, $reply_target, $sNick, @tArgs);

    } else {
        $self->{logger}->log(3, $message->prefix . " Private command '$sCommand' not found");
        return undef;
    }
}

# Handle bot quit command (Master only)
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
sub checkAuth(@) {
	my ($self,$iUserId,$sUserHandle,$sPassword) = @_;
	my $sCheckAuthQuery = "SELECT * FROM USER WHERE id_user=? AND nickname=? AND password=PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($iUserId,$sUserHandle,$sPassword)) {
		$self->{logger}->log(1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
			my $sth2 = $self->{dbh}->prepare($sQuery);
			unless ($sth2->execute($iUserId)) {
				$self->{logger}->log(1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				return 0;
			}
			$sQuery = "UPDATE USER SET last_login=? WHERE id_user =?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute(strftime('%Y-%m-%d %H:%M:%S', localtime(time)),$iUserId)) {
				$self->{logger}->log(1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			return 1;
		}
		else {
			return 0;
		}
	}
	$sth->finish;
}

# Context-based: Handle user login via private message (strictly DB nickname + password)
sub userLogin_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $sNick = $ctx->nick;

    my @tArgs = @{ $ctx->args // [] };

    # If parser prepended caller nick: [caller, user, pass] -> shift caller
    if (@tArgs >= 3 && defined $sNick && $sNick ne '' && defined $tArgs[0] && lc($tArgs[0]) eq lc($sNick)) {
        shift @tArgs;
    }

    # Expect: login <nickname_in_db> <password>
    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax error: /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        return;
    }

    my $typed_user = $tArgs[0];     # MUST match USER.nickname strictly (e.g., 'teuk')
    my $typed_pass = $tArgs[1];

    my $dbh = eval { $self->{db}->dbh };
    unless ($dbh) {
        botNotice($self, $sNick, "Internal error (DB unavailable).");
        return;
    }

    # 1) Fetch account strictly by DB nickname
    my ($id_user, $db_nick, $stored_hash, $level_id);
    my $ok = eval {
        my $sth = $dbh->prepare(q{
            SELECT id_user, nickname, password, id_user_level
            FROM USER
            WHERE nickname = ?
            LIMIT 1
        });
        $sth->execute($typed_user);
        ($id_user, $db_nick, $stored_hash, $level_id) = $sth->fetchrow_array;
        $sth->finish;
        1;
    };

    unless ($ok) {
        botNotice($self, $sNick, "Internal error (query failed).");
        return;
    }

    unless (defined $id_user) {
        botNotice($self, $sNick, "Login failed (Unknown user).");
        my $msg = ($ctx->message->prefix // '') . " Failed login (Unknown user: $typed_user)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Failed (Unknown user)");
        return;
    }

    unless (defined $stored_hash && $stored_hash ne "") {
        botNotice($self, $sNick, "Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass <password>");
        return;
    }

    # 2) Compute MariaDB PASSWORD() candidate and compare
    my ($calc_hash) = eval { $dbh->selectrow_array('SELECT PASSWORD(?)', undef, $typed_pass) };
    unless (defined $calc_hash) {
        botNotice($self, $sNick, "Internal error (hash compute failed).");
        return;
    }

    if ($stored_hash eq $calc_hash) {
        # 3) Mark authenticated and stamp last_login
        eval {
            $dbh->do('UPDATE USER SET auth=1, last_login=NOW() WHERE id_user=?', undef, $id_user);
            1;
        };

        # Best-effort in-memory flags (ignore if structure differs)
        eval {
            $self->{auth}->{logged_in}{$id_user} = 1 if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{logged_in}) eq 'HASH';
            $self->{auth}->{sessions}{lc $db_nick} = { id_user => $id_user, auth => 1 } if ref($self->{auth}) eq 'HASH' && ref($self->{auth}->{sessions}) eq 'HASH';
            1;
        };

        my $level_desc = eval { $self->{auth}->level_id_to_desc($level_id) } // $level_id // "unknown";
        botNotice($self, $sNick, "Login successful as $db_nick (Level: $level_desc)");

        my $msg = ($ctx->message->prefix // '') . " Successful login as $db_nick (Level: $level_desc)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Success");
    }
    else {
        botNotice($self, $sNick, "Login failed (Bad password).");
        my $msg = ($ctx->message->prefix // '') . " Failed login (Bad password)";
        $self->noticeConsoleChan($msg) if $self->can('noticeConsoleChan');
        logBot($self, $ctx->message, undef, "login", $typed_user, "Failed (Bad password)");
    }
}

# check user Level
sub checkUserLevel(@) {
	my ($self,$iUserLevel,$sLevelRequired) = @_;
	$self->{logger}->log(3,"isUserLevel() $iUserLevel vs $sLevelRequired");
	my $sQuery = "SELECT level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevelRequired)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $level = $ref->{'level'};
			if ( $iUserLevel <= $level ) {
				$sth->finish;
				return 1;
			}
			else {
				$sth->finish;
				return 0;
			}
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

# Count the number of users in the database
sub userCount(@) {
	my ($self) = @_;
	my $sQuery = "SELECT count(*) as nbUser FROM USER";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$self->{logger}->log(3,"userCount() " . $ref->{'nbUser'});
			my $nbUser = $ref->{'nbUser'};
			$sth->finish;
			return($nbUser);
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

sub getMessageHostmask(@) {
	my ($self,$message) = @_;
	my $sHostmask = $message->prefix;
	$sHostmask =~ s/.*!//;
	if (substr($sHostmask,0,1) eq '~') {
		$sHostmask =~ s/.//;
	}
	return ("*" . $sHostmask);
}

sub getIdUserLevel(@) {
	my ($self,$sLevel) = @_;
	my $sQuery = "SELECT id_user_level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user_level = $ref->{'id_user_level'};
			$sth->finish;
			return $id_user_level;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

sub getLevel(@) {
	my ($self,$sLevel) = @_;
	my $sQuery = "SELECT level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $level = $ref->{'level'};
			$sth->finish;
			return $level;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

sub getLevelUser(@) {
	my ($self,$sUserHandle) = @_;
	my $sQuery = "SELECT level FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $level = $ref->{'level'};
			$sth->finish;
			return $level;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

sub userAdd {
    my ($self, $hostmask, $nickname, $plain_password, $level_name, $username) = @_;
    my $dbh    = $self->{dbh} || ($self->{db} && $self->{db}->dbh);
    my $logger = $self->{logger};

    return undef unless $dbh;

    my %LEVEL = ( owner => 1, master => 2, administrator => 3, user => 4 );
    my $level_id = $LEVEL{ lc($level_name // 'user') } // 4;

    # password: si undef => NULL (évite PASSWORD(NULL))
    my $pass_sql = defined $plain_password ? 'PASSWORD(?)' : 'NULL';

    my $sql = qq{
        INSERT INTO USER (creation_date, hostmasks, nickname, password, username, id_user_level, auth)
        VALUES (NOW(), ?, ?, $pass_sql, ?, ?, 0)
    };

    my @bind = ($hostmask, $nickname);
    push @bind, $plain_password if defined $plain_password;
    push @bind, ($username, $level_id);

    my $sth = $dbh->prepare($sql);
    my $ok  = $sth->execute(@bind);
    $sth->finish;

    unless ($ok) {
        $logger->log(1, "userAdd() INSERT failed: $DBI::errstr");
        return undef;
    }

    my $id = $dbh->{mysql_insertid} || eval { $dbh->last_insert_id(undef, undef, 'USER', 'id_user') };
    $logger->log(0, "✅ userAdd() created user '$nickname' (id_user=$id, level_id=$level_id)");
    return $id;
}





sub registerChannel(@) {
	my ($self,$message,$sNick,$id_channel,$id_user) = @_;
	my $sQuery = "INSERT INTO USER_CHANNEL (id_user,id_channel,level) VALUES (?,?,500)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user,$id_channel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		$sth->finish;
		return 0;
	}
	else {
		logBot($self,$message,undef,"registerChannel","$sNick registered user : $id_user level 500 on channel : $id_channel");
		$sth->finish;
		return 1;
	}
}

# Context-based register command: allows first user creation: register <nickname_in_db> <password>
sub mbRegister_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my ($user, $pass) = @args;

    unless (defined($user) && $user ne '' && defined($pass) && $pass ne '') {
        $self->botNotice($nick, "Syntax: register <username> <password>");
        return;
    }

    if (userCount($self) > 0) {
        $self->{logger}->log(0, "Register attempt ignored (users already exist): " . ($ctx->message->prefix // ''));
        return;
    }

    my $mask = getMessageHostmask($self, $ctx->message);
    my $id = userAdd($self, $mask, $user, $pass, "Owner");

    if (defined $id) {
        $self->botNotice($nick, "Registered $user as Owner (id_user: $id) with hostmask $mask");
        logBot($self, $ctx->message, undef, 'register', 'Success');
    } else {
        $self->botNotice($nick, "Register failed");
        logBot($self, $ctx->message, undef, 'register', 'Failed');
    }
}

# Context-based: Allows the bot Owner to send a raw IRC command manually
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
sub sayChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Administrator');

    # tolerate "nick injected as first arg"
    shift @args if @args && defined($args[0]) && lc($args[0]) eq lc($nick);

    my $chan = shift(@args) // '';
    my $text = join(' ', @args);

    for ($chan, $text) { $_ //= ''; s/^\s+|\s+$//g; }

    unless ($chan ne '' && $text ne '') {
        $self->botNotice($nick, "Syntax: say <#channel> <text>");
        return;
    }

    $chan = "#$chan" unless $chan =~ /^#/;

    botPrivmsg($self, $chan, $text);
    logBot($self, $ctx->message, undef, 'say', $chan, $text);
}

# Context-based: Allows an Administrator to send an /me action to a channel
sub actChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Administrator');

    # tolerate "nick injected as first arg"
    shift @args if @args && defined($args[0]) && lc($args[0]) eq lc($nick);

    my $chan = shift(@args) // '';
    my $text = join(' ', @args);

    for ($chan, $text) { $_ //= ''; s/^\s+|\s+$//g; }

    unless ($chan ne '' && $text ne '') {
        $self->botNotice($nick, "Syntax: act <#channel> <text>");
        return;
    }

    $chan = "#$chan" unless $chan =~ /^#/;

    botAction($self, $chan, $text);
    logBot($self, $ctx->message, undef, 'act', $chan, $text);
}

sub setConnectionTimestamp(@) {
	my ($self,$iConnectionTimestamp) = @_;
	$self->{iConnectionTimestamp} = $iConnectionTimestamp;
}

sub getConnectionTimestamp(@) {
	my $self = shift;
	return $self->{iConnectionTimestamp};
}

sub setLastRadioPub(@) {
	my ($self,$iLastRadioPub) = @_;
	$self->{iLastRadioPub} = $iLastRadioPub;
}

sub getLastRadioPub(@) {
	my $self = shift;
	return $self->{iLastRadioPub};
}

sub setLastRandomQuote(@) {
	my ($self,$iLastRandomQuote) = @_;
	$self->{iLastRandomQuote} = $iLastRandomQuote;
}

sub getLastRandomQuote(@) {
	my $self = shift;
	return $self->{iLastRandomQuote};
}

sub setQuit(@) {
	my ($self,$iQuit) = @_;
	$self->{Quit} = $iQuit;
}

sub getQuit(@) {
	my $self = shift;
	return $self->{Quit};
}

# Handle bot nickname change (Owner only)
sub mbChangeNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $new_nick = $args[0];

    return unless $ctx->require_level('Owner');

    unless (defined $new_nick && $new_nick ne '') {
        $self->botNotice($nick, "Syntax: nick <new_nick>");
        return;
    }

    $self->{irc}->change_nick($new_nick);
    logBot($self, $ctx->message, undef, 'nick', $new_nick);
}

# Handle addtimer command (Owner only, Context-based)
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
            $self->{logger}->log(3, "Timer [$name] tick: $cmd");
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
sub userPass {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Ensure the password is provided
    if (defined($tArgs[0]) && $tArgs[0] ne "") {

        # Attempt to find the user associated with the IRC message
        my $user = $self->get_user_from_message($message);

        if (defined($user) && defined($user->nickname)) {

            my $sNewPassword = $tArgs[0];
            my $sQuery = "UPDATE USER SET password=PASSWORD(?) WHERE id_user=?";
            my $sth = $self->{dbh}->prepare($sQuery);

            # Try to update the password in the database
            unless ($sth->execute($sNewPassword, $user->id)) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr - Query: $sQuery");
                $sth->finish;
                return 0;
            } else {
                # Log and notify success
                my $msg = "userPass() Set password for $sNick (user_id: " . $user->id . ", host: " . $message->prefix . ")";
                $self->{logger}->log(3, $msg);
                noticeConsoleChan($self, $msg);

                botNotice($self, $sNick, "Password set.");
                botNotice($self, $sNick, "You may now login with /msg " . $self->{irc}->nick_folded . " login " . $user->nickname . " <password>");
                logBot($self, $message, undef, "pass", "Success");

                $sth->finish;
                return 1;
            }

        } else {
            # Unknown user or hostmask not registered
            my $msg = $message->prefix . " Failed pass command, unknown user $sNick (" . $message->prefix . ")";
            noticeConsoleChan($self, $msg);
            logBot($self, $message, undef, "pass", "Failed - unknown user $sNick");
            return 0;
        }
    }
}


sub userIdent(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	#login <username> <password>
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
		my ($id_user,$bAlreadyExists) = checkAuthByUser($self,$message,$tArgs[0],$tArgs[1]);
		if ( $bAlreadyExists ) {
			botNotice($self,$sNick,"This hostmask is already set");
		}
		elsif ( $id_user ) {
			botNotice($self,$sNick,"Ident successfull as " . $tArgs[0] . " new hostmask added");
			my $sNoticeMsg = $message->prefix . " Ident successfull from $sNick as " . $tArgs[0] . " id_user : $id_user";
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"ident",$tArgs[0]);
		}
		else {
			my $sNoticeMsg = $message->prefix . " Ident failed (Bad password)";
			$self->{logger}->log(0,$sNoticeMsg);
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"ident",$sNoticeMsg);
		}
	}
}

sub checkAuthByUser(@) {
	my ($self,$message,$sUserHandle,$sPassword) = @_;
	my $sCheckAuthQuery = "SELECT * FROM USER WHERE nickname=? AND password=PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($sUserHandle,$sPassword)) {
		$self->{logger}->log(1,"checkAuthByUser() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		$sth->finish;
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = getMessageHostmask($self,$message);
			$self->{logger}->log(3,"checkAuthByUser() Hostmask : $sHostmask to add to $sUserHandle");
			my $sCurrentHostmasks = $ref->{'hostmasks'};
			my $id_user = $ref->{'id_user'};
			if ( $sCurrentHostmasks =~ /\Q$sHostmask/ ) {
				return ($id_user,1);
			}
			else {
				my $sNewHostmasks = "$sCurrentHostmasks,$sHostmask";
				my $Query = "UPDATE USER SET hostmasks=? WHERE id_user=?";
				my $sth = $self->{dbh}->prepare($Query);
				unless ($sth->execute($sNewHostmasks,$id_user)) {
					$self->{logger}->log(1,"checkAuthByUser() SQL Error : " . $DBI::errstr . " Query : " . $Query);
					$sth->finish;
					return (0,0);
				}
				$sth->finish;
				return ($id_user,0);
			}
		}
		else {
			$sth->finish;
			return (0,0);
		}
	}
}

# Context-based cstat: one-line output, truncated with "..."
sub userCstat_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Administrator only
    return unless $ctx->require_level('Administrator');

    my $query = q{
        SELECT USER.nickname, USER_LEVEL.description
        FROM USER, USER_LEVEL
        WHERE USER.id_user_level = USER_LEVEL.id_user_level
          AND USER.auth = 1
        ORDER BY USER_LEVEL.level
    };

    my $sth = $self->{dbh}->prepare($query);
    unless ($sth->execute) {
        $self->{logger}->log(1, "userCstat_ctx() SQL Error: $DBI::errstr");
        botNotice($self, $nick, 'Internal error (DB query failed).');
        return;
    }

    my @entries;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $u = $ref->{nickname}    // '';
        my $d = $ref->{description} // '';
        push @entries, "$u ($d)" if $u ne '';
    }
    $sth->finish;

    my $line = 'Authenticated users: ' . join(' ', @entries);

    # Keep it one line; truncate if too long
    my $max = 380;  # keep headroom under IRC 512 bytes
    if (length($line) > $max) {
        $line = substr($line, 0, $max - 3) . '...';
    }

    botNotice($self, $nick, $line);
    logBot($self, $ctx->message, undef, 'cstat', undef);
}

# Context-based: Add a new user with a specified hostmask and optional level
sub addUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = @{ $ctx->args // [] };

    my $user = $ctx->require_level("Master") or return;

    my ($name, $mask, $level) = @args;
    $level //= 'User';

    unless ($name && $mask && $mask =~ /@/) {
        botNotice($self, $nick, "Syntax: adduser <nick> <hostmask> [level]");
        return;
    }

    if (getIdUser($self, $name)) {
        botNotice($self, $nick, "User $name already exists");
        return;
    }

    my $id = userAdd($self, $mask, $name, undef, $level);
    botNotice($self, $nick, "User $name added (id=$id, level=$level)");

    logBot($self, $ctx->message, undef, "adduser", $name);
}

sub getUserLevelDesc(@) {
	my ($self,$level) = @_;
	my $sQuery = "SELECT description FROM USER_LEVEL WHERE level=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($level)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sDescription = $ref->{'description'};
			$sth->finish;
			return $sDescription;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

# Context-based: Display user statistics to Master level users
sub userStats_ctx {
    my ($ctx) = @_;

    return unless $ctx->require_level('Master');

    my $bot  = $ctx->bot;
    my $nick = $ctx->nick;

    my $sth = $bot->{dbh}->prepare(
        "SELECT COUNT(*) AS nbUsers FROM USER"
    );
    $sth->execute;
    my ($total) = $sth->fetchrow_array;
    $sth->finish;

    $bot->botNotice($nick, "Number of users: $total");

    $sth = $bot->{dbh}->prepare(
        "SELECT description, COUNT(*) 
         FROM USER 
         JOIN USER_LEVEL USING(id_user_level)
         GROUP BY description
         ORDER BY level"
    );
    $sth->execute;

    while (my ($desc, $count) = $sth->fetchrow_array) {
        $bot->botNotice($nick, "$desc ($count)");
    }
    $sth->finish;
}


# Context-based userinfo command (Master only)
sub userInfo_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Master privilege
    $ctx->require_level('Master') or return;

    # Expected: userinfo <username>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target = $args[0] // '';
    if ($target eq '') {
        botNotice($self, $nick, "Syntax: userinfo <username>");
        return;
    }

    my $sQuery = q{
        SELECT *
        FROM USER, USER_LEVEL
        WHERE USER.id_user_level = USER_LEVEL.id_user_level
          AND nickname LIKE ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target)) {
        $self->{logger}->log(1, "userInfo_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_user     = $ref->{id_user}        // '?';
        my $nickname    = $ref->{nickname}       // '?';
        my $created     = $ref->{creation_date}  // 'N/A';
        my $last_login  = $ref->{last_login}     // 'never';
        my $hostmasks   = $ref->{hostmasks}      // 'none';
        my $password    = $ref->{password};
        my $info1       = $ref->{info1}          // 'N/A';
        my $info2       = $ref->{info2}          // 'N/A';
        my $desc        = $ref->{description}    // 'Unknown';
        my $auth        = $ref->{auth}           // 0;
        my $username    = $ref->{username}       // 'N/A';

        my $sAuthStatus = $auth ? "logged in" : "not logged in";
        my $sPassStatus = (defined($password) && $password ne '') ? "Password set" : "Password is not set";
        my $sAutoLogin  = ($username eq "#AUTOLOGIN#") ? "ON" : "OFF";

        botNotice($self, $nick, "User: $nickname (Id: $id_user - $desc)");
        botNotice($self, $nick, "Created: $created | Last login: $last_login");
        botNotice($self, $nick, "$sPassStatus | Status: $sAuthStatus | AUTOLOGIN: $sAutoLogin");
        botNotice($self, $nick, "Hostmasks: $hostmasks");
        botNotice($self, $nick, "Info: $info1 | $info2");
    } else {
        botNotice($self, $nick, "User '$target' does not exist.");
    }

    my $sNoticeMsg = $ctx->message->prefix . " userinfo on $target";
    $self->{logger}->log(0, $sNoticeMsg);
    noticeConsoleChan($self, $sNoticeMsg);
    logBot($self, $ctx->message, undef, "userinfo", $sNoticeMsg);

    $sth->finish if $sth;
}

# Context-based addhost command: add a new hostmask to an existing user (Master only)
sub addUserHost_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Master privilege
    $ctx->require_level('Master') or return;

    # Expected: addhost <username> <hostmask>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target_user  = $args[0] // '';
    my $new_hostmask = $args[1] // '';

    if ($target_user eq '' || $new_hostmask eq '') {
        botNotice($self, $nick, "Syntax: addhost <username> <hostmask>");
        return;
    }

    # Basic sanitization (keep behavior: strip ';')
    $new_hostmask =~ s/;//g;
    $new_hostmask =~ s/^\s+|\s+$//g;

    $self->{logger}->log(3, "addUserHost_ctx() target='$target_user' hostmask='$new_hostmask'");

    my $id_user = getIdUser($self, $target_user);
    unless (defined $id_user) {
        botNotice($self, $nick, "User $target_user does not exist");
        logBot($self, $ctx->message, undef, "addhost", "User $target_user does not exist");
        return;
    }

    # Fetch current hostmasks
    my $sQuery = "SELECT hostmasks FROM USER WHERE id_user = ?";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($id_user)) {
        $self->{logger}->log(1, "addUserHost_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        return;
    }

    my $hostmasks_str = '';
    if (my $ref = $sth->fetchrow_hashref()) {
        $hostmasks_str = $ref->{hostmasks} // '';
    }
    $sth->finish if $sth;

    my @hostmasks = grep { defined($_) && $_ ne '' }
                    map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x }
                    split /,/, $hostmasks_str;

    # Check duplicate
    if (grep { $_ eq $new_hostmask } @hostmasks) {
        my $msg = $ctx->message->prefix . " Hostmask $new_hostmask already exists for user $target_user";
        $self->{logger}->log(0, $msg);
        noticeConsoleChan($self, $msg);
        logBot($self, $ctx->message, undef, "addhost", $msg);
        return;
    }

    push @hostmasks, $new_hostmask;
    my $updated = join(',', @hostmasks);

    # Update DB
    $sQuery = "UPDATE USER SET hostmasks = ? WHERE id_user = ?";
    $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($updated, $id_user)) {
        $self->{logger}->log(1, "addUserHost_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        return;
    }
    $sth->finish if $sth;

    my $msg = $ctx->message->prefix . " Hostmask $new_hostmask added for user $target_user";
    $self->{logger}->log(0, $msg);
    noticeConsoleChan($self, $msg);
    logBot($self, $ctx->message, undef, "addhost", $msg);

    botNotice($self, $nick, "Hostmask added for user $target_user");
}

# Context-based addchan command: add a new channel and register it with a user (Administrator only)
sub addChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Require Administrator privilege
    $ctx->require_level('Administrator') or return;

    # Args: addchan <#channel> <user>
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    $self->{logger}->log(3, "addChannel_ctx() raw args: " . join(' ', map { defined $_ ? $_ : '<undef>' } @args));

    # Take last 2 args to avoid any parser quirks
    my ($sChannel, $sUser) = @args >= 2 ? @args[-2, -1] : ('','');

    $sChannel //= '';
    $sUser    //= '';
    $sChannel =~ s/^\s+|\s+$//g;
    $sUser    =~ s/^\s+|\s+$//g;

    unless ($sChannel ne '' && $sUser ne '' && $sChannel =~ /^#/) {
        $self->{logger}->log(2, "addChannel_ctx() missing/malformed args: channel='$sChannel' user='$sUser'");
        botNotice($self, $nick, "Syntax: addchan <#channel> <user>");
        return;
    }

    $self->{logger}->log(0, "$nick issued addchan command: $sChannel $sUser");

    # Check if target user exists
    my $id_target_user = getIdUser($self, $sUser);
    unless ($id_target_user) {
        botNotice($self, $nick, "User $sUser does not exist");
        return;
    }

    # Build channel object
    my $channel = Mediabot::Channel->new({
        name => $sChannel,
        dbh  => $self->{dbh},
        irc  => $self->{irc},
    });

    # Already exists?
    if (my $existing_id = $channel->exists_in_db) {
        botNotice($self, $nick, "Channel $sChannel already exists");
        return;
    }

    # Create in DB
    my $id_channel = $channel->create_in_db;
    unless ($id_channel) {
        $self->{logger}->log(1, "addChannel_ctx() failed SQL insert for $sChannel");
        botNotice($self, $nick, "Error: failed to create channel $sChannel in DB.");
        return;
    }

    # Store object in channel hash
    $self->{channels}{lc($sChannel)} = $channel;

    # Join + register
    joinChannel($self, $sChannel, undef);

    my $registered = registerChannel($self, $ctx->message, $nick, $id_channel, $id_target_user);
    unless ($registered) {
        $self->{logger}->log(1, "registerChannel failed $sChannel $sUser");
        botNotice($self, $nick, "Channel created but registration with user $sUser failed.");
    } else {
        $self->{logger}->log(0, "registerChannel successful $sChannel $sUser");
        botNotice($self, $nick, "Channel $sChannel added and linked to $sUser.");
    }

    logBot($self, $ctx->message, undef, "addchan", $sChannel, $sUser);
    noticeConsoleChan($self, $ctx->message->prefix . " addchan command: added $sChannel (id_channel: $id_channel) linked to $sUser");

    return $id_channel;
}

# Display syntax help for chanset command (Context-based)
sub channelSetSyntax_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    botNotice($self, $nick, "Syntax: chanset [#channel] key <key>");
    botNotice($self, $nick, "Syntax: chanset [#channel] chanmode <+chanmode>");
    botNotice($self, $nick, "Syntax: chanset [#channel] description <description>");
    botNotice($self, $nick, "Syntax: chanset [#channel] auto_join <on|off>");
    botNotice($self, $nick, "Syntax: chanset [#channel] <+value|-value>");
}

# Context-based chanset command (Administrator OR channel-level >= 450)
sub channelSet_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # If first arg is a channel, it overrides target channel (legacy syntax)
    my $target_channel = $ctx->channel // '';
    if (@args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    }

    # In private messages, ctx->channel is often the nick, so require explicit #channel
    unless (defined($target_channel) && $target_channel ne '' && $target_channel =~ /^#/) {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Must be logged in at least (require_level will enforce auth)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Permission: Administrator OR per-channel level >= 450
    my $is_admin = $user->has_level($self, 'Administrator') ? 1 : 0;
    my $is_chan  = checkUserChannelLevel($self, $ctx->message, $target_channel, $user->id, 450) ? 1 : 0;

    unless ($is_admin || $is_chan) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Must have at least: key/chanmode/auto_join/description <value...>
    # or a single +Something / -Something
    unless (
        (@args >= 2 && defined($args[0]) && $args[0] ne '' && defined($args[1]) && $args[1] ne '')
        || (@args >= 1 && defined($args[0]) && $args[0] =~ /^[+-]/)
    ) {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Resolve channel object (hash is usually keyed in lowercase)
    my $k = lc($target_channel);
    unless (exists $self->{channels}{$k} && $self->{channels}{$k}) {
        botNotice($self, $nick, "Unknown channel $target_channel");
        return;
    }

    my $channel    = $self->{channels}{$k};
    my $id_channel = eval { $channel->get_id } // undef;
    unless ($id_channel) {
        botNotice($self, $nick, "Internal error: channel id unavailable for $target_channel");
        return;
    }

    # --- command handling ---
    if ($args[0] eq 'key') {
        my $val = $args[1];
        $channel->set_key($val);
        botNotice($self, $nick, "Set $target_channel key $val");
    }
    elsif ($args[0] eq 'chanmode') {
        my $val = $args[1];
        $channel->set_chanmode($val);
        botNotice($self, $nick, "Set $target_channel chanmode $val");
    }
    elsif ($args[0] eq 'auto_join') {
        my $v = lc($args[1] // '');
        my $flag = ($v eq 'on') ? 1 : (($v eq 'off') ? 0 : undef);
        unless (defined $flag) {
            channelSetSyntax_ctx($ctx);
            return;
        }
        $channel->set_auto_join($flag);
        botNotice($self, $nick, "Set $target_channel auto_join $v");
    }
    elsif ($args[0] eq 'description') {
        shift @args; # remove "description"
        my $desc = join(' ', @args);
        if ($desc =~ /console/i) {
            botNotice($self, $nick, "You cannot set $target_channel description to $desc");
            return;
        }
        $channel->set_description($desc);
        botNotice($self, $nick, "Set $target_channel description $desc");
    }
    elsif ($args[0] =~ /^([+-])(\w+)$/) {
        my ($op, $chanset) = ($1, $2);

        my $id_chanset_list = getIdChansetList($self, $chanset);
        unless ($id_chanset_list) {
            botNotice($self, $nick, "Undefined chanset $chanset");
            return;
        }

        my $id_channel_set = getIdChannelSet($self, $target_channel, $id_chanset_list);

        if ($op eq '+') {
            if ($id_channel_set) {
                botNotice($self, $nick, "Chanset +$chanset is already set");
                return;
            }

            my $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL_SET (id_channel, id_chanset_list) VALUES (?, ?)");
            $sth->execute($id_channel, $id_chanset_list);
            $sth->finish if $sth;

            botNotice($self, $nick, "Chanset +$chanset applied to $target_channel");

            # Keep legacy side effects
            setChannelAntiFlood($self, $ctx->message, $nick, $target_channel, @args) if $chanset =~ /^AntiFlood$/i;
            set_hailo_channel_ratio($self, $target_channel, 97) if $chanset =~ /^HailoChatter$/i;
        }
        else {
            unless ($id_channel_set) {
                botNotice($self, $nick, "Chanset +$chanset is not set");
                return;
            }

            my $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL_SET WHERE id_channel_set=?");
            $sth->execute($id_channel_set);
            $sth->finish if $sth;

            botNotice($self, $nick, "Chanset -$chanset removed from $target_channel");
        }
    }
    else {
        channelSetSyntax_ctx($ctx);
        return;
    }

    # Log (keep legacy-ish payload)
    logBot($self, $ctx->message, $target_channel, "chanset", $target_channel, @args);
    return $id_channel;
}

# Retrieve the ID of a chanset from the CHANSET_LIST table
sub getIdChansetList {
    my ($self, $sChansetValue) = @_;

    # Basic sanity check
    unless (defined $sChansetValue && $sChansetValue ne '') {
        $self->{logger}->log(2, "⚠️ getIdChansetList() called without a chanset value");
        return undef;
    }

    $self->{logger}->log(3, "🔍 getIdChansetList() looking up chanset: '$sChansetValue'");

    my $id_chanset_list;
    my $sQuery = "SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?";
    my $sth = $self->{dbh}->prepare($sQuery);

    if (!$sth->execute($sChansetValue)) {
        # Log SQL error
        $self->{logger}->log(1, "❌ SQL Error in getIdChansetList(): " . $DBI::errstr . " | Query: $sQuery");
    }
    else {
        if (my $ref = $sth->fetchrow_hashref()) {
            $id_chanset_list = $ref->{id_chanset_list};
            $self->{logger}->log(3, "✅ getIdChansetList() found id_chanset_list=$id_chanset_list for chanset '$sChansetValue'");
        }
        else {
            $self->{logger}->log(3, "ℹ️ getIdChansetList() no result found for chanset '$sChansetValue'");
        }
    }

    $sth->finish;
    return $id_chanset_list;
}


# Retrieve the ID of a channel set from CHANNEL_SET table for a given channel and chanset list ID
sub getIdChannelSet {
    my ($self, $sChannel, $id_chanset_list) = @_;

    # Basic sanity checks
    unless (defined $sChannel && $sChannel ne '') {
        $self->{logger}->log(2, "⚠️ getIdChannelSet() called without a channel name");
        return undef;
    }
    unless (defined $id_chanset_list && $id_chanset_list ne '') {
        $self->{logger}->log(2, "⚠️ getIdChannelSet() called without an id_chanset_list");
        return undef;
    }

    $self->{logger}->log(3, "🔍 getIdChannelSet() searching for chanset_list_id=$id_chanset_list in channel '$sChannel'");

    my $id_channel_set;
    my $sQuery = q{
        SELECT id_channel_set
        FROM CHANNEL_SET
        JOIN CHANNEL ON CHANNEL_SET.id_channel = CHANNEL.id_channel
        WHERE name = ? AND id_chanset_list = ?
    };

    my $sth = $self->{dbh}->prepare($sQuery);

    if (!$sth->execute($sChannel, $id_chanset_list)) {
        # SQL execution failed
        $self->{logger}->log(1, "❌ SQL Error in getIdChannelSet(): " . $DBI::errstr . " | Query: $sQuery");
    }
    else {
        if (my $ref = $sth->fetchrow_hashref()) {
            $id_channel_set = $ref->{id_channel_set};
            $self->{logger}->log(3, "✅ getIdChannelSet() found id_channel_set=$id_channel_set for channel '$sChannel' and chanset_list_id=$id_chanset_list");
        }
        else {
            $self->{logger}->log(3, "ℹ️ getIdChannelSet() no matching record for channel '$sChannel' and chanset_list_id=$id_chanset_list");
        }
    }

    $sth->finish;
    return $id_channel_set;
}

# Purge a channel from the bot: delete it and archive its data (Context-based) and Administrator only
sub purgeChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    $self->{logger}->log(3, "🔍 purgeChannel_ctx() called by $nick with args: @args");

    # Privilege gate
    return unless $ctx->require_level('Administrator');

    # Validate channel argument
    my $sChannel = $args[0] // '';
    unless ($sChannel =~ /^#/) {
        Mediabot::botNotice($self, $nick, "Syntax: purge <#channel>");
        return;
    }

    # Normalize key (your channel hash may be stored lowercased)
    my $key = lc($sChannel);

    # Check if bot knows about this channel
    my $channel_obj = $self->{channels}{$sChannel} || $self->{channels}{$key};
    unless ($channel_obj) {
        Mediabot::botNotice($self, $nick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || eval { $channel_obj->id } || undef;
    unless ($id_channel) {
        $self->{logger}->log(1, "purgeChannel_ctx(): could not resolve id_channel for $sChannel");
        Mediabot::botNotice($self, $nick, "Internal error: cannot resolve channel id for $sChannel");
        return;
    }

    $self->{logger}->log(0, "🗑️ $nick issued a purge command on $sChannel (id=$id_channel)");

    # Retrieve channel info from DB
    my $sth = $self->{dbh}->prepare("SELECT * FROM CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while fetching channel info");
        Mediabot::botNotice($self, $nick, "SQL error while fetching channel info.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        Mediabot::botNotice($self, $nick, "Channel $sChannel does not exist in DB (id_channel=$id_channel)");
        return;
    }

    # Safe values for archiving
    my $desc      = defined $ref->{description} ? $ref->{description} : '';
    my $ckey      = defined $ref->{key}         ? $ref->{key}         : '';
    my $chanmode  = defined $ref->{chanmode}    ? $ref->{chanmode}    : '';
    my $auto_join = defined $ref->{auto_join}   ? $ref->{auto_join}   : 0;

    # Delete from CHANNEL
    $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while deleting CHANNEL");
        Mediabot::botNotice($self, $nick, "SQL error while deleting channel.");
        return;
    }

    # Delete links
    $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_channel = ?");
    unless ($sth && $sth->execute($id_channel)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while deleting USER_CHANNEL");
        Mediabot::botNotice($self, $nick, "SQL error while deleting channel links.");
        return;
    }

    # Archive into CHANNEL_PURGED
    $sth = $self->{dbh}->prepare(q{
        INSERT INTO CHANNEL_PURGED
            (id_channel, name, description, `key`, chanmode, auto_join, purged_by, purged_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
    });
    unless ($sth && $sth->execute($id_channel, $sChannel, $desc, $ckey, $chanmode, $auto_join, $nick)) {
        $self->{logger}->log(1, "❌ SQL Error: $DBI::errstr while inserting into CHANNEL_PURGED");
        Mediabot::botNotice($self, $nick, "SQL error while archiving channel purge.");
        return;
    }

    # PART + memory cleanup
    $self->{irc}->send_message("PART", $sChannel, "Channel purged by $nick");
    delete $self->{channels}{$sChannel};
    delete $self->{channels}{$key};

    # Log
    logBot($self, $ctx->message, undef, "purge", "$nick purged $sChannel (id_channel=$id_channel)");
    Mediabot::botNotice($self, $nick, "Channel $sChannel purged.");
}

# Part a channel (Administrator+ OR channel-level >= 500)
sub channelPart_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator here because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " part command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Target channel resolution:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: part <#channel>");
        return;
    }

    # Ensure the bot knows the channel BEFORE checking per-channel access
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        return;
    }

    # Check privileges:
    # - Administrator+ globally
    # - OR channel-level >= 500
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target, $user->id, 500) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "channelPart_ctx(): checkUserChannelLevel failed for $target: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " part command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Execute: call the LEGACY partChannel() that actually parts on IRC
    $self->{logger}->log(0, "$nick issued a part $target command");
    partChannel($self, $target, "At the request of " . ($user->nickname // $nick));
    logBot($self, $ctx->message, $target, "part", "At the request of " . ($user->nickname // $nick));
}

# Part a channel on IRC (network helper)
# NOTE: This is NOT a _ctx handler. It is a low-level helper.
sub partChannel {
    my ($self, $channel, $reason) = @_;

    $channel //= '';
    $reason  //= '';

    return unless $channel =~ /^#/;

    # Default reason if empty
    $reason = "Leaving" if $reason eq '';

    # Send PART
    eval {
        # Net::Async::IRC style
        $self->{irc}->send_message("PART", $channel, $reason);
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "partChannel(): failed to PART $channel: $err");
        return;
    };

    $self->{logger}->log(3, "partChannel(): PART sent for $channel (reason='$reason')");
    return 1;
}

# Check if a user has a specific level on a channel
sub checkUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user,$level) = @_;
	my $sQuery = "SELECT level FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $iLevel = $ref->{'level'};
			if ( $iLevel >= $level ) {
				$sth->finish;
				return 1;
			}
			else {
				$sth->finish;
				return 0;
			}
		}
		else {
			$sth->finish;
			return 0;
		}
	}	
}

# Join a channel (Administrator+ OR channel-level >= 450)
sub channelJoin_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator here because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " join command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel
    my $target = $args[0] // '';
    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: join <#channel>");
        return;
    }

    # Ensure the bot knows the channel BEFORE checking per-channel access (avoids noisy SQL)
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        return;
    }

    # Privileges:
    # - Administrator+ globally
    # - OR channel-level >= 450
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target, $user->id, 450) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "channelJoin_ctx(): checkUserChannelLevel failed for $target: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " join command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Fetch channel key (DB truth)
    my $id_channel = eval { $channel_obj->get_id } || undef;
    my $key;

    if (defined $id_channel) {
        my $sth = $self->{dbh}->prepare("SELECT `key` FROM CHANNEL WHERE id_channel = ?");
        if ($sth && $sth->execute($id_channel)) {
            if (my $ref = $sth->fetchrow_hashref) {
                $key = $ref->{key};
            }
            $sth->finish;
        } else {
            $self->{logger}->log(1, "channelJoin_ctx(): SQL error while fetching key for $target: $DBI::errstr");
        }
    } else {
        $self->{logger}->log(1, "channelJoin_ctx(): could not resolve id_channel for $target (channel object missing get_id?)");
    }

    # Execute JOIN (with key if any)
    $self->{logger}->log(0, "$nick issued a join $target command");
    joinChannel($self, $target, (defined($key) && $key ne '' ? $key : undef));

    logBot($self, $ctx->message, $target, "join", "");
}

# Add a user to a channel with a specific level
# Requires: authenticated + (Administrator+ OR channel-level >= 400)
sub channelAddUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " add user command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    # Syntax: add <#channel> <handle> <level>
    my ($target_handle, $target_level) = @args;
    unless (defined($target_handle) && $target_handle ne '' && defined($target_level) && $target_level =~ /^\d+$/) {
        botNotice($self, $nick, "Syntax: add <#channel> <handle> <level>");
        return;
    }
    $target_level = int($target_level);

    # Ensure the bot knows the channel BEFORE doing any DB access checks
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "channelAddUser_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Resolve target user id
    my $id_target_user = getIdUser($self, $target_handle);
    unless ($id_target_user) {
        botNotice($self, $nick, "User $target_handle does not exist");
        return;
    }

    # Admin check (uses your has_level hierarchy)
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Channel-level checks WITHOUT ambiguous SQL (query USER_CHANNEL only)
    my $caller_chan_level = 0;
    my $target_chan_level = 0;

    eval {
        my $sth = $self->{dbh}->prepare(q{
            SELECT level
            FROM USER_CHANNEL
            WHERE id_channel = ? AND id_user = ?
            LIMIT 1
        });

        # caller
        $sth->execute($id_channel, $user->id);
        ($caller_chan_level) = $sth->fetchrow_array;
        $caller_chan_level ||= 0;

        # target
        $sth->execute($id_channel, $id_target_user);
        ($target_chan_level) = $sth->fetchrow_array;
        $target_chan_level ||= 0;

        $sth->finish;
        1;
    } or do {
        $self->{logger}->log(1, "channelAddUser_ctx(): USER_CHANNEL lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

    # Privileges:
    # - Administrator+ globally
    # - OR caller channel-level >= 400
    my $has_chan_priv = ($caller_chan_level >= 400) ? 1 : 0;

    unless ($is_admin || $has_chan_priv) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " add user command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$caller_chan_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Already registered on this channel?
    if ($target_chan_level != 0) {
        botNotice($self, $nick, "User $target_handle is already on $channel with level $target_chan_level");
        return;
    }

    # Prevent assigning a level equal or higher than caller's (unless admin)
    if (!$is_admin && !($target_level < $caller_chan_level)) {
        botNotice($self, $nick, "You can't assign a level equal or higher than yours.");
        return;
    }

    # Insert
    my $sth = $self->{dbh}->prepare("INSERT INTO USER_CHANNEL (id_user, id_channel, level) VALUES (?, ?, ?)");
    unless ($sth && $sth->execute($id_target_user, $id_channel, $target_level)) {
        $self->{logger}->log(1, "channelAddUser_ctx(): SQL Error: $DBI::errstr while inserting USER_CHANNEL");
        botNotice($self, $nick, "Internal error (DB insert failed).");
        return;
    }
    $sth->finish if $sth;

    $self->{logger}->log(0, "$nick added $target_handle to $channel at level $target_level");
    logBot($self, $ctx->message, $channel, "add", $channel, $target_handle, $target_level);

    botNotice($self, $nick, "Added $target_handle to $channel at level $target_level");
}

# Get a user's level on a specific channel
sub getUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user) = @_;
	my $sQuery = "SELECT level FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $iLevel = $ref->{'level'};
			$sth->finish;
			return $iLevel;
		}
		else {
			$sth->finish;
			return 0;
		}
	}	
}

# Delete a user from a channel
# Requires: authenticated + (Administrator+ OR channel-level >= 400)
sub channelDelUser_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication (do NOT require Administrator because channel-level may allow it)
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " del user command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    # Syntax: del <#channel> <handle>
    my ($target_handle) = @args;
    unless ($channel =~ /^#/ && defined($target_handle) && $target_handle ne '') {
        botNotice($self, $nick, "Syntax: del <#channel> <handle>");
        return;
    }

    # Ensure the bot knows the channel BEFORE doing per-channel logic
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "channelDelUser_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Resolve target user id
    my $id_target = getIdUser($self, $target_handle);
    unless ($id_target) {
        botNotice($self, $nick, "User $target_handle does not exist");
        return;
    }

    # Admin check (uses your has_level hierarchy)
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Channel-level checks WITHOUT ambiguous SQL (query USER_CHANNEL only)
    my $issuer_level = 0;
    my $target_level = 0;

    eval {
        my $sth = $self->{dbh}->prepare(q{
            SELECT level
            FROM USER_CHANNEL
            WHERE id_channel = ? AND id_user = ?
            LIMIT 1
        });

        # issuer
        $sth->execute($id_channel, $user->id);
        ($issuer_level) = $sth->fetchrow_array;
        $issuer_level ||= 0;

        # target
        $sth->execute($id_channel, $id_target);
        ($target_level) = $sth->fetchrow_array;
        $target_level ||= 0;

        $sth->finish;
        1;
    } or do {
        $self->{logger}->log(1, "channelDelUser_ctx(): USER_CHANNEL lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

    # Permission: admin OR issuer channel-level >= 400
    my $has_chan_priv = ($issuer_level >= 400) ? 1 : 0;
    unless ($is_admin || $has_chan_priv) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " del user command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$issuer_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target must actually be on the channel
    unless ($target_level) {
        botNotice($self, $nick, "User $target_handle does not appear to have access on $channel");
        return;
    }

    # Prevent deleting someone with level equal or greater than issuer (unless admin)
    if (!$is_admin && !($target_level < $issuer_level)) {
        botNotice($self, $nick, "You can't del a user with a level equal or greater than yours");
        return;
    }

    # Delete from USER_CHANNEL
    my $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_user=? AND id_channel=?");
    unless ($sth && $sth->execute($id_target, $id_channel)) {
        $self->{logger}->log(1, "channelDelUser_ctx(): SQL Error: $DBI::errstr");
        botNotice($self, $nick, "Internal error (DB delete failed).");
        return;
    }
    $sth->finish if $sth;

    logBot($self, $ctx->message, $channel, "del", $channel, $target_handle);
    botNotice($self, $nick, "User $target_handle removed from $channel");
}

# User modinfo syntax notification
sub userModinfoSyntax(@) {
    my ($self, $message, $sNick, @tArgs) = @_;

    botNotice($self, $sNick, "Syntax: modinfo [#channel] automode <user> <OP|VOICE|NONE>");
    botNotice($self, $sNick, "Syntax: modinfo [#channel] greet <user> <greet> (use \"none\" to remove it)");
    botNotice($self, $sNick, "Syntax: modinfo [#channel] level <user> <level>");
}

# Modify user info (level, automode, greet) on a specific channel
sub userModinfo_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " modinfo command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Resolve channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it is a channel
    my $channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($channel =~ /^#/) {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }

    # Ensure channel object exists (case-insensitive)
    my $channel_obj = $self->{channels}{$channel} || $self->{channels}{lc($channel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $channel does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || undef;
    unless (defined $id_channel) {
        $self->{logger}->log(1, "userModinfo_ctx(): could not resolve id_channel for $channel");
        botNotice($self, $nick, "Internal error: channel id not found.");
        return;
    }

    # Minimal syntax: <type> <handle> <value...>
    unless (defined $args[0] && $args[0] ne '' && defined $args[1] && $args[1] ne '' && defined $args[2] && $args[2] ne '') {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }

    my $type              = lc($args[0]);
    my $target_handle     = $args[1];

    # Admin check via User.pm hierarchy
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    # Determine issuer handle (best effort)
    my $issuer_handle = eval { $user->handle } || eval { $user->nickname } || $nick;

    # Fetch issuer channel level + target channel level + target id_user (no ambiguous SQL)
    my ($issuer_level, $target_level, $id_user_target) = (0, 0, undef);

    eval {
        my $sth_issuer = $self->{dbh}->prepare(q{
            SELECT uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        });
        $sth_issuer->execute($id_channel, $issuer_handle);
        ($issuer_level) = $sth_issuer->fetchrow_array;
        $issuer_level ||= 0;
        $sth_issuer->finish;

        my $sth_target = $self->{dbh}->prepare(q{
            SELECT u.id_user, uc.level
            FROM USER_CHANNEL uc
            JOIN USER u ON u.id_user = uc.id_user
            WHERE uc.id_channel = ?
              AND u.nickname = ?
            LIMIT 1
        });
        $sth_target->execute($id_channel, $target_handle);
        ($id_user_target, $target_level) = $sth_target->fetchrow_array;
        $target_level ||= 0;
        $sth_target->finish;

        1;
    } or do {
        $self->{logger}->log(1, "userModinfo_ctx(): DB lookup failed: $@");
        botNotice($self, $nick, "Internal error (DB lookup failed).");
        return;
    };

    unless (defined $id_user_target) {
        botNotice($self, $nick, "User $target_handle does not exist on $channel");
        return;
    }

    # Permission check:
    # - level/automode => Admin OR channel-level >= 400
    # - greet          => Admin OR channel-level >= 1
    my $has_access = 0;
    if ($is_admin) {
        $has_access = 1;
    } elsif ($type eq 'greet') {
        $has_access = ($issuer_level >= 1) ? 1 : 0;
    } else {
        $has_access = ($issuer_level >= 400) ? 1 : 0;
    }

    unless ($has_access) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " modinfo command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $channel (chan_level=$issuer_level)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Prevent modifying a user with equal/higher access than caller (unless admin)
    # For greet: allow if issuer_level > 0 (matches your original intent)
    unless (
        $is_admin
        || ($issuer_level > $target_level)
        || ($type eq 'greet' && $issuer_level > 0)
    ) {
        botNotice($self, $nick, "Cannot modify a user with equal or higher access than your own.");
        return;
    }

    my $sth;

    # SWITCH
    if ($type eq 'automode') {

        my $mode = uc($args[2] // '');
        unless ($mode =~ /^(OP|VOICE|NONE)$/i) {
            userModinfoSyntax($self, $ctx->message, $nick, @args);
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($mode, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set automode $mode on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;

    } elsif ($type eq 'greet') {

        # Keep your extra restriction:
        # If caller < 400, they can only set THEIR OWN greet unless admin
        if (!$is_admin && $issuer_level < 400 && lc($target_handle) ne lc($issuer_handle)) {
            botNotice($self, $nick, "Your level does not allow you to perform this command.");
            return;
        }

        # greet text is everything after: greet <handle> ...
        my @greet_parts = @args[ 2 .. $#args ];
        my $greet_msg = (scalar(@greet_parts) == 1 && defined($greet_parts[0]) && $greet_parts[0] =~ /none/i)
            ? undef
            : join(" ", @greet_parts);

        my $query = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($greet_msg, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set greet (" . (defined $greet_msg ? $greet_msg : "none") . ") on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", ("greet", $target_handle, @greet_parts));
        return $id_channel;

    } elsif ($type eq 'level') {

        my $new_level = $args[2];
        unless (defined($new_level) && $new_level =~ /^\d+$/ && $new_level <= 500) {
            botNotice($self, $nick, "Cannot set user access higher than 500.");
            return;
        }

        my $query = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
        $sth = $self->{dbh}->prepare($query);
        unless ($sth && $sth->execute($new_level, $id_user_target, $id_channel)) {
            $self->{logger}->log(1, "userModinfo_ctx(): SQL Error: $DBI::errstr Query: $query");
            botNotice($self, $nick, "Internal error (DB update failed).");
            return;
        }
        $sth->finish if $sth;

        botNotice($self, $nick, "Set level $new_level on $channel for $target_handle");
        logBot($self, $ctx->message, $channel, "modinfo", @args);
        return $id_channel;

    } else {
        userModinfoSyntax($self, $ctx->message, $nick, @args);
        return;
    }
}

# Get user ID and level on a specific channel
sub getIdUserChannelLevel(@) {
	my ($self,$sUserHandle,$sChannel) = @_;
	my $sQuery = "SELECT USER.id_user,USER_CHANNEL.level FROM CHANNEL,USER,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER.id_user=USER_CHANNEL.id_user AND USER.nickname=? AND CHANNEL.name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle,$sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user = $ref->{'id_user'};
			my $level = $ref->{'level'};
			$self->{logger}->log(3,"getIdUserChannelLevel() $id_user $level");
			$sth->finish;
			return ($id_user,$level);
		}
		else {
			$sth->finish;
			return (undef,undef);
		}
	}
}

# Give operator (+o) to a nick on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub userOpChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " op command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: op [#channel] <nick>");
        return;
    }

    # Ensure bot knows the channel BEFORE per-channel level checks (avoids noisy SQL on unknown channel)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            # Safe deny on failure
            $self->{logger}->log(1, "userOpChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " op command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick to +o (default to caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE +o
    $self->{irc}->send_message("MODE", undef, ($target_chan, "+o", $target_nick));
    logBot($self, $ctx->message, $target_chan, "op", $target_chan, $target_nick);

    return $channel_obj->get_id;
}

# Remove operator (-o) from a nick on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub userDeopChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " deop command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: deop [#channel] <nick>");
        return;
    }

    # Ensure bot knows the channel BEFORE per-channel level checks (avoids noisy SQL on unknown channel)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            # Safe deny on failure
            $self->{logger}->log(1, "userDeopChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " deop command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick to -o (default to caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE -o
    $self->{irc}->send_message("MODE", undef, ($target_chan, "-o", $target_nick));
    logBot($self, $ctx->message, $target_chan, "deop", $target_chan, $target_nick);

    return $channel_obj->get_id;
}

# Invite a nick to a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 100).
sub userInviteChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User handles autologin already)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " invite command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - if first arg is a #channel => use it
    # - else fallback to ctx->channel if it is a channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: invite [#channel] <nick>");
        return;
    }

    # Ensure the bot knows the channel BEFORE per-channel checks (avoid noisy SQL)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally OR channel-level >= 100
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel($self, $ctx->message, $target_chan, $uid, 100) ? 1 : 0;
            1;
        } or do {
            $self->{logger}->log(1, "userInviteChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@");
            $has_chan_level = 0; # safe deny
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " invite command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Who to invite (default: caller)
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute INVITE
    $self->{irc}->send_message("INVITE", undef, ($target_nick, $target_chan));
    logBot($self, $ctx->message, $target_chan, "invite", $target_chan, $target_nick);

    return $id_channel;
}

# Give +v (voice) to a user on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 25)
sub userVoiceChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " voice command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - first argument if it is a #channel
    # - otherwise fallback to ctx->channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: voice [#channel] <nick>");
        return;
    }

    # Ensure the channel exists in bot memory (avoid useless SQL errors)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 25
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 25
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userVoiceChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " voice command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick (+v); default is the caller
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE +v
    $self->{irc}->send_message("MODE", undef, ($target_chan, "+v", $target_nick));
    logBot($self, $ctx->message, $target_chan, "voice", $target_chan, $target_nick);

    return $id_channel;
}

# Remove +v (voice) from a user on a channel.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 25)
sub userDevoiceChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " devoice command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged in to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - first argument if it is a #channel
    # - otherwise fallback to ctx->channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: devoice [#channel] <nick>");
        return;
    }

    # Ensure the channel exists in bot memory (avoid useless SQL errors)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 25
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 25
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userDevoiceChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " devoice command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Target nick (-v); default is the caller
    my $target_nick = (@args && defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    # Execute MODE -v
    $self->{irc}->send_message("MODE", undef, ($target_chan, "-v", $target_nick));
    logBot($self, $ctx->message, $target_chan, "devoice", $target_chan, $target_nick);

    return $id_channel;
}

# Kick a user from a channel, with an optional reason.
# Requires: authenticated user AND (Administrator+ OR channel-level >= 50)
sub userKickChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require authentication (Context/User already handled autologin)
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " kick command attempt (unauthenticated)";
        noticeConsoleChan($self, $notice);
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: kick [#channel] <nick> [reason]");
        return;
    }

    # Ensure the bot knows the channel BEFORE doing per-channel privilege checks
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }
    my $id_channel = $channel_obj->get_id;

    # Target nick is mandatory
    my $kick_nick = shift @args;
    unless (defined $kick_nick && $kick_nick ne '') {
        botNotice($self, $nick, "Syntax: kick [#channel] <nick> [reason]");
        return;
    }

    # Permission check:
    # - Administrator+ globally
    # - OR channel-level >= 50
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $has_chan_level = 0;
    unless ($is_admin) {
        eval {
            my $uid = eval { $user->id } // 0;
            $has_chan_level = checkUserChannelLevel(
                $self, $ctx->message, $target_chan, $uid, 50
            ) ? 1 : 0;
            1;
        } or do {
            # Safe deny if channel-level check fails
            $self->{logger}->log(
                1,
                "userKickChannel_ctx(): checkUserChannelLevel failed for $target_chan: $@"
            );
            $has_chan_level = 0;
        };
    }

    unless ($is_admin || $has_chan_level) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " kick command denied for user " . ($user->nickname // '?')
                   . " [level=$lvl] on $target_chan";
        noticeConsoleChan($self, $notice);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Optional reason
    my $reason = join(' ', @args);
    my $issuer = eval { $user->nickname } || $nick;
    my $final  = "(" . $issuer . ")" . (length($reason) ? " $reason" : "");

    # Execute KICK
    $self->{logger}->log(0, "$nick issued a kick $target_chan command");
    $self->{irc}->send_message("KICK", undef, ($target_chan, $kick_nick, $final));

    logBot($self, $ctx->message, $target_chan, "kick", $target_chan, $kick_nick, $reason);

    return $id_channel;
}

# Set the topic of a channel if the user has the appropriate privileges
sub userTopicChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $prefix = eval { $message->prefix } // '';
    my $user   = eval { $self->get_user_from_message($message) };

    unless ($user) {
        $self->noticeConsoleChan("$prefix topic: no user object from get_user_from_message()");
        botNotice($self, $sNick, "Internal error: no user");
        return;
    }

    # --- Safe getters (compat champs/méthodes) ---
    my $uid        = eval { $user->id }                // eval { $user->{id_user} }       // 0;
    my $handle     = eval { $user->nickname }          // eval { $user->{nickname} }      // $sNick;
    my $auth       = eval { $user->auth }              // eval { $user->{auth} }          // 0;
    my $level      = eval { $user->level }             // eval { $user->{level} }         // undef;
    my $level_desc = eval { $user->level_description } // eval { $user->{level_desc} }    // 'unknown';

    $self->noticeConsoleChan("$prefix AUTH[topic-enter] uid=$uid nick=$handle auth=$auth level=$level_desc");

    # ---------- tentative d'auto-login si auth=0 ----------
    if (!$auth) {
        my ($username, $masks) = ('','');
        eval {
            my $sth = $self->{dbh}->prepare("SELECT username, hostmasks FROM USER WHERE id_user=?");
            $sth->execute($uid);
            ($username, $masks) = $sth->fetchrow_array;
            $sth->finish;
        };

        my $userhost = $prefix; $userhost =~ s/^.*?!(.+)$/$1/;
        my $matched_mask;
        for my $mask (grep { length } map { my $x=$_; $x =~ s/^\s+|\s+$//g; $x } split /,/, ($masks//'') ) {
            my $re = do {
                my $q = quotemeta($mask);
                $q =~ s/\\\*/.*/g; # '*' -> '.*'
                $q =~ s/\\\?/./g;  # '?' -> '.'
                qr/^$q$/i;
            };
            if ($userhost =~ $re) { $matched_mask = $mask; last; }
        }

        $self->noticeConsoleChan("$prefix topic: auth=0; username='".($username//'')."'; mask check => ".($matched_mask ? "matched '$matched_mask'" : "no match"));

        if (defined $username && $username eq '#AUTOLOGIN#' && $matched_mask) {
            my ($ok,$why) = eval { $self->{auth}->maybe_autologin($user, $prefix) };
            $ok //= 0; $why //= ($@ ? "exception: $@" : "unknown");
            $self->noticeConsoleChan("$prefix topic: maybe_autologin => ".($ok?'OK':'NO')." ($why)");

            # rafraîchir l’état utilisateur
            $user  = eval { $self->get_user_from_message($message) } || $user;
            $auth  = eval { $user->auth } // eval { $user->{auth} } // 0;
            $level = eval { $user->level } // eval { $user->{level} } // $level;
            $level_desc = eval { $user->level_description } // eval { $user->{level_desc} } // $level_desc;
            $self->noticeConsoleChan("$prefix topic: after autologin => auth=$auth level=$level_desc");
        } else {
            $self->noticeConsoleChan("$prefix topic: autologin not eligible");
        }
    }

    # Abort if still not authenticated
    unless ($auth) {
        my $notice = "$prefix topic command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        return;
    }

    # Extract channel from arguments if provided
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    # Check permissions: Administrator or per-channel level >= 50
    my $user_id_for_check = eval { $user->id } // $uid;
    unless (
        checkUserLevel($self, $level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user_id_for_check, 50)
    ) {
        my $notice = "$prefix topic command attempt by $handle [level: $level_desc]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Ensure a topic is provided
    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    # Get channel object and verify existence
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    my $new_topic  = join(" ", @tArgs);

    # Log and send IRC topic command
    $self->{logger}->log(0, "$sNick issued a topic $sChannel command");
    $self->{irc}->send_message("TOPIC", undef, ($sChannel, $new_topic));
    logBot($self, $message, $sChannel, "topic", @tArgs);

    return $id_channel;
}

# Show available commands to the user for a specific channel (Context-based)
sub userShowcommandsChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Always-available public commands line
    my $public_line = "Level   0: access chaninfo login pass newpass ident showcommands";

    # If we can't resolve a user, show only public commands
    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, $public_line);
        return;
    }

    # Require authentication to show level-dependent commands
    unless ($user->is_authenticated) {
        my $notice = ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick)
                   . " showcommands attempt (user "
                   . (eval { $user->nickname } || eval { $user->handle } || $nick)
                   . " is not logged in)";
        noticeConsoleChan($self, $notice);
        logBot($self, $ctx->message, $ctx->channel, "showcommands", @args);

        botNotice(
            $self, $nick,
            "You must be logged to see available commands for your level - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        botNotice($self, $nick, $public_line);
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: showcommands #channel");
        return;
    }

    # If the bot doesn't know this channel, don't try DB lookups (avoid noisy SQL)
    my $channel_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target does not exist");
        botNotice($self, $nick, $public_line);
        return;
    }

    # Global admin?
    my $is_admin = eval { $user->has_level('Administrator') ? 1 : 0 } || 0;

    my $header = "Available commands on $target";
    $header .= " (because you are a global admin)" if $is_admin;

    noticeConsoleChan($self, ($ctx->message && $ctx->message->can('prefix') ? $ctx->message->prefix : $nick) . " showcommands on $target");
    logBot($self, $ctx->message, $target, "showcommands", $target);

    botNotice($self, $nick, $header);

    # Get user handle for channel-level lookup
    my $handle = eval { $user->handle }
              || eval { $user->nickname }
              || $nick;

    # Get user level on the channel (safe default 0)
    my (undef, $level) = eval { getIdUserChannelLevel($self, $handle, $target) };
    $level //= 0;

    # Show commands by channel level (admin bypasses)
    botNotice($self, $nick, "Level 500: part")            if ($is_admin || $level >= 500);
    botNotice($self, $nick, "Level 450: join chanset")    if ($is_admin || $level >= 450);
    botNotice($self, $nick, "Level 400: add del modinfo") if ($is_admin || $level >= 400);
    botNotice($self, $nick, "Level 100: op deop invite")  if ($is_admin || $level >= 100);
    botNotice($self, $nick, "Level  50: kick topic")      if ($is_admin || $level >= 50);
    botNotice($self, $nick, "Level  25: voice devoice")   if ($is_admin || $level >= 25);

    # Always show public commands
    botNotice($self, $nick, $public_line);

    return 1;
}

# Show detailed info about a registered channel (Context-based)
sub userChannelInfo_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel if it's a #channel
    my $sChannel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $sChannel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $sChannel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($sChannel =~ /^#/) {
        botNotice($self, $nick, "Syntax: chaninfo #channel");
        return;
    }

    # Require the channel to exist in the bot cache/hash first
    my $channel_obj = $self->{channels}{$sChannel} || $self->{channels}{lc($sChannel)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $sChannel does not exist");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Internal error: channel object has no id for $sChannel");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    # --- Main SQL query: channel info + owner (level 500) ---
    my $sql1 = q{
        SELECT
            U.nickname       AS nickname,
            U.last_login     AS last_login,
            C.creation_date  AS creation_date,
            C.description    AS description,
            C.`key`          AS c_key,
            C.chanmode       AS chanmode,
            C.auto_join      AS auto_join
        FROM USER_CHANNEL UC
        JOIN `USER`  U ON U.id_user    = UC.id_user
        JOIN CHANNEL C ON C.id_channel = UC.id_channel
        WHERE UC.id_channel = ? AND UC.level = 500
        LIMIT 1
    };

    my $sth1 = $self->{dbh}->prepare($sql1);
    unless ($sth1 && $sth1->execute($id_channel)) {
        $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql1");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    my $ref = $sth1->fetchrow_hashref();
    $sth1->finish;

    unless ($ref) {
        botNotice($self, $nick, "The channel $sChannel doesn't appear to be registered");
        logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
        return;
    }

    my $sUsername     = $ref->{nickname}       // '?';
    my $sLastLogin    = defined $ref->{last_login}    ? $ref->{last_login}    : "Never";
    my $creation_date = defined $ref->{creation_date} ? $ref->{creation_date} : "Unknown";
    my $description   = defined $ref->{description}   ? $ref->{description}   : "No description";

    my $sKey      = defined $ref->{c_key}    ? $ref->{c_key}    : "Not set";
    my $chanmode  = defined $ref->{chanmode} ? $ref->{chanmode} : "Not set";
    my $sAutoJoin = ($ref->{auto_join} ? "True" : "False");

    botNotice($self, $nick, "$sChannel is registered by $sUsername - last login: $sLastLogin");
    botNotice($self, $nick, "Creation date : $creation_date - Description : $description");

    # Optional Master+ info (no legacy checkUserLevel)
    my $user = $ctx->user;
    if ($user && $user->is_authenticated && eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Chan modes : $chanmode - Key : $sKey - Auto join : $sAutoJoin");
    }

    # --- List CHANSET flags (by channel id) ---
    my $sql2 = q{
        SELECT CL.chanset
        FROM CHANNEL_SET  CS
        JOIN CHANSET_LIST CL ON CL.id_chanset_list = CS.id_chanset_list
        WHERE CS.id_channel = ?
    };

    my $sth2 = $self->{dbh}->prepare($sql2);
    if ($sth2 && $sth2->execute($id_channel)) {
        my $flags = '';
        my $hasFlags = 0;
        my $hasAntiFlood = 0;

        while (my $r = $sth2->fetchrow_hashref()) {
            my $chanset = $r->{chanset};
            next unless defined $chanset && $chanset ne '';
            $flags .= "+$chanset ";
            $hasFlags = 1;
            $hasAntiFlood = 1 if $chanset =~ /AntiFlood/i;
        }
        $sth2->finish;

        botNotice($self, $nick, "Channel flags $flags") if $hasFlags;

        # If AntiFlood flag is present, fetch flood parameters
        if ($hasAntiFlood) {
            my $sql3 = q{
                SELECT nbmsg_max, nbmsg, duration, timetowait, notification
                FROM CHANNEL_FLOOD
                WHERE id_channel = ?
                LIMIT 1
            };
            my $sth3 = $self->{dbh}->prepare($sql3);
            if ($sth3 && $sth3->execute($id_channel)) {
                if (my $rf = $sth3->fetchrow_hashref()) {
                    my $nbmsg_max  = $rf->{nbmsg_max};
                    my $duration   = $rf->{duration};
                    my $timetowait = $rf->{timetowait};
                    my $notif      = ($rf->{notification} ? "ON" : "OFF");

                    botNotice(
                        $self, $nick,
                        "Antiflood parameters : $nbmsg_max messages in $duration seconds, wait for $timetowait seconds, notification : $notif"
                    );
                } else {
                    botNotice($self, $nick, "Antiflood parameters : not set ?");
                }
                $sth3->finish;
            } else {
                $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql3");
            }
        }
    } else {
        $self->{logger}->log(1, "userChannelInfo_ctx() SQL Error: $DBI::errstr | Query: $sql2");
    }

    logBot($self, $ctx->message, $sChannel, "chaninfo", $sChannel);
    return 1;
}

# Return detailed information about the currently authenticated user (Context-based)
sub userWhoAmI_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $user = $ctx->user;

    # Ensure we have a user object
    unless ($user && defined(eval { $user->id })) {
        botNotice($self, $nick, "User not found with this hostmask");
        return;
    }

    # Require authentication (whoami is meant for "current logged-in identity")
    unless ($user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged in: /msg "
            . $self->{irc}->nick_folded
            . " login <username> <password>"
        );
        return;
    }

    my $uid   = eval { $user->id } // 0;
    my $uname = eval { $user->nickname } // eval { $user->handle } // $nick;

    my $lvl_desc = eval { $user->level_description } || eval { $user->level } || 'Unknown';

    # Base line
    botNotice($self, $nick, "User: $uname (Id: $uid - $lvl_desc)");

    # Pull DB details (password set, hostmasks, created, last login, username)
    my $sql = "SELECT username, password, hostmasks, creation_date, last_login, auth FROM USER WHERE id_user=? LIMIT 1";
    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth && $sth->execute($uid)) {
        $self->{logger}->log(1, "userWhoAmI_ctx() SQL Error: $DBI::errstr | Query: $sql");
        botNotice($self, $nick, "Internal error (query failed).");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $created    = $ref->{creation_date} // 'N/A';
        my $last_login = $ref->{last_login}    // 'never';
        my $hostmasks  = $ref->{hostmasks}     // 'N/A';
        my $db_auth    = $ref->{auth}          ? 1 : 0;

        # Password set: check the password field (NOT creation_date)
        my $pass_set = (defined $ref->{password} && $ref->{password} ne '') ? "Password set" : "Password not set";

        # AUTOLOGIN status
        my $db_username = defined($ref->{username}) ? $ref->{username} : '';
        my $autologin   = ($db_username eq '#AUTOLOGIN#') ? "ON" : "OFF";

        my $auth_status = $db_auth ? "logged in" : "not logged in";

        botNotice($self, $nick, "Created: $created | Last login: $last_login");
        botNotice($self, $nick, "$pass_set | Status: $auth_status | AUTOLOGIN: $autologin");
        botNotice($self, $nick, "Hostmasks: $hostmasks");
    } else {
        botNotice($self, $nick, "User record not found in database (id=$uid)");
    }

    $sth->finish;

    # Extra fields (best-effort: depending on your User.pm)
    my $info1 = eval { $user->info1 } // eval { $user->{info1} } // 'N/A';
    my $info2 = eval { $user->info2 } // eval { $user->{info2} } // 'N/A';
    botNotice($self, $nick, "Infos: $info1 | $info2");

    logBot($self, $ctx->message, undef, "whoami");
    return 1;
}

# Add a new public command to the database (Administrator+)
sub mbDbAddCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Administrator+
    my $user = $ctx->require_level("Administrator") or return;

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
    my $user = $ctx->require_level("Administrator") or return;

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
    my $user = $ctx->require_level("Administrator") or return;

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
    my $user = $ctx->require_level("Master") or return;

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
sub channelStatLines_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Auth + level (Context handles the deny messaging cleanly)
    my $user = $ctx->require_level("Administrator") or return;

    # Resolve target channel: first arg if #chan, else ctx->channel
    my $target_channel = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target_channel = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target_channel =~ /^#/) {
        botNotice($self, $nick, "Usage: chanstatlines <#channel>");
        return;
    }

    # (small improvement) If we don't know the channel internally, say it early (no pointless SQL)
    my $chan_obj = $self->{channels}{$target_channel} || $self->{channels}{lc($target_channel)};
    unless ($chan_obj) {
        botNotice($self, $nick, "Channel $target_channel doesn't seem to be registered.");
        logBot($self, $ctx->message, undef, "chanstatlines", $target_channel, "No such channel");
        return;
    }

    my $sql = q{
        SELECT COUNT(*) AS nb_lines
        FROM CHANNEL_LOG CL
        JOIN CHANNEL C ON CL.id_channel = C.id_channel
        WHERE C.name = ?
          AND CL.ts > (NOW() - INTERVAL 1 HOUR)
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my ($count) = $sth->fetchrow_array;
    $sth->finish;

    $count ||= 0;

    # (small improvement) Do NOT talk in-channel by default; report to the requester.
    # Avoids spamming the channel / leaking admin activity.
    my $msg =
        ($count == 0)
            ? "Last hour on $target_channel: 0 lines."
            : "Last hour on $target_channel: $count " . ($count == 1 ? "line" : "lines") . ".";

    botNotice($self, $nick, $msg);
    logBot($self, $ctx->message, undef, "chanstatlines", $target_channel, $count);

    return $count;
}

# Display top talkers in a channel during the last hour (Administrator+)
# Improvements:
# - Uses Context (auth/deny handled centrally)
# - Avoids spamming/embarrassing users: sends result to requester by NOTICE (and only posts in-channel if invoked in that channel)
# - Truncates to stay within a safe IRC line length (adds "...")
# - Early exit if channel not known by the bot (avoid noisy SQL / mismatched channel names)
sub whoTalk_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Auth + level
    my $user = $ctx->require_level("Administrator") or return;

    # Resolve target channel: first arg if #chan, else ctx->channel
    my $target = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $target = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($target =~ /^#/) {
        botNotice($self, $nick, "Syntax: whotalk <#channel>");
        return;
    }

    # Prefer our internal channel hash (avoid mismatches / useless SQL)
    my $chan_obj = $self->{channels}{$target} || $self->{channels}{lc($target)};
    unless ($chan_obj) {
        botNotice($self, $nick, "Channel $target doesn't seem to be registered.");
        logBot($self, $ctx->message, undef, "whotalk", $target, "No such channel");
        return;
    }

    my $target_lc = lc($target);

    my $sql = q{
        SELECT CL.nick, COUNT(*) AS nbLines
        FROM CHANNEL_LOG CL
        JOIN CHANNEL C ON CL.id_channel = C.id_channel
        WHERE (CL.event_type = 'public' OR CL.event_type = 'action')
          AND LOWER(TRIM(C.name)) = ?
          AND CL.ts > (NOW() - INTERVAL 1 HOUR)
        GROUP BY CL.nick
        ORDER BY nbLines DESC
        LIMIT 20
    };

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_lc)) {
        $self->{logger}->log(1, "whoTalk_ctx() SQL Error: $DBI::errstr Query: $sql");
        botNotice($self, $nick, "Internal error (SQL).");
        return;
    }

    my @rows;
    while (my $r = $sth->fetchrow_hashref) {
        next unless defined $r->{nick} && $r->{nick} ne '';
        my $lines = $r->{nbLines} // 0;
        push @rows, [ $r->{nick}, $lines ];
    }
    $sth->finish;

    # Decide where to output:
    # - if command issued IN the same channel, we can post in-channel
    # - else: only NOTICE the requester (less noisy)
    my $out_chan = '';
    my $ctx_chan = $ctx->channel // '';
    if ($ctx_chan =~ /^#/ && lc($ctx_chan) eq $target_lc) {
        $out_chan = $target;   # safe to speak in-channel
    }

    if (!@rows) {
        my $msg = "No messages recorded on $target during the last hour.";
        $out_chan ? botPrivmsg($self, $out_chan, $msg) : botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "whotalk", $target, "empty");
        return;
    }

    # Build one-line summary with truncation
    my @talkers = map { "$_->[0] ($_->[1])" } @rows;
    my $prefix  = "Top talkers last hour on $target: ";

    my $max_len = 360; # conservative for NOTICE/PRIVMSG payload
    my $line = $prefix;
    for my $t (@talkers) {
        my $candidate = ($line eq $prefix) ? ($line . $t) : ($line . ", " . $t);
        if (length($candidate) > $max_len) {
            $line .= "..." if length($line) + 3 <= $max_len;
            last;
        }
        $line = $candidate;
    }

    $out_chan ? botPrivmsg($self, $out_chan, $line) : botNotice($self, $nick, $line);

    # Optional gentle warning, but only if we are already speaking in-channel
    if ($out_chan && $rows[0][1] >= 25) {
        botPrivmsg($self, $out_chan, "$rows[0][0]: please slow down a bit — you're flooding the channel.");
    }

    logBot($self, $ctx->message, undef, "whotalk", $target);
    return scalar(@rows);
}

# Check and execute a public command from the database
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
sub displayBirthDate_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Output destination: notice in private, privmsg in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    my $birth_ts = eval { $self->{conf}->get('main.MAIN_PROG_BIRTHDATE') };

    unless (defined $birth_ts && $birth_ts =~ /^\d+$/ && $birth_ts > 0) {
        my $msg = "Birthdate is not configured (main.MAIN_PROG_BIRTHDATE).";
        $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $dest_chan, $msg);
        return;
    }

    my $sBirthDate = "I was born on " . strftime("%d/%m/%Y at %H:%M:%S.", localtime($birth_ts));

    my $d = time() - $birth_ts;
    $d = 0 if $d < 0; # clock skew safety

    my @int = (
        [ 'second', 1                 ],
        [ 'minute', 60                ],
        [ 'hour',   60*60             ],
        [ 'day',    60*60*24          ],
        [ 'week',   60*60*24*7        ],
        [ 'month',  60*60*24*30.5     ],
        [ 'year',   60*60*24*30.5*12  ],
    );

    my $i = $#int;
    my @r;

    while ($i >= 0 && $d) {
        my $unit = $int[$i]->[0];
        my $sec  = $int[$i]->[1];

        if ($d / $sec >= 1) {
            my $n = int($d / $sec);
            push @r, sprintf("%d %s%s", $n, $unit, ($n > 1 ? 's' : ''));
        }
        $d %= $sec;
        $i--;
    }

    my $runtime = @r ? join(", ", @r) : "0 seconds";

    my $msg = "$sBirthDate I am $runtime old";
    $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $dest_chan, $msg);

    return 1;
}

# Rename a public command (Master+)
# Syntax: mvcmd <old_command> <new_command>
sub mbDbMvCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require auth + Master+
    my $user = $ctx->require_level("Master") or return;

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
sub mbDbChangeCategoryCommand_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx chcatcmd attempt (not logged in)");
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx chcatcmd attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Args
    unless (defined $args[0] && $args[0] ne '' && defined $args[1] && $args[1] ne '') {
        botNotice($self, $nick, "Syntax: chcatcmd <new_category> <command>");
        return;
    }

    my ($category_name, $command_name) = @args[0,1];

    # 1) Resolve category id
    my $sth = $self->{dbh}->prepare(
        "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?"
    );
    unless ($sth && $sth->execute($category_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $nick, "Database error while checking category.");
        return;
    }

    my $cat = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($cat && defined $cat->{id_public_commands_category}) {
        botNotice($self, $nick, "Category '$category_name' does not exist.");
        return;
    }

    my $category_id = $cat->{id_public_commands_category};

    # 2) Ensure command exists
    $sth = $self->{dbh}->prepare("SELECT id_public_commands FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth && $sth->execute($command_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: SELECT command");
        botNotice($self, $nick, "Database error while checking command.");
        return;
    }

    my $cmd = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($cmd && defined $cmd->{id_public_commands}) {
        botNotice($self, $nick, "Command '$command_name' does not exist.");
        return;
    }

    # 3) Update category
    $sth = $self->{dbh}->prepare(
        "UPDATE PUBLIC_COMMANDS SET id_public_commands_category = ? WHERE command = ?"
    );
    unless ($sth && $sth->execute($category_id, $command_name)) {
        $self->{logger}->log(1, "mbDbChangeCategoryCommand_ctx() SQL Error: $DBI::errstr Query: UPDATE command category");
        botNotice($self, $nick, "Failed to update category for '$command_name'.");
        return;
    }
    $sth->finish;

    botNotice($self, $nick, "Category changed to '$category_name' for command '$command_name'.");
    logBot($self, $ctx->message, $ctx->channel, "chcatcmd", "Changed category to '$category_name' for '$command_name'");

    return 1;
}

# Show the most frequently used phrases by a given nick on a given channel
# Requires: authenticated + Administrator+
sub userTopSay_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Destination (private notice vs channel privmsg)
    my $ctx_chan  = $ctx->channel // undef;
    my $is_private = !defined($ctx_chan) || $ctx_chan eq '';
    my $dest_chan  = $ctx_chan; # may be undef

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Require authentication
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx topsay attempt (unauthenticated user " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged in to use this command: /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx topsay attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        return;
    }

    # Channel and nick extraction:
    # - If first arg is a #channel => use it, and output there (unless ctx is private and you prefer notice; we keep original behavior)
    # - Else use ctx->channel
    my $chan = undef;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        $chan = $ctx_chan;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: topsay [#channel] <nick>");
        return;
    }

    # If command was issued in-channel, reply in that channel by default.
    # If issued in private, keep replying in notice unless a channel was explicitly provided.
    if (!$is_private) {
        $dest_chan = $chan;
    } else {
        # private: if user provided a channel explicitly, send to that channel (keeps old behavior: isPrivate is based on original sChannel)
        $dest_chan = $chan if defined $chan;
    }

    my $target_nick = (defined $args[0] && $args[0] ne '') ? $args[0] : $nick;

    my $sql = <<'SQL';
SELECT event_type, publictext, COUNT(publictext) as hit
FROM CHANNEL, CHANNEL_LOG
WHERE (event_type='public' OR event_type='action')
  AND CHANNEL.id_channel = CHANNEL_LOG.id_channel
  AND name = ?
  AND nick LIKE ?
GROUP BY publictext
ORDER BY hit DESC
LIMIT 30
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($chan, $target_nick)) {
        $self->{logger}->log(1, "userTopSay_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $response  = "$target_nick: ";
    my $fullLine  = $response;
    my $maxLength = 300;
    my $i         = 0;

    my @skip_patterns = (
        qr/^\s*$/,
        qr/^[:;=]?[pPdDoO)]$/,
        qr/^[(;][:;=]?$/,
        qr/^x?D$/i,
        qr/^(heh|hah|huh|hih)$/i,
        qr/^!/,
        qr/^=.?$/,
        qr/^;[p>]$/,
        qr/^:>$/,
        qr/^lol$/i,
    );

    while (my $ref = $sth->fetchrow_hashref()) {
        my ($text, $event_type, $count) = @{$ref}{qw/publictext event_type hit/};

        next unless defined $text;

        # Clean control characters (old behavior)
        $text =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;

        # Skip useless lines
        next if grep { $text =~ $_ } @skip_patterns;

        my $entry =
            ($event_type && $event_type eq 'action')
            ? String::IRC->new("$text ($count) ")->bold
            : "$text ($count) ";

        my $new_len = length($fullLine) + length($entry);
        last if $new_len >= $maxLength;

        $response .= $entry;
        $fullLine .= $entry;
        $i++;
    }

    if ($i > 0) {
        if ($is_private) {
            botNotice($self, $nick, $response);
        } else {
            botPrivmsg($self, $dest_chan, $response);
        }
    } else {
        my $msg = "No results.";
        if ($is_private) {
            botNotice($self, $nick, $msg);
        } else {
            botPrivmsg($self, $dest_chan, $msg);
        }
    }

    my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
    logBot($self, $ctx->message, $dest_chan, "topsay", "$pfx topsay on $target_nick");

    $sth->finish;
    return 1;
}

# Check nicknames used on a given channel by a specific hostname (fast DB query)
# Requires: authenticated + Administrator+
sub mbDbCheckHostnameNickChan_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Require authentication
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx checkhostchan attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged in to use this command: /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx checkhostchan attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is a #channel, use it
    # - Else fallback to ctx->channel
    my $target_chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: checkhostchan [#channel] <hostname>");
        return;
    }

    # Hostname argument
    my $hostname = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $hostname =~ s/^\s+|\s+$//g;

    unless ($hostname ne '') {
        botNotice($self, $nick, "Syntax: checkhostchan [#channel] <hostname>");
        return;
    }

    # Ensure the bot knows this channel (avoid noisy SQL / ambiguous errors elsewhere)
    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $target_chan does not exist");
        return;
    }

    # Output destination:
    # - If command issued in private, reply by notice
    # - Else reply in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel // $target_chan;

    # Optimization:
    # - Avoid JOIN on CHANNEL.name, use id_channel directly
    # - Avoid SUBSTRING_INDEX (it forces computation per row)
    #   Use LIKE on userhost tail: '%@hostname' (still wildcard, but cheaper than SUBSTRING_INDEX)
    #
    # Best real optimization long-term:
    #   store host separately (or generated column) + index it.
    my $sql = <<'SQL';
SELECT nick, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE id_channel = ?
  AND userhost IS NOT NULL
  AND userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckHostnameNickChan_ctx(): failed to prepare SQL");
        return;
    }

    # Match host suffix inside full userhost like 'nick!ident@host'
    my $mask = '%@' . $hostname;

    unless ($sth->execute($id_channel, $mask)) {
        $self->{logger}->log(1, "mbDbCheckHostnameNickChan_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{nick};
        my $h = $ref->{hits} // 0;
        next unless defined $n && $n ne '';
        push @rows, [$n, $h];
    }
    $sth->finish;

    my $resp;
    if (@rows) {
        my $list = join(' | ', map { "$_->[0] ($_->[1])" } @rows);
        $resp = "Nicks for host $hostname on $target_chan: $list";
    } else {
        $resp = "No result found for hostname $hostname on $target_chan.";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
    }

    logBot($self, $ctx->message, $dest_chan, "checkhostchan", $hostname);
    return 1;
}

# checkhost <hostname|*@host|nick!ident@host>
# Show nicknames seen for a given host (global, across all channels)
# Requires: authenticated + Administrator+
sub mbDbCheckHostnameNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Require authentication
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx checkhost attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged in to use this command: /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Require Administrator+
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx checkhost attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Argument
    my $raw = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $raw =~ s/^\s+|\s+$//g;

    unless ($raw ne '') {
        botNotice($self, $nick, "Syntax: checkhost <hostname>");
        return;
    }

    # Normalize input:
    # - nick!ident@host  -> host
    # - *@host           -> host
    # - ident@host       -> host
    # - host             -> host
    my $host = $raw;
    $host =~ s/^.*\@// if $host =~ /\@/;   # keep part after last '@'
    $host =~ s/^\*\@//;                    # strip leading '*@' if present
    $host =~ s/^\s+|\s+$//g;

    unless ($host ne '') {
        botNotice($self, $nick, "Syntax: checkhost <hostname>");
        return;
    }

    # Output destination:
    # - Private command => Notice
    # - Public command  => Privmsg in channel
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Optimization:
    # - No JOIN
    # - Pattern matches the host part inside full userhost: 'nick!ident@host'
    # - LIMIT keeps it bounded
    #
    # Index hints (if logs are big):
    #   CHANNEL_LOG(userhost), CHANNEL_LOG(nick)
    my $sql = <<'SQL';
SELECT nick, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE userhost IS NOT NULL
  AND userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 20
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx(): failed to prepare SQL");
        return;
    }

    my $mask = '%@' . $host;

    unless ($sth->execute($mask)) {
        $self->{logger}->log(1, "mbDbCheckHostnameNick_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $n = $ref->{nick};
        my $h = $ref->{hits} // 0;
        next unless defined $n && $n ne '';
        push @rows, [$n, $h];
    }
    $sth->finish;

    my $resp;
    if (@rows) {
        my $list = join(' | ', map { "$_->[0] ($_->[1])" } @rows);
        $resp = "Nicks for host $host: $list";
    } else {
        $resp = "No result found for hostname $host.";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
    }

    logBot($self, $ctx->message, $dest_chan, "checkhost", $host);
    return 1;
}

# checknick <nick> - Show top 10 hostmasks for a given nickname
# Requires: authenticated + Master+
sub mbDbCheckNickHostname_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx checknick attempt (unauthenticated)");
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
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx checknick attempt (Master required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    my $search = (defined $args[0] && $args[0] ne '') ? $args[0] : '';
    $search =~ s/^\s+|\s+$//g;

    unless ($search ne '') {
        botNotice($self, $nick, "Syntax: checknick <nick>");
        return;
    }

    # If someone passes a full hostmask, keep only the nick part
    $search =~ s/!.*$//;

    # Reply destination
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;

    # Optimization: use '=' when caller doesn't provide wildcards
    my $use_like = ($search =~ /[%_]/) ? 1 : 0;

    my $sql = $use_like ? <<'SQL' : <<'SQL';
SELECT userhost, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE nick LIKE ?
GROUP BY userhost
ORDER BY hits DESC
LIMIT 10
SQL
SELECT userhost, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE nick = ?
GROUP BY userhost
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth) {
        $self->{logger}->log(1, "mbDbCheckNickHostname_ctx(): failed to prepare SQL");
        return;
    }

    unless ($sth->execute($search)) {
        $self->{logger}->log(1, "mbDbCheckNickHostname_ctx() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref()) {
        my $uh = $ref->{userhost} // next;
        my $hits = $ref->{hits} // 0;

        # Display ident@host only (drop leading "nick!")
        $uh =~ s/^.*!//;

        push @rows, [$uh, $hits];
    }
    $sth->finish;

    my $resp;
    if (@rows) {
        my $list = join(' | ', map { "$_->[0] ($_->[1])" } @rows);
        $resp = "Hostmasks for $search: $list";
    } else {
        $resp = "No result found for nick: $search";
    }

    if ($is_private) {
        botNotice($self, $nick, $resp);
    } else {
        botPrivmsg($self, $dest_chan, $resp);
    }

    logBot($self, $ctx->message, $dest_chan, "checknick", $search);
    return 1;
}

# greet [#channel] <nick>
# If called in private: greet #channel <nick>
sub userGreet_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;  # where to speak if public

    # Resolve target channel:
    # - if first arg is #channel, use it
    # - else use ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    if ($is_private && $target_chan eq '') {
        botNotice($self, $nick, "Syntax (in private): greet #channel <nick>");
        return;
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: greet [#channel] <nick>");
        return;
    }

    # Who are we querying the greet for?
    my $greet_nick = (defined $args[0] && $args[0] ne '') ? $args[0] : $nick;
    $greet_nick =~ s/^\s+|\s+$//g;
    $greet_nick =~ s/!.*$//; # if someone passes nick!ident@host, keep nick

    my $say = sub {
        my ($text) = @_;
        if ($is_private) {
            botNotice($self, $nick, $text);
        } else {
            botPrivmsg($self, $dest_chan, $text);
        }
    };

    my $sql = <<'SQL';
SELECT uc.greet AS greet
FROM CHANNEL c
JOIN USER_CHANNEL uc ON uc.id_channel = c.id_channel
JOIN USER u         ON u.id_user     = uc.id_user
WHERE c.name = ?
  AND u.nickname = ?
LIMIT 1
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_chan, $greet_nick)) {
        $self->{logger}->log(1, "userGreet_ctx() SQL Error: $DBI::errstr Query: $sql");
        $say->("Database error while fetching greet for $greet_nick on $target_chan.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    my $greet = ($ref && defined $ref->{greet} && $ref->{greet} ne '') ? $ref->{greet} : undef;

    if ($greet) {
        $say->("greet on $target_chan ($greet_nick) $greet");
    } else {
        $say->("No greet for $greet_nick on $target_chan");
    }

    my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
    logBot($self, $ctx->message, ($is_private ? undef : $dest_chan), "greet", "$pfx greet on $greet_nick for $target_chan");

    return 1;
}

# Get stored WHOIS variables
sub getWhoisVar(@) {
	my $self = shift;
	return $self->{WHOIS_VARS};
}

# access #channel <nickhandle>
# access #channel =<nick>
sub userAccessChannel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Resolve channel:
    # - If first arg is a #channel, use it and shift it out
    # - Else fallback to ctx->channel (if it looks like a channel)
    my $chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $ctx_chan = $ctx->channel // '';
        $chan = ($ctx_chan =~ /^#/) ? $ctx_chan : '';
    }

    unless ($chan) {
        botNotice($self, $nick, "Syntax: access #channel [=]<nick>");
        return;
    }

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: access #channel [=]<nick>");
        return;
    }

    my $target = $args[0];

    # "=nick" => WHOIS path (kept identical to legacy behavior)
    if (substr($target, 0, 1) eq '=') {
        $target = substr($target, 1);

        $self->{WHOIS_VARS} = {
            nick    => $target,
            sub     => 'userAccessChannel',   # keep legacy sub name for WHOIS handler routing
            caller  => $nick,
            channel => $chan,
            message => $ctx->message,
        };

        $self->{logger}->log(3, "Triggering WHOIS on $target for $nick via userAccessChannel_ctx() channel=$chan");
        $self->{irc}->send_message("WHOIS", undef, $target);
        return;
    }

    # Direct DB handle path
    my $iAccess = getUserChannelLevelByName($self, $chan, $target);

    if (!$iAccess || $iAccess == 0) {
        botNotice($self, $nick, "No Match!");
        logBot($self, $ctx->message, $chan, "access", ($chan, $target));
        return;
    }

    botNotice($self, $nick, "USER: $target ACCESS: $iAccess");

    my $sQuery = "SELECT automode,greet FROM USER,USER_CHANNEL,CHANNEL "
               . "WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel "
               . "AND USER.id_user=USER_CHANNEL.id_user "
               . "AND nickname like ? AND CHANNEL.name=?";

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target, $chan)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $greet = defined($ref->{greet})    ? $ref->{greet}    : "None";
        my $mode  = defined($ref->{automode}) ? $ref->{automode} : "None";

        botNotice($self, $nick, "CHANNEL: $chan -- Automode: $mode");
        botNotice($self, $nick, "GREET MESSAGE: $greet");
        logBot($self, $ctx->message, $chan, "access", ($chan, $target));
    }

    $sth->finish;
    return;
}

# Get user channel level by channel name and nick handle
sub getUserChannelLevelByName(@) {
	my ($self,$sChannel,$sHandle) = @_;
	my $iChannelUserLevel = 0;
	my $sQuery = "SELECT level FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND USER_CHANNEL.id_channel=CHANNEL.id_channel AND CHANNEL.name=? AND USER.nickname=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sHandle)) {
		$self->{logger}->log(1,"getUserChannelLevelByName() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$iChannelUserLevel = $ref->{'level'};
		}
		$self->{logger}->log(3,"getUserChannelLevelByName() iChannelUserLevel = $iChannelUserLevel");
	}
	$sth->finish;
	return $iChannelUserLevel;
}

sub getNickInfoWhois(@) {
	my ($self,$sWhoisHostmask) = @_;
	my $iMatchingUserId = undef;
	my $iMatchingUserLevel = undef;
	my $iMatchingUserLevelDesc = undef;
	my $iMatchingUserAuth = undef;
	my $sMatchingUserHandle = undef;
	my $sMatchingUserPasswd = undef;
	my $sMatchingUserInfo1 = undef;
	my $sMatchingUserInfo2 = undef;
	
	my $sCheckQuery = "SELECT * FROM USER";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		$self->{logger}->log(1,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my @tHostmasks = split(/,/,$ref->{'hostmasks'});
			foreach my $sHostmask (@tHostmasks) {
				$self->{logger}->log(4,"getNickInfoWhois() Checking hostmask : " . $sHostmask);
				$sHostmask =~ s/\./\\./g;
				$sHostmask =~ s/\*/.*/g;
				if ( $sWhoisHostmask =~ /^$sHostmask/ ) {
					$self->{logger}->log(3,"getNickInfoWhois() $sHostmask matches " . $sWhoisHostmask);
					$sMatchingUserHandle = $ref->{'nickname'};
					if (defined($ref->{'password'})) {
						$sMatchingUserPasswd = $ref->{'password'};
					}
					$iMatchingUserId = $ref->{'id_user'};
					my $iMatchingUserLevelId = $ref->{'id_user_level'};
					my $sGetLevelQuery = "SELECT * FROM USER_LEVEL WHERE id_user_level=?";
					my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);
	        unless ($sth2->execute($iMatchingUserLevelId)) {
          				$self->{logger}->log(0,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sGetLevelQuery);
  				}
  				else {
						while (my $ref2 = $sth2->fetchrow_hashref()) {
							$iMatchingUserLevel = $ref2->{'level'};
							$iMatchingUserLevelDesc = $ref2->{'description'};
						}
					}
					$iMatchingUserAuth = $ref->{'auth'};
					if (defined($ref->{'info1'})) {
						$sMatchingUserInfo1 = $ref->{'info1'};
					}
					if (defined($ref->{'info2'})) {
						$sMatchingUserInfo2 = $ref->{'info2'};
					}
					$sth2->finish;
				}
			}
		}
	}
	$sth->finish;
	if (defined($iMatchingUserId)) {
		$self->{logger}->log(3,"getNickInfoWhois() iMatchingUserId : $iMatchingUserId");
	}
	else {
		$self->{logger}->log(3,"getNickInfoWhois() iMatchingUserId is undefined with this host : " . $sWhoisHostmask);
		return (undef,undef,undef,undef,undef,undef,undef);
	}
	if (defined($iMatchingUserLevel)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserLevel : $iMatchingUserLevel");
	}
	if (defined($iMatchingUserLevelDesc)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserLevelDesc : $iMatchingUserLevelDesc");
	}
	if (defined($iMatchingUserAuth)) {
		$self->{logger}->log(4,"getNickInfoWhois() iMatchingUserAuth : $iMatchingUserAuth");
	}
	if (defined($sMatchingUserHandle)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserHandle : $sMatchingUserHandle");
	}
	if (defined($sMatchingUserPasswd)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserPasswd : $sMatchingUserPasswd");
	}
	if (defined($sMatchingUserInfo1)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserInfo1 : $sMatchingUserInfo1");
	}
	if (defined($sMatchingUserInfo2)) {
		$self->{logger}->log(4,"getNickInfoWhois() sMatchingUserInfo2 : $sMatchingUserInfo2");
	}
	return ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2);
}

# auth => sub { userAuthNick_ctx($ctx) },

# /auth <nick> — Triggers a WHOIS to identify if a user is known/authenticated
sub userAuthNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Administrator+ required (and must be logged in)
    $ctx->require_level('Administrator') or return;

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: auth <nick>");
        return;
    }

    my $targetNick = $args[0];

    # WHOIS tracking context (must match mediabot.pl expectations)
    $self->{WHOIS_VARS} = {
        nick    => $targetNick,
        sub     => 'userAuthNick',
        caller  => $nick,
        channel => undef,
        message => $ctx->message,
    };

    $self->{logger}->log(3, "Triggering WHOIS on $targetNick for $nick via userAuthNick_ctx()");
    $self->{irc}->send_message("WHOIS", undef, $targetNick);

    return;
}

# verify <nick> — Triggers a WHOIS to verify a user's existence
sub userVerifyNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # NOTE: original code had no auth/level restriction, so we keep it open.
    # If you later want to restrict it, add: $ctx->require_level('Administrator') or return;

    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: verify <nick>");
        return;
    }

    my $targetNick = $args[0];

    # WHOIS tracking context (must match mediabot.pl expectations)
    $self->{WHOIS_VARS} = {
        nick    => $targetNick,
        sub     => 'userVerifyNick',
        caller  => $nick,
        channel => undef,
        message => $ctx->message,
    };

    $self->{logger}->log(3, "Triggering WHOIS on $targetNick for $nick via userVerifyNick_ctx()");
    $self->{irc}->send_message("WHOIS", undef, $targetNick);

    return;
}

# /nicklist [#channel]
# Shows the list of known users on a specific channel from memory (hChannelsNicks)
# Requires: authenticated + Administrator+
sub channelNickList_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "Unable to identify you.");
        return;
    }

    # Auth required
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx nicklist attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Admin required
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx nicklist attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel, use it
    # - Else fallback to ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: nicklist #channel");
        return;
    }

    # Normalize
    $target_chan =~ s/^\s+|\s+$//g;
    my $target_lc = lc($target_chan);

    # Fetch from memory (try exact, then lc)
    my $nicklist_ref = $self->{hChannelsNicks}{$target_chan}
                    || $self->{hChannelsNicks}{$target_lc};

    unless ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY') {
        $self->{logger}->log(2, "nicklist requested for unknown channel $target_chan");
        botNotice($self, $nick, "No nicklist known for $target_chan.");
        logBot($self, $ctx->message, undef, "nicklist", $target_chan);
        return;
    }

    my @nicks = grep { defined($_) && $_ ne '' } @$nicklist_ref;
    unless (@nicks) {
        botNotice($self, $nick, "Nicklist for $target_chan is empty.");
        logBot($self, $ctx->message, undef, "nicklist", $target_chan);
        return;
    }

    # Avoid flooding / max line length: send in chunks
    my $header = "Users on $target_chan (" . scalar(@nicks) . "): ";
    my $maxlen = 380; # conservative for IRC
    my $line   = $header;

    for my $n (@nicks) {
        my $add = $n . " ";
        if (length($line) + length($add) > $maxlen) {
            botNotice($self, $nick, $line);
            $line = $header . $add;
        } else {
            $line .= $add;
        }
    }
    botNotice($self, $nick, $line) if $line ne $header;

    $self->{logger}->log(3, "nicklist $target_chan => " . scalar(@nicks) . " users");
    logBot($self, $ctx->message, undef, "nicklist", $target_chan);

    return 1;
}

# /rnick [#channel]
# Returns a random nick from the bot's memory list for a given channel (hChannelsNicks)
# Requires: authenticated + Administrator+
sub randomChannelNick_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "Unable to identify you.");
        return;
    }

    # Auth required
    unless ($user->is_authenticated) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx rnick attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        return;
    }

    # Admin required
    unless (eval { $user->has_level('Administrator') }) {
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, "$pfx rnick attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel, use it
    # - Else fallback to ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: rnick #channel");
        return;
    }

    # Normalize
    $target_chan =~ s/^\s+|\s+$//g;
    my $target_lc = lc($target_chan);

    # Fetch from memory (try exact, then lc)
    my $nicklist_ref = $self->{hChannelsNicks}{$target_chan}
                    || $self->{hChannelsNicks}{$target_lc};

    unless ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY') {
        botNotice($self, $nick, "No known nicklist for $target_chan.");
        $self->{logger}->log(2, "rnick: no nicklist for $target_chan");
        logBot($self, $ctx->message, undef, "rnick", $target_chan);
        return;
    }

    # Sanitize list (avoid empty/undef)
    my @pool = grep { defined($_) && $_ ne '' } @$nicklist_ref;

    unless (@pool) {
        botNotice($self, $nick, "Nicklist for $target_chan is empty.");
        $self->{logger}->log(2, "rnick: empty nicklist for $target_chan");
        logBot($self, $ctx->message, undef, "rnick", $target_chan);
        return;
    }

    my $random_nick = $pool[ int(rand(@pool)) ];

    botNotice($self, $nick, "Random nick on $target_chan: $random_nick");
    $self->{logger}->log(3, "rnick $target_chan => $random_nick");
    logBot($self, $ctx->message, undef, "rnick", $target_chan);

    return 1;
}

# Get a random nick from a channel's nick list
sub getRandomNick(@) {
	my ($self,$sChannel) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	my @tChannelNicks = @{$hChannelsNicks{$sChannel}};
	my $sRandomNick = $tChannelNicks[rand @tChannelNicks];
	return $sRandomNick;
}

sub sethChannelsNicksEndOnChan(@) {
	my ($self,$sChannel,$end) = @_;
	my %hChannelsNicksEnd;
	if (defined($self->{hChannelsNicksEnd})) {
		%hChannelsNicksEnd = %{$self->{hChannelsNicksEnd}};
	}
	$hChannelsNicksEnd{$sChannel} = $end;
	%{$self->{hChannelsNicksEnd}} = %hChannelsNicksEnd;
}

sub gethChannelsNicksEndOnChan(@) {
	my ($self,$Schannel) = @_;
	my %hChannelsNicksEnd;
	if (defined($self->{hChannelsNicksEnd})) {
		%hChannelsNicksEnd = %{$self->{hChannelsNicksEnd}};
	}
	if (defined($hChannelsNicksEnd{$Schannel})) {
		return $hChannelsNicksEnd{$Schannel};
	}
	else {
		return 0;
	}
}

sub sethChannelsNicksOnChan(@) {
	my ($self,$sChannel,@tNicklist) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	@{$hChannelsNicks{$sChannel}} = @tNicklist;
	%{$self->{hChannelsNicks}} = %hChannelsNicks;
}

sub gethChannelsNicksOnChan(@) {
	my ($self,$sChannel) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	if (defined($hChannelsNicks{$sChannel})) {
		return @{$hChannelsNicks{$sChannel}};
	}
	else {
		return ();
	}
}

sub gethChannelNicks(@) {
	my $self = shift;
	return $self->{hChannelsNicks};
}

sub sethChannelNicks(@) {
	my ($self,$phChannelsNicks) = @_;
	%{$self->{hChannelsNicks}} = %$phChannelsNicks;
}

sub channelNicksRemove(@) {
	my ($self,$sChannel,$sNick) = @_;
	my %hChannelsNicks;
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	my $index;
	for ($index=0;$index<=$#{$hChannelsNicks{$sChannel}};$index++ ) {
		my $currentNick = @{$hChannelsNicks{$sChannel}}[$index];
		if ( $currentNick eq $sNick) {
			splice(@{$hChannelsNicks{$sChannel}}, $index, 1);
			last;
		}
	}
	%{$self->{hChannelsNicks}} = %hChannelsNicks;
}

sub getYoutubeDetails(@) {
	my ($self,$sText) = @_;
	my $conf = $self->{conf};
	my $sYoutubeId;
	$self->{logger}->log(3,"getYoutubeDetails() $sText");
	if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/music\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*youtu\.be\///;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
		$self->{logger}->log(3,"getYoutubeDetails() sYoutubeId = $sYoutubeId");
		my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			$self->{logger}->log(0,"getYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			$self->{logger}->log(0,"getYoutubeDetails() section [main]");
			$self->{logger}->log(0,"getYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}
		unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			$self->{logger}->log(3,"getYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
		}
		else {
			my $line;
			my $i = 0;
			my $sTitle;
			my $sDuration;
			my $sDururationSeconds;
			my $sViewCount;
			my $json_details;
			while(defined($line=<YOUTUBE_INFOS>)) {
				chomp($line);
				$json_details .= $line;
				$self->{logger}->log(5,"getYoutubeDetails() $line");
				$i++;
			}
			if (defined($json_details) && ($json_details ne "")) {
				$self->{logger}->log(4,"getYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = decode_json $json_details;
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				$self->{logger}->log(4,"getYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					$self->{logger}->log(4,"getYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					my $sTitleItem = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					$self->{logger}->log(3,"getYoutubeDetails() sDuration : $sDuration");
					$sDuration =~ s/^PT//;
					my $sDisplayDuration;
					my $sHour = $sDuration;
					if ( $sHour =~ /H/ ) {
						$sHour =~ s/H.*$//;
						$sDisplayDuration .= "$sHour" . "h ";
						$sDururationSeconds = $sHour * 3600;
					}
					my $sMin = $sDuration;
					if ( $sMin =~ /M/ ) {
						$sMin =~ s/^.*H//;
						$sMin =~ s/M.*$//;
						$sDisplayDuration .= "$sMin" . "mn ";
						$sDururationSeconds += $sMin * 60;
					}
					my $sSec = $sDuration;
					if ( $sSec =~ /S/ ) {
						$sSec =~ s/^.*H//;
						$sSec =~ s/^.*M//;
						$sSec =~ s/S$//;
						$sDisplayDuration .= "$sSec" . "s";
						$sDururationSeconds += $sSec;
					}
					$self->{logger}->log(3,"getYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					$self->{logger}->log(3,"getYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					$self->{logger}->log(3,"getYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					
					if (defined($sTitle) && ( $sTitle ne "" ) && defined($sDuration) && ( $sDuration ne "" ) && defined($sViewCount) && ( $sViewCount ne "" )) {
						my $sMsgSong .= String::IRC->new('You')->black('white');
						$sMsgSong .= String::IRC->new('Tube')->white('red');
						$sMsgSong .= String::IRC->new(" $sTitle ")->white('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sDisplayDuration ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sViewCount")->grey('black');
						$sMsgSong =~ s/\r//;
						$sMsgSong =~ s/\n//;
						return($sDururationSeconds,$sMsgSong);
					}
					else {
						$self->{logger}->log(3,"getYoutubeDetails() one of the youtube field is undef or empty");
						if (defined($sTitle)) {
							$self->{logger}->log(3,"getYoutubeDetails() sTitle=$sTitle");
						}
						else {
							$self->{logger}->log(3,"getYoutubeDetails() sTitle is undefined");
						}
						
						if (defined($sDuration)) {
							$self->{logger}->log(3,"getYoutubeDetails() sDuration=$sDuration");
						}
						else {
							$self->{logger}->log(3,"getYoutubeDetails() sDuration is undefined");
						}
						if (defined($sViewCount)) {
							$self->{logger}->log(3,"getYoutubeDetails() sViewCount=$sViewCount");
						}
						else {
							$self->{logger}->log(3,"getYoutubeDetails() sViewCount is undefined");
						}
					}
				}
				else {
					$self->{logger}->log(3,"getYoutubeDetails() Invalid id : $sYoutubeId");
					my $sNoticeMsg = "getYoutubeDetails() Invalid id : $sYoutubeId";
					noticeConsoleChan($self,$sNoticeMsg);
				}
			}
			else {
				$self->{logger}->log(3,"getYoutubeDetails() curl empty result for : curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		$self->{logger}->log(3,"getYoutubeDetails() sYoutubeId could not be determined");
	}
	return undef;
}

# Display Youtube details
sub displayYoutubeDetails(@) {
	my ($self,$message,$sNick,$sChannel,$sText) = @_;
	my $conf = $self->{conf};
	my $sYoutubeId;
	$self->{logger}->log(3,"displayYoutubeDetails() $sText");

	if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/music\.youtube\..*\/watch.*v=/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch.*v=//;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}
	elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*youtu\.be\///;
		$sYoutubeId = substr($sYoutubeId,0,11);
	}

	if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
		$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeId = $sYoutubeId");

		my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			$self->{logger}->log(0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			$self->{logger}->log(0,"displayYoutubeDetails() section [main]");
			$self->{logger}->log(0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}

		unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			$self->{logger}->log(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
		}
		else {
			my $line;
			my $i = 0;
			my $sTitle;
			my $sDuration;
			my $sViewCount;
			my $json_details;
			my $schannelTitle;
			while(defined($line=<YOUTUBE_INFOS>)) {
				chomp($line);
				$json_details .= $line;
				$self->{logger}->log(5,"displayYoutubeDetails() $line");
				$i++;
			}
			if (defined($json_details) && ($json_details ne "")) {
				$self->{logger}->log(4,"displayYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = decode_json $json_details;
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				$self->{logger}->log(4,"displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					$self->{logger}->log(4,"displayYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					$sTitle = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$schannelTitle = $hYoutubeItems{'snippet'}{'channelTitle'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					$self->{logger}->log(3,"displayYoutubeDetails() sDuration : $sDuration");
					$sDuration =~ s/^PT//;
					my $sDisplayDuration;
					my $sHour = $sDuration;
					if ( $sHour =~ /H/ ) {
						$sHour =~ s/H.*$//;
						$sDisplayDuration .= "$sHour" . "h ";
					}
					my $sMin = $sDuration;
					if ( $sMin =~ /M/ ) {
						$sMin =~ s/^.*H//;
						$sMin =~ s/M.*$//;
						$sDisplayDuration .= "$sMin" . "mn ";
					}
					my $sSec = $sDuration;
					if ( $sSec =~ /S/ ) {
						$sSec =~ s/^.*H//;
						$sSec =~ s/^.*M//;
						$sSec =~ s/S$//;
						$sDisplayDuration .= "$sSec" . "s";
					}
					$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeInfo statistics channelTitle : $schannelTitle");

					if (defined($sTitle) && ( $sTitle ne "" ) && defined($sDuration) && ( $sDuration ne "" ) && defined($sViewCount) && ( $sViewCount ne "" )) {
						# Normalize title if too many uppercase letters
						my $upper_count_title   = ($sTitle =~ tr/A-Z//);
						my $upper_count_channel = ($schannelTitle =~ tr/A-Z//);

						if ($upper_count_title > 20) {
							$self->{logger}->log( 3, "displayYoutubeDetails() sTitle has $upper_count_title uppercase letters, normalizing.");
							$sTitle = ucfirst(lc($sTitle));
						}

						if ($upper_count_channel > 20) {
							$self->{logger}->log( 3, "displayYoutubeDetails() schannelTitle has $upper_count_channel uppercase letters, normalizing.");
							$schannelTitle = ucfirst(lc($schannelTitle));
						}

						my $sMsgSong .= String::IRC->new('[')->white('black');
						$sMsgSong .= String::IRC->new('You')->black('white');
						$sMsgSong .= String::IRC->new('Tube')->white('red');
						$sMsgSong .= String::IRC->new(']')->white('black');
						$sMsgSong .= String::IRC->new(" $sTitle ")->white('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sDisplayDuration ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sViewCount ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("by $schannelTitle")->grey('black');

						$sMsgSong =~ s/\r//;
						$sMsgSong =~ s/\n//;
						botPrivmsg($self,$sChannel,"($sNick) $sMsgSong");
					}
					else {
						$self->{logger}->log(3,"displayYoutubeDetails() one of the youtube field is undef or empty");
						$self->{logger}->log(3,"displayYoutubeDetails() sTitle=$sTitle")     if defined($sTitle);
						$self->{logger}->log(3,"displayYoutubeDetails() sDuration=$sDuration") if defined($sDuration);
						$self->{logger}->log(3,"displayYoutubeDetails() sViewCount=$sViewCount") if defined($sViewCount);
					}
				}
				else {
					$self->{logger}->log(3,"displayYoutubeDetails() Invalid id : $sYoutubeId");
				}
			}
			else {
				$self->{logger}->log(3,"displayYoutubeDetails() curl empty result for : curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeId could not be determined");
	}
}

# Weather command using wttr.in
sub displayWeather_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel; # may be undef in private
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require to be used in channel (your original behavior)
    unless (defined $channel && $channel =~ /^#/) {
        botNotice($self, $nick, "Syntax (in channel): weather <City|City,CC|lat,lon>");
        return;
    }

    # Respect your chanset gate: Weather
    my $id_chanset_list = getIdChansetList($self, "Weather");
    return unless defined $id_chanset_list;

    my $id_channel_set = getIdChannelSet($self, $channel, $id_chanset_list);
    return unless defined $id_channel_set;

    my $q = join(' ', grep { defined && $_ ne '' } @args);
    $q =~ s/^\s+|\s+$//g;

    unless ($q ne '') {
        botNotice($self, $nick, "Syntax (no accents): weather <City|City,CC|lat,lon>");
        return;
    }

    # Normalize input a bit:
    # - allow "Paris FR" => "Paris,FR"
    # - keep "lat,lon"
    my $location = $q;
    if ($location !~ /,/ && $location =~ /\s+([A-Za-z]{2})$/) {
        my $cc = $1;
        $location =~ s/\s+[A-Za-z]{2}$/,$cc/;
    }
    $location =~ s/\s+/,/g if $location =~ /^[^,]+ [^,]+$/ && $location !~ /^\s*[-+]?\d/; # "New York" -> "New,York"
    $location =~ s/^\s+|\s+$//g;

    # Cache (keyed by location)
    my $cache_key = lc($location);
    $self->{_weather_cache} ||= {};
    my $cache = $self->{_weather_cache}{$cache_key};

    my $now = time();
    my $ttl_ok = 180;  # 3 minutes
    my $ttl_stale = 900; # 15 minutes (fallback if provider unhappy)

    if ($cache && ($now - ($cache->{ts}||0) <= $ttl_ok) && ($cache->{text}||'') ne '') {
        botPrivmsg($self, $channel, $cache->{text});
        return 1;
    }

    # Build wttr request
    # A bit richer than before, still short:
    # %l location, %c icon, %t temp, %f feelslike, %h humidity, %w wind, %p precip
    my $format = '%l: %c %t (feels %f) | 💧%h | 🌬%w | ☔%p';

    my $encoded = uri_escape_utf8($location);
    my $url = "https://wttr.in/$encoded?format=" . uri_escape_utf8($format) . "&m";

    my $http = HTTP::Tiny->new(
        timeout => 4,
        agent   => "mediabot_v3 weather/1.0 (+https://teuk.org)",
        verify_SSL => 1,
    );

    my $res = $http->get($url, {
        headers => {
            'Accept'          => 'text/plain',
            'Accept-Language' => 'fr-FR,fr;q=0.9,en;q=0.5',
        }
    });

    # Helper to use cached text when provider is flaky
    my $use_cache_or_msg = sub {
        my ($msg) = @_;
        if ($cache && ($now - ($cache->{ts}||0) <= $ttl_stale) && ($cache->{text}||'') ne '') {
            botPrivmsg($self, $channel, $cache->{text} . "  (cached)");
        } else {
            botPrivmsg($self, $channel, $msg);
        }
    };

    unless ($res && $res->{success}) {
        my $code = $res ? ($res->{status} // '??') : '??';
        $self->{logger}->log(2, "displayWeather_ctx(): wttr HTTP failure code=$code url=$url");
        $use_cache_or_msg->("Weather service unavailable (HTTP $code), try again later.");
        return;
    }

    my $line = $res->{content} // '';
    $line =~ s/^\s+|\s+$//g;
    $line =~ s/\r//g;

    # wttr sometimes replies with “Unknown location” or throttling texts
    if ($line eq '' || $line =~ /^Unknown location/i || $line =~ /try again later/i || $line =~ /Service unavailable/i) {
        $self->{logger}->log(2, "displayWeather_ctx(): wttr unhappy reply for '$location': '$line'");
        $use_cache_or_msg->("No answer from wttr.in for '$location'. Try again later.");
        return;
    }

    # Save cache + reply
    $self->{_weather_cache}{$cache_key} = { ts => $now, text => $line };
    botPrivmsg($self, $channel, $line);
    logBot($self, $ctx->message, $channel, "weather", $location);

    return 1;
}

# Display URL title
sub displayUrlTitle(@) {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    # Debug initial
    $self->{logger}->log(3, "displayUrlTitle() RAW input: $sText");

    my $sContentType;
    my $iHttpResponseCode;
    my $sTextURL = $sText;

    # Extraction stricte de l'URL
    $sText =~ s/^.*http/http/;
    $sText =~ s/\s+.*$//;
    $self->{logger}->log(3, "displayUrlTitle() URL extracted: $sText");

    # --- Twitter (x.com) chanset ---
    if ( $sText =~ /x.com/ ) {
        my $id_chanset_list = getIdChansetList($self, "Twitter");
        if (defined $id_chanset_list && $id_chanset_list ne "") {
            $self->{logger}->log(3, "id_chanset_list = $id_chanset_list");
            my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
            unless (defined $id_channel_set && $id_channel_set ne "") {
                return undef;
            }
            $self->{logger}->log(3, "id_channel_set = $id_channel_set");
        }
    }

    # --- Twitter special prank ---
    if ((($sText =~ /x.com/) || ($sText =~ /twitter.com/))
        && (($sNick =~ /^\[k\]$/) || ($sNick =~ /^NHI$/) || ($sNick =~ /^PersianYeti$/))) {
        $self->{logger}->log(3, "displayUrlTitle() Twitter URL = $sText");
        return undef;
    }

    # --- Instagram ---
    if ( $sText =~ /instagram.com/ ) {
        my $content;
        unless (open URL_HEAD, "curl \"$sText\" |") {
            $self->{logger}->log(3, "displayUrlTitle() insta Could not curl GET for url details");
        } else {
            while (my $line = <URL_HEAD>) {
                chomp($line);
                $content .= $line;
            }
            close URL_HEAD;
        }

        my $title = $content;
        if (defined $title) {
            $title =~ s/^.*og:title" content="//;
            $title =~ s/" .><meta property="og:image".*$//;
            unless ($title =~ /DOCTYPE html/) {
                $self->{logger}->log(3, "displayUrlTitle() (insta) Extracted title : $title");
            } else {
                $title = $content;
                $title =~ s/^.*<title//;
                $title =~ s/<\/title>.*$//;
                $title =~ s/^\s*>//;
            }
            if ($title ne "") {
                my $msg = String::IRC->new("[")->white('black');
                $msg .= String::IRC->new("Instagram")->white('pink');
                $msg .= String::IRC->new("]")->white('black');
                $msg .= " $title";
                my $regex = "&(?:" . join("|", map { s/;\z//; $_ } keys %entity2char) . ");";
                if (($msg =~ /$regex/) || ($msg =~ /&#.*;/)) {
                    $msg = decode_entities($msg);
                }
                $msg = "($sNick) " . $msg;
                unless ($msg =~ /DOCTYPE html/) {
                    botPrivmsg($self, $sChannel, substr($msg, 0, 300));
                }
            }
        }
        return undef;
    }

    # --- HEAD request pour content-type + HTTP code ---
    unless (open URL_HEAD, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -I -ks \"$sText\" |") {
        $self->{logger}->log(3, "displayUrlTitle() Could not curl headers for $sText");
    } else {
        while (my $line = <URL_HEAD>) {
            chomp($line);
            $self->{logger}->log(4, "displayUrlTitle() HEAD: $line");
            if ($line =~ /^content\-type/i) {
                (undef, $sContentType) = split(" ", $line);
                $self->{logger}->log(4, "displayUrlTitle() sContentType = $sContentType");
            } elsif ($line =~ /^http/i) {
                (undef, $iHttpResponseCode) = split(" ", $line);
                $self->{logger}->log(4, "displayUrlTitle() iHttpResponseCode = $iHttpResponseCode");
            }
        }
        close URL_HEAD;
    }

    unless (defined $iHttpResponseCode && $iHttpResponseCode eq "200") {
        $self->{logger}->log(3, "displayUrlTitle() Wrong HTTP response code (" . ($iHttpResponseCode // "undefined") . ") for $sText");
        return undef;
    }

    unless (defined $sContentType && $sContentType =~ /text\/html/i) {
        $self->{logger}->log(3, "displayUrlTitle() Wrong Content-Type for $sText (" . ($sContentType // "Undefined") . ")");
        return undef;
    }

    # --- Spotify ---
    if ($sText =~ /open.spotify.com/) {
        my $url = $sText;
        $url =~ s/\?.*$//;
        unless (open URL_TITLE, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -ks \"$url\" |") {
            $self->{logger}->log(0, "displayUrlTitle() Could not curl UrlTitle for $sText");
        } else {
            while (my $line = <URL_TITLE>) {
                chomp($line);
                if ($line =~ /<title>/) {
                    my $sDisplayMsg = $line;
                    $sDisplayMsg =~ s/^.*<title//;
                    $sDisplayMsg =~ s/<\/title>.*$//;
                    $sDisplayMsg =~ s/^>//;
                    my $artist = $sDisplayMsg;
                    $artist =~ s/^.*song and lyrics by //;
                    $artist =~ s/ \| Spotify//;
                    my $song = $sDisplayMsg;
                    $song =~ s/ - song and lyrics by.*$//;
                    $self->{logger}->log(3, "displayUrlTitle() artist = $artist song = $song");

                    my $sTextIrc = String::IRC->new("[")->white('black');
                    $sTextIrc .= String::IRC->new("Spotify")->black('green');
                    $sTextIrc .= String::IRC->new("]")->white('black');
                    $sTextIrc .= " $artist - $song";
                    my $regex = "&(?:" . join("|", map { s/;\z//; $_ } keys %entity2char) . ");";
                    if (($sTextIrc =~ /$regex/) || ($sTextIrc =~ /&#.*;/)) {
                        $sTextIrc = decode_entities($sTextIrc);
                    }
                    botPrivmsg($self, $sChannel, "($sNick) $sTextIrc");
                }
            }
            close URL_TITLE;
        }
        return undef;
    }

    # --- URL générique ---
    unless (open URL_TITLE, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -ks \"$sText\" |") {
        $self->{logger}->log(0, "displayUrlTitle() Could not curl UrlTitle for $sText");
    } else {
        my $sContent;
        while (my $line = <URL_TITLE>) {
            chomp($line);
            $sContent .= "$line\n";
        }
        close URL_TITLE;

        my $tree = HTML::Tree->new();
        $tree->parse($sContent);
        my ($title) = $tree->look_down('_tag', 'title');
        if (defined($title) && $title->as_text ne "") {
            if (($sText =~ /youtube.com/) || ($sText =~ /youtu\.be/)) {
                my $yt = String::IRC->new('[')->white('black');
                $yt .= String::IRC->new('You')->black('white');
                $yt .= String::IRC->new('Tube')->white('red');
                $yt .= String::IRC->new(']')->white('black');
                botPrivmsg($self, $sChannel, "($sNick) $yt " . $title->as_text);
            }
            elsif ($sText =~ /music.apple.com/) {
                my $id_chanset_list = getIdChansetList($self, "AppleMusic");
                if (defined($id_chanset_list) && $id_chanset_list ne "") {
                    my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
                    unless (defined($id_channel_set) && $id_channel_set ne "") {
                        return undef;
                    }
                }
                my $apple = String::IRC->new('[')->white('black');
                $apple .= String::IRC->new('AppleMusic')->white('grey');
                $apple .= String::IRC->new(']')->white('black');
                botPrivmsg($self, $sChannel, "($sNick) $apple " . $title->as_text);
            }
            else {
                if ($title->as_text !~ /The page is temporarily unavailable/i) {
                    my $msg = String::IRC->new("URL Title from $sNick:")->grey('black');
                    botPrivmsg($self, $sChannel, $msg . " " . $title->as_text);
                }
            }
        }
    }
}

# debug [0-5]
# Show or set the bot debug level.
# Requires: authenticated + Owner
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

    $self->{logger}->log(0, "Debug set to $level");
    botNotice($self, $nick, "Debug level set to $level");

    logBot($self, $ctx->message, $channel, "debug", "Debug set to $level");
    return 1;
}

# Restart the bot (/restart)
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
        my $msg = $message->prefix . " restart command attempt (level [Owner] required for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Fork process
    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            $self->{logger}->log(0, "Restart requested by " . $user->nickname);
            setsid;
            exec "./mb_restart.sh", $tArgs[0];
            exit 1; # just in case
        } else {
            botNotice($self, $sNick, "Restarting bot");
            logBot($self, $message, undef, "restart", $conf->get('main.MAIN_PROG_QUIT_MSG'));
            $self->{Quit} = 1;
            $self->{irc}->send_message("QUIT", undef, "Restarting");
        }
    } else {
        $self->{logger}->log(1, "Failed to fork for restart");
        botNotice($self, $sNick, "Restart failed: unable to fork.");
    }

    return;
}


# Jump to another server (/jump <server> [args...])
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

    unless (@tArgs && $tArgs[-1] ne "") {
        botNotice($self, $sNick, "Syntax: jump <server> [args...]");
        return;
    }

    my $server = pop @tArgs;
    my $params = join(" ", @tArgs);
    $params =~ s/--server=[^ ]*//g;  # clean existing --server if present

    $self->{logger}->log(3, "Jumping with args: $params");

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            $self->{logger}->log(0, "Jump request from " . $user->nickname);
            setsid;
            exec "./mb_restart.sh", $params, "--server=$server";
            exit 1;
        } else {
            botNotice($self, $sNick, "Jumping to $server");
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
sub make_colors_pretty {
    my ($self, $string) = @_;

    # Keep UTF-8 flag (as you did)
    Encode::_utf8_on($string);

    # mIRC color codes (avoid 0/8/15/14: too bright/low-contrast on some themes)
    # 02 blue, 03 green, 04 red, 05 brown, 06 purple, 07 orange, 10 cyan, 13 pink
    my @palette = (2, 3, 4, 6, 7, 10, 13, 5);
    my $num = scalar(@palette);

    my $new = '';
    my $i   = 0;

    for my $char (split //, $string) {
        if ($char eq ' ') {
            $new .= ' ';
            next;
        }

        my $c = $palette[$i % $num];

        # \003 = mIRC color introducer, \017 = reset
        $new .= "\003" . sprintf("%02d", $c) . $char;
        $i++;
    }

    # Reset formatting at end
    $new .= "\017";

    return $new;
}

# colors <text>  (Context version)
sub mbColors_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $text = join(' ', grep { defined && $_ ne '' } @args);

    unless (defined $text && $text ne '') {
        botNotice($self, $nick, "Syntax: colors <text>");
        return;
    }

    my $out = make_colors_pretty($self, $text);

    # In channel => privmsg ; in private => notice
    if (defined($ctx->channel) && $ctx->channel =~ /^#/) {
        botPrivmsg($self, $ctx->channel, $out);
    } else {
        botNotice($self, $nick, $out);
    }

    return 1;
}

# seen <nick> [#channel]
# - In channel: defaults to current channel for part checks, replies in channel
# - In private: you can pass an optional #channel; replies by notice
sub mbSeen_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    unless (@args) {
        botNotice($self, $nick, "Syntax: seen <nick> [#channel]");
        return;
    }

    my $targetNick = shift @args;

    # Channel context:
    # - If caller gave a #channel as next arg => use it for part checks
    # - Else if command issued in a channel => use ctx->channel
    # - Else (private) => no channel part check unless provided
    my $chan_for_part;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan_for_part = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan_for_part = ($cc =~ /^#/) ? $cc : undef;
    }

    # Output destination
    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel; # only used when not private

    # Resolve id_channel if we want a part check
    my $id_channel = 0;
    if (defined $chan_for_part && $chan_for_part =~ /^#/) {
        my $channel_obj = $self->{channels}{$chan_for_part} || $self->{channels}{lc($chan_for_part)};
        $id_channel = eval { $channel_obj->get_id } || 0;
        # If channel not known in-memory, we just skip the part check (no noisy SQL)
        $id_channel = 0 unless $id_channel;
    }

    # --- Latest QUIT (global) ---
    my $quit;
    my $sql_quit = <<'SQL';
SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
FROM CHANNEL_LOG
WHERE nick = ? AND event_type = 'quit'
ORDER BY ts DESC
LIMIT 1
SQL

    my $sth_quit = $self->{dbh}->prepare($sql_quit);
    if ($sth_quit && $sth_quit->execute($targetNick)) {
        if (my $r = $sth_quit->fetchrow_hashref()) {
            $quit = {
                ts   => $r->{ts},
                uts  => $r->{uts}  // 0,
                host => $r->{userhost}   // '',
                text => $r->{publictext} // '',
            };
        }
    } else {
        $self->{logger}->log(1, "mbSeen_ctx() SQL quit error: $DBI::errstr");
    }
    $sth_quit->finish if $sth_quit;

    # --- Latest PART (channel-scoped, only if we have an id_channel) ---
    my $part;
    if ($id_channel) {
        my $sql_part = <<'SQL';
SELECT ts, UNIX_TIMESTAMP(ts) AS uts, userhost, publictext
FROM CHANNEL_LOG
WHERE id_channel = ? AND nick = ? AND event_type = 'part'
ORDER BY ts DESC
LIMIT 1
SQL
        my $sth_part = $self->{dbh}->prepare($sql_part);
        if ($sth_part && $sth_part->execute($id_channel, $targetNick)) {
            if (my $r = $sth_part->fetchrow_hashref()) {
                $part = {
                    ts   => $r->{ts},
                    uts  => $r->{uts}  // 0,
                    host => $r->{userhost}   // '',
                    text => $r->{publictext} // '',
                };
            }
        } else {
            $self->{logger}->log(1, "mbSeen_ctx() SQL part error: $DBI::errstr");
        }
        $sth_part->finish if $sth_part;
    }

    # Helper: prettify host (strip "nick!")
    my $fmt_host = sub {
        my ($h) = @_;
        $h //= '';
        $h =~ s/^.*!//;
        return $h;
    };

    # Decide what to report
    my $msg;
    my $quit_uts = $quit ? ($quit->{uts} // 0) : 0;
    my $part_uts = $part ? ($part->{uts} // 0) : 0;

    if (!$quit_uts && !$part_uts) {
        $msg = "I don't remember seeing nick $targetNick.";
    }
    elsif ($part_uts && $part_uts >= $quit_uts && $chan_for_part) {
        my $host = $fmt_host->($part->{host});
        my $txt  = $part->{text} // '';
        $msg = "$targetNick ($host) was last seen parting $chan_for_part : $part->{ts}" . ($txt ne '' ? " ($txt)" : "");
    }
    else {
        my $host = $fmt_host->($quit->{host});
        my $txt  = $quit->{text} // '';
        $msg = "$targetNick ($host) was last seen quitting : $quit->{ts}" . ($txt ne '' ? " ($txt)" : "");
    }

    # Send output
    if ($is_private) {
        botNotice($self, $nick, $msg);
        logBot($self, $ctx->message, undef, "seen", $targetNick);
    } else {
        botPrivmsg($self, $dest_chan, $msg);
        logBot($self, $ctx->message, $dest_chan, "seen", $targetNick);
    }

    return 1;
}

# popcmd — show top 20 public commands (by hits) created by a given user
# Context-based migration:
# - Uses ctx for bot/nick/channel/message/args
# - Better display: one-line, truncated with "..."
# - Sends to channel if invoked in-channel, otherwise NOTICE
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
sub _tz_exists {
    my ($self, $tz) = @_;
    my $sth = $self->{dbh}->prepare("SELECT tz FROM TIMEZONE WHERE tz LIKE ?");
    return $sth->execute($tz) && $sth->fetchrow_hashref();
}

# Get a user's timezone
sub _get_user_tz {
    my ($self, $nick) = @_;
    my $sth = $self->{dbh}->prepare("SELECT tz FROM USER WHERE nickname LIKE ?");
    return unless $sth->execute($nick);
    my $ref = $sth->fetchrow_hashref();
    return $ref ? $ref->{tz} : undef;
}

# Set timezone for a user
sub _set_user_tz {
    my ($self, $nick, $tz) = @_;
    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=? WHERE nickname LIKE ?");
    return $sth->execute($tz, $nick);
}

# Clear timezone for a user
sub _del_user_tz {
    my ($self, $nick) = @_;
    my $sth = $self->{dbh}->prepare("UPDATE USER SET tz=NULL WHERE nickname LIKE ?");
    return $sth->execute($nick);
}

# date [tz|nick|alias|list|me|user add/del ...]
sub displayDate_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    @args = grep { defined && $_ ne '' } @args;

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel; # only when not private

    # Helper: send output to correct place
    my $say = sub {
        my ($txt) = @_;
        if ($is_private) { botNotice($self, $nick, $txt); }
        else             { botPrivmsg($self, $dest_chan, $txt); }
    };

    my $default_tz = 'America/New_York';

    # Aliases
    my %alias = (
        fr     => 'Europe/Paris',
        moscow => 'Europe/Moscow',
        la     => 'America/Los_Angeles',
        dk     => 'Europe/Copenhagen',
    );

    # No arg => default TZ
    if (!@args) {
        my $dt = DateTime->now(time_zone => $default_tz);
        $say->("$default_tz : " . $dt->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    my $arg0 = $args[0];

    # Easter egg
    if ($arg0 =~ /^me$/i) {
        my @answers = (
            "Ok $nick, I'll pick you up at eight ;>",
            "I have to ask my daddy first $nick ^^",
            "let's skip that $nick, and go to your place :P~",
        );
        $say->($answers[int(rand(@answers))]);
        return 1;
    }

    # List
    if ($arg0 =~ /^list$/i) {
        $say->("Available Timezones: https://pastebin.com/4p4pby3y");
        return 1;
    }

    # Admin subcommands: date user add <nick> <tz> | date user del <nick>
    if ($arg0 =~ /^user$/i) {
        my $user = $ctx->user;

        # Require authenticated + Administrator+
        unless ($user && $user->is_authenticated) {
            noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick) . " date user attempt (unauthenticated)");
            botNotice($self, $nick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
            return;
        }
        unless (eval { $user->has_level('Administrator') }) {
            my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
            noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick) . " date user attempt (Administrator required for " . ($user->nickname // '?') . " [$lvl])");
            botNotice($self, $nick, "Your level does not allow you to use this command.");
            return;
        }

        my $sub = $args[1] // '';
        if ($sub =~ /^add$/i) {
            my ($targetNick, $targetTZ) = @args[2, 3];

            unless (defined $targetNick && $targetNick ne '' && defined $targetTZ && $targetTZ ne '') {
                $say->("Usage:");
                $say->("  date user add <nick> <timezone>");
                return;
            }

            my $current = $self->_get_user_tz($targetNick);
            if (defined $current && $current ne '') {
                $say->("$targetNick already has timezone $current. Delete it first.");
                return;
            }

            # allow alias on tz too
            my $tz_in = $targetTZ;
            $tz_in = $alias{lc $tz_in} if exists $alias{lc $tz_in};

            unless ($self->_tz_exists($tz_in)) {
                $say->("Timezone $tz_in not found. See: https://pastebin.com/4p4pby3y");
                return;
            }

            if ($self->_set_user_tz($targetNick, $tz_in)) {
                my $now = DateTime->now(time_zone => $tz_in);
                $say->("Updated timezone for $targetNick: $tz_in " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
                logBot($self, $ctx->message, $ctx->channel, "date", @args);
            } else {
                $say->("Failed to update timezone for $targetNick.");
            }
            return 1;

        } elsif ($sub =~ /^del$/i) {
            my $targetNick = $args[2];

            unless (defined $targetNick && $targetNick ne '') {
                $say->("Usage:");
                $say->("  date user del <nick>");
                return;
            }

            my $tz = $self->_get_user_tz($targetNick);
            unless (defined $tz && $tz ne '') {
                $say->("$targetNick has no defined timezone.");
                return;
            }

            if ($self->_del_user_tz($targetNick)) {
                $say->("Deleted timezone for $targetNick.");
                logBot($self, $ctx->message, $ctx->channel, "date", @args);
            } else {
                $say->("Failed to delete timezone for $targetNick.");
            }
            return 1;

        } else {
            $say->("Usage:");
            $say->("  date user add <nick> <timezone>");
            $say->("  date user del <nick>");
            return 1;
        }
    }

    # Apply alias (for tz/user lookup too)
    $arg0 = $alias{lc $arg0} if exists $alias{lc $arg0};

    # If arg0 is a known user => show their tz
    my $user_tz = $self->_get_user_tz($arg0);
    if ($user_tz) {
        my $now = DateTime->now(time_zone => $user_tz);
        $say->("Current date for $arg0 ($user_tz): " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    # If arg0 is a valid timezone => show it
    if ($self->_tz_exists($arg0)) {
        my $now = DateTime->now(time_zone => $arg0);
        $say->("$arg0 : " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return 1;
    }

    $say->("Unknown user or timezone: $arg0");
    return 1;
}

# Responder functions
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
			$self->{logger}->log(3,"checkResponder() Found answer $sAnswer");
			botPrivmsg($self,$sChannel,$actionDo);
			my $sQuery = "UPDATE RESPONDERS SET hits=? WHERE id_responders=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($hits,$id_responders)) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$self->{logger}->log(3,"$hits hits for $sMsg");
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
sub evalAction(@) {
	my ($self,$message,$sNick,$sChannel,$sCommand,$actionDo,@tArgs) = @_;
	$self->{logger}->log(3,"evalAction() $sCommand / $actionDo");
	if (defined($tArgs[0])) {
		my $sArgs = join(" ",@tArgs);
		$actionDo =~ s/%n/$sArgs/g;
	}
	else {
		$actionDo =~ s/%n/$sNick/g;
	}
	if ( $actionDo =~ /%r/ ) {
		my $sRandomNick = getRandomNick($self,$sChannel);
		$actionDo =~ s/%r/$sRandomNick/g;
	}
	if ( $actionDo =~ /%R/ ) {
		my $sRandomNick = getRandomNick($self,$sChannel);
		$actionDo =~ s/%R/$sRandomNick/g;
	}
	if ( $actionDo =~ /%s/ ) {
		my $sCommandWithSpaces = $sCommand;
		$sCommandWithSpaces =~ s/_/ /g;
		$actionDo =~ s/%s/$sCommandWithSpaces/g;
	}
	unless ( $actionDo =~ /%b/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%b/true/g;
		}
		else {
			$actionDo =~ s/%b/false/g;
		}
	}
	if ( $actionDo =~ /%B/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%B/true/g;
		}
		else {
			$actionDo =~ s/%B/false/g;
		}
	}
	if ( $actionDo =~ /%on/ ) {
		my $iTrueFalse = int(rand(2));
		if ( $iTrueFalse == 1 ) {
			$actionDo =~ s/%on/oui/g;
		}
		else {
			$actionDo =~ s/%on/non/g;
		}
	}
	if ( $actionDo =~ /%c/ ) {
		$actionDo =~ s/%c/$sChannel/g;
	}
	if ( $actionDo =~ /%N/ ) {
		$actionDo =~ s/%N/$sNick/g;
	}
	my @tActionDo = split(/ /,$actionDo);
	my $pos;
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%d' ) {
			$tActionDo[$pos] = int(rand(10) + 1);
		}
	}
	$actionDo = join(" ",@tActionDo);
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%dd' ) {
			$tActionDo[$pos] = int(rand(90) + 10);
		}
	}
	$actionDo = join(" ",@tActionDo);
	for ($pos=0;$pos<=$#tActionDo;$pos++) {
		if ( $tActionDo[$pos] eq '%ddd' ) {
			$tActionDo[$pos] = int(rand(900) + 100);
		}
	}
	$actionDo = join(" ",@tActionDo);
	return $actionDo;
}

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
sub channelAddBadword_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx addbadword command attempt (unauthenticated)");
        return;
    }

    # Master only
    unless (eval { $user->has_level('Master') } ) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx addbadword command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Resolve target channel:
    # - If first arg is #channel use it
    # - else fallback to ctx->channel
    my $chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    # Channel must be registered in memory
    my $channel_obj = $self->{channels}{$chan} || $self->{channels}{lc($chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    # Badword text
    my $badword = join(" ", grep { defined && $_ ne '' } @args);
    $badword =~ s/^\s+|\s+$//g;

    unless ($badword ne '') {
        botNotice($self, $nick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    # Already exists?
    my $sth = $self->{dbh}->prepare(
        "SELECT id_badwords, badword FROM BADWORDS WHERE id_channel=? AND badword=?"
    );
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelAddBadword_ctx() SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $nick, "Badword [$ref->{id_badwords}] '$ref->{badword}' is already defined on $chan");
        logBot($self, $ctx->message, $chan, "addbadword", "$chan $badword");
        $sth->finish;
        return;
    }
    $sth->finish;

    # Insert
    $sth = $self->{dbh}->prepare("INSERT INTO BADWORDS (id_channel, badword) VALUES (?, ?)");
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelAddBadword_ctx() SQL Error: $DBI::errstr");
        return;
    }

    botNotice($self, $nick, "Added badword '$badword' to $chan");
    logBot($self, $ctx->message, $chan, "addbadword", "$chan $badword");
    $sth->finish;

    return 1;
}

# Remove a badword from a channel
sub channelRemBadword_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $user = $ctx->user;

    # Require authentication
    unless ($user && $user->is_authenticated) {
        botNotice(
            $self, $nick,
            "You must be logged to use this command - /msg "
            . $self->{irc}->nick_folded
            . " login username password"
        );
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        noticeConsoleChan($self, "$pfx rembadword command attempt (unauthenticated)");
        return;
    }

    # Master only
    unless (eval { $user->has_level('Master') }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'unknown';
        noticeConsoleChan($self, "$pfx rembadword command attempt (level [Master] required for " . ($user->nickname // '?') . " [$lvl])");
        return;
    }

    # Resolve target channel
    my $chan;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $chan = ($cc =~ /^#/) ? $cc : undef;
    }

    unless (defined $chan && $chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    # Channel must be registered in memory
    my $channel_obj = $self->{channels}{$chan} || $self->{channels}{lc($chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $chan is not registered");
        return;
    }

    # Badword text
    my $badword = join(" ", grep { defined && $_ ne '' } @args);
    $badword =~ s/^\s+|\s+$//g;

    unless ($badword ne '') {
        botNotice($self, $nick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    # Find badword id
    my $sql_sel = "SELECT id_badwords FROM BADWORDS WHERE id_channel = ? AND badword = ?";
    my $sth = $self->{dbh}->prepare($sql_sel);
    unless ($sth && $sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "channelRemBadword_ctx() SQL Error: $DBI::errstr Query: $sql_sel");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref && $ref->{id_badwords}) {
        botNotice($self, $nick, "Badword '$badword' is not set on $chan");
        return 0;
    }

    my $id_badwords = $ref->{id_badwords};

    # Delete
    my $sql_del = "DELETE FROM BADWORDS WHERE id_badwords = ?";
    $sth = $self->{dbh}->prepare($sql_del);
    unless ($sth && $sth->execute($id_badwords)) {
        $self->{logger}->log(1, "channelRemBadword_ctx() SQL Error: $DBI::errstr Query: $sql_del");
        return;
    }

    botNotice($self, $nick, "Removed badword '$badword' from $chan");
    logBot($self, $ctx->message, $chan, "rembadword", "$chan $badword");
    $sth->finish;

    return 1;
}

# Check if a message is from an ignored user
sub isIgnored(@) {
	my ($self,$message,$sChannel,$sNick,$sMsg)	= @_;
	my $sCheckQuery = "SELECT * FROM IGNORES WHERE id_channel=0";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		$self->{logger}->log(1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = $ref->{'hostmask'};
			$sHostmask =~ s/\./\\./g;
			$sHostmask =~ s/\*/.*/g;
			$sHostmask =~ s/\[/\\[/g;
			$sHostmask =~ s/\]/\\]/g;
			$sHostmask =~ s/\{/\\{/g;
			$sHostmask =~ s/\}/\\}/g;
			if ( $message->prefix =~ /^$sHostmask/ ) {
				$self->{logger}->log(4,"isIgnored() (allchans/private) $sHostmask matches " . $message->prefix);
				$self->{logger}->log(0,"[IGNORED] " . $ref->{'hostmask'} . " (allchans/private) " . ((substr($sChannel,0,1) eq '#') ? "$sChannel:" : "") . "<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	$sCheckQuery = "SELECT * FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
	$sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = $ref->{'hostmask'};
			$sHostmask =~ s/\./\\./g;
			$sHostmask =~ s/\*/.*/g;
			$sHostmask =~ s/\[/\\[/g;
			$sHostmask =~ s/\]/\\]/g;
			$sHostmask =~ s/\{/\\{/g;
			$sHostmask =~ s/\}/\\}/g;
			if ( $message->prefix =~ /^$sHostmask/ ) {
				$self->{logger}->log(4,"isIgnored() $sHostmask matches " . $message->prefix);
				$self->{logger}->log(0,"[IGNORED] " . $ref->{'hostmask'} . " $sChannel:<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	return 0;
}

# List ignores
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
sub youtubeSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel;  # undef si privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Feature gate via chanset
    my $id_chanset_list = getIdChansetList($self, "YoutubeSearch");
    return unless defined($id_chanset_list) && $id_chanset_list ne "";

    # en privé, on n’a pas de channel => on refuse (ou tu peux autoriser si tu veux)
    unless (defined $chan && $chan ne '') {
        botNotice($self, $nick, "yt can only be used in a channel (YoutubeSearch chanset scoped).");
        return;
    }

    my $id_channel_set = getIdChannelSet($self, $chan, $id_chanset_list);
    return unless defined($id_channel_set) && $id_channel_set ne "";

    # Args
    unless (@args && defined $args[0] && $args[0] ne "") {
        botNotice($self, $nick, "Syntax: yt <search>");
        return;
    }

    my $conf   = $self->{conf};
    my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');

    unless (defined($APIKEY) && $APIKEY ne "") {
        $self->{logger}->log(0, "youtubeSearch_ctx() YOUTUBE_APIKEY not set in ".$self->{config_file});
        return;
    }

    my $query_txt = join(" ", @args);
    my $q_enc     = url_encode_utf8($query_txt);

    # ---------- 1) search endpoint (maxResults=1, type=video, fields réduits) ----------
    my $search_url =
        "https://www.googleapis.com/youtube/v3/search"
        . "?part=snippet"
        . "&type=video"
        . "&maxResults=1"
        . "&q=$q_enc"
        . "&key=$APIKEY"
        . "&fields=items(id/videoId)";

    my $json_search = '';
    if (open my $fh, "-|", "curl", "--connect-timeout", "5", "--max-time", "6", "-fsSL", $search_url) {
        local $/;
        $json_search = <$fh> // '';
        close $fh;
    } else {
        $self->{logger}->log(2, "youtubeSearch_ctx(): curl failed for search endpoint");
        botPrivmsg($self, $chan, "($nick) YouTube: service unavailable (search).");
        return;
    }

    my $video_id;
    eval {
        my $data = decode_json($json_search);
        $video_id = $data->{items}[0]{id}{videoId};
        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/search parse error: $@");
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    };

    unless (defined $video_id && $video_id ne '') {
        botPrivmsg($self, $chan, "($nick) YouTube: no result.");
        return;
    }

    # ---------- 2) videos endpoint (fields réduits) ----------
    my $videos_url =
        "https://www.googleapis.com/youtube/v3/videos"
        . "?id=$video_id"
        . "&key=$APIKEY"
        . "&part=snippet,contentDetails,statistics"
        . "&fields=items(snippet/title,contentDetails/duration,statistics/viewCount)";

    my $json_vid = '';
    if (open my $fh2, "-|", "curl", "--connect-timeout", "5", "--max-time", "6", "-fsSL", $videos_url) {
        local $/;
        $json_vid = <$fh2> // '';
        close $fh2;
    } else {
        $self->{logger}->log(2, "youtubeSearch_ctx(): curl failed for videos endpoint");
        botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_id");
        return;
    }

    my ($title, $dur_iso, $views);
    eval {
        my $data = decode_json($json_vid);
        my $it   = $data->{items}[0] || {};
        $title   = $it->{snippet}{title};
        $dur_iso = $it->{contentDetails}{duration};
        $views   = $it->{statistics}{viewCount};
        1;
    } or do {
        $self->{logger}->log(2, "youtubeSearch_ctx(): JSON decode/videos parse error: $@");
        botPrivmsg($self, $chan, "($nick) https://www.youtube.com/watch?v=$video_id");
        return;
    };

    $title   //= '';
    $dur_iso //= '';
    $views   //= '';

    my $dur_disp = _yt_format_duration($dur_iso);
    my $views_disp = ($views ne '' && $views =~ /^\d+$/) ? "views $views" : "views ?";

    # ---------- output (safe colors) ----------
    my $badge = _yt_badge();

    my $url = "https://www.youtube.com/watch?v=$video_id";
    my $msg = "$badge $url";
    $msg   .= " - $title" if $title ne '';
    $msg   .= " - $dur_disp" if $dur_disp ne '';
    $msg   .= " - $views_disp";

    botPrivmsg($self, $chan, "($nick) $msg");
    logBot($self, $message, $chan, "yt", $query_txt);

    return 1;
}

# Duration: ISO8601 "PT#H#M#S" -> "1h 02m 03s" / "3m 12s" / "45s"
sub _yt_format_duration {
    my ($iso) = @_;
    return '' unless defined $iso && $iso =~ /^PT/i;

    my ($h,$m,$s) = (0,0,0);
    $h = $1 if $iso =~ /(\d+)H/;
    $m = $1 if $iso =~ /(\d+)M/;
    $s = $1 if $iso =~ /(\d+)S/;

    my @out;
    push @out, sprintf("%dh", $h) if $h;
    push @out, sprintf("%02dm", $m) if ($h || $m);
    push @out, sprintf("%02ds", $s) if ($h || $m || $s);

    # if no hours and minutes, show seconds even if zero
    my $txt = join(' ', @out);
    $txt =~ s/^00m\s+// if !$h; # “00m 12s” -> “12s”
    $txt =~ s/\b00s$// if ($h || $m) && $s == 0; # optionnel: “3m 00s” -> “3m”
    $txt =~ s/\s+$//;

    return $txt;
}

# YouTube badge with safe colors
sub _yt_badge {
    my $plain = "[YouTube]";
    return $plain unless eval { String::IRC->can('new') };

    my $b = String::IRC->new('[')->bold;
    $b   .= String::IRC->new('You')->bold;                  # neutre
    $b   .= String::IRC->new('Tube')->bold->red;            # rouge (sans fond)
    $b   .= String::IRC->new(']')->bold;
    return "$b";
}

# Get the current song from the radio stream
sub getRadioCurrentSong(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
	my $RADIO_JSON     = $conf->get('radio.RADIO_JSON');
	my $RADIO_SOURCE   = $conf->get('radio.RADIO_SOURCE');

	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		$self->{logger}->log(0,"getRadioCurrentSong() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}
	
	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	if ($RADIO_PORT == 443) {
		$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON";
	}
	
	unless (open ICECAST_STATUS_JSON, "curl --connect-timeout 3 -f -s $JSON_STATUS_URL |") {
		return "N/A";
	}
	
	my $line;
	if (defined($line = <ICECAST_STATUS_JSON>)) {
		close ICECAST_STATUS_JSON;
		chomp($line);
		my $json = decode_json $line;
		my $source_data = $json->{'icestats'}{'source'};
        my @sources = ref($source_data) eq 'ARRAY' ? @$source_data : ($source_data);

		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'title'})) {
				my $title = $source{'title'};
				if ($title =~ /&#.*;/) {
					return decode_entities($title);
				} else {
					return $title;
				}
			}
			elsif (defined($source{'server_description'})) {
				return $source{'server_description'};
			}
			elsif (defined($source{'server_name'})) {
				return $source{'server_name'};
			}
			else {
				return "N/A";
			}
		}
		else {
			return undef;
		}
	}
	else {
		return "N/A";
	}
}

sub getRadioCurrentListeners(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
	my $RADIO_JSON     = $conf->get('radio.RADIO_JSON');
	my $RADIO_SOURCE   = $conf->get('radio.RADIO_SOURCE');  # optionnel

	unless (defined($RADIO_HOSTNAME) && $RADIO_HOSTNAME ne "") {
		$self->{logger}->log(0, "getRadioCurrentListeners() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}

	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON" if $RADIO_PORT == 443;

	my $fh;
	unless (open($fh, "-|", "curl", "--connect-timeout", "3", "-f", "-s", $JSON_STATUS_URL)) {
		return undef;
	}

	my $line = <$fh>;
	close $fh;

	return undef unless defined $line;
	chomp($line);

	my $json;
	eval { $json = decode_json($line); };
	if ($@ or not defined $json->{'icestats'}{'source'}) {
		return undef;
	}

	my $source_data = $json->{'icestats'}{'source'};
	my @sources = ref($source_data) eq 'ARRAY' ? @$source_data : ($source_data);

	if (defined $RADIO_SOURCE && $RADIO_SOURCE ne '') {
		foreach my $s (@sources) {
			if (defined($s->{'mount'}) && $s->{'mount'} eq $RADIO_SOURCE) {
				return int($s->{'listeners'} || 0);
			}
		}
	} else {
		my $s = $sources[0];
		return int($s->{'listeners'} || 0) if defined $s;
	}

	return undef;
}




# Get the harbor name from the LIQUIDSOAP telnet port
sub getRadioHarbor(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_HARBOR, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			$self->{logger}->log( 3, "Unable to connect to LIQUIDSOAP telnet port");
		}

		my $line;
		while (defined($line = <LIQUIDSOAP_HARBOR>)) {
			chomp($line);
			if ($line =~ /harbor/) {
				my $sHarbor = $line;
				$sHarbor =~ s/^.*harbor/harbor/;
				$sHarbor =~ s/\..*$//;
				close LIQUIDSOAP_HARBOR;
				return $sHarbor;
			}
		}

		close LIQUIDSOAP_HARBOR;
		return undef;
	} else {
		return undef;
	}
}

# Check if the radio is live by checking the LIQUIDSOAP harbor status
sub isRadioLive(@) {
	my ($self, $sHarbor) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_HARBOR, "echo -ne \"$sHarbor.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			$self->{logger}->log( 3, "Unable to connect to LIQUIDSOAP telnet port");
		}

		my $line;
		while (defined($line = <LIQUIDSOAP_HARBOR>)) {
			chomp($line);
			if ($line =~ /source/) {
				$self->{logger}->log( 3, $line);
				if ($line =~ /no source client connected/) {
					return 0;
				} else {
					return 1;
				}
			}
		}
		close LIQUIDSOAP_HARBOR;
		return 0;
	} else {
		return 0;
	}
}

# Get the remaining time of the current song from the LIQUIDSOAP telnet port
sub getRadioRemainingTime(@) {
	my ($self) = @_;
	my $conf = $self->{conf};

	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');
	my $RADIO_URL = $conf->get('radio.RADIO_URL');

	my $LIQUIDSOAP_MOUNPOINT = $RADIO_URL;
	$LIQUIDSOAP_MOUNPOINT =~ s/\./(dot)/;

	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep remaining | tr -s \" \" | cut -f2 -d\" \" | tail -n 1 |") {
			$self->{logger}->log( 0, "getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
		}
		my $line;
		if (defined($line = <LIQUIDSOAP>)) {
			chomp($line);
			$self->{logger}->log( 3, $line);
			unless (open LIQUIDSOAP2, "echo -ne \"$line\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				$self->{logger}->log( 0, "getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
			}
			my $line2;
			if (defined($line2 = <LIQUIDSOAP2>)) {
				chomp($line2);
				$self->{logger}->log( 3, $line2);
				return $line2;
			}
		}
		return 0;
	} else {
		$self->{logger}->log( 0, "getRadioRemainingTime() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
}

# Display the current song on the radio
sub displayRadioCurrentSong_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel; # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};
    my $RADIO_HOSTNAME          = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT              = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL               = $conf->get('radio.RADIO_URL');
    my $LIQUIDSOAP_TELNET_HOST  = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');

    # Optional flags:
    #   --safe  => colors without background (readable on dark/light)
    #   --plain => no IRC colors at all
    my $safe  = 0;
    my $plain = 0;
    @args = grep {
        if ($_ eq '--safe')  { $safe = 1; 0 }
        elsif ($_ eq '--plain'){ $plain = 1; 0 }
        else { 1 }
    } @args;

    # Resolve target channel
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }
    unless (defined($target_chan) && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: song <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    # Fetch song + harbor/live
    my $title   = getRadioCurrentSong($self);
    my $harbor  = getRadioHarbor($self);
    my $is_live = 0;

    if (defined($harbor) && $harbor ne '') {
        $self->{logger}->log(3, $harbor);
        $is_live = isRadioLive($self, $harbor) ? 1 : 0;
    }

    unless (defined($title) && $title ne '') {
        botNotice($self, $nick, "Radio is currently unavailable");
        return;
    }

    # Build URL
    my $url;
    if (defined($RADIO_PORT) && $RADIO_PORT == 443) {
        $url = "https://$RADIO_HOSTNAME/$RADIO_URL";
    } else {
        $url = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL";
    }

    # Remaining time (only if not live and telnet configured)
    my $remaining_txt = '';
    if (!$is_live && defined($LIQUIDSOAP_TELNET_HOST) && $LIQUIDSOAP_TELNET_HOST ne '') {
        my $rem = getRadioRemainingTime($self);
        $rem = 0 unless defined($rem) && $rem =~ /^\d+(\.\d+)?$/;

        my $total = int($rem);
        my $min   = int($total / 60);
        my $sec   = $total % 60;

        my @parts;
        push @parts, sprintf("%d min%s", $min, ($min > 1 ? 's' : '')) if $min > 0;
        push @parts, sprintf("%d sec%s", $sec, ($sec > 1 ? 's' : ''));
        $remaining_txt = join(" and ", @parts) . " remaining";
    }

    # Output formatting (plain / safe / legacy)
    my $out = _radio_song_format(
        url       => $url,
        title     => $title,
        is_live   => $is_live,
        remaining => $remaining_txt,
        safe      => $safe,
        plain     => $plain,
    );

    botPrivmsg($self, $target_chan, $out);
    logBot($self, $message, $target_chan, "song", $nick);
    return 1;
}

sub _radio_song_format {
    my (%p) = @_;
    my $url       = $p{url} // '';
    my $title     = $p{title} // '';
    my $is_live   = $p{is_live} ? 1 : 0;
    my $remaining = $p{remaining} // '';
    my $safe      = $p{safe} ? 1 : 0;
    my $plain     = $p{plain} ? 1 : 0;

    # Plain text fallback (no colors)
    if ($plain || !eval { String::IRC->can('new') }) {
        my $s = "[ $url ] - [ " . ($is_live ? "Live - " : "") . $title . " ]";
        $s   .= " - [ $remaining ]" if $remaining ne '';
        return $s;
    }

    # SAFE mode: avoid background colors (readable on any theme)
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new($url)->bold->orange;
        $s   .= String::IRC->new(' ] - [ ')->bold;
        $s   .= String::IRC->new('Live - ')->bold->red if $is_live;
        $s   .= String::IRC->new($title)->bold;
        $s   .= String::IRC->new(' ]')->bold;

        if ($remaining ne '') {
            $s .= String::IRC->new(' - [ ')->bold;
            $s .= String::IRC->new($remaining)->grey;
            $s .= String::IRC->new(' ]')->bold;
        }
        return "$s";
    }

    # Legacy mode: keep your exact style (backgrounds)
    my $sMsgSong = String::IRC->new('[ ')->white('black');

    $sMsgSong .= String::IRC->new($url)->orange('black');

    $sMsgSong .= String::IRC->new(' ] ')->white('black');
    $sMsgSong .= String::IRC->new(' - ')->white('black');
    $sMsgSong .= String::IRC->new(' [ ')->orange('black');

    $sMsgSong .= String::IRC->new('Live - ')->white('black') if $is_live;

    $sMsgSong .= String::IRC->new($title)->white('black');
    $sMsgSong .= String::IRC->new(' ]')->orange('black');

    if ($remaining ne '') {
        $sMsgSong .= String::IRC->new(' - ')->white('black');
        $sMsgSong .= String::IRC->new(' [ ')->orange('black');
        $sMsgSong .= String::IRC->new($remaining)->white('black');
        $sMsgSong .= String::IRC->new(' ]')->orange('black');
    }

    return "$sMsgSong";
}

# Display current number of radio listeners
sub displayRadioListeners_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel; # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};

    my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL      = $conf->get('radio.RADIO_URL');

    # Flags optionnels :
    #   --safe  => couleurs sans background (lisible partout)
    #   --plain => aucun code couleur
    my $safe  = 0;
    my $plain = 0;
    @args = grep {
        if ($_ eq '--safe')   { $safe = 1; 0 }
        elsif ($_ eq '--plain'){ $plain = 1; 0 }
        else { 1 }
    } @args;

    # Resolve target channel :
    # - si commande vient d’un chan → ctx->channel
    # - en privé, autoriser listeners #chan
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && defined($args[0]) && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined($target_chan) && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: listeners <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc($target_chan)};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    my $listeners = getRadioCurrentListeners($self);
    unless (defined($listeners) && $listeners ne '') {
        botNotice($self, $nick, "Radio is currently unavailable");
        return;
    }

    $listeners = int($listeners);
    my $msg = _radio_listeners_format(
        listeners => $listeners,
        safe      => $safe,
        plain     => $plain,
    );

    botPrivmsg($self, $target_chan, $msg);
    logBot($self, $message, $target_chan, "listeners", "$listeners listener(s)");
    return 1;
}

sub _radio_listeners_format {
    my (%p) = @_;

    my $n     = $p{listeners} // 0;
    my $safe  = $p{safe}  ? 1 : 0;
    my $plain = $p{plain} ? 1 : 0;

    # Fallback sans couleurs (plain)
    if ($plain || !eval { String::IRC->can('new') }) {
        my $word = ($n == 1) ? "listener" : "listeners";
        return "Currently $n $word on the radio.";
    }

    my $word = ($n == 1) ? "listener" : "listeners";

    # SAFE : pas de background → lisible sur fond clair ou sombre
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new('Radio')->bold->orange;
        $s   .= String::IRC->new(' ] ')->bold;
        $s   .= String::IRC->new('Currently ')->grey;
        $s   .= String::IRC->new($n)->bold->green;
        $s   .= String::IRC->new(" $word")->grey;
        return "$s";
    }

    # Legacy : on garde ton truc psychédélique d’origine
    my $sMsgListeners = String::IRC->new('(')->white('red');
    $sMsgListeners   .= String::IRC->new(')')->maroon('red');
    $sMsgListeners   .= String::IRC->new('(')->red('maroon');
    $sMsgListeners   .= String::IRC->new(')')->black('maroon');
    $sMsgListeners   .= String::IRC->new('( ')->maroon('black');
    $sMsgListeners   .= String::IRC->new('( ')->red('black');
    $sMsgListeners   .= String::IRC->new('Currently ')->silver('black');
    $sMsgListeners   .= String::IRC->new(')-( ')->red('black');
    $sMsgListeners   .= $n;
    $sMsgListeners   .= String::IRC->new(' )-( ')->red('black');
    $sMsgListeners   .= String::IRC->new("$word")->white('black');
    $sMsgListeners   .= String::IRC->new(' ) ')->red('black');
    $sMsgListeners   .= String::IRC->new(')')->maroon('black');
    $sMsgListeners   .= String::IRC->new('(')->black('maroon');
    $sMsgListeners   .= String::IRC->new(')')->red('maroon');
    $sMsgListeners   .= String::IRC->new('(')->maroon('red');
    $sMsgListeners   .= String::IRC->new(')')->white('red');

    return "$sMsgListeners";
}

# Set the radio metadata (current song)
sub setRadioMetadata {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        my $msg = $message->prefix . " metadata command attempt (user not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->level eq "Administrator") {
        my $msg = $message->prefix . " metadata command attempt (command level [Administrator] for user " . $user->nickname . " [" . $user->level_description . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Load radio config
    my $conf = $self->{conf};
    my $RADIO_HOSTNAME  = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT      = $conf->get('radio.RADIO_PORT');
    my $RADIO_SOURCE    = $conf->get('radio.RADIO_SOURCE');
    my $RADIO_URL       = $conf->get('radio.RADIO_URL');
    my $RADIO_ADMINPASS = $conf->get('radio.RADIO_ADMINPASS');

    # If first argument is a channel name, validate and shift it
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        my $channel_name = shift @tArgs;
        my $channel_obj = $self->{channels}{$channel_name};

        unless ($channel_obj) {
            botNotice($self, $sNick, "Channel $channel_name is undefined");
            return;
        }

        $sChannel = $channel_name;
    }

    # Join remaining arguments as metadata string
    my $sNewMetadata = join(" ", @tArgs);

    # If no metadata provided, show current song instead
    unless ($sNewMetadata ne '') {
        displayRadioCurrentSong($self, $message, $sNick, $sChannel)
            if (defined($sChannel) && $sChannel ne '');
        return;
    }

    # Ensure admin password is set
    unless (defined($RADIO_ADMINPASS) && $RADIO_ADMINPASS ne '') {
        $self->{logger}->log(0, "setRadioMetadata() radio.RADIO_ADMINPASS not set in " . $self->{config_file});
        return;
    }

    # Send metadata update to Icecast
    my $encoded_meta = url_encode_utf8($sNewMetadata);
    my $curl_cmd = qq{curl --connect-timeout 3 -f -s -u admin:$RADIO_ADMINPASS "http://$RADIO_HOSTNAME:$RADIO_PORT/admin/metadata?mount=/$RADIO_URL&mode=updinfo&song=$encoded_meta"};

    unless (open ICECAST_UPDATE_METADATA, "$curl_cmd |") {
        botNotice($self, $sNick, "Unable to update metadata (curl failed)");
        return;
    }

    my $line = <ICECAST_UPDATE_METADATA>;
    close ICECAST_UPDATE_METADATA;

    # Confirm or show updated metadata
    if (defined $line) {
        chomp $line;
        if (defined($sChannel) && $sChannel ne '') {
            sleep 3;  # let Icecast refresh its metadata
            displayRadioCurrentSong($self, $message, $sNick, $sChannel);
        } else {
            botNotice($self, $sNick, "Metadata updated to: $sNewMetadata");
        }
    } else {
        botNotice($self, $sNick, "Unable to update metadata");
    }
}

# Skip to the next song in the radio stream (Context version)
sub radioNext_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my $chan    = $ctx->channel;      # undef en privé
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Récup utilisateur
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };
    unless ($user && eval { $user->id }) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        my $msg = ($message && $message->can('prefix'))
            ? $message->prefix . " nextsong command attempt (user " . $user->nickname . " is not logged in)"
            : "nextsong command attempt (unauthenticated)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Droits Administrator+
    my $is_admin = eval { $user->has_level('Administrator') };
    $is_admin = checkUserLevel($self, $user->level, "Administrator") unless $is_admin;

    unless ($is_admin) {
        my $msg = ($message && $message->can('prefix'))
            ? $message->prefix . " nextsong command attempt (user " . $user->nickname . " does not have [Administrator] rights)"
            : "nextsong command attempt (insufficient rights)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Options d'affichage : --safe / --plain (facultatives)
    my $safe  = 0;
    my $plain = 0;

    @args = grep {
        if    ($_ eq '--safe')   { $safe  = 1; 0 }
        elsif ($_ eq '--plain')  { $plain = 1; 0 }
        else { 1 }
    } @args;

    # Canal cible :
    # - si commande vient du chan → ctx->channel
    # - sinon, autoriser nextsong #chan
    my $target_chan = $chan;
    if ((!defined $target_chan || $target_chan eq '') && @args && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: nextsong <#channel> [--safe|--plain]");
        return;
    }

    my $channel_obj = $self->{channels}{$target_chan} || $self->{channels}{lc $target_chan};
    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_chan is not registered");
        return;
    }

    # Config radio
    my $conf = $self->{conf};

    my $RADIO_HOSTNAME         = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT             = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL              = $conf->get('radio.RADIO_URL');
    my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
    my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

    unless ($LIQUIDSOAP_TELNET_HOST && $LIQUIDSOAP_TELNET_PORT) {
        $self->{logger}->log(0,
            "radioNext_ctx(): LIQUIDSOAP_TELNET_HOST/PORT not set in " . ($self->{config_file} // 'config')
        );
        botNotice($self, $nick, "Liquidsoap telnet endpoint is not configured.");
        return;
    }

    # Transform mountpoint (RADIO_URL) pour Liquidsoap
    my $mountpoint = $RADIO_URL // '';
    $mountpoint =~ s/\./(dot)/g;

    # Commande telnet via nc
    my $cmd = qq{echo -ne "$mountpoint.skip\\nquit\\n" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT};

    my $lines = 0;
    if (open my $fh, "$cmd |") {
        while (my $line = <$fh>) {
            chomp $line;
            $lines++;
        }
        close $fh;
    } else {
        botNotice($self, $nick, "Unable to connect to LIQUIDSOAP telnet port");
        $self->{logger}->log(1, "radioNext_ctx(): failed to run nc command: $cmd");
        return;
    }

    # Liquidsoap répond en général quelque chose (prompt etc.)
    if ($lines > 0) {
        my $msg = _radio_next_format(
            nick        => $nick,
            hostname    => $RADIO_HOSTNAME,
            port        => $RADIO_PORT,
            mount       => $RADIO_URL,
            safe        => $safe,
            plain       => $plain,
        );
        botPrivmsg($self, $target_chan, $msg);
        logBot($self, $message, $target_chan, "nextsong", "$nick skipped to next track");
    } else {
        botNotice($self, $nick, "No response from Liquidsoap. The command may have failed.");
        $self->{logger}->log(2, "radioNext_ctx(): nc produced no output for cmd: $cmd");
    }

    return 1;
}

sub _radio_next_format {
    my (%p) = @_;

    my $nick     = $p{nick}     // '?';
    my $host     = $p{hostname} // 'radio';
    my $port     = $p{port}     // 80;
    my $mount    = $p{mount}    // '';
    my $safe     = $p{safe}  ? 1 : 0;
    my $plain    = $p{plain} ? 1 : 0;

    my $url = ($port && $port == 443)
        ? "https://$host/$mount"
        : "http://$host:$port/$mount";

    # Mode texte brut (no colors)
    if ($plain || !eval { String::IRC->can('new') }) {
        return "[$url] - [$nick skipped to next track]";
    }

    # Mode safe : couleurs sans background
    if ($safe) {
        my $s = String::IRC->new('[ ')->bold;
        $s   .= String::IRC->new($url)->orange;
        $s   .= String::IRC->new(' ] ')->bold;
        $s   .= String::IRC->new('-')->white;
        $s   .= String::IRC->new(' [ ')->orange;
        $s   .= String::IRC->new("$nick skipped to next track")->grey;
        $s   .= String::IRC->new(' ]')->orange;
        return "$s";
    }

    # Mode legacy avec fond noir, comme ton code original
    my $sMsgSong = String::IRC->new('[ ')->grey('black');
    $sMsgSong   .= String::IRC->new($url)->orange('black');
    $sMsgSong   .= String::IRC->new(' ] ')->grey('black');
    $sMsgSong   .= String::IRC->new(' - ')->white('black');
    $sMsgSong   .= String::IRC->new(' [ ')->orange('black');
    $sMsgSong   .= String::IRC->new("$nick skipped to next track")->grey('black');
    $sMsgSong   .= String::IRC->new(' ]')->orange('black');

    return "$sMsgSong";
}

# Update the bot
sub update(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				$self->{logger}->log(3,"Update TBD ;)");
			}
			else {
				my $sNoticeMsg = $message->prefix . " update command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " update command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Display the last N entries from ACTIONS_LOG table
# Syntax:
#   lastcom [<count>]
# Notes:
#   - count defaults to 5, max is 8
#   - Master+ only
#   - Always private reply (NOTICE)
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
sub mbQuotes_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;       # IRC nick of caller
    my $channel = $ctx->channel;    # may be undef in private
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------------------------
    # Syntax: if no subcommand given, show help and return
    # ---------------------------------------------------------
    unless (@args && defined $args[0] && $args[0] ne "") {
        $self->_printQuoteSyntax($nick);
        return;
    }

    # Subcommand (normalized)
    my $subcmd = lc shift @args;

    # ---------------------------------------------------------
    # Resolve user object (prefer Context, fallback to legacy)
    # ---------------------------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };

    my ($uid, $handle, $auth, $level, $level_desc) = (undef, undef, 0, undef, undef);

    if ($user) {
        $uid        = eval { $user->id };
        $handle     = eval { $user->nickname } // $nick;
        $auth       = eval { $user->is_authenticated } ? 1 : 0;
        $level      = eval { $user->level };
        $level_desc = eval { $user->level_description };
    }

    # ---------------------------------------------------------
    # Authenticated users with level >= "User"
    #   -> full access to all subcommands
    # ---------------------------------------------------------
    if ( $user && $auth && defined $level && checkUserLevel($self, $level, "User") ) {

        return mbQuoteAdd($self, $message, $uid, $handle, $nick, $channel, @args)
            if $subcmd =~ /^(add|a)$/;

        return mbQuoteDel($self, $message, $handle, $nick, $channel, @args)
            if $subcmd =~ /^(del|d)$/;

        return mbQuoteView($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(view|v)$/;

        return mbQuoteSearch($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(search|s)$/;

        return mbQuoteRand($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(random|r)$/;

        return mbQuoteStats($self, $message, $nick, $channel, @args)
            if $subcmd eq "stats";

        # Unknown subcommand for authenticated user
        $self->_printQuoteSyntax($nick);
        return;
    }

    # ---------------------------------------------------------
    # Unauthenticated or low-level users
    #   -> only view/search/random/stats
    #   -> BUT "add" is still allowed (legacy behavior),
    #      using undef uid/handle, with sNick + channel
    # ---------------------------------------------------------

    # Read-only subcommands
    return mbQuoteView($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(view|v)$/;

    return mbQuoteSearch($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(search|s)$/;

    return mbQuoteRand($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(random|r)$/;

    return mbQuoteStats($self, $message, $nick, $channel, @args)
        if $subcmd eq "stats";

    # Anonymous/legacy add (no user id/handle)
    return mbQuoteAdd($self, $message, undef, undef, $nick, $channel, @args)
        if $subcmd =~ /^(add|a)$/;

    # ---------------------------------------------------------
    # At this point, the user is either unauthenticated or
    # does not have the required level for the requested
    # subcommand (e.g. "del" without proper rights).
    # ---------------------------------------------------------
    my $who   = defined $handle ? $handle : $nick;
    my $pfx   = ($message && $message->can('prefix')) ? $message->prefix : $nick;
    my $descr = $level_desc // $level // 'unknown';

    my $logmsg = "$pfx q command attempt (user $who is not logged in or insufficient level [$descr])";
    noticeConsoleChan($self, $logmsg);

    botNotice(
        $self,
        $nick,
        "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
    );

    return;
}

# Display the syntax for the quote command
sub _printQuoteSyntax {
	my ($self, $sNick) = @_;
	botNotice($self, $sNick, "Quotes syntax:");
	botNotice($self, $sNick, "q [add or a] text1 | text2 | ... | textn");
	botNotice($self, $sNick, "q [del or d] id");
	botNotice($self, $sNick, "q [view or v] id");
	botNotice($self, $sNick, "q [search or s] text");
	botNotice($self, $sNick, "q [random or r]");
	botNotice($self, $sNick, "q stats");
}

# Add a new quote to the database for the specified channel
sub mbQuoteAdd {
	my ($self, $message, $iMatchingUserId, $sMatchingUserHandle, $sNick, $sChannel, @tArgs) = @_;

	# Require at least one argument
	unless (defined($tArgs[0]) && $tArgs[0] ne "") {
		botNotice($self, $sNick, "q [add or a] text1 | text2 | ... | textn");
		return;
	}

	my $sQuoteText = join(" ", @tArgs);

	# Check for existing quote on this channel
	my $sQuery = "SELECT * FROM QUOTES, CHANNEL WHERE CHANNEL.id_channel = QUOTES.id_channel AND name = ? AND quotetext LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel, $sQuoteText)) {
		$self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
		return;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $id_quotes = $ref->{'id_quotes'};
		botPrivmsg($self, $sChannel, "Quote (id: $id_quotes) already exists");
		logBot($self, $message, $sChannel, "q", @tArgs);
		$sth->finish;
		return;
	}
	$sth->finish;

	# Get channel object
	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined($channel_obj)) {
		botNotice($self, $sNick, "Channel $sChannel is not registered to me");
		return;
	}

	my $id_channel = $channel_obj->get_id;

	# Insert quote
	$sQuery = "INSERT INTO QUOTES (id_channel, id_user, quotetext) VALUES (?, ?, ?)";
	$sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel, ($iMatchingUserId && $iMatchingUserId =~ /^\d+$/ ? $iMatchingUserId : 0), $sQuoteText)) {
		$self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
	} else {
		my $id_inserted = String::IRC->new($sth->{mysql_insertid})->bold;
		my $prefix = defined($sMatchingUserHandle) ? "($sMatchingUserHandle) " : "";
		botPrivmsg($self, $sChannel, "$prefix" . "done. (id: $id_inserted)");
		logBot($self, $message, $sChannel, "q add", @tArgs);
	}
	$sth->finish;
}


sub mbQuoteDel(@) {
	my ($self,$message,$sMatchingUserHandle,$sNick,$sChannel,@tArgs) = @_;
	my $id_quotes = $tArgs[0];
	unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($id_quotes =~ /[0-9]+/)) {
		botNotice($self,$sNick,"q [del or q] id");
	}
	else {
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? AND id_quotes=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$id_quotes)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				$sQuery = "DELETE FROM QUOTES WHERE id_quotes=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_quotes)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $id_removed = String::IRC->new($id_quotes)->bold;
					botPrivmsg($self,$sChannel,"($sMatchingUserHandle) done. (id: $id_removed)");
					logBot($self,$message,$sChannel,"q del",@tArgs);
				}
			}
			else {
				botPrivmsg($self,$sChannel,"Quote (id : $id_quotes) does not exist for channel $sChannel");
			}
		}
		$sth->finish;
	}
}

sub mbQuoteView(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $id_quotes = $tArgs[0];
	unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($id_quotes =~ /[0-9]+/)) {
		botNotice($self,$sNick,"q [view or v] id");
	}
	else {
		my $sQuery =
			"SELECT QUOTES.*,CHANNEL.*,USER.nickname AS user_nickname ".
			"FROM QUOTES ".
			"JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel ".
			"LEFT JOIN USER ON USER.id_user = QUOTES.id_user ".
			"WHERE CHANNEL.name LIKE ? AND QUOTES.id_quotes = ?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$id_quotes)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $id_quotes  = $ref->{'id_quotes'};
				my $sQuoteText = $ref->{'quotetext'};
				my $id_user    = $ref->{'id_user'};

				# 1) handle depuis la jointure USER
				my $sUserhandle = $ref->{'user_nickname'};

				# 2) sinon on tente l'ancien getUserhandle()
				if (!defined($sUserhandle) || $sUserhandle eq "") {
					$sUserhandle = getUserhandle($self,$id_user);
				}

				# 3) fallback final
				$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");

				my $id_q = String::IRC->new($id_quotes)->bold;
				botPrivmsg($self,$sChannel,"($sUserhandle) [id: $id_q] $sQuoteText");
				logBot($self,$message,$sChannel,"q view",@tArgs);
			}
			else {
				botPrivmsg($self,$sChannel,"Quote (id : $id_quotes) does not exist for channel $sChannel");
			}
		}
		$sth->finish;
	}
}
                
sub mbQuoteSearch(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"q [search or s] text");
	}
	else {
		my $MAXQUOTES = 50;
		my $sQuoteText = join(" ",@tArgs);
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $i = 0;
			my $sQuotesIdFound;
			my $sLastQuote;
			my $ref;
			my $id_quotes;
			my $id_user;
			my $ts;
			while ($ref = $sth->fetchrow_hashref()) {
				my $sQuote = $ref->{'quotetext'};
				if ( $sQuote =~ /$sQuoteText/i ) {
					$id_quotes = $ref->{'id_quotes'};
					$id_user = $ref->{'id_user'};
					$ts = $ref->{'ts'};
					if ( $i == 0) {
						$sQuotesIdFound .= "$id_quotes";
					}
					else {
						$sQuotesIdFound .= "|$id_quotes";
					}
					$sLastQuote = $sQuote;
					$i++;
				}
			}
			if ( $i == 0) {
				botPrivmsg($self,$sChannel,"No quote found matching \"$sQuoteText\" on $sChannel");
			}
			elsif ( $i <= $MAXQUOTES ) {
					botPrivmsg($self,$sChannel,"$i quote(s) matching \"$sQuoteText\" on $sChannel : $sQuotesIdFound");
					my $id_q = String::IRC->new($id_quotes)->bold;
					my $sUserHandle = getUserhandle($self,$id_user);
					$sUserHandle = ((defined($sUserHandle) && ($sUserHandle ne "")) ? $sUserHandle : "Unknown");
					botPrivmsg($self,$sChannel,"Last on $ts by $sUserHandle (id : $id_q) $sLastQuote");
			}
			else {
					botPrivmsg($self,$sChannel,"More than $MAXQUOTES quotes matching \"$sQuoteText\" found on $sChannel, please be more specific :)");
			}
			logBot($self,$message,$sChannel,"q search",@tArgs);
		}
		$sth->finish;
	}
}

sub mbQuoteRand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER BY RAND() LIMIT 1";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_quotes = $ref->{'id_quotes'};
			my $sQuoteText = $ref->{'quotetext'};
			my $id_user = $ref->{'id_user'};
			my $sUserhandle = getUserhandle($self,$id_user);
			$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");
			my $id_q = String::IRC->new($id_quotes)->bold;
			botPrivmsg($self,$sChannel,"($sUserhandle) [id: $id_q] $sQuoteText");
		}
		else {
			botPrivmsg($self,$sChannel,"Quote database is empty for $sChannel");
		}
		logBot($self,$message,$sChannel,"q random",@tArgs);
	}
	$sth->finish;
}

sub mbQuoteStats(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT count(*) as nbQuotes FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $nbQuotes = $ref->{'nbQuotes'};
			if ( $nbQuotes == 0) {
				botPrivmsg($self,$sChannel,"Quote database is empty for $sChannel");
			}
			else {
				$sQuery = "SELECT UNIX_TIMESTAMP(ts) as minDate FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER by ts LIMIT 1";
				$sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $minDate = $ref->{'minDate'};
						$sQuery = "SELECT UNIX_TIMESTAMP(ts) as maxDate FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER by ts DESC LIMIT 1";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $maxDate = $ref->{'maxDate'};
								my $d = time() - $minDate;
								my @int = (
								    [ 'second', 1                ],
								    [ 'minute', 60               ],
								    [ 'hour',   60*60            ],
								    [ 'day',    60*60*24         ],
								    [ 'week',   60*60*24*7       ],
								    [ 'month',  60*60*24*30.5    ],
								    [ 'year',   60*60*24*30.5*12 ]
								);
								my $i = $#int;
								my @r;
								while ( ($i>=0) && ($d) )
								{
								    if ($d / $int[$i] -> [1] >= 1)
								    {
								        push @r, sprintf "%d %s%s",
								                     $d / $int[$i] -> [1],
								                     $int[$i]->[0],
								                     ( sprintf "%d", $d / $int[$i] -> [1] ) > 1
								                         ? 's'
								                         : '';
								    }
								    $d %= $int[$i] -> [1];
								    $i--;
								}
								my $minTimeAgo = join ", ", @r if @r;
								@r = ();
								$d = time() - $maxDate;
								$i = $#int;
								while ( ($i>=0) && ($d) )
								{
								    if ($d / $int[$i] -> [1] >= 1)
								    {
								        push @r, sprintf "%d %s%s",
								                     $d / $int[$i] -> [1],
								                     $int[$i]->[0],
								                     ( sprintf "%d", $d / $int[$i] -> [1] ) > 1
								                         ? 's'
								                         : '';
								    }
								    $d %= $int[$i] -> [1];
								    $i--;
								}
								my $maxTimeAgo = join ", ", @r if @r;
								botPrivmsg($self,$sChannel,"Quotes : $nbQuotes for channel $sChannel -- first : $minTimeAgo ago -- last : $maxTimeAgo ago");
								logBot($self,$message,$sChannel,"q stats",@tArgs);
							}
						}
					}
				}
			}
		}
	}
	$sth->finish;
}

# Modify a user's global level, autologin status, or fortniteid (Context version)
sub mbModUser_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;        # caller IRC nick
    my $channel = $ctx->channel;     # may be undef (private)
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------------------------
    # Resolve caller user object (Context first, then legacy)
    # ---------------------------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };

    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    my $uid        = eval { $user->id };
    my $level      = eval { $user->level };
    my $level_desc = eval { $user->level_description } || $level || 'unknown';
    my $auth       = eval { $user->is_authenticated } ? 1 : 0;
    my $handle     = eval { $user->nickname } || $nick;

    # ---------------------------------------------------------
    # Must be authenticated
    # ---------------------------------------------------------
    unless ($auth) {
        my $pfx = ($message && $message->can('prefix')) ? $message->prefix : $nick;
        noticeConsoleChan($self, "$pfx moduser attempt (user $handle not logged in)");
        botNotice($self, $nick, "You must be logged in to use this command.");
        return;
    }

    # ---------------------------------------------------------
    # Master-only command
    # ---------------------------------------------------------
    unless (defined $level && checkUserLevel($self, $level, "Master")) {
        my $pfx = ($message && $message->can('prefix')) ? $message->prefix : $nick;
        noticeConsoleChan($self, "$pfx moduser attempt (required: Master; current: $level_desc)");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---------------------------------------------------------
    # Arguments dispatch
    # moduser <user> level <Owner|Master|Administrator|User> [force]
    # moduser <user> autologin <on|off>
    # moduser <user> fortniteid <id>
    # ---------------------------------------------------------
    unless (@args) {
        _sendModUserSyntax($self, $nick);
        return;
    }

    my $target_nick = shift @args;
    my $target_uid  = getIdUser($self, $target_nick);

    unless ($target_uid) {
        botNotice($self, $nick, "User: $target_nick does not exist");
        return;
    }

    unless (@args) {
        _sendModUserSyntax($self, $nick);
        return;
    }

    my $subcmd = shift @args;
    my @original_args_for_log = ($target_nick, $subcmd, @args);

    # =========================================================
    # LEVEL MODIFICATION
    # =========================================================
    if ($subcmd =~ /^level$/i) {

        my $target_level_str = lc($args[0] // '');
        unless ($target_level_str =~ /^(owner|master|administrator|user)$/) {
            botNotice($self, $nick, "moduser $target_nick level <Owner|Master|Administrator|User>");
            return;
        }

        my $target_level   = getLevel($self, $target_level_str);
        my $current_level  = getLevelUser($self, $target_nick);

        # Safety: avoid accidental ownership transfer
        if ($target_level == 0 && $level == 0 && (!defined($args[1]) || $args[1] !~ /^force$/i)) {
            botNotice($self, $nick, "Do you really want to do that?");
            botNotice($self, $nick, "If you know what you're doing: moduser $target_nick level Owner force");
            return;
        }

        # Only allow if caller has strictly higher privileges (numeric "lower") than both
        if ($level < $current_level && $level < $target_level) {
            if ($target_level == $current_level) {
                botNotice($self, $nick, "User $target_nick is already a global $target_level_str.");
            } else {
                if (setUserLevel($self, $target_nick, getIdUserLevel($self, $target_level_str))) {
                    botNotice($self, $nick, "User $target_nick is now a global $target_level_str.");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                } else {
                    botNotice($self, $nick, "Could not set $target_nick as global $target_level_str.");
                }
            }
        } else {
            my $target_desc = getUserLevelDesc($self, $current_level);
            if ($target_level == $current_level) {
                botNotice($self, $nick, "You can't set $target_nick to $target_level_str: they're already $target_desc.");
            } else {
                botNotice($self, $nick, "You can't set $target_nick ($target_desc) to $target_level_str.");
            }
        }
        return;
    }

    # =========================================================
    # AUTOLOGIN
    # =========================================================
    elsif ($subcmd =~ /^autologin$/i) {
        my $arg = lc($args[0] // '');
        unless ($arg =~ /^(on|off)$/) {
            botNotice($self, $nick, "moduser $target_nick autologin <on|off>");
            return;
        }

        my $sth;

        if ($arg eq 'on') {
            $sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
            $sth->execute($target_nick);

            if ($sth->fetchrow_hashref()) {
                botNotice($self, $nick, "Autologin is already ON for $target_nick");
            } else {
                $sth = $self->{dbh}->prepare("UPDATE USER SET username = '#AUTOLOGIN#' WHERE nickname = ?");
                if ($sth->execute($target_nick)) {
                    botNotice($self, $nick, "Set autologin ON for $target_nick");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                }
            }
        } else {    # off
            $sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
            $sth->execute($target_nick);

            if ($sth->fetchrow_hashref()) {
                $sth = $self->{dbh}->prepare("UPDATE USER SET username = NULL WHERE nickname = ?");
                if ($sth->execute($target_nick)) {
                    botNotice($self, $nick, "Set autologin OFF for $target_nick");
                    logBot($self, $message, $channel, "moduser", @original_args_for_log);
                }
            } else {
                botNotice($self, $nick, "Autologin is already OFF for $target_nick");
            }
        }

        $sth->finish if $sth;
        return;
    }

    # =========================================================
    # FORTNITEID
    # =========================================================
    elsif ($subcmd =~ /^fortniteid$/i) {
        my $fortniteid = $args[0] // '';
        unless ($fortniteid ne '') {
            botNotice($self, $nick, "moduser $target_nick fortniteid <id>");
            return;
        }

        my $sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND fortniteid = ?");
        $sth->execute($target_nick, $fortniteid);

        if ($sth->fetchrow_hashref()) {
            botNotice($self, $nick, "fortniteid is already $fortniteid for $target_nick");
        } else {
            $sth = $self->{dbh}->prepare("UPDATE USER SET fortniteid = ? WHERE nickname = ?");
            if ($sth->execute($fortniteid, $target_nick)) {
                botNotice($self, $nick, "Set fortniteid $fortniteid for $target_nick");
                logBot($self, $message, $channel, "fortniteid", @original_args_for_log);
            }
        }

        $sth->finish;
        return;
    }

    # =========================================================
    # Unknown subcommand
    # =========================================================
    else {
        botNotice($self, $nick, "Unknown moduser command: $subcmd");
        return;
    }
}

# Helper: print moduser usage
sub _sendModUserSyntax {
    my ($self, $sNick) = @_;
    botNotice($self, $sNick, "moduser <user> level <Owner|Master|Administrator|User>");
    botNotice($self, $sNick, "moduser <user> autologin <on|off>");
    botNotice($self, $sNick, "moduser <user> fortniteid <id>");
}



sub setUserLevel(@) {
	my ($self,$sUser,$id_user_level) = @_;
	my $sQuery = "UPDATE USER SET id_user_level=? WHERE nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user_level,$sUser)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		return 0;
	}
	else {
		return 1;
	}
}

# Set the anti-flood parameters for a channel
sub setChannelAntiFlood {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		botNotice($self, $sNick, "Channel $sChannel is not registered to me");
		return;
	}

	my $id_channel = $channel_obj->get_id;

	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		$sth->finish;
		return;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $nbmsg_max = $ref->{'nbmsg_max'};
		my $duration  = $ref->{'duration'};
		my $timetowait = $ref->{'timetowait'};

		$self->{logger}->log(3, "setChannelAntiFlood() AntiFlood record exists (id_channel $id_channel) nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds");
		botNotice($self, $sNick, "Chanset parameters already exist and will be used for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");

	} else {
		$sQuery = "INSERT INTO CHANNEL_FLOOD (id_channel) VALUES (?)";
		$sth = $self->{dbh}->prepare($sQuery);

		unless ($sth->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			$sth->finish;
			return;
		}

		my $id_channel_flood = $sth->{mysql_insertid};
		$self->{logger}->log(3, "setChannelAntiFlood() AntiFlood record created, id_channel_flood : $id_channel_flood");

		$sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
		my $sth2 = $self->{dbh}->prepare($sQuery);

		unless ($sth2->execute($id_channel)) {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		} elsif (my $ref = $sth2->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $duration  = $ref->{'duration'};
			my $timetowait = $ref->{'timetowait'};

			botNotice($self, $sNick, "Chanset parameters for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
		} else {
			botNotice($self, $sNick, "Something funky happened, could not find record id_channel_flood : $id_channel_flood in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
		}

		$sth2->finish;
	}

	$sth->finish;
}

# Check the anti-flood status for a channel
sub checkAntiFlood {
	my ($self, $sChannel) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "checkAntiFlood() unknown channel: $sChannel");
		return 0;
	}

	my $id_channel = $channel_obj->get_id;
	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		$sth->finish;
		return 0;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $nbmsg       = $ref->{'nbmsg'};
		my $nbmsg_max   = $ref->{'nbmsg_max'};
		my $duration    = $ref->{'duration'};
		my $first       = $ref->{'first'};
		my $latest      = $ref->{'latest'};
		my $timetowait  = $ref->{'timetowait'};
		my $notification = $ref->{'notification'};
		my $currentTs   = time;

		my $deltaDb = ($latest - $first);
		my $delta   = ($currentTs - $first);

		if ($nbmsg == 0) {
			$nbmsg++;
			$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=? WHERE id_channel=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($nbmsg, $currentTs, $currentTs, $id_channel)) {
				$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			} else {
				my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
				$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
				return 0;
			}
		} else {
			if ($deltaDb <= $duration) {
				if ($nbmsg < $nbmsg_max) {
					$nbmsg++;
					$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, latest=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($nbmsg, $currentTs, $id_channel)) {
						$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
					} else {
						my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
						$self->{logger}->log(4, "checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max set latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds");
						return 0;
					}
				} else {
					my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
					my $endTs = $latest + $timetowait;

					if ($currentTs > $endTs) {
						$nbmsg = 1;
						$self->{logger}->log(0, "checkAntiFlood() End of antiflood for channel $sChannel");
						$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=?, notification=? WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($nbmsg, $currentTs, $currentTs, 0, $id_channel)) {
							$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
						} else {
							my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
							$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
							return 0;
						}
					} else {
						if (!$notification) {
							$sQuery = "UPDATE CHANNEL_FLOOD SET notification=? WHERE id_channel=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute(1, $id_channel)) {
								$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
							} else {
								$self->{logger}->log(4, "checkAntiFlood() Antiflood notification set to DB for $sChannel");
								noticeConsoleChan($self, "Anti flood activated on channel $sChannel $nbmsg messages in less than $duration seconds, waiting $timetowait seconds to deactivate");
							}
						}
						$self->{logger}->log(4, "checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds endTs = $endTs " . ($endTs - $currentTs) . " seconds left");
						$self->{logger}->log(0, "checkAntiFlood() Antiflood is active for channel $sChannel wait " . ($endTs - $currentTs) . " seconds");
						return 1;
					}
				}
			} else {
				$nbmsg = 1;
				$self->{logger}->log(0, "checkAntiFlood() End of antiflood for channel $sChannel");
				$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=?, notification=? WHERE id_channel=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($nbmsg, $currentTs, $currentTs, 0, $id_channel)) {
					$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
				} else {
					my $sLatest = strftime("%Y-%m-%d %H-%M-%S", localtime($currentTs));
					$self->{logger}->log(4, "checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
					return 0;
				}
			}
		}
	} else {
		$self->{logger}->log(0, "checkAntiFlood() could not find record in CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
	}

	$sth->finish;
	return 0;
}

# Set or display anti-flood parameters for a given channel (Context version)
sub setChannelAntiFloodParams_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;        # caller IRC nick
    my $channel = $ctx->channel;     # may be undef in private
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------------------------
    # Resolve user from Context (preferred) or legacy helper
    # ---------------------------------------------------------
    my $user = $ctx->user || eval { $self->get_user_from_message($message) };

    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    my $auth       = eval { $user->is_authenticated } ? 1 : 0;
    my $level      = eval { $user->level };
    my $handle     = eval { $user->nickname } || $nick;
    my $level_desc = eval { $user->level_description } || ($level // '?');

    # ---------------------------------------------------------
    # Must be authenticated
    # ---------------------------------------------------------
    unless ($auth) {
        my $pfx = ($message && $message->can('prefix')) ? $message->prefix : $nick;
        noticeConsoleChan($self, "$pfx antifloodset attempt (user $handle not logged in)");
        botNotice($self, $nick,
            "You must be logged in to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
        );
        return;
    }

    # ---------------------------------------------------------
    # Master only (same behavior as original checkUserLevel)
    # ---------------------------------------------------------
    unless (defined $level && checkUserLevel($self, $level, "Master")) {
        my $pfx = ($message && $message->can('prefix')) ? $message->prefix : $nick;
        noticeConsoleChan(
            $self,
            "$pfx antifloodset attempt (required: Master, user: $handle [$level_desc])"
        );
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---------------------------------------------------------
    # Resolve target channel
    # - If first argument is a #channel, use it
    # - Else fallback to context channel
    # ---------------------------------------------------------
    my $target_channel = undef;

    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_channel = shift @args;
    } else {
        my $cc = $channel // '';
        $target_channel = ($cc =~ /^#/) ? $cc : undef;
    }

    unless ($target_channel) {
        botNotice($self, $nick, "Undefined channel.");
        botNotice($self, $nick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
        return;
    }

    # ---------------------------------------------------------
    # Resolve channel object from in-memory map
    # ---------------------------------------------------------
    my $channel_obj = $self->{channels}{$target_channel}
                   || $self->{channels}{lc $target_channel};

    unless ($channel_obj) {
        botNotice($self, $nick, "Channel $target_channel is not registered.");
        return;
    }

    my $id_channel = eval { $channel_obj->get_id } || 0;
    unless ($id_channel) {
        botNotice($self, $nick, "Channel $target_channel is not registered.");
        return;
    }

    # ---------------------------------------------------------
    # If no args: display current antiflood parameters
    # ---------------------------------------------------------
    if (@args == 0) {
        $self->{logger}->log(3, "Fetching antiflood settings for $target_channel");

        my $sql = q{
            SELECT CHANNEL_FLOOD.nbmsg_max,
                   CHANNEL_FLOOD.duration,
                   CHANNEL_FLOOD.timetowait
            FROM CHANNEL
            JOIN CHANNEL_FLOOD ON CHANNEL.id_channel = CHANNEL_FLOOD.id_channel
            WHERE CHANNEL.name LIKE ?
        };

        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute($target_channel)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr");
            return;
        }

        if (my $row = $sth->fetchrow_hashref()) {
            my $max    = $row->{nbmsg_max}  // 0;
            my $period = $row->{duration}   // 0;
            my $wait   = $row->{timetowait} // 0;

            my $msg = "antifloodset for $target_channel: "
                    . "$max message"  . ($max    == 1 ? "" : "s")
                    . " max in $period second" . ($period == 1 ? "" : "s")
                    . ", wait $wait second"    . ($wait   == 1 ? "" : "s")
                    . " if breached";

            botNotice($self, $nick, $msg);
        } else {
            botNotice($self, $nick, "No antiflood settings found for $target_channel");
        }

        $sth->finish if $sth;
        return 0;
    }

    # ---------------------------------------------------------
    # We expect 3 numeric arguments: <max_msg> <period_sec> <wait_sec>
    # ---------------------------------------------------------
    for my $i (0..2) {
        unless (defined($args[$i]) && $args[$i] =~ /^\d+$/) {
            botNotice($self, $nick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
            return;
        }
    }

    my ($max_msg, $period_sec, $wait_sec) = @args[0..2];

    # ---------------------------------------------------------
    # Check that AntiFlood is enabled via chanset
    # ---------------------------------------------------------
    my $id_chanset    = getIdChansetList($self, "AntiFlood");
    my $id_channelset = $id_chanset ? getIdChannelSet($self, $target_channel, $id_chanset) : undef;

    unless ($id_chanset && $id_channelset) {
        botNotice($self, $nick, "You must enable AntiFlood first: chanset $target_channel +AntiFlood");
        return;
    }

    # ---------------------------------------------------------
    # Update CHANNEL_FLOOD values for this channel
    # ---------------------------------------------------------
    my $sql_update = q{
        UPDATE CHANNEL_FLOOD
        SET nbmsg_max = ?, duration = ?, timetowait = ?
        WHERE id_channel = ?
    };

    my $sth = $self->{dbh}->prepare($sql_update);
    unless ($sth) {
        $self->{logger}->log(1, "SQL Error (prepare): $DBI::errstr");
        return;
    }

    if ($sth->execute($max_msg, $period_sec, $wait_sec, $id_channel)) {
        $sth->finish;
        botNotice(
            $self,
            $nick,
            "Antiflood parameters set for $target_channel: "
              . "$max_msg messages max in $period_sec sec, wait $wait_sec sec"
        );
        return 0;
    } else {
        $self->{logger}->log(1, "SQL Error (execute): $DBI::errstr");
        $sth->finish;
        return;
    }
}

# Get the owner of a channel
sub getChannelOwner {
	my ($self, $sChannel) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "getChannelOwner() unknown channel: $sChannel");
		return undef;
	}

	my $id_channel = $channel_obj->get_id;

	my $sQuery = "SELECT nickname FROM USER,USER_CHANNEL WHERE USER.id_user = USER_CHANNEL.id_user AND id_channel = ? AND USER_CHANNEL.level = 500";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		return undef;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		return $ref->{nickname};
	}

	return undef;
}

# Convert a string to leet-speak.
# Backward compatible: leet($self, "text") or leet("text")
sub leet {
    my ($maybe_self, @rest) = @_;

    # If called as leet($self, "text"), $maybe_self is the bot object.
    # Build the input string from everything after the first arg.
    my $input;
    if (@rest) {
        $input = join(' ', @rest);
    } else {
        $input = $maybe_self // '';
    }

    Encode::_utf8_on($input);

    my @english = (
        "ph", "i", "I", "l", "a", "e", "s", "S",
        "A", "o", "O", "t", "y", "H", "W", "M",
        "D", "V", "x",
    );
    my @leet = (
        "f",  "1", "1", "|", "4", "3", "5", "Z",
        "4", "0", "0", "7", "Y", "|-|", "\\/\\/", "|\\/|",
        "|)", "\\/", "><",
    );

    for my $i (0 .. $#english) {
        my $c = $english[$i];
        my $l = $leet[$i];
        # Use \Q...\E to avoid regex side-effects
        $input =~ s/\Q$c\E/$l/g;
    }

    return $input;
}

# /leet <string>
# Convert the given string to leet-speak and display it.
sub displayLeetString_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Require a non-empty argument
    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: leet <string>");
        return;
    }

    my $raw_text = join(' ', @args);

    # Safety: avoid flooding if someone pastes a book
    my $max_len = 300;
    if (length($raw_text) > $max_len) {
        $raw_text = substr($raw_text, 0, $max_len) . '...';
    }

    my $leet_text = leet($self, $raw_text);

    my $prefix = "l33t($nick) : ";

    if (defined $channel && $channel ne '') {
        # Called from a channel -> reply in channel
        botPrivmsg($self, $channel, $prefix . $leet_text);
    } else {
        # Called in private -> reply by notice
        botNotice($self, $nick, $prefix . $leet_text);
    }

    return 1;
}

# Reload the bot configuration file (rehash), restricted to Master-level users.
# Context-based version.
sub mbRehash_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $prefix = eval { $message->prefix } // '';
    my $user   = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user) {
        noticeConsoleChan($self, "$prefix rehash: no user object from ctx->user/get_user_from_message()");
        botNotice($self, $nick, "Internal error: no user object");
        return;
    }

    # Safe getters from user object
    my $uid    = eval { $user->id }                  // eval { $user->{id_user} }          // 0;
    my $unick  = eval { $user->nickname }           // eval { $user->{nickname} }         // $nick;
    my $auth   = eval { $user->auth }               // eval { $user->{auth} }             // 0;
    my $lvlid  = eval { $user->level }              // eval { $user->{level} }            // undef;
    my $lvldes = eval { $user->level_description }  // eval { $user->{level_desc} }       // 'unknown';

    # Debug snapshot
    noticeConsoleChan($self, "$prefix AUTH[rehash-enter] uid=$uid nick=$unick auth=$auth level=$lvldes");

    # If not authenticated, attempt autologin when eligible (#AUTOLOGIN# + matching hostmask)
    if (!$auth) {
        my ($username, $masks) = ('', '');
        eval {
            my $sth = $self->{dbh}->prepare("SELECT username, hostmasks FROM USER WHERE id_user=?");
            $sth->execute($uid);
            ($username, $masks) = $sth->fetchrow_array;
            $sth->finish;
        };

        noticeConsoleChan(
            $self,
            "$prefix rehash: auth=0; username='" . ($username // '') . "'; masks='" . ($masks // '') . "'"
        );

        # Extract "ident@host" from prefix (nick!ident@host)
        my $userhost = $prefix;
        $userhost =~ s/^.*?!(.+)$/$1/;

        my $matched_mask;
        for my $mask (
            grep { length }
            map  { my $x = $_; $x =~ s/^\s+|\s+$//g; $x }
            split /,/, ($masks // '')
        ) {
            my $re = do {
                my $q = quotemeta($mask);
                $q =~ s/\\\*/.*/g;   # '*' -> .*
                $q =~ s/\\\?/./g;    # '?' -> .
                qr/^$q$/i;
            };
            if ($userhost =~ $re) {
                $matched_mask = $mask;
                last;
            }
        }

        noticeConsoleChan(
            $self,
            "$prefix rehash: autologin mask check => " . ($matched_mask ? "matched '$matched_mask'" : "no mask matched")
        );

        # If we are eligible for autologin, try to use Mediabot::Auth
        if (defined $username && $username eq '#AUTOLOGIN#' && $matched_mask) {
            my ($ok, $reason) = eval { $self->{auth}->maybe_autologin($user, $prefix) };
            $ok     //= 0;
            $reason //= ($@ ? "exception: $@" : "unknown");

            noticeConsoleChan($self, "$prefix rehash: maybe_autologin => " . ($ok ? 'OK' : 'NO') . " ($reason)");

            if ($ok) {
                # Refresh user object after autologin
                $user   = $ctx->user // eval { $self->get_user_from_message($message) } || $user;
                $auth   = eval { $user->auth }               // eval { $user->{auth} }             // $auth;
                $lvlid  = eval { $user->level }              // eval { $user->{level} }            // $lvlid;
                $lvldes = eval { $user->level_description }  // eval { $user->{level_desc} }       // $lvldes;

                noticeConsoleChan($self, "$prefix rehash: after autologin => auth=$auth level=$lvldes");
            }
        } else {
            noticeConsoleChan(
                $self,
                "$prefix rehash: autologin not eligible (username!='#AUTOLOGIN#' or mask not matched)"
            );
        }
    }

    # Still not authenticated? Deny.
    unless ($auth) {
        my $msg = "$prefix rehash command attempt (user $unick is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged in to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login <username> <password>"
        );
        return;
    }

    # Check level (Master+)
    unless (checkUserLevel($self, $lvlid, "Master")) {
        my $msg = "$prefix rehash command attempt (command level [Master] for user $unick [$lvldes])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Reload configuration file
    readConfigFile($self);

    # Notify caller
    if (defined $channel && $channel ne '') {
        botPrivmsg($self, $channel, "($nick) Successfully rehashed");
    } else {
        botNotice($self, $nick, "Successfully rehashed");
    }

    # Log action
    logBot($self, $message, $channel, "rehash", @args);

    return 1;
}

# Play a radio request
sub playRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $incomingDir = $self->{conf}->get('radio.YOUTUBEDL_INCOMING');
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					$self->{logger}->log(3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					unless (defined($sChannel) && ($sChannel ne "")) {
						botPrivmsg($self,$sChannel,"($sNick radio play) Cannot queue requests while radio is live");
					}
					else {
						botNotice($self,$sNick,"($sNick radio play) Cannot queue requests while radio is live");
					}
					return undef;
				}
				my $sYoutubeId;
				unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					botNotice($self,$sNick,"Syntax : play id <ID>|ytid <YTID>|<searchstring>");
				}
				else {
					my $sText = $tArgs[0];
					if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/music\.youtube\..*\/watch.*v=/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*watch.*v=//;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
						$sYoutubeId = $sText;
						$sYoutubeId =~ s/^.*youtu\.be\///;
						$sYoutubeId = substr($sYoutubeId,0,11);
					}
					if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
						my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
						my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
						unless (defined($sMsgSong)) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
							}
							else {
								botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
							}
							return undef;
						}
						else {
							unless ($sDurationSeconds < (12 * 60)) {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
								}
								return undef;
							}
							unless ( -d $incomingDir ) {
								$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
								return undef;
							}
							else {
								chdir $incomingDir;
							}
							my $ytDestinationFile;
							my $sQuery = "SELECT id_mp3,folder,filename FROM MP3 WHERE id_youtube=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							my $id_mp3;
							unless ($sth->execute($sYoutubeId)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									$id_mp3 = $ref->{'id_mp3'};
									$ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								}
							}
							if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : ID : $sYoutubeId (cached) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Library ID : ID : $sYoutubeId (cached) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
									}
									logBot($self,$message,$sChannel,"play",$sText);
								}
								else {
									$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
								}
								my $timer = IO::Async::Timer::Countdown->new(
							   	delay => 3,
							   	on_expire => sub {
										$self->{logger}->log(3,"Timer start, downloading $ytUrl");
										#/usr/local/bin/yt-dlp -x --audio-format mp3 --audio-quality 0 https://www.youtube.com/watch?v=JRDgihVDEko
										unless ( open YT, "/usr/local/bin/yt-dlp -x --audio-format mp3 --audio-quality 0 $ytUrl |" ) {
				                    		$self->{logger}->log(0,"Could not yt-dlp $ytUrl");
				                    		return undef;
				            			}
				            			my $ytdlOuput;
				            
										while (defined($ytdlOuput=<YT>)) {
												chomp($ytdlOuput);
												if ( $ytdlOuput =~ /^\[ExtractAudio\] Destination: (.*)$/ ) {
													$ytDestinationFile = $1;
													$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
													
												}
												$self->{logger}->log(3,"$ytdlOuput");
										}
										if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
											my $filename = $ytDestinationFile;
											my $folder = $incomingDir;
											my $id_youtube = substr($filename,-15);
											$id_youtube = substr($id_youtube,0,11);

											my $mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
											$mp3->get_tags;
											my ($title, $track, $artist, $album, $comment, $year, $genre) = $mp3->autoinfo();
											$mp3->close;
											if ($title eq $id_youtube) {
												$title = "";
											}
											print 
											my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
											my $sth = $self->{dbh}->prepare($sQuery);
											my $id_mp3 = 0;
											unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
												$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
											}
											else {
												$id_mp3 = $sth->{ mysql_insertid };
												$self->{logger}->log(3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
											}
											$sth->finish;
											my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
											if (defined($rPush) && $rPush) {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $sYoutubeId (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
												}
												else {
													botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $sYoutubeId (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
												}
												logBot($self,$message,$sChannel,"play",$sText);
											}
											else {
												$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
												}
												else {
													botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
												}
												return undef;
											}
										}
										},
								);
								$self->{loop}->add( $timer );
								$timer->start;

							}
						}
					}
					else {
						if (defined($tArgs[0]) && ($tArgs[0] =~ /^id$/) && defined($tArgs[1]) && ($tArgs[1] =~ /^[0-9]+$/)) {
							my $sQuery = "SELECT id_youtube,artist,title,folder,filename FROM MP3 WHERE id_mp3=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									$self->{logger}->log(3,"playRadio() pushing $ytDestinationFile to queue");
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
										}
										else {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / $sMsgSong / Queued");
											}
										}
										logBot($self,$message,$sChannel,"play",$sText);
										return 1;
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
										}
										return undef;
									}
								}
								else {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play / could not find mp3 id in library : $tArgs[1]");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play / could not find mp3 id in library : $tArgs[1]");
									}
									return undef;
								}
							}
						}
						if (defined($tArgs[0]) && ($tArgs[0] =~ /^ytid$/) && defined($tArgs[1]) && ($tArgs[1] ne "")) {
							my $sQuery = "SELECT id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										}
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " Youtube ID : $sText (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) Library ID : " . $tArgs[1] . " Youtube ID : $sText (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										}
										logBot($self,$message,$sChannel,"play",$sText);
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
										}
										return undef;
									}
								}
								else {
									unless ( -d $incomingDir ) {
										$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
										return undef;
									}
									else {
										chdir $incomingDir;
									}
									my $ytUrl = "https://www.youtube.com/watch?v=" . $tArgs[1];
									my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
									unless (defined($sMsgSong)) {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
										}
										return undef;
									}
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
									}
									my $timer = IO::Async::Timer::Countdown->new(
										delay => 3,
										on_expire => sub {
												$self->{logger}->log(3,"Timer start, downloading $ytUrl");
												unless ( open YT, "youtube-dl --extract-audio --audio-format mp3 --add-metadata $ytUrl |" ) {
													$self->{logger}->log(0,"Could not youtube-dl $ytUrl");
													return undef;
												}
												my $ytdlOuput;
												my $ytDestinationFile;
												while (defined($ytdlOuput=<YT>)) {
														chomp($ytdlOuput);
														if ( $ytdlOuput =~ /^\[ffmpeg\] Destination: (.*)$/ ) {
															$ytDestinationFile = $1;
															$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
															
														}
														$self->{logger}->log(3,"$ytdlOuput");
												}
												if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
													my $filename = $ytDestinationFile;
													my $folder = $incomingDir;
													my $id_youtube = substr($filename,-15);
													$id_youtube = substr($id_youtube,0,11);
													$self->{logger}->log(3,"Destination : $incomingDir/$ytDestinationFile");
													my $mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
													$mp3->get_tags;
													my ($title, $track, $artist, $album, $comment, $year, $genre) = $mp3->autoinfo();
													$mp3->close;
													if ($title eq $id_youtube) {
														$title = "";
													}
													my $id_mp3;
													my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
													my $sth = $self->{dbh}->prepare($sQuery);
													unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
														$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
													}
													else {
														$id_mp3 = $sth->{ mysql_insertid };
														$self->{logger}->log(3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
													}
													$sth->finish;
													my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
													if (defined($rPush) && $rPush) {
														if (defined($sChannel) && ($sChannel ne "")) {
															botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
														}
														else {
															botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
														}
														logBot($self,$message,$sChannel,"play",$sText);
													}
													else {
														$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
														if (defined($sChannel) && ($sChannel ne "")) {
															botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
														}
														else {
															botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
														}
														return undef;
													}
												}
												},
										);
										$self->{loop}->add( $timer );
										$timer->start;
								}
							}
						}
						else {
							# Local library search
							my $sSearch = join (" ",@tArgs);
							my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE (artist LIKE ? OR title LIKE ?) ORDER BY RAND() LIMIT 1";
							$self->{logger}->log(3,"playRadio() Query : $sQuery");
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sSearch,$sSearch)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {	
								if (my $ref = $sth->fetchrow_hashref()) {
									my $id_mp3 = $ref->{'id_mp3'};
									my $id_youtube = $ref->{'id_youtube'};
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
											}
										}
										else {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
											}
										}
										logBot($self,$message,$sChannel,"play",@tArgs);
										return 1;
									}
									else {
										$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
										}
										else {
											botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
										}
										return undef;
									}
								}
							}
							# Youtube Search
							my $sYoutubeId;
							my $sText = join("%20",@tArgs);
							$self->{logger}->log(3,"radioplay() youtubeSearch() on $sText");
							my $APIKEY = $self->{conf}->get('main.YOUTUBE_APIKEY');
							unless (defined($APIKEY) && ($APIKEY ne "")) {
								$self->{logger}->log(0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
								$self->{logger}->log(0,"displayYoutubeDetails() section [main]");
								$self->{logger}->log(0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
								return undef;
							}
							unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\" |" ) {
								$self->{logger}->log(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
							}
							else {
								my $line;
								my $i = 0;
								my $json_details;
								while(defined($line=<YOUTUBE_INFOS>)) {
									chomp($line);
									$json_details .= $line;
									$self->{logger}->log(5,"radioplay() youtubeSearch() $line");
									$i++;
								}
								if (defined($json_details) && ($json_details ne "")) {
									$self->{logger}->log(4,"radioplay() youtubeSearch() json_details : $json_details");
									my $sYoutubeInfo = decode_json $json_details;
									my %hYoutubeInfo = %$sYoutubeInfo;
										my @tYoutubeItems = $hYoutubeInfo{'items'};
										my @fTyoutubeItems = @{$tYoutubeItems[0]};
										$self->{logger}->log(4,"radioplay() youtubeSearch() tYoutubeItems length : " . $#fTyoutubeItems);
										# Check items
										if ( $#fTyoutubeItems >= 0 ) {
											my %hYoutubeItems = %{$tYoutubeItems[0][0]};
											$self->{logger}->log(4,"radioplay() youtubeSearch() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
											my @tYoutubeId = $hYoutubeItems{'id'};
											my %hYoutubeId = %{$tYoutubeId[0]};
											$self->{logger}->log(4,"radioplay() youtubeSearch() sYoutubeInfo Id : " . Dumper(%hYoutubeId));
											$sYoutubeId = $hYoutubeId{'videoId'};
											$self->{logger}->log(4,"radioplay() youtubeSearch() sYoutubeId : $sYoutubeId");
										}
										else {
											$self->{logger}->log(3,"radioplay() youtubeSearch() Invalid id : $sYoutubeId");
										}
								}
								else {
									$self->{logger}->log(3,"radioplay() youtubeSearch() curl empty result for : curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\"");
								}
							}
							if (defined($sYoutubeId) && ($sYoutubeId ne "")) {
								my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
								my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
								unless (defined($sMsgSong)) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
									}
									return undef;
								}
								unless ($sDurationSeconds < (12 * 60)) {
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
									}
									else {
										botNotice($self,$sNick,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
									}
									return undef;
								}
								my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($sYoutubeId)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									if (my $ref = $sth->fetchrow_hashref()) {
										my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
										my $rPush = queuePushRadio($self,"$ytDestinationFile");
										if (defined($rPush) && $rPush) {
											my $id_mp3 = $ref->{'id_mp3'};
											my $id_youtube = $ref->{'id_youtube'};
											my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
											my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
											my $duration = 0;
											my $sMsgSong = "$artist - $title";
											if (defined($id_youtube) && ($id_youtube ne "")) {
												($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											}
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											}
											logBot($self,$message,$sChannel,"play",$sText);
										}
										else {
											$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
											}
											return undef;
										}
									}
									else {
										unless ( -d $incomingDir ) {
											$self->{logger}->log(0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
											return undef;
										}
										else {
											chdir $incomingDir;
										}
										my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
										my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
										unless (defined($sMsgSong)) {
											if (defined($sChannel) && ($sChannel ne "")) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
											}
											else {
												botNotice($self,$sNick,"($sNick radio play) Unknown Youtube link");
											}
											return undef;
										}
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) $sMsgSong - Please wait while downloading");
										}
										my $timer = IO::Async::Timer::Countdown->new(
											delay => 3,
											on_expire => sub {
													$self->{logger}->log(3,"Timer start, downloading $ytUrl");
													
													unless ( open YT, "youtube-dl --extract-audio --audio-format mp3 --add-metadata $ytUrl |" ) {
														$self->{logger}->log(0,"Could not youtube-dl $ytUrl");
														return undef;
													}
													my $ytdlOuput;
													my $ytDestinationFile;
													while (defined($ytdlOuput=<YT>)) {
															chomp($ytdlOuput);
															if ( $ytdlOuput =~ /^\[ffmpeg\] Destination: (.*)$/ ) {
																$ytDestinationFile = $1;
																$self->{logger}->log(0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
																
															}
															$self->{logger}->log(3,"$ytdlOuput");
													}
													if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
														my $filename = $ytDestinationFile;
														my $folder = $incomingDir;
														my $id_youtube = substr($filename,-15);
														$id_youtube = substr($id_youtube,0,11);
														$self->{logger}->log(3,"Destination : $incomingDir/$ytDestinationFile");
														my $mp3 = MP3::Tag->new("$incomingDir/$ytDestinationFile");
														$mp3->get_tags;
														my ($title, $track, $artist, $album, $comment, $year, $genre) = $mp3->autoinfo();
														$mp3->close;
														if ($title eq $id_youtube) {
															$title = "";
														}
														my $id_mp3 = 0;
														my $sQuery = "INSERT INTO MP3 (id_user,id_youtube,folder,filename,artist,title) VALUES (?,?,?,?,?,?)";
														my $sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($iMatchingUserId,$id_youtube,$folder,$filename,$artist,$title)) {
															$self->{logger}->log(1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															$id_mp3 = $sth->{ mysql_insertid };
															$self->{logger}->log(3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
														}
														$sth->finish;
														my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
														if (defined($rPush) && $rPush) {
															if (defined($sChannel) && ($sChannel ne "")) {
																botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
															}
															else {
																botNotice($self,$sNick,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
															}
															logBot($self,$message,$sChannel,"play",$sText);
														}
														else {
															$self->{logger}->log(3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");
															if (defined($sChannel) && ($sChannel ne "")) {
																botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
															}
															else {
																botNotice($self,$sNick,"($sNick radio play could not queue) Already asked ?");
															}
															return undef;
														}
													}
													},
											);
											$self->{loop}->add( $timer );
											$timer->start;
									}
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play no Youtube ID found for " . join(" ",@tArgs));
								}
								else {
									botNotice($self,$sNick,"($sNick radio play no Youtube ID found for " . join(" ",@tArgs));
								}
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " play command attempt (command level [User] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " play command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Check the number of tracks in the queue
sub queueCount(@) {
	my ($self) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 | wc -w |") {
		$self->{logger}->log(0,"queueCount() Unable to connect to LIQUIDSOAP telnet port");
		return undef;
	}
	my $line;
	if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
		chomp($line);
		$self->{logger}->log(3,$line);
	}
	return $line;
}

# Check if a track is in the queue
sub isInQueueRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my $iNbTrack = queueCount($self);
	unless ( $iNbTrack == 0 ) {
		my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
		my $line;
		if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
			unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
				return undef;
			}
			if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
				chomp($line);
				$line =~ s/\r//;
				$line =~ s/\n//;
				$self->{logger}->log(3,"isInQueueRadio() $line");
			}
			if ($iNbTrack > 0) {
				my @RIDS = split(/ /,$line);
				my $i;
				for ($i=0;$i<=$#RIDS;$i++) {
					unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
						$self->{logger}->log(0,"isInQueueRadio() Unable to connect to LIQUIDSOAP telnet port");
						return undef;
					}
					my $line;
					if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
						chomp($line);
						my $sMsgSong = "";
						$line =~ s/\r//;
						$line =~ s/\n//;
						$line =~ s/^.*\[\"//;
						$line =~ s/\".*$//;
						$self->{logger}->log(3,"isInQueueRadio() $line");
						my $sFolder = dirname($line);
						my $sFilename = basename($line);
						my $sBaseFilename = basename($sFilename, ".mp3");
						if ( $line eq $sAudioFilename) {
							return 1;
						}
					}
				}
			}
		}
		else {
			$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
		}
	}
	else {
		return 0;
	}
}

# Push a track to the radio queue
sub queueRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $iHarborId = getHarBorId($self);
				my $bHarbor = 0;
				if (defined($iHarborId) && ($iHarborId ne "")) {
					$self->{logger}->log(3,"Harbord ID : $iHarborId");
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"harbor_$iHarborId.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						my $line;
						if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							$self->{logger}->log(3,$line);
							unless ($line =~ /^no source client connected/) {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,radioMsg($self,"Live - " . getRadioCurrentSong($self)));
								}
								else {
									botNotice($self,$sNick,radioMsg($self,"Live - " . getRadioCurrentSong($self)));
								}
								$bHarbor = 1;
							}
						}
					}
					else {
						$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
					}
				}
				
				my $iNbTrack = queueCount($self);
				unless ( $iNbTrack == 0 ) {
					my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
					my $line;
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							$self->{logger}->log(3,"queueRadio() $line");
						}
						if ($iNbTrack > 0) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,radioMsg($self,"$iNbTrack $sNbTrack in queue, RID : $line"));
							}
							else {
								botNotice($self,$sNick,radioMsg($self,"$iNbTrack $sNbTrack in queue, RID : $line"));
							}
							my @RIDS = split(/ /,$line);
							my $i;
							for ($i=0;($i<3 && $i<=$#RIDS);$i++) {
								unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
									$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
									return undef;
								}
								my $line;
								if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
									chomp($line);
									my $sMsgSong = "";
									if (( $i == 0 ) && (!$bHarbor)) {
										#Remaining time
										my $sRemainingTime = getRadioRemainingTime($self);
										$self->{logger}->log(3,"queueRadio() sRemainingTime = $sRemainingTime");
										my $siSecondsRemaining = int($sRemainingTime);
										my $iMinutesRemaining = int($siSecondsRemaining / 60) ;
										my $iSecondsRemaining = int($siSecondsRemaining - ( $iMinutesRemaining * 60 ));
										$sMsgSong .= String::IRC->new(' - ')->white('black');
										my $sTimeRemaining = "";
										if ( $iMinutesRemaining > 0 ) {
											$sTimeRemaining .= $iMinutesRemaining . " mn";
											if ( $iMinutesRemaining > 1 ) {
												$sTimeRemaining .= "s";
											}
											$sTimeRemaining .= " and ";
										}
										$sTimeRemaining .= $iSecondsRemaining . " sec";
										if ( $iSecondsRemaining > 1 ) {
											$sTimeRemaining .= "s";
										}
										$sTimeRemaining .= " remaining";
										$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
									}
									$line =~ s/\r//;
									$line =~ s/\n//;
									$line =~ s/^.*\[\"//;
									$line =~ s/\".*$//;
									$self->{logger}->log(3,"queueRadio() $line");
									my $sFolder = dirname($line);
									my $sFilename = basename($line);
									my $sBaseFilename = basename($sFilename, ".mp3");
									my $sQuery = "SELECT artist,title FROM MP3 WHERE folder=? AND filename=?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($sFolder,$sFilename)) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										if (my $ref = $sth->fetchrow_hashref()) {
											my $title = $ref->{'title'};
											my $artist = $ref->{'artist'};
											if ($i == 0) {
												unless ($bHarbor) {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $artist - $title" . $sMsgSong);
													}
													else {
														botNotice($self,$sNick,"» $artist - $title" . $sMsgSong);
													}
												}
												else {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $artist - $title");
													}
													else {
														botNotice($self,$sNick,"» $artist - $title");
													}
												}
											}
											else {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"└ $artist - $title");
												}
												else {
													botNotice($self,$sNick,"└ $artist - $title");
												}
											}
										}
										else {
											if ($i == 0) {
												unless ($bHarbor) {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $sBaseFilename" . $sMsgSong);
													}
													else {
														botNotice($self,$sNick,"» $sBaseFilename" . $sMsgSong);
													}
												}
												else {
													if (defined($sChannel) && ($sChannel ne "")) {
														botPrivmsg($self,$sChannel,"» $sBaseFilename");
													}
													else {
														botNotice($self,$sNick,"» $sBaseFilename");
													}
												}
											}
											else {
												if (defined($sChannel) && ($sChannel ne "")) {
													botPrivmsg($self,$sChannel,"└ $sBaseFilename");
												}
												else {
													botNotice($self,$sNick,"└ $sBaseFilename");
												}
											}
										}
									}
									$sth->finish;
								}
							}
						}
					}
					else {
						$self->{logger}->log(0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
					}
				}
				else {
					unless ( $bHarbor ) {
						#Remaining time
						my $sRemainingTime = getRadioRemainingTime($self);
						$self->{logger}->log(3,"queueRadio() sRemainingTime = $sRemainingTime");
						my $siSecondsRemaining = int($sRemainingTime);
						my $iMinutesRemaining = int($siSecondsRemaining / 60) ;
						my $iSecondsRemaining = int($siSecondsRemaining - ( $iMinutesRemaining * 60 ));
						my $sMsgSong .= String::IRC->new(' - ')->white('black');
						my $sTimeRemaining = "";
						if ( $iMinutesRemaining > 0 ) {
							$sTimeRemaining .= $iMinutesRemaining . " mn";
							if ( $iMinutesRemaining > 1 ) {
								$sTimeRemaining .= "s";
							}
							$sTimeRemaining .= " and ";
						}
						$sTimeRemaining .= $iSecondsRemaining . " sec";
						if ( $iSecondsRemaining > 1 ) {
							$sTimeRemaining .= "s";
						}
						$sTimeRemaining .= " remaining";
						$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
						if (defined($sChannel) && ($sChannel ne "")) {
							botPrivmsg($self,$sChannel,radioMsg($self,"Global playlist - " . getRadioCurrentSong($self) . $sMsgSong));
						}
						else {
							botNotice($self,$sNick,radioMsg($self,"Global playlist - " . getRadioCurrentSong($self) . $sMsgSong));
						}
					}
				}
				logBot($self,$message,$sChannel,"queue",@tArgs);
			}
			else {
				my $sNoticeMsg = $message->prefix . " queue command attempt (command level [User] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " queue command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Push a track to the radio queue
sub queuePushRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	if (defined($sAudioFilename) && ($sAudioFilename ne "")) {
		unless (isInQueueRadio($self,$sAudioFilename)) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
				$self->{logger}->log(3,"queuePushRadio() pushing $sAudioFilename to queue");
				unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.push $sAudioFilename\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
					$self->{logger}->log(0,"queuePushRadio() Unable to connect to LIQUIDSOAP telnet port");
					return undef;
				}
				my $line;
				while (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
					chomp($line);
					$self->{logger}->log(3,$line);
				}
				return 1;
			}
			else {
				$self->{logger}->log(0,"playRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				return 0;
			}
		}
		else {
			$self->{logger}->log(3,"queuePushRadio() $sAudioFilename already in queue");
			return 0;
		}
	}
	else {
		$self->{logger}->log(3,"queuePushRadio() missing audio file parameter");
		return 0;
	}
}

# Send a next command to the radio
sub nextRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"radio(dot)mp3.skip\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
						$self->{logger}->log(0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
						return undef;
					}
					my $line;
					while (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
						chomp($line);
						$self->{logger}->log(3,$line);
					}
					logBot($self,$message,$sChannel,"next",@tArgs);
					sleep(6);
					displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
				}
				else {
					$self->{logger}->log(0,"nextRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " next command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " next command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Display the current song on the radio
sub radioMsg(@) {
	my ($self,$sText) = @_;
	my $sMsgSong = "";
	my $RADIO_HOSTNAME = $self->{conf}->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $self->{conf}->get('radio.RADIO_PORT');
	my $RADIO_URL      = $self->{conf}->get('radio.RADIO_URL');
	
	$sMsgSong .= String::IRC->new('[ ')->white('black');
	if ( $RADIO_PORT == 443 ) {
		$sMsgSong .= String::IRC->new("https://$RADIO_HOSTNAME/$RADIO_URL")->orange('black');
	}
	else {
		$sMsgSong .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
	}
	$sMsgSong .= String::IRC->new(' ] ')->white('black');
	$sMsgSong .= String::IRC->new(' - ')->white('black');
	$sMsgSong .= String::IRC->new(' [ ')->orange('black');
	$sMsgSong .= String::IRC->new($sText)->white('black');
	$sMsgSong .= String::IRC->new(' ]')->orange('black');
	return($sMsgSong);
}

# Ransomly play a track from the radio library
sub rplayRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $incomingDir = $self->{conf}->get('radio.YOUTUBEDL_INCOMING');
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');

	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					$self->{logger}->log(3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					if (defined($sChannel) && ($sChannel ne "")) {
						botPrivmsg($self,$sChannel,"($sNick radio rplay) Cannot queue requests while radio is live");
					}
					else {
						botNotice($self,$sNick,"($sNick radio rplay) Cannot queue requests while radio is live");
					}
					return undef;
				}
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					if (defined($tArgs[0]) && ($tArgs[0] eq "user") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
						my $id_user = getIdUser($self,$tArgs[1]);
						unless (defined($id_user)) {
							if (defined($sChannel) && ($sChannel ne "")) {
								botPrivmsg($self,$sChannel,"($sNick radio play) Unknown user " . $tArgs[0]);
							}
							else {
								botNotice($self,$sNick,"($sNick radio play) Unknown user " . $tArgs[0]);
							}
							return undef;
						}
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_user=? ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_user)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() user / could not queue queuePushRadio() $ytDestinationFile");	
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / user / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / user / could not queue)");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
							}
						}
						$sth->finish;
					}
					elsif (defined($tArgs[0]) && ($tArgs[0] eq "artist") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
						shift @tArgs;
						my $sText = join (" ",@tArgs);
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE artist like ? ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sText)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() artist / could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / artist / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / artist / could not queue)");
									}
									
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play user " . $tArgs[1] . " / no track found)");
								}
							}
						}
						$sth->finish;
					}
					elsif (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						my $sText = join ("%",@tArgs);
						my $sSearch = $sText;
						$sSearch =~ s/\s+/%/g;
						$sSearch =~ s/%+/%/g;
						$sSearch =~ s/;//g;
						$sSearch =~ s/'/\\'/g;
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE CONCAT(artist,title) LIKE '%" . $sSearch . "%' ORDER BY RAND() LIMIT 1";
						$self->{logger}->log(3,"rplayRadio() Query : $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
									}
									return undef;
								}
							}
							else {
								if (defined($sChannel) && ($sChannel ne "")) {
									botPrivmsg($self,$sChannel,"($sNick radio play $sText / no track found)");
								}
								else {
									botNotice($self,$sNick,"($sNick radio play $sText / no track found)");
								}
							}
						}
						$sth->finish;
					}
					else {
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_mp3 = $ref->{'id_mp3'};
								my $id_youtube = $ref->{'id_youtube'};
								my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
								my $rPush = queuePushRadio($self,$ytDestinationFile);
								if (defined($rPush) && $rPush) {
									my $id_youtube = $ref->{'id_youtube'};
									my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
									my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
									my $duration = 0;
									my $sMsgSong = "$artist - $title";
									if (defined($id_youtube) && ($id_youtube ne "")) {
										($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
									}
									else {
										if (defined($sChannel) && ($sChannel ne "")) {
											botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										else {
											botNotice($self,$sNick,"($sNick radio play) (Library ID : $id_mp3) / $artist - $title / Queued");
										}
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									$self->{logger}->log(3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");	
									if (defined($sChannel) && ($sChannel ne "")) {
										botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									}
									else {
										botNotice($self,$sNick,"($sNick radio rplay / could not queue)");
									}
									return undef;
								}
							}
						}
						$sth->finish;
					}
				}
				else {
					$self->{logger}->log(0,"rplayRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " rplay command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " rplay command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Context-based MP3 command.
# Features:
#   - mp3 count        : show total number of MP3s in local library
#   - mp3 id <id>      : show info for a specific library ID
#   - mp3 <search...>  : search by artist/title, show first match + up to 10 IDs
sub mp3_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user from context ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    # Must be authenticated
    unless ($user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        noticeConsoleChan($self, "$pfx mp3 command attempt (user $who is not logged in)");
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    # Require at least "User" level (this was already the case logically)
    my $level = eval { $user->level };
    unless (defined $level && checkUserLevel($self, $level, "User")) {
        my $who   = eval { $user->nickname } // $nick;
        my $lvl_d = eval { $user->level_description } || eval { $user->level } || '?';
        my $pfx   = eval { $message->prefix } // $who;

        noticeConsoleChan(
            $self,
            "$pfx mp3 command attempt (command level [User] for user $who [$lvl_d])"
        );
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- No arguments => syntax ---
    unless (@args) {
        botNotice($self, $nick, "Syntax: mp3 <title>");
        botNotice($self, $nick, "        mp3 count");
        botNotice($self, $nick, "        mp3 id <LibraryID>");
        return;
    }

    my $sub = lc $args[0];

    # =========================
    #  mp3 count
    # =========================
    if ($sub eq 'count') {
        my $sql = "SELECT COUNT(*) AS nbMp3 FROM MP3";
        my $sth = $self->{dbh}->prepare($sql);

        unless ($sth && $sth->execute()) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
            botPrivmsg($self, $channel, "($nick mp3 count) unexpected error") if $channel;
            return;
        }

        my $nb = 0;
        if (my $ref = $sth->fetchrow_hashref()) {
            $nb = $ref->{nbMp3} // 0;
        }
        $sth->finish;

        my $dst = $channel ? sub { botPrivmsg($self, $channel, @_) }
                           : sub { botNotice($self, $nick, @_) };

        $dst->("($nick mp3 count) $nb in local library");
        logBot($self, $message, $channel, "mp3", @args);
        return;
    }

    # =========================
    #  mp3 id <id>
    # =========================
    if ($sub eq 'id' && defined $args[1] && $args[1] =~ /^\d+$/) {
        my $id = int($args[1]);

        my $sql = "SELECT id_mp3, id_youtube, artist, title, folder, filename FROM MP3 WHERE id_mp3 = ?";
        $self->{logger}->log(3, "mp3_ctx(): $sql (id=$id)");

        my $sth = $self->{dbh}->prepare($sql);
        unless ($sth && $sth->execute($id)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
            return;
        }

        if (my $ref = $sth->fetchrow_hashref()) {
            my $id_mp3    = $ref->{id_mp3};
            my $id_yt     = $ref->{id_youtube};
            my $artist    = defined($ref->{artist}) ? $ref->{artist} : "Unknown";
            my $title     = defined($ref->{title})  ? $ref->{title}  : "Unknown";
            my $sMsgSong  = "$artist - $title";
            my $duration  = 0;

            if (defined($id_yt) && $id_yt ne "") {
                # Reuse existing helper. It may override $sMsgSong with better info.
                ($duration, $sMsgSong) = getYoutubeDetails($self, "https://www.youtube.com/watch?v=$id_yt");
                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) (Library ID : $id_mp3 YTID : $id_yt) / $sMsgSong - https://www.youtube.com/watch?v=$id_yt"
                );
            } else {
                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) First result (Library ID : $id_mp3) / $artist - $title"
                );
            }

            logBot($self, $message, $channel, "mp3", @args);
        } else {
            botPrivmsg($self, $channel, "($nick mp3 search) ID $id not found");
        }

        $sth->finish;
        return;
    }

    # =========================
    #  mp3 <search string>
    # =========================

    my $text = join(' ', @args);
    unless (defined $text && $text ne '') {
        botNotice($self, $nick, "Syntax: mp3 <title>");
        return;
    }

    # Build a LIKE pattern safely:
    #   - split on spaces
    #   - join with '%' so "foo bar" -> "%foo%bar%"
    #   - bind as param instead of interpolating raw
    my @tokens = grep { length } split(/\s+/, $text);
    my $pattern = '%' . join('%', @tokens) . '%';

    # 1) Count matching MP3s
    my $sql_count = "SELECT COUNT(*) AS nbMp3 FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ?";
    $self->{logger}->log(3, "mp3_ctx(): $sql_count (pattern=$pattern)");
    my $sth = $self->{dbh}->prepare($sql_count);

    my $nbMp3 = 0;
    unless ($sth && $sth->execute($pattern)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_count");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        $nbMp3 = $ref->{nbMp3} // 0;
    }
    $sth->finish;

    unless ($nbMp3 > 0) {
        botPrivmsg($self, $channel, "($nick mp3 search) $text not found");
        return;
    }

    # 2) Fetch first matching result
    my $sql_first = "SELECT id_mp3, id_youtube, artist, title, folder, filename FROM MP3 ".
                    "WHERE CONCAT(artist, ' ', title) LIKE ? LIMIT 1";
    $self->{logger}->log(3, "mp3_ctx(): $sql_first (pattern=$pattern)");
    $sth = $self->{dbh}->prepare($sql_first);

    unless ($sth && $sth->execute($pattern)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_first");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_mp3    = $ref->{id_mp3};
        my $id_yt     = $ref->{id_youtube};
        my $artist    = defined($ref->{artist}) ? $ref->{artist} : "Unknown";
        my $title     = defined($ref->{title})  ? $ref->{title}  : "Unknown";
        my $duration  = 0;
        my $sMsgSong  = "$artist - $title";
        my $word      = ($nbMp3 > 1 ? "matches" : "match");

        if (defined($id_yt) && $id_yt ne "") {
            ($duration, $sMsgSong) = getYoutubeDetails($self, "https://www.youtube.com/watch?v=$id_yt");
            botPrivmsg(
                $self,
                $channel,
                "($nick mp3 search) $nbMp3 $word, first result : ".
                "(Library ID : $id_mp3 YTID : $id_yt) / $sMsgSong - https://www.youtube.com/watch?v=$id_yt"
            );
        } else {
            botPrivmsg(
                $self,
                $channel,
                "($nick mp3 search) $nbMp3 $word, first result : ".
                "(Library ID : $id_mp3) / $artist - $title"
            );
        }

        # 3) If multiple matches, show up to 10 IDs
        if ($nbMp3 > 1) {
            my $sql_list = "SELECT id_mp3, id_youtube, artist, title, folder, filename ".
                           "FROM MP3 WHERE CONCAT(artist, ' ', title) LIKE ? LIMIT 10";
            $self->{logger}->log(3, "mp3_ctx(): $sql_list (pattern=$pattern)");
            my $sth2 = $self->{dbh}->prepare($sql_list);

            unless ($sth2 && $sth2->execute($pattern)) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql_list");
            } else {
                my $output = "";
                while (my $r = $sth2->fetchrow_hashref()) {
                    my $id2 = $r->{id_mp3};
                    $output .= "$id2 ";
                }
                $sth2->finish;

                if ($nbMp3 > 10) {
                    $output .= "And " . ($nbMp3 - 10) . " more...";
                }

                botPrivmsg(
                    $self,
                    $channel,
                    "($nick mp3 search) Next 10 Library IDs : $output"
                );
            }

            logBot($self, $message, $channel, "mp3", @args);
        }
    } else {
        # Extremely unlikely, because count>0, but keep a fallback
        botPrivmsg($self, $channel, "($nick mp3 search) unexpected error, please try again");
    }

    return;
}

# Execute a shell command and return (up to) the last 3 lines.
# Context-based version, restricted to Owner-level users.
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

    # Very basic safety guard for obviously destructive commands
    if (
        $command =~ /\brm\s+-rf\b/i
        || $command =~ /:()\s*{\s*:|:&};:/   # old bash fork bomb
        || $command =~ /\bshutdown\b|\breboot\b/i
        || $command =~ /\bmkfs\b/i
        || $command =~ /\bdd\s+if=/i
        || $command =~ />\s*\/dev\/sd/i
    ) {
        botNotice($self, $nick, "Don't be that evil!");
        return;
    }

    # Log the attempt in console (owner-only, so it is fine to log full command)
    my $pfx = eval { $message->prefix } // $nick;
    noticeConsoleChan($self, "$pfx exec: $command");

    # Execute command, pipe through tail -n 3 to reduce spam
    my $shell = "$command | tail -n 3 2>&1";
    open my $cmd_fh, "-|", $shell or do {
        $self->{logger}->log(3, "mbExec_ctx: Failed to execute: $command");
        $send->("Execution failed.");
        return;
    };

    my $i          = 0;
    my $has_output = 0;

    while (my $line = <$cmd_fh>) {
        chomp $line;
        $send->("$i: $line");
        $has_output = 1;
        last if ++$i >= 3;    # double safety, even though tail already limits
    }
    close $cmd_fh;

    $send->("No output.") unless $has_output;

    # Log to ACTIONS_LOG as usual
    logBot($self, $message, ($channel // "(private)"), "exec", $command);

    return 1;
}

# Get the harbor ID from LIQUIDSOAP telnet server
sub getHarBorId(@) {
	my ($self) = @_;
	my $LIQUIDSOAP_TELNET_HOST = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_HOST');
	my $LIQUIDSOAP_TELNET_PORT = $self->{conf}->get('radio.LIQUIDSOAP_TELNET_PORT');
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep harbor | grep status | awk '{print \$2}' | awk -F'.' {'print \$1}' | awk -F'_' '{print \$2}' |") {
			$self->{logger}->log(0,"getHarBorId() Unable to connect to LIQUIDSOAP telnet port");
			return undef;
		}
		my $line;
		if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
			chomp($line);
			$self->{logger}->log(3,$line);
			return $line;
		}
		else {
			$self->{logger}->log(3,"getHarBorId() No output");
		}
	}
	else {
		$self->{logger}->log(0,"getHarBorId() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
	return undef;
}

# qlog: search CHANNEL_LOG for a pattern, grep-style
# Syntax:
#   qlog [-n nick] [#channel] <word1> <word2> ...
# - If -n nick is given, restrict search to that nick.
# - If #channel is given, search that channel (defaults to current channel).
# - Shows up to 5 most recent matches, first one displayed first.
sub mbChannelLog_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---- Resolve user and permissions ----
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx qlog command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level("Administrator") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx qlog command attempt (command level [Administrator] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # ---- Optional #channel as first arg (allows: qlog #chan foo bar) ----
    my $target_chan = $channel;
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
        return;
    }

    # ---- Optional -n nickname filter ----
    my $target_nick;
    if (@args && defined $args[0] && $args[0] eq '-n') {
        shift @args; # remove -n
        $target_nick = shift @args; # nickname
        unless (defined $target_nick && $target_nick ne '') {
            botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
            return;
        }
    }

    # Remaining args = search terms
    my @terms = @args;

    # If no terms and no nick => nothing to search
    unless (@terms || $target_nick) {
        botNotice($self, $nick, "Syntax: qlog [-n nickname] [#channel] <word1> <word2> ...");
        return;
    }

    # ---- Output routing: chan vs private ----
    my $is_private = !defined($channel) || $channel eq '';
    my $dest       = $target_chan; # we always display in the target channel when it exists

    my $send = $is_private
        ? sub { my ($msg) = @_; botNotice($self, $nick, $msg) }
        : sub { my ($msg) = @_; botPrivmsg($self, $dest, $msg) };

    # ---- Build SQL grep-like query ----
    # We search in CHANNEL_LOG / CHANNEL for the target channel,
    # optional nick, and optional pattern in publictext.
    my @where = (
        'c.name = ?',                  # channel
        'cl.publictext NOT LIKE ?',    # avoid matching qlog itself
    );
    my @bind  = ($target_chan, '%qlog%');

    if (defined $target_nick) {
        push @where, 'cl.nick LIKE ?';
        push @bind,  $target_nick;
    }

    if (@terms) {
        # Build a LIKE pattern: word1%word2%word3 ...
        my $pattern = '%' . join('%', @terms) . '%';
        push @where, 'cl.publictext LIKE ?';
        push @bind,  $pattern;
    }

    my $where_sql = join(' AND ', @where);

    my $limit = 5;    # show up to 5 matches
    $limit = 1 if $limit < 1;

    my $sql = <<"SQL";
SELECT cl.ts, cl.nick, cl.publictext
FROM CHANNEL_LOG cl
JOIN CHANNEL c ON c.id_channel = cl.id_channel
WHERE $where_sql
ORDER BY cl.ts DESC
LIMIT $limit
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute(@bind)) {
        $self->{logger}->log(1, "mbChannelLog_ctx() SQL Error: $DBI::errstr | Query: $sql");
        return;
    }

    my @rows;
    while (my $row = $sth->fetchrow_hashref) {
        push @rows, $row;
    }
    $sth->finish;

    unless (@rows) {
        $send->("($nick qlog) No result.");
        logBot($self, $message, $dest, "qlog", @args);
        return;
    }

    my $total = scalar @rows;

    # ---- Display results, first match highlighted as "main" ----
    my $idx = 0;
    for my $row (@rows) {
        my $ts   = $row->{ts}        // '';
        my $n    = $row->{nick}      // '';
        my $text = $row->{publictext} // '';

        # Compact whitespace and truncate to avoid flooding
        $text =~ s/\s+/ /g;
        if (length($text) > 300) {
            $text = substr($text, 0, 297) . '...';
        }

        my $pos = $idx + 1;
        my $tag = ($pos == 1)
            ? "[1/$total] latest match"
            : "[$pos/$total]";

        $send->("($nick qlog $tag) $ts <$n> $text");
        $idx++;
    }

    logBot($self, $message, $dest, "qlog", @args);
    return 1;
}

# Check if a nick is in the HAILO_EXCLUSION_NICK table
sub is_hailo_excluded_nick(@) {
	my ($self,$nick) = @_;
	my $sQuery = "SELECT * FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($nick)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sOutput = "";
		if (my $ref = $sth->fetchrow_hashref()) {
			$sth->finish;
			return 1;
		}
		else {
			$sth->finish;
			return 0;
		}
	}
}

# hailo_ignore <nick>
# Add a nick to HAILO_EXCLUSION_NICK so Hailo will ignore it
# Requires: authenticated + Master
sub hailo_ignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user and permissions ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_ignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    # --- Syntax and arguments ---
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_ignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    # --- Check if nick is already ignored ---
    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL Error (SELECT): $DBI::errstr | Query: $sql");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        $sth->finish;
        botNotice($self, $caller, "Nick $target_nick is already ignored by Hailo (id $ref->{id_hailo_exclusion_nick}).");
        return;
    }
    $sth->finish;

    # --- Insert new ignore entry ---
    $sql = "INSERT INTO HAILO_EXCLUSION_NICK (nick) VALUES (?)";
    $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_ignore_ctx() SQL Error (INSERT): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while adding Hailo ignore for $target_nick.");
        return;
    }
    $sth->finish;

    botNotice($self, $caller, "Hailo will now ignore nick $target_nick.");
    logBot($self, $message, $ctx->channel, "hailo_ignore", $target_nick);

    return 1;
}

# hailo_unignore <nick>
# Remove a nick from HAILO_EXCLUSION_NICK so Hailo will reply again
# Requires: authenticated + Master
sub hailo_unignore_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $caller  = $ctx->nick;
    my $chan    = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # --- Resolve user and permissions ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $caller // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $caller,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $caller;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_unignore command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $caller, "Your level does not allow you to use this command.");
        return;
    }

    # --- Syntax and arguments ---
    unless (defined $args[0] && $args[0] ne '') {
        botNotice($self, $caller, "Syntax: hailo_unignore <nick>");
        return;
    }

    my $target_nick = $args[0];

    # --- Check if nick is currently ignored ---
    my $sql = "SELECT id_hailo_exclusion_nick FROM HAILO_EXCLUSION_NICK WHERE nick = ?";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($target_nick)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL Error (SELECT): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while checking Hailo ignore for $target_nick.");
        return;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        botNotice($self, $caller, "Nick $target_nick is not ignored by Hailo.");
        return;
    }

    my $id_excl = $row->{id_hailo_exclusion_nick};

    # --- Delete ignore entry ---
    $sql = "DELETE FROM HAILO_EXCLUSION_NICK WHERE id_hailo_exclusion_nick = ?";
    $sth = $self->{dbh}->prepare($sql);
    unless ($sth && $sth->execute($id_excl)) {
        $self->{logger}->log(1, "hailo_unignore_ctx() SQL Error (DELETE): $DBI::errstr | Query: $sql");
        botNotice($self, $caller, "Database error while removing Hailo ignore for $target_nick.");
        return;
    }
    $sth->finish;

    botNotice($self, $caller, "Hailo will no longer ignore nick $target_nick.");
    logBot($self, $message, $chan, "hailo_unignore", $target_nick);

    return 1;
}

# hailo_status
# Show Hailo brain statistics (tokens, expressions, links, etc.)
# Requires: authenticated + Master
sub hailo_status_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    # --- Auth check ---
    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    # --- Permission check: Master+ ---
    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_status command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Get Hailo object ---
    my $hailo = eval { get_hailo($self) };
    if ($@ || !$hailo) {
        $self->{logger}->log(1, "hailo_status_ctx(): failed to get Hailo object: $@");
        botNotice($self, $nick, "Internal error: could not access Hailo brain.");
        return;
    }

    # --- Get stats from Hailo ---
    my $stats_raw = eval { $hailo->stats };
    if ($@) {
        $self->{logger}->log(1, "hailo_status_ctx(): Hailo->stats died: $@");
        botNotice($self, $nick, "Internal error: Hailo stats() failed.");
        return;
    }
    unless (defined $stats_raw) {
        botNotice($self, $nick, "Hailo did not return any stats.");
        return;
    }

    my $summary;
    my $extra = "";

    if (ref $stats_raw eq 'HASH') {
        my $href = $stats_raw;

        # Generic listing of all available keys
        my @pairs;
        for my $k (sort keys %$href) {
            next unless defined $href->{$k};
            push @pairs, "$k=$href->{$k}";
        }
        $summary = join(", ", @pairs) || "No stats available";

        # Try to compute some useful derived metrics if we recognize keys
        my $tokens = $href->{tokens};
        my $prev   = $href->{previous_token_links} // $href->{previous_links};
        my $next   = $href->{next_token_links}     // $href->{next_links};

        if (defined $tokens && $tokens > 0 && defined $prev && defined $next) {
            my $total_links = $prev + $next;
            my $avg_links   = sprintf("%.2f", $total_links / $tokens);
            $extra = " | total_links=$total_links, avg_links_per_token=$avg_links";
        }
    }
    else {
        # Old behaviour: stats() returns a simple string like
        # "X tokens, Y expressions, Z previous links and W next links"
        $summary = $stats_raw;
    }

    my $msg_out = "Hailo stats: $summary$extra";

    if (defined $channel && $channel ne '') {
        botPrivmsg($self, $channel, $msg_out);
        logBot($self, $message, $channel, "hailo_status", undef);
    } else {
        botNotice($self, $nick, $msg_out);
        logBot($self, $message, undef, "hailo_status", undef);
    }

    return 1;
}

# Get the Hailo chatter ratio for a specific channel
sub get_hailo_channel_ratio(@) {
	my ($self,$sChannel) = @_;
	my $sQuery = "SELECT ratio FROM HAILO_CHANNEL,CHANNEL WHERE HAILO_CHANNEL.id_channel=CHANNEL.id_channel AND name like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $ratio = $ref->{'ratio'};
			$sth->finish;
			return $ratio;
		}
		else {
			$sth->finish;
			return -1;
		}
	}
}

# Set the Hailo chatter ratio for a specific channel
sub set_hailo_channel_ratio {
	my ($self, $sChannel, $ratio) = @_;

	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined $channel_obj) {
		$self->{logger}->log(1, "set_hailo_channel_ratio() unknown channel: $sChannel");
		return undef;
	}

	my $id_channel = $channel_obj->get_id;

	# Check if HAILO_CHANNEL entry exists for this channel
	my $sQuery = "SELECT * FROM HAILO_CHANNEL WHERE id_channel = ?";
	my $sth = $self->{dbh}->prepare($sQuery);

	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
		return undef;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		# Entry exists, update ratio
		$sQuery = "UPDATE HAILO_CHANNEL SET ratio = ? WHERE id_channel = ?";
		$sth = $self->{dbh}->prepare($sQuery);

		if ($sth->execute($ratio, $id_channel)) {
			$sth->finish;
			$self->{logger}->log(3, "set_hailo_channel_ratio updated hailo chatter ratio to $ratio for $sChannel");
			return 0;
		} else {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			return undef;
		}
	} else {
		# No entry yet, insert new one
		$sQuery = "INSERT INTO HAILO_CHANNEL (id_channel, ratio) VALUES (?, ?)";
		$sth = $self->{dbh}->prepare($sQuery);

		if ($sth->execute($id_channel, $ratio)) {
			$sth->finish;
			$self->{logger}->log(3, "set_hailo_channel_ratio set hailo chatter ratio to $ratio for $sChannel");
			return 0;
		} else {
			$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
			return undef;
		}
	}
}


# hailo_chatter
# Get or set Hailo chatter ratio for a given channel.
# - Query: hailo_chatter [#channel]
# - Set:   hailo_chatter [#channel] <ratio 0-100>
# Stored ratio is still "inverted" (100 - user_ratio) to keep legacy behaviour.
sub hailo_chatter_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = ();
    if (ref($ctx->args) eq 'ARRAY') {
        @args = @{ $ctx->args };
    } elsif (defined $ctx->args) {
        @args = ($ctx->args);
    }

    # --- Auth / permission checks (Master+) ---
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    unless (eval { $user->has_level('Master') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx hailo_chatter command attempt (command level [Master] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Resolve target channel ---
    my $target_chan = undef;

    # First arg can be a channel name
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        $target_chan = $channel if defined $channel && $channel =~ /^#/;
    }

    unless (defined $target_chan && $target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }

    # --- If no numeric arg: just display current ratio ---
    my $is_query_only = 1;
    if (@args && defined $args[0] && $args[0] =~ /^\d+$/) {
        $is_query_only = 0;
    }

    if ($is_query_only) {
        my $stored_ratio = eval { get_hailo_channel_ratio($self, $target_chan) };
        if (!defined $stored_ratio || $stored_ratio == -1) {
            botNotice($self, $nick, "No Hailo chatter ratio set for $target_chan (using default behaviour).");
        } else {
            my $user_ratio = 100 - $stored_ratio;    # keep legacy inversion
            botNotice(
                $self,
                $nick,
                "Hailo chatter reply chance on $target_chan is currently ${user_ratio}%."
            );
        }
        logBot($self, $message, $target_chan, "hailo_chatter", "show $target_chan");
        return 1;
    }

    # --- Set mode: hailo_chatter [#channel] <ratio> ---
    my $ratio = $args[0];

    unless (defined $ratio && $ratio =~ /^\d+$/) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        return;
    }
    if ($ratio > 100) {
        botNotice($self, $nick, "Syntax: hailo_chatter [#channel] <ratio 0-100>");
        botNotice($self, $nick, "ratio must be between 0 and 100");
        return;
    }

    # Check that chanset +HailoChatter is enabled
    my $id_chanset_list = eval { getIdChansetList($self, "HailoChatter") };
    unless ($id_chanset_list) {
        botNotice($self, $nick, "Chanset list HailoChatter is not defined.");
        return;
    }

    my $id_channel_set = eval { getIdChannelSet($self, $target_chan, $id_chanset_list) };
    unless ($id_channel_set) {
        botNotice($self, $nick, "Chanset +HailoChatter is not set on $target_chan (use: chanset $target_chan +HailoChatter).");
        return;
    }

    # Legacy internal representation: store 100 - ratio
    my $internal_ratio = 100 - $ratio;

    my $ret = eval { set_hailo_channel_ratio($self, $target_chan, $internal_ratio) };
    if ($@) {
        $self->{logger}->log(1, "hailo_chatter_ctx(): set_hailo_channel_ratio died: $@");
        botNotice($self, $nick, "Internal error while setting Hailo chatter ratio.");
        return;
    }

    if ($ret) {
        botNotice($self, $nick, "HailoChatter's ratio is now set to ${ratio}% on $target_chan");
        logBot($self, $message, $target_chan, "hailo_chatter", "set $target_chan $ratio");
        return 1;
    } else {
        botNotice($self, $nick, "Failed to update HailoChatter ratio on $target_chan.");
        return;
    }
}

# whereis <hostname|IP>
sub whereis(@) {
	my ($self,$sHostname) = @_;
	my $userIP;
	$self->{logger}->log(3,"whereis() $sHostname");
	if ( $sHostname =~ /users.undernet.org$/ ) {
		return "on an Undernet hidden host ;)";
	}
	unless ( $sHostname =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ ) {
		my $packed_ip = gethostbyname("$sHostname");
		if (defined $packed_ip) {
			$userIP = inet_ntoa($packed_ip);
		}
	}
	else {
		$userIP = $sHostname;
	}
	unless (defined($userIP) && ($userIP =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/)) {
		return "N/A";
	}
	unless (open WHEREIS, "curl --connect-timeout 3 -f -s https://api.country.is/$userIP |") {
		return "N/A";
	}
	my $line;
	if (defined($line=<WHEREIS>)) {
		close WHEREIS;
		chomp($line);
		my $json = decode_json $line;
		my $country = $json->{'country'};
		if (defined($country)) {
			return $country;
		}
		else {
			return undef;
		}
	}
	else {
		return "N/A";
	}	
}

# whereis <nick>
# Triggers a WHOIS and lets the WHOIS handler call whereis() on the hostname/IP.
sub mbWhereis_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Normalize args
    my @args;
    if (ref($ctx->args) eq 'ARRAY') {
        @args = @{ $ctx->args };
    } elsif (defined $ctx->args) {
        @args = ($ctx->args);
    }

    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: whereis <nick>");
        return;
    }

    my $target_nick = $args[0];

    # Prepare WHOIS context for the async handler
    my %whois = (
        nick    => $target_nick,
        sub     => 'mbWhereis',      # kept for compatibility with existing WHOIS handler
        caller  => $nick,
        channel => $channel,
        message => $message,
        ts      => time,
    );

    # Store in bot state (same semantics as before: re-use the existing hashref)
    %{$self->{WHOIS_VARS}} = %whois;

    # Send WHOIS to IRC server
    $self->{irc}->send_message("WHOIS", undef, $target_nick);

    $self->{logger}->log(3, "mbWhereis_ctx(): WHOIS requested for $target_nick by $nick"
                             . (defined $channel ? " on $channel" : " (private)"));

    return 1;
}

# birthday:
#   add user <username> <dd/mm|dd/mm/YYYY>
#   del user <username>
#   next
#   <username>
sub userBirthday_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Normalize args
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    unless (@args) {
        botNotice($self, $nick, "Syntax: birthday <username>");
        return;
    }

    # Helper: where to reply
    my $is_private = (!defined($channel) || $channel eq '');
    my $reply_chan = $channel;

    #
    # birthday <username>
    #
    if (@args == 1 && $args[0] !~ /^(add|del|next)$/i) {
        my $target = $args[0];

        my $sth = $self->{dbh}->prepare("SELECT birthday FROM USER WHERE nickname LIKE ?");
        unless ($sth && $sth->execute($target)) {
            $self->{logger}->log(1, "userBirthday_ctx() SQL Error: $DBI::errstr");
            return;
        }

        if (my $row = $sth->fetchrow_hashref) {
            if (defined $row->{birthday} && $row->{birthday} ne '') {
                my $msg = "${target}'s birthday is $row->{birthday}";
                $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
            } else {
                my $msg = "User $target has no defined birthday.";
                $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
            }
        } else {
            my $msg = "Unknown user $target";
            $is_private ? botNotice($self, $nick, $msg) : botPrivmsg($self, $reply_chan, $msg);
        }

        $sth->finish;
        return 1;
    }

    #
    # birthday next
    #
    if ($args[0] =~ /^next$/i) {
        return _birthday_next_ctx($ctx);
    }

    #
    # birthday add|del user ...
    # Requires: authenticated + Administrator
    #
    my $user = $ctx->user || $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $nick,
            "You must be logged in to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password");
        return;
    }

    unless (eval { $user->has_level("Administrator") }) {
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    my ($mode, $kwd, $target, $date) = @args;

    unless (defined $mode && $mode =~ /^(add|del)$/i && defined $kwd && $kwd =~ /^user$/i && defined $target && $target ne '') {
        botNotice($self, $nick, "Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
        botNotice($self, $nick, "Syntax: birthday del user <username>");
        return;
    }

    if ($mode =~ /^add$/i) {
        return _birthday_add_ctx($ctx, $target, $date);
    }

    if ($mode =~ /^del$/i) {
        return _birthday_del_ctx($ctx, $target);
    }

    botNotice($self, $nick, "Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
    return;
}

# Send a public message to all channels with chanset +RadioPub
sub radioPub(@) {
	my ($self,$message,$sNick,undef,@tArgs) = @_;
	
	# Check channels with chanset +RadioPub
	if (defined($self->{conf}->get('radio.RADIO_HOSTNAME'))) {	
		my $sQuery = "SELECT name FROM CHANNEL,CHANNEL_SET,CHANSET_LIST WHERE CHANNEL.id_channel=CHANNEL_SET.id_channel AND CHANNEL_SET.id_chanset_list=CHANSET_LIST.id_chanset_list AND CHANSET_LIST.chanset LIKE 'RadioPub'";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			while (my $ref = $sth->fetchrow_hashref()) {
				my $curChannel = $ref->{'name'};
				$self->{logger}->log(3,"RadioPub on $curChannel");
				my $currentTitle = getRadioCurrentSong($self);
				if ( $currentTitle ne "Unknown" ) {
					displayRadioCurrentSong($self,undef,undef,$curChannel,undef);
				}
				else {
					$self->{logger}->log(3,"RadioPub skipped for $curChannel, title is $currentTitle");
				}
			}
		}
		$sth->finish;
	}
}

# Context-based: Delete a user from the database (Master only)
sub delUser_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $message = $ctx->message;
    my $nick    = $ctx->nick;
    my @args    = @{ $ctx->args // [] };

    # Remove caller nick if injected
    shift @args if @args && lc($args[0]) eq lc($nick);

    my $user = $ctx->require_level("Master") or return;

    my $target = $args[0] // '';
    $target =~ s/^\s+|\s+$//g;

    if ($target eq '') {
        botNotice($self, $nick, "Syntax: deluser <username>");
        return;
    }

    my $id_user = getIdUser($self, $target);
    unless ($id_user) {
        botNotice($self, $nick, "Undefined user $target");
        return;
    }

    $self->{dbh}->do("DELETE FROM USER_CHANNEL WHERE id_user=?", undef, $id_user);
    $self->{dbh}->do("DELETE FROM USER WHERE id_user=?", undef, $id_user);

    my $msg = "User $target (id_user: $id_user) has been deleted";
    botNotice($self, $nick, $msg);
    logBot($self, $message, undef, "deluser", $msg);
}

# Get Fortnite ID for a user
sub getFortniteId(@) {
	my ($self,$sUser) = @_;
	my $sQuery = "SELECT fortniteid FROM USER WHERE nickname LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUser)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $fortniteid = $ref->{'fortniteid'};
			$sth->finish;
			return $fortniteid;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

# Fortnite stats:
#   f <username>
#
# Requires:
#   - Logged in
#   - Level >= User
sub fortniteStats_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Reply target (notice in private, privmsg in channel)
    my $is_private = (!defined($channel) || $channel eq '');
    my $reply_to   = $is_private ? $nick : $channel;

    # Normalize args (only accept ARRAY)
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: f <username>");
        return;
    }

    # API key from config
    my $api_key = eval { $self->{conf}->get('fortnite.API_KEY') } // '';
    unless ($api_key) {
        $self->{logger}->log(0, "fortniteStats_ctx(): fortnite.API_KEY is undefined in config file");
        return;
    }

    # Auth + level checks (Context)
    my $user = $ctx->user || $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        my $who = $user ? ($user->nickname // 'unknown') : 'unknown';
        my $msg = $message->prefix . " f command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick,
            "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
        );
        logBot($self, $message, undef, "f", $msg);
        return;
    }

    unless (eval { $user->has_level("User") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $msg = $message->prefix . " f command attempt (requires User for "
                . ($user->nickname // $nick) . " [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        logBot($self, $message, undef, "f", $msg);
        return;
    }

    my $target_name = $args[0];

    # Resolve internal user + fortniteid (keep legacy helpers)
    my $id_user = getIdUser($self, $target_name);
    unless (defined $id_user) {
        botNotice($self, $nick, "Undefined user $target_name");
        return;
    }

    my $account_id = getFortniteId($self, $target_name);
    unless (defined $account_id && $account_id ne '') {
        botNotice($self, $nick, "Undefined fortniteid for user $target_name");
        return;
    }

    # Call API
    my $url = "https://fortnite-api.com/v2/stats/br/v2/$account_id";

    # Use exec list form to avoid shell quoting issues (still via curl)
    my @cmd = (
        "curl", "-L",
        "--header", "Authorization: $api_key",
        "--connect-timeout", "5",
        "--max-time", "8",
        "-sS",
        $url,
    );

    open my $fh, "-|", @cmd or do {
        $self->{logger}->log(3, "fortniteStats_ctx(): failed to exec curl");
        botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    };

    my $json_details = join('', <$fh>);
    close $fh;

    unless (defined $json_details && $json_details ne '') {
        $self->{logger}->log(3, "fortniteStats_ctx(): empty API response for $target_name/$account_id");
        botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $data = eval { decode_json($json_details) };
    if ($@ || !$data) {
        $self->{logger}->log(3, "fortniteStats_ctx(): JSON decode error: $@");
        botPrivmsg($self, $reply_to, "Fortnite stats: unexpected API response.");
        return;
    }

    # API may return {status:..., error:...}
    if (ref($data) eq 'HASH' && exists $data->{status} && $data->{status} != 200) {
        my $err = $data->{error} // "API error";
        $self->{logger}->log(3, "fortniteStats_ctx(): API status=$data->{status} error=$err");
        botPrivmsg($self, $reply_to, "Fortnite stats: $err");
        return;
    }

    my $payload = $data->{data};
    unless ($payload && ref($payload) eq 'HASH') {
        botPrivmsg($self, $reply_to, "Fortnite stats: no data for this account.");
        return;
    }

    my $account    = $payload->{account}    || {};
    my $battlepass = $payload->{battlePass} || {};

    # Some payloads are nested differently depending on API versions / modes
    my $overall = $payload->{stats}{all}{overall}
              || $payload->{stats}{all}{overall}{solo}   # defensive (rare)
              || {};

    my $name        = $account->{name}       // $target_name;
    my $matches     = $overall->{matches}    // 0;
    my $wins        = $overall->{wins}       // 0;
    my $win_rate    = defined $overall->{winRate} ? $overall->{winRate} : 0;
    my $kills       = $overall->{kills}      // 0;
    my $kd          = defined $overall->{kd} ? $overall->{kd} : 0;
    my $top3        = $overall->{top3}       // 0;
    my $top5        = $overall->{top5}       // 0;
    my $top10       = $overall->{top10}      // 0;
    my $bp_level    = $battlepass->{level}   // 0;
    my $bp_progress = defined $battlepass->{progress} ? $battlepass->{progress} : 0;

    # Readable on dark/light: bold labels only (no background colors)
    my $user_tag = String::IRC->new('[' . $name . ']')->bold;

    my $line =
        "Fortnite -- $user_tag "
      . (String::IRC->new('Matches:')->bold . " $matches")
      . " | " . (String::IRC->new('Wins:')->bold . " $wins ($win_rate%)")
      . " | " . (String::IRC->new('Kills:')->bold . " $kills")
      . " | " . (String::IRC->new('K/D:')->bold . " $kd")
      . " | " . (String::IRC->new('BP:')->bold . " L$bp_level ($bp_progress%)")
      . " | " . (String::IRC->new('Top3/5/10:')->bold . " $top3/$top5/$top10");

    botPrivmsg($self, $reply_to, $line);

    logBot($self, $message, $channel, "f", @args);
    return 1;
}

# ------------------------------------------------------------------
# CONSTANTS (all prefixed with CHATGPT_)
# ------------------------------------------------------------------
use constant {
    CHATGPT_API_URL      => 'https://api.openai.com/v1/chat/completions',
    CHATGPT_MODEL        => 'gpt-4o-mini',
    CHATGPT_TEMPERATURE  => 0.7,
    CHATGPT_MAX_TOKENS   => 400,
    CHATGPT_MAX_PRIVMSG  => 4,       # how many PRIVMSG we allow to send
    CHATGPT_WRAP_BYTES   => 400,     # safe IRC payload length
    CHATGPT_SLEEP_US     => 750_000, # µs between PRIVMSG
	CHATGPT_TRUNC_MSG    => ' [¯\_(ツ)_/¯ guess you can’t have everything…]',   # suffix when we truncate
};

# ------------------------------------------------------------------
# chatGPT()
# ------------------------------------------------------------------
sub chatGPT(@) {
    my ($self, $message, $nick, $chan, @args) = @_;

    # --------------------------------------------------------------
    #  sanity / config checks
    # --------------------------------------------------------------
	my $api_key = $self->{conf}->get('openai.API_KEY')
    	or ($self->{logger}->log(0,'chatGPT() openai.API_KEY missing'), return);

    @args
        or (botNotice($self,$nick,'Syntax: tellme <prompt>'), return);

    # opt-in check (+chatGPT chanset)
    my $setlist = getIdChansetList($self,'chatGPT') // '';
    my $setid   = getIdChannelSet($self,$chan,$setlist) // '';
    return unless length $setid;

    # --------------------------------------------------------------
    # payload preparation
    # --------------------------------------------------------------
    my $prompt = join ' ', @args;
    $self->{logger}->log(3,"chatGPT() chatGPT prompt: $prompt");

    my $json = encode_json {
        model       => CHATGPT_MODEL,
        temperature => CHATGPT_TEMPERATURE,
        max_tokens  => CHATGPT_MAX_TOKENS,
        messages    => [
            { role => 'system',
              content =>
                'You always answer in a helpfull and serious way , precise and never start your answer with « Oh là là » when the answer is in french, always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis'
            },
            { role => 'user', content => $prompt },
        ],
    };

    # write JSON to a temp file to avoid shell-quoting hell
    my ($fh,$tmp) = tempfile(UNLINK => 1, SUFFIX => '.json');
    print $fh $json;
    close $fh;

    # --------------------------------------------------------------
    # call the API with curl
    # --------------------------------------------------------------
    my $cmd = join ' ',
        'curl -sS -X POST',
        "-H 'Content-Type: application/json'",
        "-H 'Authorization: Bearer $api_key'",
        "--data-binary \@$tmp",
        CHATGPT_API_URL;

    my $response = qx{$cmd};
    if ($? != 0 || !$response) {
        $self->{logger}->log(0,"chatGPT() chatGPT curl failed: $?");
        botPrivmsg($self,$chan,"($nick) Sorry, API did not answer.");
        return;
    }

    # --------------------------------------------------------------
	# decode the JSON response
	# --------------------------------------------------------------
	my $data = eval { decode_json($response) };
	if ($@ || !($data->{choices}[0]{message}{content} || '')) {
		$self->{logger}->log( 0, 'chatGPT() chatGPT invalid JSON response');
		$self->{logger}->log( 3, "chatGPT() Raw API response: $response");
		$self->{logger}->log( 3, "chatGPT() JSON decode error: $@") if $@;
		$self->{logger}->log( 3, "chatGPT() Missing expected content in response structure") unless $@;
		botPrivmsg($self, $chan, "($nick) Could not read API response.");
		return;
	}

	my $answer = $data->{choices}[0]{message}{content};
    $self->{logger}->log(4,"chatGPT() chatGPT raw answer: $answer");

    # -------- minimise PRIVMSG --------------------------------------
    $answer =~ s/[\r\n]+/ /g;    # strip CR/LF
    $answer =~ s/\s{2,}/ /g;     # squeeze spaces

    my @chunk = _chatgpt_wrap($answer);           # word-safe
    # … after  my @chunk = _chatgpt_wrap($answer);
    my $truncate   = @chunk > CHATGPT_MAX_PRIVMSG;
    my $last       = $truncate ? CHATGPT_MAX_PRIVMSG-1 : $#chunk;

    if ($truncate) {
        my $suff  = CHATGPT_TRUNC_MSG;                   # funny suffix
        my $allow = CHATGPT_WRAP_BYTES - length($suff);  # bytes we can keep

        if (length($chunk[$last]) > $allow) {            # always enforce room
            $chunk[$last] = substr($chunk[$last], 0, $allow);
            $chunk[$last] =~ s/\s+\S*$//;                # backtrack to prev word
            $chunk[$last] =~ s/\s+$//;                   # trim trailing spaces
        }
        $chunk[$last] .= $suff;                          # now safe to append
    }

    for my $i (0..$last) {
        botPrivmsg($self,$chan,$chunk[$i]);
        usleep(CHATGPT_SLEEP_US);
    }
    $self->{logger}->log(3,"chatGPT() sent ".($last+1)." PRIVMSG");
}

# ------------------------------------------------------------------
# helper: wrap text to ≤CHATGPT_WRAP_BYTES without splitting words
# ------------------------------------------------------------------
sub _chatgpt_wrap {
    my ($txt) = @_;
    my @out;

    while (length $txt) {

        # If the remainder already fits, push and break
        if (length($txt) <= CHATGPT_WRAP_BYTES) {
            push @out, $txt;
            last;
        }

        # Look ahead up to the limit
        my $slice = substr($txt, 0, CHATGPT_WRAP_BYTES);
        my $break = rindex($slice, ' ');

        # If space found, split there; else hard split
        $break = CHATGPT_WRAP_BYTES if $break == -1;

        push @out, substr($txt, 0, $break, '');   # remove from $txt
        $txt =~ s/^\s+//;                         # trim leading spaces
    }
    return @out;
}

# xlogin
# Authenticate the bot to Undernet CSERVICE and set +x on itself.
# Requires:
#   - Logged in
#   - Level >= Master
sub xLogin_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my $conf = $self->{conf};

    # --- Resolve user from context ---
    my $user = $ctx->user;
    unless ($user && $user->is_authenticated) {
        my $who = $user ? $user->nickname : "unknown";
        my $sNoticeMsg = $message->prefix . " xLogin command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice(
            $self,
            $nick,
            "You must be logged to use this command : /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        logBot($self, $message, undef, "xLogin", $sNoticeMsg);
        return;
    }

    # --- Check privileges (Master+) ---
    unless (eval { $user->has_level("Master") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $sNoticeMsg = $message->prefix
            . " xLogin command attempt (command level [Master] for user "
            . $user->nickname . " [$lvl])";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice(
            $self,
            $nick,
            "This command is not available for your level. Contact a bot master."
        );
        logBot($self, $message, undef, "xLogin", $sNoticeMsg);
        return;
    }

    # --- Read configuration ---
    my $xService = $conf->get('undernet.UNET_CSERVICE_LOGIN');
    unless (defined($xService) && $xService ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_LOGIN is undefined in configuration file");
        return;
    }

    my $xUsername = $conf->get('undernet.UNET_CSERVICE_USERNAME');
    unless (defined($xUsername) && $xUsername ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_USERNAME is undefined in configuration file");
        return;
    }

    my $xPassword = $conf->get('undernet.UNET_CSERVICE_PASSWORD');
    unless (defined($xPassword) && $xPassword ne "") {
        botNotice($self, $nick, "undernet.UNET_CSERVICE_PASSWORD is undefined in configuration file");
        return;
    }

    # --- Perform login to CSERVICE ---
    my $sNoticeMsg = "Authenticating to $xService with username $xUsername";
    botNotice($self, $nick, $sNoticeMsg);
    noticeConsoleChan($self, $sNoticeMsg);

    # Send login command to service
    botPrivmsg($self, $xService, "login $xUsername $xPassword");

    # Request +x on the bot nick (same as old write)
    my $botnick = $self->{irc}->nick_folded;
    $self->{irc}->write("MODE $botnick +x\x0d\x0a");

    # Log action
    logBot($self, $message, undef, "xLogin", "$xUsername\@$xService");
    return 1;
}

# yomomma
# Send a random "Yomomma" joke, or a specific one by ID.
# Usage:
#   yomomma           -> random joke
#   yomomma <id>      -> joke with given id_yomomma
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
sub resolve_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = @{ $ctx->args // [] };

    # --- Syntax check ---
    unless (@args && defined $args[0] && $args[0] ne '') {
        botNotice($self, $nick, "Syntax: resolve <hostname|IP>");
        return;
    }

    my $input = $args[0];

    # --- Case 1: Input is IPv4 → reverse DNS ---
    if ($input =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {

        my $packed = inet_aton($input);
        unless ($packed) {
            botPrivmsg($self, $channel, "($nick) Invalid IPv4 format: $input");
            return;
        }

        my $host = gethostbyaddr($packed, AF_INET);
        if ($host) {
            botPrivmsg($self, $channel, "($nick) Reverse DNS → $input = $host");
        } else {
            botPrivmsg($self, $channel, "($nick) No reverse DNS entry for $input");
        }

        logBot($self, $ctx->message, $channel, "resolve", $input);
        return;
    }

    # --- Case 2: hostname → IPv4 ---
    my ($name, $aliases, $addrtype, $length, @addrs) = gethostbyname($input);

    unless (@addrs) {
        botPrivmsg($self, $channel, "($nick) Hostname could not be resolved: $input");
        return;
    }

    # Convert packed IPs to strings
    my @ips = map { inet_ntoa($_) } @addrs;

    # Format output
    if (@ips == 1) {
        botPrivmsg($self, $channel, "($nick) $input → $ips[0]");
    } else {
        botPrivmsg($self, $channel, "($nick) $input resolved to multiple IPs:");
        for my $ip (@ips) {
            botPrivmsg($self, $channel, " - $ip");
        }
    }

    logBot($self, $ctx->message, $channel, "resolve", $input);
    return 1;
}

# Set the TMDB language for a channel
sub setTMDBLangChannel {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	my $sTargetChannel = $sChannel;

	my (
		$iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc,
		$iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd,
		$sMatchingUserInfo1, $sMatchingUserInfo2
	) = getNickInfo($self, $message);

	return undef unless defined $iMatchingUserId;

	if ($iMatchingUserAuth) {
		if (defined($iMatchingUserLevel) && checkUserLevel($self, $iMatchingUserLevel, "Master")) {

			# If first argument is a channel, shift it
			if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
				$sChannel = shift @tArgs;
				$sTargetChannel = $sChannel;
			}

			unless (defined($sChannel) && $sChannel ne "") {
				botNotice($self, $sNick, "Undefined channel");
				botNotice($self, $sNick, "Syntax tmdblangset [#channel] <lang>");
				return undef;
			}

			my $channel_obj = $self->{channels}{$sChannel};

			unless (defined $channel_obj) {
				botNotice($self, $sNick, "Channel $sChannel is not registered to me");
				return undef;
			}

			my $id_channel = $channel_obj->get_id;

			if (defined($tArgs[0]) && $tArgs[0] ne "") {
				my $sLang = $tArgs[0];

				$self->{logger}->log(3, "setTMDBLangChannel() $sChannel lang set to $sLang");

				my $sQuery = "UPDATE CHANNEL SET tmdb_lang = ? WHERE id_channel = ?";
				my $sth = $self->{dbh}->prepare($sQuery);

				unless ($sth->execute($sLang, $id_channel)) {
					$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
					return undef;
				} else {
					botPrivmsg($self, $sChannel, "TMDB language set to $sLang");
					$sth->finish;
					return undef;
				}
			} else {
				botNotice($self, $sNick, "Syntax tmdblangset [#channel] <lang>");
			}

		} else {
			my $sNoticeMsg = $message->prefix . " tmdblangset command attempt (command level [Master] for user $sMatchingUserHandle [$iMatchingUserLevel])";
			noticeConsoleChan($self, $sNoticeMsg);
			botNotice($self, $sNick, "Your level does not allow you to use this command.");
			return undef;
		}
	} else {
		my $sNoticeMsg = $message->prefix . " tmdblangset command attempt (user $sMatchingUserHandle is not logged in)";
		noticeConsoleChan($self, $sNoticeMsg);
		botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		return undef;
	}
}


# Search a movie or TV show on TMDB and return a clean synopsis with details
sub mbTMDBSearch {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $conf = $self->{conf};

    my $api_key = $conf->get('tmdb.API_KEY');
    unless (defined($api_key) && $api_key ne "") {
        $self->{logger}->log(0, "tmdb.API_KEY is undefined in config file");
        botNotice($self, $sNick, "TMDB API key is missing in the configuration.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: tmdb <movie or series name>");
        return;
    }

    my $query = join(" ", @tArgs);
    my $lang  = getTMDBLangChannel($self, $sChannel) || 'en';
    $self->{logger}->log(3, "tmdb_lang for $sChannel is $lang");

    # Make the TMDB API call
    my $info = get_tmdb_info_with_curl($api_key, $lang, $query);
    unless ($info) {
        botNotice($self, $sNick, "No results found for '$query'.");
        return;
    }

    my $title     = $info->{title}     || $info->{name}     || "Unknown title";
    my $overview  = $info->{overview}  || "No synopsis available.";
    my $date      = $info->{release_date} || $info->{first_air_date} || "????";
    my $year      = ($date =~ /^(\d{4})/) ? $1 : "????";
    my $rating    = defined($info->{vote_average}) ? sprintf("%.1f", $info->{vote_average}) : "?";
    my $type      = exists($info->{title}) ? "Movie" : "TV Series";

    my $msg = "🎬 [$type] \"$title\" ($year) • Rating: $rating/10\n📜 Synopsis: $overview";
    $msg = "($sNick) $msg" if defined $sNick;

    botPrivmsg($self, $sChannel, $msg);
}

# Get TMDB info using curl
sub getTMDBLangChannel (@) {
	my ($self, $sChannel) = @_;
	my $sQuery = "SELECT tmdb_lang FROM CHANNEL WHERE name LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $tmdb_lang = $ref->{'tmdb_lang'};
			$sth->finish;
			return $tmdb_lang || 'en-US';
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

# Get detailed TMDB info for the first matching result
sub get_tmdb_info_with_curl {
    my ($api_key, $lang, $query) = @_;

    my $encoded_query = uri_escape($query);
    my $url = "https://api.themoviedb.org/3/search/multi?api_key=$api_key&language=$lang&query=$encoded_query";

    my $json_response = `curl -s "$url"`;
    return undef unless $json_response;

    my $data = eval { decode_json($json_response) };
    return undef if $@ || !ref($data) || !$data->{results} || !@{$data->{results}};

    # Find the first movie or TV result
    my $result;
    foreach my $item (@{$data->{results}}) {
        next unless $item->{media_type} eq 'movie' || $item->{media_type} eq 'tv';
        $result = $item;
        last;
    }

    return undef unless $result;

    # Trim the overview cleanly
    my $overview = $result->{overview} // "No synopsis available.";
    if (length($overview) > 350) {
        $overview = substr($overview, 0, 347) . '...';
    }

    return {
        title           => $result->{title} // $result->{name},
        overview        => $overview,
        release_date    => $result->{release_date} // $result->{first_air_date},
        vote_average    => $result->{vote_average},
        media_type      => $result->{media_type},
    };
}

# --- Helpers DEBUG ------------------------------------------------------------

sub _bool_str {  # affiche joliment undef/0/1
    return 'undef' if !defined $_[0];
    return $_[0] ? '1' : '0';
}

# Dump l'état d'auth partout (objet, DB, module Auth, caches)
sub _dbg_auth_snapshot {
    my ($self, $stage, $user, $nick, $fullmask) = @_;

    my $uid = eval { $user && $user->can('id') ? $user->id : undef } // ($user->{id_user} // $user->{id} // undef);
    my $user_auth = $user ? $user->{auth} : undef;

    my $db_auth   = 'n/a';
    if ($uid) {
        eval { ($db_auth) = $self->{dbh}->selectrow_array('SELECT auth FROM USER WHERE id_user=?', undef, $uid); 1; }
          or do { $db_auth = 'err'; };
    }

    my $auth_mod = 'n/a';
    if ($self->{auth} && $uid) {
        my $ok = eval { $self->{auth}->is_logged_in_id($uid) };
        $auth_mod = defined $ok ? $ok : 'err';
    }

    my $sess_auth = eval { $self->{sessions}{lc($nick)}{auth} } // undef;
    my $cache_id  = eval { $self->{logged_in}{$uid} } // undef;

    $self->{logger}->log(
        3,
        sprintf("🔎 AUTH[%s] uid=%s user.auth=%s db.auth=%s authmod=%s cache.logged_in=%s session[%s].auth=%s mask='%s'",
            $stage,
            (defined $uid ? $uid : 'undef'),
            _bool_str($user_auth),
            ( $db_auth eq 'n/a' || $db_auth eq 'err' ? $db_auth : _bool_str($db_auth) ),
            ( $auth_mod eq 'n/a' || $auth_mod eq 'err' ? $auth_mod : _bool_str($auth_mod) ),
            _bool_str($cache_id),
            (defined $nick ? $nick : ''),
            _bool_str($sess_auth),
            (defined $fullmask ? $fullmask : '')
        )
    );
}

# Force les caches mémoire si la DB dit auth=1 (utile si du vieux code lit ailleurs)
sub _ensure_logged_in_state {
    my ($self, $user, $nick, $fullmask) = @_;
    return unless $user;

    my $uid = eval { $user->can('id') ? $user->id : undef } // ($user->{id_user} // $user->{id} // undef);
    return unless $uid;

    my ($auth_db) = $self->{dbh}->selectrow_array('SELECT auth FROM USER WHERE id_user=?', undef, $uid);
    return unless $auth_db;

    $user->{auth} = 1;

    if ($self->{auth}) {
        eval { $self->{auth}->set_logged_in($uid, 1) };
        eval {
            $self->{auth}->set_session_user($nick, {
                id_user        => $uid,
                nickname       => $user->{nickname},
                username       => $user->{username},
                id_user_level  => $user->{id_user_level},
                auth           => 1,
                hostmask       => $fullmask,
            })
        };
        eval { $self->{auth}->update_last_login($uid) };
    }

    $self->{logged_in}{$uid}           = 1;
    $self->{logged_in_by_nick}{lc $nick} = 1;
    $self->{sessions}{lc $nick} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
    $self->{users_by_id}{$uid} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
    $self->{users_by_nick}{lc $nick} = {
        id_user        => $uid,
        nickname       => $user->{nickname},
        username       => $user->{username},
        id_user_level  => $user->{id_user_level},
        auth           => 1,
        hostmask       => $fullmask,
    };
}

# Simple echo command using Mediabot::Context as a first integration step
sub mbEcho {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $chan = $ctx->channel;
    my $text = join(' ', @{ $ctx->args // [] });

    return unless length $text;

    botPrivmsg($self, $chan, $text);
}

# Context-based status (Master only)
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
    if (open my $fh_uptime, '-|', 'uptime') {
        if (defined(my $line = <$fh_uptime>)) {
            chomp $line;
            $server_uptime = $line;
        }
        close $fh_uptime;
    } else {
        $self->{logger}->log(1, "Could not execute 'uptime' command");
    }

    # --- OS Info ---
    my $uname = 'Unknown';
    if (open my $fh_uname, '-|', 'uname -a') {
        if (defined(my $line = <$fh_uname>)) {
            chomp $line;
            $uname = $line;
        }
        close $fh_uname;
    } else {
        $self->{logger}->log(1, "Could not execute 'uname' command");
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

1;