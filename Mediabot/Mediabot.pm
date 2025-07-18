package Mediabot;
 
use strict;
use warnings;
use diagnostics;
use Mediabot::Auth;
use Mediabot::User;
use Time::HiRes qw(usleep);
use Config::Simple;
use Date::Format;
use Date::Parse;
use Data::Dumper;
use DBI;
use Switch;
use Memory::Usage;
use IO::Async::Timer::Periodic;
use String::IRC;
use POSIX qw(setsid);
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
use URI::Escape qw(uri_escape);
use List::Util qw/min/;
use File::Temp qw/tempfile/;
use Carp qw(croak);

sub new {
    my ($class, $args) = @_;

    my $self = bless {
        config_file => $args->{config_file} // undef,
        server      => $args->{server}      // undef,
        dbh         => $args->{dbh}         // undef,
        conf        => $args->{conf}        // undef,
        channels    => {},
    }, $class;

    return $self;
}


#-----------------------------------------------------------------
# Timestamped log methods (avoid namespace collisions)
#-----------------------------------------------------------------

# Return a Mediabot::User object matching the message prefix, or undef if none matched
# Return a Mediabot::User object from IRC message
sub get_user_from_message {
    my ($self, $message) = @_;

    my $hostmask = $message->prefix;
    my $query = "SELECT * FROM USER";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth->execute) {
        $self->{logger}->log(1, "get_user_from_message() SQL Error: $DBI::errstr");
        return;
    }

    while (my $row = $sth->fetchrow_hashref) {
        my @patterns = split(/,/, $row->{hostmasks} // "");
        foreach my $mask (@patterns) {
            my $regex = $mask;
            $regex =~ s/\./\\./g;
            $regex =~ s/\*/.*/g;
            $regex =~ s/\[/\\[/g;
            $regex =~ s/\]/\\]/g;
            $regex =~ s/\{/\\{/g;
            $regex =~ s/\}/\\}/g;

            if ($hostmask =~ /^$regex/) {
                $self->{logger}->log(3, "get_user_from_message() $regex matches $hostmask");
                require Mediabot::User;
                my $user = Mediabot::User->new($row);
                $user->load_level($self->{dbh});
                $user->maybe_autologin($self, $hostmask);
                $self->{logger}->log(3, "get_user_from_message() matched user id: " . $user->id);
                return $user;
            }
        }
    }

    $sth->finish;
    $self->{logger}->log(3, "get_user_from_message() no user matched hostmask $hostmask");
    return;
}


sub my_log_info {
    my ($self, $msg) = @_;
    my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
    print STDOUT "$ts [INFO] $msg\n";
}

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

# Clean up and exit the program
sub clean_and_exit(@) {
	my ($self,$iRetValue) = @_;
	$self->{logger}->log(0,"Cleaning and exiting...");
	
	if (defined($self->{dbh}) && ($self->{dbh} != 0)) {
		if ( $iRetValue != 1146 ) {
		}
		$self->{dbh}->disconnect();
	}
	
	if(defined(fileno($self->{LOG}))) { close $self->{LOG}; }
	
	exit $iRetValue;
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
sub getUserhandle(@) {
	my ($self,$id_user) = @_;
	my $sUserhandle = undef;
	my $sQuery = "SELECT nickname FROM USER WHERE id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user) ) {
		$self->{logger}->log(1,"getUserhandle() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$sUserhandle = $ref->{'nickname'};
		}
	}
	$sth->finish;
	return $sUserhandle;
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
    my ($id_channel, $name, $chanmode, $key) = getConsoleChan($self);

    if (defined $name && $name ne '') {
        botNotice($self, $name, $sMsg);
    } else {
        $self->{logger}->log(0, "No console channel defined! Run ./configure to set up the bot.");
    }
}

