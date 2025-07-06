package Mediabot;
 
use strict;
use warnings;
use diagnostics;
use Mediabot::Auth;
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

# Get channel name from channel id
#sub getChannelName(@) {
#	my ($self,$id_channel) = @_;
#	my $name = undef;
#	my $sQuery = "SELECT name FROM CHANNEL WHERE id_channel=?";
#	my $sth = $self->{dbh}->prepare($sQuery);
#	unless ($sth->execute($id_channel) ) {
#		$self->{logger}->log(1,"getChannelName() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
#	}
#	else {
#		if (my $ref = $sth->fetchrow_hashref()) {
#			$name = $ref->{'name'};
#		}
#	}
#	$sth->finish;
#	return $name;
#}

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

# Log a bot command, optionally linked to a channel and user
sub logBot {
    my ($self, $message, $sChannel, $action, @tArgs) = @_;

    # Retrieve user info from the message
    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    my $sHostmask = $message->prefix // 'unknown';
    my $id_user   = $iMatchingUserId // undef;
    my $sUser     = defined $iMatchingUserId ? $sMatchingUserHandle : "Unknown user";

    # Resolve channel ID if a valid channel name is provided
    my $id_channel;
    if (defined $sChannel && exists $self->{channels}{$sChannel}) {
        $id_channel = $self->{channels}{$sChannel}->get_id;
    }

    # Prepare the arguments as a single string
    my $args_string = join(" ", @tArgs);
    $args_string = "" unless defined $args_string;

    # Insert the log entry into the database
    my $sQuery = "INSERT INTO ACTIONS_LOG (ts, id_user, id_channel, hostmask, action, args) VALUES (?, ?, ?, ?, ?, ?)";
    my $sth = $self->{dbh}->prepare($sQuery);
    my $timestamp = time2str("%Y-%m-%d %H-%M-%S", time);

    unless ($sth->execute($timestamp, $id_user, $id_channel, $sHostmask, $action, $args_string)) {
        $self->{logger}->log(0, "logBot() SQL Error: " . $DBI::errstr . " Query: $sQuery");
        return;
    }

    # Build a human-readable notice for the console
    my $sNoticeMsg = "($sUser : $sHostmask) command $action";
    $sNoticeMsg .= " $args_string" if $args_string ne "";
    $sNoticeMsg .= " on $sChannel" if defined $sChannel;

    # Send a notice and log the event
    $self->noticeConsoleChan($sNoticeMsg);
    $self->{logger}->log(3, "logBot() $sNoticeMsg");

    $sth->finish;
}

# Log bot action with event type
sub logBotAction(@) {
	my ($self,$message,$eventtype,$sNick,$sChannel,$sText) = @_;
	#my $dbh = $self->{dbh};
	my $sUserhost = "";
	if (defined($message)) {
		$sUserhost = $message->prefix;
	}
	my $id_channel;
	if (defined($sChannel)) {
		$self->{logger}->log(5,"logBotAction() eventtype = $eventtype chan = $sChannel nick = $sNick text = $sText");
	}
	else {
		$self->{logger}->log(5,"logBotAction() eventtype = $eventtype nick = $sNick text = $sText");
	}
	$self->{logger}->log(5,"logBotAction() " . Dumper($message));
	
	my $sQuery = "SELECT * FROM CHANNEL WHERE name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel) ) {
		$self->{logger}->log(1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if ((my $ref = $sth->fetchrow_hashref()) || ($eventtype eq "quit")) {
			unless ($eventtype eq "quit") { $id_channel = $ref->{'id_channel'}; }
			$self->{logger}->log(5,"logBotAction() ts = " . time2str("%Y-%m-%d %H-%M-%S",time));
			my $sQuery = "INSERT INTO CHANNEL_LOG (id_channel,ts,event_type,nick,userhost,publictext) VALUES (?,?,?,?,?,?)";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($id_channel,time2str("%Y-%m-%d %H-%M-%S",time),$eventtype,$sNick,$sUserhost,$sText) ) {
				$self->{logger}->log(1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$self->{logger}->log(5,"logBotAction() inserted " . $eventtype . " event into CHANNEL_LOG");
			}
		}
	}
}

