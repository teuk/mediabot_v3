#!/usr/bin/perl

# +---------------------------------------------------------------------------+
# !          MEDIABOT SERVERS CONFIG (Net::Async::IRC bot)                    !
# +---------------------------------------------------------------------------+

# +---------------------------------------------------------------------------+
# !          MODULES                                                          !
# +---------------------------------------------------------------------------+

use strict;
use warnings;
use diagnostics;
use Date::Format;
use File::Basename;
use Data::Dumper;
use Getopt::Long;
use DBI;

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+

sub log_messageln(@);
sub log_message(@);
sub log_messageln_wots(@);
sub init_log(@);
sub dbConnect(@);
sub getNetworkInfos(@);
sub addIrcNetwork(@);
sub getIrcserversNetwork(@);
sub addIrcServer(@);
sub menuServers(@);
sub getIrcServerId(@);
sub writeNetworkToConf(@);
sub displayAll(@);

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+
my $CONN_SERVER_NETWORK;
my $CONN_SERVER_NETWORK_CLAUSE_FOUND;
my $MAIN_PROG_DDBNAME;
my $MAIN_PROG_DBUSER;
my $MAIN_PROG_DBPASS;
my $MAIN_PROG_DBHOST;
my $MAIN_PROG_DBPORT;
my $CONFIG_FILE;
my $CONFIG_LIST;

# Check command line parameters
my $result = GetOptions (
        "conf=s" => \$CONFIG_FILE,
        "list" => \$CONFIG_LIST,
);

unless (defined($CONFIG_FILE) && ($CONFIG_FILE ne "")) {
	print STDERR "Usage: " . basename($0) . " --conf=<configuration_file> [--list]\n";
	exit 1;
}

init_log("conf_servers.log");

# Get database connection settings
log_messageln("Get database connection settings");
unless (open CONF,"$CONFIG_FILE") {
	log_messageln("Could not open $CONFIG_FILE");
	exit 2;
}
my $line;
while(defined($line=<CONF>)) {
	chomp($line);
	if ( $line =~ /^CONN_SERVER_NETWORK=(.*)$/ ) {
		$CONN_SERVER_NETWORK = $1;
		$CONN_SERVER_NETWORK_CLAUSE_FOUND = 1;
	}
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

unless (defined($CONN_SERVER_NETWORK_CLAUSE_FOUND) && $CONN_SERVER_NETWORK_CLAUSE_FOUND) {
	log_messageln("Clause CONN_SERVER_NETWORK=<network> not found in config file. Did you run ./configure without options before first use ?");
	exit 8;
}



# Establish a MySQL connection
log_messageln("Connect to database $MAIN_PROG_DDBNAME");
my $dbh = dbConnect($MAIN_PROG_DDBNAME,$MAIN_PROG_DBHOST,$MAIN_PROG_DBPORT,$MAIN_PROG_DBUSER,$MAIN_PROG_DBPASS);

if ( $CONFIG_LIST ) {
	displayAll($CONN_SERVER_NETWORK);
	log_messageln("------------------------------------------------------------");
	log_messageln("If your current network does not appear run ./configure -s to add it");
	exit 0;
}

my $id_network;
if (defined($CONN_SERVER_NETWORK) && ($CONN_SERVER_NETWORK ne "")) {
	my $CONN_SERVER_NETWORK_OLD = $CONN_SERVER_NETWORK;
	log_messageln("Current defined network : $CONN_SERVER_NETWORK");
	log_message("Do you want to keep that network (y/n) [y] : ");
	$line=<STDIN>;
	chomp($line);
	if (defined($line) && ($line eq "n")) {
		($id_network,$CONN_SERVER_NETWORK) = addIrcNetwork();
	}
	else {
		log_messageln("Keeping $CONN_SERVER_NETWORK, checking database");
		($id_network,$CONN_SERVER_NETWORK) = getNetworkInfos($CONN_SERVER_NETWORK);
		if (defined($id_network)) {
			log_messageln("Network $CONN_SERVER_NETWORK already exists in database (id_network : $id_network)");
		}
		else {
			my $sQuery = "INSERT INTO NETWORK (network_name) VALUES (?)";
			my $sth = $dbh->prepare($sQuery);
			unless ($sth->execute($CONN_SERVER_NETWORK_OLD)) {
				log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				exit 10;
			}
			else {
				$id_network = $sth->{ mysql_insertid };
				log_messageln("Added network $CONN_SERVER_NETWORK_OLD in database (id_network : $id_network)");
				$CONN_SERVER_NETWORK = $CONN_SERVER_NETWORK_OLD;
			}
		}
	}
}
else {
	log_messageln("No current defined network");
	($id_network,$CONN_SERVER_NETWORK) = addIrcNetwork();
}

log_messageln("Going on with IRC Network $CONN_SERVER_NETWORK (id_network : $id_network)");
writeNetworkToConf($CONFIG_FILE,$CONN_SERVER_NETWORK);
getIrcserversNetwork($id_network);
my $sChoice = menuServers($id_network);
while ( $sChoice ne "q" ) {
	getIrcserversNetwork($id_network);
	$sChoice = menuServers($id_network);
}
log_messageln("---------------------------------------------------------------------");
log_messageln("Configuration written for network $CONN_SERVER_NETWORK with servers :");
getIrcserversNetwork($id_network);
log_messageln("---------------------------------------------------------------------");

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

sub log_messageln_wots(@) {
	my ($sMsg) = @_;
	if (defined($sMsg) && ($sMsg ne "")) {
		print "$sMsg\n";
		print LOG "$sMsg\n";
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
	        	exit 9;
	        }
	}
	log_messageln("Connected to $dbname.");
	return $dbh;
}