# Log a bot command to ACTIONS_LOG, optionally linked to a user and a channel
sub logBot {
    my ($self, $message, $channel, $action, @args) = @_;

    # Attempt to resolve the user object
    my $user = $self->get_user_from_message($message);

    my $user_id   = $user ? $user->id : undef;
    my $user_name = $user ? $user->nickname : 'Unknown user';
    my $hostmask  = $message->prefix // 'unknown';

    # Resolve the channel ID using channel object, if available
    my $channel_id;
    if (defined $channel && exists $self->{channels}{$channel}) {
        $channel_id = $self->{channels}{$channel}->get_id;
    }

    # Normalize args string
    my $args_string = join(' ', @args) // '';

    # Insert the log entry
    my $sql = "INSERT INTO ACTIONS_LOG (ts, id_user, id_channel, hostmask, action, args) VALUES (?, ?, ?, ?, ?, ?)";
    my $sth = $self->{dbh}->prepare($sql);
    my $timestamp = time2str("%Y-%m-%d %H-%M-%S", time);

    unless ($sth->execute($timestamp, $user_id, $channel_id, $hostmask, $action, $args_string)) {
        $self->{logger}->log(0, "logBot() SQL error: $DBI::errstr — Query: $sql");
        return;
    }

    # Compose and log a console message
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
		if (utf8::is_utf8($sMsg)) {
			$sMsg = Encode::encode("UTF-8", $sMsg);
			$sMsg =~ s/[\r\n]+/ /g;
		}
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

# Send a notice to a target
sub botNotice(@) {
	my ($self,$sTo,$sMsg) = @_;
	$self->{irc}->do_NOTICE( target => $sTo, text => $sMsg );
	$self->{logger}->log(0,"-> -$sTo- $sMsg");
	if (substr($sTo, 0, 1) eq '#') {
		logBotAction($self,undef,"notice",$self->{irc}->nick_folded,$sTo,$sMsg);
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
        my $sql = "SELECT * FROM USER_CHANNEL, CHANNEL WHERE USER_CHANNEL.id_channel = CHANNEL.id_channel AND name = ? AND id_user = ?";
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

# DEPRECATED: Get nick information from a message and return a Mediabot::User object
# This method is maintained for backward compatibility only.
sub getNickInfo {
    my ($self, $message) = @_;

    my $conf   = $self->{conf};
    my $prefix = $message->prefix;

    $self->{logger}->log(2, "DEPRECATED: getNickInfo() was called – use get_user_from_message() instead");

    my $sQuery = "SELECT * FROM USER";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute) {
        $self->{logger}->log(1, "getNickInfo() SQL Error: $DBI::errstr - Query: $sQuery");
        return undef;
    }

    while (my $ref = $sth->fetchrow_hashref()) {
        my @masks = split(/,/, $ref->{hostmasks});
        foreach my $raw_mask (@masks) {
            $self->{logger}->log(4, "getNickInfo() Checking hostmask: $raw_mask");

            my $src = $raw_mask;
            my $mask = $raw_mask;
            $mask =~ s/\./\\./g;
            $mask =~ s/\*/.*/g;
            $mask =~ s/\[/\\[/g;
            $mask =~ s/\]/\\]/g;
            $mask =~ s/\{/\\{/g;
            $mask =~ s/\}/\\}/g;

            if ($prefix =~ /^$mask/) {
                $self->{logger}->log(3, "getNickInfo() $mask matches $prefix");

                my $user = Mediabot::User->new($ref);
                $user->load_level($self->{dbh});
                $user->maybe_autologin($self, $src);

                $self->{logger}->log(3, "getNickInfo() matched user id: " . $user->id);
                $sth->finish;
                return $user;
            }
        }
    }

    $sth->finish;
    $self->{logger}->log(4, "getNickInfo() No match for prefix $prefix");
    return undef;
}

# Handle public commands
sub mbCommandPublic(@) {
	my ($self,$message,$sChannel,$sNick,$botNickTriggered,$sCommand,@tArgs)	= @_;
	my $conf = $self->{conf};
	switch($sCommand) {
		case /^die$/i				{
													mbQuit($self,$message,$sNick,@tArgs);
												}
		case /^nick$/i			{
													mbChangeNick($self,$message,$sNick,@tArgs);
												}
		case /^addtimer$/i	{
													mbAddTimer($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^remtimer$/i	{
													mbRemTimer($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^timers$/i		{
													mbTimers($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^msg$/i				{
													msgCmd($self,$message,$sNick,@tArgs);
												}
		case /^say$/i				{
													sayChannel($self,$message,$sNick,@tArgs);
												}
		case /^act$/i				{
													actChannel($self,$message,$sNick,@tArgs);
												}
		case /^cstat$/i			{
													userCstat($self,$message,$sNick,@tArgs);
												}
		case /^status$/i		{
													mbStatus($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^adduser$/i		{
													addUser($self,$message,$sNick,@tArgs);
												}
		case /^deluser$/i		{
													delUser($self,$message,$sNick,@tArgs);
												}
		case /^users$/i			{
													userStats($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^userinfo$/i	{
													userInfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addhost$/i		{
													addUserHost($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addchan$/i		{
													addChannel($self,$message,$sNick,@tArgs);
												}
		case /^chanset$/i		{
													channelSet($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^purge$/i			{
													purgeChannel($self,$message,$sNick,@tArgs);
												}
		case /^part$/i			{
													channelPart($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^join$/i			{
													channelJoin($self,$message,$sNick,@tArgs);
												}
		case /^add$/i				{
													channelAddUser($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^del$/i				{
													channelDelUser($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^modinfo$/i		{
													userModinfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^op$/i				{
													userOpChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^deop$/i			{
													userDeopChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^invite$/i		{
													userInviteChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^voice$/i			{
													userVoiceChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^devoice$/i		{
													userDevoiceChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^kick$/i			{
													userKickChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topic$/i			{
													userTopicChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^showcommands$/i	{
													userShowcommandsChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chaninfo$/i	{
													userChannelInfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chanlist$/i	{
													channelList($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^whoami$/i		{
													userWhoAmI($self,$message,$sNick,@tArgs);
												}
		case /^auth$/i			{
													userAuthNick($self,$message,$sNick,@tArgs);
												}
		case /^verify$/i		{
													userVerifyNick($self,$message,$sNick,@tArgs);
												}
		case /^access$/i		{
													userAccessChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addcmd$/i		{
													mbDbAddCommand($self,$message,$sNick,@tArgs);
												}
		case /^remcmd$/i		{
													mbDbRemCommand($self,$message,$sNick,@tArgs);
												}
		case /^modcmd$/i		{
													mbDbModCommand($self,$message,$sNick,@tArgs);
												}
		case /^mvcmd$/i			{
													mbDbMvCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^showcmd$/i		{
													mbDbShowCommand($self,$message,$sNick,@tArgs);
												}
		case /^version$/i 						{
													$self->{logger}->log( 0, "mbVersion() by $sNick on $sChannel");
													botPrivmsg($self,$sChannel,$self->{conf}->get('main.MAIN_PROG_NAME') . $self->{main_prog_version});
													logBot($self, $message, undef, "version", undef);
												}
		case /^chanstatlines$/i	{
														channelStatLines($self,$message,$sChannel,$sNick,@tArgs);
													}
		case /^whotalk|whotalks$/i		{
														whoTalk($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^countcmd$/i	{
														mbCountCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topcmd$/i		{
														mbTopCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^popcmd$/i		{
														mbPopCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^searchcmd$/i	{
														mbDbSearchCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^lastcmd$/i		{
														mbLastCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^owncmd$/i		{
														mbDbOwnersCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^holdcmd$/i		{
														mbDbHoldCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addcatcmd$/i	{
														mbDbAddCategoryCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chcatcmd$/i	{
														mbDbChangeCategoryCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topsay$/i		{
														userTopSay($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^checkhostchan$/i		{
															mbDbCheckHostnameNickChan($self,$message,$sNick,$sChannel,@tArgs);
														}
		case /^checkhost$/i	{
															mbDbCheckHostnameNick($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^checknick$/i	{
													mbDbCheckNickHostname($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^greet$/i			{
													userGreet($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^nicklist$/i	{
														channelNickList($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^rnick$/i			{
														randomChannelNick($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^birthdate$/i	{
														displayBirthDate($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^colors$/i		{
														mbColors($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^seen$/i			{
														mbSeen($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^date$/i								{
														displayDate($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^weather$|^meteo$/i					{
																	displayWeather($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^addbadword$/i						{
														channelAddBadword($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^rembadword$/i						{
														channelRemBadword($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^ignores$/i							{
														IgnoresList($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^ignore$/i 							{
														addIgnore($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^unignore$/i							{
														delIgnore($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^yt$/i								{
														youtubeSearch($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^song$/i								{
														displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^listeners$/i							{
														displayRadioListeners($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^nextsong$/i							{
														radioNext($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^wordstat$/i							{
														wordStat($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^addresponder$/i						{
															addResponder($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^delresponder$/i						{
															delResponder($self,$message,$sNick,$sChannel,@tArgs);
														}
		case /^update$/i							{
														update($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^lastcom$/i							{
														lastCom($self,$message,$sNick,$sChannel,@tArgs);
													}
		case "q"									{
														mbQuotes($self,$message,$sNick,$sChannel,@tArgs);
													}
		case "Q"									{
														mbQuotes($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^moduser$/i 							{
														mbModUser($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^antifloodset$/i 						{
														setChannelAntiFloodParams($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^leet$/i 								{
														displayLeetString($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^rehash/i								{
														mbRehash($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^play$/i								{
														playRadio($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^rplay$/i								{
														rplayRadio($self,$message,$sNick,$sChannel,@tArgs);
													}	
		case /^queue$/i								{
														queueRadio($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^next$/i								{
														nextRadio($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^mp3$/i								{		
														mp3($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^exec$/i								{		
														mbExec($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^qlog$/i								{		
														mbChannelLog($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^hailo_ignore$/i						{		
														hailo_ignore($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^hailo_unignore$/i					{		
														hailo_unignore($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^hailo_status$/i						{		
														hailo_status($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^hailo_chatter$/i						{		
														hailo_chatter($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^whereis$/i							{		
														mbWhereis($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^birthday$/i							{
														userBirthday($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^f$/i									{
														fortniteStats($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^xlogin$/i							{
														xLogin($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^yomomma$/i							{
														Yomomma($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^Spike$/i								{
														botPrivmsg($self,$sChannel,"https://teuk.org/In_Spike_Memory.jpg");
													}
		case /^resolve$/i							{
														mbResolver($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^tmdb$/i						    	{
														mbTMDBSearch($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^tmdblangset$/i						{
														setTMDBLangChannel($self,$message,$sNick,$sChannel,@tArgs);
													}	
		case /^debug$/i						    	{
														mbDebug($self,$message,$sNick,$sChannel,@tArgs);
													}
		case /^help$/i								{
														unless(defined($tArgs[0]) && ($tArgs[0] ne "")) {
															botPrivmsg($self,$sChannel,"Please visit https://github.com/teuk/mediabot_v3/wiki for full documentation on mediabot");
															return 0;
														}
														else {
															botPrivmsg($self,$sChannel,"Help on command $tArgs[0] is not available (unknown command ?). Please visit https://github.com/teuk/mediabot_v3/wiki for full documentation on mediabot");
															return 0;
														}
													}	
		else										{
														my $bFound = mbDbCommand($self,$message,$sChannel,$sNick,$sCommand,@tArgs);
														unless ( $bFound ) {
															if ($botNickTriggered) {
																my $what = join(" ",($sCommand,@tArgs));
																switch($what) {
																	case /how\s+old\s+are\s+you|how\s+old\s+r\s+you|how\s+old\s+r\s+u/i {
																		$bFound = 1;
																		displayBirthDate($self,$message,$sNick,$sChannel,@tArgs);
																	}
																	case /who.. your daddy|who is your daddy/i {
																		my $owner = getChannelOwner($self,$sChannel);
																		unless (defined($owner) && ($owner ne "")) {
																			botPrivmsg($self,$sChannel,"I have no clue of who is " . $sChannel . "'s owner, but Te[u]K's my daddy");
																		}
																		else {
																			botPrivmsg($self,$sChannel,"Well I'm registered to $owner on $sChannel, but Te[u]K's my daddy");
																		}
																	}
																	case /^thx$|^thanx$|^thank you$|^thanks$/i {
																		botPrivmsg($self,$sChannel,"you're welcome $sNick");
																	}
																	case /who.. StatiK/i {
																		botPrivmsg($self,$sChannel,"StatiK is my big brother $sNick, he's awesome !");
																	}
																	elsif ($botNickTriggered) {
																		my $id_chanset_list = getIdChansetList($self, "Hailo");
																		if (defined($id_chanset_list)) {
																			my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
																			if (defined($id_channel_set)) {
																				unless (is_hailo_excluded_nick($self, $sNick) || (substr($what, 0, 1) eq "!")  || (substr($what, 0, 1) eq $self->{conf}->get('main.MAIN_PROG_CMD_CHAR')) ) {
																					my $hailo = get_hailo($self);
																					my $sCurrentNick = $self->{irc}->nick_folded;
																					$what =~ s/$sCurrentNick//g;
																					$what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });
																					my $sAnswer = $hailo->learn_reply($what);
																					if (defined($sAnswer) && ($sAnswer ne "") && !($sAnswer =~ /^\Q$what\E\s*\.$/i)) {
																						$self->{logger}->log( 4, "learn_reply $what from $sNick : $sAnswer");
																						botPrivmsg($self, $sChannel, $sAnswer);
																					}
																				}
																			}
																		}
																	}
																}
															}
															else {
																$self->{logger}->log(3,"Public command '$sCommand' not found");
															}
														}
													}
	}
}

# Handle private commands
sub mbCommandPrivate(@) {
	my ($self,$message,$sNick,$sCommand,@tArgs)	= @_;
	switch($sCommand) {
		case /^die$/i				{
													mbQuit($self,$message,$sNick,@tArgs);
												}
		case /^nick$/i			{
													mbChangeNick($self,$message,$sNick,@tArgs);
												}
		case /^addtimer$/i	{
													mbAddTimer($self,$message,undef,$sNick,@tArgs);
												}
		case /^remtimer$/i	{
													mbRemTimer($self,$message,undef,$sNick,@tArgs);
												}
		case /^timers$/i		{
													mbTimers($self,$message,undef,$sNick,@tArgs);
												}
		case /^register$/i	{
													mbRegister($self,$message,$sNick,@tArgs);
												}
		case /^dump$/i			{
													dumpCmd($self,$message,$sNick,@tArgs);
												}
		case /^msg$/i				{
													msgCmd($self,$message,$sNick,@tArgs);
												}
		case /^say$/i				{
													sayChannel($self,$message,$sNick,@tArgs);
												}
		case /^act$/i				{
													actChannel($self,$message,$sNick,@tArgs);
												}
		case /^status$/i		{
													mbStatus($self,$message,$sNick,undef,@tArgs);
												}
		case /^login$/i			{
													userLogin($self,$message,$sNick,@tArgs);
												}
		case /^pass$/i			{
													userPass($self,$message,$sNick,@tArgs);
												}
		case /^ident$/i			{
													userIdent($self,$message,$sNick,@tArgs);
												}
		case /^cstat$/i			{
													userCstat($self,$message,$sNick,@tArgs);
												}
		case /^adduser$/i		{
													addUser($self,$message,$sNick,@tArgs);
												}
		case /^deluser$/i		{
													delUser($self,$message,$sNick,@tArgs);
												}
		case /^users$/i			{
													userStats($self,$message,$sNick,undef,@tArgs);
												}
		case /^userinfo$/i	{
													userInfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^addhost$/i		{
													addUserHost($self,$message,$sNick,undef,@tArgs);
												}
		case /^addchan$/i		{
													addChannel($self,$message,$sNick,@tArgs);
												}
		case /^chanset$/i		{
													channelSet($self,$message,$sNick,undef,@tArgs);
												}
		case /^purge$/i			{
													purgeChannel($self,$message,$sNick,@tArgs);
												}
		case /^part$/i			{
													channelPart($self,$message,$sNick,undef,@tArgs);
												}
		case /^join$/i			{
													channelJoin($self,$message,$sNick,@tArgs);
												}
		case /^add$/i				{
													channelAddUser($self,$message,$sNick,undef,@tArgs);
												}
		case /^del$/i				{
													channelDelUser($self,$message,$sNick,undef,@tArgs);
												}
		case /^modinfo$/i		{
													userModinfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^op$/i				{
													userOpChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^deop$/i			{
													userDeopChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^invite$/i		{
													userInviteChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^voice$/i			{
													userVoiceChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^devoice$/i		{
													userDevoiceChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^kick$/i			{
													userKickChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^topic$/i			{
													userTopicChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^showcommands$/i	{
															userShowcommandsChannel($self,$message,$sNick,undef,@tArgs);
														}
		case /^chaninfo$/i	{
													userChannelInfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^chanlist$/i	{
													channelList($self,$message,$sNick,undef,@tArgs);
												}
		case /^whoami$/i		{
													userWhoAmI($self,$message,$sNick,@tArgs);
												}
		case /^verify$/i		{
													userVerifyNick($self,$message,$sNick,@tArgs);
												}
		case /^auth$/i			{
													userAuthNick($self,$message,$sNick,@tArgs);
												}
		case /^access$/i		{
													userAccessChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^addcmd$/i		{
													mbDbAddCommand($self,$message,$sNick,@tArgs);
												}
		case /^remcmd$/i		{
													mbDbRemCommand($self,$message,$sNick,@tArgs);
												}
		case /^modcmd$/i		{
													mbDbModCommand($self,$message,$sNick,@tArgs);
												}
		case /^showcmd$/i		{
													mbDbShowCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^mvcmd$/i			{
													mbDbMvCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^countcmd$/i	{
														mbCountCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^topcmd$/i		{
														mbTopCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^popcmd$/i		{
														mbPopCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^searchcmd$/i	{
														mbDbSearchCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^lastcmd$/i		{
														mbLastCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^owncmd$/i		{
														mbDbOwnersCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^holdcmd$/i		{
														mbDbHoldCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^addcatcmd$/i	{
														mbDbAddCategoryCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^chcatcmd$/i	{
														mbDbChangeCategoryCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^topsay$/i		{
														userTopSay($self,$message,$sNick,undef,@tArgs);
												}
		case /^checkhostchan$/i		{
																mbDbCheckHostnameNickChan($self,$message,$sNick,undef,@tArgs);
															}
		case /^checkhost$/i	{
													mbDbCheckHostnameNick($self,$message,$sNick,undef,@tArgs);
												}
		case /^checknick$/i	{
													mbDbCheckNickHostname($self,$message,$sNick,undef,@tArgs);
												}
		case /^greet$/i			{
													userGreet($self,$message,$sNick,undef,@tArgs);
												}
		case /^nicklist$/i	{
														channelNickList($self,$message,$sNick,undef,@tArgs);
												}
		case /^rnick$/i			{
														randomChannelNick($self,$message,$sNick,undef,@tArgs);
												}
		case /^chanstatlines$/i	{
															channelStatLines($self,$message,undef,$sNick,@tArgs);
														}
		case /^whotalk$/i		{
														whoTalk($self,$message,undef,$sNick,@tArgs);
												}
		case /^birthdate$/i	{
														displayBirthDate($self,$message,$sNick,undef,@tArgs);
												}
		case /^ignores$/i 	{
													IgnoresList($self,$message,$sNick,undef,@tArgs);
												}
		case /^ignore$/i 		{
													addIgnore($self,$message,$sNick,undef,@tArgs);
												}
		case /^unignore$/i	{
													delIgnore($self,$message,$sNick,undef,@tArgs);
												}
		case /^metadata$/i	{
													setRadioMetadata($self,$message,$sNick,undef,@tArgs);
												}
		case /^update$/i		{
													update($self,$message,$sNick,undef,@tArgs);
												}
		case /^lastcom$/i	{
												lastCom($self,$message,$sNick,undef,@tArgs);
											}
		case /^moduser$/i {
												mbModUser($self,$message,$sNick,undef,@tArgs);
											}
		case /^antifloodset$/i 		{
																setChannelAntiFloodParams($self,$message,$sNick,undef,@tArgs);
															}
		case /^rehash/i				{
														mbRehash($self,$message,$sNick,undef,@tArgs);
													}
		case /^play$/i								{
														playRadio($self,$message,$sNick,undef,@tArgs);
													}
		case /^radiopub$/i							{
														radioPub($self,$message,$sNick,undef,@tArgs);
													}
		case /^song$/i								{
														displayRadioCurrentSong($self,$message,$sNick,undef,@tArgs);
													}
		case /^debug$/i						    	{
														mbDebug($self,$message,$sNick,undef,@tArgs);
													}
		else										{
														$self->{logger}->log(3,$message->prefix . " Private command '$sCommand' not found");
														return undef;
													}
	}
}

# Quit the bot
sub mbQuit {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Retrieve user object from message
    my $user = $self->get_user_from_message($message);

    # If no user matched, silently ignore
    unless ($user) {
        $self->{logger}->log(3, "mbQuit(): No matching user for $sNick, command ignored.");
        return;
    }

    # User must be authenticated
    unless ($user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # User must have Master privilege level
    unless (checkUserLevel($self, $user->level, "Master")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Log and quit
    logBot($self, $message, undef, "die", @tArgs);
    $self->{Quit} = 1;
    $self->{irc}->send_message("QUIT", undef, join(" ", @tArgs));
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
			unless ($sth->execute(time2str("%Y-%m-%d %H-%M-%S",time),$iUserId)) {
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

# Handle user login via private message
sub userLogin {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Expect exactly: login <username> <password>
    if (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        my $user = $self->get_user_from_message($message);

        if (defined $user) {
            my $password = $user->password;
            my $user_id  = $user->id;
            my $nickname = $user->nickname;
            my $level_desc = $user->level_description // "unknown";

            unless (defined $password) {
                botNotice($self, $sNick, "Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass password");
                return;
            }

            my $auth_ok = $self->{auth}->verify_credentials($user_id, $tArgs[0], $tArgs[1]);

            if ($auth_ok) {
                botNotice($self, $sNick, "Login successful as $nickname (Level: $level_desc)");
                my $msg = $message->prefix . " Successful login as $nickname (Level: $level_desc)";
                $self->noticeConsoleChan($msg);
                logBot($self, $message, undef, "login", $tArgs[0], "Success");
            } else {
                botNotice($self, $sNick, "Login failed (Bad password).");
                my $msg = $message->prefix . " Failed login (Bad password)";
                $self->noticeConsoleChan($msg);
                logBot($self, $message, undef, "login", $tArgs[0], "Failed (Bad password)");
            }
        } else {
            my $msg = $message->prefix . " Failed login (hostmask not found in DB)";
            $self->noticeConsoleChan($msg);
            logBot($self, $message, undef, "login", $tArgs[0], "Failed (Bad hostmask)");
        }
    } else {
        botNotice($self, $sNick, "Syntax error: /msg " . $self->{irc}->nick_folded . " login <username> <password>");
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

sub userAdd(@) {
	my ($self,$sHostmask,$sUserHandle,$sPassword,$sLevel) = @_;
	unless (defined($sHostmask) && ($sHostmask =~ /^.+@.+/)) {
		return undef;
	}
	my $id_user_level = getIdUserLevel($self,$sLevel);
	if (defined($sPassword) && ($sPassword ne "")) {
		my $sQuery = "INSERT INTO USER (hostmasks,nickname,password,id_user_level) VALUES (?,?,PASSWORD(?),?)";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sHostmask,$sUserHandle,$sPassword,$id_user_level)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			return undef;
		}
		else {
			my $id_user = $sth->{ mysql_insertid };
			$self->{logger}->log(3,"userAdd() Added user : $sUserHandle with hostmask : $sHostmask id_user : $id_user as $sLevel password set : yes");
			return ($id_user);
		}
		$sth->finish;
	}
	else {
		my $sQuery = "INSERT INTO USER (hostmasks,nickname,id_user_level) VALUES (?,?,?)";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sHostmask,$sUserHandle,$id_user_level)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			return undef;
		}
		else {
			my $id_user = $sth->{ mysql_insertid };
			$self->{logger}->log(0,"Added user : $sUserHandle with hostmask : $sHostmask id_user : $id_user as $sLevel password set : no");
			return ($id_user);
		}
		$sth->finish;
	}
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

sub mbRegister(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my $sUserHandle = $tArgs[0];
	my $sPassword = $tArgs[1];
	if (defined($sUserHandle) && ($sUserHandle ne "") && defined($sPassword) && ($sPassword ne "")) {
		if (userCount($self) == 0) {
 			$self->{logger}->log(0,$message->prefix . " wants to register");
 			my $sHostmask = getMessageHostmask($self,$message);
 			my $id_user = userAdd($self,$sHostmask,$sUserHandle,$sPassword,"Owner");
 			if (defined($id_user)) {
 				$self->{logger}->log(0,"Registered $sUserHandle (id_user : $id_user) as Owner with hostmask $sHostmask");
 				botNotice($self,$sNick,"You just registered as $sUserHandle (id_user : $id_user) as Owner with hostmask $sHostmask");
 				logBot($self,$message,undef,"register","Success");
 				my ($id_channel,$name,$chanmode,$key) = getConsoleChan($self);
 				if (registerChannel($self,$message,$sNick,$id_channel,$id_user)) {
					$self->{logger}->log(0,"registerChan successfull $name $sUserHandle");
				}
				else {
					$self->{logger}->log(0,"registerChan failed $name $sUserHandle");
				}
 			}
 			else {
 				$self->{logger}->log(0,"Register failed for " . $message->prefix);
 			}
 		}
 		else {
 			$self->{logger}->log(0,"Register attempt from " . $message->prefix);
 		}
	}
}

# Allows an Administrator to force the bot to say something in a given channel
sub sayChannel {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Administrator")) {

                # Expect: say #channel message
                if (defined($tArgs[0]) && $tArgs[0] ne "" && $tArgs[0] =~ /^#/ && defined($tArgs[1])) {
                    my (undef, @tArgsTemp) = @tArgs;
                    my $sChannelText = join(" ", @tArgsTemp);

                    $self->{logger}->log(0, "$sNick issued a say command: $tArgs[0] $sChannelText");
                    botPrivmsg($self, $tArgs[0], $sChannelText);
                    logBot($self, $message, undef, "say", @tArgs);
                } else {
                    botNotice($self, $sNick, "Syntax: say <#channel> <text>");
                }

            } else {
                my $msg = $message->prefix . " say command attempt (command level [Administrator] for user " . $user->nickname . " [" . ($user->level // 'undef') . "])";
                $self->noticeConsoleChan($msg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            my $msg = $message->prefix . " say command attempt (user " . $user->nickname . " is not logged in)";
            $self->noticeConsoleChan($msg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
}


# Allows the bot Owner to send a raw IRC command manually
sub dumpCmd {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Owner")) {

                # Expect at least one argument for raw IRC command
                if (defined($tArgs[0]) && $tArgs[0] ne "") {
                    my $sDumpCommand = join(" ", @tArgs);
                    $self->{logger}->log(0, "$sNick issued a dump command: $sDumpCommand");
                    $self->{irc}->write("$sDumpCommand\x0d\x0a");
                    logBot($self, $message, undef, "dump", @tArgs);
                } else {
                    botNotice($self, $sNick, "Syntax error: dump <irc raw command>");
                }

            } else {
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
}


# Allows an Administrator to send a private message to a user or channel
sub msgCmd {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Administrator")) {

                # Check for proper syntax: msg <target> <text>
                if (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "") {
                    my $sTarget = shift @tArgs;
                    my $sMsg = join(" ", @tArgs);

                    $self->{logger}->log(0, "$sNick issued a msg command: $sTarget $sMsg");
                    botPrivmsg($self, $sTarget, $sMsg);
                    logBot($self, $message, undef, "msg", ($sTarget, @tArgs));
                } else {
                    botNotice($self, $sNick, "Syntax error: msg <target> <text>");
                }

            } else {
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
}


# Allows an Administrator to send an /me action to a channel
sub actChannel {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Administrator")) {

                # Ensure we have a channel and some text
                if (defined($tArgs[0]) && $tArgs[0] ne "" &&
                    defined($tArgs[1]) && $tArgs[1] ne "" &&
                    $tArgs[0] =~ /^#/) {

                    my (undef, @tArgsText) = @tArgs;
                    my $sChannelText = join(" ", @tArgsText);

                    $self->{logger}->log(0, "$sNick issued an act command: $tArgs[0] ACTION $sChannelText");
                    botAction($self, $tArgs[0], $sChannelText);
                    logBot($self, $message, undef, "act", @tArgs);

                } else {
                    botNotice($self, $sNick, "Syntax: act <#channel> <text>");
                }

            } else {
                my $notice = $message->prefix . " act command attempt (command level [Administrator] for user " . $user->nickname . "[" . $user->level . "])";
                noticeConsoleChan($self, $notice);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            my $notice = $message->prefix . " act command attempt (user " . $user->nickname . " is not logged in)";
            noticeConsoleChan($self, $notice);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
}


# Check bot resource usage and status
sub mbStatus {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Retrieve the user object from message prefix
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Master")) {

                # --- Bot Uptime ---
                my $uptime = time - $self->{iConnectionTimestamp};
                my $days    = int($uptime / 86400);
                my $hours   = sprintf("%02d", int(($uptime % 86400) / 3600));
                my $minutes = sprintf("%02d", int(($uptime % 3600) / 60));
                my $seconds = sprintf("%02d", $uptime % 60);

                my $uptime_str = "";
                $uptime_str .= "$days days, "    if $days > 0;
                $uptime_str .= "$hours" . "h "   if $hours > 0;
                $uptime_str .= "$minutes" . "mn " if $minutes > 0;
                $uptime_str .= "$seconds" . "s";
                $uptime_str = "Unknown" unless $uptime_str;

                # --- Server uptime ---
                my $server_uptime = "Unknown";
                if (open my $fh_uptime, "-|", "uptime") {
                    chomp($server_uptime = <$fh_uptime>) if defined($server_uptime = <$fh_uptime>);
                    close $fh_uptime;
                } else {
                    $self->{logger}->log(0, "Could not exec uptime command");
                }

                # --- Server OS info ---
                my $uname = "Unknown";
                if (open my $fh_uname, "-|", "uname -a") {
                    chomp($uname = <$fh_uname>) if defined($uname = <$fh_uname>);
                    close $fh_uname;
                } else {
                    $self->{logger}->log(0, "Could not exec uname command");
                }

                # --- Memory usage ---
                my $mu = Memory::Usage->new();
                $mu->record('Memory stats');

                my @mem_state = $mu->state();
                my @values = $mem_state[0][0];
                my $vm_mb     = sprintf("%.2f", $values[2] / 1024) if defined $values[2];
                my $rss_mb    = sprintf("%.2f", $values[3] / 1024) if defined $values[3];
                my $shared_mb = sprintf("%.2f", $values[4] / 1024) if defined $values[4];
                my $data_mb   = sprintf("%.2f", $values[6] / 1024) if defined $values[6];

                # --- Output bot status to user ---
                botNotice($self, $sNick, $self->{conf}->get('main.MAIN_PROG_NAME') . " v" . $self->{main_prog_version} . " Uptime: $uptime_str");
                botNotice($self, $sNick, "Memory usage (VM ${vm_mb}MB) (Resident ${rss_mb}MB) (Shared ${shared_mb}MB) (Data+Stack ${data_mb}MB)");
                botNotice($self, $sNick, "Server: $uname");
                botNotice($self, $sNick, "Server uptime: $server_uptime");

                logBot($self, $message, undef, "status", undef);

            } else {
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
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

# Change the bot's nickname
sub mbChangeNick {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Retrieve the user object from the message
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Owner")) {

                if (defined($tArgs[0]) && $tArgs[0] ne "") {
                    my $new_nick = $tArgs[0];
                    $self->{irc}->change_nick($new_nick);
                    logBot($self, $message, undef, "nick", $new_nick);
                } else {
                    botNotice($self, $sNick, "Syntax: nick <new_nick>");
                }

            } else {
                my $msg = $message->prefix . " nick command attempt (requires level [Owner] for user " . $user->nickname . " [" . $user->level . "])";
                noticeConsoleChan($self, $msg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            my $msg = $message->prefix . " nick command attempt (user " . $user->nickname . " is not logged in)";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
}


# Add a recurring timer that sends a raw IRC command periodically
sub mbAddTimer {
    my ($self, $message, $sChannel, $sNick, @tArgs) = @_;

    my %hTimers = $self->{hTimers} ? %{$self->{hTimers}} : ();

    # Retrieve user object from IRC message
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Owner")) {

                # Expected syntax: addtimer <name> <frequency> <raw>
                if (
                    defined($tArgs[0]) && $tArgs[0] ne "" &&
                    defined($tArgs[1]) && $tArgs[1] =~ /^[0-9]+$/ &&
                    defined($tArgs[2]) && $tArgs[2] ne ""
                ) {
                    my $timer_name = shift @tArgs;
                    my $interval   = shift @tArgs;
                    my $raw_cmd    = join(" ", @tArgs);

                    # Prevent duplicate timer names
                    if (exists $hTimers{$timer_name}) {
                        botNotice($self, $sNick, "Timer $timer_name already exists.");
                        return;
                    }

                    # Create and start the new periodic timer
                    my $timer = IO::Async::Timer::Periodic->new(
                        interval => $interval,
                        on_tick  => sub {
                            $self->{logger}->log(3, "Timer [$timer_name] tick: $raw_cmd");
                            $self->{irc}->write("$raw_cmd\x0d\x0a");
                        },
                    );

                    $self->{loop}->add($timer);
                    $timer->start;
                    $hTimers{$timer_name} = $timer;

                    # Persist the timer in the database
                    my $sth = $self->{dbh}->prepare("INSERT INTO TIMERS (name, duration, command) VALUES (?, ?, ?)");
                    unless ($sth->execute($timer_name, $interval, $raw_cmd)) {
                        $self->{logger}->log(1, "SQL Error: $DBI::errstr - INSERT INTO TIMERS");
                    } else {
                        botNotice($self, $sNick, "Timer $timer_name added.");
                        logBot($self, $message, undef, "addtimer", "Timer $timer_name added.");
                    }
                    $sth->finish;
                } else {
                    botNotice($self, $sNick, "Syntax: addtimer <name> <frequency> <raw>");
                }

            } else {
                my $msg = $message->prefix . " addtimer command attempt (requires [Owner] level for " . $user->nickname . ")";
                noticeConsoleChan($self, $msg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            my $msg = $message->prefix . " addtimer command attempt (user " . $user->nickname . " is not logged in)";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }

    # Update the bot's timer reference
    $self->{hTimers} = \%hTimers;
}


# Remove an existing timer by name
sub mbRemTimer {
    my ($self, $message, $sChannel, $sNick, @tArgs) = @_;

    my %hTimers = $self->{hTimers} ? %{$self->{hTimers}} : ();

    # Retrieve the user object from the message
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Owner")) {

                # Syntax: remtimer <name>
                if (defined($tArgs[0]) && $tArgs[0] ne "") {
                    my $timer_name = shift @tArgs;

                    unless (exists $hTimers{$timer_name}) {
                        botNotice($self, $sNick, "Timer $timer_name does not exist.");
                        return;
                    }

                    # Remove timer from the event loop and internal hash
                    $self->{loop}->remove($hTimers{$timer_name});
                    delete $hTimers{$timer_name};

                    # Delete from database
                    my $sth = $self->{dbh}->prepare("DELETE FROM TIMERS WHERE name=?");
                    unless ($sth->execute($timer_name)) {
                        $self->{logger}->log(1, "SQL Error: $DBI::errstr - DELETE FROM TIMERS");
                    } else {
                        botNotice($self, $sNick, "Timer $timer_name removed.");
                        logBot($self, $message, undef, "remtimer", "Timer $timer_name removed.");
                    }
                    $sth->finish;
                } else {
                    botNotice($self, $sNick, "Syntax: remtimer <name>");
                }

            } else {
                my $msg = $message->prefix . " remtimer command attempt (requires [Owner] level for user " . $user->nickname . ")";
                noticeConsoleChan($self, $msg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            my $msg = $message->prefix . " remtimer command attempt (user " . $user->nickname . " is not logged in)";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }

    # Update the bot's internal timer hash
    $self->{hTimers} = \%hTimers;
}


# List all registered timers currently stored in the database.
# Only available to authenticated users with 'Owner' level.
sub mbTimers {
    my ($self, $message, $sChannel, $sNick, @tArgs) = @_;

    # Extract local in-memory timers, if any
    my %hTimers = $self->{hTimers} ? %{$self->{hTimers}} : ();

    # Retrieve the user object from IRC message
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (defined($user->level) && checkUserLevel($self, $user->level, "Owner")) {

                # SQL query to fetch all timers from the database
                my $sQuery = "SELECT * FROM TIMERS";
                my $sth = $self->{dbh}->prepare($sQuery);

                unless ($sth->execute()) {
                    $self->{logger}->log(1, "SQL Error: $DBI::errstr - Query: $sQuery");
                } else {
                    my @tTimers;
                    my $i = 0;

                    while (my $ref = $sth->fetchrow_hashref()) {
                        my $id_timers = $ref->{id_timers};
                        my $name      = $ref->{name};
                        my $duration  = $ref->{duration};
                        my $command   = $ref->{command};

                        my $sSecondText = ($duration > 1 ? "seconds" : "second");
                        push @tTimers, "$name - id: $id_timers - every $duration $sSecondText - command: $command";
                        $i++;
                    }

                    # Send result to the user
                    if ($i > 0) {
                        botNotice($self, $sNick, "Active timers:");
                        foreach my $line (@tTimers) {
                            botNotice($self, $sNick, $line);
                        }
                    } else {
                        botNotice($self, $sNick, "No active timers");
                    }

                    logBot($self, $message, undef, "timers", undef);
                }

                $sth->finish;

            } else {
                # User level is not sufficient
                my $msg = $message->prefix . " timers command attempt (requires [Owner] level for user " . $user->nickname . ")";
                noticeConsoleChan($self, $msg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        } else {
            # User not logged in
            my $msg = $message->prefix . " timers command attempt (user " . $user->nickname . " is not logged in)";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        }
    }
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

# Display all currently authenticated users to an Administrator
sub userCstat {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Resolve user from hostmask
    my $user = $self->get_user_from_message($message);

    if (defined $user) {
        if ($user->is_authenticated) {
            if (checkUserLevel($self, $user->level, "Administrator")) {

                my $query = "SELECT nickname,description FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND auth=1 ORDER BY level";
                my $sth = $self->{dbh}->prepare($query);

                unless ($sth->execute) {
                    $self->{logger}->log(1, "userCstat() SQL Error: $DBI::errstr - Query: $query");
                    return;
                }

                my @lines;
                while (my $ref = $sth->fetchrow_hashref()) {
                    push @lines, $ref->{nickname} . " (" . $ref->{description} . ")";
                }

                my $prefix = "Authenticated users: ";
                my $line = $prefix;
                for my $entry (@lines) {
                    # Add word while staying under 400 chars
                    if (length($line) + length($entry) + 1 > 400) {
                        botNotice($self, $sNick, $line);
                        $line = "  $entry";
                    } else {
                        $line .= " $entry";
                    }
                }

                # Send remaining line
                botNotice($self, $sNick, $line) if $line ne $prefix;

                logBot($self, $message, undef, "cstat", @tArgs);
                $sth->finish;

            } else {
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
                noticeConsoleChan($self, $message->prefix . " cstat command denied (level too low: " . $user->level . ")");
            }
        } else {
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
            noticeConsoleChan($self, $message->prefix . " cstat command denied (user not authenticated)");
        }
    }
}


# Add a new user with a specified hostmask and optional level
sub addUser(@) {
    my ($self, $message, $sNick, @tArgs) = @_;
    my $bNotify = 0;

    # Handle optional -n flag for notification
    if (defined($tArgs[0]) && ($tArgs[0] eq "-n")) {
        $bNotify = 1;
        shift @tArgs;
    }

    my $user = $self->get_user_from_message($message);
    return unless $user;

    if ($user->is_authenticated) {
        if (checkUserLevel($self, $user->level, "Master")) {

            # Expecting at least username and hostmask
            if (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "") {
                my ($new_username, $new_hostmask, $new_level) = @tArgs;
                $new_level = "User" unless defined($new_level) && $new_level ne "";

                # Validate level
                if (defined($new_level) && getIdUserLevel($self, $new_level)) {
                    if ($user->level_description eq "Master" && $new_level eq "Owner") {
                        botNotice($self, $sNick, "Masters cannot add a user with Owner level");
                        logBot($self, $message, undef, "adduser", "Masters cannot add a user with Owner level");
                        return;
                    }
                } else {
                    botNotice($self, $sNick, "$new_level is not a valid user level");
                    return;
                }

                # Check if user already exists
                my $existing_id = getIdUser($self, $new_username);
                if (defined($existing_id)) {
                    botNotice($self, $sNick, "User $new_username already exists (id_user: $existing_id)");
                    logBot($self, $message, undef, "adduser", "User $new_username already exists (id_user: $existing_id)");
                    return;
                }

                # Add user
                my $new_id = userAdd($self, $new_hostmask, $new_username, undef, $new_level);
                if (defined($new_id)) {
                    my $msg = sprintf("Added user %s id_user: %d with hostmask %s (Level: %s)", $new_username, $new_id, $new_hostmask, $new_level);
                    $self->{logger}->log(0, "addUser() $msg");
                    noticeConsoleChan($self, $msg);
                    botNotice($self, $sNick, $msg);

                    if ($bNotify) {
                        botNotice($self, $new_username, "You've been added to " . $self->{irc}->nick_folded . " as user $new_username (Level: $new_level) with hostmask $new_hostmask");
                        botNotice($self, $new_username, "/msg " . $self->{irc}->nick_folded . " pass password");
                        botNotice($self, $new_username, "Replace 'password' with something strong and that you won't forget :p");
                    }

                    logBot($self, $message, undef, "adduser", $msg);
                } else {
                    botNotice($self, $sNick, "Could not add user $new_username");
                }

            } else {
                botNotice($self, $sNick, "Syntax: adduser [-n] <username> <hostmask> [level]");
            }

        } else {
            my $msg = $message->prefix . " adduser command attempt, (command level [Master] required for user " . $user->nickname . " [" . $user->level . "])";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "This command is not available for your level. Contact a bot master.");
            logBot($self, $message, undef, "adduser", $msg);
        }

    } else {
        my $msg = $message->prefix . " adduser command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
        logBot($self, $message, undef, "adduser", $msg);
    }
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

sub userStats(@) {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    return unless $user;

    if ($user->is_authenticated) {
        if (checkUserLevel($self, $user->level, "Master")) {

            # Total user count
            my $sQuery = "SELECT COUNT(*) AS nbUsers FROM USER";
            my $sth = $self->{dbh}->prepare($sQuery);

            unless ($sth->execute()) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
                return;
            }

            my $nbUsers = 0;
            if (my $ref = $sth->fetchrow_hashref()) {
                $nbUsers = $ref->{'nbUsers'} // 0;
            }
            $sth->finish;

            # Count per level
            $sQuery = "SELECT description, COUNT(nickname) AS nbUsers FROM USER, USER_LEVEL WHERE USER.id_user_level = USER_LEVEL.id_user_level GROUP BY description ORDER BY level";
            $sth = $self->{dbh}->prepare($sQuery);

            unless ($sth->execute()) {
                $self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
                return;
            }

            my @lines;
            push @lines, "Number of users: $nbUsers";

            while (my $ref = $sth->fetchrow_hashref()) {
                my $desc = $ref->{'description'} // 'Unknown';
                my $count = $ref->{'nbUsers'} // 0;
                push @lines, "$desc ($count)";
            }
            $sth->finish;

            # Response
            foreach my $line (@lines) {
                botNotice($self, $sNick, $line);
            }

        } else {
            my $sNoticeMsg = $message->prefix . " users command attempt (command level [Master] for user " . $user->nickname . " [" . $user->level . "])";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "Your level does not allow you to use this command.");
        }
    } else {
        my $sNoticeMsg = $message->prefix . " users command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
    }
}


sub userInfo(@) {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    return unless $user;

    if ($user->is_authenticated) {
        if (checkUserLevel($self, $user->level, "Master")) {

            if (defined($tArgs[0]) && $tArgs[0] ne "") {
                my $sTargetUser = $tArgs[0];

                my $sQuery = "SELECT * FROM USER, USER_LEVEL WHERE USER.id_user_level = USER_LEVEL.id_user_level AND nickname LIKE ? LIMIT 1";
                my $sth = $self->{dbh}->prepare($sQuery);

                unless ($sth->execute($sTargetUser)) {
                    $self->{logger}->log(1, "userInfo() SQL Error: $DBI::errstr | Query: $sQuery");
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
                    my $sPassStatus = defined($password) ? "Password set" : "Password is not set";
                    my $sAutoLogin  = ($username eq "#AUTOLOGIN#") ? "ON" : "OFF";

                    botNotice($self, $sNick, "User: $nickname (Id: $id_user - $desc)");
                    botNotice($self, $sNick, "Created: $created | Last login: $last_login");
                    botNotice($self, $sNick, "$sPassStatus | Status: $sAuthStatus | AUTOLOGIN: $sAutoLogin");
                    botNotice($self, $sNick, "Hostmasks: $hostmasks");
                    botNotice($self, $sNick, "Info: $info1 | $info2");

                } else {
                    botNotice($self, $sNick, "User '$sTargetUser' does not exist.");
                }

                my $sNoticeMsg = $message->prefix . " userinfo on $sTargetUser";
                $self->{logger}->log(0, $sNoticeMsg);
                noticeConsoleChan($self, $sNoticeMsg);
                logBot($self, $message, undef, "userinfo", $sNoticeMsg);

                $sth->finish;

            } else {
                botNotice($self, $sNick, "Syntax: userinfo <username>");
            }

        } else {
            my $sNoticeMsg = $message->prefix . " userinfo command attempt (level required: Master, actual: " . $user->level . " [" . $user->nickname . "])";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "This command is not available for your level.");
            logBot($self, $message, undef, "userinfo", $sNoticeMsg);
        }
    } else {
        my $sNoticeMsg = $message->prefix . " userinfo command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "You must be logged in: /msg " . $self->{irc}->nick_folded . " login username password");
        logBot($self, $message, undef, "userinfo", $sNoticeMsg);
    }
}


sub addUserHost(@) {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    return unless $user;

    if ($user->is_authenticated) {
        if (checkUserLevel($self, $user->level, "Master")) {

            if (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "") {

                my $sTargetUser   = $tArgs[0];
                my $sNewHostmask  = $tArgs[1];
                $sNewHostmask =~ s/[;]//g;

                $self->{logger}->log(3, "addUserHost() $sTargetUser $sNewHostmask");

                my $id_user = getIdUser($self, $sTargetUser);
                unless (defined($id_user)) {
                    botNotice($self, $sNick, "User $sTargetUser does not exist");
                    logBot($self, $message, undef, "addhost", "User $sTargetUser does not exist");
                    return;
                }

                # Get current hostmasks
                my $sQuery = "SELECT hostmasks FROM USER WHERE id_user = ?";
                my $sth = $self->{dbh}->prepare($sQuery);

                unless ($sth->execute($id_user)) {
                    $self->{logger}->log(1, "addUserHost() SQL Error : $DBI::errstr | Query: $sQuery");
                    return;
                }

                my $sHostmasks = "";
                if (my $ref = $sth->fetchrow_hashref()) {
                    $sHostmasks = $ref->{hostmasks} // "";
                }
                $sth->finish;

                my @tHostmasks = grep { $_ ne "" } map { s/^\s+|\s+$//gr } split /,/, $sHostmasks;

                if (grep { $_ eq $sNewHostmask } @tHostmasks) {
                    my $msg = $message->prefix . " Hostmask $sNewHostmask already exists for user $sTargetUser";
                    $self->{logger}->log(0, $msg);
                    noticeConsoleChan($self, $msg);
                    logBot($self, $message, undef, "addhost", $msg);
                    return;
                }

                push @tHostmasks, $sNewHostmask;
                my $sUpdatedHostmasks = join(",", @tHostmasks);

                # Update hostmasks
                $sQuery = "UPDATE USER SET hostmasks = ? WHERE id_user = ?";
                $sth = $self->{dbh}->prepare($sQuery);
                if ($sth->execute($sUpdatedHostmasks, $id_user)) {
                    my $msg = $message->prefix . " Hostmask $sNewHostmask added for user $sTargetUser";
                    $self->{logger}->log(0, $msg);
                    noticeConsoleChan($self, $msg);
                    logBot($self, $message, undef, "addhost", $msg);
                } else {
                    $self->{logger}->log(1, "addUserHost() SQL Error : $DBI::errstr | Query: $sQuery");
                }
                $sth->finish;

            } else {
                botNotice($self, $sNick, "Syntax: addhost <username> <hostmask>");
            }

        } else {
            my $msg = $message->prefix . " addhost command attempt, (level required: Master, actual: " . $user->level . " for " . $user->nickname . ")";
            noticeConsoleChan($self, $msg);
            botNotice($self, $sNick, "This command is not available for your level. Contact a bot master.");
            logBot($self, $message, undef, "addhost", $msg);
        }
    } else {
        my $msg = $message->prefix . " addhost command attempt (user " . $user->nickname . " not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged in to use this command: /msg " . $self->{irc}->nick_folded . " login <username> <password>");
        logBot($self, $message, undef, "addhost", $msg);
    }
}



sub addChannel(@) {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Auth check via Mediabot::User
    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Arguments
    my ($sChannel, $sUser) = @tArgs;
    unless ($sChannel && $sUser && $sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: addchan <#channel> <user>");
        return;
    }

    $self->{logger}->log(0, "$sNick issued addchan command: $sChannel $sUser");

    # Check if target user exists
    my $id_target_user = getIdUser($self, $sUser);
    unless ($id_target_user) {
        botNotice($self, $sNick, "User $sUser does not exist");
        return;
    }

    # Build channel object
    my $channel = Mediabot::Channel->new({
        name => $sChannel,
        dbh  => $self->{dbh},
        irc  => $self->{irc},
    });

    if (my $existing_id = $channel->exists_in_db) {
        botNotice($self, $sNick, "Channel $sChannel already exists");
        return;
    }

    # Create new channel
    my $id_channel = $channel->create_in_db;
    unless ($id_channel) {
        $self->{logger}->log(1, "addChannel() failed SQL insert for $sChannel");
        botNotice($self, $sNick, "Error: failed to create channel $sChannel in DB.");
        return;
    }

    # Store object in channel hash
    $self->{channels}{lc($sChannel)} = $channel;

    # Join + register
    joinChannel($self, $sChannel, undef);
    my $registered = registerChannel($self, $message, $sNick, $id_channel, $id_target_user);

    unless ($registered) {
        $self->{logger}->log(1, "registerChannel failed $sChannel $sUser");
        botNotice($self, $sNick, "Channel created but registration with user $sUser failed.");
    } else {
        $self->{logger}->log(0, "registerChannel successful $sChannel $sUser");
        botNotice($self, $sNick, "Channel $sChannel added and linked to $sUser.");
    }

    logBot($self, $message, undef, "addchan", ($sChannel, @tArgs));
    noticeConsoleChan($self, $message->prefix . " addchan command " . $user->nickname . " added $sChannel (id_channel: $id_channel)");

    return $id_channel;
}


sub channelSetSyntax(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	botNotice($self,$sNick,"Syntax: chanset [#channel] key <key>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] chanmode <+chanmode>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] description <description>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] auto_join <on|off>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] <+value|-value>");
}

sub channelSet {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc,
        $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd,
        $sMatchingUserInfo1, $sMatchingUserInfo2) = getNickInfo($self, $message);

    if (defined($iMatchingUserId)) {
        if ($iMatchingUserAuth) {

            if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
                $sChannel = shift @tArgs;
            }

            unless (defined $sChannel) {
                channelSetSyntax($self, $message, $sNick, @tArgs);
                return;
            }

            if (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
                || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 450)) {

                if ((defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "")
                    || (defined($tArgs[0]) && $tArgs[0] =~ /^[+-]/)) {

                    if (exists $self->{channels}{$sChannel}) {
                        my $channel = $self->{channels}{$sChannel};
                        my $id_channel = $channel->get_id;

                        # Gestion par mot-clé
                        if ($tArgs[0] eq "key") {
                            $channel->set_key($tArgs[1]);
                            botNotice($self, $sNick, "Set $sChannel key $tArgs[1]");
                        }
                        elsif ($tArgs[0] eq "chanmode") {
                            $channel->set_chanmode($tArgs[1]);
                            botNotice($self, $sNick, "Set $sChannel chanmode $tArgs[1]");
                        }
                        elsif ($tArgs[0] eq "auto_join") {
                            my $flag = lc($tArgs[1]) eq "on" ? 1 : (lc($tArgs[1]) eq "off" ? 0 : undef);
                            if (!defined $flag) {
                                channelSetSyntax($self, $message, $sNick, @tArgs);
                                return;
                            }
                            $channel->set_auto_join($flag);
                            botNotice($self, $sNick, "Set $sChannel auto_join $tArgs[1]");
                        }
                        elsif ($tArgs[0] eq "description") {
                            shift @tArgs;
                            if ($tArgs[0] =~ /console/i) {
                                botNotice($self, $sNick, "You cannot set $sChannel description to $tArgs[0]");
                            } else {
                                my $desc = join(" ", @tArgs);
                                $channel->set_description($desc);
                                botNotice($self, $sNick, "Set $sChannel description $desc");
                            }
                        }

                        # Gestion des +/-
                        elsif ($tArgs[0] =~ /^([+-])(\w+)$/) {
                            my ($op, $chanset) = ($1, $2);
                            my $id_chanset_list = getIdChansetList($self, $chanset);
                            unless ($id_chanset_list) {
                                botNotice($self, $sNick, "Undefined chanset $chanset");
                                return;
                            }
                            my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
                            if ($op eq "+") {
                                if ($id_channel_set) {
                                    botNotice($self, $sNick, "Chanset +$chanset is already set");
                                    return;
                                }
                                my $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL_SET (id_channel, id_chanset_list) VALUES (?, ?)");
                                $sth->execute($id_channel, $id_chanset_list);
                                botNotice($self, $sNick, "Chanset +$chanset applied to $sChannel");

                                setChannelAntiFlood($self, $message, $sNick, $sChannel, @tArgs) if $chanset =~ /^AntiFlood$/i;
                                set_hailo_channel_ratio($self, $sChannel, 97) if $chanset =~ /^HailoChatter$/i;
                            } else {
                                unless ($id_channel_set) {
                                    botNotice($self, $sNick, "Chanset +$chanset is not set");
                                    return;
                                }
                                my $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL_SET WHERE id_channel_set=?");
                                $sth->execute($id_channel_set);
                                botNotice($self, $sNick, "Chanset -$chanset removed from $sChannel");
                            }
                        }
                        else {
                            channelSetSyntax($self, $message, $sNick, @tArgs);
                        }

                        logBot($self, $message, $sChannel, "chanset", ($sChannel, @tArgs));
                        return $channel->get_id;
                    } else {
                        $self->{logger}->log(3, "channelSet: channel $sChannel not found in hash");
                    }
                }
                else {
                    channelSetSyntax($self, $message, $sNick, @tArgs);
                }
            }
            else {
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
            }
        }
        else {
            botNotice($self, $sNick, "You must be logged in to use this command.");
        }
    }
}



sub getIdChansetList(@) {
	my ($self,$sChansetValue) = @_;
	my $id_chanset_list;
	my $sQuery = "SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChansetValue) ) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_chanset_list = $ref->{'id_chanset_list'};
		}
	}
	$sth->finish;
	return $id_chanset_list;
}

sub getIdChannelSet(@) {
	my ($self,$sChannel,$id_chanset_list) = @_;
	my $id_channel_set;
	my $sQuery = "SELECT id_channel_set FROM CHANNEL_SET,CHANNEL WHERE CHANNEL_SET.id_channel=CHANNEL.id_channel AND name=? AND id_chanset_list=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_chanset_list) ) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_channel_set = $ref->{'id_channel_set'};
		}
	}
	$sth->finish;
	return $id_channel_set;
}

# Purge a channel from the bot: delete it and archive its data
# Only accessible by authenticated users with Administrator level
sub purgeChannel {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Get user object from message prefix (hostmask-based matching)
    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        $self->noticeConsoleChan($message->prefix . " purge command attempt (unauthenticated user)");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        $self->noticeConsoleChan($message->prefix . " purge command attempt (user " . $user->nickname . " level: " . $user->level . ")");
        return;
    }

    # Validate channel argument
    my $sChannel = $tArgs[0] // '';
    unless ($sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: purge <#channel>");
        return;
    }

    # Check if the bot knows about this channel
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    $self->{logger}->log(0, "$sNick issued a purge command on $sChannel");

    # Retrieve full channel info from DB
    my $sth = $self->{dbh}->prepare("SELECT * FROM CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr while fetching channel info");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;
    unless ($ref) {
        $self->{logger}->log(1, "Channel $sChannel (id: $id_channel) not found in DB");
        return;
    }

    # Extract values for archiving
    my ($desc, $key, $chanmode, $auto_join) = @$ref{qw(description key chanmode auto_join)};

    # Delete from CHANNEL
    $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr while deleting CHANNEL");
        return;
    }

    # Delete user-channel links
    $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr while deleting USER_CHANNEL");
        return;
    }

    # Archive into CHANNEL_PURGED
    $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL_PURGED (id_channel, name, description, `key`, chanmode, auto_join) VALUES (?, ?, ?, ?, ?, ?)");
    unless ($sth->execute($id_channel, $sChannel, $desc, $key, $chanmode, $auto_join)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr while inserting into CHANNEL_PURGED");
        return;
    }

    # Part from IRC and clean memory
    $self->partChannel($sChannel, "Channel purged by $sNick");
    delete $self->{channels}{$sChannel};

    # Log action
    $self->logBot($message, undef, "purge", "$sNick purged $sChannel (id: $id_channel)");
}


# Channel part command (refactored)
sub channelPart {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "Unknown user or no matching hostmask.");
        return;
    }

    unless ($user->is_authenticated) {
        my $notice = $message->prefix . " part command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Argument extraction
    if (!defined($sChannel) || (defined($tArgs[0]) && $tArgs[0] ne "")) {
        if (defined($tArgs[0]) && $tArgs[0] ne "" && $tArgs[0] =~ /^#/) {
            $sChannel = $tArgs[0];
            shift @tArgs;
        } else {
            botNotice($self, $sNick, "Syntax: part <#channel>");
            return;
        }
    }

    # Check privileges
    if (
        checkUserLevel($self, $user->level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user->id, 500)
    ) {
        my $channel_obj = $self->{channels}{$sChannel};
        if ($channel_obj) {
            $self->{logger}->log(0, "$sNick issued a part $sChannel command");
            partChannel($self, $sChannel, "At the request of " . $user->nickname);
            logBot($self, $message, $sChannel, "part", "At the request of " . $user->nickname);
        } else {
            botNotice($self, $sNick, "Channel $sChannel does not exist");
        }
    } else {
        my $notice = $message->prefix . " part command attempt for user " . $user->nickname . " [" . ($user->level_description // '?') . "]";
        noticeConsoleChan($self, $notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
    }
}


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

# Join a channel with its key if one exists, or without if not
# Requires user to be authenticated and have Administrator or high channel level
sub channelJoin {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Retrieve user object from IRC message prefix
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        $self->noticeConsoleChan($message->prefix . " join command attempt (unauthenticated)");
        return;
    }

    my $sChannel = $tArgs[0] // '';
    unless ($sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: join <#channel>");
        return;
    }
    shift @tArgs;

    # Check user level: global Administrator or per-channel >= 450
    unless (checkUserLevel($self, $user->level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user->id, 450)) {
        
        $self->noticeConsoleChan($message->prefix . " join command attempt for user " . $user->handle . " [level: " . $user->level . "]");
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Ensure the channel exists in memory
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    $self->{logger}->log(0, "$sNick issued a join $sChannel command");

    # Fetch channel key if any
    my $sKey;
    my $sth = $self->{dbh}->prepare("SELECT `key` FROM CHANNEL WHERE id_channel = ?");
    if ($sth->execute($id_channel)) {
        if (my $ref = $sth->fetchrow_hashref) {
            $sKey = $ref->{key};
        }
        $sth->finish;
    } else {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr while fetching key for $sChannel");
    }

    # Join with or without key
    joinChannel($self, $sChannel, $sKey || undef);

    # Log the action
    logBot($self, $message, $sChannel, "join", "");
}

# Add a user to a channel with a specific level
# Requires the calling user to be authenticated and to have sufficient rights on the channel
sub channelAddUser {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get the user object from the IRC message prefix
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        $self->noticeConsoleChan($message->prefix . " add user command attempt (unauthenticated)");
        return;
    }

    # Extract channel name from args if not provided directly
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    # Check if the user has enough privileges (admin or ≥400 on that channel)
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 400)
    ) {
        my $notice = $message->prefix . " add user command attempt for user " . $user->handle . " [level " . $user->level . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Syntax check
    unless (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] =~ /^\d+$/) {
        botNotice($self, $sNick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    my $sTargetHandle = $tArgs[0];
    my $iTargetLevel  = $tArgs[1];

    # Retrieve channel object
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Get target user ID
    my $id_target_user = getIdUser($self, $sTargetHandle);
    unless ($id_target_user) {
        botNotice($self, $sNick, "User $sTargetHandle does not exist");
        return;
    }

    # Check if the user is already registered on this channel
    my $existing_level = getUserChannelLevel($self, $message, $sChannel, $id_target_user);
    if ($existing_level != 0) {
        botNotice($self, $sNick, "User $sTargetHandle is already on $sChannel with level $existing_level");
        return;
    }

    # Prevent the user from assigning levels higher or equal to theirs (unless admin)
    if (
        $iTargetLevel < getUserChannelLevel($self, $message, $sChannel, $user->id) ||
        checkUserLevel($self, $user->level, "Administrator")
    ) {
        my $sth = $self->{dbh}->prepare("INSERT INTO USER_CHANNEL (id_user, id_channel, level) VALUES (?, ?, ?)");
        unless ($sth->execute($id_target_user, $id_channel, $iTargetLevel)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr while inserting USER_CHANNEL");
        } else {
            $self->{logger}->log(0, "$sNick added $sTargetHandle to $sChannel at level $iTargetLevel");
            logBot($self, $message, $sChannel, "add", @tArgs);
        }
        $sth->finish;
    } else {
        botNotice($self, $sNick, "You can't assign a level equal or higher than yours.");
    }
}


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
# Requires authenticated user with admin or high-level access on the channel
sub channelDelUser {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user object from IRC message
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        $self->noticeConsoleChan($message->prefix . " del user command attempt (unauthenticated)");
        return;
    }

    # Extract channel from arguments if needed
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless ($sChannel) {
        botNotice($self, $sNick, "Syntax: del <#channel> <handle>");
        return;
    }

    # Get channel object
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    # Check user permission: admin or level ≥ 400 on the channel
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 400)
    ) {
        my $sNoticeMsg = $message->prefix . " del user command attempt by " . $user->handle . " [level " . $user->level . "]";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Target handle required
    my $sTargetHandle = $tArgs[0];
    unless ($sTargetHandle) {
        botNotice($self, $sNick, "Syntax: del <#channel> <handle>");
        return;
    }

    # Resolve target user ID
    my $id_target = getIdUser($self, $sTargetHandle);
    unless (defined $id_target) {
        botNotice($self, $sNick, "User $sTargetHandle does not exist");
        return;
    }

    # Get current target user's level on the channel
    my $level_target = getUserChannelLevel($self, $message, $sChannel, $id_target);
    unless ($level_target) {
        botNotice($self, $sNick, "User $sTargetHandle does not appear to have access on $sChannel");
        return;
    }

    # Ensure caller has higher level than the target
    my $level_issuer = getUserChannelLevel($self, $message, $sChannel, $user->id);
    unless ($level_target < $level_issuer || checkUserLevel($self, $user->level, "Administrator")) {
        botNotice($self, $sNick, "You can't del a user with a level equal or greater than yours");
        return;
    }

    # Proceed to deletion from USER_CHANNEL
    my $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_user=? AND id_channel=?");
    unless ($sth->execute($id_target, $channel_obj->get_id)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    logBot($self, $message, $sChannel, "del", $sTargetHandle);
    botNotice($self, $sNick, "User $sTargetHandle removed from $sChannel");
}


# User modinfo syntax notification
sub userModinfoSyntax(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	botNotice($self,$sNick,"Syntax: modinfo [#channel] automode <user> <voice|op|none>");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] greet <user> <greet> (use keyword \"none\" for <greet> to remove it)");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] level <user> <level>");
}

# Modify user info (level, automode, greet) on a specific channel
sub userModinfo {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load user object from IRC hostmask
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " modinfo command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel if passed as first argument
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        userModinfoSyntax($self, $message, $sNick, @tArgs);
        return;
    }

    # Ensure channel object exists
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    # Permission check: Administrator, 400+ on channel, or greet with 1+
    my $has_access =
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 400) ||
        (
            defined $tArgs[0] &&
            $tArgs[0] =~ /^greet$/i &&
            checkUserChannelLevel($self, $message, $sChannel, $user->id, 1)
        );

    unless ($has_access) {
        my $notice = $message->prefix . " modinfo command attempt by " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Syntax validation
    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && defined $tArgs[2] && $tArgs[2] ne "") {
        userModinfoSyntax($self, $message, $sNick, @tArgs);
        return;
    }

    my $id_channel = $channel_obj->get_id;
    my ($id_user_target, $level_target) = getIdUserChannelLevel($self, $tArgs[1], $sChannel);
    my $user_target_handle = $tArgs[1];

    unless (defined $id_user_target) {
        botNotice($self, $sNick, "User $user_target_handle does not exist on $sChannel");
        return;
    }

    my (undef, $user_level_on_channel) = getIdUserChannelLevel($self, $user->handle, $sChannel);

    unless (
        $user_level_on_channel > $level_target ||
        checkUserLevel($self, $user->level, "Administrator") ||
        ($tArgs[0] =~ /^greet$/i && $user_level_on_channel > 0)
    ) {
        botNotice($self, $sNick, "Cannot modify a user with equal or higher access than your own.");
        return;
    }

    my $type = lc($tArgs[0]);
    my $sth;

    SWITCH: {
        $type eq "automode" and do {
            my $mode = uc($tArgs[2]);
            unless ($mode =~ /^(OP|VOICE|NONE)$/i) {
                userModinfoSyntax($self, $message, $sNick, @tArgs);
                last SWITCH;
            }

            my $query = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($mode, $id_user_target, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error: $DBI::errstr Query: $query");
                return;
            }

            botNotice($self, $sNick, "Set automode $mode on $sChannel for $user_target_handle");
            logBot($self, $message, $sChannel, "modinfo", @tArgs);
            return $id_channel;
        };

        $type eq "greet" and do {
            if (
                $user_level_on_channel < 400 &&
                $user_target_handle ne $user->handle &&
                !checkUserLevel($self, $user->level, "Administrator")
            ) {
                botNotice($self, $sNick, "Your level does not allow you to perform this command.");
                last SWITCH;
            }

            splice @tArgs, 0, 2;
            my $greet_msg = (scalar @tArgs == 1 && $tArgs[0] =~ /none/i) ? undef : join(" ", @tArgs);

            my $query = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($greet_msg, $id_user_target, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error: $DBI::errstr Query: $query");
                return;
            }

            botNotice($self, $sNick, "Set greet (" . ($greet_msg // "none") . ") on $sChannel for $user_target_handle");
            logBot($self, $message, $sChannel, "modinfo", ("greet $user_target_handle", @tArgs));
            return $id_channel;
        };

        $type eq "level" and do {
            my $new_level = $tArgs[2];
            unless ($new_level =~ /^\d+$/ && $new_level <= 500) {
                botNotice($self, $sNick, "Cannot set user access higher than 500.");
                last SWITCH;
            }

            my $query = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($new_level, $id_user_target, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error: $DBI::errstr Query: $query");
                return;
            }

            botNotice($self, $sNick, "Set level $new_level on $sChannel for $user_target_handle");
            logBot($self, $message, $sChannel, "modinfo", @tArgs);
            return $id_channel;
        };

        # Unknown type
        userModinfoSyntax($self, $message, $sNick, @tArgs);
    }

    return;
}


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

# Give +o operator mode to a user on a channel
sub userOpChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load user object from IRC hostmask
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " op command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if it's the first element
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: op #channel <nick>");
        return;
    }

    # Check privileges: must be Administrator or have at least 100 access level on channel
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 100)
    ) {
        my $notice = $message->prefix . " op command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Check channel existence
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine the target nick for +o
    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    # Send MODE +o
    $self->{irc}->send_message("MODE", undef, ($sChannel, "+o", $target_nick));
    logBot($self, $message, $sChannel, "op", @tArgs);

    return $id_channel;
}


# Remove +o operator mode from a user on a channel
sub userDeopChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load authenticated user from message
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " deop command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if needed
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: deop #channel <nick>");
        return;
    }

    # Check global or channel privileges
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 100)
    ) {
        my $notice = $message->prefix . " deop command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Check channel existence
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine who gets -o
    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "-o", $target_nick));
    logBot($self, $message, $sChannel, "deop", @tArgs);

    return $id_channel;
}


# Invite a user to a channel if the issuer has the required permissions
sub userInviteChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load authenticated user from message
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " invite command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if needed
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: invite #channel <nick>");
        return;
    }

    # Check global or per-channel privileges
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 100)
    ) {
        my $notice = $message->prefix . " invite command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Get channel object
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine who to invite
    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("INVITE", undef, ($target_nick, $sChannel));
    logBot($self, $message, $sChannel, "invite", @tArgs);

    return $id_channel;
}


# Give +v (voice) to a user on a given channel, if issuer has proper rights
sub userVoiceChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load authenticated user from message prefix
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " voice command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if needed
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: voice #channel <nick>");
        return;
    }

    # Check privileges: global admin OR channel-level 25+
    unless (
        checkUserLevel($self, $user->level, "Administrator") ||
        checkUserChannelLevel($self, $message, $sChannel, $user->id, 25)
    ) {
        my $notice = $message->prefix . " voice command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Load channel object
    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine target nick to voice (default to issuer)
    my $target_nick = (defined $tArgs[0] && $tArgs[0] ne "") ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "+v", $target_nick));
    logBot($self, $message, $sChannel, "voice", @tArgs);

    return $id_channel;
}


# Remove +v (voice) from a user on a given channel, if issuer has proper rights
sub userDevoiceChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load authenticated user from message prefix
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " devoice command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: devoice #channel <nick>");
        return;
    }

    # Check privileges: global admin OR channel-level 25+
    unless (
        checkUserLevel($self, $user->level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user->id, 25)
    ) {
        my $notice = $message->prefix . " devoice command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Check that the channel exists
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine who gets -v (default to issuer)
    my $target_nick = (defined $tArgs[0] && $tArgs[0] ne "") ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "-v", $target_nick));
    logBot($self, $message, $sChannel, "devoice", @tArgs);

    return $id_channel;
}


# Kick a user from a channel, with an optional reason, if the issuer has proper rights
sub userKickChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Load user object from IRC message prefix
    my $user = $self->get_user_from_message($message);

    # Abort if user is not authenticated
    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " kick command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: kick #channel <nick> [reason]");
        return;
    }

    # Check user privileges: global admin or channel-level >= 50
    unless (
        checkUserLevel($self, $user->level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user->id, 50)
    ) {
        my $notice = $message->prefix . " kick command attempt for user " . $user->handle . " [" . $user->level_desc . "]";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Get channel object
    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Check target nick
    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: kick #channel <nick> [reason]");
        return;
    }

    # Extract target nick and optional reason
    my $sKickNick   = shift @tArgs;
    my $sKickReason = join(" ", @tArgs) // "";
    my $sFinalMsg   = "(" . $user->handle . ") $sKickReason";

    # Send kick command to IRC server
    $self->{logger}->log(0, "$sNick issued a kick $sChannel command");
    $self->{irc}->send_message("KICK", undef, ($sChannel, $sKickNick, $sFinalMsg));
    logBot($self, $message, $sChannel, "kick", ($sKickNick, @tArgs));

    return $id_channel;
}


# Set the topic of a channel if the user has the appropriate privileges
sub userTopicChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user object from IRC message prefix
    my $user = $self->get_user_from_message($message);

    # Abort if user not authenticated
    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " topic command attempt (unauthenticated)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
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
    unless (
        checkUserLevel($self, $user->level, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $user->id, 50)
    ) {
        my $notice = $message->prefix . " topic command attempt by " . $user->handle . " [level: " . $user->level_desc . "]";
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



# Show available commands to the user for a specific channel
sub userShowcommandsChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user object from the IRC message
    my $user = $self->get_user_from_message($message);

    # If no user found, show only public commands
    unless ($user) {
        botNotice($self, $sNick, "Level   0: access chaninfo login pass newpass ident showcommands");
        return;
    }

    # Check if user is logged in
    unless ($user->is_authenticated) {
        my $notice = $message->prefix . " showcommands attempt (user " . $user->handle . " is not logged in)";
        $self->noticeConsoleChan($notice);
        logBot($self, $message, $sChannel, "showcommands", @tArgs);

        botNotice($self, $sNick, "You must be logged to see available commands for your level - /msg " . $self->{irc}->nick_folded . " login username password");
        botNotice($self, $sNick, "Level   0: access chaninfo login pass ident showcommands");
        return;
    }

    # Extract channel from args if needed
    if (!defined($sChannel) || (defined($tArgs[0]) && $tArgs[0] ne "")) {
        if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
            $sChannel = shift @tArgs;
        } else {
            botNotice($self, $sNick, "Syntax: showcommands #channel");
            return;
        }
    }

    # Check if user is a global admin
    my $isAdmin = checkUserLevel($self, $user->level, "Administrator");

    my $notice = "Available commands on $sChannel";
    $notice .= " (because you are a global admin)" if $isAdmin;

    $self->noticeConsoleChan($message->prefix . " showcommands on $sChannel");
    logBot($self, $message, $sChannel, "showcommands", @tArgs);
    botNotice($self, $sNick, $notice);

    # Get user level on the channel
    my ($id_user, $level) = getIdUserChannelLevel($self, $user->handle, $sChannel);

    # Show commands by level (falling through if admin)
    if ($isAdmin || $level >= 500) {
        botNotice($self, $sNick, "Level 500: part");
    }
    if ($isAdmin || $level >= 450) {
        botNotice($self, $sNick, "Level 450: join chanset");
    }
    if ($isAdmin || $level >= 400) {
        botNotice($self, $sNick, "Level 400: add del modinfo");
    }
    if ($isAdmin || $level >= 100) {
        botNotice($self, $sNick, "Level 100: op deop invite");
    }
    if ($isAdmin || $level >= 50) {
        botNotice($self, $sNick, "Level  50: kick topic");
    }
    if ($isAdmin || $level >= 25) {
        botNotice($self, $sNick, "Level  25: voice devoice");
    }

    # Always show public commands
    botNotice($self, $sNick, "Level   0: access chaninfo login pass newpass ident showcommands");
}


# Show detailed info about a registered channel
sub userChannelInfo {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Extract channel from args if needed
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: chaninfo #channel");
        return;
    }

    # Main SQL query: get channel info + owner (level 500)
    my $sQuery = q{
        SELECT * FROM USER, USER_CHANNEL, CHANNEL
         WHERE USER.id_user = USER_CHANNEL.id_user
           AND CHANNEL.id_channel = USER_CHANNEL.id_channel
           AND name = ?
           AND level = 500
    };
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute($sChannel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $sUsername      = $ref->{'nickname'};
        my $sLastLogin     = $ref->{'last_login'} // "Never";
        my $creation_date  = $ref->{'creation_date'} // "Unknown";
        my $description    = $ref->{'description'} // "No description";
        my $sKey           = $ref->{'key'} // "Not set";
        my $chanmode       = $ref->{'chanmode'} // "Not set";
        my $sAutoJoin      = $ref->{'auto_join'} ? "True" : "False";

        botNotice($self, $sNick, "$sChannel is registered by $sUsername - last login: $sLastLogin");
        botNotice($self, $sNick, "Creation date : $creation_date - Description : $description");

        # Optional admin-only info
        my $user = $self->get_user_from_message($message);
        if ($user && $user->is_authenticated && checkUserLevel($self, $user->level, "Master")) {
            botNotice($self, $sNick, "Chan modes : $chanmode - Key : $sKey - Auto join : $sAutoJoin");
        }

        # List CHANSET flags
        $sQuery = q{
            SELECT chanset FROM CHANSET_LIST, CHANNEL_SET, CHANNEL
             WHERE CHANNEL_SET.id_channel = CHANNEL.id_channel
               AND CHANNEL_SET.id_chanset_list = CHANSET_LIST.id_chanset_list
               AND name = ?
        };
        $sth = $self->{dbh}->prepare($sQuery);
        if ($sth->execute($sChannel)) {
            my $sChansetFlags = "Channel flags ";
            my $hasFlags = 0;
            my $isChansetAntiFlood = 0;

            while (my $ref = $sth->fetchrow_hashref()) {
                my $chanset = $ref->{'chanset'};
                $sChansetFlags .= "+$chanset ";
                $isChansetAntiFlood = 1 if $chanset =~ /AntiFlood/i;
                $hasFlags++;
            }

            botNotice($self, $sNick, $sChansetFlags) if $hasFlags;

            # If AntiFlood flag is present, fetch flood parameters
            if ($isChansetAntiFlood) {
                my $channel_obj = $self->{channels}{$sChannel};
                if ($channel_obj) {
                    my $id_channel = $channel_obj->get_id;
                    $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
                    $sth = $self->{dbh}->prepare($sQuery);
                    if ($sth->execute($id_channel)) {
                        if (my $ref = $sth->fetchrow_hashref()) {
                            my $nbmsg_max  = $ref->{'nbmsg_max'};
                            my $nbmsg      = $ref->{'nbmsg'};
                            my $duration   = $ref->{'duration'};
                            my $timetowait = $ref->{'timetowait'};
                            my $notif      = $ref->{'notification'};
                            my $notif_txt  = $notif ? "ON" : "OFF";

                            botNotice(
                                $self, $sNick,
                                "Antiflood parameters : $nbmsg_max messages in $duration seconds, wait for $timetowait seconds, notification : $notif_txt"
                            );
                        } else {
                            botNotice($self, $sNick, "Antiflood parameters : not set ?");
                        }
                    } else {
                        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
                    }
                } else {
                    botNotice($self, $sNick, "Antiflood details unavailable: internal channel object not found.");
                }
            }
        } else {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        }
    } else {
        botNotice($self, $sNick, "The channel $sChannel doesn't appear to be registered");
    }

    logBot($self, $message, $sChannel, "chaninfo", @tArgs);
    $sth->finish;
}


# List all known channels and user count (Master only)
sub channelList {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $sNoticeMsg = $message->prefix . " chanlist command attempt (user " . ($user ? $user->handle : 'unknown') . " is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Master")) {
        my $sNoticeMsg = $message->prefix . " chanlist command attempt (command level [Master] for user " . $user->handle . "[" . $user->level . "])";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $sQuery = q{
        SELECT name, COUNT(id_user) AS nbUsers
        FROM CHANNEL, USER_CHANNEL
        WHERE CHANNEL.id_channel = USER_CHANNEL.id_channel
        GROUP BY name
        ORDER BY creation_date
        LIMIT 20
    };
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute()) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    my $sNoticeMsg = "[#chan (users)] ";
    while (my $ref = $sth->fetchrow_hashref()) {
        my $name    = $ref->{'name'};
        my $nbUsers = $ref->{'nbUsers'};
        $sNoticeMsg .= "$name ($nbUsers) ";
    }

    botNotice($self, $sNick, $sNoticeMsg);
}


# Return info about the current authenticated user
sub userWhoAmI {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && defined $user->id) {
        botNotice($self, $sNick, "User not found with this hostmask");
        return;
    }

    my $sNoticeMsg = "User " . $user->handle . " (" . $user->level_desc . ")";

    my $sQuery = "SELECT password, hostmasks, creation_date, last_login FROM USER WHERE id_user=?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth->execute($user->id)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $sPasswordSet = defined($ref->{'creation_date'}) ? "Password set" : "Password not set";
        $sNoticeMsg .= " - created " . $ref->{'creation_date'} . " - last login " . ($ref->{'last_login'} // "never");

        botNotice($self, $sNick, $sNoticeMsg);
        botNotice($self, $sNick, $sPasswordSet);
        botNotice($self, $sNick, "Hostmasks : " . ($ref->{'hostmasks'} // "N/A"));
    }

    $sth->finish;

    my $sInfos = "Infos : ";
    $sInfos .= (defined $user->info1 ? $user->info1 : "N/A") . " - ";
    $sInfos .= (defined $user->info2 ? $user->info2 : "N/A");

    botNotice($self, $sNick, $sInfos);

    logBot($self, $message, undef, "whoami", @tArgs);
}


sub mbDbAddCommand {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " addcmd command attempt (user " . ($user ? $user->handle : 'unknown') . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->has_level("Administrator")) {
        my $notice = $message->prefix . " addcmd command attempt (command level [Administrator] for user " . $user->handle . " [" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    if (
        defined($tArgs[0]) && $tArgs[0] ne ""
        && defined($tArgs[1]) && $tArgs[1] =~ /^(message|action)$/i
        && defined($tArgs[2]) && $tArgs[2] ne ""
        && defined($tArgs[3]) && $tArgs[3] ne ""
    ) {
        my $sCommand  = shift @tArgs;
        my $sType     = shift @tArgs;
        my $sCategory = shift @tArgs;

        my $id_public_commands_category = getCommandCategory($self, $sCategory);
        unless (defined $id_public_commands_category) {
            botNotice($self, $sNick, "Unknown category : $sCategory");
            return;
        }

        my $query_check = "SELECT command FROM PUBLIC_COMMANDS WHERE command LIKE ?";
        my $sth = $self->{dbh}->prepare($query_check);
        unless ($sth->execute($sCommand)) {
            $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query_check");
            return;
        }

        if (my $ref = $sth->fetchrow_hashref()) {
            botNotice($self, $sNick, "$sCommand command already exists");
            $sth->finish;
            return;
        }

        $sth->finish;

        botNotice($self, $sNick, "Adding command $sCommand [$sType] " . join(" ", @tArgs));

        my $sAction = ($sType =~ /^message$/i) ? "PRIVMSG %c " : "ACTION %c ";
        $sAction .= join(" ", @tArgs);

        my $insert_query = "INSERT INTO PUBLIC_COMMANDS (id_user, id_public_commands_category, command, description, action) VALUES (?, ?, ?, ?, ?)";
        $sth = $self->{dbh}->prepare($insert_query);
        unless ($sth->execute($user->id, $id_public_commands_category, $sCommand, $sCommand, $sAction)) {
            $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $insert_query");
        } else {
            botNotice($self, $sNick, "Command $sCommand added");
            logBot($self, $message, undef, "addcmd", ("Command $sCommand added"));
        }

        $sth->finish;
    } else {
        botNotice($self, $sNick, "Syntax: addcmd <command> <message|action> <category> <text>");
        botNotice($self, $sNick, "Ex: m addcmd Hello message general Hello %n !");
    }
}

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

sub mbDbRemCommand {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " remcmd command attempt (user " . ($user ? $user->handle : 'unknown') . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->has_level("Administrator")) {
        my $notice = $message->prefix . " remcmd command attempt (command level [Administrator] for user " . $user->handle . " [" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: remcmd <command>");
        return;
    }

    my $sCommand = shift @tArgs;

    my $query = "SELECT id_user, id_public_commands FROM PUBLIC_COMMANDS WHERE command LIKE ?";
    my $sth = $self->{dbh}->prepare($query);
    unless ($sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $query");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_command_user = $ref->{id_user};
        my $id_public_commands = $ref->{id_public_commands};

        if ($id_command_user == $user->id || $user->has_level("Master")) {
            botNotice($self, $sNick, "Removing command $sCommand");

            my $delete_query = "DELETE FROM PUBLIC_COMMANDS WHERE id_public_commands=?";
            my $sth_del = $self->{dbh}->prepare($delete_query);
            unless ($sth_del->execute($id_public_commands)) {
                $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $delete_query");
                return;
            }

            botNotice($self, $sNick, "Command $sCommand removed");
            logBot($self, $message, undef, "remcmd", ("Command $sCommand removed"));
            $sth_del->finish;
        } else {
            botNotice($self, $sNick, "$sCommand command belongs to another user");
        }
    } else {
        botNotice($self, $sNick, "$sCommand command does not exist");
    }

    $sth->finish;
}


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


sub mbDbShowCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my $sCommand = $tArgs[0];
		my $sQuery = "SELECT hits,id_user,creation_date,action,PUBLIC_COMMANDS_CATEGORY.description as category FROM PUBLIC_COMMANDS,PUBLIC_COMMANDS_CATEGORY WHERE PUBLIC_COMMANDS.id_public_commands_category=PUBLIC_COMMANDS_CATEGORY.id_public_commands_category AND command LIKE ?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sCommand)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $id_user = $ref->{'id_user'};
				my $sCategory = $ref->{'category'};
				my $sUserHandle = "Unknown";
				my $sCreationDate = $ref->{'creation_date'};
				my $sAction = $ref->{'action'};
				my $hits = $ref->{'hits'};
				my $sHitsWord = ( $hits > 1 ? "$hits hits" : "0 hit" );
				if (defined($id_user)) {
					$sQuery = "SELECT * FROM USER WHERE id_user=?";
					my $sth2 = $self->{dbh}->prepare($sQuery);
					unless ($sth2->execute($id_user)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref2 = $sth2->fetchrow_hashref()) {
							$sUserHandle = $ref2->{'nickname'};
						}
					}
					$sth2->finish;
				}
				botNotice($self,$sNick,"Command : $sCommand Author : $sUserHandle Created : $sCreationDate");
				botNotice($self,$sNick,"$sHitsWord Category : $sCategory Action : $sAction");
			}
			else {
				botNotice($self,$sNick,"$sCommand command does not exist");
			}
			logBot($self,$message,undef,"showcmd",($sCommand));
		}
		$sth->finish;
	}
	else {
		botNotice($self,$sNick,"Syntax: showcmd <command>");
		return undef;
	}
}

sub mbChownCommand {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " chowncmd command attempt (user " . ($user ? $user->handle : 'unknown') . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->has_level("Master")) {
        my $notice = $message->prefix . " chowncmd command attempt (command level [Master] for user " . $user->handle . "[" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax: chowncmd <command> <username>");
        return;
    }

    my ($sCommand, $sTargetUser) = @tArgs;

    # Step 1: Get command info
    my $cmd_query = "SELECT PC.id_public_commands, PC.id_user AS old_user, U.nickname AS old_nick
                     FROM PUBLIC_COMMANDS PC
                     JOIN USER U ON PC.id_user = U.id_user
                     WHERE PC.command LIKE ?";
    my $sth = $self->{dbh}->prepare($cmd_query);
    unless ($sth->execute($sCommand)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $cmd_query");
        return;
    }

    my $cmd_info = $sth->fetchrow_hashref();
    unless ($cmd_info) {
        botNotice($self, $sNick, "$sCommand command does not exist");
        return;
    }

    my $id_cmd       = $cmd_info->{id_public_commands};
    my $id_old_user  = $cmd_info->{old_user};
    my $old_nickname = $cmd_info->{old_nick};

    # Step 2: Get new user
    my $user_query = "SELECT id_user FROM USER WHERE nickname LIKE ?";
    $sth = $self->{dbh}->prepare($user_query);
    unless ($sth->execute($sTargetUser)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $user_query");
        return;
    }

    my $target_user = $sth->fetchrow_hashref();
    unless ($target_user) {
        botNotice($self, $sNick, "$sTargetUser user does not exist");
        return;
    }

    my $id_new_user = $target_user->{id_user};

    # Step 3: Update owner
    my $update_query = "UPDATE PUBLIC_COMMANDS SET id_user=? WHERE id_public_commands=?";
    $sth = $self->{dbh}->prepare($update_query);
    unless ($sth->execute($id_new_user, $id_cmd)) {
        $self->{logger}->log(1, "SQL Error : $DBI::errstr Query : $update_query");
        return;
    }

    botNotice($self, $sNick, "Changed owner of command $sCommand ($old_nickname -> $sTargetUser)");
    logBot($self, $message, undef, "chowncmd", ("Changed owner of command $sCommand ($old_nickname -> $sTargetUser)"));

    $sth->finish;
}


# Show the number of lines sent on a channel during the last hour
sub channelStatLines {
    my ($self, $message, $sChannel, $sNick, @tArgs) = @_;

    # Get user object from message
    my $user = $self->get_user_from_message($message);

    # Require authentication
    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " chanstatlines command attempt (user " . ($user ? $user->handle : "unknown") . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged in to use this command — try: /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Require Administrator level
    unless ($user->has_level("Administrator")) {
        my $notice = $message->prefix . " chanstatlines command attempt (requires Administrator level for user " . $user->handle . "[" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Sorry, this command is reserved for Administrators.");
        return;
    }

    # Determine which channel we're analyzing
    my $target_channel;
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $target_channel = shift @tArgs;
    } elsif (defined $sChannel && $sChannel =~ /^#/) {
        $target_channel = $sChannel;
    } else {
        botNotice($self, $sNick, "Usage: chanstatlines <#channel>");
        return;
    }

    # Prepare SQL statement
    my $sql = <<'SQL';
SELECT COUNT(*) AS nb_lines
FROM CHANNEL_LOG
JOIN CHANNEL ON CHANNEL_LOG.id_channel = CHANNEL.id_channel
WHERE CHANNEL.name = ?
  AND ts > (NOW() - INTERVAL 1 HOUR)
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth->execute($target_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    # Fetch and display result
    if (my $row = $sth->fetchrow_hashref) {
        my $count = $row->{nb_lines} || 0;

        my $msg = ($count == 0)
            ? "It's been awfully quiet on $target_channel this past hour... Not a single line. ☕"
            : "📈 Activity report: $count " . ($count == 1 ? "line" : "lines") . " sent on $target_channel in the last hour.";

        botPrivmsg($self, $target_channel, $msg);
        logBot($self, $message, undef, "chanstatlines", $target_channel);
    } else {
        botNotice($self, $sNick, "Hmm... Channel $target_channel doesn't seem to be registered.");
    }

    $sth->finish;
}



# Display top talkers in a channel during the last hour.
# Automatically warns the most talkative user if flooding is detected.
sub whoTalk {
    my ($self, $message, $sChannel, $sNick, @tArgs) = @_;

    # Extract user object from message
    my $user = $self->get_user_from_message($message);

    # Require user authentication
    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " whotalk command attempt (user " . ($user ? $user->nickname : "unknown") . " is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login <user> <pass>");
        return;
    }

    # Load user level if not already available
    if (!defined $user->level) {
        $user->load_level($self->{dbh});
    }

    # Require Administrator level to execute the command
    unless ($user->has_level("Administrator", $self->{dbh})) {
        my $notice = $message->prefix . " whotalk command attempt (requires Administrator level for user " . $user->nickname . " [" . ($user->level // 'undef') . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Access denied. This command requires Administrator privileges.");
        return;
    }

    # Determine which channel we're targeting
    my $target_channel;
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $target_channel = shift @tArgs;
    } elsif (defined $sChannel && $sChannel =~ /^#/) {
        $target_channel = $sChannel;
    } else {
        botNotice($self, $sNick, "Syntax: whotalk <#channel>");
        return;
    }

    # Normalize channel name (lowercase and trimmed)
    $target_channel = lc($target_channel);
    $target_channel =~ s/^\s+|\s+$//g;

    # Build SQL query to count messages from public or action events within the last hour
    my $sql = <<'SQL';
SELECT nick, COUNT(*) AS nbLines
FROM CHANNEL_LOG
JOIN CHANNEL ON CHANNEL_LOG.id_channel = CHANNEL.id_channel
WHERE (event_type = 'public' OR event_type = 'action')
  AND LOWER(TRIM(CHANNEL.name)) = ?
  AND ts > (NOW() - INTERVAL 1 HOUR)
GROUP BY nick
ORDER BY nbLines DESC
LIMIT 20
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth->execute($target_channel)) {
        $self->{logger}->log(1, "whoTalk() SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $i        = 0;
    my $warned   = 0;
    my @rows;
    my $line_total = 0;

    # Fetch results
    while (my $row = $sth->fetchrow_hashref) {
        my $nick  = $row->{nick}    // next;
        my $lines = $row->{nbLines} // 0;
        $line_total += $lines;
        push @rows, [$nick, $lines];
        $i++;
    }

    if ($i == 0) {
        # No talkers at all
        botNotice($self, $sNick, "No messages recorded in $target_channel during the last hour.");
    } else {
        # Build the summary string
        my @talkers = map { "$_->[0] ($_->[1])" } @rows;
        my $summary = join(', ', @talkers);
        my $count = scalar(@rows);
        botPrivmsg($self, $target_channel, "Top $count talkers in the last hour: $summary");

        # Warn the top talker if message count is excessive
        if ($rows[0][1] >= 25) {
            botPrivmsg($self, $target_channel, "$rows[0][0]: please slow down a bit – you're flooding the channel!");
            $warned = 1;
        }

        # Optional: log summary to console
        $self->{logger}->log(3, "whoTalk() => $count users, $line_total total lines in $target_channel");
    }

    # Log this command invocation
    logBot($self, $message, undef, "whotalk", $target_channel);
    $sth->finish;
}



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

# Display the bot birth date and its age
sub displayBirthDate(@) {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	my $isPrivate = !defined($sChannel);

	my $birth_ts = $self->{conf}->get('main.MAIN_PROG_BIRTHDATE');
	my $sBirthDate = time2str("I was born on %d/%m/%Y at %H:%M:%S.", $birth_ts);

	my $d = time() - $birth_ts;
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

	while ($i >= 0 && $d) {
	    if ($d / $int[$i]->[1] >= 1) {
	        push @r, sprintf "%d %s%s",
	            int($d / $int[$i]->[1]),
	            $int[$i]->[0],
	            (int($d / $int[$i]->[1]) > 1 ? 's' : '');
	    }
	    $d %= $int[$i]->[1];
	    $i--;
	}

	my $runtime = join(", ", @r) if @r;

	if ($isPrivate) {
		botNotice($self, $sNick, "$sBirthDate I am $runtime old");
	} else {
		botPrivmsg($self, $sChannel, "$sBirthDate I am $runtime old");
	}
}

# Rename a public command
sub mbDbMvCommand {
    my ($self, $message, $sNick, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $notice = $message->prefix . " mvcmd command attempt (not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->has_level("Master")) {
        my $notice = $message->prefix . " mvcmd command attempt (requires Master level for user " . $user->handle . "[" . $user->level . "])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax: mvcmd <old_command> <new_command>");
        return;
    }

    my ($old_cmd, $new_cmd) = @tArgs;

    # Check if new command name already exists
    my $sth = $self->{dbh}->prepare("SELECT command FROM PUBLIC_COMMANDS WHERE command = ?");
    $sth->execute($new_cmd);
    if (my $existing = $sth->fetchrow_hashref) {
        botNotice($self, $sNick, "Command $new_cmd already exists. Please choose another name.");
        return;
    }

    # Find the original command
    $sth = $self->{dbh}->prepare("SELECT id_public_commands, id_user FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth->execute($old_cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT for $old_cmd");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    unless ($ref) {
        botNotice($self, $sNick, "Command $old_cmd does not exist.");
        return;
    }

    my ($id_cmd, $id_owner) = ($ref->{id_public_commands}, $ref->{id_user});

    unless ($id_owner == $user->id || $user->has_level("Master")) {
        botNotice($self, $sNick, "You do not own $old_cmd and are not Master.");
        return;
    }

    # Update command name
    $sth = $self->{dbh}->prepare("UPDATE PUBLIC_COMMANDS SET command = ? WHERE id_public_commands = ?");
    unless ($sth->execute($new_cmd, $id_cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: UPDATE to $new_cmd");
        botNotice($self, $sNick, "Failed to rename $old_cmd to $new_cmd. Does $new_cmd already exist?");
        return;
    }

    botNotice($self, $sNick, "Command $old_cmd has been renamed to $new_cmd.");
    logBot($self, $message, undef, "mvcmd", "Command $old_cmd renamed to $new_cmd");
    $sth->finish;
}


sub mbCountCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT count(*) as nbCommands FROM PUBLIC_COMMANDS";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $nbTotalCommands = 0;
		if (my $ref = $sth->fetchrow_hashref()) {
			$nbTotalCommands = $ref->{'nbCommands'};
		}
		$sQuery = "SELECT PUBLIC_COMMANDS_CATEGORY.description as sCategory,count(*) as nbCommands FROM PUBLIC_COMMANDS,PUBLIC_COMMANDS_CATEGORY WHERE PUBLIC_COMMANDS.id_public_commands_category=PUBLIC_COMMANDS_CATEGORY.id_public_commands_category GROUP by PUBLIC_COMMANDS_CATEGORY.description";
		$sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sNbCommandNotice = "$nbTotalCommands Commands in database : ";
			my $i = 0;
			while (my $ref = $sth->fetchrow_hashref()) {
				my $nbCommands = $ref->{'nbCommands'};
				my $sCategory = $ref->{'sCategory'};
				$sNbCommandNotice .= "($sCategory $nbCommands) ";
				$i++;
			}
			if ( $i ) {
				if (defined($sChannel)) {
					botPrivmsg($self,$sChannel,$sNbCommandNotice);
					logBot($self,$message,$sChannel,"countcmd",undef);
				}
				else {
					botNotice($self,$sNick,$sNbCommandNotice);
					logBot($self,$message,undef,"countcmd",undef);
				}
			}
			else {
				if (defined($sChannel)) {
					botPrivmsg($self,$sChannel,"No command in database");
					logBot($self,$message,$sChannel,"countcmd",undef);
				}
				else {
					botNotice($self,$sNick,$sNbCommandNotice);
					logBot($self,$message,undef,"countcmd",undef);
				}
			}
		}
	}
	$sth->finish;
}

sub mbTopCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT command,hits FROM PUBLIC_COMMANDS ORDER BY hits DESC LIMIT 20";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sNbCommandNotice = "Top commands in database : ";
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $command = $ref->{'command'};
			my $hits = $ref->{'hits'};
			$sNbCommandNotice .= "$command ($hits) ";
			$i++;
		}
		if ( $i ) {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,$sNbCommandNotice);
			}
			else {
				botNotice($self,$sNick,$sNbCommandNotice);
			}
		}
		else {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,"No top commands in database");
			}
			else {
				botNotice($self,$sNick,"No top commands in database");
			}
		}
		logBot($self,$message,$sChannel,"topcmd",undef);
	}
	$sth->finish;
}

# lastcmd
sub mbLastCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT command FROM PUBLIC_COMMANDS ORDER BY creation_date DESC LIMIT 10";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sCommandText;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $command = $ref->{'command'};
			$sCommandText .= " $command";
			
		}
		if (defined($sCommandText) && ($sCommandText ne "")) {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,"Last commands in database :$sCommandText");
			}
			else {
				botNotice($self,$sNick,"Last commands in database :$sCommandText");
			}
		}
		else {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,"No command found in databse");
			}
			else {
				botNotice($self,$sNick,"No command found in databse");
			}
		}
		logBot($self,$message,$sChannel,"lastcmd",undef);
	}
	$sth->finish;
}

sub mbDbSearchCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my $sCommand = $tArgs[0];
		$self->{logger}->log(3,"sCommand : $sCommand");
		my $sQuery = "SELECT * FROM PUBLIC_COMMANDS";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sResponse;
			while (my $ref = $sth->fetchrow_hashref()) {
				my $command = $ref->{'command'};
				my $action = $ref->{'action'};
				if ( $action =~ /$sCommand/ ) {
					$sResponse .= " $command";
				}
			}
			unless(defined($sResponse) && ($sResponse ne "")) {
				botNotice($self,$sNick,"keyword $sCommand not found in commands");
			}
			else {
				if (defined($sChannel)) {
					botPrivmsg($self,$sChannel,"Commands containing $sCommand : $sResponse");
				}
				else {
					botNotice($self,$sNick,"Commands containing $sCommand : $sResponse");
				}
			}
			logBot($self,$message,$sChannel,"searchcmd",("Commands containing $sCommand"));
		}
		$sth->finish;
	}
	else {
		botNotice($self,$sNick,"Syntax: searchcmd <keyword>");
		return undef;
	}
}

sub mbDbOwnersCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT nickname,count(command) as nbCommands FROM PUBLIC_COMMANDS,USER WHERE PUBLIC_COMMANDS.id_user=USER.id_user GROUP by nickname ORDER BY nbCommands DESC";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sResponse = "Number of commands by user : ";
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $nickname = $ref->{'nickname'};
			my $nbCommands = $ref->{'nbCommands'};
			$sResponse .= "$nickname($nbCommands) ";
			$i++;
		}
		unless ( $i ) {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,"not found");
			}
			else {
				botNotice($self,$sNick,"not found");
			}
		}
		else {
			if (defined($sChannel)) {
				botPrivmsg($self,$sChannel,$sResponse);
			}
			else {
				botNotice($self,$sNick,$sResponse);
			}
		}
		logBot($self,$message,$sChannel,"owncmd",undef);
	}
	$sth->finish;
}

# Temporarily disable (hold) a public command (refactored)
sub mbDbHoldCommand {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " holdcmd attempt (not logged in)");
        botNotice($self, $sNick, "You must be logged in to use this command.");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        noticeConsoleChan($self, $message->prefix . " holdcmd attempt (requires Administrator level for " . $user->nickname . " [" . $user->level . "])");
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: holdcmd <command>");
        return;
    }

    my $cmd = $tArgs[0];

    my $sth = $self->{dbh}->prepare("SELECT id_public_commands, active FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth->execute($cmd)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT for holdcmd");
        botNotice($self, $sNick, "Database error while checking command.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    unless ($ref) {
        botNotice($self, $sNick, "Command '$cmd' does not exist.");
        return;
    }

    unless ($ref->{active}) {
        botNotice($self, $sNick, "Command '$cmd' is already on hold.");
        return;
    }

    my $id = $ref->{id_public_commands};
    $sth = $self->{dbh}->prepare("UPDATE PUBLIC_COMMANDS SET active = 0 WHERE id_public_commands = ?");
    unless ($sth->execute($id)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: UPDATE holdcmd");
        botNotice($self, $sNick, "Failed to put command '$cmd' on hold.");
        return;
    }

    botNotice($self, $sNick, "Command '$cmd' has been placed on hold.");
    logBot($self, $message, $sChannel, "holdcmd", "Command '$cmd' deactivated");
    $sth->finish;
}


# Add a new public command category (refactored)
sub mbDbAddCategoryCommand {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " addcatcmd attempt (user " . $user->nickname . " not logged in)");
        botNotice($self, $sNick, "You must be logged in to use this command.");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        noticeConsoleChan($self, $message->prefix . " addcatcmd attempt (level [Administrator] required for " . $user->nickname . " [" . $user->level . "])");
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: addcatcmd <new_category>");
        return;
    }

    my $category = $tArgs[0];

    my $sth = $self->{dbh}->prepare("SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?");
    unless ($sth->execute($category)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $sNick, "Database error while checking category.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $sNick, "Category '$category' already exists.");
        return;
    }

    $sth = $self->{dbh}->prepare("INSERT INTO PUBLIC_COMMANDS_CATEGORY (description) VALUES (?)");
    unless ($sth->execute($category)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: INSERT category");
        botNotice($self, $sNick, "Failed to add category '$category'.");
        return;
    }

    botNotice($self, $sNick, "Category '$category' successfully added.");
    logBot($self, $message, $sChannel, "addcatcmd", "Category '$category' added");
    $sth->finish;
}



# Change the category of an existing public command (refactored)
sub mbDbChangeCategoryCommand {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " chcatcmd attempt (user " . $user->nickname . " not logged in)");
        botNotice($self, $sNick, "You must be logged in to use this command.");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        noticeConsoleChan($self, $message->prefix . " chcatcmd attempt (Administrator level required for " . $user->nickname . " [" . $user->level . "])");
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && $tArgs[1] ne "") {
        botNotice($self, $sNick, "Syntax: chcatcmd <new_category> <command>");
        return;
    }

    my ($categoryName, $commandName) = @tArgs;

    # Check if the category exists
    my $sth = $self->{dbh}->prepare("SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description = ?");
    unless ($sth->execute($categoryName)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT category");
        botNotice($self, $sNick, "Database error while checking category.");
        return;
    }
    my $catRef = $sth->fetchrow_hashref();
    unless ($catRef) {
        botNotice($self, $sNick, "Category '$categoryName' does not exist.");
        return;
    }
    my $categoryId = $catRef->{'id_public_commands_category'};

    # Check if the command exists
    $sth = $self->{dbh}->prepare("SELECT id_public_commands FROM PUBLIC_COMMANDS WHERE command = ?");
    unless ($sth->execute($commandName)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: SELECT command");
        botNotice($self, $sNick, "Database error while checking command.");
        return;
    }
    my $cmdRef = $sth->fetchrow_hashref();
    unless ($cmdRef) {
        botNotice($self, $sNick, "Command '$commandName' does not exist.");
        return;
    }

    # Perform the update
    $sth = $self->{dbh}->prepare("UPDATE PUBLIC_COMMANDS SET id_public_commands_category = ? WHERE command = ?");
    unless ($sth->execute($categoryId, $commandName)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: UPDATE command category");
        botNotice($self, $sNick, "Failed to update category for '$commandName'.");
        return;
    }

    botNotice($self, $sNick, "Category changed to '$categoryName' for command '$commandName'.");
    logBot($self, $message, $sChannel, "chcatcmd", "Changed category to '$categoryName' for '$commandName'");

    $sth->finish;
}



# Show the most frequently used phrases by a given nick on a given channel (OO version)
sub userTopSay {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $isPrivate = !defined($sChannel);

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " topsay attempt (unauthenticated user " . $user->nickname . ")");
        botNotice($self, $sNick, "You must be logged in to use this command: /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        noticeConsoleChan($self, $message->prefix . " topsay attempt (level [Administrator] required for " . $user->nickname . " [" . $user->level . "])");
        botNotice($self, $sNick, "This command is not available for your level. Contact a bot master.");
        return;
    }

    # Channel and nick extraction
    my $sChannelDest = $sChannel;
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }
    $sChannelDest //= $sChannel;

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: topsay [#channel] <nick>");
        return;
    }

    my $targetNick = $tArgs[0] // $sNick;

    # SQL query
    my $sql = <<"SQL";
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
    unless ($sth->execute($sChannel, $targetNick)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $response  = "$targetNick: ";
    my $fullLine  = $response;
    my $maxLength = 300;
    my $i         = 0;

    my @skip_patterns = (
        qr/^\s*$/, qr/^[:;=]?[pPdDoO)]$/, qr/^[(;][:;=]?$/, qr/^x?D$/i,
        qr/^(heh|hah|huh|hih)$/i, qr/^!/, qr/^=.?$/, qr/^;[p>]$/, qr/^:>$/, qr/^lol$/i
    );

    while (my $ref = $sth->fetchrow_hashref()) {
        my ($text, $event_type, $count) = @{$ref}{qw/publictext event_type hit/};

        # Clean control characters
        $text =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;

        # Skip useless lines
        next if grep { $text =~ $_ } @skip_patterns;

        my $entry = ($event_type eq "action") ? String::IRC->new("$text ($count) ")->bold : "$text ($count) ";
        my $newLength = length($fullLine) + length($entry);
        if ($newLength < $maxLength) {
            $response .= $entry;
            $fullLine .= $entry;
            $i++;
        } else {
            last;
        }
    }

    if ($i > 0) {
        $isPrivate ? botNotice($self, $sNick, $response) : botPrivmsg($self, $sChannelDest, $response);
    } else {
        my $msg = "No results.";
        $isPrivate ? botNotice($self, $sNick, $msg) : botPrivmsg($self, $sChannelDest, $msg);
    }

    logBot($self, $message, $sChannelDest, "topsay", $message->prefix . " topsay on $targetNick");
    $sth->finish;
}



# Check nicknames used on a given channel by a specific hostname (OO version)
sub mbDbCheckHostnameNickChan {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $isPrivate = !defined($sChannel);

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " checkhostchan attempt (unauthenticated " . $user->nickname . ")");
        botNotice($self, $sNick, "You must be logged in to use this command: /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        my $msg = $message->prefix . " checkhostchan attempt (level [Administrator] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Extract channel and hostname
    my $sChannelDest = $sChannel;
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }
    $sChannelDest //= $sChannel;

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: checkhostchan [#channel] <hostname>");
        return;
    }

    my $sHostname = $tArgs[0];

    # SQL Query
    my $sql = <<"SQL";
SELECT nick, COUNT(nick) AS hits
FROM CHANNEL_LOG
JOIN CHANNEL ON CHANNEL.id_channel = CHANNEL_LOG.id_channel
WHERE name = ? AND userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    my $hostnameMask = '%!%@' . $sHostname;
    unless ($sth->execute($sChannel, $hostnameMask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $i = 0;
    my $sResponse = "Nicks for host $sHostname on $sChannel: ";

    while (my $ref = $sth->fetchrow_hashref()) {
        my $nick = $ref->{nick};
        my $hits = $ref->{hits};
        $sResponse .= "$nick ($hits) ";
        $i++;
    }

    $sResponse = "No result found for hostname $sHostname on $sChannel."
        unless $i;

    $isPrivate
        ? botNotice($self, $sNick, $sResponse)
        : botPrivmsg($self, $sChannelDest, $sResponse);

    logBot($self, $message, $sChannelDest, "checkhostchan", $sHostname);
    $sth->finish;
}


# Check nicknames globally for a given hostname (OO version)
sub mbDbCheckHostnameNick {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $isPrivate = !defined($sChannel);

    my $user = $self->get_user_from_message($message);
    unless ($user) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " checkhost attempt (unauthenticated " . $user->nickname . ")";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Master")) {
        my $msg = $message->prefix . " checkhost command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: checkhost <hostname>");
        return;
    }

    my $sHostname = $tArgs[0];

    my $sql = <<"SQL";
SELECT nick, COUNT(nick) AS hits
FROM CHANNEL_LOG
WHERE userhost LIKE ?
GROUP BY nick
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    my $hostnameMask = '%!%@' . $sHostname;

    unless ($sth->execute($hostnameMask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $response = "Nicks for host $sHostname: ";
    my $i = 0;
    while (my $ref = $sth->fetchrow_hashref()) {
        $response .= "$ref->{nick} ($ref->{hits}) ";
        $i++;
    }

    $response = "No result found for hostname: $sHostname" unless $i;

    $isPrivate ? botNotice($self, $sNick, $response)
               : botPrivmsg($self, $sChannel, $response);

    logBot($self, $message, $sChannel // "(private)", "checkhost", $sHostname);
    $sth->finish;
}



# checknick <nick> - Show top 10 hostmasks for a given nickname (OO version)
sub mbDbCheckNickHostname {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $isPrivate = !defined($sChannel);

    my $user = $self->get_user_from_message($message);

    unless ($user && $user->is_authenticated) {
        my $msg = $message->prefix . " checknick attempt (unauthenticated " . ($user ? $user->nickname : 'unknown') . ")";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Master")) {
        my $msg = $message->prefix . " checknick command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: checknick <nick>");
        return;
    }

    my $sNickSearch = $tArgs[0];

    my $sql = <<"SQL";
SELECT userhost, COUNT(*) AS hits
FROM CHANNEL_LOG
WHERE nick LIKE ?
GROUP BY userhost
ORDER BY hits DESC
LIMIT 10
SQL

    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth->execute($sNickSearch)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sql");
        return;
    }

    my $response = "Hostmasks for $sNickSearch: ";
    my $count = 0;

    while (my $ref = $sth->fetchrow_hashref()) {
        my $hostmask = $ref->{userhost};
        $hostmask =~ s/^.*!//;  # Remove 'nick!' part if present
        my $hits = $ref->{hits};
        $response .= "$hostmask ($hits) ";
        $count++;
    }

    $response = "No result found for nick: $sNickSearch" unless $count;

    $isPrivate ? botNotice($self, $sNick, $response)
               : botPrivmsg($self, $sChannel, $response);

    logBot($self, $message, $sChannel // "(private)", "checknick", $sNickSearch);
    $sth->finish;
}



sub userGreet(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $isPrivate = !defined($sChannel);
	my $sChannelDest = $sChannel;
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
		$sChannel = $tArgs[0];
		shift @tArgs;
	}
	if ($isPrivate && !defined($sChannel)) {
		botNotice($self,$sNick,"Syntax (in private): greet #channel <nick>");
		return undef;
	}
	my $sGreetNick = $sNick;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		$sGreetNick = $tArgs[0];
	}
	my $sQuery = "SELECT greet FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND nickname=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sGreetNick)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $greet = $ref->{'greet'};
			if (defined($greet)) {
				unless ($isPrivate) {
					botPrivmsg($self,$sChannelDest,"greet on $sChannel (" . $sGreetNick . ") $greet");
				}
				else {
					botNotice($self,$sNick,"greet on $sChannel (" . $sGreetNick . ") $greet");
				}
			}
			else {
				unless ($isPrivate) {
					botPrivmsg($self,$sChannelDest,"No greet for " . $sGreetNick . " on $sChannel");
				}
				else {
					botNotice($self,$sNick,"No greet for " . $sGreetNick . " on $sChannel");
				}
			}
		}
		else {
			unless ($isPrivate) {
				botPrivmsg($self,$sChannelDest,"No greet for " . $sGreetNick . " on $sChannel");
			}
			else {
				botNotice($self,$sNick,"No greet for " . $sGreetNick . " on $sChannel");
			}
		}
		my $sNoticeMsg = $message->prefix . " greet on " . $sGreetNick . " for $sChannel";
		logBot($self,$message,$sChannelDest,"greet",$sNoticeMsg);
		$sth->finish;
	}
}

sub getWhoisVar(@) {
	my $self = shift;
	return $self->{WHOIS_VARS};
}

# access #channel <nickhandle>
# access #channel =<nick>
sub userAccessChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %WHOIS_VARS;
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
		$sChannel = $tArgs[0];
		shift @tArgs;
	}
	unless (defined($sChannel)) {
		botNotice($self,$sNick,"Syntax: access #channel [=]<nick>");
		return undef;
	}
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		if (substr($tArgs[0], 0, 1) eq '=') {
			$tArgs[0] = substr($tArgs[0],1);
			$WHOIS_VARS{'nick'} = $tArgs[0];
			$WHOIS_VARS{'sub'} = "userAccessChannel";
			$WHOIS_VARS{'caller'} = $sNick;
			$WHOIS_VARS{'channel'} = $sChannel;
			$WHOIS_VARS{'message'} = $message;
			$self->{irc}->send_message("WHOIS", undef, $tArgs[0]);
			%{$self->{WHOIS_VARS}} = %WHOIS_VARS;
			return undef;
		}
		else {
			my $iChannelUserLevelAccess = getUserChannelLevelByName($self,$sChannel,$tArgs[0]);
			if ( $iChannelUserLevelAccess == 0 ) {
				botNotice($self,$sNick,"No Match!");
				logBot($self,$message,$sChannel,"access",($sChannel,@tArgs));
			}
			else {
				botNotice($self,$sNick,"USER: " . $tArgs[0] . " ACCESS: $iChannelUserLevelAccess");
				my $sQuery = "SELECT automode,greet FROM USER,USER_CHANNEL,CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER.id_user=USER_CHANNEL.id_user AND nickname like ? AND CHANNEL.name=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($tArgs[0],$sChannel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						botNotice($self,$sNick,"CHANNEL: $sChannel -- Automode: $sAutomode");
						botNotice($self,$sNick,"GREET MESSAGE: $sGreetMsg");
						logBot($self,$message,$sChannel,"access",($sChannel,@tArgs));
					}
				}
				$sth->finish;
			}
		}
	}
	else {
		botNotice($self,$sNick,"Syntax: access #channel [=]<nick>");
	}
}

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

# /auth <nick> — Triggers a WHOIS to identify if a user is known/authenticated
sub userAuthNick {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Récupération de l’objet utilisateur
    my $user = $self->get_user_from_message($message);

    unless ($user) {
        botNotice($self, $sNick, "Unable to identify you.");
        return;
    }

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " auth command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        my $msg = $message->prefix . " auth command attempt (level [Administrator] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: auth <nick>");
        return;
    }

    my $targetNick = $tArgs[0];

    # WHOIS tracking context
    $self->{WHOIS_VARS} = {
        nick    => $targetNick,
        sub     => 'userAuthNick',
        caller  => $sNick,
        channel => undef,
        message => $message,
    };

    $self->{logger}->log(3, "Triggering WHOIS on $targetNick for $sNick via userAuthNick()");
    $self->{irc}->send_message("WHOIS", undef, $targetNick);
}



sub userVerifyNick(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %WHOIS_VARS;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		$WHOIS_VARS{'nick'} = $tArgs[0];
		$WHOIS_VARS{'sub'} = "userVerifyNick";
		$WHOIS_VARS{'caller'} = $sNick;
		$WHOIS_VARS{'channel'} = undef;
		$WHOIS_VARS{'message'} = $message;
		$self->{irc}->send_message("WHOIS", undef, $tArgs[0]);
		%{$self->{WHOIS_VARS}} = %WHOIS_VARS;
		return undef;
	}
	else {
		botNotice($self,$sNick,"Syntax: verify <nick>");
	}
}

# /nicklist <#channel>
# Shows the list of known users on a specific channel from memory
sub channelNickList {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Récupération de l’utilisateur appelant
    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " nicklist command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        my $msg = $message->prefix . " nicklist command attempt (command level [Administrator] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Extraction de l’argument #channel si fourni
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: nicklist #channel");
        return;
    }

    # Récupération de la liste de nicks en mémoire
    my $nicklist_ref = $self->{hChannelsNicks}{$sChannel};
    if ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY') {
        my $nick_string = join(" ", @$nicklist_ref);
        $self->{logger}->log(1, "Users on $sChannel: $nick_string");
        botNotice($self, $sNick, "Users on $sChannel: $nick_string");
    } else {
        $self->{logger}->log(2, "nicklist requested for unknown channel $sChannel");
        botNotice($self, $sNick, "No nicklist known for $sChannel.");
    }

    return;
}



# /rnick <#channel>
# Returns a random nick from the bot's memory list for a given channel
sub randomChannelNick {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Utilisation de l’objet utilisateur
    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " rnick command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        my $msg = $message->prefix . " rnick command attempt (command level [Administrator] for user " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Extraction du canal demandé
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: rnick #channel");
        return;
    }

    # Vérifie l'existence d'une liste de nicks pour ce canal
    my $nicklist_ref = $self->{hChannelsNicks}{$sChannel};
    if ($nicklist_ref && ref($nicklist_ref) eq 'ARRAY' && @$nicklist_ref) {
        my $random_nick = $nicklist_ref->[ int(rand(@$nicklist_ref)) ];
        botNotice($self, $sNick, "Random nick on $sChannel: $random_nick");
    } else {
        botNotice($self, $sNick, "No known nicklist or empty list for $sChannel.");
        $self->{logger}->log(2, "rnick requested but no valid nicklist for $sChannel");
    }

    return;
}



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

sub displayWeather(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $id_chanset_list = getIdChansetList($self,"Weather");
	if (defined($id_chanset_list)) {
		my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
		if (defined($id_channel_set)) {
			my $sText = join(" ",@tArgs);
			if (defined($sText) && ($sText ne "")) {
				my $sContentType;
				my $iHttpResponseCode;
				my $sCity = $sText;
				unless ( open URL_WEATHER, "curl --connect-timeout 3 --max-time 3 -L -ks 'http://wttr.in/" . url_encode($sCity) . "?format=\"%l:+%c+%t+%w+%p\"&m' |" ) {
					$self->{logger}->log(3,"displayWeather() Could not curl headers from wttr.in");
				}
				else {
					my $line;
					if(defined($line=<URL_WEATHER>)) {
						chomp($line);
						$line =~ s/^\"//;
						$line =~ s/\"$//;
						$line =~ s/\+/ /g;
						unless ($line =~ /^Unknown location/) {
							botPrivmsg($self,$sChannel,$line);
						}
						else {
							botPrivmsg($self,$sChannel,"Service unavailable, try again later");
						}
					}
					else {
						botPrivmsg($self,$sChannel,"No answer from http://wttr.in for $sCity. Try again in a few seconds.");
					}
				}
			}
			else {
				botNotice($self,$sNick,"Syntax (no accents): weather <City>");
				return undef;
			}
		}
	}
}

sub displayUrlTitle(@) {
	my ($self,$message,$sNick,$sChannel,$sText) = @_;
	$self->{logger}->log(3,"displayUrlTitle() $sText");
	my $sContentType;
	my $iHttpResponseCode;
	my $sTextURL = $sText;
	$sText =~ s/^.*http/http/;
	$sText =~ s/\s+.*$//;
	$self->{logger}->log(3,"displayUrlTitle() URL = $sText");
	if ( $sText =~ /x.com/ ) {
		my $id_chanset_list = getIdChansetList($self,"Twitter");
		if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
			$self->{logger}->log(3,"id_chanset_list = $id_chanset_list");
			my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
			unless (defined($id_channel_set) && ($id_channel_set ne "")) {
				return undef;
			}
			else {
				$self->{logger}->log(3,"id_channel_set = $id_channel_set");
			}
		}
		#TBD or not
	} # Special prank for a bro :)
	if ( (($sText =~ /x.com/) || ($sText =~ /twitter.com/)) && (($sNick =~ /^\[k\]$/) || ($sNick =~ /^NHI$/) || ($sNick =~ /^PersianYeti$/))) {
		$self->{logger}->log(3,"displayUrlTitle() Twitter URL = $sText");
		return undef;
		my @tAnswers = ( "Ok $sNick, you need to take a breathe", "$sNick the truth is out theeeeere ^^", "You're the wisest $sNick, you checked your sources :P~","Great another Twitter thingy, we missed that $sNick");
		botPrivmsg($self,$sChannel,$tAnswers[rand($#tAnswers + 1)]);
		return undef;
		my $user;
		my $id;
		if ( $sText =~ /^https.*x\.com\/(.*)\/status.*$/ ) {
			$user = $1;
		}
		if ( $sText =~ /^https.*x\.com\/.*\/status\/([^?]*).*$/ ) {
			$id = $1;
		}
		if ($user) {
			$self->{logger}->log(3,"displayUrlTitle() user = $user");
		}
		else {
			$self->{logger}->log(3,"displayUrlTitle() Could not get Twitter user");
			return undef;
		}
		if ($id) {
			$self->{logger}->log(3,"displayUrlTitle() id = $id");
		}
		else {
			$self->{logger}->log(3,"displayUrlTitle() Could not get Twitter id");
			return undef;
		}

		

		my $twitter_url = "https://twitter.com/$user/status/$id";  # Replace with the actual URL
		$self->{logger}->log(3,"displayUrlTitle() twitter_url = $twitter_url");

		

		# Use curl to fetch the Twitter page content
		my $curl_output = `curl -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0" -s "$twitter_url"`;
		#$self->{logger}->log(4,"displayUrlTitle() curl_output = $curl_output");

		# Check if the curl command was successful
		if ($? == -1) {
			$self->{logger}->log(3,"displayUrlTitle() Failed to execute curl: $!");
			return undef;
		}
		elsif ($? & 127) {
			$self->{logger}->log(3,"displayUrlTitle() curl died with signal " . ($? & 127));
		}
		else {
			my $exit_code = $? >> 8;
			if ($exit_code != 0) {
				$self->{logger}->log(3,"displayUrlTitle() curl exited with non-zero status: $exit_code");
			}
		}

		# Extract the tweet text from the HTML response using a regular expression
		if ($curl_output =~ /<p class="tweet-text" data-aria-label-part="0">([^<]+)/) {
			my $tweet_text = $1;
			$tweet_text =~ s/\s+/ /g;  # Remove extra whitespace
			$self->{logger}->log(3,"displayUrlTitle() Tweet Text: $tweet_text");
		}
		else {
			$self->{logger}->log(3,"displayUrlTitle() Tweet text not found");
		}
	}
	if ( $sText =~ /instagram.com/ ) {
		my $content;
		unless ( open URL_HEAD, "curl \"$sText\" |" ) {
			$self->{logger}->log(3,"displayUrlTitle() insta Could not curl GET for url details");
		}
		else {
			my $line;
			while (defined($line=<URL_HEAD>)) {
				chomp($line);
				$content .= $line;
			}
		}

		my $title = $content;
		if (defined($title)) {
			$title =~ s/^.*og:title" content="//;
			$title =~ s/" .><meta property="og:image".*$//;
			unless ( $title =~ /DOCTYPE html/ ) {
				$self->{logger}->log(3,"displayUrlTitle() (insta) Extracted title : $title");
			}
			else {
				$title = $content;
				$title =~ s/^.*<title//;
				$title =~ s/<\/title>.*$//;
				$title =~ s/^\s*>//;
			}
			if ($title ne "") {
				$sText = String::IRC->new("[")->white('black');
				$sText .= String::IRC->new("Instagram")->white('pink');
				$sText .= String::IRC->new("]")->white('black');
				$sText .= " $title";
				my $regex = "&(?:" . join("|", map {s/;\z//; $_} keys %entity2char) . ");";
				if (($sText =~ /$regex/) || ( $sText =~ /&#.*;/)) {
					$sText = decode_entities($sText);
				}
				$sText = "($sNick) " . $sText;
				unless ( $sText =~ /DOCTYPE html/ ) {
					botPrivmsg($self,$sChannel,substr($sText, 0, 300));
				}
			}
		}

		return undef;
	}

	unless ( open URL_HEAD, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -I -ks \"$sText\" |" ) {
		$self->{logger}->log(3,"displayUrlTitle() Could not curl headers for $sText");
	}
	else {
		my $line;
		my $i = 0;
		while(defined($line=<URL_HEAD>)) {
			chomp($line);
			$self->{logger}->log(4,"displayUrlTitle() $line");
			if ( $line =~ /^content\-type/i ) {
				(undef,$sContentType) = split(" ",$line);
				$self->{logger}->log(4,"displayUrlTitle() sContentType = $sContentType");
			}
			elsif ( $line =~ /^http/i ) {
				(undef,$iHttpResponseCode) = split(" ",$line);
				$self->{logger}->log(4,"displayUrlTitle() iHttpResponseCode = $iHttpResponseCode");
			}
			$i++;
		}
	}
	unless (defined($iHttpResponseCode) && ($iHttpResponseCode eq "200")) {
		$self->{logger}->log(3,"displayUrlTitle() Wrong HTTP response code (" . (defined($iHttpResponseCode) ? $iHttpResponseCode : "undefined") .") for $sText " . (defined($iHttpResponseCode) ? $iHttpResponseCode : "Undefined") );
	}
	else {
		unless (defined($sContentType) && ($sContentType =~ /text\/html/i)) {
			$self->{logger}->log(3,"displayUrlTitle() Wrong Content-Type for $sText " . (defined($sContentType) ? $sContentType : "Undefined") );
		}
		else {
			if ( $sText =~ /open.spotify.com/ ) {
				my $url = $sText;
				$url =~ s/\?.*$//;
				unless ( open URL_TITLE, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -ks \"$url\" |" ) {
					$self->{logger}->log(0,"displayUrlTitle() Could not curl UrlTitle for $sText");
				}
				else {
					my $line;
					my $i = 0;
					my $sTitle;
					while(defined($line=<URL_TITLE>)) {
						chomp($line);
						if ( $line =~ /<title>/) {
							my $sDisplayMsg = $line;
							$sDisplayMsg =~ s/^.*<title//;
							$sDisplayMsg =~ s/<\/title>.*$//;
							$sDisplayMsg =~ s/^>//;
							my $artist = $sDisplayMsg;
							$artist =~ s/^.*song and lyrics by //;
							$artist =~ s/ \| Spotify//;
							my $song = $sDisplayMsg;
							$song =~ s/ - song and lyrics by.*$//;
							$self->{logger}->log(3,"displayUrlTitle() artist = $artist song = $song");

							my $sText = String::IRC->new("[")->white('black');
							$sText .= String::IRC->new("Spotify")->black('green');
							$sText .= String::IRC->new("]")->white('black');
							$sText .= " $artist - $song";
							my $regex = "&(?:" . join("|", map {s/;\z//; $_} keys %entity2char) . ");";
							if (($sText =~ /$regex/) || ( $sText =~ /&#.*;/)) {
								$sText = decode_entities($sText);
							}
							
							botPrivmsg($self,$sChannel,"($sNick) $sText");
						}	
						$i++;
					}
				}
				return undef;
			}
			unless ( open URL_TITLE, "curl -A -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0\" --connect-timeout 3 --max-time 3 -L -ks \"$sText\" |" ) {
				$self->{logger}->log(0,"displayUrlTitle() Could not curl UrlTitle for $sText");
			}
			else {
				my $line;
				my $i = 0;
				my $sTitle;
				my $sContent;
				while(defined($line=<URL_TITLE>)) {
					chomp($line);
					$sContent .= "$line\n";
					$i++;
				}
				if ( $i > 0 ) {
					my $tree = HTML::Tree->new();
					$tree->parse($sContent);
					my ($title) = $tree->look_down( '_tag' , 'title' );
					if (defined($title) && ($title->as_text ne "")) {
						my $sDisplayMsg;
						if (( $sText =~ /youtube.com/ ) || ( $sText =~ /youtu\.be/ )) {
							$sDisplayMsg = String::IRC->new('[')->white('black');
							$sDisplayMsg .= String::IRC->new('You')->black('white');
							$sDisplayMsg .= String::IRC->new('Tube')->white('red');
							$sDisplayMsg .= String::IRC->new(']')->white('black');
							botPrivmsg($self,$sChannel,"($sNick) $sDisplayMsg " . $title->as_text);
						}
						elsif ( $sText =~ /music.apple.com/ ) {
							my $id_chanset_list = getIdChansetList($self,"AppleMusic");
							if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
								$self->{logger}->log(3,"id_chanset_list = $id_chanset_list");
								my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
								unless (defined($id_channel_set) && ($id_channel_set ne "")) {
									return undef;
								}
								else {
									$self->{logger}->log(3,"id_channel_set = $id_channel_set");
								}
							}
							$sDisplayMsg = String::IRC->new('[')->white('black');
							$sDisplayMsg .= String::IRC->new('AppleMusic')->white('grey');
							$sDisplayMsg .= String::IRC->new(']')->white('black');
							botPrivmsg($self,$sChannel,"($sNick) $sDisplayMsg " . $title->as_text);
						}
						else {
							if ( $title->as_text =~ /The page is temporarily unavailable/i ) {
								return undef;
							}
							else {
								$sDisplayMsg = String::IRC->new("URL Title from $sNick:")->grey('black');
								botPrivmsg($self,$sChannel,$sDisplayMsg . " " . $title->as_text);
							}
						}
					}
				}
			}
		}
		
	}
}

# Set or show the debug level of the bot
sub mbDebug {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $level     = $tArgs[0];
    my $irc_nick  = $self->{irc}->nick_folded;
    my $conf      = $self->{conf}; # object Mediabot::Conf

    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg $irc_nick login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Owner")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Display current debug level if no argument is given
    unless (defined $level) {
        my $current = $conf->get("main.MAIN_PROG_DEBUG") // 0;
        botNotice($self, $sNick, "Current debug level is $current (0-5)");
        return;
    }

    # Check if the level is a valid integer between 0 and 5
    unless ($level =~ /^[0-5]$/) {
        botNotice($self, $sNick, "Syntax: debug <debug_level>");
        botNotice($self, $sNick, "debug_level must be between 0 and 5");
        return;
    }

    # Update the configuration with the new debug level
    $conf->set("main.MAIN_PROG_DEBUG", $level);
    $conf->save();

    # Immediately update the logger's debug level
    $self->{logger}->{debug_level} = $level;

    $self->{logger}->log(0, "Debug set to $level");
    botNotice($self, $sNick, "Debug level set to $level");
    logBot($self, $message, $sChannel, "debug", "Debug set to $level");
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


# Make a string with colors
sub make_colors {
    my ($self, $string) = @_;
    Encode::_utf8_on($string);

    my @palette = (3, 7, 8, 9, 10, 11, 12, 13);  # green → pink
    my $num_colors = scalar @palette;
    my $newstr = "";

    my $i = 0;
    for my $char (split //, $string) {
        if ($char eq ' ') {
            $newstr .= $char;
            next;
        }
        my $color = $palette[$i % $num_colors];
        $newstr .= "\003" . sprintf("%02d", $color) . $char;
        $i++;
    }

    return $newstr;
}

sub mbColors(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sText = join(" ",@tArgs);
	botPrivmsg($self,$sChannel,make_colors($self,$sText));
}

# Enhanced and cleaned-up version of mbSeen()
sub mbSeen(@) {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	return unless defined $tArgs[0] && $tArgs[0] ne "";

	my $targetNick = $tArgs[0];
	my ($quit, $part);

	# --- Fetch the latest quit event ---
	my $sth_quit = $self->{dbh}->prepare(
		"SELECT ts, userhost, publictext FROM CHANNEL_LOG WHERE nick = ? AND event_type = 'quit' ORDER BY ts DESC LIMIT 1"
	);
	if ($sth_quit->execute($targetNick)) {
		if (my $ref = $sth_quit->fetchrow_hashref()) {
			$quit = {
				ts         => $ref->{ts},
				userhost   => $ref->{userhost},
				publictext => $ref->{publictext} // '',
			};
			$self->{logger}->log(3, "mbSeen() Quit: $quit->{ts}");
		}
	} else {
		$self->{logger}->log(1, "SQL Error (quit): $DBI::errstr");
	}

	# --- Fetch the latest part event for the current channel ---
	my $sth_part = $self->{dbh}->prepare(
		"SELECT CHANNEL_LOG.ts, CHANNEL_LOG.userhost, CHANNEL_LOG.publictext FROM CHANNEL_LOG \
		 JOIN CHANNEL ON CHANNEL.id_channel = CHANNEL_LOG.id_channel \
		 WHERE CHANNEL.name = ? AND CHANNEL_LOG.nick = ? AND event_type = 'part' \
		 ORDER BY CHANNEL_LOG.ts DESC LIMIT 1"
	);
	if ($sth_part->execute($sChannel, $targetNick)) {
		if (my $ref = $sth_part->fetchrow_hashref()) {
			$part = {
				ts         => $ref->{ts},
				userhost   => $ref->{userhost},
				publictext => $ref->{publictext} // '',
			};
			$self->{logger}->log(3, "mbSeen() Part: $part->{ts}");
		}
	} else {
		$self->{logger}->log(1, "SQL Error (part): $DBI::errstr");
	}

	# --- Convert timestamps to epoch ---
	my $ts_quit_epoch = $quit  ? str2time($quit->{ts})  - 21600 : 0;
	my $ts_part_epoch = $part  ? str2time($part->{ts})  - 21600 : 0;

	# --- Generate output ---
	if ($ts_quit_epoch == 0 && $ts_part_epoch == 0) {
		botPrivmsg($self, $sChannel, "I don't remember seeing nick $targetNick");
	} elsif ($ts_part_epoch > $ts_quit_epoch) {
		my $host = $part->{userhost} // '';
		$host =~ s/^.*!//;
		botPrivmsg(
			$self, $sChannel,
			"$targetNick ($host) was last seen parting $sChannel : $part->{ts} ($part->{publictext})"
		);
	} else {
		my $host = $quit->{userhost} // '';
		$host =~ s/^.*!//;
		botPrivmsg(
			$self, $sChannel,
			"$targetNick ($host) was last seen quitting : $quit->{ts} ($quit->{publictext})"
		);
	}

	logBot($self, $message, $sChannel, "seen", @tArgs);

	$sth_quit->finish;
	$sth_part->finish;
}


sub mbPopCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"Syntax: popcmd <nick>");
	}
	else {
		my $sQuery = "SELECT command,hits FROM USER,PUBLIC_COMMANDS WHERE USER.id_user=PUBLIC_COMMANDS.id_user AND nickname like ? ORDER BY hits DESC LIMIT 20";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($tArgs[0])) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sNbCommandNotice = "Popular commands for " . $tArgs[0] . " : ";
			my $i = 0;
			while (my $ref = $sth->fetchrow_hashref()) {
				my $command = $ref->{'command'};
				my $hits = $ref->{'hits'};
				$sNbCommandNotice .= "$command ($hits) ";
				$i++;
			}
			if ( $i ) {
				if (defined($sChannel)) {
					botPrivmsg($self,$sChannel,$sNbCommandNotice);
				}
				else {
					botNotice($self,$sNick,$sNbCommandNotice);
				}
			}
			else {
				if (defined($sChannel)) {
					botPrivmsg($self,$sChannel,"No popular commands for " . $tArgs[0]);
				}
				else {
					botNotice($self,$sNick,"No popular commands for " . $tArgs[0]);
				}
			}
			logBot($self,$message,$sChannel,"popcmd",undef);
		}
		$sth->finish;
	}
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


# Display the current date and time in a specified timezone
sub displayDate(@) {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $sDefaultTZ = 'America/New_York';

    # Handle common aliases
    my %alias = (
        fr     => 'Europe/Paris',
        moscow => 'Europe/Moscow',
        la     => 'America/Los_Angeles',
        dk     => 'Europe/Copenhagen',
    );

    if (!@tArgs) {
        my $time = DateTime->now(time_zone => $sDefaultTZ);
        botPrivmsg($self, $sChannel, "$sDefaultTZ : " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return;
    }

    my $arg0 = $tArgs[0];

    # Easter egg
    if ($arg0 =~ /^me$/i) {
        my @answers = (
            "Ok $sNick, I'll pick you up at eight ;>",
            "I have to ask my daddy first $sNick ^^",
            "let's skip that $sNick, and go to your place :P~"
        );
        botPrivmsg($self, $sChannel, $answers[int(rand(@answers))]);
        return;
    }

    # Show timezone list
    if ($arg0 =~ /^list$/i) {
        botPrivmsg($self, $sChannel, "Available Timezones: https://pastebin.com/4p4pby3y");
        return;
    }

    # Admin subcommands
    if ($arg0 =~ /^user$/i) {
        my $user = $self->get_user_from_message($message);
        unless ($user && $user->is_authenticated && $user->level eq 'Administrator') {
            botNotice($self, $sNick, "You must be logged in as Administrator.");
            return;
        }

        if (defined($tArgs[1]) && $tArgs[1] =~ /^add$/i && defined($tArgs[2]) && defined($tArgs[3])) {
            my ($targetNick, $targetTZ) = @tArgs[2, 3];

            my $current = $self->_get_user_tz($targetNick);
            if (defined $current) {
                botPrivmsg($self, $sChannel, "$targetNick already has timezone $current. Delete it first.");
                return;
            }

            unless ($self->_tz_exists($targetTZ)) {
                botPrivmsg($self, $sChannel, "Timezone $targetTZ not found. See: https://pastebin.com/4p4pby3y");
                return;
            }

            if ($self->_set_user_tz($targetNick, $targetTZ)) {
                my $now = DateTime->now(time_zone => $targetTZ);
                botPrivmsg($self, $sChannel, "Updated timezone for $targetNick: $targetTZ " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
                logBot($self, $message, $sChannel, "date", @tArgs);
            }
            return;

        } elsif (defined($tArgs[1]) && $tArgs[1] =~ /^del$/i && defined($tArgs[2])) {
            my $targetNick = $tArgs[2];
            my $tz = $self->_get_user_tz($targetNick);
            unless (defined $tz) {
                botPrivmsg($self, $sChannel, "$targetNick has no defined timezone.");
                return;
            }

            if ($self->_del_user_tz($targetNick)) {
                botPrivmsg($self, $sChannel, "Deleted timezone for $targetNick.");
                logBot($self, $message, $sChannel, "date", @tArgs);
            }
            return;

        } else {
            botPrivmsg($self, $sChannel, "Usage:");
            botPrivmsg($self, $sChannel, "  date user add <nick> <timezone>");
            botPrivmsg($self, $sChannel, "  date user del <nick>");
            return;
        }
    }

    # Handle alias
    $arg0 = $alias{lc $arg0} if exists $alias{lc $arg0};

    # Check if it's a known user
    my $user_tz = $self->_get_user_tz($arg0);
    if ($user_tz) {
        my $now = DateTime->now(time_zone => $user_tz);
        botPrivmsg($self, $sChannel, "Current date for $arg0 ($user_tz): " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return;
    }

    # Check if it's a valid timezone
    if ($self->_tz_exists($arg0)) {
        my $now = DateTime->now(time_zone => $arg0);
        botPrivmsg($self, $sChannel, "$arg0 : " . $now->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
        return;
    }

    botPrivmsg($self, $sChannel, "Unknown user or timezone: $arg0");
    botPrivmsg($self, $sChannel, "See: https://pastebin.com/4p4pby3y");
}



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

sub addResponder {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user
    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged in - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->level eq 'Master') {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Detect channel scope
    my $id_channel = 0;
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
        my $channel_obj = $self->{channels}{$sChannel};
        unless ($channel_obj) {
            botNotice($self, $sNick, "$sChannel is not registered.");
            return;
        }
        $id_channel = $channel_obj->get_id;
    }

    # Syntax
    my $syntax_msg = "Syntax: addresponder [#channel] <chance> <responder> | <answer>";
    my $chance = shift @tArgs;
    unless (defined $chance && $chance =~ /^[0-9]+$/ && $chance <= 100) {
        botNotice($self, $sNick, $syntax_msg);
        return;
    }

    my $joined_args = join(' ', @tArgs);
    my ($responder, $answer) = split(/\s*\|\s*/, $joined_args, 2);
    unless ($responder && $answer) {
        botNotice($self, $sNick, $syntax_msg);
        return;
    }

    # Check if already exists
    my $sth = $self->{dbh}->prepare("SELECT * FROM RESPONDERS WHERE id_channel=? AND responder LIKE ?");
    unless ($sth->execute($id_channel, $responder)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $sNick, "Responder '$responder' already exists with answer '$ref->{answer}' ($ref->{chance}%) [hits: $ref->{hits}]");
    } else {
        $sth = $self->{dbh}->prepare("INSERT INTO RESPONDERS (id_channel, chance, responder, answer) VALUES (?, ?, ?, ?)");
        unless ($sth->execute($id_channel, (100 - $chance), $responder, $answer)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        } else {
            my $scope = $id_channel == 0 ? "global" : "channel $sChannel";
            botNotice($self, $sNick, "Added $scope responder: '$responder' ($chance%) → '$answer'");
        }
    }

    $sth->finish;
    return 0;
}



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

sub channelAddBadword {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Utilisateur
    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        noticeConsoleChan($self, $message->prefix . " addbadword command attempt (unauthenticated)");
        return;
    }

    unless ($user->level eq 'Master') {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        noticeConsoleChan($self, $message->prefix . " addbadword command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])");
        return;
    }

    # Canal cible
    if ((!defined $sChannel || $sChannel eq '') && defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless ($sChannel && $sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel is not registered");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Mot interdit
    my $badword = join(" ", @tArgs);
    unless ($badword && $badword ne "") {
        botNotice($self, $sNick, "Syntax: addbadword <#channel> <badword>");
        return;
    }

    # Vérifie si déjà présent
    my $sth = $self->{dbh}->prepare(
        "SELECT id_badwords, badword FROM BADWORDS WHERE id_channel=? AND badword=?"
    );
    unless ($sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        botNotice($self, $sNick, "Badword [$ref->{id_badwords}] '$ref->{badword}' is already defined on $sChannel");
        logBot($self, $message, undef, "addbadword", $sChannel);
        $sth->finish;
        return;
    }
    $sth->finish;

    # Ajout
    $sth = $self->{dbh}->prepare("INSERT INTO BADWORDS (id_channel, badword) VALUES (?, ?)");
    if ($sth->execute($id_channel, $badword)) {
        botNotice($self, $sNick, "Added badword '$badword' to $sChannel");
        logBot($self, $message, undef, "addbadword", "$sChannel $badword");
    } else {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
    }

    $sth->finish;
    return 0;
}



sub channelRemBadword {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Utilisateur
    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        noticeConsoleChan($self, $message->prefix . " rembadword command attempt (unauthenticated)");
        return;
    }

    unless ($user->level eq 'Master') {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        noticeConsoleChan($self, $message->prefix . " rembadword command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])");
        return;
    }

    # Canal cible
    if ((!defined $sChannel || $sChannel eq '') && defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless ($sChannel && $sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless ($channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel is not registered");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Badword
    my $badword = join(" ", @tArgs);
    unless ($badword && $badword ne "") {
        botNotice($self, $sNick, "Syntax: rembadword <#channel> <badword>");
        return;
    }

    # Vérifie l'existence
    my $sth = $self->{dbh}->prepare(
        "SELECT id_badwords FROM BADWORDS WHERE id_channel = ? AND badword = ?"
    );
    unless ($sth->execute($id_channel, $badword)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_badwords = $ref->{id_badwords};
        $sth->finish;

        # Suppression
        $sth = $self->{dbh}->prepare("DELETE FROM BADWORDS WHERE id_badwords = ?");
        if ($sth->execute($id_badwords)) {
            botNotice($self, $sNick, "Removed badword '$badword' from $sChannel");
            logBot($self, $message, undef, "rembadword", "$sChannel $badword");
        } else {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        }
    } else {
        $sth->finish;
        botNotice($self, $sNick, "Badword '$badword' is not set on $sChannel");
    }

    return 0;
}



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

sub IgnoresList {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Récupération de l'utilisateur via son hostmask
    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        noticeConsoleChan($self, $message->prefix . " ignores command attempt (unauthenticated)");
        return;
    }

    unless ($user->level eq "Master") {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        noticeConsoleChan($self, $message->prefix . " ignores command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])");
        return;
    }

    # Canal ou scope global
    my $id_channel = 0;
    my $label = "allchans/private";

    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        my $target = shift @tArgs;
        my $chan_obj = $self->{channels}{$target};

        unless ($chan_obj) {
            botNotice($self, $sNick, "Channel $target is not registered");
            return;
        }

        $id_channel = $chan_obj->get_id;
        $label = $target;
    }

    # Récupération des entrées d'ignore
    my $sth = $self->{dbh}->prepare("SELECT id_ignores, hostmask FROM IGNORES WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    my @results;
    while (my $ref = $sth->fetchrow_hashref) {
        push @results, $ref;
    }
    $sth->finish;

    my $count = scalar @results;
    if ($count == 0) {
        botNotice($self, $sNick, "Ignores ($label) : there are no ignores.");
    } else {
        botNotice($self, $sNick, "Ignores ($label) : $count entr" . ($count > 1 ? "ies" : "y") . " found");
        for my $ref (@results) {
            botNotice($self, $sNick, "ID: $ref->{id_ignores} : $ref->{hostmask}");
        }
    }

    logBot($self, $message, undef, "ignores", $label);
    return 0;
}

sub addIgnore {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        noticeConsoleChan($self, $message->prefix . " ignore command attempt (unauthenticated)");
        return;
    }

    unless ($user->level eq "Master") {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        noticeConsoleChan($self, $message->prefix . " ignore command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])");
        return;
    }

    # Channel context
    my $id_channel = 0;
    my $label = "(allchans/private)";

    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        my $chan_name = shift @tArgs;
        my $chan_obj = $self->{channels}{$chan_name};

        unless ($chan_obj) {
            botNotice($self, $sNick, "Channel $chan_name is not registered");
            return;
        }

        $id_channel = $chan_obj->get_id;
        $label = $chan_name;
    }

    # Hostmask
    my $hostmask = join(" ", @tArgs);
    unless ($hostmask && $hostmask =~ /^.+!.+\@.+$/) {
        botNotice($self, $sNick, "Syntax: ignore [#channel] <hostmask>");
        botNotice($self, $sNick, "Example: nick*!*ident\@*.example.org");
        return;
    }

    # Check existing
    my $sth = $self->{dbh}->prepare("SELECT id_ignores FROM IGNORES WHERE id_channel = ? AND hostmask LIKE ?");
    unless ($sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        botNotice($self, $sNick, "$hostmask is already ignored on $label");
        $sth->finish;
        return;
    }
    $sth->finish;

    # Insert
    $sth = $self->{dbh}->prepare("INSERT INTO IGNORES (id_channel, hostmask) VALUES (?, ?)");
    unless ($sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    my $id = $sth->{mysql_insertid} // "?";
    botNotice($self, $sNick, "Added ignore ID $id $hostmask on $label");
    $sth->finish;

    return 0;
}

sub delIgnore {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $user = $self->get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        noticeConsoleChan($self, $message->prefix . " unignore command attempt (unauthenticated)");
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless ($user->level eq "Master") {
        noticeConsoleChan($self, $message->prefix . " unignore command attempt (level [Master] for user " . $user->nickname . " [" . $user->level . "])");
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Channel context
    my $id_channel = 0;
    my $label = "(allchans/private)";

    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        my $chan = shift @tArgs;
        my $chan_obj = $self->{channels}{$chan};
        unless ($chan_obj) {
            botNotice($self, $sNick, "Channel $chan is undefined");
            return;
        }
        $id_channel = $chan_obj->get_id;
        $label = $chan;
    }

    # Hostmask
    my $hostmask = join(" ", @tArgs);
    unless ($hostmask && $hostmask =~ /^.+!.+\@.+$/) {
        botNotice($self, $sNick, "Syntax: unignore [#channel] <hostmask>");
        botNotice($self, $sNick, "Example: nick*!*ident\@*.example.org");
        return;
    }

    # Lookup
    my $sth = $self->{dbh}->prepare("SELECT id_ignores FROM IGNORES WHERE id_channel = ? AND hostmask LIKE ?");
    unless ($sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        botNotice($self, $sNick, "$hostmask is not ignored on $label");
        return;
    }

    # Delete
    $sth = $self->{dbh}->prepare("DELETE FROM IGNORES WHERE id_channel = ? AND hostmask LIKE ?");
    unless ($sth->execute($id_channel, $hostmask)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr");
    } else {
        botNotice($self, $sNick, "Deleted ignore $hostmask on $label");
    }

    $sth->finish;
    return 0;
}



# Search for a youtube video
sub youtubeSearch(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $conf = $self->{conf};
	my $APIKEY = $conf->get('main.YOUTUBE_APIKEY');

	my $id_chanset_list = getIdChansetList($self,"YoutubeSearch");
	if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
		$self->{logger}->log(3,"id_chanset_list = $id_chanset_list");
		my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
		unless (defined($id_channel_set) && ($id_channel_set ne "")) {
			return undef;
		} else {
			$self->{logger}->log(3,"id_channel_set = $id_channel_set");
		}
	} else {
		return undef;
	}

	my $sYoutubeId;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"yt <search>");
		return undef;
	}
	my $sText = join(" ",@tArgs);
	$sText = url_encode_utf8($sText);
	$self->{logger}->log(3,"youtubeSearch() on $sText");

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
				my @tYoutubeId = $hYoutubeItems{'id'};
				my %hYoutubeId = %{$tYoutubeId[0]};
				$self->{logger}->log(4,"displayYoutubeDetails() sYoutubeInfo Id : " . Dumper(%hYoutubeId));
				$sYoutubeId = $hYoutubeId{'videoId'};
				$self->{logger}->log(4,"displayYoutubeDetails() sYoutubeId : $sYoutubeId");
			}
			else {
				$self->{logger}->log(3,"displayYoutubeDetails() Invalid id : $sYoutubeId");
			}
		}
		else {
			$self->{logger}->log(3,"displayYoutubeDetails() curl empty result for : curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\"");
		}
	}

	if (defined($sYoutubeId) && ($sYoutubeId ne "")) {
		$self->{logger}->log(3,"displayYoutubeDetails() sYoutubeId = $sYoutubeId");

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

					if (defined($sTitle) && ($sTitle ne "") && defined($sDuration) && ($sDuration ne "") && defined($sViewCount) && ($sViewCount ne "")) {
						my $sMsgSong = String::IRC->new('[')->white('black');
						$sMsgSong .= String::IRC->new('You')->black('white');
						$sMsgSong .= String::IRC->new('Tube')->white('red');
						$sMsgSong .= String::IRC->new(']')->white('black');
						$sMsgSong .= String::IRC->new(" https://www.youtube.com/watch?v=$sYoutubeId - $sTitle ")->white('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sDisplayDuration ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sViewCount")->grey('black');
						botPrivmsg($self,$sChannel,"($sNick) $sMsgSong");
					}
					else {
						$self->{logger}->log(3,"displayYoutubeDetails() one of the youtube field is undef or empty");
						$self->{logger}->log(3,"sTitle=$sTitle") if defined $sTitle;
						$self->{logger}->log(3,"sDuration=$sDuration") if defined $sDuration;
						$self->{logger}->log(3,"sViewCount=$sViewCount") if defined $sViewCount;
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
		my @sources = $json->{'icestats'}{'source'};

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

# Get the current listeners from the radio stream
sub getRadioCurrentListeners(@) {
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
		my @sources = $json->{'icestats'}{'source'};

		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'listeners'})) {
				return $source{'listeners'};
			} else {
				return "N/A";
			}
		} else {
			return undef;
		}
	} else {
		return "N/A";
	}
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

# Display the current song playing on the radio, with optional remaining time
sub displayRadioCurrentSong(@) {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME          = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT              = $conf->get('radio.RADIO_PORT');
	my $RADIO_SOURCE            = $conf->get('radio.RADIO_SOURCE');
	my $RADIO_URL               = $conf->get('radio.RADIO_URL');
	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');

	# Determine target channel
	my $channel_obj;
	if (!defined($sChannel) || $sChannel eq '') {
		if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
			$sChannel = shift @tArgs;
			$channel_obj = $self->{channels}{$sChannel};
			unless (defined $channel_obj) {
				botNotice($self, $sNick, "Channel $sChannel is not registered");
				return;
			}
		} else {
			botNotice($self, $sNick, "Syntax: song <#channel>");
			return;
		}
	} else {
		$channel_obj = $self->{channels}{$sChannel};
		unless (defined $channel_obj) {
			botNotice($self, $sNick, "Channel $sChannel is not registered");
			return;
		}
	}

	# Get current song title and harbor status
	my $sRadioCurrentSongTitle = getRadioCurrentSong($self);
	my $sHarbor = getRadioHarbor($self);
	my $bRadioLive = 0;

	if (defined($sHarbor) && $sHarbor ne '') {
		$self->{logger}->log(3, $sHarbor);
		$bRadioLive = isRadioLive($self, $sHarbor);
	}

	# If a song is currently playing
	if (defined($sRadioCurrentSongTitle) && $sRadioCurrentSongTitle ne '') {
		my $sMsgSong = String::IRC->new('[ ')->white('black');

		# Build radio link
		if ($RADIO_PORT == 443) {
			$sMsgSong .= String::IRC->new("https://$RADIO_HOSTNAME/$RADIO_URL")->orange('black');
		} else {
			$sMsgSong .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
		}

		$sMsgSong .= String::IRC->new(' ] ')->white('black');
		$sMsgSong .= String::IRC->new(' - ')->white('black');
		$sMsgSong .= String::IRC->new(' [ ')->orange('black');

		# Show live status if applicable
		if ($bRadioLive) {
			$sMsgSong .= String::IRC->new('Live - ')->white('black');
		}

		# Append current song title
		$sMsgSong .= String::IRC->new($sRadioCurrentSongTitle)->white('black');
		$sMsgSong .= String::IRC->new(' ]')->orange('black');

		# If not live, show remaining time
		unless ($bRadioLive) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && $LIQUIDSOAP_TELNET_HOST ne '') {
				my $sRemainingTime = getRadioRemainingTime($self);
				$self->{logger}->log(3, "displayRadioCurrentSong() sRemainingTime = $sRemainingTime");

				my $iTotal = int($sRemainingTime);
				my $iMin   = int($iTotal / 60);
				my $iSec   = $iTotal % 60;

				my $sTimeRemaining = "";
				if ($iMin > 0) {
					$sTimeRemaining .= "$iMin mn";
					$sTimeRemaining .= "s" if $iMin > 1;
					$sTimeRemaining .= " and ";
				}
				$sTimeRemaining .= "$iSec sec";
				$sTimeRemaining .= "s" if $iSec > 1;
				$sTimeRemaining .= " remaining";

				$sMsgSong .= String::IRC->new(' - ')->white('black');
				$sMsgSong .= String::IRC->new(' [ ')->orange('black');
				$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
				$sMsgSong .= String::IRC->new(' ]')->orange('black');
			}
		}

		botPrivmsg($self, $sChannel, "$sMsgSong");
	} else {
		botNotice($self, $sNick, "Radio is currently unavailable");
	}
}

# Display the current song on the radio
sub displayRadioListeners(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT     = $conf->get('radio.RADIO_PORT');
	my $RADIO_SOURCE   = $conf->get('radio.RADIO_SOURCE');
	my $RADIO_URL      = $conf->get('radio.RADIO_URL');
	
	my $sRadioCurrentListeners = getRadioCurrentListeners($self);

	if (defined($sRadioCurrentListeners) && ($sRadioCurrentListeners ne "")) {
		my $sMsgListeners = String::IRC->new('(')->white('red');
		$sMsgListeners .= String::IRC->new(')')->maroon('red');
		$sMsgListeners .= String::IRC->new('(')->red('maroon');
		$sMsgListeners .= String::IRC->new(')')->black('maroon');
		$sMsgListeners .= String::IRC->new('( ')->maroon('black');
		$sMsgListeners .= String::IRC->new('( ')->red('black');
		$sMsgListeners .= String::IRC->new('Currently ')->silver('black');
		$sMsgListeners .= String::IRC->new(')-( ')->red('black');
		$sMsgListeners .= int($sRadioCurrentListeners);
		$sMsgListeners .= String::IRC->new(' )-( ')->red('black');
		$sMsgListeners .= String::IRC->new("listener(s)")->white('black');
		$sMsgListeners .= String::IRC->new(' ) ')->red('black');
		$sMsgListeners .= String::IRC->new(')')->maroon('black');
		$sMsgListeners .= String::IRC->new('(')->black('maroon');
		$sMsgListeners .= String::IRC->new(')')->red('maroon');
		$sMsgListeners .= String::IRC->new('(')->maroon('red');
		$sMsgListeners .= String::IRC->new(')')->white('red');

		botPrivmsg($self,$sChannel,"$sMsgListeners");
	} else {
		botNotice($self,$sNick,"Radio is currently unavailable");
	}
}

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




# Skip to the next song in the radio stream
sub radioNext {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Retrieve user object from the IRC message
    my $user = $self->get_user_from_message($message);

    unless ($user && $user->id) {
        botNotice($self, $sNick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " nextsong command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Administrator")) {
        my $msg = $message->prefix . " nextsong command attempt (user " . $user->nickname . " does not have [Administrator] rights)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Retrieve radio config
    my $conf = $self->{conf};
    my $RADIO_HOSTNAME         = $conf->get('radio.RADIO_HOSTNAME');
    my $RADIO_PORT             = $conf->get('radio.RADIO_PORT');
    my $RADIO_URL              = $conf->get('radio.RADIO_URL');
    my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
    my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

    unless ($LIQUIDSOAP_TELNET_HOST) {
        $self->{logger}->log(0, "radioNext(): LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
        return;
    }

    # Transform mountpoint
    my $mountpoint = $RADIO_URL;
    $mountpoint =~ s/\./(dot)/;

    # Build telnet command
    my $cmd = qq{echo -ne "$mountpoint.skip\\nquit\\n" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT};

    # Execute command
    open my $fh, "$cmd |" or do {
        botNotice($self, $sNick, "Unable to connect to LIQUIDSOAP telnet port");
        return;
    };

    my $i = 0;
    while (my $line = <$fh>) {
        chomp($line);
        $i++;
    }
    close $fh;

    if ($i > 0) {
        my $msg = "";
        $msg .= String::IRC->new('[ ')->grey('black');
        $msg .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
        $msg .= String::IRC->new(' ] ')->grey('black');
        $msg .= String::IRC->new(' - ')->white('black');
        $msg .= String::IRC->new(' [ ')->orange('black');
        $msg .= String::IRC->new("$sNick skipped to next track")->grey('black');
        $msg .= String::IRC->new(' ]')->orange('black');
        botPrivmsg($self, $sChannel, $msg);
    }
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

# Display the last N commands from the ACTIONS_LOG table
sub lastCom {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user auth info
    my (
        $uid, $level, $level_desc, $auth,
        $handle, $passwd, $info1, $info2
    ) = getNickInfo($self, $message);

    # Check if user is authenticated and has "Master" level
    unless (defined $uid && $auth && defined $level && checkUserLevel($self, $level, "Master")) {
        my $why = !$auth ? "is not logged in" : "does not have [Master] rights";
        my $msg = $message->prefix . " lastcom command attempt (user $handle $why)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick,
            $auth
                ? "Your level does not allow you to use this command."
                : "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password"
        );
        return;
    }

    # Determine number of lines to show
    my $max_lines = 8;
    my $nb_lines = 5;
    if (defined $tArgs[0] && $tArgs[0] =~ /^\d+$/ && $tArgs[0] != 0) {
        if ($tArgs[0] > $max_lines) {
            $nb_lines = $max_lines;
            botNotice($self, $sNick, "lastCom: max lines $max_lines");
        } else {
            $nb_lines = $tArgs[0];
        }
    }

    # Prepare and execute SQL query
    my $sql = "SELECT * FROM ACTIONS_LOG ORDER BY ts DESC LIMIT ?";
    my $sth = $self->{dbh}->prepare($sql);
    unless ($sth->execute($nb_lines)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sql");
        return;
    }

    # Format and display results
    while (my $row = $sth->fetchrow_hashref()) {
        my $ts        = $row->{ts};
        my $id_user   = $row->{id_user};
        my $hostmask  = $row->{hostmask};
        my $action    = $row->{action};
        my $args      = $row->{args} // "";

        my $userhandle = getUserhandle($self, $id_user);
        $userhandle = (defined $userhandle && $userhandle ne "") ? $userhandle : "Unknown";

        my $chan_obj = $self->getChannelById($row->{id_channel});
        my $channel_str = defined $chan_obj ? " " . $chan_obj->{name} : "";

        botNotice($self, $sNick, "$ts ($userhandle)$channel_str $hostmask $action $args");
    }

    logBot($self, $message, $sChannel, "lastcom", @tArgs);
}


# Handles all quote-related commands: add, del, view, search, random, stats
sub mbQuotes {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

	# Show syntax if no subcommand is provided
	unless (@tArgs && $tArgs[0] ne "") {
		$self->_printQuoteSyntax($sNick);
		return;
	}

	# Extract subcommand and normalize
	my $subcmd = lc shift @tArgs;

	# Retrieve user info
	my ($uid, $level, $level_desc, $auth, $handle) = getNickInfo($self, $message);

	# Authenticated + has level "User"
	if ($uid && $auth && $level && checkUserLevel($self, $level, "User")) {

		return mbQuoteAdd($self, $message, $uid, $handle, $sNick, $sChannel, @tArgs)    if $subcmd =~ /^(add|a)$/;
		return mbQuoteDel($self, $message, $handle, $sNick, $sChannel, @tArgs)          if $subcmd =~ /^(del|d)$/;
		return mbQuoteView($self, $message, $sNick, $sChannel, @tArgs)                  if $subcmd =~ /^(view|v)$/;
		return mbQuoteSearch($self, $message, $sNick, $sChannel, @tArgs)                if $subcmd =~ /^(search|s)$/;
		return mbQuoteRand($self, $message, $sNick, $sChannel, @tArgs)                  if $subcmd =~ /^(random|r)$/;
		return mbQuoteStats($self, $message, $sNick, $sChannel, @tArgs)                 if $subcmd eq "stats";

		# Unknown subcommand
		$self->_printQuoteSyntax($sNick);
		return;
	}

	# Anonymous users: allow safe commands
	return mbQuoteView($self, $message, $sNick, $sChannel, @tArgs)     if $subcmd =~ /^(view|v)$/;
	return mbQuoteSearch($self, $message, $sNick, $sChannel, @tArgs)   if $subcmd =~ /^(search|s)$/;
	return mbQuoteRand($self, $message, $sNick, $sChannel, @tArgs)     if $subcmd =~ /^(random|r)$/;
	return mbQuoteStats($self, $message, $sNick, $sChannel, @tArgs)    if $subcmd eq "stats";
	return mbQuoteAdd($self, $message, undef, undef, $sNick, $sChannel, @tArgs) if $subcmd =~ /^(add|a)$/;

	# If we reach this, it's an unauthorized or invalid command
	my $msg = $message->prefix . " q command attempt (user $handle is not logged in)";
	noticeConsoleChan($self, $msg);
	botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
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
	unless ($sth->execute($id_channel, (defined($iMatchingUserId) ? $iMatchingUserId : 0), $sQuoteText)) {
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
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? AND id_quotes=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$id_quotes)) {
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

# Modify a user's global level, autologin status, or fortniteid
sub mbModUser(@) {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

	# Get caller info
	my ($uid, $level, $level_desc, $auth, $handle) = getNickInfo($self, $message);

	return unless defined $uid;
	unless ($auth) {
		noticeConsoleChan($self, $message->prefix . " moduser attempt (user $handle not logged in)");
		botNotice($self, $sNick, "You must be logged in to use this command.");
		return;
	}
	unless (checkUserLevel($self, $level, "Master")) {
		noticeConsoleChan($self, $message->prefix . " moduser attempt (required: Master; current: $level_desc)");
		botNotice($self, $sNick, "Your level does not allow you to use this command.");
		return;
	}

	# Missing arguments
	unless (@tArgs) {
		_sendModUserSyntax($self, $sNick);
		return;
	}

	my $target_nick = shift @tArgs;
	my $target_uid = getIdUser($self, $target_nick);
	unless ($target_uid) {
		botNotice($self, $sNick, "User: $target_nick does not exist");
		return;
	}

	unless (@tArgs) {
		_sendModUserSyntax($self, $sNick);
		return;
	}

	my $subcmd = shift @tArgs;
	my @oArgs = ($target_nick, $subcmd, @tArgs);

	# === LEVEL MODIFICATION ===
	if ($subcmd =~ /^level$/i) {
		my $target_level_str = lc($tArgs[0] // '');
		unless ($target_level_str =~ /^(owner|master|administrator|user)$/) {
			botNotice($self, $sNick, "moduser $target_nick level <Owner|Master|Administrator|User>");
			return;
		}

		my $target_level = getLevel($self, $target_level_str);
		my $current_level = getLevelUser($self, $target_nick);

		# Prevent accidental ownership transfer
		if ($target_level == 0 && $level == 0 && (!defined($tArgs[1]) || $tArgs[1] !~ /^force$/i)) {
			botNotice($self, $sNick, "Do you really want to do that?");
			botNotice($self, $sNick, "If you know what you're doing: moduser $target_nick level Owner force");
			return;
		}

		# Check if caller has sufficient privileges
		if ($level < $current_level && $level < $target_level) {
			if ($target_level == $current_level) {
				botNotice($self, $sNick, "User $target_nick is already a global $target_level_str.");
			} else {
				if (setUserLevel($self, $target_nick, getIdUserLevel($self, $target_level_str))) {
					botNotice($self, $sNick, "User $target_nick is now a global $target_level_str.");
					logBot($self, $message, $sChannel, "moduser", @oArgs);
				} else {
					botNotice($self, $sNick, "Could not set $target_nick as global $target_level_str.");
				}
			}
		} else {
			my $target_desc = getUserLevelDesc($self, $current_level);
			if ($target_level == $current_level) {
				botNotice($self, $sNick, "You can't set $target_nick to $target_level_str: they're already $target_desc.");
			} else {
				botNotice($self, $sNick, "You can't set $target_nick ($target_desc) to $target_level_str.");
			}
		}
		return;
	}

	# === AUTOLOGIN ===
	elsif ($subcmd =~ /^autologin$/i) {
		my $arg = lc($tArgs[0] // '');
		unless ($arg =~ /^(on|off)$/) {
			botNotice($self, $sNick, "moduser $target_nick autologin <on|off>");
			return;
		}

		my $sth;
		if ($arg eq "on") {
			$sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
			$sth->execute($target_nick);
			if ($sth->fetchrow_hashref()) {
				botNotice($self, $sNick, "Autologin is already ON for $target_nick");
			} else {
				$sth = $self->{dbh}->prepare("UPDATE USER SET username = '#AUTOLOGIN#' WHERE nickname = ?");
				if ($sth->execute($target_nick)) {
					botNotice($self, $sNick, "Set autologin ON for $target_nick");
					logBot($self, $message, $sChannel, "moduser", @oArgs);
				}
			}
		}
		else {  # off
			$sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND username = '#AUTOLOGIN#'");
			$sth->execute($target_nick);
			if ($sth->fetchrow_hashref()) {
				$sth = $self->{dbh}->prepare("UPDATE USER SET username = NULL WHERE nickname = ?");
				if ($sth->execute($target_nick)) {
					botNotice($self, $sNick, "Set autologin OFF for $target_nick");
					logBot($self, $message, $sChannel, "moduser", @oArgs);
				}
			} else {
				botNotice($self, $sNick, "Autologin is already OFF for $target_nick");
			}
		}
		$sth->finish if $sth;
		return;
	}

	# === FORTNITEID ===
	elsif ($subcmd =~ /^fortniteid$/i) {
		my $fortniteid = $tArgs[0] // '';
		unless ($fortniteid ne '') {
			botNotice($self, $sNick, "moduser $target_nick fortniteid <id>");
			return;
		}

		my $sth = $self->{dbh}->prepare("SELECT * FROM USER WHERE nickname = ? AND fortniteid = ?");
		$sth->execute($target_nick, $fortniteid);
		if ($sth->fetchrow_hashref()) {
			botNotice($self, $sNick, "fortniteid is already $fortniteid for $target_nick");
		} else {
			$sth = $self->{dbh}->prepare("UPDATE USER SET fortniteid = ? WHERE nickname = ?");
			if ($sth->execute($fortniteid, $target_nick)) {
				botNotice($self, $sNick, "Set fortniteid $fortniteid for $target_nick");
				logBot($self, $message, $sChannel, "fortniteid", @oArgs);
			}
		}
		$sth->finish;
		return;
	}

	# Unknown command
	else {
		botNotice($self, $sNick, "Unknown moduser command: $subcmd");
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
				my $sLatest = time2str("%Y-%m-%d %H-%M-%S", $currentTs);
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
						my $sLatest = time2str("%Y-%m-%d %H-%M-%S", $currentTs);
						$self->{logger}->log(4, "checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max set latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds");
						return 0;
					}
				} else {
					my $sLatest = time2str("%Y-%m-%d %H-%M-%S", $currentTs);
					my $endTs = $latest + $timetowait;

					if ($currentTs > $endTs) {
						$nbmsg = 1;
						$self->{logger}->log(0, "checkAntiFlood() End of antiflood for channel $sChannel");
						$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?, first=?, latest=?, notification=? WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($nbmsg, $currentTs, $currentTs, 0, $id_channel)) {
							$self->{logger}->log(1, "SQL Error : $DBI::errstr | Query : $sQuery");
						} else {
							my $sLatest = time2str("%Y-%m-%d %H-%M-%S", $currentTs);
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
					my $sLatest = time2str("%Y-%m-%d %H-%M-%S", $currentTs);
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

# Set or display anti-flood parameters for a given channel
sub setChannelAntiFloodParams {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	my $sTargetChannel = $sChannel;

	# Retrieve user auth info
	my ($uid, $level, $level_desc, $auth, $handle) = getNickInfo($self, $message);
	return unless defined $uid;

	unless ($auth) {
		noticeConsoleChan($self, $message->prefix . " antifloodset attempt (user $handle not logged in)");
		botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		return;
	}

	unless (checkUserLevel($self, $level, "Master")) {
		noticeConsoleChan($self, $message->prefix . " antifloodset attempt (required: Master, user: $handle [$level])");
		botNotice($self, $sNick, "Your level does not allow you to use this command.");
		return;
	}

	# Optional channel as first argument
	if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
		$sChannel = shift @tArgs;
		$sTargetChannel = $sChannel;
	}

	unless ($sChannel) {
		botNotice($self, $sNick, "Undefined channel.");
		botNotice($self, $sNick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
		return;
	}

	# Resolve channel object
	my $channel_obj = $self->{channels}{$sChannel};
	unless ($channel_obj) {
		botNotice($self, $sNick, "Channel $sChannel is not registered.");
		return;
	}
	my $id_channel = $channel_obj->get_id;

	# Show current values if no args provided
	if (@tArgs == 0) {
		$self->{logger}->log(3, "Fetching antiflood settings for $sChannel");

		my $sth = $self->{dbh}->prepare(
			"SELECT * FROM CHANNEL, CHANNEL_FLOOD WHERE CHANNEL.id_channel = CHANNEL_FLOOD.id_channel AND CHANNEL.name LIKE ?"
		);
		unless ($sth->execute($sChannel)) {
			$self->{logger}->log(1, "SQL Error: $DBI::errstr");
			return;
		}

		if (my $row = $sth->fetchrow_hashref()) {
			my ($max, $period, $wait) = @$row{qw(nbmsg_max duration timetowait)};
			botNotice($self, $sNick, "antifloodset for $sChannel: $max message" . ($max > 1 ? "s" : "") .
				" max in $period second" . ($period > 1 ? "s" : "") .
				", wait $wait second" . ($wait > 1 ? "s" : "") . " if breached");
		} else {
			botNotice($self, $sNick, "No antiflood settings found for $sChannel");
		}
		return 0;
	}

	# Validate the 3 numeric args
	for my $i (0..2) {
		unless (defined($tArgs[$i]) && $tArgs[$i] =~ /^\d+$/) {
			botNotice($self, $sNick, "Syntax: antifloodset [#channel] <max_msg> <period_sec> <wait_sec>");
			return;
		}
	}

	# Check that AntiFlood is enabled via chanset
	my $id_chanset = getIdChansetList($self, "AntiFlood");
	my $id_channelset = getIdChannelSet($self, $sChannel, $id_chanset);

	unless ($id_channelset) {
		botNotice($self, $sNick, "You must enable AntiFlood first: chanset $sChannel +AntiFlood");
		return;
	}

	# Update database
	my $sth = $self->{dbh}->prepare(
		"UPDATE CHANNEL_FLOOD SET nbmsg_max = ?, duration = ?, timetowait = ? WHERE id_channel = ?"
	);
	if ($sth->execute(@tArgs[0..2], $id_channel)) {
		$sth->finish;
		botNotice($self, $sNick, "Antiflood parameters set for $sChannel: $tArgs[0] messages max in $tArgs[1] sec, wait $tArgs[2] sec");
		return 0;
	} else {
		$self->{logger}->log(1, "SQL Error: $DBI::errstr");
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


sub leet(@) {
	my ($self,$input) = @_;
	my @english = ("i","I","l","a", "e", "s", "S", "A", "o", "O", "t", "l", "ph", "y", "H", "W", "M", "D", "V", "x"); 
	my @leet = ("1","1","|","4", "3", "5", "Z", "4", "0", "0", "7", "1", "f", "Y", "|-|", "\\/\\/", "|\\/|", "|)", "\\/", "><");

	my $i;
	for ($i=0;$i<=$#english;$i++) {
		my $c = $english[$i];
		my $l = $leet[$i];
		$input =~ s/$c/$l/g;
	}
	return $input;
}

sub displayLeetString(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"Syntax : leet <string>");
		return undef;
	}
	else {
		botPrivmsg($self,$sChannel,"l33t($sNick) : " . leet($self,join(" ",@tArgs)));
	}
}

# Reload the bot configuration file (rehash), restricted to Master-level users
sub mbRehash {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

	# Fetch user authentication info
	my (
		$uid, $level, $level_desc, $auth,
		$handle, $passwd, $info1, $info2
	) = getNickInfo($self, $message);

	# Reject if user not identified
	return unless defined $uid;

	# Reject if not logged in
	unless ($auth) {
		my $msg = $message->prefix . " rehash command attempt (user $handle is not logged in)";
		noticeConsoleChan($self, $msg);
		botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		return;
	}

	# Reject if user level is insufficient
	unless (checkUserLevel($self, $level, "Master")) {
		my $msg = $message->prefix . " rehash command attempt (command level [Master] for user $handle [$level])";
		noticeConsoleChan($self, $msg);
		botNotice($self, $sNick, "Your level does not allow you to use this command.");
		return;
	}

	# Perform configuration reload
	readConfigFile($self);

	# Notify in appropriate channel or private
	if ($sChannel && $sChannel ne "") {
		botPrivmsg($self, $sChannel, "($sNick) Successfully rehashed");
	} else {
		botNotice($self, $sNick, "Successfully rehashed");
	}

	# Log the action
	logBot($self, $message, $sChannel, "rehash", @tArgs);
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

sub mp3(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sText = join (" ",@tArgs);
				unless (defined($sText) && ($sText ne "")) {
					botNotice($self,$sNick,"Syntax : mp3 <title>");
					return undef;
				}
				if ($tArgs[0] eq "count") {
					my $sQuery = "SELECT count(*) as nbMp3 FROM MP3";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {	
						if (my $ref = $sth->fetchrow_hashref()) {
							my $nbMp3 = $ref->{'nbMp3'};
							botPrivmsg($self,$sChannel,"($sNick mp3 count) $nbMp3 in local library");
						}
						else {
							botPrivmsg($self,$sChannel,"($sNick mp3 count) unexpected error");
						}
					}
				}
				elsif ($tArgs[0] eq "id" && (defined($tArgs[1]) && ($tArgs[1] =~ /[0-9]+/))) {
					my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_mp3=?";
					$self->{logger}->log(3,"$sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($tArgs[1])) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {	
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_mp3 = $ref->{'id_mp3'};
							my $id_youtube = $ref->{'id_youtube'};
							my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
							my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
							my $duration = 0;
							my $sMsgSong = "$artist - $title";
							if (defined($id_youtube) && ($id_youtube ne "")) {
								($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
								botPrivmsg($self,$sChannel,"($sNick mp3 search) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube");
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick mp3 search) First result (Library ID : $id_mp3) / $artist - $title");
							}
							logBot($self,$message,$sChannel,"mp3",@tArgs);
						}
						else {
							botPrivmsg($self,$sChannel,"($sNick mp3 search) ID " . $tArgs[1] . " not found");
						}
					}
					$sth->finish;
				}
				else {
					my $searchstring = $sText ;
					$searchstring =~ s/\s+/%/g;
					$searchstring =~ s/'/\\'/g;
					$searchstring =~ s/;//g;
					my $nbMp3 = 0;
					my $sQuery = "SELECT count(*) as nbMp3 FROM MP3 WHERE CONCAT(artist,title) LIKE '%" . $searchstring . "%'";
					$self->{logger}->log(3,"$sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {	
						if (my $ref = $sth->fetchrow_hashref()) {
							$nbMp3 = $ref->{'nbMp3'};
						}
					}
					$sth->finish;
					unless ($nbMp3 > 0 ) {
						botPrivmsg($self,$sChannel,"($sNick mp3 search) $sText not found");
						return undef;
					}

					$sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE CONCAT(artist,title) LIKE '%" . $searchstring . "%' LIMIT 1";
					$self->{logger}->log(3,"$sQuery = $sQuery");
					$sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {	
						if (my $ref = $sth->fetchrow_hashref()) {
							my $sNbMp3 = ( $nbMp3 > 1 ? "matches" : "match" );
							my $id_mp3 = $ref->{'id_mp3'};
							my $id_youtube = $ref->{'id_youtube'};
							my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
							my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
							my $duration = 0;
							my $sMsgSong = "$artist - $title";
							if (defined($id_youtube) && ($id_youtube ne "")) {
								($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
								botPrivmsg($self,$sChannel,"($sNick mp3 search) $nbMp3 $sNbMp3, first result : (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube");
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick mp3 search) $nbMp3 $sNbMp3, first result : (Library ID : $id_mp3) / $artist - $title");
							}
							if ( $nbMp3 > 1 ) {
								$sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE CONCAT(artist,title) LIKE '%" . $searchstring . "%' LIMIT 10";
								$self->{logger}->log(3,"$sQuery = $sQuery");
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute()) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									my $sOutput = "";
									while (my $ref = $sth->fetchrow_hashref()) {
										my $id_mp3 = $ref->{'id_mp3'};
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
										}
										$sOutput .= "$id_mp3 ";
									}
									if ($nbMp3 > 10 ) {
										$sOutput .= "And " . ( $nbMp3 - 10 ) . " more..."
									}
									botPrivmsg($self,$sChannel,"($sNick mp3 search) Next 10 Library IDs : " . $sOutput);
								}
								logBot($self,$message,$sChannel,"mp3",@tArgs);
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " mp3 command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " mp3 command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Execute a shell command and return the last 3 lines (Owner-only command)
sub mbExec {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Retrieve user object from message
    my $user = $self->get_user_from_message($message);

    # Check authentication
    unless ($user && $user->is_authenticated) {
        my $who = $user ? $user->nickname : "unknown";
        my $msg = $message->prefix . " exec command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Check privilege
    unless ($user->has_level("Owner")) {
        my $msg = $message->prefix . " exec command attempt (command level [Owner] for user " . $user->nickname . " [" . ($user->level // 'undef') . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Join command arguments
    my $command = join(" ", @tArgs);
    unless ($command && $command ne "") {
        botNotice($self, $sNick, "Syntax: exec <command>");
        return;
    }

    # Block dangerous commands
    if ($command =~ /\brm\s+-rf\b/i || $command =~ /:()\s*{\s*:|:&};:/ || $command =~ /shutdown|reboot|mkfs|dd\s+if=|>\s+\/dev\/sd/) {
        botNotice($self, $sNick, "Don't be that evil!");
        return;
    }

    # Execute command and output last 3 lines
    my $shell = "$command | tail -n 3 2>&1";
    open my $cmd_fh, "-|", $shell or do {
        $self->{logger}->log(3, "mbExec: Failed to execute: $command");
        botNotice($self, $sNick, "Execution failed.");
        return;
    };

    my $i = 0;
    my $has_output = 0;
    while (my $line = <$cmd_fh>) {
        chomp $line;
        botPrivmsg($self, $sChannel, "$i: $line");
        $has_output = 1;
        last if ++$i >= 3;
    }
    close $cmd_fh;

    botPrivmsg($self, $sChannel, "No output.") unless $has_output;
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

# check CHANNEL_LOG table for a specific pattern
sub mbChannelLog(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sText = join ("%",@tArgs);
				unless (defined($sText) && ($sText ne "")) {
					botNotice($self,$sNick,"Syntax : qlog [-n nickname] <word1> <word2> ... <<wordn>");
					return undef;
				}
				elsif (defined($tArgs[0]) && ($tArgs[0] eq "-n") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					shift @tArgs;
					my $nickname = $tArgs[0];
					shift @tArgs;
					if (defined($nickname) && ($nickname ne "")) {
						my $searchstring = join ("%",@tArgs);
						$searchstring =~ s/'/\\'/;
						$searchstring =~ s/;//;
						my $sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL_LOG.id_channel=CHANNEL.id_channel AND CHANNEL.name like ? AND nick LIKE ? AND publictext LIKE '%" . $searchstring . "%' AND publictext not LIKE '%qlog%' ORDER BY RAND() LIMIT 1";
						$self->{logger}->log(3,"sQuery = $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel,$nickname)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $sOutput = "";
							if (my $ref = $sth->fetchrow_hashref()) {
								my $publictext = $ref->{'publictext'};
								my $nick = $ref->{'nick'};
								my $sDate = $ref->{'ts'};
								$sOutput = $publictext;
								botPrivmsg($self,$sChannel,"($sNick qlog search) $sDate <$nick> $sOutput");
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick qlog search) No result");
							}
						}
						$sth->finish;
						logBot($self,$message,$sChannel,"qlog",@tArgs);
					}
					else {
						my $sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL_LOG.id_channel=CHANNEL.id_channel AND CHANNEL.name like ? AND nick LIKE ? AND publictext not LIKE '%qlog%' ORDER BY RAND() LIMIT 1";
						$self->{logger}->log(3,"sQuery = $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel,$nickname)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $sOutput = "";
							if (my $ref = $sth->fetchrow_hashref()) {
								my $publictext = $ref->{'publictext'};
								my $nick = $ref->{'nick'};
								my $sDate = $ref->{'ts'};
								$sOutput = $publictext;
								botPrivmsg($self,$sChannel,"($sNick qlog search) $sDate <$nick> $sOutput");
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick qlog search) No result");
							}
						}
						$sth->finish;
						logBot($self,$message,$sChannel,"qlog",@tArgs);
					}
				}
				else {
					my $searchstring = join ("%",@tArgs);
					$searchstring =~ s/'/\\'/;
					$searchstring =~ s/;//;
					my $sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL_LOG.id_channel=CHANNEL.id_channel AND CHANNEL.name like ? AND publictext LIKE '%" . $searchstring . "%' AND publictext not LIKE '%qlog%' ORDER BY RAND() LIMIT 1";
					$self->{logger}->log(3,"sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sOutput = "";
						if (my $ref = $sth->fetchrow_hashref()) {
							my $publictext = $ref->{'publictext'};
							my $nick = $ref->{'nick'};
							my $sDate = $ref->{'ts'};
							$sOutput = $publictext;
							botPrivmsg($self,$sChannel,"($sNick qlog search) $sDate <$nick> $sOutput");
						}
						else {
							botPrivmsg($self,$sChannel,"($sNick qlog search) No result");
						}
					}
					$sth->finish;
					logBot($self,$message,$sChannel,"qlog",@tArgs);
				}
				
			}
			else {
				my $sNoticeMsg = $message->prefix . " qlog command attempt (command level [Owner] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " qlog command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}	
}

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

sub hailo_ignore(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				unless (defined($tArgs[0] && ($tArgs[0] ne ""))) {
					botNotice($self,$sNick,"Syntax: hailo_ignore <nick>");
					return undef;
				}
				my $sQuery = "SELECT * FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($tArgs[0])) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						$sth->finish;
						botNotice($self,$sNick,"Nick " . $tArgs[0] . " is already ignored by Hailo");
						return undef;
					}
					else {
						$sQuery = "INSERT INTO HAILO_EXCLUSION_NICK (nick) VALUES (?)";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							botNotice($self,$sNick,"Hailo ignored nick " . $tArgs[0]);
							return 1;
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " hailo_ignore command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " hailo_ignore command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub hailo_unignore(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				unless (defined($tArgs[0] && ($tArgs[0] ne ""))) {
					botNotice($self,$sNick,"Syntax: hailo_unignore <nick>");
					return undef;
				}
				my $sQuery = "SELECT * FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($tArgs[0])) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						$sQuery = "DELETE FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							botNotice($self,$sNick,"Hailo unignored nick " . $tArgs[0]);
							return 1;
						}
					}
					else {
						$sth->finish;
						botNotice($self,$sNick,"Nick " . $tArgs[0] . " is not ignored by Hailo");
						return undef;
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " hailo_unignore command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " hailo_unignore command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub hailo_status(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;	
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $hailo = get_hailo($self);
				my $status = $hailo->stats();
				$self->{logger}->log(3,"$status tokens, expressions, previous token links and next token links");
				botPrivmsg($self,$sChannel,"$status tokens, expressions, previous token links and next token links");
			}
			else {
				my $sNoticeMsg = $message->prefix . " hailo_status command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " hailo_status command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

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


sub hailo_chatter(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sTargetChannel = $sChannel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sTargetChannel = $tArgs[0];
					shift @tArgs;
				}
				unless (defined($tArgs[0]) && ($tArgs[0] =~ /[0-9]+/) ) {
					my $ratio = get_hailo_channel_ratio($self,$sTargetChannel);
					if ( $ratio == -1) {
						botNotice($self,$sNick,"No hailo chatter ratio set for $sTargetChannel");	
					}
					else {
						botNotice($self,$sNick,"hailo chatter ratio is " . (100 - $ratio) ."% for $sTargetChannel");
					}
					return undef;
				}
				if ( $tArgs[0] > 100 ) {
					botNotice($self,$sNick,"Syntax: hailo_chatter <ratio>");
					botNotice($self,$sNick,"ratio must be between 0 and 100");
					return undef;
				}
				my $id_chanset_list = getIdChansetList($self,"HailoChatter");
				if (defined($id_chanset_list)) {
					my $id_channel_set = getIdChannelSet($self,$sTargetChannel,$id_chanset_list);
					if (defined($id_channel_set)) {
						my $ret = set_hailo_channel_ratio($self,$sTargetChannel,(100 - $tArgs[0]));
						botNotice($self,$sNick,"HailoChatter's ratio is now set to " . $tArgs[0] . "% on $sTargetChannel");
						return $ret;
					}
					else {
						botNotice($self,$sNick,"Chanset +HailoChatter is not set on $sTargetChannel");
						return undef;
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " hailo_chatter command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " hailo_chatter command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

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

sub mbWhereis(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %WHOIS_VARS;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		$WHOIS_VARS{'nick'} = $tArgs[0];
		$WHOIS_VARS{'sub'} = "mbWhereis";
		$WHOIS_VARS{'caller'} = $sNick;
		$WHOIS_VARS{'channel'} = $sChannel;
		$WHOIS_VARS{'message'} = $message;
		$self->{irc}->send_message("WHOIS", undef, $tArgs[0]);
		%{$self->{WHOIS_VARS}} = %WHOIS_VARS;
		return undef;
	}
	else {
		botNotice($self,$sNick,"Syntax: whereis <nick>");
	}
}

sub userBirthday(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	if (defined($tArgs[0]) && $tArgs[0] ne "") {
		if ($tArgs[0] =~ /^add$|^del$/i) {
			my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
			if (defined($iMatchingUserId)) {
				if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
					if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
						if (defined($tArgs[1]) && ($tArgs[1] =~ /^user$/i) && defined($tArgs[2]) && ($tArgs[2] ne "")) {
							switch ($tArgs[0]) {
								case /^add$/i {
									if (defined($tArgs[3]) && (($tArgs[3] =~  /^[0-9]{2}\/[0-9]{2}$/) || $tArgs[3] =~ /^[0-9]{2}\/[0-9]{2}\/[0-9]{4}$/)) {
										my $sQuery = "SELECT nickname,birthday FROM USER WHERE nickname like ?";
										my $sth = $self->{dbh}->prepare($sQuery);
										unless ($sth->execute($tArgs[2])) {
											$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
										}
										else {
											if (my $ref = $sth->fetchrow_hashref()) {
												my $nickname = $ref->{'nickname'};
												my $birthday = $ref->{'birthday'};
												if (defined($birthday)) {
													botPrivmsg($self,$sChannel,"User $nickname already has a birthday set to $birthday");
													$sth->finish;
													return undef;
												}
												else {
													$sQuery = "UPDATE USER SET birthday=? WHERE nickname like ?";
													$sth = $self->{dbh}->prepare($sQuery);
													unless ($sth->execute($tArgs[3],$tArgs[2	])) {
														$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
													}
													else {
														botPrivmsg($self,$sChannel,"Set " . $tArgs[2] . "'s birthday to $tArgs[3]");
														$sth->finish;
														return 0
													}
												}
												$sth->finish;
												return 0;
											}
											else {
												botPrivmsg($self,$sChannel,"Unknown user $tArgs[2]");
												return undef;
											}
										}
									}
									else {
										botNotice($self,$sNick,"Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
										botNotice($self,$sNick,"Syntax: birthday del user <username>");
										return undef;
									}
								}
								case /^del$/i {
									my $sQuery = "SELECT nickname,birthday FROM USER WHERE nickname like ?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($tArgs[2])) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										if (my $ref = $sth->fetchrow_hashref()) {
											my $nickname = $ref->{'nickname'};
											my $birthday = $ref->{'birthday'};
											if (defined($birthday) && ($birthday ne "")) {
												$sQuery = "UPDATE USER SET birthday=NULL WHERE nickname like ?";
												$sth = $self->{dbh}->prepare($sQuery);
												unless ($sth->execute($tArgs[2])) {
													$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													botPrivmsg($self,$sChannel,"Deleted " . $tArgs[2] . "'s birthday.");
												}
											}
											else {
												botPrivmsg($self,$sChannel,"User $tArgs[2] has no defined birthday.");
												$sth->finish;
												return undef;
											}
										}
										else {
											botPrivmsg($self,$sChannel,"Unknown user $tArgs[2]");
											return undef;
										}
									}
								}
								else {
									botNotice($self,$sNick,"Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
									botNotice($self,$sNick,"Syntax: birthday del user <username>");
									return undef;
								}
							}
							
						}
						else {
							botNotice($self,$sNick,"Syntax: birthday add user <username> [dd/mm | dd/mm/YYYY]");
							botNotice($self,$sNick,"Syntax: birthday del user <username>");
							return undef;
						}
					}
					else {
						botNotice($self,$sNick,"Your level does not allow you to use this command.");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
					return undef;
				}
			}
		}
		elsif (defined($tArgs[0]) && ($tArgs[0] =~ /^next$/i)) {
			my $time = DateTime->now( time_zone => 'America/New_York' );
			my $tday = $time->format_cldr("dd");
			my $tmonth = $time->format_cldr("MM");
			my $tyear = $time->format_cldr("yyyy");
			my $tref = "$tmonth$tday";
			my @bmin;
			my @bcandidate;
			my $bnickname;
			my $sQuery = "SELECT nickname,birthday FROM USER";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute()) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				my $i = 0;
				while (my $ref = $sth->fetchrow_hashref()) {
					my $nickname = $ref->{'nickname'};
					my $birthday = $ref->{'birthday'};
					if (defined($birthday)) {
						my ($bday,$bmonth,$byear);
						if ( $birthday =~ /^([0-9]*)\/([0-9]*)\/([0-9]*)$/ ) {
							$bday = $1;
							$bmonth = $2;
							$byear = $3;
						}
						elsif ( $birthday =~ /^([0-9]*)\/([0-9]*)$/ ) {
							$bday = $1;
							$bmonth = $2;
						}
						my $cbday = "$bmonth$bday";

						unless (defined($bmin[1])) {
							$bmin[0] = $nickname;
							$bmin[1] = $cbday;
						}
						elsif ( $cbday < $bmin[1] ) {
							$bmin[0] = $nickname;
							$bmin[1] = $cbday;
						}

						unless (defined($bcandidate[1])) {
							if ($cbday > $tref) {
								$bcandidate[0] = $nickname;
								$bcandidate[1] = $cbday;
							}
						}
						elsif ( ($cbday > $tref) && (defined($bcandidate[1]) && ($bcandidate[1] > $tref)) && (defined($bcandidate[1]) && ($cbday < $bcandidate[1])) ) {
							$bcandidate[0] = $nickname;
							$bcandidate[1] = $cbday;
						}
						if ( $cbday == $tref ) {
							botPrivmsg($self,$sChannel,"Happy Birthday To: \2$nickname\2 - Hope you have a Great Day! !!!");
						}
						if ( $i < 50 ) { $self->{logger}->log(3,"(birthday next) Min : $bmin[0] $bmin[1] Candidate : " . (defined($bcandidate[0]) ? "$bcandidate[0] " : "N/A ") . (defined($bcandidate[1]) ? "$bcandidate[1]" : "N/A") . " Current $nickname $cbday"); }
						$i++;
					}
				}
				unless ($i > 0) {
					botPrivmsg($self,$sChannel,"No user's birthday defined in database.");
					return undef;
				}
				if ( defined($bcandidate[1]) && $bcandidate[1] > $tref ) {
					$bnickname = $bcandidate[0];
				}
				else {
					$bnickname = $bmin[0];
				}
				$sQuery = "SELECT nickname,birthday FROM USER where nickname LIKE ?";
				$sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($bnickname)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nickname = $ref->{'nickname'};
						my $birthday = $ref->{'birthday'};
						botPrivmsg($self,$sChannel,"Next birthday is " . $nickname . "'s ($birthday)");
					}
				}
				$sth->finish;
			}
			return undef;
		}
		else {
			if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
				my $sQuery = "SELECT nickname,birthday FROM USER WHERE nickname like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($tArgs[0])) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nickname = $ref->{'nickname'};
						my $birthday = $ref->{'birthday'};
						if (defined($birthday)) {
							botPrivmsg($self,$sChannel,$tArgs[0] . "'s birthday is $birthday");
							$sth->finish;
							return 0;
						}
						else {
							botPrivmsg($self,$sChannel,"User " . $tArgs[0] . " has no defined birthday.");
							$sth->finish;
							return undef;
						}
					}
					else {
						botPrivmsg($self,$sChannel,"Unknown user $tArgs[0]");
						$sth->finish;
						return undef;
					}
				}
				$sth->finish;
			}
			else {
				botNotice($self,$sNick,"Syntax: birthday <username>");
			}
		}
	}
	else {
		botNotice($self,$sNick,"Syntax: birthday <username>");
		return undef;
	}
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

# Delete a user from the database
sub delUser(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					$self->{logger}->log(3,"delUser() " . $tArgs[0]);
					my $id_user = getIdUser($self,$tArgs[0]);
					if (defined($id_user)) {
						my $sQuery = "DELETE FROM USER_CHANNEL WHERE id_user=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_user)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						$sQuery = "DELETE FROM USER WHERE id_user=?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_user)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							return undef;
						}
						$sth->finish;
						logBot($self,$message,undef,"deluser","User " . $tArgs[0] . " (id_user : $id_user) has been deleted");
						return undef;
					}
					else {
						botNotice($self,$sNick,"Undefined user " . $tArgs[0]);
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: deluser <username>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix;
				$sNoticeMsg .= " deluser command attempt, (command level [1] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,undef,"adduser",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix;
			$sNoticeMsg .= " deluser command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,undef,"adduser",$sNoticeMsg);
		}
	}
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

# Get Fortnite stats for a user
sub fortniteStats(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	
	my $api_key = $self->{conf}->get('fortnite.API_KEY');
	unless (defined($api_key) && $api_key ne "") {
		$self->{logger}->log(0,"fortnite.API_KEY is undefined in config file");
		return undef;
	}

	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				if (defined($tArgs[0]) && $tArgs[0] ne "") {
					$self->{logger}->log(3,"fortniteStats() $tArgs[0]");
					my $id_user = getIdUser($self,$tArgs[0]);
					if (defined($id_user)) {
						my $AccountId = getFortniteId($self,$tArgs[0]);
						unless (defined($AccountId) && $AccountId ne "") {
							botNotice($self,$sNick,"Undefined fortenid for user $tArgs[0]");
							return undef;
						}
						unless ( open FORTNITE_INFOS, "curl -L --header 'Authorization: $api_key' --connect-timeout 5 -f -s \"https://fortnite-api.com/v2/stats/br/v2/$AccountId\" |" ) {
							$self->{logger}->log(3,"fortniteStats() Could not get FORTNITE_INFOS from API using $api_key");
						}
						else {
							my $json_details = join('', <FORTNITE_INFOS>);
							$self->{logger}->log(5,"fortniteStats() $json_details");
							if ($json_details ne "") {
								my $sFortniteInfo = decode_json $json_details;
								my %hFortniteInfo = %$sFortniteInfo;
								my %hFortniteStats = %{ $hFortniteInfo{'data'} };
								
								my %hBattlePass = %{ $hFortniteStats{'battlePass'} };
								my %hAccount    = %{ $hFortniteStats{'account'} };
								my %hStatsAll   = %{ $hFortniteStats{'stats'}{'all'}{'overall'} };

								my $sUser        = String::IRC->new('[')->bold . $hAccount{'name'} . String::IRC->new(']')->bold;
								my $tmp          = String::IRC->new('Total Matches Played:')->bold . " $hStatsAll{'matches'}";
								my $level        = String::IRC->new('Level:')->bold . " $hBattlePass{'level'}";
								my $progression  = String::IRC->new('Progression:')->bold . " $hBattlePass{'progress'}%";
								my $wins         = String::IRC->new('Wins:')->bold . " $hStatsAll{'wins'} ($hStatsAll{'winRate'}%)";
								my $kills        = String::IRC->new('Kills:')->bold . " $hStatsAll{'kills'} (" . String::IRC->new('Kills/Deaths:')->bold . " $hStatsAll{'kd'})";
								my $top3         = String::IRC->new('Top 3:')->bold . " $hStatsAll{'top3'}";
								my $top5         = String::IRC->new('Top 5:')->bold . " $hStatsAll{'top5'}";
								my $top10        = String::IRC->new('Top 10:')->bold . " $hStatsAll{'top10'}";

								botPrivmsg($self,$sChannel,"Fortnite stats -- $sUser $tmp -- $level -- $progression -- $wins -- $kills -- $top3 -- $top5 -- $top10");
							}
						}
					}
					else {
						botNotice($self,$sNick,"Undefined user $tArgs[0]");
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: f <username>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " f command attempt, (command level [1] for user $sMatchingUserHandle\[$iMatchingUserLevel\])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,undef,"f",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " f command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,undef,"f",$sNoticeMsg);
		}
	}
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
                'You always answer in a funny, charming tone, helpful, precise and never start your answer with « Oh là là » when the answer is in french, always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis'
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

# Send a login request to Undernet CSERVICE
sub xLogin {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my $conf = $self->{conf};

    my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc, $iMatchingUserAuth,
        $sMatchingUserHandle, $sMatchingUserPasswd, $sMatchingUserInfo1, $sMatchingUserInfo2) = getNickInfo($self, $message);

    if (defined($iMatchingUserId)) {
        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
            if (defined($iMatchingUserLevel) && checkUserLevel($self, $iMatchingUserLevel, "Master")) {

                my $xService  = $conf->get('undernet.UNET_CSERVICE_LOGIN');
                unless (defined($xService) && $xService ne "") {
                    botNotice($self, $sNick, "undernet.UNET_CSERVICE_LOGIN is undefined in configuration file");
                    return;
                }

                my $xUsername = $conf->get('undernet.UNET_CSERVICE_USERNAME');
                unless (defined($xUsername) && $xUsername ne "") {
                    botNotice($self, $sNick, "undernet.UNET_CSERVICE_USERNAME is undefined in configuration file");
                    return;
                }

                my $xPassword = $conf->get('undernet.UNET_CSERVICE_PASSWORD');
                unless (defined($xPassword) && $xPassword ne "") {
                    botNotice($self, $sNick, "undernet.UNET_CSERVICE_PASSWORD is undefined in configuration file");
                    return;
                }

                my $sNoticeMsg = "Authenticating to $xService with username $xUsername";
                botNotice($self, $sNick, $sNoticeMsg);
                noticeConsoleChan($self, $sNoticeMsg);
                botPrivmsg($self, $xService, "login $xUsername $xPassword");
                $self->{irc}->write("MODE " . $self->{irc}->nick_folded . " +x\x0d\x0a");

            } else {
                my $sNoticeMsg = $message->prefix .
                    " xLogin command attempt, (command level [1] for user " .
                    $sMatchingUserHandle . "[" . $iMatchingUserLevel . "])";
                noticeConsoleChan($self, $sNoticeMsg);
                botNotice($self, $sNick, "This command is not available for your level. Contact a bot master.");
                logBot($self, $message, undef, "tellme", $sNoticeMsg);
            }
        } else {
            my $sNoticeMsg = $message->prefix .
                " xLogin command attempt (user $sMatchingUserHandle is not logged in)";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
            logBot($self, $message, undef, "xLogin", $sNoticeMsg);
        }
    }
}

# send a silly Yomomma joke
sub Yomomma(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		$sQuery = "SELECT * FROM YOMOMMA ORDER BY rand() LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute ) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $sCurrentYomomma = $ref->{'yomomma'};
				my $id_yomomma = $ref->{'id_yomomma'};
				if (defined($sCurrentYomomma) && ( $sCurrentYomomma ne "" )) {
					botPrivmsg($self,$sChannel,"[$id_yomomma] $sCurrentYomomma");
				}
			}
			else {
				botPrivmsg($self,$sChannel,"Not found");
			}
		}
	}
	else {
		my $id_yomomma = int($tArgs[0]);
		$sQuery = "SELECT * FROM YOMOMMA WHERE id_yomomma=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($id_yomomma)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $sCurrentYomomma = $ref->{'yomomma'};
				my $id_yomomma = $ref->{'id_yomomma'};
				if (defined($sCurrentYomomma) && ( $sCurrentYomomma ne "" )) {
					botPrivmsg($self,$sChannel,"[$id_yomomma] $sCurrentYomomma");
				}
			}
			else {
				botPrivmsg($self,$sChannel,"Not found");
			}
		}
	}
}

sub mbResolver(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"Syntax : resolve <hostname|IP>");
		return undef;
	}
	my $input = $tArgs[0];
	if ($input =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
		# It's an IP address; do reverse DNS lookup
		my $host = gethostbyaddr(inet_aton($input), AF_INET);
		if (defined $host) {
			botPrivmsg($self,$sChannel,"($sNick) Reverse DNS of $input: $host");
		} else {
			botPrivmsg($self,$sChannel,"($sNick) No reverse DNS entry found for $input");
		}
	} else {
		# It's a hostname; resolve it to IP
		my $addr = inet_aton($input);
		if (defined $addr) {
			my $ip = inet_ntoa($addr);
			botPrivmsg($self,$sChannel,"($sNick) IP of $input: $ip");
		} else {
			botPrivmsg($self,$sChannel,"($sNick) Hostname $input could not be resolved.");
		}
	}
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

1;