# Send a private message to a target
sub botPrivmsg(@) {
	my ($self,$sTo,$sMsg) = @_;
	if (defined($sTo)) {
		my $eventtype = "public";
		if (substr($sTo, 0, 1) eq '#') {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botPrivmsg() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(3,"botPrivmsg() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					$self->{logger}->log(4,"botPrivmsg() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						$self->{logger}->log(3,"botPrivmsg() channel $sTo has chanset +AntiFlood");
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
			if (utf8::is_utf8($sMsg)) {
				$sMsg = Encode::encode("UTF-8", $sMsg);
				# Clean IRC message: no newlines allowed
				$sMsg =~ s/[\r\n]+/ /g;
				$self->{irc}->do_PRIVMSG( target => $sTo, text => $sMsg );
			}
			else {
				$self->{irc}->do_PRIVMSG( target => $sTo, text => $sMsg );
			}
		}
		else {
			$self->{logger}->log(0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		$self->{logger}->log(0,"botPrivmsg() ERROR no target specified to send $sMsg");
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
			if (utf8::is_utf8($sMsg)) {
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
sub userOnJoin(@) {
	my ($self,$message,$sChannel,$sNick) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		my $sChannelUserQuery = "SELECT * FROM USER_CHANNEL,CHANNEL WHERE USER_CHANNEL.id_channel=CHANNEL.id_channel AND name=? AND id_user=?";
		$self->{logger}->log(4,$sChannelUserQuery);
		my $sth = $self->{dbh}->prepare($sChannelUserQuery);
		unless ($sth->execute($sChannel,$iMatchingUserId)) {
			$self->{logger}->log(1,"on_join() SQL Error : " . $DBI::errstr . " Query : " . $sChannelUserQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $sAutoMode = $ref->{'automode'};
				if (defined($sAutoMode) && ($sAutoMode ne "")) {
					if ($sAutoMode eq 'OP') {
						$self->{irc}->send_message("MODE", undef, ($sChannel,"+o",$sNick));
					}
					elsif ($sAutoMode eq 'VOICE') {
						$self->{irc}->send_message("MODE", undef, ($sChannel,"+v",$sNick));
					}
				}
				my $sGreetChan = $ref->{'greet'};
				if (defined($sGreetChan) && ($sGreetChan ne "")) {
					botPrivmsg($self,$sChannel,"($sMatchingUserHandle) $sGreetChan");
				}
			}
		}
		$sth->finish;
	}
	my $sChannelUserQuery = "SELECT * FROM CHANNEL WHERE name=?";
	$self->{logger}->log(4,$sChannelUserQuery);
	my $sth = $self->{dbh}->prepare($sChannelUserQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"on_join() SQL Error : " . $DBI::errstr . " Query : " . $sChannelUserQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sNoticeOnJoin = $ref->{'notice'};
			if (defined($sNoticeOnJoin) && ($sNoticeOnJoin ne "")) {
				botNotice($self,$sNick,$sNoticeOnJoin);
			}
		}
	}
}

# Get nick information from a message
sub getNickInfo(@) {
    my ($self, $message) = @_;

    my $conf = $self->{conf};

    my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc, $iMatchingUserAuth);
    my ($sMatchingUserHandle, $sMatchingUserPasswd, $sMatchingUserInfo1, $sMatchingUserInfo2);

    my $sCheckQuery = "SELECT * FROM USER";
    my $sth = $self->{dbh}->prepare($sCheckQuery);
    unless ($sth->execute) {
        $self->{logger}->log( 1, "getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
    } else {
        while (my $ref = $sth->fetchrow_hashref()) {
            my @tHostmasks = split(/,/, $ref->{'hostmasks'});
            foreach my $sHostmask (@tHostmasks) {
                $self->{logger}->log( 4, "getNickInfo() Checking hostmask : $sHostmask");
                my $sHostmaskSource = $sHostmask;
                $sHostmask =~ s/\./\\./g;
                $sHostmask =~ s/\*/.*/g;
                $sHostmask =~ s/\[/\\[/g;
                $sHostmask =~ s/\]/\\]/g;
                $sHostmask =~ s/\{/\\{/g;
                $sHostmask =~ s/\}/\\}/g;
                if ($message->prefix =~ /^$sHostmask/) {
                    $self->{logger}->log( 3, "getNickInfo() $sHostmask matches " . $message->prefix);
                    $sMatchingUserHandle = $ref->{'nickname'};
                    $sMatchingUserPasswd = $ref->{'password'} if defined($ref->{'password'});
                    $iMatchingUserId = $ref->{'id_user'};
                    my $iMatchingUserLevelId = $ref->{'id_user_level'};

                    my $sGetLevelQuery = "SELECT * FROM USER_LEVEL WHERE id_user_level=?";
                    my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);
                    unless ($sth2->execute($iMatchingUserLevelId)) {
                        $self->{logger}->log( 1, "getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sGetLevelQuery);
                    } else {
                        while (my $ref2 = $sth2->fetchrow_hashref()) {
                            $iMatchingUserLevel = $ref2->{'level'};
                            $iMatchingUserLevelDesc = $ref2->{'description'};
                        }
                    }

                    $iMatchingUserAuth = $ref->{'auth'};

                    if (
                        defined($conf->get('connection.CONN_NETWORK_TYPE')) &&
                        $conf->get('connection.CONN_NETWORK_TYPE') eq "1" &&
                        defined($conf->get('undernet.UNET_CSERVICE_HOSTMASK')) &&
                        $conf->get('undernet.UNET_CSERVICE_HOSTMASK') ne ""
                    ) {
                        unless ($iMatchingUserAuth) {
                            my $sUnetHostmask = $conf->get('undernet.UNET_CSERVICE_HOSTMASK');
                            if ($sHostmaskSource =~ /$sUnetHostmask$/) {
                                my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
                                my $sth2 = $self->{dbh}->prepare($sQuery);
                                unless ($sth2->execute($iMatchingUserId)) {
                                    $self->{logger}->log( 1, "getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                                } else {
                                    $iMatchingUserAuth = 1;
                                    $self->{logger}->log( 0, "getNickInfo() Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource");
                                    noticeConsoleChan($self, "Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource");
                                }
                                $sth2->finish;
                            }
                        }
                    }

                    if (getUserAutologin($self, $sMatchingUserHandle)) {
                        unless ($iMatchingUserAuth) {
                            my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
                            my $sth2 = $self->{dbh}->prepare($sQuery);
                            unless ($sth2->execute($iMatchingUserId)) {
                                $self->{logger}->log( 1, "getNickInfo() SQL Error : " . $DBI::errstr . " Query : $sQuery");
                            } else {
                                $iMatchingUserAuth = 1;
                                $self->{logger}->log( 0, "getNickInfo() Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource (autologin is ON)");
                                noticeConsoleChan($self, "Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource (autologin is ON)");
                            }
                            $sth2->finish;
                        }
                    }

                    $sMatchingUserInfo1 = $ref->{'info1'} if defined($ref->{'info1'});
                    $sMatchingUserInfo2 = $ref->{'info2'} if defined($ref->{'info2'});
                }
            }
        }
    }
    $sth->finish;

    unless (defined($iMatchingUserId)) {
        $self->{logger}->log( 4, "getNickInfo() iMatchingUserId is undefined with this host : " . $message->prefix);
        return (undef, undef, undef, undef, undef, undef, undef);
    }

    $self->{logger}->log( 3, "getNickInfo() iMatchingUserId : $iMatchingUserId")       if defined($iMatchingUserId);
    $self->{logger}->log( 4, "getNickInfo() iMatchingUserLevel : $iMatchingUserLevel") if defined($iMatchingUserLevel);
    $self->{logger}->log( 4, "getNickInfo() iMatchingUserLevelDesc : $iMatchingUserLevelDesc") if defined($iMatchingUserLevelDesc);
    $self->{logger}->log( 4, "getNickInfo() iMatchingUserAuth : $iMatchingUserAuth")   if defined($iMatchingUserAuth);
    $self->{logger}->log( 4, "getNickInfo() sMatchingUserHandle : $sMatchingUserHandle") if defined($sMatchingUserHandle);
    $self->{logger}->log( 4, "getNickInfo() sMatchingUserPasswd : $sMatchingUserPasswd") if defined($sMatchingUserPasswd);
    $self->{logger}->log( 4, "getNickInfo() sMatchingUserInfo1 : $sMatchingUserInfo1") if defined($sMatchingUserInfo1);
    $self->{logger}->log( 4, "getNickInfo() sMatchingUserInfo2 : $sMatchingUserInfo2") if defined($sMatchingUserInfo2);

    return (
        $iMatchingUserId,
        $iMatchingUserLevel,
        $iMatchingUserLevelDesc,
        $iMatchingUserAuth,
        $sMatchingUserHandle,
        $sMatchingUserPasswd,
        $sMatchingUserInfo1,
        $sMatchingUserInfo2
    );
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
sub mbQuit(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				logBot($self,$message,undef,"die",@tArgs);
				$self->{Quit} = 1;
				$self->{irc}->send_message( "QUIT", undef, join(" ",@tArgs) );
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

sub userLogin(@) {
    my ($self,$message,$sNick,@tArgs) = @_;

    # login <username> <password>
    if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
        my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,
            $sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);

        if (defined($iMatchingUserId)) {
            unless (defined($sMatchingUserPasswd)) {
                botNotice($self,$sNick,"Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass password");
            } else {
                my $auth_ok = $self->{auth}->verify_credentials($iMatchingUserId, $tArgs[0], $tArgs[1]);

                if ($auth_ok) {
                    botNotice($self,$sNick,"Login successful as $sMatchingUserHandle (Level : $iMatchingUserLevelDesc)");
                    my $sNoticeMsg = $message->prefix . " Successful login as $sMatchingUserHandle (Level : $iMatchingUserLevelDesc)";
                    noticeConsoleChan($self,$sNoticeMsg);
                    logBot($self,$message,undef,"login",($tArgs[0],"Success"));
                } else {
                    botNotice($self,$sNick,"Login failed (Bad password).");
                    my $sNoticeMsg = $message->prefix . " Failed login (Bad password)";
                    noticeConsoleChan($self,$sNoticeMsg);
                    logBot($self,$message,undef,"login",($tArgs[0],"Failed (Bad password)"));
                }
            }
        } else {
            my $sNoticeMsg = $message->prefix . " Failed login (hostmask may not be present in database)";
            noticeConsoleChan($self,$sNoticeMsg);
            logBot($self,$message,undef,"login",($tArgs[0],"Failed (Bad hostmask)"));
        }
    } else {
        botNotice($self,$sNick,"Syntax error : /msg " . $self->{irc}->nick_folded . " login <username> <password>");
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

sub sayChannel(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && ( $tArgs[0] =~ /^#/)) {
					my (undef,@tArgsTemp) = @tArgs;
					my $sChannelText = join(" ",@tArgsTemp);
					$self->{logger}->log(0,"$sNick issued a say command : " . $tArgs[0] . " $sChannelText");
					botPrivmsg($self,$tArgs[0],$sChannelText);
					logBot($self,$message,undef,"say",@tArgs);
				}
				else {
					botNotice($self,$sNick,"Syntax: say <#channel> <text>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " say command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " say command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub dumpCmd(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sDumpCommand = join(" ",@tArgs);
					$self->{logger}->log(0,"$sNick issued a dump command : $sDumpCommand");
					$self->{irc}->write("$sDumpCommand\x0d\x0a");
					logBot($self,$message,undef,"dump",@tArgs);
    		}
    		else {
    			botNotice($self,$sNick,"Syntax error : dump <irc raw command>");
    		}
    	}
    	else {
    		botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub msgCmd(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sTarget = $tArgs[0];
					shift @tArgs;
					my $sMsg = join(" ",@tArgs);
					$self->{logger}->log(0,"$sNick issued a msg command : $sTarget $sMsg");
					botPrivmsg($self,$sTarget,$sMsg);
					logBot($self,$message,undef,"msg",($sTarget,@tArgs));
    		}
    		else {
    			botNotice($self,$sNick,"Syntax error : msg <target> <text>");
    		}
    	}
    	else {
    		botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub actChannel(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && ( $tArgs[0] =~ /^#/)) {
					my (undef,@tArgsTemp) = @tArgs;
					my $sChannelText = join(" ",@tArgsTemp);
					$self->{logger}->log(0,"$sNick issued a act command : " . $tArgs[0] . "ACTION $sChannelText");
					botAction($self,$tArgs[0],$sChannelText);
					logBot($self,$message,undef,"act",@tArgs);
				}
				else {
					botNotice($self,$sNick,"Syntax: act <#channel> <text>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " act command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " act command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

# Check resource usage of the bot
sub mbStatus(@) {
	my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
	my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc, $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd, $sMatchingUserInfo1, $sMatchingUserInfo2) = getNickInfo($self, $message);
	
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self, $iMatchingUserLevel, "Master")) {

				# Bot Uptime
				my $iUptime = time - $self->{iConnectionTimestamp};
				my $days = int($iUptime / 86400);
				my $hours = sprintf("%02d", int(($iUptime % 86400) / 3600));
				my $minutes = sprintf("%02d", int(($iUptime % 3600) / 60));
				my $seconds = sprintf("%02d", $iUptime % 60);

				$self->{logger}->log( 3, "days = $days hours = $hours minutes = $minutes seconds = $seconds");

				my $sUptimeStr = "";
				$sUptimeStr .= "$days days, " if $days > 0;
				$sUptimeStr .= "$hours" . "h " if $hours > 0;
				$sUptimeStr .= "$minutes" . "mn " if $minutes > 0;
				$sUptimeStr .= "$seconds" . "s";

				$sUptimeStr = "Unknown" unless defined($sUptimeStr);

				# Server Uptime
				my $sUptime = "Unknown";
				if (open my $LOAD, "-|", "uptime") {
					chomp($sUptime = <$LOAD>) if defined($sUptime = <$LOAD>);
					close $LOAD;
				} else {
					$self->{logger}->log( 0, "Could not exec uptime command");
				}

				# Server type
				my $sUname = "Unknown";
				if (open my $UNAME, "-|", "uname -a") {
					chomp($sUname = <$UNAME>) if defined($sUname = <$UNAME>);
					close $UNAME;
				} else {
					$self->{logger}->log( 0, "Could not exec uname command");
				}

				# Memory usage
				my $mu = Memory::Usage->new();
				$mu->record('Memory stats');

				my @tMemStateResultsArrayRef = $mu->state();
				my @tMemStateResults = $tMemStateResultsArrayRef[0][0];
				my ($iTimestamp, $sMessage, $fVmSize, $fResSetSize, $fSharedMemSize, $sCodeSize, $fDataStackSize);

				$fVmSize = sprintf("%.2f", $tMemStateResults[0][2] / 1024) if defined $tMemStateResults[0][2];
				$fResSetSize = sprintf("%.2f", $tMemStateResults[0][3] / 1024) if defined $tMemStateResults[0][3];
				$fSharedMemSize = sprintf("%.2f", $tMemStateResults[0][4] / 1024) if defined $tMemStateResults[0][4];
				$fDataStackSize = sprintf("%.2f", $tMemStateResults[0][6] / 1024) if defined $tMemStateResults[0][6];

				botNotice($self, $sNick, $self->{conf}->get('main.MAIN_PROG_NAME') . " v" . $self->{main_prog_version} . " Uptime : $sUptimeStr");
				botNotice($self, $sNick, "Memory usage (VM $fVmSize MB) (Resident Set $fResSetSize MB) (Shared Memory $fSharedMemSize MB) (Data and Stack $fDataStackSize MB)");
				botNotice($self, $sNick, "Server : $sUname");
				botNotice($self, $sNick, "Server's uptime : $sUptime");
				logBot($self, $message, undef, "status", undef);
			} else {
				botNotice($self, $sNick, "Your level does not allow you to use this command.");
				return undef;
			}
		} else {
			botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
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

sub mbChangeNick(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sNewNick = $tArgs[0];
					shift @tArgs;
					$self->{irc}->change_nick( $sNewNick );
					logBot($self,$message,undef,"nick",($sNewNick));
				}
				else {
					botNotice($self,$sNick,"Syntax: nick <nick>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " nick command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " nick command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub mbAddTimer(@) {
	my ($self,$message,$sChannel,$sNick,@tArgs) = @_;
	my %hTimers;
	if ($self->{hTimers}) {
		%hTimers = %{$self->{hTimers}};
	}
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && ($tArgs[1] =~ /[0-9]+/) && defined($tArgs[2]) && ($tArgs[2] ne "")) {
					my $sTimerName = $tArgs[0];
					shift @tArgs;
					if (exists $hTimers{$sTimerName}) {
						botNotice($self,$sNick,"Timer $sTimerName already exists");
						return undef;
					}
					my $iFrequency = $tArgs[0];
					my $timer;
					shift @tArgs;
					my $sRaw = join(" ",@tArgs);
					$timer = IO::Async::Timer::Periodic->new(
				    interval => $iFrequency,
				    on_tick => sub {
				    	$self->{logger}->log(3,"Timer every $iFrequency seconds : $sRaw");
    					$self->{irc}->write("$sRaw\x0d\x0a");
 						},
					);
					$hTimers{$sTimerName} = $timer;
					$self->{loop}->add( $timer );
					$timer->start;
					my $sQuery = "INSERT INTO TIMERS (name,duration,command) VALUES (?,?,?)";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTimerName,$iFrequency,$sRaw)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						botNotice($self,$sNick,"Timer $sTimerName added.");
						logBot($self,$message,undef,"addtimer",("Timer $sTimerName added."));
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: addtimer <name> <frequency> <raw>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " addtimer command attempt (command level [Owner] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addtimer command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
	%{$self->{hTimers}} = %hTimers;
}

sub mbRemTimer(@) {
	my ($self,$message,$sChannel,$sNick,@tArgs) = @_;
	my %hTimers;
	if ($self->{hTimers}) {
		%hTimers = %{$self->{hTimers}};
	}
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sTimerName = $tArgs[0];
					shift @tArgs;
					unless (exists $hTimers{$sTimerName}) {
						botNotice($self,$sNick,"Timer $sTimerName does not exist");
						return undef;
					}
					$self->{loop}->remove($hTimers{$sTimerName});
					delete $hTimers{$sTimerName};
					my $sQuery = "DELETE FROM TIMERS WHERE name=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTimerName)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						botNotice($self,$sNick,"Timer $sTimerName removed.");
						logBot($self,$message,undef,"remtimer",("Timer $sTimerName removed."));
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: remtimer <name>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " remtimer command attempt (command level [Owner] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " remtimer command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
	%{$self->{hTimers}} = %hTimers;
}

sub mbTimers(@) {
	my ($self,$message,$sChannel,$sNick,@tArgs) = @_;
	my %hTimers;
	if ($self->{hTimers}) {
		%hTimers = %{$self->{hTimers}};
	}
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				my $sQuery = "SELECT * FROM TIMERS";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my @tTimers;
					my $i = 0;
					while (my $ref = $sth->fetchrow_hashref()) {
						my $id_timers = $ref->{'id_timers'};
						my $name = $ref->{'name'};
						my $duration = $ref->{'duration'};
						my $command = $ref->{'command'};
						my $sSecondText = ( $duration > 1 ? "seconds" : "second" );
						push @tTimers, "$name - id : $id_timers - every $duration $sSecondText - command $command";
						$i++;
					}
					if ( $i ) {
						botNotice($self,$sNick,"Active timers :");
						foreach (@tTimers) {
						  botNotice($self,$sNick,"$_");
						}
					}
					else {
						botNotice($self,$sNick,"No active timers");
					}
					logBot($self,$message,undef,"timers",undef);
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " timers command attempt (command level [Owner] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " timers command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub userPass(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
		if (defined($iMatchingUserId) && (defined($sMatchingUserHandle))) {
			my $sQuery = "UPDATE USER SET password=PASSWORD(?) WHERE id_user=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($tArgs[0],$iMatchingUserId)) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				$sth->finish;
				return 0;
			}
			else {
				$self->{logger}->log(3,"userPass() Set password for $sNick id_user : $iMatchingUserId (" . $message->prefix . ")");
				my $sNoticeMsg = "Set password for $sNick id_user : $iMatchingUserId (" . $message->prefix . ")";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Password set.");
				botNotice($self,$sNick,"You may now login with /msg " . $self->{irc}->nick_folded . " login $sMatchingUserHandle password");
				logBot($self,$message,undef,"pass","Success");
				$sth->finish;
				return 1;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " Failed pass command, unknown user $sNick (" . $message->prefix . ")";
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"pass","Failed unknown user $sNick");
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

sub userCstat(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sGetAuthUsers = "SELECT nickname,description,level FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND auth=1 ORDER by level";
				my $sth = $self->{dbh}->prepare($sGetAuthUsers);
				unless ($sth->execute) {
					$self->{logger}->log(1,"userCstat() SQL Error : " . $DBI::errstr . " Query : " . $sGetAuthUsers);
				}
				else {
					my $sAuthUserStr;
					while (my $ref = $sth->fetchrow_hashref()) {
						$sAuthUserStr .= $ref->{'nickname'} . " (" . $ref->{'description'} . ") ";
					}
					botNotice($self,$sNick,"Utilisateurs authentifiÃ©s : " . $sAuthUserStr);
					logBot($self,$message,undef,"cstat",@tArgs);
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " cstat command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " cstat command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub addUser(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my $bNotify = 0;
	if (defined($tArgs[0]) && ($tArgs[0] eq "-n")) {
		$bNotify = 1;
		shift @tArgs;
	}
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					$self->{logger}->log(3,"addUser() " . $tArgs[0] . " " . $tArgs[1]);
					my $id_user = getIdUser($self,$tArgs[0]);
					if (defined($id_user)) {
						botNotice($self,$sNick,"User " . $tArgs[0] . " already exists (id_user : $id_user)");
						logBot($self,$message,undef,"adduser","User " . $tArgs[0] . " already exists (id_user : $id_user)");
						return undef;
					}
					my $sLevel = "User";
					if (defined($tArgs[2]) && ($tArgs[2] ne "")) {
						if (defined(getIdUserLevel($self,$tArgs[2]))) {
							$sLevel = $tArgs[2];
						}
						else {
							botNotice($self,$sNick,$tArgs[2] . " is not a valid user level");
							return undef;
						}
					}
					if ((getUserLevelDesc($self,$iMatchingUserLevel) eq "Master") && ($sLevel eq "Owner")) {
						botNotice($self,$sNick,"Masters cannot add a user with Owner level");
						logBot($self,$message,undef,"adduser","Masters cannot add a user with Owner level");
						return undef;
					}
					$id_user = userAdd($self,$tArgs[1],$tArgs[0],undef,$sLevel);
					if (defined($id_user)) {
						$self->{logger}->log(0,"addUser() id_user : $id_user " . $tArgs[0] . " Hostmask : " . $tArgs[1] . " (Level:" . $sLevel . ")");
						noticeConsoleChan($self,"Added user " . $tArgs[0] . " id_user : $id_user with hostmask " . $tArgs[1] . " (Level:" . $sLevel .")");
						botNotice($self,$sNick,"Added user " . $tArgs[0] . " id_user : $id_user with hostmask " . $tArgs[1] . " (Level:" . $sLevel .")");
						if ( $bNotify ) {
							botNotice($self,$tArgs[0],"You've been added to " . $self->{irc}->nick_folded . " as user " . $tArgs[0] . " (Level : " . $sLevel . ") with hostmask $tArgs[1]");
							botNotice($self,$tArgs[0],"/msg " . $self->{irc}->nick_folded . " pass password");
							botNotice($self,$tArgs[0],"replace 'password' with something strong and that you won't forget :p");
						}
						logBot($self,$message,undef,"adduser","Added user " . $tArgs[0] . " id_user : $id_user with hostmask " . $tArgs[1] . " (Level:" . $sLevel .")");
					}
					else {
						botNotice($self,$sNick,"Could not add user " . $tArgs[0]);
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: adduser [-n] <username> <hostmask> [level]");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix;
				$sNoticeMsg .= " adduser command attempt, (command level [1] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,undef,"adduser",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix;
			$sNoticeMsg .= " adduser command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,undef,"adduser",$sNoticeMsg);
		}
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
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sQuery="SELECT count(*) as nbUsers FROM USER";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sNoticeMsg = "Numbers of users : ";
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nbUsers = $ref->{'nbUsers'};
						$sNoticeMsg .= "$nbUsers - ";
						$sQuery="SELECT description,count(nickname) as nbUsers FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level GROUP BY description ORDER BY level";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $i = 0;
							while (my $ref = $sth->fetchrow_hashref()) {
								my $nbUsers = $ref->{'nbUsers'};
								my $description = $ref->{'description'};
								$sNoticeMsg .= "$description($nbUsers) ";
								$i++;
							}
							unless ( $i ) {
								#This shoud never happen
								botNotice($self,$sNick,"No user in database");
							}
							else {
								botNotice($self,$sNick,$sNoticeMsg);
							}
						}
					}
					else {
						# This should never happen since bot need to be registered
						botNotice($self,$sNick,"WTF ? No user in database ?");
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " users command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " users command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userInfo(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						my $sQuery = "SELECT * FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND nickname LIKE ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							$self->{logger}->log(1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $id_user = $ref->{'id_user'};
								my $sUser = $ref->{'nickname'};
								my $creation_date = $ref->{'creation_date'};
								my $sHostmasks = $ref->{'hostmasks'};
								my $sPassword = $ref->{'password'};
								my $sDescription = $ref->{'description'};
								my $sInfo1 = $ref->{'info1'};
								my $sInfo2 = $ref->{'info2'};								
								my $last_login = $ref->{'last_login'};
								my $auth = $ref->{'auth'};
								my $username = $ref->{'username'};
								botNotice($self,$sNick,"User : $sUser (Id: $id_user - $sDescription) - created $creation_date - last login " . (defined($last_login) ? $last_login : ""));
								my $sPasswordSet = (defined($sPassword) ? "Password set" : "Password is not set" );
								my $sLoggedIn = (($auth) ? "logged in" : "not logged in" );
								my $sAutoLogin = (($username eq "#AUTOLOGIN#") ? "ON" : "OFF");
								botNotice($self,$sNick,"$sPasswordSet ($sLoggedIn) Force AUTOLOGIN : $sAutoLogin");
								botNotice($self,$sNick,"Hostmasks : $sHostmasks");
								botNotice($self,$sNick,"Infos : " . (defined($sInfo1) ? $sInfo1 : "N/A") . " - " . (defined($sInfo2) ? $sInfo2 : "N/A"));								
							}
							else {
								botNotice($self,$sNick,"User " . $tArgs[0] . " does not exist");
							}
							my $sNoticeMsg = $message->prefix . " userinfo on " . $tArgs[0];
							$self->{logger}->log(0,$sNoticeMsg);
							noticeConsoleChan($self,$sNoticeMsg);
							logBot($self,$message,undef,"userinfo",$sNoticeMsg);
							$sth->finish;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: userinfo <username>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix;
				$sNoticeMsg .= " userinfo command attempt, (command level [1] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,undef,"userinfo",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix;
			$sNoticeMsg .= " userinfo command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,undef,"userinfo",$sNoticeMsg);
		}
	}
}

sub addUserHost(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					$self->{logger}->log(3,"addUserHost() " . $tArgs[0] . " " . $tArgs[1]);
					my $id_user = getIdUser($self,$tArgs[0]);
					unless (defined($id_user)) {
						botNotice($self,$sNick,"User " . $tArgs[0] . " does not exists");
						logBot($self,$message,undef,"addhost","User " . $tArgs[0] . " does not exists");
						return undef;
					}
					else {
						my $sSearch = $tArgs[1];
						$sSearch =~ s/;//g;
						my $sQuery = "SELECT * FROM USER WHERE nickname=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							$self->{logger}->log(1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $sUser = $ref->{'nickname'};
								my $sHostmasks = $ref->{'hostmasks'};
								$self->{logger}->log(3,"(addUserHost) $sHostmasks");
								my @tHostmasks = split (",",$sHostmasks);
								foreach my $hm (@tHostmasks) {
									$self->{logger}->log(3,"(addUserHost) $hm");
									if ( $hm eq $tArgs[1]) {
										my $sNoticeMsg = $message->prefix . " Hostmask " . $tArgs[1] . " already exist for user for user $sUser";
										$self->{logger}->log(0,$sNoticeMsg);
										noticeConsoleChan($self,$sNoticeMsg);
										logBot($self,$message,undef,"addhost",$sNoticeMsg);
										return undef;
									}
								}
							}
							$sQuery = "SELECT hostmasks FROM USER WHERE id_user=?";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($id_user)) {
								$self->{logger}->log(1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $sHostmasks = "";
								if (my $ref = $sth->fetchrow_hashref()) {
									$sHostmasks = $ref->{'hostmasks'};
								}
								$sQuery = "UPDATE USER SET hostmasks=? WHERE id_user=?";
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($sHostmasks . "," . $tArgs[1],$id_user)) {
									$self->{logger}->log(1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									my $sNoticeMsg = $message->prefix . " Hostmask " . $tArgs[1] . " added for user " . $tArgs[0];
									$self->{logger}->log(0,$sNoticeMsg);
									noticeConsoleChan($self,$sNoticeMsg);
									logBot($self,$message,undef,"addhost",$sNoticeMsg);
								}
							}
						}
						$sth->finish;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: addhost <username> <hostmask>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix;
				$sNoticeMsg .= " addhost command attempt, (command level [1] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,undef,"addhost",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix;
			$sNoticeMsg .= " addhost command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,undef,"addhost",$sNoticeMsg);
		}
	}
}


sub addChannel(@) {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Authentication check
    my ($id_user, $user_level, $desc, $auth, $handle) = getNickInfo($self, $message);
    unless ($id_user && $auth) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }
    unless (checkUserLevel($self, $user_level, "Administrator")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Arguments
    my ($sChannel, $sUser) = @tArgs;
    unless ($sChannel && $sUser && $sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: addchan <#channel> <user>");
        return;
    }

    $self->{logger}->log( 0, "$sNick issued addchan command: $sChannel $sUser");

    # Check if target user exists
    my $id_target_user = getIdUser($self, $sUser);
    unless ($id_target_user) {
        botNotice($self, $sNick, "User $sUser does not exist");
        return;
    }

    # Check channel existence
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
        $self->{logger}->log( 1, "addChannel() failed SQL insert for $sChannel");
        return;
    }

	# Create channel object and store it
	$self->{channels}{$sChannel} = Mediabot::Channel->new({
		id         => $id_channel,
		name       => $sChannel,
		dbh        => $self->{dbh},
		irc        => $self->{irc},
	});

    # Register channel
    joinChannel($self, $sChannel, undef);
    my $registered = registerChannel($self, $message, $sNick, $id_channel, $id_target_user);

    $self->{logger}->log( 0, $registered ? "registerChannel successful $sChannel $sUser" : "registerChannel failed $sChannel $sUser");
    logBot($self, $message, undef, "addchan", ($sChannel, @tArgs));
    noticeConsoleChan($self, $message->prefix . " addchan command $handle added $sChannel (id_channel: $id_channel)");

    return $id_channel;
}

sub channelSet(@) {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;
    my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc, 
        $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd, 
        $sMatchingUserInfo1, $sMatchingUserInfo2) = getNickInfo($self, $message);

    if (defined($iMatchingUserId)) {
        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {

            # Si le premier argument commence par '#', c'est le channel
            if (defined($tArgs[0]) && $tArgs[0] ne "" && $tArgs[0] =~ /^#/) {
                $sChannel = $tArgs[0];
                shift @tArgs;
            }
            unless (defined($sChannel)) {
                channelSetSyntax($self, $message, $sNick, @tArgs);
                return undef;
            }

            # Vérifier le niveau de l’utilisateur (Admin global ou niveau >=450 sur ce channel)
            if (defined($iMatchingUserLevel) && 
                (checkUserLevel($self, $iMatchingUserLevel, "Administrator") 
                 || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 450))) {

                # Check if arguments are provided
                if ( (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] ne "") || (defined($tArgs[0]) && $tArgs[0] ne "" && ((substr($tArgs[0], 0, 1) eq "+") || (substr($tArgs[0], 0, 1) eq "-")) ) ) {
                    # get channel object if exists
                    if (exists $self->{channels}{$sChannel}) {
                        my $channel = $self->{channels}{$sChannel};
                        my $id_channel = $channel->get_id;
                        switch ($tArgs[0]) {
                            case "key" {
                                $channel->set_key($tArgs[1]);
                                botNotice($self, $sNick, "Set $sChannel key " . $tArgs[1]);
                                logBot($self, $message, $sChannel, "chanset", ($sChannel, @tArgs));
                                return $id_channel;
                            }
                            case "chanmode" {
                                $channel->set_chanmode($tArgs[1]);
                                botNotice($self, $sNick, "Set $sChannel chanmode " . $tArgs[1]);
                                logBot($self, $message, $sChannel, "chanset", ($sChannel, @tArgs));
                                return $id_channel;
                            }
                            case "auto_join" {
                                my $bAutoJoin;
                                if    ($tArgs[1] =~ /on/i)  { $bAutoJoin = 1; }
                                elsif ($tArgs[1] =~ /off/i) { $bAutoJoin = 0; }
                                else {
                                    channelSetSyntax($self, $message, $sNick, @tArgs);
                                    return undef;
                                }
                                $channel->set_auto_join($bAutoJoin);
                                botNotice($self, $sNick, "Set $sChannel auto_join " . $tArgs[1]);
                                logBot($self, $message, $sChannel, "chanset", ($sChannel, @tArgs));
                                return $id_channel;
                            }
                            case "description" {
                                shift @tArgs;
                                unless ($tArgs[0] =~ /console/i) {
                                    my $new_desc = join(" ", @tArgs);
                                    $channel->set_description($new_desc);
                                    botNotice($self, $sNick, "Set $sChannel description " . $new_desc);
                                    logBot($self, $message, $sChannel, "chanset", ($sChannel, "description", @tArgs));
                                    return $id_channel;
                                }
                                else {
                                    botNotice($self, $sNick, "You cannot set $sChannel description to " . $tArgs[0]);
                                    logBot($self, $message, $sChannel, "chanset", ("You cannot set $sChannel description to " . $tArgs[0]));
                                }
                            }
                            else {
                                # Chanset management with +/-
                                if ((substr($tArgs[0], 0, 1) eq "+") || (substr($tArgs[0], 0, 1) eq "-")) {
                                    my $sChansetValue  = substr($tArgs[0], 1);
                                    my $sChansetAction = substr($tArgs[0], 0, 1);
                                    $self->{logger}->log( 0, "chanset $sChannel $sChansetAction$sChansetValue");
                                    my $id_chanset_list = getIdChansetList($self, $sChansetValue);
                                    unless (defined($id_chanset_list) && $id_chanset_list ne "") {
                                        botNotice($self, $sNick, "Undefined chanset $sChansetValue");
                                        logBot($self, $message, $sChannel, "chanset", 
                                               ($sChannel, "Undefined chanset $sChansetValue"));
                                        return undef;
                                    }
                                    my $id_channel_set = getIdChannelSet($self, $sChannel, $id_chanset_list);
                                    if ($sChansetAction eq "+") {
                                        if (defined($id_channel_set)) {
                                            botNotice($self, $sNick, "Chanset +$sChansetValue is already set for $sChannel");
                                            logBot($self, $message, $sChannel, "chanset", 
                                                   ("Chanset +$sChansetValue is already set"));
                                            return undef;
                                        }
                                        my $sQuery = "INSERT INTO CHANNEL_SET (id_channel, id_chanset_list) VALUES (?, ?)";
                                        my $sth = $self->{dbh}->prepare($sQuery);
                                        unless ($sth->execute($id_channel, $id_chanset_list)) {
                                            $self->{logger}->log( 1, "SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                                        }
                                        else {
                                            botNotice($self, $sNick, "Chanset +$sChansetValue for $sChannel");
                                            logBot($self, $message, $sChannel, "chanset", ("Chanset +$sChansetValue"));
                                            if ($sChansetValue =~ /^AntiFlood$/i) {
                                                setChannelAntiFlood($self, $message, $sNick, $sChannel, @tArgs);
                                            }
                                            elsif ($sChansetValue =~ /^HailoChatter$/i) {
                                                # TBD: check old ratio
                                                set_hailo_channel_ratio($self, $sChannel, 97);
                                            }
                                        }
                                        $sth->finish;
                                        return $id_channel;
                                    }
                                    else {  # $sChansetAction eq "-"
                                        unless (defined($id_channel_set)) {
                                            botNotice($self, $sNick, "Chanset +$sChansetValue is not set for $sChannel");
                                            logBot($self, $message, $sChannel, "chanset", 
                                                   ("Chanset +$sChansetValue is not set"));
                                            return undef;
                                        }
                                        my $sQuery = "DELETE FROM CHANNEL_SET WHERE id_channel_set=?";
                                        my $sth = $self->{dbh}->prepare($sQuery);
                                        unless ($sth->execute($id_channel_set)) {
                                            $self->{logger}->log( 1, "SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
                                        }
                                        else {
                                            botNotice($self, $sNick, "Chanset -$sChansetValue for $sChannel");
                                            logBot($self, $message, $sChannel, "chanset", ("Chanset -$sChansetValue"));
                                        }
                                        $sth->finish;
                                        return $id_channel;
                                    }
                                }
                                else {
                                    channelSetSyntax($self, $message, $sNick, @tArgs);
                                    return undef;
                                }
                            }

                        }
                    }
                    else {
                        # Channel not found in hash
                        $self->{logger}->log( 3, "channelSet : channel $sChannel not found in hash");
                        return undef;
                    }
                }
                else {
                    channelSetSyntax($self, $message, $sNick, @tArgs);
                    return undef;
                }
            }
            else {
                my $sNoticeMsg = $message->prefix . " chanset command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc . "]";
                noticeConsoleChan($self, $sNoticeMsg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
                return undef;
            }
        }
        else {
            my $sNoticeMsg = $message->prefix . " chanset command attempt (user $sMatchingUserHandle is not logged in)";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login <user> <pass>");
            return undef;
        }
    }
}

sub channelSetSyntax(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	botNotice($self,$sNick,"Syntax: chanset [#channel] key <key>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] chanmode <+chanmode>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] description <description>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] auto_join <on|off>");
	botNotice($self,$sNick,"Syntax: chanset [#channel] <+value|-value>");
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

# Purge a channel from the bot (delete + archive), if the user is an authenticated administrator
sub purgeChannel {
    my ($self, $message, $sNick, @tArgs) = @_;

    # Retrieve user info
    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    unless (defined $iMatchingUserId && $iMatchingUserAuth) {
        botNotice($self, $sNick, "You must be logged in to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        my $notice = $message->prefix . " purge command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        return;
    }

    unless (checkUserLevel($self, $iMatchingUserLevel, "Administrator")) {
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        my $notice = $message->prefix . " purge command attempt (command level [Administrator] for user $sMatchingUserHandle [$iMatchingUserLevel])";
        $self->noticeConsoleChan($notice);
        return;
    }

    my $sChannel = $tArgs[0] // '';
    unless ($sChannel =~ /^#/) {
        botNotice($self, $sNick, "Syntax: purge <#channel>");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $self->{channels}{$sChannel}->get_id;
    $self->{logger}->log(0, "$sNick issued a purge command on $sChannel");

    # Retrieve full channel info from DB (not just what's cached)
    my $sth = $self->{dbh}->prepare("SELECT * FROM CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " Query: SELECT * FROM CHANNEL WHERE id_channel = ?");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;
    unless ($ref) {
        $self->{logger}->log(1, "Channel $sChannel (id: $id_channel) not found in database during purge.");
        return;
    }

    my $sDescription = $ref->{description};
    my $sKey         = $ref->{key};
    my $sChanmode    = $ref->{chanmode};
    my $bAutoJoin    = $ref->{auto_join};

    # Delete from CHANNEL table
    $sth = $self->{dbh}->prepare("DELETE FROM CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " while deleting from CHANNEL");
        return;
    }

    # Delete associated access rights
    $sth = $self->{dbh}->prepare("DELETE FROM USER_CHANNEL WHERE id_channel = ?");
    unless ($sth->execute($id_channel)) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " while deleting from USER_CHANNEL");
        return;
    }

    # Archive into CHANNEL_PURGED
    $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL_PURGED (id_channel, name, description, `key`, chanmode, auto_join) VALUES (?, ?, ?, ?, ?, ?)");
    unless ($sth->execute($id_channel, $sChannel, $sDescription, $sKey, $sChanmode, $bAutoJoin)) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " while inserting into CHANNEL_PURGED");
        return;
    }

    # Clean IRC and memory
    $self->{logger}->log(0, "Channel $sChannel (id: $id_channel) successfully purged");
    $self->partChannel($sChannel, "Channel purged by $sNick");
    delete $self->{channels}{$sChannel};  # Remove from in-memory hash

    # Log and notify
    my $log_msg = "$sNick purged $sChannel (id_channel: $id_channel)";
    $self->logBot($message, undef, "purge", $log_msg);
}

sub partChannel(@) {
	my ($self,$channel,$sPartMsg) = @_;
	if (defined($sPartMsg) && ($sPartMsg ne "")) {
		$self->{logger}->log(0,"Parting $channel $sPartMsg");
		$self->{irc}->send_message("PART", undef, ($channel,$sPartMsg));
	}
	else {
		$self->{logger}->log(0,"Parting $channel");
		$self->{irc}->send_message("PART", undef,$channel);
	}
}

# Channel part command
sub channelPart {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    if (defined($iMatchingUserId)) {
        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {

            if (!defined($sChannel) || (defined($tArgs[0]) && $tArgs[0] ne "")) {
                if (defined($tArgs[0]) && $tArgs[0] ne "" && $tArgs[0] =~ /^#/) {
                    $sChannel = $tArgs[0];
                    shift @tArgs;
                } else {
                    botNotice($self, $sNick, "Syntax: part <#channel>");
                    return undef;
                }
            }

            if (defined($iMatchingUserLevel)
                && (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
                    || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 500))) {

                my $channel_obj = $self->{channels}{$sChannel};
                if (defined $channel_obj) {
                    $self->{logger}->log(0, "$sNick issued a part $sChannel command");
                    partChannel($self, $sChannel, "At the request of $sMatchingUserHandle");
                    logBot($self, $message, $sChannel, "part", "At the request of $sMatchingUserHandle");
                } else {
                    botNotice($self, $sNick, "Channel $sChannel does not exist");
                    return undef;
                }

            } else {
                my $sNoticeMsg = $message->prefix . " part command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
                noticeConsoleChan($self, $sNoticeMsg);
                botNotice($self, $sNick, "Your level does not allow you to use this command.");
                return undef;
            }

        } else {
            my $sNoticeMsg = $message->prefix . " part command attempt (user $sMatchingUserHandle is not logged in)";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
            return undef;
        }
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

# Join a channel with a key if it exists, or without key if not
sub channelJoin {
    my ($self, $message, $sNick, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    if (defined($iMatchingUserId)) {
        if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
            if (defined($tArgs[0]) && $tArgs[0] ne "" && $tArgs[0] =~ /^#/) {
                my $sChannel = $tArgs[0];
                shift @tArgs;

                if (defined($iMatchingUserLevel) &&
                    (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
                        || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 450))) {

                    my $channel_obj = $self->{channels}{$sChannel};
                    unless (defined $channel_obj) {
                        botNotice($self, $sNick, "Channel $sChannel does not exist");
                        return undef;
                    }

                    my $id_channel = $channel_obj->get_id;
                    $self->{logger}->log(0, "$sNick issued a join $sChannel command");

                    my $sKey;
                    my $sQuery = "SELECT `key` FROM CHANNEL WHERE id_channel=?";
                    my $sth = $self->{dbh}->prepare($sQuery);
                    unless ($sth->execute($id_channel)) {
                        $self->{logger}->log(1, "SQL Error : " . $DBI::errstr . " Query : $sQuery");
                    } else {
                        if (my $ref = $sth->fetchrow_hashref()) {
                            $sKey = $ref->{'key'};
                        }
                        $sth->finish;
                    }

                    # Join with or without key
                    if (defined($sKey) && $sKey ne "") {
                        joinChannel($self, $sChannel, $sKey);
                    } else {
                        joinChannel($self, $sChannel, undef);
                    }

                    logBot($self, $message, $sChannel, "join", "");
                } else {
                    my $sNoticeMsg = $message->prefix . " join command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
                    noticeConsoleChan($self, $sNoticeMsg);
                    botNotice($self, $sNick, "Your level does not allow you to use this command.");
                    return undef;
                }
            } else {
                botNotice($self, $sNick, "Syntax: join <#channel>");
                return undef;
            }
        } else {
            my $sNoticeMsg = $message->prefix . " join command attempt (user $sMatchingUserHandle is not logged in)";
            noticeConsoleChan($self, $sNoticeMsg);
            botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
            return undef;
        }
    }
}

# Add a user to a channel with a specific level
sub channelAddUser {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " add user command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from arguments if not directly passed
    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = $tArgs[0];
        shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator") ||
         checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 400))
    ) {
        my $notice = $message->prefix . " add user command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "" && defined($tArgs[1]) && $tArgs[1] =~ /^\d+$/) {
        botNotice($self, $sNick, "Syntax: add <#channel> <handle> <level>");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel   = $channel_obj->get_id;
    my $sUserHandle  = $tArgs[0];
    my $iLevel       = $tArgs[1];
    my $id_user      = getIdUser($self, $sUserHandle);

    unless (defined $id_user) {
        botNotice($self, $sNick, "User $sUserHandle does not exist");
        return;
    }

    my $iCheckUserLevel = getUserChannelLevel($self, $message, $sChannel, $id_user);
    if ($iCheckUserLevel != 0) {
        botNotice($self, $sNick, "User $sUserHandle on $sChannel already added at level $iCheckUserLevel");
        return;
    }

    # Check if the user can assign the level
    if (
        $iLevel < getUserChannelLevel($self, $message, $sChannel, $iMatchingUserId)
        || checkUserLevel($self, $iMatchingUserLevel, "Administrator")
    ) {
        my $sQuery = "INSERT INTO USER_CHANNEL (id_user, id_channel, level) VALUES (?, ?, ?)";
        my $sth = $self->{dbh}->prepare($sQuery);
        unless ($sth->execute($id_user, $id_channel, $iLevel)) {
            $self->{logger}->log(1, "SQL Error : " . $DBI::errstr . " Query : $sQuery");
        } else {
            $self->{logger}->log(0, "$sNick issued a add user $sChannel command");
            logBot($self, $message, $sChannel, "add", @tArgs);
        }
        $sth->finish;
    } else {
        botNotice($self, $sNick, "You can't add a user with a level equal or greater than yours");
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

sub channelDelUser(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: del <#channel> <handle>");
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,400))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						$self->{logger}->log(0,"$sNick issued a del user $sChannel command");
						my $sUserHandle = $tArgs[0];
						my $id_user = getIdUser($self,$tArgs[0]);
						if (defined($id_user)) {
							my $iCheckUserLevel = getUserChannelLevel($self,$message,$sChannel,$id_user);
							if ( $iCheckUserLevel != 0 ) {
								if ( $iCheckUserLevel < getUserChannelLevel($self,$message,$sChannel,$iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
									my $sQuery = "DELETE FROM USER_CHANNEL WHERE id_user=? AND id_channel=?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_user,$id_channel)) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										logBot($self,$message,$sChannel,"del",@tArgs);
									}
									$sth->finish;
								}
								else {
									botNotice($self,$sNick,"You can't del a user with a level equal or greater than yours");
								}
							}
							else {
								botNotice($self,$sNick,"User $sUserHandle does not appear to have access on $sChannel");
							}
						}
						else {
							botNotice($self,$sNick,"User $sUserHandle does not exist");
						}
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: del <#channel> <handle>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " del user command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " del user command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

# User modinfo syntax notification
sub userModinfoSyntax(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	botNotice($self,$sNick,"Syntax: modinfo [#channel] automode <user> <voice|op|none>");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] greet <user> <greet> (use keyword \"none\" for <greet> to remove it)");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] level <user> <level>");
}

# User modinfo command
sub userModinfo {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " modinfo command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel if passed as first arg
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        userModinfoSyntax($self, $message, $sNick, @tArgs);
        return;
    }

    # Check global or channel-specific permissions
    my $has_access =
        checkUserLevel($self, $iMatchingUserLevel, "Administrator")
        || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 400)
        || (
            defined $tArgs[0]
            && $tArgs[0] =~ /^greet$/i
            && checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 1)
        );

    unless ($has_access) {
        my $notice = $message->prefix . " modinfo command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Basic syntax check
    unless (defined $tArgs[0] && $tArgs[0] ne "" && defined $tArgs[1] && defined $tArgs[2] && $tArgs[2] ne "") {
        userModinfoSyntax($self, $message, $sNick, @tArgs);
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    my ($id_user, $level) = getIdUserChannelLevel($self, $tArgs[1], $sChannel);

    unless (defined $id_user) {
        botNotice($self, $sNick, "User $tArgs[1] does not exist on $sChannel");
        return;
    }

    my (undef, $iMatchingUserLevelChannel) = getIdUserChannelLevel($self, $sMatchingUserHandle, $sChannel);

    unless (
        $iMatchingUserLevelChannel > $level
        || checkUserLevel($self, $iMatchingUserLevel, "Administrator")
        || ($tArgs[0] =~ /^greet$/i && $iMatchingUserLevelChannel > 0)
    ) {
        botNotice($self, $sNick, "Cannot modify a user with equal or higher access than your own.");
        return;
    }

    my $sType = lc $tArgs[0];
    my $sth;

    SWITCH: {
        $sType eq "automode" and do {
            my $sAutomode = uc($tArgs[2]);
            unless ($sAutomode =~ /^(OP|VOICE|NONE)$/i) {
                userModinfoSyntax($self, $message, $sNick, @tArgs);
                last SWITCH;
            }

            my $query = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($sAutomode, $id_user, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error : " . $DBI::errstr . " Query : $query");
                $sth->finish;
                return;
            }
            botNotice($self, $sNick, "Set automode $sAutomode on $sChannel for $tArgs[1]");
            logBot($self, $message, $sChannel, "modinfo", @tArgs);
            $sth->finish;
            return $id_channel;
        };

        $sType eq "greet" and do {
            my $sUser = $tArgs[1];

            if ($iMatchingUserLevelChannel < 400 && $sUser ne $sMatchingUserHandle && !checkUserLevel($self, $iMatchingUserLevel, "Administrator")) {
                botNotice($self, $sNick, "Your level does not allow you to perform this command.");
                last SWITCH;
            }

            splice @tArgs, 0, 2;
            my $sGreet = (scalar @tArgs == 1 && $tArgs[0] =~ /none/i) ? undef : join(" ", @tArgs);

            my $query = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($sGreet, $id_user, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error : " . $DBI::errstr . " Query : $query");
                $sth->finish;
                return;
            }

            botNotice($self, $sNick, "Set greet (" . ($sGreet // "none") . ") on $sChannel for $sUser");
            logBot($self, $message, $sChannel, "modinfo", ("greet $sUser", @tArgs));
            $sth->finish;
            return $id_channel;
        };

        $sType eq "level" and do {
            my $sUser = $tArgs[1];
            my $new_level = $tArgs[2];

            unless ($new_level =~ /^\d+$/ && $new_level <= 500) {
                botNotice($self, $sNick, "Cannot set user access higher than 500.");
                last SWITCH;
            }

            my $query = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
            $sth = $self->{dbh}->prepare($query);
            unless ($sth->execute($new_level, $id_user, $id_channel)) {
                $self->{logger}->log(1, "userModinfo() SQL Error : " . $DBI::errstr . " Query : $query");
                $sth->finish;
                return;
            }

            botNotice($self, $sNick, "Set level $new_level on $sChannel for $sUser");
            logBot($self, $message, $sChannel, "modinfo", @tArgs);
            $sth->finish;
            return $id_channel;
        };

        # Unknown case
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

# User op command
sub userOpChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " op command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: op #channel <nick>");
        return;
    }

    # Check global or per-channel privileges
    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 100))
    ) {
        my $notice = $message->prefix . " op command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine who gets +o
    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "+o", $target_nick));
    logBot($self, $message, $sChannel, "op", @tArgs);

    return $id_channel;
}