sub getNetworkInfos(@) {
	my ($sNetworkParam) = @_;
	my $sNetworkName;
	my $id_network;
	my $sQuery = "SELECT * FROM NETWORK where network_name like ?";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute($sNetworkParam)) {
		log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 10;
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$sNetworkName = $ref->{'network_name'};
			$id_network = $ref->{'id_network'};
			return ($id_network,$sNetworkName);
		}
		else {
			return (undef,undef);
		}
	}
}

sub addIrcNetwork(@) {
	log_message("Enter network name : ");
	$line=<STDIN>;
	chomp($line);
	while ($line eq "") {
		log_message("Enter network name : ");
		$line=<STDIN>;
		chomp($line);
	}
	my ($id_network,$sNetworkName) = getNetworkInfos($line);
	if (defined($id_network)) {
		log_messageln("Network $sNetworkName already exists in database (id_network : $id_network)");
	}
	else {
		my $sQuery = "INSERT INTO NETWORK (network_name) VALUES (?)";
		my $sth = $dbh->prepare($sQuery);
		unless ($sth->execute($line)) {
			log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			exit 10;
		}
		else {
			$id_network = $sth->{ mysql_insertid };
			$sNetworkName = $line;
			log_messageln("Added network $line in database (id_network : $id_network)");
		}
	}
	return ($id_network,$sNetworkName);
}

sub addIrcServer(@) {
	my ($id_network,$server_hostname) = @_;
	my $id_server;
	my $sQuery = "INSERT INTO SERVERS (id_network,server_hostname) VALUES (?,?)";
	my $sth = $dbh->prepare($sQuery);
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

sub getIrcServerId(@) {
	my ($sServerhostname) = @_;
	my $sQuery = "SELECT * FROM SERVERS where server_hostname like ?";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute($sServerhostname)) {
		log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 10;
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_server = $ref->{'id_server'};
			return $id_server;
		}
		else {
			return undef;
		}
	}
}

sub getIrcserversNetwork(@) {
	my ($id_network) = @_;
	my $sQuery = "SELECT * FROM SERVERS where id_network=?";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute($id_network)) {
		log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 10;
	}
	else {
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			log_messageln("Server id : " . $ref->{'id_server'} . "\t" . $ref->{'server_hostname'});
			$i++;
		}
		unless ( $i ) {
			log_messageln("No irc server found for this network");
			return 0;
		}
		else {
			return 1;
		}
	}
}

