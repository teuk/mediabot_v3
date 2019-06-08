#!/usr/bin/perl

# +---------------------------------------------------------------------------+
# !          MEDIABOT INSTALLER     (Net::Async::IRC bot)                     !
# +---------------------------------------------------------------------------+

# +---------------------------------------------------------------------------+
# !          MODULES                                                          !
# +---------------------------------------------------------------------------+

use strict;
use warnings;
use diagnostics;
use Getopt::Long;
use Date::Format;
use DBI;

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+

sub log_messageln(@);
sub log_message(@);
sub init_log(@);
sub dbConnect(@);
sub addIrcServer(@);
sub addConsoleChannelCheck();
sub addConsoleChannel();

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+
my $CONFIG_FILE;
my $MAIN_PROG_DDBNAME;
my $MAIN_PROG_DBUSER;
my $MAIN_PROG_DBPASS;
my $MAIN_PROG_DBHOST;
my $MAIN_PROG_DBPORT;

init_log("configure.log");

# Check command line parameters
my $result = GetOptions (
        "conf=s" => \$CONFIG_FILE,
);

unless (defined($CONFIG_FILE)) {
	log_messageln("You must specify a config file");
	exit 1;
}

# Get database connection settings
log_messageln("Get database connection settings");
unless (open CONF,"$CONFIG_FILE") {
	log_messageln("Could not open $CONFIG_FILE");
	exit 2;
}
my $line;
while(defined($line=<CONF>)) {
	chomp($line);
	if ( $line =~ /^MAIN_PROG_DDBNAME=(.*)$/ ) {
		$MAIN_PROG_DDBNAME = $1;
	}
	if ( $line =~ /^MAIN_PROG_DBUSER=(.*)$/ ) {
		$MAIN_PROG_DBUSER = $1;
	}
	if ( $line =~ /^MAIN_PROG_DBPASS=(.*)$/ ) {
		$MAIN_PROG_DBPASS = $1;
	}
	if ( $line =~ /^MAIN_PROG_DBHOST=(.*)$/ ) {
		$MAIN_PROG_DBHOST = $1;
	}
	if ( $line =~ /^MAIN_PROG_DBPORT=(.*)$/ ) {
		$MAIN_PROG_DBPORT = $1;
	}
}
close CONF;

unless (defined($MAIN_PROG_DDBNAME)) {
	log_messageln("MAIN_PROG_DDBNAME was not found in $CONFIG_FILE");
	exit 3;
}

unless (defined($MAIN_PROG_DBUSER)) {
	log_messageln("MAIN_PROG_DBUSER was not found in $CONFIG_FILE");
	exit 4;
}

unless (defined($MAIN_PROG_DBPASS)) {
	log_messageln("MAIN_PROG_DBPASS was not found in $CONFIG_FILE");
	exit 5;
}

unless (defined($MAIN_PROG_DBHOST)) {
	log_messageln("MAIN_PROG_DBHOST was not found in $CONFIG_FILE");
	exit 6;
}

unless (defined($MAIN_PROG_DBPORT)) {
	log_messageln("MAIN_PROG_DBPORT was not found in $CONFIG_FILE");
	exit 7;
}

# Establish a MySQL connection
log_messageln("Connect to database $MAIN_PROG_DDBNAME");
my $dbh = dbConnect($MAIN_PROG_DDBNAME,$MAIN_PROG_DBHOST,$MAIN_PROG_DBPORT,$MAIN_PROG_DBUSER,$MAIN_PROG_DBPASS);

# Configure [connection] in $CONFIG_FILE
unless (open CONF,">>$CONFIG_FILE") {
	log_messageln("Could not open $CONFIG_FILE");
	exit 3;
}
log_messageln("Configure [connection] in $CONFIG_FILE");
print CONF "[connection]\n";
log_message("Enter network name : ");
$line=<STDIN>;
chomp($line);
while ( $line eq "" ) {
	log_message("Enter network name : ");
	$line=<STDIN>;
	chomp($line);
}
my $NETWORK_NAME=$line;

# Create network if not exists and add irc server
my $id_network;