# User deop command
sub userDeopChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " deop command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: deop #channel <nick>");
        return;
    }

    # Check global or per-channel privileges
    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 100))
    ) {
        my $notice = $message->prefix . " deop command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

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

# User invite command
sub userInviteChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " invite command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: invite #channel <nick>");
        return;
    }

    # Check global or per-channel privileges
    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 100))
    ) {
        my $notice = $message->prefix . " invite command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

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

# User voice command
sub userVoiceChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " voice command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Extract channel from args if necessary
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: voice #channel <nick>");
        return;
    }

    # Check global or per-channel privileges
    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 25))
    ) {
        my $notice = $message->prefix . " voice command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    # Determine who gets +v
    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "+v", $target_nick));
    logBot($self, $message, $sChannel, "voice", @tArgs);

    return $id_channel;
}

# User devoice command
sub userDevoiceChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $notice = $message->prefix . " devoice command attempt (user $sMatchingUserHandle is not logged in)";
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

    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 25))
    ) {
        my $notice = $message->prefix . " devoice command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($notice);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    my $target_nick = defined($tArgs[0]) && $tArgs[0] ne "" ? $tArgs[0] : $sNick;

    $self->{irc}->send_message("MODE", undef, ($sChannel, "-v", $target_nick));
    logBot($self, $message, $sChannel, "devoice", @tArgs);

    return $id_channel;
}