sub menuServers(@) {
	my ($id_network) = @_;
	my $sResponse;
	log_message("Choose what to do (a)dd, (r)emove or (q)uit [a] : ");
	$line=<STDIN>;
	chomp($line);
	if ($line eq "") { 
		$sResponse = "a";
	}
	else {
		$sResponse = $line;
	}
	while (($sResponse ne "a") && ($sResponse ne "r") && ($sResponse ne "q")){
		log_message("Choose what to do (a)dd, (r)emove or (q)uit [a] : ");
		$line=<STDIN>;
		chomp($line);
		if ($line eq "") { 
			$sResponse = "a";
		}
		else {
			$sResponse = $line;
		}
	}
	if ( $sResponse eq "a" ) {
		my $id_server;
		log_message("Enter server hostname (or hostname:port) : ");
		$line=<STDIN>;
		chomp($line);
		while ($line eq "") {
			log_message("Enter server hostname (or hostname:port) : ");
			$line=<STDIN>;
			chomp($line);
		}
		$id_server = getIrcServerId($line);
		while (defined($id_server)) {
			log_messageln("Server already exists (id_server : $id_server)");
			log_message("Enter server hostname (or hostname:port) : ");
			$line=<STDIN>;
			chomp($line);
			while ($line eq "") {
				log_message("Enter server hostname (or hostname:port) : ");
				$line=<STDIN>;
				chomp($line);
			}
			$id_server = getIrcServerId($line);
		}
		$id_server = addIrcServer($id_network,$line);
		return "a";
	}
	elsif ( $sResponse eq "r" ) {
		my $id_server;
		while (!defined($id_server) && ($line ne "q")) {
			log_message("Enter server id or (q)uit : ");
			$line=<STDIN>;
			chomp($line);
			while ($line eq "") {
				log_message("Enter server id or (q)uit : ");
				$line=<STDIN>;
				chomp($line);
			}
			my $sQuery = "SELECT * FROM SERVERS where id_server=?";
			my $sth = $dbh->prepare($sQuery);
			unless ($sth->execute($line)) {
				log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				exit 10;
			}
			else {
				if (my $ref = $sth->fetchrow_hashref()) {
					$id_server = $ref->{'id_server'};
					$sQuery = "DELETE FROM SERVERS where id_server=?";
					$sth = $dbh->prepare($sQuery);
					unless ($sth->execute($id_server)) {
						log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						exit 10;
					}
					else {
						log_messageln("Deleted server id : $id_server");
					}
				}
			}
			unless (defined($id_server)) {
				if ($line ne "q") {
					log_messageln("Server id $line is undefined");
				}
			}
		}
		return "r";
	}
	else {
		return "q";
	}
}

sub writeNetworkToConf(@) {
	my ($CONFIG_FILE,$sNetworkName) = @_;
	unless (open SED, "sed -i -e 's/^CONN_SERVER_NETWORK=.*\$/CONN_SERVER_NETWORK=$sNetworkName/' $CONFIG_FILE |") {
		log_messageln("Could not write CONN_SERVER_NETWORK to config file");
		exit 11;
	}
	else {
		my $line=<SED>;
		log_messageln("Set CONN_SERVER_NETWORK to $CONN_SERVER_NETWORK in config file");
	}
}

sub displayAll(@) {
	my ($CONN_SERVER_NETWORK) = @_;
	unless (defined($CONN_SERVER_NETWORK) && ($CONN_SERVER_NETWORK ne "")) {
		log_messageln("No current network set in $CONFIG_FILE ! Run ./configure -s to add one");
	}
	else {
		log_messageln("Current network set : $CONN_SERVER_NETWORK");
	}
	my $sQuery = "SELECT * FROM NETWORK";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute()) {
		log_messageln("SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		exit 10;
	}
	else {
		my $bFound = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $id_network = $ref->{'id_network'};
			my $sNetworkName = $ref->{'network_name'};
			if ( $sNetworkName =~ /$CONN_SERVER_NETWORK/ ) {
				$bFound = 1;
			}
			log_messageln("------------------------------------------------------------");
			log_message("Network : $sNetworkName ");
			if ( $bFound ) {
				log_messageln_wots(" <= Current network");
				$bFound = 0;
			}
			else {
				log_messageln_wots(" ");
			}
			unless (getIrcserversNetwork($id_network)) {
				log_messageln("No server defined for this network");
			}
		}
	}
}