my $sQuery = "SELECT * FROM NETWORK WHERE network_name LIKE ?";
my $sth = $dbh->prepare($sQuery);
unless ($sth->execute($line) ) {
	log_messageln(0,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	exit 9;
}
else {
	if (my $ref = $sth->fetchrow_hashref()) {
		$id_network = $ref->{'id_network'};
		my $sDbNetworkName = $ref->{'network_name'};
		log_messageln("Network '$sDbNetworkName' already exists in database table NETWORK, id : $id_network");
		print CONF "CONN_SERVER_NETWORK=$sDbNetworkName\n";
		$sQuery = "SELECT * FROM SERVERS WHERE id_network=?";
		$sth = $dbh->prepare($sQuery);
		unless ($sth->execute($id_network) ) {
			log_messageln(0,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			exit 10;
		}
		else {
			my $server_hostname;
			while (my $ref = $sth->fetchrow_hashref()) {
				$server_hostname = $ref->{'server_hostname'};
				log_messageln("Available server : $server_hostname");
			}
			unless (defined($server_hostname)) {
				log_messageln("No IRC Server defined for network $sDbNetworkName");
				# Add irc server
				log_message("Enter irc server hostname : ");
				$line=<STDIN>;
				chomp($line);
				while ( $line eq "" ) {
					log_message("Enter irc server hostname : ");
					$line=<STDIN>;
					chomp($line);
				}
				unless (defined(addIrcServer($id_network,$line))) {
					log_messageln("Could not add IRC Server");
					exit 11;
				}
			}
		}
	}
	else {
		$sQuery = "INSERT INTO NETWORK (network_name) VALUES (?)";
		$sth = $dbh->prepare($sQuery);
		unless ($sth->execute($line)) {
			log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			exit 12;
		}
		else {
			$id_network = $sth->{ mysql_insertid };
			log_messageln("Network $line added in NETWORK table with id : $id_network");
			print CONF "CONN_SERVER_NETWORK=$line\n";
			log_message("Enter irc server hostname : ");
			$line=<STDIN>;
			chomp($line);
			while ( $line eq "" ) {
				log_message("Enter irc server hostname : ");
				$line=<STDIN>;
				chomp($line);
			}
			unless (defined(addIrcServer($id_network,$line))) {
				log_messageln("Could not add IRC Server");
				exit 11;
			}
		}
	}
}

# Configure remaining [connection] values
log_message("Enter bot nick [mediabot] : ");
$line=<STDIN>;
chomp($line);
if ( $line eq "" ) {
	$line = "mediabot";
}
print CONF "CONN_NICK=$line\n";

log_message("Enter alternative nick [mediabot_] : ");
$line=<STDIN>;
chomp($line);
if ( $line eq "" ) {
	$line = "mediabot_";
}
print CONF "CONN_NICK_ALTERNATE=$line\n";

log_message("Enter bot ident (username) [" . $ENV{'USER'} . "] : ");
$line=<STDIN>;
chomp($line);
if ( $line eq "" ) {
	$line = $ENV{'USER'};
}
print CONF "CONN_USERNAME=$line\n";

log_message("Enter bot real name [mediabot] : ");
$line=<STDIN>;
chomp($line);
if ( $line eq "" ) {
	$line = "mediabot";
}
print CONF "CONN_IRCNAME=$line\n";

addConsoleChannelCheck();

log_messageln("If you choose to set +x usermode on Undernet network type, be sure to have a valid username");
log_messageln("Joining channels (other than console) in this case will fail because you're not authenticated to X");
log_message("Enter bot user mode [+i] : ");
$line=<STDIN>;
chomp($line);
if ($line eq "" ) { $line ="+i"; }

print CONF "CONN_USERMODE=$line\n";

# Configure network type section
log_messageln("You can specify network type ");
log_messageln("1 : Undernet (ircu)");
log_messageln("2 : Freenode (ircd-seven)");
log_messageln("0 : Other");
log_message("Enter network type [0] : ");
$line=<STDIN>;
chomp($line);
if ($line eq "" ) { $line=0; }
print CONF "CONN_NETWORK_TYPE=$line\n\n";

if ( $line == 1 ) {
	log_messageln("Configure undernet section");
	print CONF "[undernet]\n";
	
	log_message("Enter channel service target [x\@channels.undernet.org] : ");
	$line=<STDIN>;
	chomp($line);
	if ($line eq "" ) { $line ="x\@channels.undernet.org"; }
	print CONF "UNET_CSERVICE_LOGIN=$line\n";
	
	log_message("Enter channel service username (Enter to leave it empty) : ");
	$line=<STDIN>;
	chomp($line);
	unless(defined($line) && ($line ne "" )) {
		log_messageln("No username specified");
		$line = "";
	}
	print CONF "UNET_CSERVICE_USERNAME=$line\n";
	
	log_message("Enter channel service password (Enter to leave it empty) : ");
	$line=<STDIN>;
	chomp($line);
	unless(defined($line) && ($line ne "" )) {
		log_messageln("No password specified");
		$line = "";
	}
	print CONF "UNET_CSERVICE_PASSWORD=$line\n";
}
elsif ( $line == 2 ) {
	log_messageln("Configure freenode section");
	print CONF "[freenode]\n";
	log_message("Enter NickServ service password (Enter to leave it empty) : ");
	$line=<STDIN>;
	chomp($line);
	unless(defined($line) && ($line ne "" )) {
		log_messageln("No password specified");
		$line = "";
	}
	print CONF "FREENODE_NICKSERV_PASSWORD=$line\n";
}

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+
sub init_log(@) {
	my ($sLogFilename) = @_;
	unless (open LOG, ">>$sLogFilename") {
		print STDERR "Could not open $sLogFilename for writing.\n";
		exit 1;
	}
	$|=1;
	print LOG "+--------------------------------------------------------------------------------------------------+\n";
}

sub log_messageln(@) {
	my ($sMsg) = @_;
	if (defined($sMsg) && ($sMsg ne "")) {
		my $sDisplayMsg = time2str("[%d/%m/%Y %H:%M:%S]",time) . " $sMsg\n";
		print $sDisplayMsg;
		print LOG $sDisplayMsg;
	}
}

sub log_message(@) {
	my ($sMsg) = @_;
	if (defined($sMsg) && ($sMsg ne "")) {
		my $sDisplayMsg = time2str("[%d/%m/%Y %H:%M:%S]",time) . " $sMsg";
		print $sDisplayMsg;
		print LOG $sDisplayMsg;
	}
}

sub dbConnect(@) {
	my ($dbname,$dbhost,$dbport,$dbuser,$dbpasswd) = @_;
	my $connectionInfo="DBI:mysql:database=$dbname;$dbhost:$dbport";   # Database connection string
	my $dbh;                                                   				 # Database handle
	
	unless ( $dbh = DBI->connect($connectionInfo,$dbuser,$dbpasswd) ) {
	        log_messageln("dbConnect() DBI Error : " . $DBI::errstr);
	        log_messageln("dbConnect() DBI Native error code : " . $DBI::err);
	        if ( defined( $DBI::err ) ) {
	        	exit 8;
	        }
	}
	log_messageln("Connected to $dbname.");
	return $dbh;
}

sub addIrcServer(@) {
	my ($id_network,$server_hostname) = @_;
	my $id_server;
	$sQuery = "INSERT INTO SERVERS (id_network,server_hostname) VALUES (?,?)";
	$sth = $dbh->prepare($sQuery);
	unless ($sth->execute($id_network,$server_hostname)) {
		log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 10;
	}
	else {
		$id_server = $sth->{ mysql_insertid };
		log_messageln("IRC Server $line added in SERVERS table with id : $id_server");
	}
	return $id_server;
}

sub addConsoleChannelCheck() {
	my $sQuery = "SELECT * FROM CHANNEL WHERE description='console'";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute()) {
		log_messageln(0,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 13;
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_channel = $ref->{'id_channel'};
			my $name = $ref->{'name'};
			log_messageln("Console channel $name (id : $id_channel) already exists");
			log_message("Do you want to keep it ? (y/n) [y] : ");
			my $line=<STDIN>;
			chomp($line);
			if ($line eq "n") {
				$sQuery = "DELETE FROM CHANNEL WHERE id_channel=?";
				$sth = $dbh->prepare($sQuery);
				unless ($sth->execute($id_channel)) {
					log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					exit 14;
				}
				else {
					log_messageln("Console channel $name removed in CHANNEL table");
					addConsoleChannel();
				}
			}
		}
		else {
			addConsoleChannel();
		}
	}
}

sub addConsoleChannel() {
	log_message("Enter bot default (console) channel (must start with #) : ");
	my $line=<STDIN>;
	chomp($line);
	while ( ($line eq "") && (substr($line, 0, 1) ne '#')) {
		log_message("Enter bot default (console) channel (must start with #) : ");
		$line=<STDIN>;
		chomp($line);
	}
	my $sConsoleChannel = $line;
	log_message("Enter bot default (console) channel key (Hit Enter for none) : ");
	$line=<STDIN>;
	chomp($line);
	my $sConsoleChannelKey = $line;
	
	my $sConsoleChannelModes = "+stn";
	if (defined($sConsoleChannelKey) && ($sConsoleChannelKey ne "")) {
		$sConsoleChannelModes .= "k $sConsoleChannelKey";
	}
	my $sQuery;
	if (defined($sConsoleChannelKey) && ($sConsoleChannelKey ne "")) {
		$sQuery = "INSERT INTO CHANNEL (name,description,`key`,chanmode,auto_join) VALUES (?,?,?,?,1)";
		my $sth = $dbh->prepare($sQuery);
		unless ($sth->execute($sConsoleChannel,"console",$sConsoleChannelKey,$sConsoleChannelModes)) {
			log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			exit 15;
		}
		else {
			my $id_channel = $sth->{ mysql_insertid };
			log_messageln("Console channel $sConsoleChannel added in CHANNEL table with id : $id_channel");
		}
	}
	else {
		$sQuery = "INSERT INTO CHANNEL (name,description,chanmode,auto_join) VALUES (?,?,?,1)";
		my $sth = $dbh->prepare($sQuery);
		unless ($sth->execute($sConsoleChannel,"console",$sConsoleChannelModes)) {
			log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			exit 15;
		}
		else {
			my $id_channel = $sth->{ mysql_insertid };
			log_messageln("Console channel $sConsoleChannel added in CHANNEL table with id : $id_channel");
		}
	}
	
}