# User kick command
sub userKickChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $sNoticeMsg = $message->prefix . " kick command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    # Channel from args if needed
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: kick #channel <nick> [reason]");
        return;
    }

    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
            || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 50))
    ) {
        my $sNoticeMsg = $message->prefix . " kick command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: kick #channel <nick> [reason]");
        return;
    }

    my $sKickNick   = shift @tArgs;
    my $sKickReason = join(" ", @tArgs) // "";
    my $sFinalMsg   = "($sMatchingUserHandle) $sKickReason";

    $self->{logger}->log(0, "$sNick issued a kick $sChannel command");
    $self->{irc}->send_message("KICK", undef, ($sChannel, $sKickNick, $sFinalMsg));
    logBot($self, $message, $sChannel, "kick", ($sKickNick, @tArgs));

    return $id_channel;
}

# User topic command
sub userTopicChannel {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my (
        $iMatchingUserId,     $iMatchingUserLevel,    $iMatchingUserLevelDesc,
        $iMatchingUserAuth,   $sMatchingUserHandle,   $sMatchingUserPasswd,
        $sMatchingUserInfo1,  $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    return unless defined $iMatchingUserId;

    unless ($iMatchingUserAuth) {
        my $sNoticeMsg = $message->prefix . " topic command attempt (user $sMatchingUserHandle is not logged in)";
        $self->noticeConsoleChan($sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    unless (
        defined $iMatchingUserLevel &&
        (checkUserLevel($self, $iMatchingUserLevel, "Administrator")
         || checkUserChannelLevel($self, $message, $sChannel, $iMatchingUserId, 50))
    ) {
        my $sNoticeMsg = $message->prefix . " topic command attempt for user $sMatchingUserHandle [$iMatchingUserLevelDesc])";
        $self->noticeConsoleChan($sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    unless (defined $tArgs[0] && $tArgs[0] ne "") {
        botNotice($self, $sNick, "Syntax: topic #channel <topic>");
        return;
    }

    my $channel_obj = $self->{channels}{$sChannel};
    unless (defined $channel_obj) {
        botNotice($self, $sNick, "Channel $sChannel does not exist");
        return;
    }

    my $id_channel = $channel_obj->get_id;
    my $new_topic  = join(" ", @tArgs);

    $self->{logger}->log(0, "$sNick issued a topic $sChannel command");
    $self->{irc}->send_message("TOPIC", undef, ($sChannel, $new_topic));
    logBot($self, $message, $sChannel, "topic", @tArgs);

    return $id_channel;
}


sub userShowcommandsChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (!defined($sChannel) || (defined($tArgs[0]) && ($tArgs[0] ne ""))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				else {
					botNotice($self,$sNick,"Syntax: showcommands #channel");
					return undef;
				}
			}
			
			my $sNoticeMsg = "Available commands on $sChannel";
			my $isAdmin = checkUserLevel($self,$iMatchingUserLevel,"Administrator");
			if ( $isAdmin ) { $sNoticeMsg .= " (because you are a global admin)"; }
			noticeConsoleChan($self,$message->prefix . " showcommands on $sChannel");
			logBot($self,$message,$sChannel,"showcommands",@tArgs);
			botNotice($self,$sNick,$sNoticeMsg);
			my ($id_user,$level) = getIdUserChannelLevel($self,$sMatchingUserHandle,$sChannel);
			if ($isAdmin || ( $level >= 500)) { botNotice($self,$sNick,"Level 500: part"); }
			if ($isAdmin || ( $level >= 450)) { botNotice($self,$sNick,"Level 450: join chanset"); }
			if ($isAdmin || ( $level >= 400)) { botNotice($self,$sNick,"Level 400: add del modinfo"); }
			if ($isAdmin || ( $level >= 100)) { botNotice($self,$sNick,"Level 100: op deop invite"); }
			if ($isAdmin || ( $level >= 50)) { botNotice($self,$sNick,"Level  50: kick topic"); }
			if ($isAdmin || ( $level >= 25)) { botNotice($self,$sNick,"Level  25: voice devoice"); }
			botNotice($self,$sNick,"Level   0: access chaninfo login pass newpass ident showcommands");
		}
		else {
			my $sNoticeMsg = $message->prefix . " showcommands attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,$sChannel,"showcommands",@tArgs);
			botNotice($self,$sNick,"You must be logged to see available commands for your level - /msg " . $self->{irc}->nick_folded . " login username password");
			botNotice($self,$sNick,"Level   0: access chaninfo login pass ident showcommands");
			return undef;
		}
	}
	else {
		botNotice($self,$sNick,"Level   0: access chaninfo login pass newpass ident showcommands");
	}
}

# Channel info command
sub userChannelInfo {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    if (defined($tArgs[0]) && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
    }

    unless (defined $sChannel) {
        botNotice($self, $sNick, "Syntax: chaninfo #channel");
        return;
    }

    # Recherche du propriétaire du channel
    my $sQuery = "SELECT * FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND level=500";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute($sChannel)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $sUsername    = $ref->{'nickname'};
        my $sLastLogin   = $ref->{'last_login'} // "Never";
        my $creation_date = $ref->{'creation_date'};
        my $description  = $ref->{'description'};
        my $sKey         = $ref->{'key'} // "Not set";
        my $chanmode     = $ref->{'chanmode'} // "Not set";
        my $sAutoJoin    = $ref->{'auto_join'} ? "True" : "False";

        botNotice($self, $sNick, "$sChannel is registered by $sUsername - last login: $sLastLogin");
        botNotice($self, $sNick, "Creation date : $creation_date - Description : $description");

        # Infos privées réservées aux Master
        my (
            $iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc,
            $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd,
            $sMatchingUserInfo1, $sMatchingUserInfo2
        ) = getNickInfo($self, $message);

        if (defined $iMatchingUserId && $iMatchingUserAuth && checkUserLevel($self, $iMatchingUserLevel, "Master")) {
            botNotice($self, $sNick, "Chan modes : $chanmode - Key : $sKey - Auto join : $sAutoJoin");
        }

        # Liste des flags CHANSET
        $sQuery = "SELECT chanset FROM CHANSET_LIST,CHANNEL_SET,CHANNEL WHERE CHANNEL_SET.id_channel=CHANNEL.id_channel AND CHANNEL_SET.id_chanset_list=CHANSET_LIST.id_chanset_list AND name=?";
        $sth = $self->{dbh}->prepare($sQuery);
        unless ($sth->execute($sChannel)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        } else {
            my $sChansetFlags = "Channel flags ";
            my $i;
            my $isChansetAntiFlood = 0;

            while (my $ref = $sth->fetchrow_hashref()) {
                my $chanset = $ref->{'chanset'};
                $sChansetFlags .= "+$chanset ";
                $isChansetAntiFlood = 1 if $chanset =~ /AntiFlood/i;
                $i++;
            }

            botNotice($self, $sNick, $sChansetFlags) if $i;

            # Si le flag AntiFlood est présent, on récupère les paramètres
            if ($isChansetAntiFlood) {
                my $channel_obj = $self->{channels}{$sChannel};
                if (defined $channel_obj) {
                    my $id_channel = $channel_obj->get_id;

                    $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
                    $sth = $self->{dbh}->prepare($sQuery);
                    unless ($sth->execute($id_channel)) {
                        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
                    } elsif (my $ref = $sth->fetchrow_hashref()) {
                        my $nbmsg_max  = $ref->{'nbmsg_max'};
                        my $nbmsg      = $ref->{'nbmsg'};
                        my $duration   = $ref->{'duration'};
                        my $timetowait = $ref->{'timetowait'};
                        my $notification = $ref->{'notification'};
                        my $sNotification = $notification ? "ON" : "OFF";

                        botNotice($self, $sNick,
                            "Antiflood parameters : $nbmsg_max messages in $duration seconds, wait for $timetowait seconds, notification : $sNotification"
                        );
                    } else {
                        botNotice($self, $sNick, "Antiflood parameters : not set ?");
                    }
                } else {
                    botNotice($self, $sNick, "Antiflood details unavailable: internal channel object not found.");
                }
            }
        }
    } else {
        botNotice($self, $sNick, "The channel $sChannel doesn't appear to be registered");
    }

    logBot($self, $message, $sChannel, "chaninfo", @tArgs);
    $sth->finish;
}

sub channelList(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sQuery="SELECT name,count(id_user) as nbUsers FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel GROUP BY name ORDER by creation_date LIMIT 20";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sNoticeMsg = "[#chan (users)] ";
					while (my $ref = $sth->fetchrow_hashref()) {
						my $name = $ref->{'name'};
						my $nbUsers = $ref->{'nbUsers'};
						$sNoticeMsg .= "$name ($nbUsers) ";
					}
					botNotice($self,$sNick,$sNoticeMsg);
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " chanlist command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " chanlist command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userWhoAmI(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		my $sNoticeMsg = "User $sMatchingUserHandle ($iMatchingUserLevelDesc)";
		my $sQuery = "SELECT password,hostmasks,creation_date,last_login FROM USER WHERE id_user=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($iMatchingUserId)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $sPasswordSet = defined($ref->{'creation_date'}) ? "Password set" : "Password not set";
				$sNoticeMsg .= " - created " . $ref->{'creation_date'} . " - last login " . $ref->{'last_login'};
				botNotice($self,$sNick,$sNoticeMsg);
				botNotice($self,$sNick,$sPasswordSet);
				$sNoticeMsg = "Hostmasks : " . $ref->{'hostmasks'};
				botNotice($self,$sNick,$sNoticeMsg);
			}
		}
		$sNoticeMsg = "Infos : ";
		if (defined($sMatchingUserInfo1)) {
			$sNoticeMsg .= $sMatchingUserInfo1;
		}
		else {
			$sNoticeMsg .= "N/A";
		}
		$sNoticeMsg .= " - ";
		if (defined($sMatchingUserInfo2)) {
			$sNoticeMsg .= $sMatchingUserInfo2;
		}
		else {
			$sNoticeMsg .= "N/A";
		}
		botNotice($self,$sNick,$sNoticeMsg);
		logBot($self,$message,undef,"whoami",@tArgs);
		$sth->finish;
	}
	else {
		botNotice($self,$sNick,"User not found with this hostmask");
	}
}

sub mbDbAddCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && (($tArgs[1] =~ /^message$/i) || ($tArgs[1] =~ /^action$/i)) && defined($tArgs[2]) && ($tArgs[2] ne "") && defined($tArgs[3]) && ($tArgs[3] ne "")) {
					my $sCommand = $tArgs[0];
					shift @tArgs;
					my $sType = $tArgs[0];
					shift @tArgs;
					my $sCategory = $tArgs[0];
					shift @tArgs;
					my $id_public_commands_category = getCommandCategory($self,$sCategory);
					if (defined($id_public_commands_category)) {
						my $sQuery = "SELECT command FROM PUBLIC_COMMANDS WHERE command LIKE ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sCommand)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							unless (my $ref = $sth->fetchrow_hashref()) {
								botNotice($self,$sNick,"Adding command $sCommand [$sType] " . join (" ",@tArgs));
								my $sAction;
								if ( $sType =~ /^message$/i ) {
									$sAction = "PRIVMSG %c ";
								}
								elsif ($sType =~ /^action$/i ) {
									$sAction = "ACTION %c ";
								}
								$sAction .= join(" ",@tArgs);
								$sQuery = "INSERT INTO PUBLIC_COMMANDS (id_user,id_public_commands_category,command,description,action) VALUES (?,?,?,?,?)";
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($iMatchingUserId,$id_public_commands_category,$sCommand,$sCommand,$sAction)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									botNotice($self,$sNick,"Command $sCommand added");
									logBot($self,$message,undef,"addcmd",("Command $sCommand added"));
								}
							}
							else {
								botNotice($self,$sNick,"$sCommand command already exists");
							}
						}
						$sth->finish;
					}
					else {
						botNotice($self,$sNick,"Unknown category : $sCategory");
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: addcmd <command> <message|action> <category> <text>");
					botNotice($self,$sNick,"Ex: m addcmd Hello message general Hello %n !");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " addcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
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

sub mbDbRemCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sCommand = $tArgs[0];
					shift @tArgs;
					my $sQuery = "SELECT id_user,id_public_commands FROM PUBLIC_COMMANDS WHERE command LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCommand)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_public_commands = $ref->{'id_public_commands'};
							my $id_user = $ref->{'id_user'};
							if (($id_user == $iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Master")) {
								botNotice($self,$sNick,"Removing command $sCommand");
								$sQuery = "DELETE FROM PUBLIC_COMMANDS WHERE id_public_commands=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($id_public_commands)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									botNotice($self,$sNick,"Command $sCommand removed");
									logBot($self,$message,undef,"remcmd",("Command $sCommand removed"));
								}
							}
							else {
								botNotice($self,$sNick,"$sCommand command belongs to another user");
							}
						}
						else {
							botNotice($self,$sNick,"$sCommand command does not exist");
						}
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: remcmd <command>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " remcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " remcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub mbDbModCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && (($tArgs[1] =~ /^message$/i) || ($tArgs[1] =~ /^action$/i)) && defined($tArgs[2]) && ($tArgs[2] ne "") && defined($tArgs[3]) && ($tArgs[3] ne "")) {
					my $sCommand = $tArgs[0];
					shift @tArgs;
					my $sType = $tArgs[0];
					shift @tArgs;
					my $sCategory = $tArgs[0];
					shift @tArgs;
					my $sQuery = "SELECT id_public_commands,id_user FROM PUBLIC_COMMANDS WHERE command LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCommand)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_user = $ref->{'id_user'};
							my $id_public_commands = $ref->{'id_public_commands'};
							if (($id_user == $iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Master")) {
								my $id_public_commands_category = getCommandCategory($self,$sCategory);
								if (defined($id_public_commands_category)) {
									botNotice($self,$sNick,"Modifying command $sCommand [$sType] " . join (" ",@tArgs));
									my $sAction;
									if ( $sType =~ /^message$/i ) {
										$sAction = "PRIVMSG %c ";
									}
									elsif ($sType =~ /^action$/i ) {
										$sAction = "ACTION %c ";
									}
									$sAction .= join(" ",@tArgs);
									$sQuery = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=?,action=? WHERE id_public_commands=?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_public_commands_category,$sAction,$id_public_commands)) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										botNotice($self,$sNick,"Command $sCommand modified");
										logBot($self,$message,undef,"modcmd",("Command $sCommand modified"));
									}
								}
								else {
									botNotice($self,$sNick,"Unknown category : $sCategory");
								}
							}
							else {
								botNotice($self,$sNick,"$sCommand command belongs to another user");
							}
						}
						else {
							botNotice($self,$sNick,"$sCommand command does not exist");
						}
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: modcmd <command> <message|action> <category> <text>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " modcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " modcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub mbChownCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sCommand = $tArgs[0];
					my $sUsername = $tArgs[1];
					my $sQuery = "SELECT nickname,USER.id_user,id_public_commands FROM PUBLIC_COMMANDS,USER WHERE PUBLIC_COMMANDS.id_user=USER.id_user AND command LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCommand)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_public_commands = $ref->{'id_public_commands'};
							my $id_user = $ref->{'id_user'};
							my $nickname = $ref->{'nickname'};
							$sQuery = "SELECT id_user,nickname FROM USER WHERE nickname LIKE ?";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sUsername)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $id_user_new = $ref->{'id_user'};
									$sQuery = "UPDATE PUBLIC_COMMANDS SET id_user=? WHERE id_public_commands=?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_user_new,$id_public_commands)) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										botNotice($self,$sNick,"Changed owner of command $sCommand ($nickname -> $sUsername)");
										logBot($self,$message,undef,"chowncmd",("Changed owner of command $sCommand ($nickname -> $sUsername)"));
									}
								}
								else {
									botNotice($self,$sNick,"$sUsername user does not exist");
								}
							}
						}
						else {
							botNotice($self,$sNick,"$sCommand command does not exist");
						}
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: chowncmd <command> <username>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " chowncmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " chowncmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub channelStatLines(@) {
	my ($self,$message,$sChannel,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sTargetChannel;
				if (!defined($sChannel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $tArgs[0];
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						botNotice($self,$sNick,"Syntax: chanstatlines <#channel>");
						return undef;
					}
				}
				else {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $sChannel;
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						$sTargetChannel = $sChannel;
					}
				}
				my $sQuery = "SELECT COUNT(*) as nbLinesPerHour FROM CHANNEL,CHANNEL_LOG WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND CHANNEL.name like ? AND ts > date_sub('" . time2str("%Y-%m-%d %H:%M:%S",time) . "', INTERVAL 1 HOUR)";
				$self->{logger}->log(3,$sQuery);
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nbLinesPerHour = $ref->{'nbLinesPerHour'};
						my $sLineTxt = "line";
						if ( $nbLinesPerHour > 0 ) {
							$sLineTxt .= "s";
						}
						botPrivmsg($self,$sTargetChannel,"$nbLinesPerHour $sLineTxt per hour on $sChannel");
						logBot($self,$message,undef,"chanstatlines",($sChannel));
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel is not registered");
					}
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " chanstatlines command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " chanstatlines command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub whoTalk(@) {
	my ($self,$message,$sChannel,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sTargetChannel;
				if (!defined($sChannel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $tArgs[0];
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						botNotice($self,$sNick,"Syntax: whotalk <#channel>");
						return undef;
					}
				}
				else {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $sChannel;
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						$sTargetChannel = $sChannel;
					}
				}
				my $sQuery = "SELECT nick,COUNT(nick) as nbLinesPerHour FROM CHANNEL,CHANNEL_LOG WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND (event_type='public' OR event_type='action') AND CHANNEL.name like ? AND ts > date_sub('" . time2str("%Y-%m-%d %H:%M:%S",time) . "', INTERVAL 1 HOUR) GROUP BY nick ORDER BY nbLinesPerHour DESC LIMIT 20";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sResult = "Top 20 talkers ";
					my $i = 0;
					while (my $ref = $sth->fetchrow_hashref()) {
						my $nbLinesPerHour = $ref->{'nbLinesPerHour'};
						my $sCurrentNick = $ref->{'nick'};
						$sResult .= "$sCurrentNick ($nbLinesPerHour) ";
						$i++;
					}
					unless ($i) {
						botNotice($self,$sNick,"No result for $sChannel");
					}
					else {
						botPrivmsg($self,$sTargetChannel,"$sResult per hour on $sChannel");
					}
					logBot($self,$message,undef,"whotalk",($sChannel));
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " whotalk command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " whotalk command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub mbDbMvCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sCommand = $tArgs[0];
					my $sCommandNew = $tArgs[1];
					my $sQuery = "SELECT id_user,id_public_commands FROM PUBLIC_COMMANDS WHERE command LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCommand)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_public_commands = $ref->{'id_public_commands'};
							my $id_user = $ref->{'id_user'};
							if (($id_user == $iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Master")) {
								botNotice($self,$sNick,"Renaming command $sCommand");
								$sQuery = "UPDATE PUBLIC_COMMANDS SET command=? WHERE id_public_commands=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($sCommandNew,$id_public_commands)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									botNotice($self,$sNick,"Does command $sCommandNew already exists ?");
								}
								else {
									botNotice($self,$sNick,"Command $sCommand renamed to $sCommandNew");
									logBot($self,$message,undef,"mvcmd",("Command $sCommand renamed to $sCommandNew"));
								}
							}
							else {
								botNotice($self,$sNick,"$sCommand command belongs to another user");
							}
						}
						else {
							botNotice($self,$sNick,"$sCommand command does not exist");
						}
					}
					$sth->finish;
				}
				else {
					botNotice($self,$sNick,"Syntax: mvcmd <command_old> <command_new>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " mvcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " mvcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub mbDbHoldCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					botNotice($self,$sNick,"Syntax: addcatcmd <new_catgeroy>");
				}
				else {
					logBot($self,$message,$sChannel,"holdcmd",@tArgs);
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " addcatcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addcatcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub mbDbAddCategoryCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sCategory = $tArgs[0];
					my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCategory)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							botNotice($self,$sNick,"Category $sCategory already exists");
							$sth->finish;
						}
						else {
							# Add category
							$sQuery = "INSERT INTO PUBLIC_COMMANDS_CATEGORY (description) VALUES (?)";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sCategory)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								botNotice($self,$sNick,"Category $sCategory added");
								logBot($self,$message,$sChannel,"addcatcmd",("Category $sCategory added"));
							}
						}
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: addcatcmd <new_catgeroy>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " addcatcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addcatcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub mbDbChangeCategoryCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sCategory = $tArgs[0];
					my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCategory)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						unless (my $ref = $sth->fetchrow_hashref()) {
							botNotice($self,$sNick,"Category $sCategory does not exist");
							$sth->finish;
						}
						else {
							my $id_public_commands_category = $ref->{'id_public_commands_category'};
							$sQuery = "SELECT id_public_commands FROM PUBLIC_COMMANDS WHERE command LIKE ?";
							# Change category
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								unless (my $ref = $sth->fetchrow_hashref()) {
								botNotice($self,$sNick,"Command " . $tArgs[1] . " does not exist");
									$sth->finish;
								}
								else {
									$sQuery = "UPDATE PUBLIC_COMMANDS SET id_public_commands_category=? WHERE command like ?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_public_commands_category,$tArgs[1])) {
										$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										botNotice($self,$sNick,"Changed category to $sCategory for " . $tArgs[1]);
										logBot($self,$message,$sChannel,"chcatcmd",("Changed category to $sCategory for " . $tArgs[1]));
									}
								}
							}
						}
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: chcatcmd <new_category> <command>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " chcatcmd command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " chcatcmd command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userTopSay(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $isPrivate = !defined($sChannel);
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sChannelDest = $sChannel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				unless (defined($sChannel)) {
					botNotice($self,$sNick,"Syntax: topsay [#channel] <nick>");
					return undef;
				}
				unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					$tArgs[0] = $sNick;
				}
				my $sQuery = "SELECT event_type,publictext,count(publictext) as hit FROM CHANNEL,CHANNEL_LOG WHERE (event_type='public' OR event_type='action') AND CHANNEL.id_channel=CHANNEL_LOG.id_channel AND name=? AND nick like ? GROUP BY publictext ORDER by hit DESC LIMIT 30";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel,$tArgs[0])) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sTopSay = $tArgs[0] . " : ";
					my $sTopSayMax = $sTopSay;
					my $i = 0;
					while (my $ref = $sth->fetchrow_hashref()) {
						my $publictext = $ref->{'publictext'};
						my $event_type = $ref->{'event_type'};
						my $hit = $ref->{'hit'};
						$publictext =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;
						unless (($publictext =~ /^\s*$/) || ($publictext eq ':)') || ($publictext eq ';)') || ($publictext eq ':p') || ($publictext eq ':P') || ($publictext eq ':d') || ($publictext eq ':D') || ($publictext eq ':o') || ($publictext eq ':O') || ($publictext eq '(:') || ($publictext eq '(;') || ($publictext =~ /lol/i) || ($publictext eq 'xD') || ($publictext eq 'XD') || ($publictext eq 'heh') || ($publictext eq 'hah') || ($publictext eq 'huh') || ($publictext eq 'hih') || ($publictext eq '!bang') || ($publictext eq '!reload') || ($publictext eq '!inventory') || ($publictext eq '!lastduck') || ($publictext eq '!tappe') || ($publictext eq '!duckstats') || ($publictext =~ /^!shop/i) || ($publictext eq '=D') || ($publictext eq '=)') || ($publictext eq ';p') || ($publictext eq ':>') || ($publictext eq ';>')) {
							if ( $event_type eq "action" ) {
								$sTopSayMax .= String::IRC->new("$publictext ($hit) ")->bold;
								if (length($sTopSayMax) < 300) {
									$sTopSay .= String::IRC->new("$publictext ($hit) ")->bold;
								}
								else {
									$i++;
									last;
								}
							}
							else {
								$sTopSayMax .= "$publictext ($hit) ";
								if (length($sTopSayMax) < 300) {
									$sTopSay .= "$publictext ($hit) ";
								}
								else {
									$i++;
									last;
								}
							}
							$i++;
						}
					}
					if ( $i ) {
						unless ($isPrivate) {
							botPrivmsg($self,$sChannelDest,$sTopSay);
						}
						else {
							botNotice($self,$sNick,$sTopSay);
						}
					}
					else {
						if (defined($sChannel)) {
							botPrivmsg($self,$sChannelDest,"No results.");
						}
						else {
							botNotice($self,$sNick,"No results.");
						}
					}
					my $sNoticeMsg = $message->prefix . " topsay on " . $tArgs[0];
					logBot($self,$message,$sChannel,"topsay",$sNoticeMsg);
					$sth->finish;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix;
				$sNoticeMsg .= " topsay command attempt for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"This command is not available for your level. Contact a bot master.");
				logBot($self,$message,$sChannel,"topsay",$sNoticeMsg);
			}
		}
		else {
			my $sNoticeMsg = $message->prefix;
			$sNoticeMsg .= " topsay command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command : /msg " . $self->{irc}->nick_folded . " login username password");
			logBot($self,$message,$sChannel,"topsay",$sNoticeMsg);
		}
	}
}

# checkhostchan [#channel] <hostname>
sub mbDbCheckHostnameNickChan(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $isPrivate = !defined($sChannel);
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sChannelDest = $sChannel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sHostname = $tArgs[0];
					my $sQuery = "SELECT nick,count(nick) as hits FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND name=? AND userhost like '%!%@" . $sHostname . "' GROUP BY nick ORDER by hits DESC LIMIT 10";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sResponse = "Nicks for host $sHostname on $sChannel - ";
						my $i = 0;
						while (my $ref = $sth->fetchrow_hashref()) {
							my $sNickFound = $ref->{'nick'};
							my $sHitsFound = $ref->{'hits'};
							$sResponse .= "$sNickFound ($sHitsFound) ";
							$i++;
						}
						unless ( $i ) {
							$sResponse = "No result found for hostname $sHostname on $sChannel";
						}
						unless ($isPrivate) {
							botPrivmsg($self,$sChannelDest,$sResponse);
						}
						else {
							botNotice($self,$sNick,$sResponse);
						}
						logBot($self,$message,$sChannelDest,"checkhostchan",($sHostname));
						$sth->finish;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: checkhostchan <hostname>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " checkhostchan command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " checkhostchan command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# checkhost <hostname>
sub mbDbCheckHostnameNick(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $isPrivate = !defined($sChannel);
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sHostname = $tArgs[0];
					my $sQuery = "SELECT nick,count(nick) as hits FROM CHANNEL_LOG WHERE userhost like '%!%@" . $sHostname . "' GROUP BY nick ORDER by hits DESC LIMIT 10";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sResponse = "Nicks for host $sHostname - ";
						my $i = 0;
						while (my $ref = $sth->fetchrow_hashref()) {
							my $sNickFound = $ref->{'nick'};
							my $sHitsFound = $ref->{'hits'};
							$sResponse .= "$sNickFound ($sHitsFound) ";
							$i++;
						}
						unless ( $i ) {
							$sResponse = "No result found for hostname : $sHostname";
						}
						unless ($isPrivate) {
							botPrivmsg($self,$sChannel,$sResponse);
						}
						else {
							botNotice($self,$sNick,$sResponse);
						}
						logBot($self,$message,$sChannel,"checkhost",($sHostname));
						$sth->finish;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: checkhost <hostname>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " checkhost command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " checkhost command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# checknick <nick>
sub mbDbCheckNickHostname(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $isPrivate = !defined($sChannel);
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sNickSearch = $tArgs[0];
					my $sQuery = "SELECT userhost,count(userhost) as hits FROM CHANNEL_LOG WHERE nick LIKE ? GROUP BY userhost ORDER BY hits DESC LIMIT 10";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sNickSearch)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sResponse = "Hostmasks for $sNickSearch - ";
						my $i = 0;
						while (my $ref = $sth->fetchrow_hashref()) {
							my $HostmaskFound = $ref->{'userhost'};
							$HostmaskFound =~ s/^.*!//;
							my $sHitsFound = $ref->{'hits'};
							$sResponse .= "$HostmaskFound ($sHitsFound) ";
							$i++;
						}
						unless ( $i ) {
							$sResponse = "No result found for nick : $sNickSearch";
						}
						unless ($isPrivate) {
							botPrivmsg($self,$sChannel,$sResponse);
						}
						else {
							botNotice($self,$sNick,$sResponse);
						}
						logBot($self,$message,$sChannel,"checknick",($sNickSearch));
						$sth->finish;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: checknick <nick>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " checknick command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " checknick command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub userAuthNick(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %WHOIS_VARS;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					$WHOIS_VARS{'nick'} = $tArgs[0];
					$WHOIS_VARS{'sub'} = "userAuthNick";
					$WHOIS_VARS{'caller'} = $sNick;
					$WHOIS_VARS{'channel'} = undef;
					$WHOIS_VARS{'message'} = $message;
					$self->{irc}->send_message("WHOIS", undef, $tArgs[0]);
					%{$self->{WHOIS_VARS}} = %WHOIS_VARS;
					return undef;
				}
				else {
					botNotice($self,$sNick,"Syntax: auth <nick>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " auth command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " auth command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

# nicklist #channel
sub channelNickList(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %hChannelsNicks = ();
	if (defined($self->{hChannelsNicks})) {
		%hChannelsNicks = %{$self->{hChannelsNicks}};
	}
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				unless (defined($sChannel)) {
					botNotice($self,$sNick,"Syntax: nicklist #channel");
					return undef;
				}
				$self->{logger}->log(0,"Users on $sChannel : " . join(" ",@{$hChannelsNicks{$sChannel}}));
			}
			else {
				my $sNoticeMsg = $message->prefix . " nicklist command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " nicklist command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# rnick #channel
sub randomChannelNick(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %hChannelsNicks;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				unless (defined($sChannel)) {
					botNotice($self,$sNick,"Syntax: rnick #channel");
					return undef;
				}
				botNotice($self,$sNick,"Random nick on $sChannel : " . getRandomNick($self,$sChannel));
			}
			else {
				my $sNoticeMsg = $message->prefix . " nicklist command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " nicklist command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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
    my $level = $tArgs[0];

    my $irc_nick = $self->{irc}->nick_folded;
    my $conf     = $self->{conf}; # object Mediabot::Conf

    my ($uid, $ulevel, $ulevel_desc, $is_auth, $uhandle, $upass, $info1, $info2) = getNickInfo($self, $message);

    unless (defined $uid) {
        return; # no user matched, silent fail
    }

    unless ($is_auth) {
        botNotice($self, $sNick, "You must be logged to use this command - /msg $irc_nick login username password");
        return;
    }

    unless (defined $ulevel && checkUserLevel($self, $ulevel, "Owner")) {
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

# Restart the bot
sub mbRestart(@) {
	my ($self, $message, $sNick, @tArgs) = @_;
	my $conf = $self->{conf};  # nouvelle méthode de lecture de config

	my ($iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc, $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd, $sMatchingUserInfo1, $sMatchingUserInfo2) = getNickInfo($self, $message);

	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self, $iMatchingUserLevel, "Owner")) {
				my $iCHildPid;
				if (defined($iCHildPid = fork())) {
					unless ($iCHildPid) {
						$self->{logger}->log( 0, "Restart request from $sMatchingUserHandle");
						setsid;
						exec "./mb_restart.sh", $tArgs[0];
					} else {
						botNotice($self, $sNick, "Restarting bot");
						logBot($self, $message, undef, "restart", $conf->get('main.MAIN_PROG_QUIT_MSG'));
						$self->{Quit} = 1;
						$self->{irc}->send_message("QUIT", undef, "Restarting");
					}
				}
				logBot($self, $message, undef, "restart", undef);
			} else {
				botNotice($self, $sNick, "Your level does not allow you to use this command.");
				return undef;
			}
		} else {
			botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Jump to another server
sub mbJump(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				my $sServer = pop @tArgs;
				my $sFullParams = join(" ",@tArgs);
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					$sFullParams =~ s/\-\-server=[^ ]*//g;
					$self->{logger}->log(3,$sFullParams);
					my $iCHildPid;
					if (defined($iCHildPid = fork())) {
						unless ($iCHildPid) {
							$self->{logger}->log(0,"Jump request from $sMatchingUserHandle");
							setsid;
							exec "./mb_restart.sh",($sFullParams,"--server=$sServer");
						}
						else {
							botNotice($self,$sNick,"Jumping to $sServer");
							logBot($self,$message,undef,"jump",($sServer));
							$self->{Quit} = 1;
							$self->{irc}->send_message( "QUIT", undef, "Changing server" );
						}
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: jump <server>");
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

# In progress...
sub mbSeen(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		# Quit vars from EVENT_LOG
		my $tsQuit;
		my $channelQuit;
		my $msgQuit;
		my $userhostQuit;
		
		my $sQuery = "SELECT * FROM CHANNEL_LOG WHERE nick like ? AND event_type='quit' ORDER BY ts DESC LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($tArgs[0])) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sCommandText;
			if (my $ref = $sth->fetchrow_hashref()) {
				$tsQuit = $ref->{'ts'};
				$channelQuit = $ref->{'name'};
				$msgQuit = $ref->{'publictext'};
				$userhostQuit = $ref->{'userhost'};
				$self->{logger}->log(3,"mbSeen() Quit : $tsQuit");
			}
		}
		
		my $tsPart;
		my $channelPart;
		my $msgPart;
		my $userhostPart;
		# Part vars from CHANNEL_LOG
		$sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND CHANNEL.name like ? AND nick like ? AND event_type='part' ORDER BY ts DESC LIMIT 1";
		$sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$tArgs[0])) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sCommandText;
			if (my $ref = $sth->fetchrow_hashref()) {
				$tsPart = $ref->{'ts'};
				$channelPart = $ref->{'name'};
				$msgPart = $ref->{'publictext'};
				$userhostPart = $ref->{'userhost'};
				$self->{logger}->log(3,"mbSeen() Part : $tsPart");
			}
		}
		
		my $epochTsQuit;
		unless (defined($tsQuit)) {
			$epochTsQuit = 0;
		}
		else {
			# I know this is ugly, ts logs are in CEST in my case, I'll take care of TZ later...
			$epochTsQuit = str2time($tsQuit) - 21600;
		}
		my $epochTsPart;
		unless (defined($tsPart)) {
			$epochTsPart = 0;
		}
		else {
			# I know this is ugly, ts logs are in CEST in my case, I'll take care of TZ later...
			$epochTsPart = str2time($tsPart) - 21600;
		}
		if (( $epochTsQuit == 0) && ( $epochTsPart == 0)) {
			botPrivmsg($self,$sChannel,"I don't remember seeing nick ". $tArgs[0]);
		}
		else {
			if ( $epochTsPart > $epochTsQuit ) {
				$userhostPart =~ s/^.*!//;
				botPrivmsg($self,$sChannel,$tArgs[0] . " ($userhostPart) was last seen parting $sChannel : $tsPart ($msgPart)");
			}
			elsif ( $epochTsQuit != 0) {
				$userhostQuit =~ s/^.*!//;
				botPrivmsg($self,$sChannel,$tArgs[0] . " ($userhostQuit) was last seen quitting : $tsQuit ($msgQuit)");
			}
			else {
				
			}
		}
		
		logBot($self,$message,$sChannel,"seen",@tArgs);
		$sth->finish;
	}
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

sub displayDate(@) {
	#u date user add <username> <timezone>
	#u date user del <username>
	#u date list
	#u date list EUrope/Paris
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sDefaultTZ = 'America/New_York';
	if (defined($tArgs[0])) {
		switch($tArgs[0]) {
			case /^fr$/i { $sDefaultTZ = 'Europe/Paris'; }
			case /^Moscow$/i { $sDefaultTZ = 'Europe/Moscow'; }
			case /^LA$/i { $sDefaultTZ = 'America/Los_Angeles'; }
			case /^DK$/i { $sDefaultTZ = 'Europe/Copenhagen'; }
			case /^me$/i {
				my @tAnswers = ( "Ok $sNick, I'll pick you up at eight ;>", "I have to ask my daddy first $sNick ^^", "let's skip that $sNick, and go to your place :P~");
				botPrivmsg($self,$sChannel,$tAnswers[rand($#tAnswers + 1)]);
				return undef;
			}
			case /^list$/i {
				botPrivmsg($self,$sChannel,"Available Timezones can be found here : https://pastebin.com/4p4pby3y");
				return 0;
			}
			case /^user$/i {
				my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
				if (defined($iMatchingUserId)) {
					if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
						if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
							if (defined($tArgs[1]) && ($tArgs[1] ne "")) {
								switch($tArgs[1]) {
									case /^add$/i {
										my $sQuery = "SELECT nickname,tz FROM USER WHERE nickname like ?";
										my $sth = $self->{dbh}->prepare($sQuery);
										if (defined($tArgs[2]) && ($tArgs[2] ne "") && defined($tArgs[3] && $tArgs[3] ne "")) {
											unless ($sth->execute($tArgs[2])) {
												$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
											}
											else {
												my $i = 0;
												if (my $ref = $sth->fetchrow_hashref()) {
													my $tz = $ref->{'tz'};
													my $nick = $ref->{'nickname'};
													if (defined($tz)) {
														botPrivmsg($self,$sChannel,"$nick has already a timezone set to $tz, delete it before change it");
														return undef;
													}
													else {
														$self->{logger}->log(3,"$nick has no defined timezone");
														$sQuery = "SELECT tz FROM TIMEZONE WHERE tz like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($tArgs[3])) {
															$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															my $i = 0;
															if (my $ref = $sth->fetchrow_hashref()) {
																my $tzset = $ref->{'tz'};
																if (defined($tzset)) {
																	$self->{logger}->log(3,"Found timezone : $tzset");
																	$sQuery = "UPDATE USER SET tz=? WHERE nickname like ?";
																	$sth = $self->{dbh}->prepare($sQuery);
																	unless ($sth->execute($tzset,$nick)) {
																		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																	}
																	else {
																		my $time = DateTime->now( time_zone => $tzset );
																		botPrivmsg($self,$sChannel,"Updated timezone for $nick : $tzset " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
																		return 0;
																	}
																	return undef;
																}
																else {
																	botPrivmsg($self,$sChannel,"Something weird happened. Sorry try again.");
																	return undef;
																}
																$i++;
															}
															else {
																botPrivmsg($self,$sChannel,"Timezone $tArgs[3] was not found. Available Timezones can be found here : https://pastebin.com/4p4pby3y");
																return undef;
															}
															logBot($self,$message,$sChannel,"date",@tArgs);
														}
														$sth->finish;
														return 0;
													}
													$i++;
												}
												else {
													botPrivmsg($self,$sChannel,"$tArgs[2] user unknown");
													return undef;
												}
												logBot($self,$message,$sChannel,"date",@tArgs);
											}
											$sth->finish;
										}
										else {
											botPrivmsg($self,$sChannel,"date user add <nick> <timezone>");
										}
									}
									case /^del$/i {
										my $sQuery = "SELECT nickname,tz FROM USER WHERE nickname like ?";
										my $sth = $self->{dbh}->prepare($sQuery);
										if (defined($tArgs[2]) && ($tArgs[2] ne "")) {
											unless ($sth->execute($tArgs[2])) {
												$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
											}
											else {
												my $i = 0;
												if (my $ref = $sth->fetchrow_hashref()) {
													my $tz = $ref->{'tz'};
													my $nick = $ref->{'nickname'};
													if (defined($tz)) {
														$self->{logger}->log(3,"$nick has already a timezone set to $tz, let's delete it.");
														$sQuery = "UPDATE USER SET tz=NULL WHERE nickname like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($tArgs[2])) {
															$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															botPrivmsg($self,$sChannel,"Deleted timezone for user $nick.");
														}
														return undef;
													}
													else {
														botPrivmsg($self,$sChannel,"$nick has no defined timezone.");
													}
													$i++;
												}
												else {
													botPrivmsg($self,$sChannel,"$tArgs[2] user unknown");
													return undef;
												}
												logBot($self,$message,$sChannel,"date",@tArgs);
											}
											$sth->finish;
										}
										else {
											botPrivmsg($self,$sChannel,"date user del <nick>");
										}
									}
									else {
										
									}
								}
							}
							else {
								botPrivmsg($self,$sChannel,"date user add <nick> <timezone>");
								botPrivmsg($self,$sChannel,"date user del <nick>");
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
			else {
				my $sQuery = "SELECT nickname,tz FROM USER WHERE nickname like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($tArgs[0])) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $i = 0;
					if (my $ref = $sth->fetchrow_hashref()) {
						my $tz = $ref->{'tz'};
						my $nick = $ref->{'nickname'};
						if (defined($tz)) {
							my $time = DateTime->now( time_zone => $tz );
							botPrivmsg($self,$sChannel,"Current date for $nick $tz " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
							return 0;
						}
						else {
							$sQuery = "SELECT tz FROM TIMEZONE WHERE tz like ?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[0])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $i = 0;
								if (my $ref = $sth->fetchrow_hashref()) {
									my $tz = $ref->{'tz'};
									my $time = DateTime->now( time_zone => $tz );
									botPrivmsg($self,$sChannel,"$tz " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
									$i++;
								}
								return 0;
							}
							botPrivmsg($self,$sChannel,"I don't know this timezone or user's timezone.");
							return undef;
						}
						$i++;
					}
					else {
						$sQuery = "SELECT tz FROM TIMEZONE WHERE tz like ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $i = 0;
							if (my $ref = $sth->fetchrow_hashref()) {
								my $tz = $ref->{'tz'};
								my $time = DateTime->now( time_zone => $tz );
								botPrivmsg($self,$sChannel,"$tz " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
								$i++;
							}
							return 0;
						}
						botPrivmsg($self,$sChannel,"I don't know this timezone or user's timezone.");
						return undef;
					}
					logBot($self,$message,$sChannel,"date",@tArgs);
				}
				$sth->finish;
				botPrivmsg($self,$sChannel,"date <timezone> -or- date <timezone_alias>");
				botPrivmsg($self,$sChannel,"date user add <nick> <timezone>");
				botPrivmsg($self,$sChannel,"date user del <nick>");
				botPrivmsg($self,$sChannel,"date list");
				return undef;
			}
		}
	}
	
	my $time = DateTime->now( time_zone => $sDefaultTZ );
	botPrivmsg($self,$sChannel,"$sDefaultTZ : " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
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

# Add a new responder
sub addResponder {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user info
    my (
        $iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc,
        $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd,
        $sMatchingUserInfo1, $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    # Require login and master level
    unless (defined $iMatchingUserId && $iMatchingUserAuth) {
        my $sNoticeMsg = $message->prefix . " addresponder command attempt (user $sMatchingUserHandle is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $iMatchingUserLevel, "Master")) {
        my $sNoticeMsg = $message->prefix . " addresponder command attempt (command level [Master] for user $sMatchingUserHandle [$iMatchingUserLevel])";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Optional channel name
    my $id_channel = 0;
    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
        my $channel_obj = $self->{channels}{$sChannel};
        if (defined $channel_obj) {
            $id_channel = $channel_obj->get_id;
            $self->{logger}->log(3, "Adding responder for channel $sChannel ($id_channel)");
        } else {
            botNotice($self, $sNick, "$sChannel is not registered to me");
            return;
        }
    } else {
        $self->{logger}->log(3, "Adding global responder");
    }

    # Syntax fallback
    my $syntax_msg = "Syntax : addresponder [#channel] <chance> <responder> | <answer>";

    # Check chance
    my $chance = shift @tArgs;
    unless (defined $chance && $chance =~ /^[0-9]+$/ && $chance <= 100) {
        botNotice($self, $sNick, $syntax_msg);
        return;
    }

    # Join remaining args and split on first '|'
    my $sJoined = join(' ', @tArgs);
    my ($sResponder, $sAnswer) = split(/\s*\|\s*/, $sJoined, 2);
    unless (defined $sResponder && defined $sAnswer && $sResponder ne "" && $sAnswer ne "") {
        botNotice($self, $sNick, $syntax_msg);
        return;
    }

    $self->{logger}->log(3, "Parsed responder: '$sResponder' -> '$sAnswer' at $chance%");

    # Check existing entry
    my $sQuery = "SELECT * FROM RESPONDERS WHERE id_channel=? AND responder LIKE ?";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute($id_channel, $sResponder)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $existing_answer = $ref->{'answer'};
        my $iChance = $ref->{'chance'};
        my $hits = $ref->{'hits'};
        $self->{logger}->log(3, "Found existing responder: $sResponder -> $existing_answer ($iChance%) [$hits hits]");
        botNotice($self, $sNick, "Found answer '$existing_answer' for responder '$sResponder' with chance $iChance on $sChannel [hits: $hits]");
    } else {
        # Insert new responder
        $sQuery = "INSERT INTO RESPONDERS (id_channel, chance, responder, answer) VALUES (?,?,?,?)";
        $sth = $self->{dbh}->prepare($sQuery);
        unless ($sth->execute($id_channel, (100 - $chance), $sResponder, $sAnswer)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        } else {
            my $responder_type = ($id_channel == 0) ? "global responder" : "responder for channel $sChannel";
            botNotice($self, $sNick, "Added $responder_type: $sResponder with chance $chance% → $sAnswer");
        }
    }

    $sth->finish;
    return 0;
}

# Delete a responder
sub delResponder {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    # Get user info
    my (
        $iMatchingUserId, $iMatchingUserLevel, $iMatchingUserLevelDesc,
        $iMatchingUserAuth, $sMatchingUserHandle, $sMatchingUserPasswd,
        $sMatchingUserInfo1, $sMatchingUserInfo2
    ) = getNickInfo($self, $message);

    # Auth checks
    unless (defined $iMatchingUserId && $iMatchingUserAuth) {
        my $sNoticeMsg = $message->prefix . " delresponder command attempt (user $sMatchingUserHandle is not logged in)";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $iMatchingUserLevel, "Master")) {
        my $sNoticeMsg = $message->prefix . " delresponder command attempt (command level [Master] for user $sMatchingUserHandle [$iMatchingUserLevel])";
        noticeConsoleChan($self, $sNoticeMsg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    # Init channel context
    my $id_channel = 0;
    my $responder_type = "global responder";

    if (defined $tArgs[0] && $tArgs[0] =~ /^#/) {
        $sChannel = shift @tArgs;
        my $channel_obj = $self->{channels}{$sChannel};
        if (defined $channel_obj) {
            $id_channel = $channel_obj->get_id;
            $responder_type = "responder for channel $sChannel";
            $self->{logger}->log(3, "Deleting responder for $sChannel ($id_channel)");
        } else {
            botNotice($self, $sNick, "$sChannel is not registered to me");
            return;
        }
    } else {
        $self->{logger}->log(3, "Deleting global responder");
    }

    # Parse responder
    my $sResponder = join(" ", @tArgs);
    unless (defined $sResponder && $sResponder ne "") {
        botNotice($self, $sNick, "Syntax : delresponder [#channel] <responder>");
        return;
    }

    # Look up
    my $sQuery = "SELECT * FROM RESPONDERS WHERE id_channel=? AND responder LIKE ?";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth->execute($id_channel, $sResponder)) {
        $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $answer = $ref->{'answer'};
        my $iChance = $ref->{'chance'};
        my $hits = $ref->{'hits'};
        $self->{logger}->log(3, "delResponder() Found answer '$answer' for responder '$sResponder'");

        # Delete it
        $sQuery = "DELETE FROM RESPONDERS WHERE id_channel=? AND responder LIKE ?";
        $sth = $self->{dbh}->prepare($sQuery);
        unless ($sth->execute($id_channel, $sResponder)) {
            $self->{logger}->log(1, "SQL Error: $DBI::errstr Query: $sQuery");
        } else {
            botNotice(
                $self, $sNick,
                "Deleted $responder_type : '$sResponder' with chance " . (100 - $iChance) . "% → $answer [hits: $hits]"
            );
        }
    } else {
        botNotice($self, $sNick, "Could not find a $responder_type matching '$sResponder'");
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

sub channelAddBadword(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sTargetChannel;
				if (!defined($sChannel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $tArgs[0];
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						botNotice($self,$sNick,"Syntax: addbadword <#channel> <badword text>");
						return undef;
					}
				}
				else {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $sChannel;
						$sChannel = $tArgs[0];
						unless (defined(getIdChannel($self,$sChannel))) {
							botNotice($self,$sNick,"Channel #channel is undefined");
							return;
						}
						shift @tArgs;
					}
					else {
						$sTargetChannel = $sChannel;
					}
				}
				my $sAddBadwords = join(" ",@tArgs);
				unless (defined($sAddBadwords) && ($sAddBadwords ne "")) {
					botNotice($self,$sNick,"Syntax: addbadword <#channel> <badword text>");
					return;
				}
				my $sQuery = "SELECT id_badwords,badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND CHANNEL.name like ? AND badword like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel,$sAddBadwords)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $id_badwords = $ref->{'id_badwords'};
						my $sBadword = $ref->{'badword'};
						botNotice($self,$sNick,"Badword [$id_badwords] $sBadword on $sChannel is already set");
						logBot($self,$message,undef,"addbadword",($sChannel));
						$sth->finish;
						return;
					}
					else {
						my $id_channel = getIdChannel($self,$sChannel);
						$sQuery = "INSERT INTO BADWORDS (id_channel,badword) VALUES (?,?)";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_channel,$sAddBadwords)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							botNotice($self,$sNick,"Added badwords $sAddBadwords on $sChannel");
						}
					}
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " addbadword command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addbadword command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub channelRemBadword(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sTargetChannel;
				if (!defined($sChannel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $tArgs[0];
						$sChannel = $tArgs[0];
						shift @tArgs;
					}
					else {
						botNotice($self,$sNick,"Syntax: rembadword <#channel> <badword text>");
						return undef;
					}
				}
				else {
					if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
						$sTargetChannel = $sChannel;
						$sChannel = $tArgs[0];
						unless (defined(getIdChannel($self,$sChannel))) {
							botNotice($self,$sNick,"Channel #channel is undefined");
							return;
						}
						shift @tArgs;
					}
					else {
						$sTargetChannel = $sChannel;
					}
				}
				my $sAddBadwords = join(" ",@tArgs);
				unless (defined($sAddBadwords) && ($sAddBadwords ne "")) {
					botNotice($self,$sNick,"Syntax: rembadword <#channel> <badword text>");
					return;
				}
				my $sQuery = "SELECT id_badwords,badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND CHANNEL.name like ? AND badword like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel,$sAddBadwords)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $id_badwords = $ref->{'id_badwords'};
						my $sBadword = $ref->{'badword'};
						$sQuery = "DELETE FROM BADWORDS WHERE id_badwords=?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_badwords)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							botNotice($self,$sNick,"Removed badwords $sAddBadwords on $sChannel");
							logBot($self,$message,undef,"rembadword",($sChannel));
							$sth->finish;
							return;
						}
					}
					else {
						botNotice($self,$sNick,"Badword $sAddBadwords is not set on $sChannel");
					}
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " rembadword command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " rembadword command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub IgnoresList(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sTargetChannel;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sTargetChannel = $tArgs[0];
					unless (defined(getIdChannel($self,$sChannel))) {
						botNotice($self,$sNick,"Channel sTargetChannel is undefined");
						return;
					}
					shift @tArgs;
				}
				if (defined($sTargetChannel) && ($sTargetChannel ne "")) {
					# Ignores ($sTargetChannel)
					my $sQuery = "SELECT COUNT(*) as nbIgnores FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTargetChannel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $ref = $sth->fetchrow_hashref();
						my $nbIgnores = $ref->{'nbIgnores'};
						$sth->finish;
						if ( $nbIgnores == 0 ) {
							botNotice($self,$sNick,"Ignores ($sTargetChannel) : there is no ignores");
							logBot($self,$message,undef,"ignores",undef);
							return undef;
						}
						else {
							my $sQuery = "SELECT IGNORES.id_ignores,IGNORES.hostmask FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sTargetChannel)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								botNotice($self,$sNick,"Ignores ($sTargetChannel) : there " . ($nbIgnores > 1 ? "are" : "is") . " $nbIgnores ignore" . ($nbIgnores > 1 ? "s" : ""));
								while (my $ref = $sth->fetchrow_hashref()) {
									my $id_ignores = $ref->{'id_ignores'};
									my $sHostmask = $ref->{'hostmask'};
									botNotice($self,$sNick,"ID : $id_ignores : $sHostmask");
								}
							}
						}
					}
				}
				else {
					# Ignores (allchans/private)
					my $sQuery = "SELECT COUNT(*) as nbIgnores FROM IGNORES WHERE id_channel=0";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $ref = $sth->fetchrow_hashref();
						my $nbIgnores = $ref->{'nbIgnores'};
						$sth->finish;
						if ( $nbIgnores == 0 ) {
							botNotice($self,$sNick,"Ignores (allchans/private) : there is no global ignores");
							logBot($self,$message,undef,"ignores",undef);
							return undef;
						}
						else {
							my $sQuery = "SELECT * FROM IGNORES WHERE id_channel=0";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute()) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								botNotice($self,$sNick,"Ignores (allchans/private) : there " . ($nbIgnores > 1 ? "are" : "is") . " $nbIgnores global ignore" . ($nbIgnores > 1 ? "s" : ""));
								while (my $ref = $sth->fetchrow_hashref()) {
									my $id_ignores = $ref->{'id_ignores'};
									my $sHostmask = $ref->{'hostmask'};
									botNotice($self,$sNick,"ID : $id_ignores : $sHostmask");
								}
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " ignores command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " ignores command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub addIgnore(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sTargetChannel;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sTargetChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel)) {
						botNotice($self,$sNick,"Channel $sTargetChannel is undefined");
						return undef;
					}
					shift @tArgs;
				}
				unless (defined($tArgs[0]) && ($tArgs[0] =~ /^.+!.+\@.+$/)) {
					botNotice($self,$sNick,"Syntax ignore [#channel] <hostmask>");
					botNotice($self,$sNick,"hostmask example : nick*!*ident\@domain*.tld");
				}
				
				if (defined($sTargetChannel) && ($sTargetChannel ne "")) {
					# Ignores ($sTargetChannel)
					my $sQuery = "SELECT * FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ? AND IGNORES.hostmask LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTargetChannel,$tArgs[0])) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $hostmask = $ref->{hostmask};
							botNotice($self,$sNick,"hostmask $hostmask is already ignored on $sTargetChannel");
							$sth->finish;
							return undef;
						}
						else {
							$sQuery = "INSERT INTO IGNORES (id_channel,hostmask) VALUES (?,?)";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($id_channel,$tArgs[0])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $id_ignores = $sth->{ mysql_insertid };
								botNotice($self,$sNick,"Added ignore ID $id_ignores " . $tArgs[0] . " on $sTargetChannel");
							}
						}
					}
				}
				else {
					# Ignores (allchans/private)
					my $sQuery = "SELECT * FROM IGNORES WHERE id_channel=0 AND IGNORES.hostmask LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($tArgs[0])) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $hostmask = $ref->{hostmask};
							botNotice($self,$sNick,"hostmask $hostmask is already ignored on (allchans/private)");
							$sth->finish;
							return undef;
						}
						else {
							$sQuery = "INSERT INTO IGNORES (hostmask) VALUES (?)";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[0])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $id_ignores = $sth->{ mysql_insertid };
								botNotice($self,$sNick,"Added ignore ID $id_ignores " . $tArgs[0] . " on (allchans/private)");
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " ignore command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " ignore command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub delIgnore(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sTargetChannel;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sTargetChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel)) {
						botNotice($self,$sNick,"Channel $sTargetChannel is undefined");
						return undef;
					}
					shift @tArgs;
				}
				unless (defined($tArgs[0]) && ($tArgs[0] =~ /^.+!.+\@.+$/)) {
					botNotice($self,$sNick,"Syntax unignore [#channel] <hostmask>");
					botNotice($self,$sNick,"hostmask example : nick*!*ident\@domain*.tld");
				}
				
				if (defined($sTargetChannel) && ($sTargetChannel ne "")) {
					# Ignores ($sTargetChannel)
					my $sQuery = "SELECT * FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ? AND IGNORES.hostmask LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTargetChannel,$tArgs[0])) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						unless (my $ref = $sth->fetchrow_hashref()) {
							my $hostmask = $ref->{hostmask};
							botNotice($self,$sNick,"hostmask $hostmask is not ignored on $sTargetChannel");
							$sth->finish;
							return undef;
						}
						else {
							$sQuery = "DELETE FROM IGNORES WHERE id_channel=? AND hostmask LIKE ?";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($id_channel,$tArgs[0])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								#my $id_ignores = $sth->{ mysql_insertid };
								botNotice($self,$sNick,"Deleted ignore " . $tArgs[0] . " on $sTargetChannel");
							}
						}
					}
				}
				else {
					# Ignores (allchans/private)
					my $sQuery = "SELECT * FROM IGNORES WHERE id_channel=0 AND IGNORES.hostmask LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($tArgs[0])) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						unless (my $ref = $sth->fetchrow_hashref()) {
							my $hostmask = $ref->{hostmask};
							botNotice($self,$sNick,"hostmask $hostmask is not ignored on (allchans/private)");
							$sth->finish;
							return undef;
						}
						else {
							$sQuery = "DELETE FROM IGNORES WHERE id_channel=0 AND hostmask LIKE ?";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[0])) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								#my $id_ignores = $sth->{ mysql_insertid };
								botNotice($self,$sNick,"Deleted ignore " . $tArgs[0] . " on (allchans/private)");
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " unignore command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " unignore command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

# Display the current song on the radio
sub displayRadioCurrentSong(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $conf = $self->{conf};

	my $RADIO_HOSTNAME = $conf->get('radio.RADIO_HOSTNAME');
	my $RADIO_PORT = $conf->get('radio.RADIO_PORT');
	my $RADIO_SOURCE = $conf->get('radio.RADIO_SOURCE');
	my $RADIO_URL = $conf->get('radio.RADIO_URL');
	my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');

	unless (defined($sChannel) && ($sChannel ne "")) {
		my $id_channel;
		if (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^#/)) {
			$sChannel = $tArgs[0];
			$id_channel = getIdChannel($self,$sChannel);
			unless (defined($id_channel)) {
				botNotice($self,$sNick,"Channel $sChannel is not registered");
				return undef;
			}
			shift @tArgs;
		} else {
			botNotice($self,$sNick,"Syntax: song <#channnel>");
			return undef;
		}
	}

	my $sRadioCurrentSongTitle = getRadioCurrentSong($self);

	my $sHarbor = getRadioHarbor($self);
	my $bRadioLive = 0;
	if (defined($sHarbor) && ($sHarbor ne "")) {
		$self->{logger}->log(3,$sHarbor);
		$bRadioLive = isRadioLive($self,$sHarbor);
	}

	if (defined($sRadioCurrentSongTitle) && ($sRadioCurrentSongTitle ne "")) {
		my $sMsgSong = "";

		$sMsgSong .= String::IRC->new('[ ')->white('black');
		if ($RADIO_PORT == 443) {
			$sMsgSong .= String::IRC->new("https://$RADIO_HOSTNAME/$RADIO_URL")->orange('black');
		} else {
			$sMsgSong .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
		}
		$sMsgSong .= String::IRC->new(' ] ')->white('black');
		$sMsgSong .= String::IRC->new(' - ')->white('black');
		$sMsgSong .= String::IRC->new(' [ ')->orange('black');
		if ($bRadioLive) {
			$sMsgSong .= String::IRC->new('Live - ')->white('black');
		}
		$sMsgSong .= String::IRC->new($sRadioCurrentSongTitle)->white('black');
		$sMsgSong .= String::IRC->new(' ]')->orange('black');

		unless ($bRadioLive) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
				my $sRemainingTime = getRadioRemainingTime($self);
				$self->{logger}->log(3,"displayRadioCurrentSong() sRemainingTime = $sRemainingTime");
				my $siSecondsRemaining = int($sRemainingTime);
				my $iMinutesRemaining = int($siSecondsRemaining / 60);
				my $iSecondsRemaining = int($siSecondsRemaining - ($iMinutesRemaining * 60));
				$sMsgSong .= String::IRC->new(' - ')->white('black');
				$sMsgSong .= String::IRC->new(' [ ')->orange('black');
				my $sTimeRemaining = "";
				if ($iMinutesRemaining > 0) {
					$sTimeRemaining .= $iMinutesRemaining . " mn";
					$sTimeRemaining .= "s" if $iMinutesRemaining > 1;
					$sTimeRemaining .= " and ";
				}
				$sTimeRemaining .= $iSecondsRemaining . " sec";
				$sTimeRemaining .= "s" if $iSecondsRemaining > 1;
				$sTimeRemaining .= " remaining";
				$sMsgSong .= String::IRC->new($sTimeRemaining)->white('black');
				$sMsgSong .= String::IRC->new(' ]')->orange('black');
			}
		}
		botPrivmsg($self,$sChannel,"$sMsgSong");
	} else {
		botNotice($self,$sNick,"Radio is currently unavailable");
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

# set the radio metadata
sub setRadioMetadata(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);

	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {

				my $conf = $self->{conf};
				my $RADIO_HOSTNAME  = $conf->get('radio.RADIO_HOSTNAME');
				my $RADIO_PORT      = $conf->get('radio.RADIO_PORT');
				my $RADIO_SOURCE    = $conf->get('radio.RADIO_SOURCE');
				my $RADIO_URL       = $conf->get('radio.RADIO_URL');
				my $RADIO_ADMINPASS = $conf->get('radio.RADIO_ADMINPASS');

				my $id_channel;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$id_channel = getIdChannel($self,$tArgs[0]);
					unless (defined($id_channel)) {
						botNotice($self,$sNick,"Channel " . $tArgs[0] . " is undefined");
						return undef;
					}
					else {
						$sChannel = $tArgs[0];
					}
					shift @tArgs;
				}

				my $sNewMetadata = join(" ",@tArgs);
				unless (defined($sNewMetadata) && ($sNewMetadata ne "")) {
					if (defined($sChannel) && ($sChannel ne "")) {
						displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
					}
					return undef;
				}

				if (defined($RADIO_ADMINPASS) && ($RADIO_ADMINPASS ne "")) {
					unless (open ICECAST_UPDATE_METADATA, "curl --connect-timeout 3 -f -s -u admin:$RADIO_ADMINPASS \"http://$RADIO_HOSTNAME:$RADIO_PORT/admin/metadata?mount=/$RADIO_URL&mode=updinfo&song=" . url_encode_utf8($sNewMetadata) . "\" |") {
						botNotice($self,$sNick,"Unable to update metadata (curl failed)");
					}
					my $line;
					if (defined($line=<ICECAST_UPDATE_METADATA>)) {
						close ICECAST_UPDATE_METADATA;
						chomp($line);
						if (defined($sChannel) && ($sChannel ne "")) {
							sleep 3;
							displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
						}
						else {
							botNotice($self,$sNick,"Metadata updated to : " . join(" ",@tArgs));
						}
					}
					else {
						botNotice($self,$sNick,"Unable to update metadata");
					}
				}
				else {
					$self->{logger}->log(0,"setRadioMetadata() radio.RADIO_ADMINPASS not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " metadata command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " metadata command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Skip to the next song in the radio stream
sub radioNext(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);

	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {

				my $conf = $self->{conf};
				my $RADIO_HOSTNAME         = $conf->get('radio.RADIO_HOSTNAME');
				my $RADIO_PORT             = $conf->get('radio.RADIO_PORT');
				my $RADIO_SOURCE           = $conf->get('radio.RADIO_SOURCE');
				my $RADIO_URL              = $conf->get('radio.RADIO_URL');
				my $RADIO_ADMINPASS        = $conf->get('radio.RADIO_ADMINPASS');
				my $LIQUIDSOAP_TELNET_HOST = $conf->get('radio.LIQUIDSOAP_TELNET_HOST');
				my $LIQUIDSOAP_TELNET_PORT = $conf->get('radio.LIQUIDSOAP_TELNET_PORT');

				my $LIQUIDSOAP_MOUNPOINT = $RADIO_URL;
				$LIQUIDSOAP_MOUNPOINT =~ s/\./(dot)/;

				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					unless (open LIQUIDSOAP_NEXT, "echo -ne \"$LIQUIDSOAP_MOUNPOINT.skip\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
						botNotice($self,$sNick,"Unable to connect to LIQUIDSOAP telnet port");
					}
					my $line;
					my $i = 0;
					while (defined($line=<LIQUIDSOAP_NEXT>)) {
						chomp($line);
						$i++;
					}
					if ($i != 0) {
						my $sMsgSong = "";
						$sMsgSong .= String::IRC->new('[ ')->grey('black');
						$sMsgSong .= String::IRC->new("http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_URL")->orange('black');
						$sMsgSong .= String::IRC->new(' ] ')->grey('black');
						$sMsgSong .= String::IRC->new(' - ')->white('black');
						$sMsgSong .= String::IRC->new(' [ ')->orange('black');
						$sMsgSong .= String::IRC->new("$sNick skipped to next track")->grey('black');
						$sMsgSong .= String::IRC->new(' ]')->orange('black');
						botPrivmsg($self,$sChannel,"$sMsgSong");
					}
				}
				else {
					$self->{logger}->log(0,"radioNext() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " nextsong command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " nextsong command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

# Display the word statistics for a given word in the last 24 hours
sub wordStat(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $MAIN_PROG_CMD_CHAR = $self->{conf}->get('main.MAIN_PROG_CMD_CHAR');
	my $sWord;

	unless (defined($tArgs[0]) && ($tArgs[0])) {
		botNotice($self,$sNick,"Syntax : wordstat <word>");
		return undef;
	} else {
		$sWord = $tArgs[0];
	}
	
	my $sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND name=? AND ts > date_sub('" . time2str("%Y-%m-%d %H:%M:%S",time) . "', INTERVAL 1 DAY)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : $sQuery");
	} else {
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $publictext = $ref->{'publictext'};
			if (( $publictext =~ /\s$sWord$/i ) || 
			    ( $publictext =~ /\s$sWord\s/i ) || 
			    ( $publictext =~ /^$sWord\s/i ) || 
			    ( $publictext =~ /^$sWord$/i )) {
				$self->{logger}->log(3,"publictext : $publictext") if $i < 10;
				$i++;
			}
		}
		botPrivmsg($self,$sChannel,"wordstat for $tArgs[0] : $i");
		logBot($self,$message,$sChannel,"wordstat",@tArgs);
	}
	$sth->finish;
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

sub lastCom(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $maxCom = 8;
				my $nbCom = 5;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /[0-9]+/) && ($tArgs[0] ne "0")) {
					if ($tArgs[0] > $maxCom) {
						$nbCom = $maxCom;
						botNotice($self,$sNick,"lastCom : max lines $maxCom");
					}
					else {
						$nbCom = $tArgs[0];
					}
				}
				my $sQuery = "SELECT * FROM ACTIONS_LOG ORDER by ts DESC LIMIT $nbCom";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $i = 0;
					while (my $ref = $sth->fetchrow_hashref()) {
						my $ts = $ref->{'ts'};
						my $id_user = $ref->{'id_user'};
						my $sUserhandle = getUserhandle($self,$id_user);
						$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");
						my $id_channel = $ref->{'id_channel'};
						my $chan_obj = $self->getChannelById($id_channel);
						my $sChannelCom = defined($chan_obj) ? " " . $chan_obj->{name} : "";
						my $hostmask = $ref->{'hostmask'};
						my $action = $ref->{'action'};
						my $args = $ref->{'args'};
						$args = (defined($args) && ($args ne "") ? $args : "");
						botNotice($self,$sNick,"$ts ($sUserhandle)$sChannelCom $hostmask $action $args");
						$i++;
					}
					logBot($self,$message,$sChannel,"lastcom",@tArgs);
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " lastcom command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " lastcom command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub mbQuotes(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"Quotes syntax :");
		botNotice($self,$sNick,"q [add or a] text1 | text2 | ... | textn");
		botNotice($self,$sNick,"q [del or q] id");
		botNotice($self,$sNick,"q [view or v] id");
		botNotice($self,$sNick,"q [search or s] text");
		botNotice($self,$sNick,"q [random or r]");
		botNotice($self,$sNick,"q stats");
		return undef;
	}
	my @oArgs = @tArgs;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sCommand = $tArgs[0];
				shift @tArgs;
				switch($sCommand) {
					case /^add$|^a$/i		{ mbQuoteAdd($self,$message,$iMatchingUserId,$sMatchingUserHandle,$sNick,$sChannel,@tArgs); }
					case /^del$|^d$/i		{ mbQuoteDel($self,$message,$sMatchingUserHandle,$sNick,$sChannel,@tArgs); }
					case /^view$|^v$/i	{ mbQuoteView($self,$message,$sNick,$sChannel,@tArgs); }
					case /^search$/i	{ mbQuoteSearch($self,$message,$sNick,$sChannel,@tArgs); }
					case "s" { mbQuoteSearch($self,$message,$sNick,$sChannel,@tArgs); }
					case "S" { mbQuoteSearch($self,$message,$sNick,$sChannel,@tArgs); }
					case /^random$|^r$/i { mbQuoteRand($self,$message,$sNick,$sChannel,@tArgs); }
					case /^stats$/i { mbQuoteStats($self,$message,$sNick,$sChannel,@tArgs); }
					else {
						botNotice($self,$sNick,"Quotes syntax :");
						botNotice($self,$sNick,"q [add or a] text1 | text2 | ... | textn");
						botNotice($self,$sNick,"q [del or q] id");
						botNotice($self,$sNick,"q [view or v] id");
						botNotice($self,$sNick,"q [search or s] text");
						botNotice($self,$sNick,"q [random or r]");
						botNotice($self,$sNick,"q stats");
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " q command attempt (command level [User] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
	}
	elsif (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^view$|^v$/i)) {
		shift @tArgs;
		mbQuoteView($self,$message,$sNick,$sChannel,@tArgs);
	}
	elsif (defined($tArgs[0]) && ($tArgs[0] ne "") && (($tArgs[0] =~ /^search$/i) || ($tArgs[0] eq "s") || ($tArgs[0] eq "S"))) {
		shift @tArgs;
		mbQuoteSearch($self,$message,$sNick,$sChannel,@tArgs);
	}
	elsif (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^random$|^r$/i)) {
		shift @tArgs;
		mbQuoteRand($self,$message,$sNick,$sChannel,@tArgs);
	}
	elsif (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^stats$/i)) {
		shift @tArgs;
		mbQuoteStats($self,$message,$sNick,$sChannel,@tArgs);
	}
	elsif (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^add$|^a$/i)) {
		shift @tArgs;
		mbQuoteAdd($self,$message,undef,undef,$sNick,$sChannel,@tArgs);
	}
	else {
		my $sNoticeMsg = $message->prefix . " q command attempt (user $sMatchingUserHandle is not logged in)";
		noticeConsoleChan($self,$sNoticeMsg);
		botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		return undef;
	}
}

sub mbQuoteAdd(@) {
	my ($self,$message,$iMatchingUserId,$sMatchingUserHandle,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"q [add or a] text1 | text2 | ... | textn");
	}
	else {
		my $sQuoteText = join(" ",@tArgs);
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name=? AND quotetext like ?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$sQuoteText)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $id_quotes = $ref->{'id_quotes'};
				botPrivmsg($self,$sChannel,"Quote (id : $id_quotes) already exists");
				logBot($self,$message,$sChannel,"q",@tArgs);
			}
			else {
				my $id_channel = getIdChannel($self,$sChannel);
				unless (defined($id_channel) && ($id_channel ne "")) {
					botNotice($self,$sNick,"Channel $sChannel is not registered to me");
				}
				else {
					$sQuery = "INSERT INTO QUOTES (id_channel,id_user,quotetext) VALUES (?,?,?)";
					$sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($id_channel,(defined($iMatchingUserId) ? $iMatchingUserId : 0),$sQuoteText)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $id_inserted = String::IRC->new($sth->{ mysql_insertid })->bold;
						botPrivmsg($self,$sChannel,(defined($sMatchingUserHandle) ? "($sMatchingUserHandle) " : "") . "done. (id: $id_inserted)");
						logBot($self,$message,$sChannel,"q add",@tArgs);
					}
				}
			}
		}
		$sth->finish;
	}
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

sub mbModUser(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my @oArgs = @tArgs;
				unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					botNotice($self,$sNick,"moduser <user> level <Owner|Master|Administrator|User>");
					botNotice($self,$sNick,"moduser <user> autologin <on|off>");
				}
				else {
					my $sUser = $tArgs[0];
					shift @tArgs;
					my $id_user = getIdUser($self,$sUser);
					unless (defined($id_user) && ($id_user ne "")) {
						botNotice($self,$sNick,"User: $sUser does not exist");
					}
					else {
						unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
							botNotice($self,$sNick,"moduser <user> level <Owner|Master|Administrator|User>");
							botNotice($self,$sNick,"moduser <user> autologin <on|off>");
						}
						else {
							my $sCommand = $tArgs[0];
							shift @tArgs;
							switch($sCommand) {
								case /^level$/i {
									unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^owner$|^master$|^administrator$|^user$/i)) {
										botNotice($self,$sNick,"moduser <user> level <Owner|Master|Administrator|User>");
									}
									else {
										my $target_user_level = getLevel($self,$tArgs[0]);
										my $current_user_level = getLevelUser($self,$sUser);
										if (( $target_user_level == 0) && ($iMatchingUserLevel == 0)) {
											unless (defined($tArgs[1]) && ($tArgs[1] ne "") && ($tArgs[1] =~ /^force$/i)) {
												botNotice($self,$sNick,"Do you really want to do that ?");
												botNotice($self,$sNick,"If you know what you are doing use : moduser $sUser level Owner force");
											}
											else {
												botNotice($self,$sNick,"User $sUser is know a global Owner of the bot !");
												logBot($self,$message,$sChannel,"moduser",@oArgs);
											}
										}
										elsif (($iMatchingUserLevel < $current_user_level) && ($iMatchingUserLevel < $target_user_level)) {
											if ( $target_user_level == $current_user_level ) {
												botNotice($self,$sNick,"User $sUser is already a global " . $tArgs[0] . " of the bot");
											}
											else {
												if ( setUserLevel($self,$sUser,getIdUserLevel($self,$tArgs[0])) ) {
													botNotice($self,$sNick,"User $sUser is now a global " . $tArgs[0] . " of the bot");
													logBot($self,$message,$sChannel,"moduser",@oArgs);
												}
												else {
													botNotice($self,$sNick,"Could not set $sUser as a global " . $tArgs[0] . " of the bot, weird ^^");
												}
											}
										}
										else {
											if ( $target_user_level == $current_user_level) {
												botNotice($self,$sNick,"As a global $iMatchingUserLevelDesc, you can't set $sUser as a global " . $tArgs[0] . " of the bot, it's funny cause $sUser is already a global " . getUserLevelDesc($self,$current_user_level) . " of the bot ;)");
											}
											else {
												botNotice($self,$sNick,"As a global $iMatchingUserLevelDesc, you can't set $sUser (" . getUserLevelDesc($self,$current_user_level) . ") as a global " . $tArgs[0] . " of the bot");
											}
										}
										
									}
								}
								case /^autologin$/i {
									unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /^on$|^off$/i)) {
										botNotice($self,$sNick,"moduser <user> autologin <on|off>");
									}
									else {
										switch($tArgs[0]) {
											case /^on$/i {
												my $sQuery = "SELECT * FROM USER WHERE nickname like ? AND username='#AUTOLOGIN#'";
												my $sth = $self->{dbh}->prepare($sQuery);
												unless ($sth->execute($sUser)) {
													$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													if (my $ref = $sth->fetchrow_hashref()) {
														botNotice($self,$sNick,"autologin is already ON for user $sUser");
													}
													else {
														$sQuery = "UPDATE USER SET username='#AUTOLOGIN#' WHERE nickname like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($sUser)) {
															$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															botNotice($self,$sNick,"Set autologin ON for user $sUser");
															logBot($self,$message,$sChannel,"moduser",@oArgs);
														}
													}
												}
												$sth->finish;
											}
											case /^off$/i {
												my $sQuery = "SELECT * FROM USER WHERE nickname like ? AND username='#AUTOLOGIN#'";
												my $sth = $self->{dbh}->prepare($sQuery);
												unless ($sth->execute($sUser)) {
													$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													if (my $ref = $sth->fetchrow_hashref()) {
														$sQuery = "UPDATE USER SET username=NULL WHERE nickname like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($sUser)) {
															$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															botNotice($self,$sNick,"Set autologin OFF for user $sUser");
															logBot($self,$message,$sChannel,"moduser",@oArgs);
														}
														
													}
													else {
														botNotice($self,$sNick,"autologin is already OFF for user $sUser");
													}
												}
												$sth->finish;
											}
										}
									}
								}
								case /^fortniteid$/i {
									unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
										botNotice($self,$sNick,"moduser <user> fortniteid <id>");
									}
									else {
										my $sQuery = "SELECT * FROM USER WHERE nickname like ? AND fortniteid=?";
										my $sth = $self->{dbh}->prepare($sQuery);
										unless ($sth->execute($sUser,$tArgs[0])) {
											$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
										}
										else {
											my $ref;
											if ($ref = $sth->fetchrow_hashref()) {
												my $fortniteid = $ref->{'fortniteid'};
												botNotice($self,$sNick,"fortniteid is already $fortniteid for user $sUser");
											}
											else {
												$sQuery = "UPDATE USER SET fortniteid=? WHERE nickname like ?";
												$sth = $self->{dbh}->prepare($sQuery);
												unless ($sth->execute($tArgs[0],$sUser)) {
													$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													botNotice($self,$sNick,"Set fortniteid $tArgs[0] for user $sUser");
													logBot($self,$message,$sChannel,"fortniteid",@oArgs);
												}
											}
										}
										$sth->finish;
									}
								}
								else {
									botNotice($self,$sNick,"Unknown moduser command : $sCommand");
								}
							}
						}
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " moduser command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " moduser command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub setChannelAntiFlood(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $id_channel = getIdChannel($self,$sChannel);
	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $duration = $ref->{'duration'};
			my $timetowait = $ref->{'timetowait'};
			$self->{logger}->log(3,"setChannelAntiFlood() AntiFlood record exists (id_channel $id_channel) nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds");
			botNotice($self,$sNick,"Chanset parameters already exist and will be used for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
		}
		else {
			$sQuery = "INSERT INTO CHANNEL_FLOOD (id_channel) VALUES (?)";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($id_channel)) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				my $id_channel_flood = $sth->{ mysql_insertid };
				$self->{logger}->log(3,"setChannelAntiFlood() AntiFlood record created, id_channel_flood : $id_channel_flood");
				$sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_channel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nbmsg_max = $ref->{'nbmsg_max'};
						my $duration = $ref->{'duration'};
						my $timetowait = $ref->{'timetowait'};
						botNotice($self,$sNick,"Chanset parameters for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
					}
					else {
						botNotice($self,$sNick,"Something funky happened, could not find record id_channel_flood : $id_channel_flood in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
					}
				}
			}
		}
	}
	$sth->finish;
}

sub checkAntiFlood(@) {
	my ($self,$sChannel) = @_;
	my $id_channel = getIdChannel($self,$sChannel);
	my $sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $nbmsg = $ref->{'nbmsg'};
			my $duration = $ref->{'duration'};
			my $first = $ref->{'first'};
			my $latest = $ref->{'latest'};
			my $timetowait = $ref->{'timetowait'};
			my $notification = $ref->{'notification'};
			my $currentTs = time;
			my $deltaDb = ($latest - $first);
			my $delta = ($currentTs - $first);
			
			if ($nbmsg == 0) {
				$nbmsg++;
				$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,first=?,latest=? WHERE id_channel=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($nbmsg,$currentTs,$currentTs,$id_channel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
					$self->{logger}->log(4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
					return 0;
				}
			}
			else {
				if ( $deltaDb <= $duration ) {
					if ($nbmsg < $nbmsg_max) {
						$nbmsg++;
						$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,latest=? WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($nbmsg,$currentTs,$id_channel)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
							$self->{logger}->log(4,"checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max set latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds");
							return 0;
						}
					}
					else {
						my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
						my $endTs = $latest + $timetowait;
						unless ( $currentTs <= $endTs ) {
							$nbmsg = 1;
							$self->{logger}->log(0,"checkAntiFlood() End of antiflood for channel $sChannel");
							$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,first=?,latest=?,notification=? WHERE id_channel=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($nbmsg,$currentTs,$currentTs,0,$id_channel)) {
								$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
								$self->{logger}->log(4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
								return 0;
							}
						}
						else {
							unless ( $notification ) {
								#$self->{irc}->do_PRIVMSG( target => $sChannel, text => "Anti flood active for $timetowait seconds on channel $sChannel, no more than $nbmsg_max requests in $duration seconds." );
								$sQuery = "UPDATE CHANNEL_FLOOD SET notification=? WHERE id_channel=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute(1,$id_channel)) {
									$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									$self->{logger}->log(4,"checkAntiFlood() Antiflood notification set to DB for $sChannel");
									noticeConsoleChan($self,"Anti flood activated on channel $sChannel $nbmsg messages in less than $duration seconds, waiting $timetowait seconds to desactivate");
								}
							}
							$self->{logger}->log(4,"checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds endTs = $endTs " . ($endTs - $currentTs) . " seconds left");
							$self->{logger}->log(0,"checkAntiFlood() Antiflood is active for channel $sChannel wait " . ($endTs - $currentTs) . " seconds");
							return 1;
						}
					}
				}
				else {
					$nbmsg = 1;
					$self->{logger}->log(0,"checkAntiFlood() End of antiflood for channel $sChannel");
					$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,first=?,latest=?,notification=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($nbmsg,$currentTs,$currentTs,0,$id_channel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
						$self->{logger}->log(4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
						return 0;
					}
				}
			}
		}
		else {
			$self->{logger}->log(0,"Something funky happened, could not find record in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
		}
	}
	return 0;
}

sub setChannelAntiFloodParams(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sTargetChannel;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel)) {
						botNotice($self,$sNick,"Channel $sTargetChannel is not registered to me");
						return undef;
					}
					shift @tArgs;
				}
				unless (defined($sChannel) && ($sChannel ne "")) {
					botNotice($self,$sNick,"Undefined channel");
					botNotice($self,$sNick,"Syntax antifloodset [#channel] <max_msg> <period in sec> <timetowait in sec>");
					return undef;
				}
				if ($#tArgs == -1) {
					$self->{logger}->log(3,"Check antifloodset on $sChannel");
					my $sQuery = "SELECT * FROM CHANNEL,CHANNEL_FLOOD WHERE CHANNEL.id_channel=CHANNEL_FLOOD.id_channel and CHANNEL.name like ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						return undef;
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $nbmsg_max =  $ref->{'nbmsg_max'};
							my $duration =  $ref->{'duration'};
							my $timetowait =  $ref->{'timetowait'};
							botNotice($self,$sNick,"antifloodset for $sChannel : $nbmsg_max message". ($nbmsg_max > 1 ? "s" : "") . " max in $duration second". ($duration > 1 ? "s" : "") . ", $timetowait second". ($duration > 1 ? "s" : "") . " to wait if breached");
						}
						else {
							botNotice($self,$sNick,"no antifloodset settings for $sChannel");
						}
					}
					return 0;
				}
				unless (defined($tArgs[0]) && ($tArgs[0] =~ /^[0-9]+$/)) {
					botNotice($self,$sNick,"Syntax antifloodset [#channel] <max_msg> <period in sec> <timetowait in sec>");
					return undef;
				}
				unless (defined($tArgs[1]) && ($tArgs[1] =~ /^[0-9]+$/)) {
					botNotice($self,$sNick,"Syntax antifloodset [#channel] <max_msg> <period in sec> <timetowait in sec>");
					return undef;
				}
				unless (defined($tArgs[2]) && ($tArgs[2] =~ /^[0-9]+$/)) {
					botNotice($self,$sNick,"Syntax antifloodset [#channel] <max_msg> <period in sec> <timetowait in sec>");
					return undef;
				}
				my $id_chanset_list = getIdChansetList($self,"AntiFlood");
				my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
				unless (defined($id_channel_set)) {
					botNotice($self,$sNick,"To change antiflood parameters, first issue a chanset $sChannel +AntiFlood");
					return undef;
				}
				else {
					my $sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg_max=?,duration=?,timetowait=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($tArgs[0],$tArgs[1],$tArgs[2],$id_channel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						$sth->finish;
						botNotice($self,$sNick,"Antiflood parameters set for $sChannel, $tArgs[0] messages max in $tArgs[1] seconds, wait for $tArgs[2] seconds");
						return 0;
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " antifloodset command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " antifloodset command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub getChannelOwner(@) {
	my ($self,$sChannel) = @_;
	my $id_channel = getIdChannel($self,$sChannel);
	my $sQuery = "SELECT nickname FROM USER,USER_CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND id_channel=? AND USER_CHANNEL.level=500";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		return undef;
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			return $ref->{'nickname'};
		}
		else {
			return undef;
		}
	}
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

sub mbRehash(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				readConfigFile($self);
				unless (defined($sChannel) && ($sChannel ne "")) {
					botNotice($self,$sNick,"Successfully rehashed");
				}
				else {
					botPrivmsg($self,$sChannel,"($sNick) Successfully rehashed");
				}
				logBot($self,$message,$sChannel,"rehash",@tArgs);
			}
			else {
				my $sNoticeMsg = $message->prefix . " rehash command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " rehash command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
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

sub mbExec(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				my $sText = join (" ",@tArgs);
				unless (defined($sText) && ($sText ne "")) {
					botNotice($self,$sNick,"Syntax : exec <command> [");
					return undef;
				}
				if ($sText =~ /rm -rf/i) {
					botNotice($self,$sNick,"Don't be that evil !");
					return undef;
				}
				unless (open CMD, "$sText | tail -n 3 |") {
					$self->{logger}->log(3,"mbExec could not issue $sText command");
				}
				else {
					my $line;
					my $i = 0;
					while (defined($line=<CMD>)) {
						chomp($line);
						botPrivmsg($self,$sChannel,"$i: $line");
						if ($i > 3) {
							close CMD;
							return undef;
						}
						$i++;
					}
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " exec command attempt (command level [Owner] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " exec command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}	
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

sub set_hailo_channel_ratio(@) {
	my ($self,$sChannel,$ratio) = @_;
	my $sQuery = "SELECT * FROM HAILO_CHANNEL,CHANNEL WHERE HAILO_CHANNEL.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_channel = $ref->{'id_channel'};
			$sQuery = "UPDATE HAILO_CHANNEL SET ratio=? WHERE id_channel=?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($ratio,$id_channel)) {
				$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$sth->finish;
				$self->{logger}->log(3,"set_hailo_channel_ratio updated hailo chatter ratio to $ratio for $sChannel");
				return 0;
			}
		}
		else {
			my $id_channel = getIdChannel($self,$sChannel);
			unless (defined($id_channel)) {
				$sth->finish;
				return undef;
			}
			else {
				$sQuery = "INSERT INTO HAILO_CHANNEL (id_channel,ratio) VALUES (?,?)";
				$sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_channel,$ratio)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					$sth->finish;
					$self->{logger}->log(3,"set_hailo_channel_ratio set hailo chatter ratio to $ratio for $sChannel");
					return 0;
				}
			}
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

# Set TMDB language for a channel
sub setTMDBLangChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sTargetChannel;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel)) {
						botNotice($self,$sNick,"Channel $sTargetChannel is not registered to me");
						return undef;
					}
					shift @tArgs;
				}
				unless (defined($sChannel) && ($sChannel ne "")) {
					botNotice($self,$sNick,"Undefined channel");
					botNotice($self,$sNick,"Syntax tmdblangset [#channel] <lang>");
					return undef;
				}
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sLang = $tArgs[0];
					$self->{logger}->log(3,"setTMDBLangChannel() " . $sChannel . " lang set to " . $sLang);
					my $sQuery = "UPDATE CHANNEL SET tmdb_lang=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sLang,$id_channel)) {
						$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						return undef;
					}
					else {
						botPrivmsg($self,$sChannel,"TMDB language set to " . $sLang);
						$sth->finish;
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax tmdblangset [#channel] <lang>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " tmdblangset command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " tmdblangset command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
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