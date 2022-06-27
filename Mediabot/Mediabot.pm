package Mediabot;
 
use strict;
use warnings;
use diagnostics;
use Config::Simple;
use Date::Format;
use Date::Parse;
use Data::Dumper;
use DBI;
use Switch;
use Memory::Usage;
use IO::Async::Timer::Periodic;
use String::IRC;
use JSON;
use POSIX 'setsid';
use DateTime;
use DateTime::TimeZone;
use utf8;
use HTML::Tree;
use URL::Encode qw(url_encode_utf8 url_encode url_decode_utf8);
use HTML::Entities;
use MP3::Tag;
use File::Basename;
use Encode;
use Moose;
use Hailo;
use Socket;

sub new {
	my ($class,$args) = @_;
	my $self = bless {
		config_file => $args->{config_file},
		server => $args->{server},
	}, $class;
}

sub readConfigFile(@) {
	my $self = shift;
	unless ( -r $self->{config_file} ) {
		print STDERR time2str("[%d/%m/%Y %H:%M:%S]",time) . " Cannot open $self->{config_file}\n";
		exit 1;
	}
	print STDERR time2str("[%d/%m/%Y %H:%M:%S]",time) . " Reading configuration file $self->{config_file}\n";
	my $cfg = new Config::Simple();
	$cfg->read($self->{config_file}) or die $cfg->error();
	print STDERR time2str("[%d/%m/%Y %H:%M:%S]",time) . " $self->{config_file} loaded.\n";
	$self->{MAIN_CONF} = $cfg->vars();
	$self->{cfg} = $cfg;
}

sub getVersion(@) {
	my $self = shift;
	my ($MAIN_PROG_VERSION,$MAIN_GIT_VERSION);
	my ($cVerMajor,$cVerMinor,$cStable,$cVerDev);
	my ($gVerMajor,$gVerMinor,$gStable,$gVerDev);
	
	# Get current version
	log_message($self,0,"Getting current version from VERSION file");
	unless (open VERSION, "VERSION") {
		log_message($self,0,"Could not get version from VERSION file");
		$MAIN_PROG_VERSION = "Undefined";
	}
	else {
		my $line;
		if (defined($line=<VERSION>)) {
			chomp($line);
			$MAIN_PROG_VERSION = $line;
			($cVerMajor,$cVerMinor,$cStable,$cVerDev) = getDetailedVersion($self,$MAIN_PROG_VERSION);
		}
		else {
			$MAIN_PROG_VERSION = "Undefined";
		}
		if (defined($cVerMajor) && ($cVerMajor ne "") && defined($cVerMinor) && ($cVerMinor ne "") && defined($cStable) && ($cStable ne "")) {
			log_message($self,0,"-> Mediabot $cStable version $cVerMajor.$cVerMinor " . ((defined($cVerDev) && ($cVerDev ne "")) ? "($cVerDev)" : ""));
		}
		else {
			log_message($self,0,"-> Mediabot unknown version detected : $MAIN_PROG_VERSION");
		}
	}

	unless ( $MAIN_PROG_VERSION eq "Undefined" ) {
		# Check for latest version
		log_message($self,0,"Checking latest version from github (https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION)");
		unless (open GITVERSION, "curl --connect-timeout 5 -f -s https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION |") {
			log_message($self,0,"Could not get version from github");
			$MAIN_GIT_VERSION = "Undefined";
		}
		else {
			my $line;
			if (defined($line=<GITVERSION>)) {
				chomp($line);
				$MAIN_GIT_VERSION = $line;
				($gVerMajor,$gVerMinor,$gStable,$gVerDev) = getDetailedVersion($self,$MAIN_GIT_VERSION);
				if (defined($gVerMajor) && ($gVerMajor ne "") && defined($gVerMinor) && ($gVerMinor ne "") && defined($gStable) && ($gStable ne "")) {
					log_message($self,0,"-> Mediabot github $cStable version $gVerMajor.$gVerMinor " . ((defined($gVerDev) && ($gVerDev ne "")) ? "($cVerDev)" : ""));
					if ( $MAIN_PROG_VERSION eq $MAIN_GIT_VERSION ) {
						log_message($self,0,"Mediabot is up to date");
					}
					else {
						log_message($self,0,"Mediabot should be updated to $cStable version $gVerMajor.$gVerMinor " . ((defined($gVerDev) && ($gVerDev ne "")) ? "($cVerDev)" : ""));
					}
				}
				else {
					log_message($self,0,"Mediabot unknown git version detected : $MAIN_GIT_VERSION");
				}
			}
			else {
				$MAIN_GIT_VERSION = "Undefined";
				log_message($self,0,"-> Mediabot undefined git version detected ($MAIN_GIT_VERSION)");
			}
		}
	}
	$self->{'main_prog_version'} = $MAIN_PROG_VERSION;
	return ($MAIN_PROG_VERSION,$MAIN_GIT_VERSION);
}

sub getDetailedVersion(@) {
	my ($self,$sVersion) = @_;
	my ($str1,$str2) = split(/\./,$sVersion);
	if ( $str2 =~ /^[0-9]+$/) {
		# Stable version
		#print time2str("[%d/%m/%Y %H:%M:%S]",time) . " [DEBUG1] getVersion() Mediabot stable $str1.$str2\n";
		return ($str1,$str2,"stable",undef);
	}
	elsif ( $str2 =~ /dev/ ) {
		# Devel version
		my ($sMinor,$sReleaseDate) = split(/\-/,$str2);
		$sMinor =~ s/dev//;
		#print time2str("[%d/%m/%Y %H:%M:%S]",time) . " [DEBUG1] getVersion() Mediabot devel $str1.$sMinor ($sReleaseDate)\n";
		return ($str1,$sMinor,"devel",$sReleaseDate);
	}
	else {
		#print time2str("[%d/%m/%Y %H:%M:%S]",time) . " [DEBUG1] getVersion() Mediabot unknown version : $sVersion\n";
		return (undef,undef,undef,undef);
	}
}

sub getDebugLevel(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return $MAIN_CONF{'main.MAIN_PROG_DEBUG'};
}

sub getLogFile(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return $MAIN_CONF{'main.MAIN_LOG_FILE'};
}

sub dumpConfig(@) {
	my $self = shift;
	print STDERR Dumper($self->{MAIN_CONF});
}

sub getMainConf(@) {
	my $self = shift;
	return $self->{MAIN_CONF};
}

sub getMainConfCfg(@) {
	my $self = shift;
	return $self->{cfg};
}

sub getPidFile(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return $MAIN_CONF{'main.MAIN_PID_FILE'};
}

sub getPidFromFile(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $pidfile = $MAIN_CONF{'main.MAIN_PID_FILE'};
	unless (open PIDFILE, $pidfile) {
		return undef;
	}
	else {
		my $line;
		if (defined($line=<PIDFILE>)) {
			chomp($line);
			close PIDFILE;
			return $line;
		}
		else {
			log_message($self,1,"getPidFromFile() couldn't read PID from $pidfile");
			return undef;
		}
	}
}

sub init_log(@) {
	my ($self) = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sLogFilename = $MAIN_CONF{'main.MAIN_LOG_FILE'};
	my $LOG;
	unless (open $LOG, ">>$sLogFilename") {
		print STDERR "Could not open $sLogFilename for writing.\n";
		clean_and_exit($self,1);
	}
	$|=1;
	print $LOG "+--------------------------------------------------------------------------------------------------+\n";
	$self->{LOG} = $LOG;
}

sub init_hailo(@) {
	my ($self) = shift;
	log_message($self,0,"Initialize Hailo");
	my $hailo = Hailo->new(
		brain => 'mediabot_v3.brn',
		save_on_exit => 1,
	);
	$self->{hailo} = $hailo;
}

sub get_hailo(@) {
	my ($self) = shift;
	return $self->{hailo};
}

sub clean_and_exit(@) {
	my ($self,$iRetValue) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	log_message($self,0,"Cleaning and exiting...");
	
	if (defined($self->{dbh}) && ($self->{dbh} != 0)) {
		if ( $iRetValue != 1146 ) {
		}
		$self->{dbh}->disconnect();
	}
	
	if(defined(fileno($self->{LOG}))) { close $self->{LOG}; }
	
	exit $iRetValue;
}

sub log_message(@) {
	my ($self,$iLevel,$sMsg) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LOG = $self->{LOG};
	binmode STDOUT, ':utf8';
	binmode $LOG, ':utf8';
	if (defined($sMsg) && ($sMsg ne "")) {
		my $sDisplayMsg = time2str("[%d/%m/%Y %H:%M:%S]",time) . " ";
		select $LOG;
		$|=1;
		if ( $MAIN_CONF{'main.MAIN_PROG_DEBUG'} >= $iLevel ) {
			if ( $iLevel == 0 ) {
				$sDisplayMsg .= "$sMsg\n";
				print $LOG $sDisplayMsg;
			}
			else {
				$sDisplayMsg .= "[DEBUG" . $iLevel . "] $sMsg\n";
				print $LOG $sDisplayMsg;
			}
			select STDOUT;
			print $sDisplayMsg;
		}
	}
}

sub dbConnect(@) {
	my ($self) = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LOG = $self->{LOG};
	my $connectionInfo="DBI:mysql:database=" . $MAIN_CONF{'mysql.MAIN_PROG_DDBNAME'} . ";" . $MAIN_CONF{'mysql.MAIN_PROG_DBHOST'} . ":" . $MAIN_CONF{'mysql.MAIN_PROG_DBPORT'};   # Database connection string
	# Database handle
	my $dbh;

	log_message($self,1,"dbConnect() Connecting to Database : " . $MAIN_CONF{'mysql.MAIN_PROG_DDBNAME'});
	
	unless ( $dbh = DBI->connect($connectionInfo,$MAIN_CONF{'mysql.MAIN_PROG_DBUSER'},$MAIN_CONF{'mysql.MAIN_PROG_DBPASS'}) ) {
	        log_message($self,0,"dbConnect() DBI Error : " . $DBI::errstr);
	        log_message($self,0,"dbConnect() DBI Native error code : " . $DBI::err);
	        if ( defined( $DBI::err ) ) {
	        	clean_and_exit($self,3);
	        }
	}
	$dbh->{mysql_auto_reconnect} = 1;
	log_message($self,1,"dbConnect() Connected to " . $MAIN_CONF{'mysql.MAIN_PROG_DDBNAME'} . ".");
	my $sQuery = "SET NAMES 'utf8'";
	my $sth = $dbh->prepare($sQuery);
	unless ($sth->execute() ) {
		log_message($self,1,"dbConnect() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	$sQuery = "SET CHARACTER SET utf8";
	$sth = $dbh->prepare($sQuery);
	unless ($sth->execute() ) {
		log_message($self,1,"dbConnect() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	$sQuery = "SET COLLATION_CONNECTION = 'utf8_general_ci'";
	$sth = $dbh->prepare($sQuery);
	unless ($sth->execute() ) {
		log_message($self,1,"dbConnect() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	$sth->finish;
	$self->{dbh} = $dbh;
}

sub getDbh(@) {
	my $self = shift;
	return $self->{dbh};
}

sub dbCheckTables(@) {
	my ($self) = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LOG = $self->{LOG};
	my $dbh = $self->{dbh};
	log_message($self,3,"Checking USER table");
	my $sLogoutQuery = "SELECT * FROM USER";
	my $sth = $dbh->prepare($sLogoutQuery);
	unless ($sth->execute) {
		log_message($self,0,"dbCheckTables() SQL Error : " . $DBI::errstr . "(" . $DBI::err . ") Query : " . $sLogoutQuery);
		if (defined($DBI::err) && ($DBI::err == 1146)) {
			log_message($self,3,"USER table does not exist. Check your database installation");
			clean_and_exit($self,1146);
		}
	}
	else {	
		log_message($self,3,"USER table exists");
	}
}

sub dbLogoutUsers(@) {
	my ($self) = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LOG = $self->{LOG};
	my $dbh = $self->{dbh};
	my $sLogoutQuery = "UPDATE USER SET auth=0 WHERE auth=1";
	my $sth = $dbh->prepare($sLogoutQuery);
	unless ($sth->execute) {
		log_message($self,0,"dbLogoutUsers() SQL Error : " . $DBI::errstr . "(" . $DBI::err . ") Query : " . $sLogoutQuery);
	}
	else {	
		log_message($self,0,"Logged out all users");
	}
}

sub setServer(@) {
	my ($self,$sServer) = @_;
	$self->{server} = $sServer;
}

sub pickServer(@) {
	my ($self) = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LOG = $self->{LOG};
	my $dbh = $self->{dbh};
	unless (defined($self->{server}) && ($self->{server} ne "")) {
		# Pick a server in db default on CONN_SERVER_NETWORK
		my $sQuery = "SELECT SERVERS.server_hostname FROM NETWORK,SERVERS WHERE NETWORK.id_network=SERVERS.id_network AND NETWORK.network_name like ? ORDER BY RAND() LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($MAIN_CONF{'connection.CONN_SERVER_NETWORK'})) {
			log_message($self,0,"Startup select SERVER, SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {	
			if (my $ref = $sth->fetchrow_hashref()) {
				$self->{server} = $ref->{'server_hostname'};
			}
		}
		$sth->finish;

		unless (defined($MAIN_CONF{'connection.CONN_SERVER_NETWORK'}) && ($MAIN_CONF{'connection.CONN_SERVER_NETWORK'} ne "")) {
			log_message($self,0,"No CONN_SERVER_NETWORK defined in $self->{config_file}");
			log_message($self,0,"Run ./configure at first use or ./configure -s to set it properly");
			clean_and_exit($self,4);
		}
		unless (defined($self->{server}) && ($self->{server} ne "")) {
			log_message($self,0,"No server found for network " . $MAIN_CONF{'connection.CONN_SERVER_NETWORK'} . " defined in $self->{config_file}");
			log_message($self,0,"Run ./configure at first use or ./configure -s to set it properly");
			clean_and_exit($self,4);
		}
		$self->log_message(0,"Picked $self->{server} from Network $MAIN_CONF{'connection.CONN_SERVER_NETWORK'}");
	}
	else {
		$self->log_message(0,"Picked $self->{server} from command line");
	}
	
	$self->{server_hostname} = $self->{server};
	if ( $self->{server} =~ /:/ ) {
		$self->{server_hostname} =~ s/\:.*$//;
		$self->{server_port} = $self->{server};
		$self->{server_port} =~ s/^.*\://;
	}
	else {
		$self->{server_port} = 6667;
	}
}

sub getServerHostname(@) {
	my $self = shift;
	return $self->{server_hostname};
}

sub getServerPort(@) {
	my $self = shift;
	return $self->{server_port};
}

sub setLoop(@) {
	my ($self,$loop) = @_;
	$self->{loop} = $loop;
}

sub getLoop(@) {
	my $self = shift;
	return $self->{loop};
}

sub setMainTimerTick(@) {
	my ($self,$timer) = @_;
	$self->{main_timer_tick} = $timer;
}

sub getMainTimerTick(@) {
	my $self = shift;
	return $self->{maint_timer_tick};
}

sub setIrc(@) {
	my ($self,$irc) = @_;
	$self->{irc} = $irc;
}

sub getIrc(@) {
	my $self = shift;
	return $self->{irc};
}

sub getConnectionNick(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sConnectionNick = $MAIN_CONF{'connection.CONN_NICK'};
	if (($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1) && ($MAIN_CONF{'connection.CONN_USERMODE'} =~ /x/)) {
		my @chars = ("A".."Z", "a".."z");
		my $string;
		$string .= $chars[rand @chars] for 1..8;
		$sConnectionNick = $string . (int(rand(100))+10);
	}
	log_message($self,0,"Connection nick : $sConnectionNick");
	return $sConnectionNick;
}

sub getServerPass(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return (defined($MAIN_CONF{'connection.CONN_PASS'}) ? $MAIN_CONF{'connection.CONN_PASS'} : "");
}

sub getNickTrigger(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return (defined($MAIN_CONF{'main.NICK_TRIGGER'}) ? $MAIN_CONF{'main.NICK_TRIGGER'} : 0);
}

sub getUserName(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return $MAIN_CONF{'connection.CONN_USERNAME'};
}

sub getIrcName(@) {
	my $self = shift;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	return $MAIN_CONF{'connection.CONN_IRCNAME'};
}

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

sub getIdChannel(@) {
	my ($self,$sChannel) = @_;
	my $id_channel = undef;
	my $sQuery = "SELECT id_channel FROM CHANNEL WHERE name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel) ) {
		log_message($self,1,"getIdChannel() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_channel = $ref->{'id_channel'};
		}
	}
	$sth->finish;
	return $id_channel;
}

sub getUserhandle(@) {
	my ($self,$id_user) = @_;
	my $sUserhandle = undef;
	my $sQuery = "SELECT nickname FROM USER WHERE id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user) ) {
		log_message($self,1,"getUserhandle() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$sUserhandle = $ref->{'nickname'};
		}
	}
	$sth->finish;
	return $sUserhandle;
}

sub getUserAutologin(@) {
	my ($self,$sMatchingUserHandle) = @_;
	my $sQuery = "SELECT * FROM USER WHERE nickname like ? AND username='#AUTOLOGIN#'";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sMatchingUserHandle) ) {
		log_message($self,1,"getUserAutologin() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub getIdUser(@) {
	my ($self,$sUserhandle) = @_;
	my $id_user = undef;
	my $sQuery = "SELECT id_user FROM USER WHERE nickname like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserhandle) ) {
		log_message($self,1,"getIdUser() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_user = $ref->{'id_user'};
		}
	}
	$sth->finish;
	return $id_user;
}

sub getChannelName(@) {
	my ($self,$id_channel) = @_;
	my $name = undef;
	my $sQuery = "SELECT name FROM CHANNEL WHERE id_channel=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel) ) {
		log_message($self,1,"getChannelName() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$name = $ref->{'name'};
		}
	}
	$sth->finish;
	return $name;
}

sub getConsoleChan(@) {
	my ($self) = @_;
	my $sQuery = "SELECT * FROM CHANNEL WHERE description='console'";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_channel = $ref->{'id_channel'};
			my $name = $ref->{'name'};
			my $chanmode = $ref->{'chanmode'};
			my $key = $ref->{'key'};
			return($id_channel,$name,$chanmode,$key);
		}
		else {
			return (undef,undef,undef,undef);
		}
	}
	$sth->finish;
}

sub noticeConsoleChan(@) {
	my ($self,$sMsg) = @_;
	my ($id_channel,$name,$chanmode,$key) = getConsoleChan($self);
	unless(defined($name) && ($name ne "")) {
		log_message($self,0,"No console chan defined ! Run ./configure to setup the bot");
	}
	else {
		botNotice($self,$name,$sMsg);
	}
}

sub logBot(@) {
	my ($self,$message,$sChannel,$action,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	my $sHostmask = $message->prefix;
	my $id_user = undef;
	my $sUser = "Unknown user";
	if (defined($iMatchingUserId)) {
		$id_user = $iMatchingUserId;
		$sUser = $sMatchingUserHandle;
	}
	my $id_channel = undef;
	if (defined($sChannel)) {
		$id_channel = getIdChannel($self,$sChannel);
	}
	my $sQuery = "INSERT INTO ACTIONS_LOG (ts,id_user,id_channel,hostmask,action,args) VALUES (?,?,?,?,?,?)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless (defined($tArgs[0])) {
		$tArgs[0] = "";
	}
	unless ($sth->execute(time2str("%Y-%m-%d %H-%M-%S",time),$id_user,$id_channel,$sHostmask,$action,join(" ",@tArgs))) {
		log_message($self,0,"logBot() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sNoticeMsg = "($sUser : $sHostmask) command $action";
		if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
			$sNoticeMsg .= " " . join(" ",@tArgs);
		}
		if (defined($sChannel)) {
			$sNoticeMsg .= " on $sChannel";
		}
		noticeConsoleChan($self,$sNoticeMsg);
		log_message($self,3,"logBot() $sNoticeMsg");
	}
	$sth->finish;
}

sub logBotAction(@) {
	my ($self,$message,$eventtype,$sNick,$sChannel,$sText) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	#my $dbh = $self->{dbh};
	my $sUserhost = "";
	if (defined($message)) {
		$sUserhost = $message->prefix;
	}
	my $id_channel;
	if (defined($sChannel)) {
		log_message($self,5,"logBotAction() eventtype = $eventtype chan = $sChannel nick = $sNick text = $sText");
	}
	else {
		log_message($self,5,"logBotAction() eventtype = $eventtype nick = $sNick text = $sText");
	}
	log_message($self,5,"logBotAction() " . Dumper($message));
	
	my $sQuery = "SELECT * FROM CHANNEL WHERE name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel) ) {
		log_message($self,1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if ((my $ref = $sth->fetchrow_hashref()) || ($eventtype eq "quit")) {
			unless ($eventtype eq "quit") { $id_channel = $ref->{'id_channel'}; }
			log_message($self,5,"logBotAction() ts = " . time2str("%Y-%m-%d %H-%M-%S",time));
			my $sQuery = "INSERT INTO CHANNEL_LOG (id_channel,ts,event_type,nick,userhost,publictext) VALUES (?,?,?,?,?,?)";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($id_channel,time2str("%Y-%m-%d %H-%M-%S",time),$eventtype,$sNick,$sUserhost,$sText) ) {
				log_message($self,1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				log_message($self,5,"logBotAction() inserted " . $eventtype . " event into CHANNEL_LOG");
			}
		}
	}
}

sub botPrivmsg(@) {
	my ($self,$sTo,$sMsg) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($sTo)) {
		my $eventtype = "public";
		if (substr($sTo, 0, 1) eq '#') {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					log_message($self,4,"botPrivmsg() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						log_message($self,3,"botPrivmsg() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					log_message($self,4,"botPrivmsg() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						log_message($self,3,"botPrivmsg() channel $sTo has chanset +AntiFlood");
						if (checkAntiFlood($self,$sTo)) {
							return undef;
						}
					}
				}
				log_message($self,0,"$sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
				my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND name=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sTo) ) {
					log_message($self,1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					while (my $ref = $sth->fetchrow_hashref()) {
						my $sBadwordDb = $ref->{'badword'};
						my $sBadwordLc = lc $sBadwordDb;
						my $sMsgLc = lc $sMsg;
						if (index($sMsgLc, $sBadwordLc) != -1) {
							logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,"$sMsg (BADWORD : $sBadwordDb)");
							noticeConsoleChan($self,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							log_message($self,3,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$sth->finish;
							return;
						}
					}
					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}
		}
		else {
			$eventtype = "private";
			log_message($self,0,"-> *$sTo* $sMsg");
		}
		if (defined($sMsg) && ($sMsg ne "")) {
			if (utf8::is_utf8($sMsg)) {
				$sMsg = Encode::encode("UTF-8", $sMsg);
				$self->{irc}->do_PRIVMSG( target => $sTo, text => $sMsg );
			}
			else {
				$self->{irc}->do_PRIVMSG( target => $sTo, text => $sMsg );
			}
		}
		else {
			log_message($self,0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		log_message($self,0,"botPrivmsg() ERROR no target specified to send $sMsg");
	}
}

sub botAction(@) {
	my ($self,$sTo,$sMsg) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($sTo)) {
		my $eventtype = "public";
		if (substr($sTo, 0, 1) eq '#') {
				my $id_chanset_list = getIdChansetList($self,"NoColors");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					log_message($self,4,"botAction() check chanset NoColors, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						log_message($self,3,"botAction() channel $sTo has chanset +NoColors");
						$sMsg =~ s/\cC\d{1,2}(?:,\d{1,2})?|[\cC\cB\cI\cU\cR\cO]//g;
					}
				}
				$id_chanset_list = getIdChansetList($self,"AntiFlood");
				if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
					log_message($self,4,"botAction() check chanset AntiFlood, id_chanset_list = $id_chanset_list");
					my $id_channel_set = getIdChannelSet($self,$sTo,$id_chanset_list);
					if (defined($id_channel_set) && ($id_channel_set ne "")) {
						log_message($self,3,"botAction() channel $sTo has chanset +AntiFlood");
						if (checkAntiFlood($self,$sTo)) {
							return undef;
						}
					}
				}
				log_message($self,0,"$sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
				my $sQuery = "SELECT badword FROM CHANNEL,BADWORDS WHERE CHANNEL.id_channel=BADWORDS.id_channel AND name=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sTo) ) {
					log_message($self,1,"logBotAction() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					while (my $ref = $sth->fetchrow_hashref()) {
						my $sBadwordDb = $ref->{'badword'};
						my $sBadwordLc = lc $sBadwordDb;
						my $sMsgLc = lc $sMsg;
						if (index($sMsgLc, $sBadwordLc) != -1) {
							logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,"$sMsg (BADWORD : $sBadwordDb)");
							noticeConsoleChan($self,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							log_message($self,3,"Badword : $sBadwordDb blocked on channel $sTo ($sMsg)");
							$sth->finish;
							return;
						}
					}
					logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
				}
		}
		else {
			$eventtype = "private";
			log_message($self,0,"-> *$sTo* $sMsg");
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
			log_message($self,0,"botPrivmsg() ERROR no message specified to send to target");
		}
	}
	else {
		log_message($self,0,"botAction() ERROR no target specified to send $sMsg");
	}
}

sub botNotice(@) {
	my ($self,$sTo,$sMsg) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	$self->{irc}->do_NOTICE( target => $sTo, text => $sMsg );
	log_message($self,0,"-> -$sTo- $sMsg");
	if (substr($sTo, 0, 1) eq '#') {
		logBotAction($self,undef,"notice",$self->{irc}->nick_folded,$sTo,$sMsg);
	}
}

sub joinChannel(@) {
	my ($self,$channel,$key) = @_;
	if (defined($key) && ($key ne "")) {
		log_message($self,0,"Trying to join $channel with key $key");
		$self->{irc}->send_message("JOIN", undef, ($channel,$key));
	}
	else {
		log_message($self,0,"Trying to join $channel");
		$self->{irc}->send_message("JOIN", undef, $channel);
	}
}

# Join channel with auto_join set
sub joinChannels(@) {
	my $self = shift;
	my $sQuery = "SELECT * FROM CHANNEL WHERE auto_join=1 and description !='console'";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			if ( $i == 0 ) {
				log_message($self,0,"Auto join channels");
			}
			my $id_channel = $ref->{'id_channel'};
			my $name = $ref->{'name'};
			my $chanmode = $ref->{'chanmode'};
			my $key = $ref->{'key'};
			joinChannel($self,$name,$key);
			$i++;
		}
		if ( $i == 0 ) {
			log_message($self,0,"No channel to auto join");
		}
	}
	$sth->finish;
	
}

# Set timers at startup
sub onStartTimers(@) {
	my $self = shift;
	my %hTimers;
	my $sQuery = "SELECT * FROM TIMERS";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		log_message($self,0,"Checking timers to set at startup");
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $id_timers = $ref->{'id_timers'};
			my $name = $ref->{'name'};
			my $duration = $ref->{'duration'};
			my $command = $ref->{'command'};
			my $sSecondText = ( $duration > 1 ? "seconds" : "second" );
			log_message($self,0,"Timer $name - id : $id_timers - every $duration $sSecondText - command $command");
			my $timer = IO::Async::Timer::Periodic->new(
			    interval => $duration,
			    on_tick => sub {
			    	log_message($self,3,"Timer every $duration seconds : $command");
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
			log_message($self,0,"$i active $sTimerText set at startup");
		}
		else {
			log_message($self,0,"No timer to set at startup");
		}
	}
	$sth->finish;
	%{$self->{hTimers}} = %hTimers;
}

sub userOnJoin(@) {
	my ($self,$message,$sChannel,$sNick) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		my $sChannelUserQuery = "SELECT * FROM USER_CHANNEL,CHANNEL WHERE USER_CHANNEL.id_channel=CHANNEL.id_channel AND name=? AND id_user=?";
		log_message($self,4,$sChannelUserQuery);
		my $sth = $self->{dbh}->prepare($sChannelUserQuery);
		unless ($sth->execute($sChannel,$iMatchingUserId)) {
			log_message($self,1,"on_join() SQL Error : " . $DBI::errstr . " Query : " . $sChannelUserQuery);
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
}

sub getNickInfo(@) {
	my ($self,$message) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $iMatchingUserId;
	my $iMatchingUserLevel;
	my $iMatchingUserLevelDesc;
	my $iMatchingUserAuth;
	my $sMatchingUserHandle;
	my $sMatchingUserPasswd;
	my $sMatchingUserInfo1;
	my $sMatchingUserInfo2;
	
	my $sCheckQuery = "SELECT * FROM USER";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		log_message($self,1,"getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {
		while (my $ref = $sth->fetchrow_hashref()) {
			my @tHostmasks = split(/,/,$ref->{'hostmasks'});
			foreach my $sHostmask (@tHostmasks) {
				log_message($self,4,"getNickInfo() Checking hostmask : " . $sHostmask);
				my $sHostmaskSource = $sHostmask;
				$sHostmask =~ s/\./\\./g;
				$sHostmask =~ s/\*/.*/g;
				$sHostmask =~ s/\[/\\[/g;
				$sHostmask =~ s/\]/\\]/g;
				$sHostmask =~ s/\{/\\{/g;
				$sHostmask =~ s/\}/\\}/g;
				if ( $message->prefix =~ /^$sHostmask/ ) {
					log_message($self,3,"getNickInfo() $sHostmask matches " . $message->prefix);
					$sMatchingUserHandle = $ref->{'nickname'};
					if (defined($ref->{'password'})) {
						$sMatchingUserPasswd = $ref->{'password'};
					}
					$iMatchingUserId = $ref->{'id_user'};
					my $iMatchingUserLevelId = $ref->{'id_user_level'};
					my $sGetLevelQuery = "SELECT * FROM USER_LEVEL WHERE id_user_level=?";
					my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);
				        unless ($sth2->execute($iMatchingUserLevelId)) {
                				log_message($self,1,"getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sGetLevelQuery);
        				}
        				else {
               					while (my $ref2 = $sth2->fetchrow_hashref()) {
							$iMatchingUserLevel = $ref2->{'level'};
							$iMatchingUserLevelDesc = $ref2->{'description'};
						}
					}
					$iMatchingUserAuth = $ref->{'auth'};
					if ( defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} eq "1") && defined($MAIN_CONF{'undernet.UNET_CSERVICE_HOSTMASK'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_HOSTMASK'} ne "")) {
						unless ($iMatchingUserAuth) {
							my $sUnetHostmask = $MAIN_CONF{'undernet.UNET_CSERVICE_HOSTMASK'};
							if ($sHostmaskSource =~ /$sUnetHostmask$/) {
								my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
								my $sth2 = $self->{dbh}->prepare($sQuery);
								unless ($sth2->execute($iMatchingUserId)) {
									log_message($self,1,"getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									$iMatchingUserAuth = 1;
									log_message($self,0,"getNickInfo() Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource");
									noticeConsoleChan($self,"Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource");
								}
								$sth2->finish;
							}
						}
					}
					if (getUserAutologin($self,$sMatchingUserHandle)) {
						unless ($iMatchingUserAuth) {
							my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
							my $sth2 = $self->{dbh}->prepare($sQuery);
							unless ($sth2->execute($iMatchingUserId)) {
								log_message($self,1,"getNickInfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								$iMatchingUserAuth = 1;
								log_message($self,0,"getNickInfo() Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource (autologin is ON)");
								noticeConsoleChan($self,"Auto logged $sMatchingUserHandle with hostmask $sHostmaskSource (autologin is ON)");
							}
							$sth2->finish;
						}
					}
					if (defined($ref->{'info1'})) {
						$sMatchingUserInfo1 = $ref->{'info1'};
					}
					if (defined($ref->{'info2'})) {
						$sMatchingUserInfo2 = $ref->{'info2'};
					}
				}
			}
		}
	}
	$sth->finish;
	if (defined($iMatchingUserId)) {
		log_message($self,3,"getNickInfo() iMatchingUserId : $iMatchingUserId");
	}
	else {
		log_message($self,4,"getNickInfo() iMatchingUserId is undefined with this host : " . $message->prefix);
		return (undef,undef,undef,undef,undef,undef,undef);
	}
	if (defined($iMatchingUserLevel)) {
		log_message($self,4,"getNickInfo() iMatchingUserLevel : $iMatchingUserLevel");
	}
	if (defined($iMatchingUserLevelDesc)) {
		log_message($self,4,"getNickInfo() iMatchingUserLevelDesc : $iMatchingUserLevelDesc");
	}
	if (defined($iMatchingUserAuth)) {
		log_message($self,4,"getNickInfo() iMatchingUserAuth : $iMatchingUserAuth");
	}
	if (defined($sMatchingUserHandle)) {
		log_message($self,4,"getNickInfo() sMatchingUserHandle : $sMatchingUserHandle");
	}
	if (defined($sMatchingUserPasswd)) {
		log_message($self,4,"getNickInfo() sMatchingUserPasswd : $sMatchingUserPasswd");
	}
	if (defined($sMatchingUserInfo1)) {
		log_message($self,4,"getNickInfo() sMatchingUserInfo1 : $sMatchingUserInfo1");
	}
	if (defined($sMatchingUserInfo2)) {
		log_message($self,4,"getNickInfo() sMatchingUserInfo2 : $sMatchingUserInfo2");
	}
	
	return ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2);
}

sub mbCommandPublic(@) {
	my ($self,$message,$sChannel,$sNick,$botNickTriggered,$sCommand,@tArgs)	= @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
		case /^version$/i		{
													log_message($self,0,"mbVersion() by $sNick on $sChannel");
													botPrivmsg($self,$sChannel,$MAIN_CONF{'main.MAIN_PROG_NAME'} . $self->{main_prog_version});
													logBot($self,$message,undef,"version",undef);
												}
		case /^chanstatlines$/i	{
														channelStatLines($self,$message,$sChannel,$sNick,@tArgs);
													}
		case /^whotalk$/i		{
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
		case /^countslaps$/i						{
														mbCountSlaps($self,$message,$sNick,$sChannel,@tArgs);
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
		else									{
														#my $bFound = mbPluginCommand(\%MAIN_CONF,$LOG,$dbh,$irc,$message,$sChannel,$sNick,$sCommand,@tArgs);
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
																		my $id_chanset_list = getIdChansetList($self,"Hailo");
																		if (defined($id_chanset_list)) {
																			my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
																			if (defined($id_channel_set)) {
																				unless (is_hailo_excluded_nick($self,$sNick) || (substr($what, 0, 1) eq "!") || (substr($what, 0, 1) eq $MAIN_CONF{'main.MAIN_PROG_CMD_CHAR'})) {
																					my $hailo = get_hailo($self);
																					my $sCurrentNick = $self->{irc}->nick_folded;
																					$what =~ s/$sCurrentNick//g;
																					$what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });
																					my $sAnswer = $hailo->learn_reply($what);
																					if (defined($sAnswer) && ($sAnswer ne "") && !($sAnswer =~ /^\Q$what\E\s*\.$/i)) {
																						log_message($self,4,"learn_reply $what from $sNick : $sAnswer");
																						botPrivmsg($self,$sChannel,$sAnswer);
																					}
																				}
																			}
																		}
																	}
																}
															}
															else {
																log_message($self,3,"Public command '$sCommand' not found");
															}
														}
													}
	}
}

sub mbCommandPrivate(@) {
	my ($self,$message,$sNick,$sCommand,@tArgs)	= @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
		else							{
													#my $bFound = mbPluginCommand(\%MAIN_CONF,$LOG,$dbh,$irc,$message,undef,$sNick,$sCommand,@tArgs);
													log_message($self,3,$message->prefix . " Private command '$sCommand' not found");
													return undef;
											}
	}
}

sub mbQuit(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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

sub checkAuth(@) {
	my ($self,$iUserId,$sUserHandle,$sPassword) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sCheckAuthQuery = "SELECT * FROM USER WHERE id_user=? AND nickname=? AND password=PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($iUserId,$sUserHandle,$sPassword)) {
		log_message($self,1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sQuery = "UPDATE USER SET auth=1 WHERE id_user=?";
			my $sth2 = $self->{dbh}->prepare($sQuery);
			unless ($sth2->execute($iUserId)) {
				log_message($self,1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				return 0;
			}
			$sQuery = "UPDATE USER SET last_login=? WHERE id_user =?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute(time2str("%Y-%m-%d %H-%M-%S",time),$iUserId)) {
				log_message($self,1,"checkAuth() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	#login <username> <password>
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
		my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
		if (defined($iMatchingUserId)) {
			unless (defined($sMatchingUserPasswd)) {
				botNotice($self,$sNick,"Your password is not set. Use /msg " . $self->{irc}->nick_folded . " pass password");
			}
			else {
				if (checkAuth($self,$iMatchingUserId,$tArgs[0],$tArgs[1])) {
					botNotice($self,$sNick,"Login successfull as $sMatchingUserHandle (Level : $iMatchingUserLevelDesc)");
					my $sNoticeMsg = $message->prefix . " Successfull login as $sMatchingUserHandle (Level : $iMatchingUserLevelDesc)";
					noticeConsoleChan($self,$sNoticeMsg);
					logBot($self,$message,undef,"login",($tArgs[0],"Success"));
				}
				else {
					botNotice($self,$sNick,"Login failed (Bad password).");
					my $sNoticeMsg = $message->prefix . " Failed login (Bad password)";
					noticeConsoleChan($self,$sNoticeMsg);
					logBot($self,$message,undef,"login",($tArgs[0],"Failed (Bad password)"));
				}
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " Failed login (hostmask may not be present in database)";
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"login",($tArgs[0],"Failed (Bad hostmask)"));
		}
	}
	else {
		botNotice($self,$sNick,"Syntax error : /msg " . $self->{irc}->nick_folded . " login <username> <password>");
	}
}

sub checkUserLevel(@) {
	my ($self,$iUserLevel,$sLevelRequired) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	log_message($self,3,"isUserLevel() $iUserLevel vs $sLevelRequired");
	my $sQuery = "SELECT level FROM USER_LEVEL WHERE description like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sLevelRequired)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub userCount(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT count(*) as nbUser FROM USER";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			log_message($self,3,"userCount() " . $ref->{'nbUser'});
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	unless (defined($sHostmask) && ($sHostmask =~ /^.+@.+/)) {
		return undef;
	}
	my $id_user_level = getIdUserLevel($self,$sLevel);
	if (defined($sPassword) && ($sPassword ne "")) {
		my $sQuery = "INSERT INTO USER (hostmasks,nickname,password,id_user_level) VALUES (?,?,PASSWORD(?),?)";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sHostmask,$sUserHandle,$sPassword,$id_user_level)) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			return undef;
		}
		else {
			my $id_user = $sth->{ mysql_insertid };
			log_message($self,3,"userAdd() Added user : $sUserHandle with hostmask : $sHostmask id_user : $id_user as $sLevel password set : yes");
			return ($id_user);
		}
		$sth->finish;
	}
	else {
		my $sQuery = "INSERT INTO USER (hostmasks,nickname,id_user_level) VALUES (?,?,?)";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sHostmask,$sUserHandle,$id_user_level)) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			return undef;
		}
		else {
			my $id_user = $sth->{ mysql_insertid };
			log_message($self,0,"Added user : $sUserHandle with hostmask : $sHostmask id_user : $id_user as $sLevel password set : no");
			return ($id_user);
		}
		$sth->finish;
	}
}

sub registerChannel(@) {
	my ($self,$message,$sNick,$id_channel,$id_user) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "INSERT INTO USER_CHANNEL (id_user,id_channel,level) VALUES (?,?,500)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_user,$id_channel)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sUserHandle = $tArgs[0];
	my $sPassword = $tArgs[1];
	if (defined($sUserHandle) && ($sUserHandle ne "") && defined($sPassword) && ($sPassword ne "")) {
		if (userCount($self) == 0) {
 			log_message($self,0,$message->prefix . " wants to register");
 			my $sHostmask = getMessageHostmask($self,$message);
 			my $id_user = userAdd($self,$sHostmask,$sUserHandle,$sPassword,"Owner");
 			if (defined($id_user)) {
 				log_message($self,0,"Registered $sUserHandle (id_user : $id_user) as Owner with hostmask $sHostmask");
 				botNotice($self,$sNick,"You just registered as $sUserHandle (id_user : $id_user) as Owner with hostmask $sHostmask");
 				logBot($self,$message,undef,"register","Success");
 				my ($id_channel,$name,$chanmode,$key) = getConsoleChan($self);
 				if (registerChannel($self,$message,$sNick,$id_channel,$id_user)) {
					log_message($self,0,"registerChan successfull $name $sUserHandle");
				}
				else {
					log_message($self,0,"registerChan failed $name $sUserHandle");
				}
 			}
 			else {
 				log_message($self,0,"Register failed for " . $message->prefix);
 			}
 		}
 		else {
 			log_message($self,0,"Register attempt from " . $message->prefix);
 		}
	}
}

sub sayChannel(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && ( $tArgs[0] =~ /^#/)) {
					my (undef,@tArgsTemp) = @tArgs;
					my $sChannelText = join(" ",@tArgsTemp);
					log_message($self,0,"$sNick issued a say command : " . $tArgs[0] . " $sChannelText");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sDumpCommand = join(" ",@tArgs);
					log_message($self,0,"$sNick issued a dump command : $sDumpCommand");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sTarget = $tArgs[0];
					shift @tArgs;
					my $sMsg = join(" ",@tArgs);
					log_message($self,0,"$sNick issued a msg command : $sTarget $sMsg");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && ( $tArgs[0] =~ /^#/)) {
					my (undef,@tArgsTemp) = @tArgs;
					my $sChannelText = join(" ",@tArgsTemp);
					log_message($self,0,"$sNick issued a act command : " . $tArgs[0] . "ACTION $sChannelText");
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

sub mbStatus(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				# Bot Uptime
				my $iUptime = time - $self->{iConnectionTimestamp};
				my $days = int($iUptime / 86400);
				my $hours = int(($iUptime - ( $days * 86400 )) / 3600);
				$hours = sprintf("%02d",$hours);
				my $minutes = int(($iUptime - ( $days * 86400 ) - ( $hours * 3600 )) / 60);
				$minutes = sprintf("%02d",$minutes);
				my $seconds = int($iUptime - ( $days * 86400 ) - ( $hours * 3600 ) - ( $minutes * 60 ));
				$seconds = sprintf("%02d",$seconds);
				log_message($self,3,"days = $days hours = $hours minutes = $minutes seconds = $seconds");
				#my $sUptimeStr = ($days > 0 ? "$days days, " : "") . (int($hours) > 0 ? ("$hours" . "h ") : "") . (int($minutes > 0 ? ("$minutes" . "mn") : "")) . "$seconds" . "s";
				my $sUptimeStr;
				if ($days > 0) {
					$sUptimeStr .= "$days days, ";
				}
				if (int($hours) > 0) {
					$sUptimeStr .= "$hours" . "h ";
				}
				if (int($minutes) > 0) {
					$sUptimeStr .= "$minutes" . "mn ";
				}
				$sUptimeStr .= "$seconds" . "s";
				
				unless (defined($sUptimeStr)) {
					$sUptimeStr = "Unknown";
				}
				
				# Server Uptime
				my $sUptime = "Unknown";
				unless (open LOAD, "uptime |") {
					log_message($self,0,"Could not exec uptime command");
				}
				else {
					my $line;
					if (defined($line=<LOAD>)) {
						chomp($line);
						$sUptime = $line;
					}
				}
				
				# Server type
				my $sUname = "Unknown";
				unless (open UNAME, "uname -a |") {
					log_message($self,0,"Could not exec uptime command");
				}
				else {
					my $line;
					if (defined($line=<UNAME>)) {
						chomp($line);
						$sUname = $line;
					}
				}
				
				# Memory usage
				my $mu = Memory::Usage->new();
				$mu->record('Memory stats');

				my @tMemStateResultsArrayRef = $mu->state();
				my @tMemStateResults = $tMemStateResultsArrayRef[0][0];
				
				my ($iTimestamp,$sMessage,$fVmSize,$fResSetSize,$fSharedMemSize,$sCodeSize,$fDataStackSize);
				if (defined($tMemStateResults[0][0]) && ($tMemStateResults[0][0] ne "")) {
					$iTimestamp = $tMemStateResults[0][0];
				}
				if (defined($tMemStateResults[0][1]) && ($tMemStateResults[0][1] ne "")) {
					$sMessage = $tMemStateResults[0][1];
				}
				if (defined($tMemStateResults[0][2]) && ($tMemStateResults[0][2] ne "")) {
					$fVmSize = $tMemStateResults[0][2];
					$fVmSize = $fVmSize / 1024;
					$fVmSize = sprintf("%.2f",$fVmSize);
				}
				if (defined($tMemStateResults[0][3]) && ($tMemStateResults[0][3] ne "")) {
					$fResSetSize = $tMemStateResults[0][3];
					$fResSetSize = $fResSetSize / 1024;
					$fResSetSize = sprintf("%.2f",$fResSetSize);
				}
				if (defined($tMemStateResults[0][4]) && ($tMemStateResults[0][4] ne "")) {
					$fSharedMemSize = $tMemStateResults[0][4];
					$fSharedMemSize = $fSharedMemSize / 1024;
					$fSharedMemSize = sprintf("%.2f",$fSharedMemSize);
				}
				if (defined($tMemStateResults[0][5]) && ($tMemStateResults[0][5] ne "")) {
					$sCodeSize = $tMemStateResults[0][5];
				}
				if (defined($tMemStateResults[0][6]) && ($tMemStateResults[0][6] ne "")) {
					$fDataStackSize = $tMemStateResults[0][6];
					$fDataStackSize = $fDataStackSize / 1024;
					$fDataStackSize = sprintf("%.2f",$fDataStackSize);
				
				}
				
				botNotice($self,$sNick,$MAIN_CONF{'main.MAIN_PROG_NAME'} . " v" . $self->{main_prog_version} . " Uptime : $sUptimeStr");
				botNotice($self,$sNick,"Memory usage (VM $fVmSize MB) (Resident Set $fResSetSize MB) (Shared Memory $fSharedMemSize MB) (Data and Stack $fDataStackSize MB)");
				botNotice($self,$sNick,"Server : $sUname");
				botNotice($self,$sNick,"Server's uptime : $sUptime");
				logBot($self,$message,undef,"status",undef);
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

sub setConnectionTimestamp(@) {
	my ($self,$iConnectionTimestamp) = @_;
	$self->{iConnectionTimestamp} = $iConnectionTimestamp;
}

sub getConnectionTimestamp(@) {
	my $self = shift;
	return $self->{iConnectionTimestamp};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
				    	log_message($self,3,"Timer every $iFrequency seconds : $sRaw");
    					$self->{irc}->write("$sRaw\x0d\x0a");
 						},
					);
					$hTimers{$sTimerName} = $timer;
					$self->{loop}->add( $timer );
					$timer->start;
					my $sQuery = "INSERT INTO TIMERS (name,duration,command) VALUES (?,?,?)";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sTimerName,$iFrequency,$sRaw)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
		if (defined($iMatchingUserId) && (defined($sMatchingUserHandle))) {
			my $sQuery = "UPDATE USER SET password=PASSWORD(?) WHERE id_user=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($tArgs[0],$iMatchingUserId)) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				$sth->finish;
				return 0;
			}
			else {
				log_message($self,3,"userPass() Set password for $sNick id_user : $iMatchingUserId (" . $message->prefix . ")");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
			log_message($self,0,$sNoticeMsg);
			noticeConsoleChan($self,$sNoticeMsg);
			logBot($self,$message,undef,"ident",$sNoticeMsg);
		}
	}
}

sub checkAuthByUser(@) {
	my ($self,$message,$sUserHandle,$sPassword) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sCheckAuthQuery = "SELECT * FROM USER WHERE nickname=? AND password=PASSWORD(?)";
	my $sth = $self->{dbh}->prepare($sCheckAuthQuery);
	unless ($sth->execute($sUserHandle,$sPassword)) {
		log_message($self,1,"checkAuthByUser() SQL Error : " . $DBI::errstr . " Query : " . $sCheckAuthQuery);
		$sth->finish;
		return 0;
	}
	else {	
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sHostmask = getMessageHostmask($self,$message);
			log_message($self,3,"checkAuthByUser() Hostmask : $sHostmask to add to $sUserHandle");
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
					log_message($self,1,"checkAuthByUser() SQL Error : " . $DBI::errstr . " Query : " . $Query);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my $sGetAuthUsers = "SELECT nickname,description,level FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND auth=1 ORDER by level";
				my $sth = $self->{dbh}->prepare($sGetAuthUsers);
				unless ($sth->execute) {
					log_message($self,1,"userCstat() SQL Error : " . $DBI::errstr . " Query : " . $sGetAuthUsers);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,3,"addUser() " . $tArgs[0] . " " . $tArgs[1]);
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
						log_message($self,0,"addUser() id_user : $id_user " . $tArgs[0] . " Hostmask : " . $tArgs[1] . " (Level:" . $sLevel . ")");
						noticeConsoleChan($self,"Added user " . $tArgs[0] . " id_user : $id_user with hostmask " . $tArgs[1] . " (Level:" . $sLevel .")");
						botNotice($self,$sNick,"Added user " . $tArgs[0] . " id_user : $id_user with hostmask " . $tArgs[1] . " (Level:" . $sLevel .")");
						if ( $bNotify ) {
							botNotice($self,$tArgs[0],"You've been added to " . $self->{irc}->nick_folded . " as user " . $tArgs[0] . " (Level : " . $sLevel . ")");
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sQuery="SELECT count(*) as nbUsers FROM USER";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sNoticeMsg = "Numbers of users : ";
					if (my $ref = $sth->fetchrow_hashref()) {
						my $nbUsers = $ref->{'nbUsers'};
						$sNoticeMsg .= "$nbUsers - ";
						$sQuery="SELECT description,count(nickname) as nbUsers FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level GROUP BY description ORDER BY level";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						my $sQuery = "SELECT * FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND nickname LIKE ?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							log_message($self,1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								botNotice($self,$sNick,"User : $sUser (Id: $id_user - $sDescription) - created $creation_date - last login $last_login");
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
							log_message($self,0,$sNoticeMsg);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					log_message($self,3,"addUserHost() " . $tArgs[0] . " " . $tArgs[1]);
					my $id_user = getIdUser($self,$tArgs[0]);
					unless (defined($id_user)) {
						botNotice($self,$sNick,"User " . $tArgs[0] . " does not exists");
						logBot($self,$message,undef,"addhost","User " . $tArgs[0] . " does not exists");
						return undef;
					}
					else {
						my $sSearch = $tArgs[1];
						$sSearch =~ s/;//g;
						my $sQuery = "SELECT nickname FROM USER WHERE hostmasks LIKE '%" . $sSearch . "%'";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							log_message($self,1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $sUser = $ref->{'nickname'};
								my $sNoticeMsg = $message->prefix . " Hostmask " . $tArgs[1] . " already exist for user for user $sUser";
								log_message($self,0,$sNoticeMsg);
								noticeConsoleChan($self,$sNoticeMsg);
								logBot($self,$message,undef,"addhost",$sNoticeMsg);
							}
							else {
								$sQuery = "SELECT hostmasks FROM USER WHERE id_user=?";
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($id_user)) {
									log_message($self,1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									my $sHostmasks = "";
									if (my $ref = $sth->fetchrow_hashref()) {
										$sHostmasks = $ref->{'hostmasks'};
									}
									$sQuery = "UPDATE USER SET hostmasks=? WHERE id_user=?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($sHostmasks . "," . $tArgs[1],$id_user)) {
										log_message($self,1,"addUserHost() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										my $sNoticeMsg = $message->prefix . " Hostmask " . $tArgs[1] . " added for user " . $tArgs[0];
										log_message($self,0,$sNoticeMsg);
										noticeConsoleChan($self,$sNoticeMsg);
										logBot($self,$message,undef,"addhost",$sNoticeMsg);
									}
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
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/) && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sChannel = $tArgs[0];
					my $sUser = $tArgs[1];
					log_message($self,0,"$sNick issued an addchan command $sChannel $sUser");
					my $id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel)) {
						my $id_user = getIdUser($self,$sUser);
						if (defined($id_user)) {
							my $sQuery = "INSERT INTO CHANNEL (name,description,auto_join) VALUES (?,?,1)";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sChannel,$sChannel)) {
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								$sth->finish;
								return undef;
							}
							else {
								my $id_channel = $sth->{ mysql_insertid };
								log_message($self,3,"addChannel() Added channel : $sChannel id_channel : $id_channel");
								my $sNoticeMsg = $message->prefix . " addchan command $sMatchingUserHandle added $sChannel (id_channel : $id_channel)";
								noticeConsoleChan($self,$sNoticeMsg);
								logBot($self,$message,undef,"addchan",($sChannel,@tArgs));
								joinChannel($self,$sChannel,undef);
								if (registerChannel($self,$message,$sNick,$id_channel,$id_user)) {
									log_message($self,0,"registerChannel successfull $sChannel $sUser");
								}
								else {
									log_message($self,0,"registerChannel failed $sChannel $sUser");
								}
								$sth->finish;
								return $id_channel;
							}
						}
						else {
							botNotice($self,$sNick,"User $sUser does not exist");
							return undef;
						}
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel already exists");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: addchan <#channel> <user>");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " addchan command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addchan command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub channelSet(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				channelSetSyntax($self,$message,$sNick,@tArgs);
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,450))) {	
				if ( (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) || (defined($tArgs[0]) && ($tArgs[0] ne "") && ((substr($tArgs[0],0,1) eq "+") || (substr($tArgs[0],0,1) eq "-"))) ) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						switch($tArgs[0]) {
							case "key"					{
																		my $sQuery = "UPDATE CHANNEL SET `key`=? WHERE id_channel=?";
																		my $sth = $self->{dbh}->prepare($sQuery);
																		unless ($sth->execute($tArgs[1],$id_channel)) {
																			log_message($self,1,"channelSet() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																			$sth->finish;
																			return undef;
																		}
																		botNotice($self,$sNick,"Set $sChannel key " . $tArgs[1]);
																		logBot($self,$message,$sChannel,"chanset",($sChannel,@tArgs));
																		$sth->finish;
																		return $id_channel;
																	}
							case "chanmode"			{
																		my $sQuery = "UPDATE CHANNEL SET chanmode=? WHERE id_channel=?";
																		my $sth = $self->{dbh}->prepare($sQuery);
																		unless ($sth->execute($tArgs[1],$id_channel)) {
																			log_message($self,1,"channelSet() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																			$sth->finish;
																			return undef;
																		}
																		botNotice($self,$sNick,"Set $sChannel chanmode " . $tArgs[1]);
																		logBot($self,$message,$sChannel,"chanset",($sChannel,@tArgs));
																		$sth->finish;
																		return $id_channel;
																	}
							case "auto_join"		{
																		my $bAutoJoin;
																		if ( $tArgs[1] =~ /on/i ) {
																			$bAutoJoin = 1;
																		}
																		elsif ( $tArgs[1] =~ /off/i ) {
																			$bAutoJoin = 0;
																		}
																		else {
																			channelSetSyntax($self,$message,$sNick,@tArgs);
																			return undef;
																		}
																		my $sQuery = "UPDATE CHANNEL SET auto_join=? WHERE id_channel=?";
																		my $sth = $self->{dbh}->prepare($sQuery);
																		unless ($sth->execute($bAutoJoin,$id_channel)) {
																			log_message($self,1,"channelSet() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																			$sth->finish;
																			return undef;
																		}
																		botNotice($self,$sNick,"Set $sChannel auto_join " . $tArgs[1]);
																		logBot($self,$message,$sChannel,"chanset",($sChannel,@tArgs));
																		$sth->finish;
																		return $id_channel;
																	}
							case "description"	{
																		shift @tArgs;
																		unless ( $tArgs[0] =~ /console/i ) {
																			my $sQuery = "UPDATE CHANNEL SET description=? WHERE id_channel=?";
																			my $sth = $self->{dbh}->prepare($sQuery);
																			unless ($sth->execute(join(" ",@tArgs),$id_channel)) {
																				log_message($self,1,"channelSet() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																				$sth->finish;
																				return undef;
																			}
																			botNotice($self,$sNick,"Set $sChannel description " . join(" ",@tArgs));
																			logBot($self,$message,$sChannel,"chanset",($sChannel,"description",@tArgs));
																			$sth->finish;
																			return $id_channel;
																		}
																		else {
																			botNotice($self,$sNick,"You cannot set $sChannel description to " . $tArgs[0]);
																			logBot($self,$message,$sChannel,"chanset",("You cannot set $sChannel description to " . $tArgs[0]));
																		}
																	}
							else								{
																		if ((substr($tArgs[0],0,1) eq "+") || (substr($tArgs[0],0,1) eq "-")){
																			my $sChansetValue = substr($tArgs[0],1);
																			my $sChansetAction = substr($tArgs[0],0,1);
																			log_message($self,0,"chanset $sChannel $sChansetAction$sChansetValue");
																			my $id_chanset_list = getIdChansetList($self,$sChansetValue);
																			unless (defined($id_chanset_list) && ($id_chanset_list ne "")) {
																				botNotice($self,$sNick,"Undefined chanset $sChansetValue");
																				logBot($self,$message,$sChannel,"chanset",($sChannel,"Undefined chanset $sChansetValue"));
																				return undef;
																			}
																			my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
																			if ( $sChansetAction eq "+" ) {
																				if (defined($id_channel_set)) {
																					botNotice($self,$sNick,"Chanset +$sChansetValue is already set for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Chanset +$sChansetValue is already set"));
																					return undef;
																				}
																				my $sQuery = "INSERT INTO CHANNEL_SET (id_channel,id_chanset_list) VALUES (?,?)";
																				my $sth = $self->{dbh}->prepare($sQuery);
																				unless ($sth->execute($id_channel,$id_chanset_list)) {
																					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																				}
																				else {
																					botNotice($self,$sNick,"Chanset +$sChansetValue for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Chanset +$sChansetValue"));
																					if ($sChansetValue =~ /^AntiFlood$/i) {
																						setChannelAntiFlood($self,$message,$sNick,$sChannel,@tArgs);
																					}
																					elsif ($sChansetValue =~ /^HailoChatter$/i) {
																						# TBD : check old ratio
																						set_hailo_channel_ratio($self,$sChannel,97);
																					}
																				}
																				$sth->finish;
																				return $id_channel;
																			}
																			else {
																				unless (defined($id_channel_set)) {
																					botNotice($self,$sNick,"Chanset +$sChansetValue is not set for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Chanset +$sChansetValue is not set"));
																					return undef;
																				}
																				my $sQuery = "DELETE FROM CHANNEL_SET WHERE id_channel_set=?";
																				my $sth = $self->{dbh}->prepare($sQuery);
																				unless ($sth->execute($id_channel_set)) {
																					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																				}
																				else {
																					botNotice($self,$sNick,"Chanset -$sChansetValue for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Chanset -$sChansetValue"));
																				}
																				$sth->finish;
																				return $id_channel;
																			}
																			
																		}
																		else {
																			channelSetSyntax($self,$message,$sNick,@tArgs);
																			return undef;
																		}
																	}
						}
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					channelSetSyntax($self,$message,$sNick,@tArgs);
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " chanset command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " chanset command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $id_chanset_list;
	my $sQuery = "SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChansetValue) ) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $id_channel_set;
	my $sQuery = "SELECT id_channel_set FROM CHANNEL_SET,CHANNEL WHERE CHANNEL_SET.id_channel=CHANNEL.id_channel AND name=? AND id_chanset_list=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_chanset_list) ) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_channel_set = $ref->{'id_channel_set'};
		}
	}
	$sth->finish;
	return $id_channel_set;
}

sub purgeChannel(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					my $sChannel = $tArgs[0];
					log_message($self,0,"$sNick issued an purge command $sChannel");
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						my $sQuery = "SELECT * FROM CHANNEL WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_channel)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $sDecription = $ref->{'description'};
								my $sKey = $ref->{'key'};
								my $sChanmode = $ref->{'chanmode'};
								my $bAutoJoin = $ref->{'auto_join'};
								$sQuery = "DELETE FROM CHANNEL WHERE id_channel=?";
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($id_channel)) {
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									$sth->finish;
									return undef;
								}
								else {
									log_message($self,0,"Deleted channel $sChannel id_channel : $id_channel");
									$sQuery = "DELETE FROM USER_CHANNEL WHERE id_channel=?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_channel)) {
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
										$sth->finish;
										return undef;
									}
									else {
										log_message($self,0,"Deleted channel access for $sChannel id_channel : $id_channel");
										$sQuery = "INSERT INTO CHANNEL_PURGED (id_channel,name,description,`key`,chanmode,auto_join) VALUES (?,?,?,?,?,?)";
										$sth = $self->{dbh}->prepare($sQuery);
										unless ($sth->execute($id_channel,$sChannel,$sDecription,$sKey,$sChanmode,$bAutoJoin)) {
											log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
											$sth->finish;
											return undef;
										}
										else {
											log_message($self,0,"Added $sChannel id_channel : $id_channel to CHANNEL_PURGED");
											partChannel($self,$sChannel,"Channel purged by $sNick");
											logBot($self,$message,undef,"purge","$sNick purge $sChannel id_channel : $id_channel");
										}
									}
								}
							}
							else {
								$sth->finish;
								return undef;
							}
						}
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: purge <#channel>");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " purge command attempt (command level [Administrator] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " purge command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub partChannel(@) {
	my ($self,$channel,$sPartMsg) = @_;
	if (defined($sPartMsg) && ($sPartMsg ne "")) {
		log_message($self,0,"Parting $channel $sPartMsg");
		$self->{irc}->send_message("PART", undef, ($channel,$sPartMsg));
	}
	else {
		log_message($self,0,"Parting $channel");
		$self->{irc}->send_message("PART", undef,$channel);
	}
}

sub channelPart(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (!defined($sChannel) || (defined($tArgs[0]) && ($tArgs[0] ne ""))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					shift @tArgs;
				}
				else {
					botNotice($self,$sNick,"Syntax: part <#channel>");
					return undef;
				}
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,500))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					log_message($self,0,"$sNick issued a part $sChannel command");
					partChannel($self,$sChannel,"At the request of $sMatchingUserHandle");
					logBot($self,$message,$sChannel,"part","At the request of $sMatchingUserHandle");
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " part command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " part command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub checkUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user,$level) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT level FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub channelJoin(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				my $sChannel = $tArgs[0];
				shift @tArgs;
				if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,450))) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a join $sChannel command");
						my $sKey;
						my $sQuery = "SELECT `key` FROM CHANNEL WHERE id_channel=?";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_channel)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								$sKey = $ref->{'key'};
							}
						}
						if (defined($sKey) && ($sKey ne "")) {
							joinChannel($self,$sChannel,$sKey);
						}
						else {
							joinChannel($self,$sChannel,undef);
						}
						logBot($self,$message,$sChannel,"join","");
						$sth->finish;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					my $sNoticeMsg = $message->prefix . " join command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
					noticeConsoleChan($self,$sNoticeMsg);
					botNotice($self,$sNick,"Your level does not allow you to use this command.");
					return undef;
				}
			}
			else {
				botNotice($self,$sNick,"Syntax: join <#channel>");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " join command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub channelAddUser(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: add <#channel> <handle> <level>");
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,400))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] =~ /[0-9]+/)) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a add user $sChannel command");
						my $sUserHandle = $tArgs[0];
						my $iLevel = $tArgs[1];
						my $id_user = getIdUser($self,$tArgs[0]);
						if (defined($id_user)) {
							my $iCheckUserLevel = getUserChannelLevel($self,$message,$sChannel,$id_user);
							if ( $iCheckUserLevel == 0 ) {
								if ( $iLevel < getUserChannelLevel($self,$message,$sChannel,$iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
									my $sQuery = "INSERT INTO USER_CHANNEL (id_user,id_channel,level) VALUES (?,?,?)";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_user,$id_channel,$iLevel)) {
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										logBot($self,$message,$sChannel,"add",@tArgs);
									}
									$sth->finish;
								}
								else {
									botNotice($self,$sNick,"You can't add a user with a level equal or greater than yours");
								}
							}
							else {
								botNotice($self,$sNick,"User $sUserHandle on $sChannel already added at level $iCheckUserLevel");
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
					botNotice($self,$sNick,"Syntax: add <#channel> <handle> <level>");
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " add user command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " add user command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
		}
	}
}

sub getUserChannelLevel(@) {
	my ($self,$message,$sChannel,$id_user) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT level FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND id_user=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$id_user)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,0,"$sNick issued a del user $sChannel command");
						my $sUserHandle = $tArgs[0];
						my $id_user = getIdUser($self,$tArgs[0]);
						if (defined($id_user)) {
							my $iCheckUserLevel = getUserChannelLevel($self,$message,$sChannel,$id_user);
							if ( $iCheckUserLevel != 0 ) {
								if ( $iCheckUserLevel < getUserChannelLevel($self,$message,$sChannel,$iMatchingUserId) || checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
									my $sQuery = "DELETE FROM USER_CHANNEL WHERE id_user=? AND id_channel=?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_user,$id_channel)) {
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub userModinfoSyntax(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	botNotice($self,$sNick,"Syntax: modinfo [#channel] automode <user> <voice|op|none>");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] greet <user> <greet> (use keyword \"none\" for <greet> to remove it)");
	botNotice($self,$sNick,"Syntax: modinfo [#channel] level <user> <level>");
}

sub userModinfo(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				userModinfoSyntax($self,$message,$sNick,@tArgs);
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,400) || ( ($tArgs[0] =~ /^greet$/i) && ( checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,1))) )) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "") && defined($tArgs[2]) && ($tArgs[2] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						my ($id_user,$level) = getIdUserChannelLevel($self,$tArgs[1],$sChannel);
						if (defined($id_user)) {
							my (undef,$iMatchingUserLevelChannel) = getIdUserChannelLevel($self,$sMatchingUserHandle,$sChannel);
							if (($iMatchingUserLevelChannel > $level) || (checkUserLevel($self,$iMatchingUserLevel,"Administrator")) || ( ($tArgs[0] =~ /^greet$/i) && ( $iMatchingUserLevelChannel > 0)) ) {
								switch($tArgs[0]) {
									case "automode"			{
																				my $sAutomode = $tArgs[2];
																				if ( ($sAutomode =~ /op/i ) || ($sAutomode =~ /voice/i) || ($sAutomode =~ /none/i)) {
																					$sAutomode = uc($sAutomode);
																					my $sQuery = "UPDATE USER_CHANNEL SET automode=? WHERE id_user=? AND id_channel=?";
																					my $sth = $self->{dbh}->prepare($sQuery);
																					unless ($sth->execute($sAutomode,$id_user,$id_channel)) {
																						log_message($self,1,"userModinfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																						$sth->finish;
																						return undef;
																					}
																					botNotice($self,$sNick,"Set automode $sAutomode on $sChannel for " . $tArgs[1]);
																					logBot($self,$message,$sChannel,"modinfo",@tArgs);
																					$sth->finish;
																					return $id_channel;
																												}
																					
																				else {
																					userModinfoSyntax($self,$message,$sNick,@tArgs);
																					return undef;
																				}
																			}
									case "greet"				{
																				my $sUser = $tArgs[1];
																				if ( (($iMatchingUserLevelChannel < 400) && ( $sUser ne $sMatchingUserHandle)) && (!checkUserLevel($self,$iMatchingUserLevel,"Administrator"))) {
																					botNotice($self,$sNick,"Your level does not allow you to perfom this command.");
																				}
																				splice @tArgs,0,2;
																				my $sGreet;
																				# Check remove keyword "none"
																				unless (( $tArgs[0] =~ /none/i ) && ($#tArgs == 0)) {
																					$sGreet = join(" ",@tArgs);
																				}
																				my $sQuery = "UPDATE USER_CHANNEL SET greet=? WHERE id_user=? AND id_channel=?";
																				my $sth = $self->{dbh}->prepare($sQuery);
																				unless ($sth->execute($sGreet,$id_user,$id_channel)) {
																					log_message($self,1,"userModinfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																					$sth->finish;
																					return undef;
																				}
																				botNotice($self,$sNick,"Set greet ($sGreet) on $sChannel for $sUser");
																				logBot($self,$message,$sChannel,"modinfo",("greet $sUser",@tArgs));
																				$sth->finish;
																				return $id_channel;
																			}
									case "level"				{
																				my $sUser = $tArgs[1];
																				if ( $tArgs[2] =~ /[0-9]+/ ) {
																					if ( $tArgs [2] <= 500 ) {
																						my $sQuery = "UPDATE USER_CHANNEL SET level=? WHERE id_user=? AND id_channel=?";
																						my $sth = $self->{dbh}->prepare($sQuery);
																						unless ($sth->execute($tArgs[2]	,$id_user,$id_channel)) {
																							log_message($self,1,"userModinfo() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																							$sth->finish;
																							return undef;
																						}
																						botNotice($self,$sNick,"Set level " . $tArgs[2] . " on $sChannel for $sUser");
																						logBot($self,$message,$sChannel,"modinfo",@tArgs);
																						$sth->finish;
																						return $id_channel;
																					}
																					else {
																						botNotice($self,$sNick,"Cannot set user access higher than 500.");
																					}
																				}
																				else {
																					userModinfoSyntax($self,$message,$sNick,@tArgs);
																					return undef;
																				}
																			}
									else								{
																				userModinfoSyntax($self,$message,$sNick,@tArgs);
																				return undef;
																			}
								}
							}
							else {
								botNotice($self,$sNick,"Cannot modify a user with equal or higher access than your own.");
							}
						}
						else {
							botNotice($self,$sNick,"User " . $tArgs[1] . " does not exist on $sChannel");
							return undef;
						}
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					userModinfoSyntax($self,$message,$sNick,@tArgs);
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " modinfo command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " modinfo command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub getIdUserChannelLevel(@) {
	my ($self,$sUserHandle,$sChannel) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT USER.id_user,USER_CHANNEL.level FROM CHANNEL,USER,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER.id_user=USER_CHANNEL.id_user AND USER.nickname=? AND CHANNEL.name=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle,$sChannel)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user = $ref->{'id_user'};
			my $level = $ref->{'level'};
			log_message($self,3,"getIdUserChannelLevel() $id_user $level");
			$sth->finish;
			return ($id_user,$level);
		}
		else {
			$sth->finish;
			return (undef,undef);
		}
	}
}

sub userOpChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: op #channel <nick>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,100))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						$self->{irc}->send_message("MODE",undef,($sChannel,"+o",$tArgs[0]));
					}
					else {
						$self->{irc}->send_message("MODE",undef,($sChannel,"+o",$sNick));
					}
					logBot($self,$message,$sChannel,"op",@tArgs);
					return $id_channel;
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " op command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " op command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userDeopChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: deop #channel <nick>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,100))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						$self->{irc}->send_message("MODE",undef,($sChannel,"-o",$tArgs[0]));
					}
					else {
						$self->{irc}->send_message("MODE",undef,($sChannel,"-o",$sNick));
					}
					logBot($self,$message,$sChannel,"deop",@tArgs);
					return $id_channel;
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " deop command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " deop command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userInviteChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: invite #channel <nick>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,100))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						$self->{irc}->send_message("INVITE",undef,($tArgs[0],$sChannel));
					}
					else {
						$self->{irc}->send_message("INVITE",undef,($sNick,$sChannel));
					}
					logBot($self,$message,$sChannel,"invite",@tArgs);
					return $id_channel;
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " invite command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " invite command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userVoiceChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: voice #channel <nick>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,25))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						$self->{irc}->send_message("MODE",undef,($sChannel,"+v",$tArgs[0]));
					}
					else {
						$self->{irc}->send_message("MODE",undef,($sChannel,"+v",$sNick));
					}
					logBot($self,$message,$sChannel,"voice",@tArgs);
					return $id_channel;
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " voice command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " voice command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userDevoiceChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: devoice #channel <nick>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,25))) {
				my $id_channel = getIdChannel($self,$sChannel);
				if (defined($id_channel)) {
					if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
						$self->{irc}->send_message("MODE",undef,($sChannel,"-v",$tArgs[0]));
					}
					else {
						$self->{irc}->send_message("MODE",undef,($sChannel,"-v",$sNick));
					}
					logBot($self,$message,$sChannel,"devoice",@tArgs);
					return $id_channel;
				}
				else {
					botNotice($self,$sNick,"Channel $sChannel does not exist");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " devoice command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " devoice command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userKickChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: kick #channel <nick> [reason]");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,50))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a kick $sChannel command");
						my $sKickNick = $tArgs[0];
						shift @tArgs;
						my $sKickReason = join(" ",@tArgs);
						$self->{irc}->send_message("KICK",undef,($sChannel,$sKickNick,"($sMatchingUserHandle) $sKickReason"));
						logBot($self,$message,$sChannel,"kick",($sKickNick,@tArgs));
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: kick #channel <nick> [reason]");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " kick command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " kick command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userTopicChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
				$sChannel = $tArgs[0];
				shift @tArgs;
			}
			unless (defined($sChannel)) {
				botNotice($self,$sNick,"Syntax: topic #channel <topic>");
				return undef;
			}
			if (defined($iMatchingUserLevel) && ( checkUserLevel($self,$iMatchingUserLevel,"Administrator") || checkUserChannelLevel($self,$message,$sChannel,$iMatchingUserId,50))) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a topic $sChannel command");
						$self->{irc}->send_message("TOPIC",undef,($sChannel,join(" ",@tArgs)));
						logBot($self,$message,$sChannel,"topic",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: topic #channel <topic>");
					return undef;
				}
			}
			else {
				my $sNoticeMsg = $message->prefix . " topic command attempt for user " . $sMatchingUserHandle . " [" . $iMatchingUserLevelDesc ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " topic command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}
}

sub userShowcommandsChannel(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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

sub userChannelInfo(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
		$sChannel = $tArgs[0];
		shift @tArgs;
	}
	unless (defined($sChannel)) {
		botNotice($self,$sNick,"Syntax: chaninfo #channel");
		return undef;
	}
	my $sQuery = "SELECT * FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND level=500";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sUsername = $ref->{'nickname'};
			my $sLastLogin = $ref->{'last_login'};
			my $creation_date = $ref->{'creation_date'};
			my $description = $ref->{'description'};
			my $sKey = $ref->{'key'};
			$sKey = ( defined($sKey) ? $sKey : "Not set" );
			my $chanmode = $ref->{'chanmode'};
			$chanmode = ( defined($chanmode) ? $chanmode : "Not set" );
			my $sAutoJoin = $ref->{'auto_join'};
			$sAutoJoin = ( $sAutoJoin ? "True" : "False" );
			unless(defined($sLastLogin) && ($sLastLogin ne "")) {
				$sLastLogin = "Never";
			}
			botNotice($self,$sNick,"$sChannel is registered by $sUsername - last login: $sLastLogin");
			botNotice($self,$sNick,"Creation date : $creation_date - Description : $description");
			my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
			if (defined($iMatchingUserId)) {
				if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
					if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
						botNotice($self,$sNick,"Chan modes : $chanmode - Key : $sKey - Auto join : $sAutoJoin");
					}
				}
			}
			$sQuery = "SELECT chanset FROM CHANSET_LIST,CHANNEL_SET,CHANNEL WHERE CHANNEL_SET.id_channel=CHANNEL.id_channel AND CHANNEL_SET.id_chanset_list=CHANSET_LIST.id_chanset_list AND name like ?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($sChannel)) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				my $sChansetFlags = "Channel flags ";
				my $i;
				my $isChansetAntiFlood = 0;
				while (my $ref = $sth->fetchrow_hashref()) {
					my $chanset = $ref->{'chanset'};
					if ( $chanset =~ /AntiFlood/i ) {
						$isChansetAntiFlood = 1;
					}
					$sChansetFlags .= "+$chanset ";
					$i++;
				}
				if ( $i ) {
					botNotice($self,$sNick,$sChansetFlags);
				}
				if ( $isChansetAntiFlood ) {
					my $id_channel = getIdChannel($self,$sChannel);
					$sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
					$sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($id_channel)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
							my $sNotification = ( $notification ? "ON" : "OFF" );
							botNotice($self,$sNick,"Antiflood parameters : $nbmsg_max messages in $duration seconds, wait for $timetowait seconds, notification : $sNotification");
						}
						else {
							botNotice($self,$sNick,"Antiflood parameters : not set ?");
						}
					}
				}
			}
		}
		else {
			botNotice($self,$sNick,"The channel $sChannel doesn't appear to be registered");
		}
		logBot($self,$message,$sChannel,"chaninfo",@tArgs);
	}
	$sth->finish;
}

sub channelList(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $sQuery="SELECT name,count(id_user) as nbUsers FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel GROUP BY name ORDER by creation_date LIMIT 20";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute()) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		my $sNoticeMsg = "User $sMatchingUserHandle ($iMatchingUserLevelDesc)";
		my $sQuery = "SELECT password,hostmasks,creation_date,last_login FROM USER WHERE id_user=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($iMatchingUserId)) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sCategory)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my $sCommand = $tArgs[0];
		my $sQuery = "SELECT hits,id_user,creation_date,action,PUBLIC_COMMANDS_CATEGORY.description as category FROM PUBLIC_COMMANDS,PUBLIC_COMMANDS_CATEGORY WHERE PUBLIC_COMMANDS.id_public_commands_category=PUBLIC_COMMANDS_CATEGORY.id_public_commands_category AND command LIKE ?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sCommand)) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						if (my $ref = $sth->fetchrow_hashref()) {
							my $id_public_commands = $ref->{'id_public_commands'};
							my $id_user = $ref->{'id_user'};
							my $nickname = $ref->{'nickname'};
							$sQuery = "SELECT id_user,nickname FROM USER WHERE nickname LIKE ?";
							$sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($sUsername)) {
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $id_user_new = $ref->{'id_user'};
									$sQuery = "UPDATE PUBLIC_COMMANDS SET id_user=? WHERE id_public_commands=?";
									$sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($id_user_new,$id_public_commands)) {
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
				log_message($self,3,$sQuery);
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel)) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	log_message($self,2,"Check SQL command : $sCommand");
	my $sQuery = "SELECT * FROM PUBLIC_COMMANDS WHERE command like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sCommand)) {
		log_message($self,1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
				log_message($self,1,"mbDbCommand() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				log_message($self,2,"SQL command found : $sCommand description : $description action : $action");
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
					log_message($self,2,"Unknown actionType : $actionType");
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

sub displayBirthDate(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $isPrivate = !defined($sChannel);
	my $sBirthDate = time2str("I was born on %m/%d/%Y at %H:%M:%S.",$MAIN_CONF{'main.MAIN_PROG_BIRTHDATE'});
	my $d = time() - $MAIN_CONF{'main.MAIN_PROG_BIRTHDATE'};
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

	my $runtime = join ", ", @r if @r;
	unless ($isPrivate) {
		botPrivmsg($self,$sChannel,"$sBirthDate I am $runtime old");
	}
	else {
		botNotice($self,$sNick,"$sBirthDate I am $runtime old");
	}
}

sub mbDbMvCommand(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT count(*) as nbCommands FROM PUBLIC_COMMANDS";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $nbTotalCommands = 0;
		if (my $ref = $sth->fetchrow_hashref()) {
			$nbTotalCommands = $ref->{'nbCommands'};
		}
		$sQuery = "SELECT PUBLIC_COMMANDS_CATEGORY.description as sCategory,count(*) as nbCommands FROM PUBLIC_COMMANDS,PUBLIC_COMMANDS_CATEGORY WHERE PUBLIC_COMMANDS.id_public_commands_category=PUBLIC_COMMANDS_CATEGORY.id_public_commands_category GROUP by PUBLIC_COMMANDS_CATEGORY.description";
		$sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT command,hits FROM PUBLIC_COMMANDS ORDER BY hits DESC LIMIT 20";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub mbCountSlaps(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my $sQuery = "SELECT ts,count(ts) as hits FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND CHANNEL.name like ? AND `event_type` LIKE 'action' AND `nick` LIKE ? AND `publictext` LIKE '%slaps%' GROUP BY TO_DAYS(`ts`) ORDER BY ts DESC LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$tArgs[0])) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sNbSlapsMsg = "Slaps count for " . $tArgs[0];
			if (my $ref = $sth->fetchrow_hashref()) {
				my $hits = $ref->{'hits'};
				my $ts = $ref->{'ts'};
				my $sDay = $ts;
				$sDay =~ s/\s+.*$//;
				$sNbSlapsMsg .= " : $hits ($sDay)";
				botPrivmsg($self,$sChannel,$sNbSlapsMsg);
			}
			else {
				$sNbSlapsMsg .= " : None";
				botPrivmsg($self,$sChannel,$sNbSlapsMsg);
			}
			logBot($self,$message,$sChannel,"countslaps",@tArgs);
		}
		$sth->finish;
	}
	else {
		botNotice($self,$sNick,"Syntax : countslaps <nick>");
	}
}

# lastcmd
sub mbLastCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT command FROM PUBLIC_COMMANDS ORDER BY creation_date DESC LIMIT 10";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		my $sCommand = $tArgs[0];
		unless ($sCommand =~ /%/) {
			log_message($self,3,"sCommand : $sCommand");
			my $sSearch = $sCommand;
			$sSearch =~ s/'/\\'/g;
			$sSearch =~ s/;//g;
			my $sQuery = "SELECT * FROM PUBLIC_COMMANDS WHERE action LIKE '%" . $sSearch . "%' ORDER BY command LIMIT 20";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute()) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				my $sResponse;
				while (my $ref = $sth->fetchrow_hashref()) {
					my $command = $ref->{'command'};
					$sResponse .= " $command";
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
	}
	else {
		botNotice($self,$sNick,"Syntax: searchcmd <keyword>");
		return undef;
	}
}

sub mbDbOwnersCommand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT nickname,count(command) as nbCommands FROM PUBLIC_COMMANDS,USER WHERE PUBLIC_COMMANDS.id_user=USER.id_user GROUP by nickname ORDER BY nbCommands DESC";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute()) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sCategory = $tArgs[0];
					my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCategory)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
					my $sCategory = $tArgs[0];
					my $sQuery = "SELECT id_public_commands_category FROM PUBLIC_COMMANDS_CATEGORY WHERE description LIKE ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sCategory)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $iChannelUserLevel = 0;
	my $sQuery = "SELECT level FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND USER_CHANNEL.id_channel=CHANNEL.id_channel AND CHANNEL.name=? AND USER.nickname=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sHandle)) {
		log_message($self,1,"getUserChannelLevelByName() SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			$iChannelUserLevel = $ref->{'level'};
		}
		log_message($self,3,"getUserChannelLevelByName() iChannelUserLevel = $iChannelUserLevel");
	}
	$sth->finish;
	return $iChannelUserLevel;
}

sub getNickInfoWhois(@) {
	my ($self,$sWhoisHostmask) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
		log_message($self,1,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
	}
	else {	
		while (my $ref = $sth->fetchrow_hashref()) {
			my @tHostmasks = split(/,/,$ref->{'hostmasks'});
			foreach my $sHostmask (@tHostmasks) {
				log_message($self,4,"getNickInfoWhois() Checking hostmask : " . $sHostmask);
				$sHostmask =~ s/\./\\./g;
				$sHostmask =~ s/\*/.*/g;
				if ( $sWhoisHostmask =~ /^$sHostmask/ ) {
					log_message($self,3,"getNickInfoWhois() $sHostmask matches " . $sWhoisHostmask);
					$sMatchingUserHandle = $ref->{'nickname'};
					if (defined($ref->{'password'})) {
						$sMatchingUserPasswd = $ref->{'password'};
					}
					$iMatchingUserId = $ref->{'id_user'};
					my $iMatchingUserLevelId = $ref->{'id_user_level'};
					my $sGetLevelQuery = "SELECT * FROM USER_LEVEL WHERE id_user_level=?";
					my $sth2 = $self->{dbh}->prepare($sGetLevelQuery);
	        unless ($sth2->execute($iMatchingUserLevelId)) {
          				log_message($self,0,"getNickInfoWhois() SQL Error : " . $DBI::errstr . " Query : " . $sGetLevelQuery);
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
		log_message($self,3,"getNickInfoWhois() iMatchingUserId : $iMatchingUserId");
	}
	else {
		log_message($self,3,"getNickInfoWhois() iMatchingUserId is undefined with this host : " . $sWhoisHostmask);
		return (undef,undef,undef,undef,undef,undef,undef);
	}
	if (defined($iMatchingUserLevel)) {
		log_message($self,4,"getNickInfoWhois() iMatchingUserLevel : $iMatchingUserLevel");
	}
	if (defined($iMatchingUserLevelDesc)) {
		log_message($self,4,"getNickInfoWhois() iMatchingUserLevelDesc : $iMatchingUserLevelDesc");
	}
	if (defined($iMatchingUserAuth)) {
		log_message($self,4,"getNickInfoWhois() iMatchingUserAuth : $iMatchingUserAuth");
	}
	if (defined($sMatchingUserHandle)) {
		log_message($self,4,"getNickInfoWhois() sMatchingUserHandle : $sMatchingUserHandle");
	}
	if (defined($sMatchingUserPasswd)) {
		log_message($self,4,"getNickInfoWhois() sMatchingUserPasswd : $sMatchingUserPasswd");
	}
	if (defined($sMatchingUserInfo1)) {
		log_message($self,4,"getNickInfoWhois() sMatchingUserInfo1 : $sMatchingUserInfo1");
	}
	if (defined($sMatchingUserInfo2)) {
		log_message($self,4,"getNickInfoWhois() sMatchingUserInfo2 : $sMatchingUserInfo2");
	}
	return ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2);
}

sub userAuthNick(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
				log_message($self,0,"Users on $sChannel : " . join(" ",@{$hChannelsNicks{$sChannel}}));
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sYoutubeId;
	log_message($self,3,"getYoutubeDetails() $sText");
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
		log_message($self,3,"getYoutubeDetails() sYoutubeId = $sYoutubeId");
		my $APIKEY = $MAIN_CONF{'main.YOUTUBE_APIKEY'};
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			log_message($self,0,"getYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			log_message($self,0,"getYoutubeDetails() section [main]");
			log_message($self,0,"getYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}
		unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			log_message(3,"getYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
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
				log_message($self,5,"getYoutubeDetails() $line");
				$i++;
			}
			if (defined($json_details) && ($json_details ne "")) {
				log_message($self,4,"getYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = decode_json $json_details;
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				log_message($self,4,"getYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					log_message($self,4,"getYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					$sTitle = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					log_message($self,3,"getYoutubeDetails() sDuration : $sDuration");
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
					log_message($self,3,"getYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					log_message($self,3,"getYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					log_message($self,3,"getYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					
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
						log_message($self,3,"getYoutubeDetails() one of the youtube field is undef or empty");
						if (defined($sTitle)) {
							log_message($self,3,"getYoutubeDetails() sTitle=$sTitle");
						}
						else {
							log_message($self,3,"getYoutubeDetails() sTitle is undefined");
						}
						
						if (defined($sDuration)) {
							log_message($self,3,"getYoutubeDetails() sDuration=$sDuration");
						}
						else {
							log_message($self,3,"getYoutubeDetails() sDuration is undefined");
						}
						if (defined($sViewCount)) {
							log_message($self,3,"getYoutubeDetails() sViewCount=$sViewCount");
						}
						else {
							log_message($self,3,"getYoutubeDetails() sViewCount is undefined");
						}
					}
				}
				else {
					log_message($self,3,"getYoutubeDetails() Invalid id : $sYoutubeId");
				}
			}
			else {
				log_message($self,3,"getYoutubeDetails() curl empty result for : curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		log_message($self,3,"getYoutubeDetails() sYoutubeId could not be determined");
	}
	return undef;
}

sub displayYoutubeDetails(@) {
	my ($self,$message,$sNick,$sChannel,$sText) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sYoutubeId;
	log_message($self,3,"displayYoutubeDetails() $sText");
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
		log_message($self,3,"displayYoutubeDetails() sYoutubeId = $sYoutubeId");
		my $APIKEY = $MAIN_CONF{'main.YOUTUBE_APIKEY'};
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			log_message($self,0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			log_message($self,0,"displayYoutubeDetails() section [main]");
			log_message($self,0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}
		unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			log_message(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
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
				log_message($self,5,"displayYoutubeDetails() $line");
				$i++;
			}
			if (defined($json_details) && ($json_details ne "")) {
				log_message($self,4,"displayYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = decode_json $json_details;
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				log_message($self,4,"displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					log_message($self,4,"displayYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					$sTitle = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					log_message($self,3,"displayYoutubeDetails() sDuration : $sDuration");
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
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					
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
						botPrivmsg($self,$sChannel,"($sNick) $sMsgSong");
					}
					else {
						log_message($self,3,"displayYoutubeDetails() one of the youtube field is undef or empty");
						if (defined($sTitle)) {
							log_message($self,3,"displayYoutubeDetails() sTitle=$sTitle");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sTitle is undefined");
						}
						
						if (defined($sDuration)) {
							log_message($self,3,"displayYoutubeDetails() sDuration=$sDuration");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sDuration is undefined");
						}
						if (defined($sViewCount)) {
							log_message($self,3,"displayYoutubeDetails() sViewCount=$sViewCount");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sViewCount is undefined");
						}
					}
				}
				else {
					log_message($self,3,"displayYoutubeDetails() Invalid id : $sYoutubeId");
				}
			}
			else {
				log_message($self,3,"displayYoutubeDetails() curl empty result for : curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		log_message($self,3,"displayYoutubeDetails() sYoutubeId could not be determined");
	}
}

sub displayWeather(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message(3,"displayUrlTitle() Could not curl headers from wttr.in");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	log_message($self,3,"displayUrlTitle() $sText");
	my $sContentType;
	my $iHttpResponseCode;
	my $sTextURL = $sText;
	$sTextURL =~ s/^.*http/http/;
	$sTextURL =~ s/\s+.*$//;
	$sText = $sTextURL;
	log_message($self,3,"displayUrlTitle() URL = $sText");
	
	unless ( open URL_HEAD, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:74.0) Gecko/20100101 Firefox/74.0\" --connect-timeout 3 --max-time 3 -L -I -ks \"$sText\" |" ) {
		log_message(3,"displayUrlTitle() Could not curl headers for $sText");
	}
	else {
		my $line;
		my $i = 0;
		while(defined($line=<URL_HEAD>)) {
			chomp($line);
			log_message($self,4,"displayUrlTitle() $line");
			if ( $line =~ /^content\-type/i ) {
				(undef,$sContentType) = split(" ",$line);
				log_message($self,4,"displayUrlTitle() sContentType = $sContentType");
			}
			elsif ( $line =~ /^http/i ) {
				(undef,$iHttpResponseCode) = split(" ",$line);
				log_message($self,4,"displayUrlTitle() iHttpResponseCode = $iHttpResponseCode");
			}
			$i++;
		}
	}
	unless (defined($iHttpResponseCode) && ($iHttpResponseCode eq "200")) {
		log_message($self,3,"displayUrlTitle() Wrong HTTP response code (" . (defined($iHttpResponseCode) ? $iHttpResponseCode : "undefined") .") for $sText " . (defined($iHttpResponseCode) ? $iHttpResponseCode : "Undefined") );
	}
	else {
		unless (defined($sContentType) && ($sContentType =~ /text\/html/i)) {
			log_message($self,3,"displayUrlTitle() Wrong Content-Type for $sText " . (defined($sContentType) ? $sContentType : "Undefined") );
		}
		else {
			log_message($self,3,"displayUrlTitle() iHttpResponseCode = $iHttpResponseCode");
			unless ( open URL_TITLE, "curl -A \"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:74.0) Gecko/20100101 Firefox/74.0\" --connect-timeout 3 --max-time 3 -L -ks \"$sText\" |" ) {
				log_message(0,"displayUrlTitle() Could not curl UrlTitle for $sText");
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
						my $sText = String::IRC->new("URL Title from $sNick:")->grey('black');
						unless (( $title->as_text =~ /annie\s+claude/i ) || ( $title->as_text =~ /annie.claude/i ) || ( $title->as_text =~ /418.*618.*1447/)) {
							botPrivmsg($self,$sChannel,$sText . " " . $title->as_text);
						}
					}
				}
			}
		}
	}
}

sub mbDebug(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $cfg = $self->{cfg};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ($tArgs[0] =~ /[0-9]+/) && ($tArgs[0] <= 5)) {
					$cfg->param("main.MAIN_PROG_DEBUG", $tArgs[0]);
					$cfg->save();
					$self->{cfg} = $cfg;
					$self->{MAIN_CONF} = $cfg->vars();
					log_message($self,0,"Debug set to " . $tArgs[0]);
					botNotice($self,$sNick,"Debug set to " . $tArgs[0]);
					logBot($self,$message,undef,"debug",("Debug set to " . $tArgs[0]));
				}
				else {
					botNotice($self,$sNick,"Syntax: debug <debug_level>");
					botNotice($self,$sNick,"debug_level 0 to 5");
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

sub mbRestart(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				my $iCHildPid;
				if (defined($iCHildPid = fork())) {
					unless ($iCHildPid) {
						log_message($self,0,"Restart request from $sMatchingUserHandle");
						setsid;
						exec "./mb_restart.sh",$tArgs[0];
					}
					else {
						botNotice($self,$sNick,"Restarting bot");
						logBot($self,$message,undef,"restart",($MAIN_CONF{'main.MAIN_PROG_QUIT_MSG'}));
						$self->{Quit} = 1;
						$self->{irc}->send_message( "QUIT", undef, "Restarting" );
					}
				}
				logBot($self,$message,undef,"restart",undef);
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

sub mbJump(@) {
	my ($self,$message,$sNick,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				my $sServer = pop @tArgs;
				my $sFullParams = join(" ",@tArgs);
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					$sFullParams =~ s/\-\-server=[^ ]*//g;
					log_message($self,3,$sFullParams);
					my $iCHildPid;
					if (defined($iCHildPid = fork())) {
						unless ($iCHildPid) {
							log_message($self,0,"Jump request from $sMatchingUserHandle");
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

sub make_colors {
	my ($self,$string) = @_;
	Encode::_utf8_on($string);
	my $newstr = "";
	my $color;
	for (my $c = 0; $c < length($string); $c++) {
		my $char = substr($string, $c, 1);
		if ($char eq ' ') {
			$newstr .= $char;
			next;
		}
		$newstr .= "\003";
		$newstr .= int(rand(100));
		$newstr .= ",";
		$newstr .= int(rand(100));
		$newstr .= $char;
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		# Quit vars from EVENT_LOG
		my $tsQuit;
		my $channelQuit;
		my $msgQuit;
		my $userhostQuit;
		
		my $sQuery = "SELECT * FROM CHANNEL_LOG WHERE nick like ? AND event_type='quit' ORDER BY ts DESC LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($tArgs[0])) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sCommandText;
			if (my $ref = $sth->fetchrow_hashref()) {
				$tsQuit = $ref->{'ts'};
				$channelQuit = $ref->{'name'};
				$msgQuit = $ref->{'publictext'};
				$userhostQuit = $ref->{'userhost'};
				log_message($self,3,"mbSeen() Quit : $tsQuit");
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sCommandText;
			if (my $ref = $sth->fetchrow_hashref()) {
				$tsPart = $ref->{'ts'};
				$channelPart = $ref->{'name'};
				$msgPart = $ref->{'publictext'};
				$userhostPart = $ref->{'userhost'};
				log_message($self,3,"mbSeen() Part : $tsPart");
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sDefaultTZ = 'America/New_York';
	if (defined($tArgs[0])) {
		switch($tArgs[0]) {
			case /^fr$/i { $sDefaultTZ = 'Europe/Paris'; }
			case /^Moscow$/i { $sDefaultTZ = 'Europe/Moscow'; }
			case /^LA$/i { $sDefaultTZ = 'America/Los_Angeles'; }
			else { 	botPrivmsg($self,$sChannel,"Invalid parameter");	
							return undef;
			}
		}
	}
	my $time = DateTime->now( time_zone => $sDefaultTZ );
	botPrivmsg($self,$sChannel,"$sDefaultTZ : " . $time->format_cldr("cccc dd/MM/yyyy HH:mm:ss"));
}

sub checkResponder(@) {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT answer,chance FROM RESPONDERS,CHANNEL WHERE ((CHANNEL.id_channel=RESPONDERS.id_channel AND CHANNEL.name like ?) OR (RESPONDERS.id_channel=0)) AND responder like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sMsg)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sAnswer = $ref->{'answer'};
			my $iChance = $ref->{'chance'};
			log_message($self,4,"checkResponder() Found answer $sAnswer for $sMsg with chance " . (100-$iChance) ." %");
			return $iChance;
		}
	}
	$sth->finish;
	return 100;
}

sub doResponder(@) {
	my ($self,$message,$sNick,$sChannel,$sMsg,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT id_responders,answer,hits FROM RESPONDERS,CHANNEL WHERE ((CHANNEL.id_channel=RESPONDERS.id_channel AND CHANNEL.name like ?) OR (RESPONDERS.id_channel=0)) AND responder like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel,$sMsg)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $sAnswer = $ref->{'answer'};
			my $id_responders = $ref->{'id_responders'};
			my $hits = $ref->{'hits'} + 1;
			my $actionDo = evalAction($self,$message,$sNick,$sChannel,$sMsg,$sAnswer);
			log_message($self,3,"checkResponder() Found answer $sAnswer");
			botPrivmsg($self,$sChannel,$actionDo);
			my $sQuery = "UPDATE RESPONDERS SET hits=? WHERE id_responders=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($hits,$id_responders)) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				log_message($self,3,"$hits hits for $sMsg");
			}
			setLastReponderTs($self,time);
			return 1;
		}
	}
	$sth->finish;
	return 0;
}

sub addResponder(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel;
				my $chance;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel) && ($id_channel ne "")) {
						botNotice($self,$sNick,"$sChannel is not registered to me");
						return undef;
					}
					log_message($self,3,"Adding responder for channel $sChannel($id_channel)");
					shift @tArgs;
				}
				else {
					$id_channel = 0;
					log_message($self,3,"Adding global responder");
				}
				my $sArgs = join(" ",@tArgs);
				unless (defined($sArgs) && ($sArgs ne "")) {
					botNotice($self,$sNick,"Syntax : addresponder [#channel] <chance> <responder> | <answer>");
					return undef;
				}
				
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^[0-9]+/) && ($tArgs[0] <= 100)) {
					$chance = $tArgs[0];
					shift(@tArgs);
				}
				else {
					botNotice($self,$sNick,"Syntax : addresponder [#channel] <chance> <responder> | <answer>");
					return undef;
				}
				
				# Parse @tArgs
				my $i;
				my $j = 0;
				my $sResponder;
				my $sAnswer;
				my $sepFound = 0;
				for ($i=0;$i<=$#tArgs;$i++) {
					if ($sepFound) {
						if ($j==0) {
							$sAnswer = $tArgs[0];
							$j++;
						}
						else {
							$sAnswer .= " " . $tArgs[$i];
						}
					}
					elsif ($tArgs[$i] eq "|") {
						$sepFound = 1;
					}
					else {
						if ($i==0) {
							$sResponder = $tArgs[0];
						}
						else {
							$sResponder .= " " . $tArgs[$i];
						}
					}
				}
				unless ($sepFound && defined($sResponder) && ($sResponder ne "") && defined($sAnswer) && ($sAnswer ne "")) {
					botNotice($self,$sNick,"Syntax : addresponder [#channel] <chance> <responder> | <answer>");
					return undef;
				}
				else {
					log_message($self,3,"chance = $chance sResponder = $sResponder sAnswer = $sAnswer");
				}
				
				my $sQuery = "SELECT * FROM RESPONDERS WHERE id_channel=? AND responder like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_channel,$sResponder)) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $answer = $ref->{'answer'};
						my $iChance = $ref->{'chance'};
						my $hits = $ref->{'hits'};
						log_message($self,3,"addResponder() Found answer $answer for responder $sResponder");
						botNotice($self,$sNick,"Found answer $answer for responder $sResponder with chance $iChance on $sChannel [hits : $hits]");
					}
					else {
						$sQuery = "INSERT INTO RESPONDERS (id_channel,chance,responder,answer) VALUES (?,?,?,?)";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_channel,(100 - $chance),$sResponder,$sAnswer)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $sResponderType;
							if ( $id_channel == 0 ) {
								$sResponderType = "global responder";
							}
							else {
								$sResponderType = "responder for channel $sChannel";
							}
							botNotice($self,$sNick,"Added $sResponderType : $sResponder with chance $chance % -> $sAnswer");
						}
					}
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " addresponder command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " addresponder command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}				
	return 0;
}

sub delResponder(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				my $id_channel;
				my $chance;
				if (defined($tArgs[0]) && ($tArgs[0] ne "") && ( $tArgs[0] =~ /^#/)) {
					$sChannel = $tArgs[0];
					$id_channel = getIdChannel($self,$sChannel);
					unless (defined($id_channel) && ($id_channel ne "")) {
						botNotice($self,$sNick,"$sChannel is not registered to me");
						return undef;
					}
					log_message($self,3,"Deleting responder for channel $sChannel($id_channel)");
					shift @tArgs;
				}
				else {
					$id_channel = 0;
					log_message($self,3,"Deleting global responder");
				}
				my $sResponder = join(" ",@tArgs);
				unless (defined($sResponder) && ($sResponder ne "")) {
					botNotice($self,$sNick,"Syntax : delresponder [#channel] <responder>");
					return undef;
				}
				
				my $sQuery = "SELECT * FROM RESPONDERS WHERE id_channel=? AND responder like ?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_channel,$sResponder)) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sResponderType;
					if ( $id_channel == 0 ) {
						$sResponderType = "global responder";
					}
					else {
						$sResponderType = "responder for channel $sChannel";
					}
					if (my $ref = $sth->fetchrow_hashref()) {
						my $answer = $ref->{'answer'};
						my $iChance = $ref->{'chance'};
						my $hits = $ref->{'hits'};
						log_message($self,3,"delResponder() Found answer $answer for responder $sResponder");
						$sQuery = "DELETE FROM RESPONDERS WHERE id_channel=? AND responder like ?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_channel,$sResponder)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {	
							botNotice($self,$sNick,"Deleted $sResponderType : $sResponder with chance " . (100 - $iChance) . " % -> $answer [hits : $hits]");
						}
					}
					else {
						botNotice($self,$sNick,"Could not find a $sResponderType matching $sResponder");
					}
				}
				$sth->finish;
			}
			else {
				my $sNoticeMsg = $message->prefix . " delresponder command attempt (command level [Master] for user " . $sMatchingUserHandle . "[" . $iMatchingUserLevel ."])";
				noticeConsoleChan($self,$sNoticeMsg);
				botNotice($self,$sNick,"Your level does not allow you to use this command.");
				return undef;
			}
		}
		else {
			my $sNoticeMsg = $message->prefix . " delresponder command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
	}				
	return 0;
}

sub evalAction(@) {
	my ($self,$message,$sNick,$sChannel,$sCommand,$actionDo,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	log_message($self,3,"evalAction() $sCommand / $actionDo");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $id_badwords = $ref->{'id_badwords'};
						my $sBadword = $ref->{'badword'};
						$sQuery = "DELETE FROM BADWORDS WHERE id_badwords=?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_badwords)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sCheckQuery = "SELECT * FROM IGNORES WHERE id_channel=0";
	my $sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute ) {
		log_message($self,1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
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
				log_message($self,4,"isIgnored() (allchans/private) $sHostmask matches " . $message->prefix);
				log_message($self,0,"[IGNORED] " . $ref->{'hostmask'} . " (allchans/private) " . ((substr($sChannel,0,1) eq '#') ? "$sChannel:" : "") . "<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	$sCheckQuery = "SELECT * FROM IGNORES,CHANNEL WHERE IGNORES.id_channel=CHANNEL.id_channel AND CHANNEL.name like ?";
	$sth = $self->{dbh}->prepare($sCheckQuery);
	unless ($sth->execute($sChannel)) {
		log_message($self,1,"isIgnored() SQL Error : " . $DBI::errstr . " Query : " . $sCheckQuery);
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
				log_message($self,4,"isIgnored() $sHostmask matches " . $message->prefix);
				log_message($self,0,"[IGNORED] " . $ref->{'hostmask'} . " $sChannel:<$sNick> $sMsg");
				return 1;
			}
		}
	}
	$sth->finish;
	return 0;
}

sub IgnoresList(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub youtubeSearch(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $id_chanset_list = getIdChansetList($self,"YoutubeSearch");
	if (defined($id_chanset_list) && ($id_chanset_list ne "")) {
		log_message($self,3,"id_chanset_list = $id_chanset_list");
		my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
		unless (defined($id_channel_set) && ($id_channel_set ne "")) {
			return undef;
		}
		else {
			log_message($self,3,"id_channel_set = $id_channel_set");
		}
	}
	else {
		return undef;
	}
	my $sYoutubeId;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"yt <search>");
		return undef;
	}
	my $sText = join("%20",@tArgs);
	log_message($self,3,"youtubeSearch() on $sText");
	my $APIKEY = $MAIN_CONF{'main.YOUTUBE_APIKEY'};
	unless (defined($APIKEY) && ($APIKEY ne "")) {
		log_message($self,0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
		log_message($self,0,"displayYoutubeDetails() section [main]");
		log_message($self,0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
		return undef;
	}
	unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\" |" ) {
		log_message(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
	}
	else {
		my $line;
		my $i = 0;
		my $json_details;
		while(defined($line=<YOUTUBE_INFOS>)) {
			chomp($line);
			$json_details .= $line;
			log_message($self,5,"displayYoutubeDetails() $line");
			$i++;
		}
		if (defined($json_details) && ($json_details ne "")) {
			log_message($self,4,"displayYoutubeDetails() json_details : $json_details");
			my $sYoutubeInfo = decode_json $json_details;
			my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				log_message($self,4,"displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					log_message($self,4,"displayYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					my @tYoutubeId = $hYoutubeItems{'id'};
					my %hYoutubeId = %{$tYoutubeId[0]};
					log_message($self,4,"displayYoutubeDetails() sYoutubeInfo Id : " . Dumper(%hYoutubeId));
					$sYoutubeId = $hYoutubeId{'videoId'};
					log_message($self,4,"displayYoutubeDetails() sYoutubeId : $sYoutubeId");
				}
				else {
					log_message($self,3,"displayYoutubeDetails() Invalid id : $sYoutubeId");
				}
		}
		else {
			log_message($self,3,"displayYoutubeDetails() curl empty result for : curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\"");
		}
	}
	if (defined($sYoutubeId) && ( $sYoutubeId ne "" )) {
		log_message($self,3,"displayYoutubeDetails() sYoutubeId = $sYoutubeId");
		my $APIKEY = $MAIN_CONF{'main.YOUTUBE_APIKEY'};
		unless (defined($APIKEY) && ($APIKEY ne "")) {
			log_message($self,0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
			log_message($self,0,"displayYoutubeDetails() section [main]");
			log_message($self,0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
			return undef;
		}
		unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			log_message(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
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
				log_message($self,5,"displayYoutubeDetails() $line");
				$i++;
			}
			if (defined($json_details) && ($json_details ne "")) {
				log_message($self,4,"displayYoutubeDetails() json_details : $json_details");
				my $sYoutubeInfo = decode_json $json_details;
				my %hYoutubeInfo = %$sYoutubeInfo;
				my @tYoutubeItems = $hYoutubeInfo{'items'};
				my @fTyoutubeItems = @{$tYoutubeItems[0]};
				log_message($self,4,"displayYoutubeDetails() tYoutubeItems length : " . $#fTyoutubeItems);
				# Check items
				if ( $#fTyoutubeItems >= 0 ) {
					my %hYoutubeItems = %{$tYoutubeItems[0][0]};
					log_message($self,4,"displayYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
					$sViewCount = "views $hYoutubeItems{'statistics'}{'viewCount'}";
					$sTitle = $hYoutubeItems{'snippet'}{'localized'}{'title'};
					$sDuration = $hYoutubeItems{'contentDetails'}{'duration'};
					log_message($self,3,"displayYoutubeDetails() sDuration : $sDuration");
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
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics duration : $sDisplayDuration");
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics viewCount : $sViewCount");
					log_message($self,3,"displayYoutubeDetails() sYoutubeInfo statistics title : $sTitle");
					
					if (defined($sTitle) && ( $sTitle ne "" ) && defined($sDuration) && ( $sDuration ne "" ) && defined($sViewCount) && ( $sViewCount ne "" )) {
						my $sMsgSong .= String::IRC->new('You')->black('white');
						$sMsgSong .= String::IRC->new('Tube')->white('red');
						$sMsgSong .= String::IRC->new(" https://www.youtube.com/watch?v=$sYoutubeId - $sTitle ")->white('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sDisplayDuration ")->grey('black');
						$sMsgSong .= String::IRC->new("- ")->orange('black');
						$sMsgSong .= String::IRC->new("$sViewCount")->grey('black');
						botPrivmsg($self,$sChannel,"($sNick) $sMsgSong");
					}
					else {
						log_message($self,3,"displayYoutubeDetails() one of the youtube field is undef or empty");
						if (defined($sTitle)) {
							log_message($self,3,"displayYoutubeDetails() sTitle=$sTitle");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sTitle is undefined");
						}
						
						if (defined($sDuration)) {
							log_message($self,3,"displayYoutubeDetails() sDuration=$sDuration");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sDuration is undefined");
						}
						if (defined($sViewCount)) {
							log_message($self,3,"displayYoutubeDetails() sViewCount=$sViewCount");
						}
						else {
							log_message($self,3,"displayYoutubeDetails() sViewCount is undefined");
						}
					}
				}
				else {
					log_message($self,3,"displayYoutubeDetails() Invalid id : $sYoutubeId");
				}
			}
			else {
				log_message($self,3,"displayYoutubeDetails() curl empty result for : curl --connect-timeout 5 -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		log_message($self,3,"displayYoutubeDetails() sYoutubeId could not be determined");
	}
}

sub getRadioCurrentSong(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	
	my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
	my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
	my $RADIO_JSON = $MAIN_CONF{'radio.RADIO_JSON'};
	my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};

	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		log_message($self,0,"getRadioCurrentSong() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}
	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	if ( $RADIO_PORT == 443 ) {
		$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON";
	}
	unless (open ICECAST_STATUS_JSON, "curl --connect-timeout 3 -f -s $JSON_STATUS_URL |") {
		return "N/A";
	}
	my $line;
	if (defined($line=<ICECAST_STATUS_JSON>)) {
		close ICECAST_STATUS_JSON;
		chomp($line);
		my $json = decode_json $line;
		my @sources = $json->{'icestats'}{'source'};
		#my %source = %{$sources[0][$RADIO_SOURCE]};
		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'title'})) {
				my $title = $source{'title'};
				if ( $title =~ /&#.*;/) {
					return decode_entities($title);
				}
				else {
					return $source{'title'};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	
	my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
	my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
	my $RADIO_JSON = $MAIN_CONF{'radio.RADIO_JSON'};
	my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};

	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		log_message($self,0,"getRadioCurrentSong() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
		return undef;
	}
	my $JSON_STATUS_URL = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	if ( $RADIO_PORT == 443 ) {
		$JSON_STATUS_URL = "https://$RADIO_HOSTNAME/$RADIO_JSON";
	}
	unless (open ICECAST_STATUS_JSON, "curl --connect-timeout 3 -f -s $JSON_STATUS_URL |") {
		return "N/A";
	}
	my $line;
	if (defined($line=<ICECAST_STATUS_JSON>)) {
		close ICECAST_STATUS_JSON;
		chomp($line);
		my $json = decode_json $line;
		my @sources = $json->{'icestats'}{'source'};
		#my %source = %{$sources[0][$RADIO_SOURCE]};
		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'listeners'})) {
				return $source{'listeners'};
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

sub getRadioHarbor(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_HARBOR, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			log_message($self,3,"Unable to connect to LIQUIDSOAP telnet port");
		}
		my $line;
		my $sHarbor;
		while (defined($line=<LIQUIDSOAP_HARBOR>)) {
			chomp($line);
			if ( $line =~ /harbor/) {
				my $sHarbor = $line;
				$sHarbor =~ s/^.*harbor/harbor/;
				$sHarbor =~ s/\..*$//;
				close LIQUIDSOAP_HARBOR;
				return $sHarbor;
			}
		}
		close LIQUIDSOAP_HARBOR;
		return undef;
	}
	else {
		return undef;
	}
}

sub isRadioLive(@) {
	my ($self,$sHarbor) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_HARBOR, "echo -ne \"$sHarbor.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
			log_message($self,3,"Unable to connect to LIQUIDSOAP telnet port");
		}
		my $line;
		my $sHarbor;
		while (defined($line=<LIQUIDSOAP_HARBOR>)) {
			chomp($line);
			if ( $line =~ /source/ ) {
				log_message($self,3,$line);
				if ( $line =~ /no source client connected/ ) {
					return 0;
				}
				else {
					return 1;
				}
			}
		}
		close LIQUIDSOAP_HARBOR;
		return 0;
	}
	else {
		return 0;
	}
}

sub getRadioRemainingTime(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
	my $LIQUIDSOAP_MOUNPOINT = $RADIO_URL;
	$LIQUIDSOAP_MOUNPOINT =~ s/\./(dot)/;
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep remaining | tr -s \" \" | cut -f2 -d\" \" | tail -n 1 |") {
			log_message($self,0,"getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
		}
		my $line;
		if (defined($line=<LIQUIDSOAP>)) {
			chomp($line);
			log_message($self,3,$line);
			unless (open LIQUIDSOAP2, "echo -ne \"$line\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				log_message($self,0,"getRadioRemainingTime() Unable to connect to LIQUIDSOAP telnet port");
			}
			my $line2;
			if (defined($line2=<LIQUIDSOAP2>)) {
				chomp($line2);
				log_message($self,3,$line2);
				return($line2);
			}
		}
		return 0;
	}
	else {
		log_message($self,0,"getRadioRemainingTime() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
}

sub displayRadioCurrentSong(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
	my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
	my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};
	my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	
	my $sRadioCurrentSongTitle = getRadioCurrentSong($self);
	
	my $sHarbor = getRadioHarbor($self);
	my $bRadioLive = 0;
	if (defined($sHarbor) && ($sHarbor ne "")) {
		log_message($self,3,$sHarbor);
		$bRadioLive = isRadioLive($self,$sHarbor);
	}
	
	if (defined($sRadioCurrentSongTitle) && ($sRadioCurrentSongTitle ne "")) {
		# Format message with irc colors
		my $sMsgSong = "";
		
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
		if ( $bRadioLive ) {
			$sMsgSong .= String::IRC->new('Live - ')->white('black');
		}
		$sMsgSong .= String::IRC->new($sRadioCurrentSongTitle)->white('black');
		$sMsgSong .= String::IRC->new(' ]')->orange('black');
		unless ( $bRadioLive ) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
				#Remaining time
				my $sRemainingTime = getRadioRemainingTime($self);
				log_message($self,3,"displayRadioCurrentSong() sRemainingTime = $sRemainingTime");
				my $siSecondsRemaining = int($sRemainingTime);
				my $iMinutesRemaining = int($siSecondsRemaining / 60) ;
				my $iSecondsRemaining = int($siSecondsRemaining - ( $iMinutesRemaining * 60 ));
				$sMsgSong .= String::IRC->new(' - ')->white('black');
				$sMsgSong .= String::IRC->new(' [ ')->orange('black');
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
				$sMsgSong .= String::IRC->new(' ]')->orange('black');
			}
		}
		botPrivmsg($self,$sChannel,"$sMsgSong");
	}
	else {
		botNotice($self,$sNick,"Radio is currently unavailable");
	}
}

sub displayRadioListeners(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
	my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
	my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};
	my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
	
	my $sRadioCurrentListeners = getRadioCurrentListeners($self);
	
	if (defined($sRadioCurrentListeners) && ($sRadioCurrentListeners ne "")) {
		# Format message with irc colors
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
	}
	else {
		botNotice($self,$sNick,"Radio is currently unavailable");
	}
}

sub setRadioMetadata(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my %MAIN_CONF = %{$self->{MAIN_CONF}};
				my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
				my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
				my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};
				my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
				my $RADIO_ADMINPASS = $MAIN_CONF{'radio.RADIO_ADMINPASS'};
				
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
							sleep 2;
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
					log_message($self,0,"setRadioMetadata() radio.RADIO_HOSTNAME not set in " . $self->{config_file});
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

sub radioNext(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Administrator")) {
				my %MAIN_CONF = %{$self->{MAIN_CONF}};
				my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
				my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
				my $RADIO_SOURCE = $MAIN_CONF{'radio.RADIO_SOURCE'};
				my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
				my $RADIO_ADMINPASS = $MAIN_CONF{'radio.RADIO_ADMINPASS'};
				my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
				my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
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
					if ( $i != 0 ) {
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
					log_message($self,0,"radioNext() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
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

sub wordStat(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $MAIN_PROG_CMD_CHAR = $MAIN_CONF{'main.MAIN_PROG_CMD_CHAR'};
	my $sWord;
	unless (defined($tArgs[0]) && ($tArgs[0])) {
		botNotice($self,$sNick,"Syntax : wordstat <word>");
		return undef;
	}
	else {
		$sWord = $tArgs[0];
	}
	
	my $sQuery = "SELECT * FROM CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND name=? AND ts > date_sub('" . time2str("%Y-%m-%d %H:%M:%S",time) . "', INTERVAL 1 DAY)";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		my $sResponse;
		my $i = 0;
		while (my $ref = $sth->fetchrow_hashref()) {
			my $publictext = $ref->{'publictext'};
			if (( $publictext =~ /\s$sWord$/i ) || ( $publictext =~ /\s$sWord\s/i ) || ( $publictext =~ /^$sWord\s/i ) || ( $publictext =~ /^$sWord$/i )) {
				if ( $i < 10 ) {
					log_message($self,3,"publictext : $publictext");
				}
				$i++;
			}
		}
		botPrivmsg($self,$sChannel,"wordstat for $tArgs[0] : $i");
		logBot($self,$message,$sChannel,"wordstat",@tArgs);
	}
	$sth->finish;
	
}

sub update(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Owner")) {
				log_message($self,3,"Update TBD ;)");
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $i = 0;
					while (my $ref = $sth->fetchrow_hashref()) {
						my $ts = $ref->{'ts'};
						my $id_user = $ref->{'id_user'};
						my $sUserhandle = getUserhandle($self,$id_user);
						$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");
						my $id_channel = $ref->{'id_channel'};
						my $sChannelCom = getChannelName($self,$id_channel);
						$sChannelCom = (defined($sChannelCom) && ($sChannelCom ne "") ? " $sChannelCom" : "");
						my $hostmask = $ref->{'hostmask'};
						my $action = $ref->{'action'};
						my $args = $ref->{'args'};
						$args = (defined($args) && ($args ne "") ? $args : "");
						botNotice($self,$sNick,"$ts ($sUserhandle)$sChannelCom $hostmask $action $args");
						#$self->{irc}->write("NOTICE " . $sNick . ":$ts ($sUserhandle)$sChannelCom $hostmask $action $args\x0d\x0a");
						#if (($i % 3) == 0) { sleep 3; }
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
		else {
			my $sNoticeMsg = $message->prefix . " q command attempt (user $sMatchingUserHandle is not logged in)";
			noticeConsoleChan($self,$sNoticeMsg);
			botNotice($self,$sNick,"You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
			return undef;
		}
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					unless ($sth->execute($id_channel,$iMatchingUserId,$sQuoteText)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $id_inserted = String::IRC->new($sth->{ mysql_insertid })->bold;
						botPrivmsg($self,$sChannel,"($sMatchingUserHandle) done. (id: $id_inserted)");
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				$sQuery = "DELETE FROM QUOTES WHERE id_quotes=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_quotes)) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $minDate = $ref->{'minDate'};
						$sQuery = "SELECT UNIX_TIMESTAMP(ts) as maxDate FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER by ts DESC LIMIT 1";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
													log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													if (my $ref = $sth->fetchrow_hashref()) {
														botNotice($self,$sNick,"autologin is already ON for user $sUser");
													}
													else {
														$sQuery = "UPDATE USER SET username='#AUTOLOGIN#' WHERE nickname like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($sUser)) {
															log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
													log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
												}
												else {
													if (my $ref = $sth->fetchrow_hashref()) {
														$sQuery = "UPDATE USER SET username=NULL WHERE nickname like ?";
														$sth = $self->{dbh}->prepare($sQuery);
														unless ($sth->execute($sUser)) {
															log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $nbmsg_max = $ref->{'nbmsg_max'};
			my $duration = $ref->{'duration'};
			my $timetowait = $ref->{'timetowait'};
			log_message($self,3,"setChannelAntiFlood() AntiFlood record exists (id_channel $id_channel) nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds");
			botNotice($self,$sNick,"Chanset parameters already exist and will be used for $sChannel (nbmsg_max : $nbmsg_max duration : $duration seconds timetowait : $timetowait seconds)");
		}
		else {
			$sQuery = "INSERT INTO CHANNEL_FLOOD (id_channel) VALUES (?)";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($id_channel)) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				my $id_channel_flood = $sth->{ mysql_insertid };
				log_message($self,3,"setChannelAntiFlood() AntiFlood record created, id_channel_flood : $id_channel_flood");
				$sQuery = "SELECT * FROM CHANNEL_FLOOD WHERE id_channel=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_channel)) {
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
					log_message($self,4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
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
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
							log_message($self,4,"checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max set latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds");
							return 0;
						}
					}
					else {
						my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
						my $endTs = $latest + $timetowait;
						unless ( $currentTs <= $endTs ) {
							$nbmsg = 1;
							log_message($self,0,"checkAntiFlood() End of antiflood for channel $sChannel");
							$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,first=?,latest=?,notification=? WHERE id_channel=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($nbmsg,$currentTs,$currentTs,0,$id_channel)) {
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
								log_message($self,4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
								return 0;
							}
						}
						else {
							unless ( $notification ) {
								#$self->{irc}->do_PRIVMSG( target => $sChannel, text => "Anti flood active for $timetowait seconds on channel $sChannel, no more than $nbmsg_max requests in $duration seconds." );
								$sQuery = "UPDATE CHANNEL_FLOOD SET notification=? WHERE id_channel=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute(1,$id_channel)) {
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
								}
								else {
									log_message($self,4,"checkAntiFlood() Antiflood notification set to DB for $sChannel");
									noticeConsoleChan($self,"Anti flood activated on channel $sChannel $nbmsg messages in less than $duration seconds, waiting $timetowait seconds to desactivate");
								}
							}
							log_message($self,4,"checkAntiFlood() msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max latest current : $sLatest ($currentTs) in db, deltaDb = $deltaDb seconds endTs = $endTs " . ($endTs - $currentTs) . " seconds left");
							log_message($self,0,"checkAntiFlood() Antiflood is active for channel $sChannel wait " . ($endTs - $currentTs) . " seconds");
							return 1;
						}
					}
				}
				else {
					$nbmsg = 1;
					log_message($self,0,"checkAntiFlood() End of antiflood for channel $sChannel");
					$sQuery = "UPDATE CHANNEL_FLOOD SET nbmsg=?,first=?,latest=?,notification=? WHERE id_channel=?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($nbmsg,$currentTs,$currentTs,0,$id_channel)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sLatest = time2str("%Y-%m-%d %H-%M-%S",$currentTs);
						log_message($self,4,"checkAntiFlood() First msg nbmsg : $nbmsg nbmsg_max : $nbmsg_max first and latest current : $sLatest ($currentTs)");
						return 0;
					}
				}
			}
		}
		else {
			log_message($self,0,"Something funky happened, could not find record in Table CHANNEL_FLOOD for channel $sChannel (id_channel : $id_channel)");
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
					log_message($self,3,"Check antifloodset on $sChannel");
					my $sQuery = "SELECT * FROM CHANNEL,CHANNEL_FLOOD WHERE CHANNEL.id_channel=CHANNEL_FLOOD.id_channel and CHANNEL.name like ?";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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

sub playRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $incomingDir = $MAIN_CONF{'radio.YOUTUBEDL_INCOMING'};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					log_message($self,3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					botPrivmsg($self,$sChannel,"($sNick radio play) Cannot queue requests while radio is live");
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
							botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
							return undef;
						}
						else {
							unless ($sDurationSeconds < (12 * 60)) {
								botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
								return undef;
							}
							unless ( -d $incomingDir ) {
								log_message($self,0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
									botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : ID : $sYoutubeId (cached) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
									logBot($self,$message,$sChannel,"play",$sText);
								}
								else {
									log_message($self,3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
									botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
									return undef;
								}
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
								my $timer = IO::Async::Timer::Countdown->new(
							   	delay => 3,
							   	on_expire => sub {
										log_message($self,3,"Timer start, downloading $ytUrl");
										
										unless ( open YT, "youtube-dl --extract-audio --audio-format mp3 --add-metadata $ytUrl |" ) {
				                    		log_message($self,0,"Could not youtube-dl $ytUrl");
				                    		return undef;
				            			}
				            			my $ytdlOuput;
				            
										while (defined($ytdlOuput=<YT>)) {
												chomp($ytdlOuput);
												if ( $ytdlOuput =~ /^\[ffmpeg\] Destination: (.*)$/ ) {
													$ytDestinationFile = $1;
													log_message($self,0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
													
												}
												log_message($self,3,"$ytdlOuput");
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
												log_message($self,1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
											}
											else {
												$id_mp3 = $sth->{ mysql_insertid };
												log_message($self,3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
											}
											$sth->finish;
											my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
											if (defined($rPush) && $rPush) {
												botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $sYoutubeId (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
												logBot($self,$message,$sChannel,"play",$sText);
											}
											else {
												log_message($self,3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");	
												botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
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
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
							}
							else {
								if (my $ref = $sth->fetchrow_hashref()) {
									my $ytDestinationFile = $ref->{'folder'} . "/" . $ref->{'filename'};
									log_message($self,3,"playRadio() pushing $ytDestinationFile to queue");
									my $rPush = queuePushRadio($self,$ytDestinationFile);
									if (defined($rPush) && $rPush) {
										my $id_youtube = $ref->{'id_youtube'};
										my $artist = ( defined($ref->{'artist'}) ? $ref->{'artist'} : "Unknown");
										my $title = ( defined($ref->{'title'}) ? $ref->{'title'} : "Unknown");
										my $duration = 0;
										my $sMsgSong = "$artist - $title";
										if (defined($id_youtube) && ($id_youtube ne "")) {
											($duration,$sMsgSong) = getYoutubeDetails($self,"https://www.youtube.com/watch?v=$id_youtube");
											botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										}
										else {
											botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " (cached) / $sMsgSong / Queued");
										}
										logBot($self,$message,$sChannel,"play",$sText);
										return 1;
									}
									else {
										log_message($self,3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
										botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										return undef;
									}
								}
								else {
									botPrivmsg($self,$sChannel,"($sNick radio play / could not find mp3 id in library : $tArgs[1]");
									return undef;
								}
							}
						}
						if (defined($tArgs[0]) && ($tArgs[0] =~ /^ytid$/) && defined($tArgs[1]) && ($tArgs[1] ne "")) {
							my $sQuery = "SELECT id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute($tArgs[1])) {
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : " . $tArgs[1] . " Youtube ID : $sText (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
										logBot($self,$message,$sChannel,"play",$sText);
									}
									else {
										log_message($self,3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
										botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
										return undef;
									}
								}
								else {
									unless ( -d $incomingDir ) {
										log_message($self,0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
										return undef;
									}
									else {
										chdir $incomingDir;
									}
									my $ytUrl = "https://www.youtube.com/watch?v=" . $tArgs[1];
									my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
									unless (defined($sMsgSong)) {
										botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
										return undef;
									}
									botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
									my $timer = IO::Async::Timer::Countdown->new(
										delay => 3,
										on_expire => sub {
												log_message($self,3,"Timer start, downloading $ytUrl");
												unless ( open YT, "youtube-dl --extract-audio --audio-format mp3 --add-metadata $ytUrl |" ) {
													log_message($self,0,"Could not youtube-dl $ytUrl");
													return undef;
												}
												my $ytdlOuput;
												my $ytDestinationFile;
												while (defined($ytdlOuput=<YT>)) {
														chomp($ytdlOuput);
														if ( $ytdlOuput =~ /^\[ffmpeg\] Destination: (.*)$/ ) {
															$ytDestinationFile = $1;
															log_message($self,0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
															
														}
														log_message($self,3,"$ytdlOuput");
												}
												if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
													my $filename = $ytDestinationFile;
													my $folder = $incomingDir;
													my $id_youtube = substr($filename,-15);
													$id_youtube = substr($id_youtube,0,11);
													log_message($self,3,"Destination : $incomingDir/$ytDestinationFile");
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
														log_message($self,1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
													}
													else {
														$id_mp3 = $sth->{ mysql_insertid };
														log_message($self,3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
													}
													$sth->finish;
													my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
													if (defined($rPush) && $rPush) {
														botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
														logBot($self,$message,$sChannel,"play",$sText);
													}
													else {
														log_message($self,3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");	
														botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
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
							my $sTextLocal = join ("%",@tArgs);
							my $sSearch = $sTextLocal;
							$sSearch =~ s/\s+/%/g;
							$sSearch =~ s/%+/%/g;
							$sSearch =~ s/;//g;
							$sSearch =~ s/'/\\'/g;
							my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE CONCAT(artist,title) LIKE '%" . $sSearch . "%' ORDER BY RAND() LIMIT 1";
							log_message($self,3,"playRadio() Query : $sQuery");
							my $sth = $self->{dbh}->prepare($sQuery);
							unless ($sth->execute()) {
								log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
										}
										else {
											botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
										}
										logBot($self,$message,$sChannel,"play",@tArgs);
										return 1;
									}
									else {
										log_message($self,3,"playRadio() could not queue queuePushRadio() $ytDestinationFile");	
										botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
										return undef;
									}
								}
							}
							# Youtube Search
							my $sYoutubeId;
							my $sText = join("%20",@tArgs);
							log_message($self,3,"radioplay() youtubeSearch() on $sText");
							my $APIKEY = $MAIN_CONF{'main.YOUTUBE_APIKEY'};
							unless (defined($APIKEY) && ($APIKEY ne "")) {
								log_message($self,0,"displayYoutubeDetails() API Youtube V3 DEV KEY not set in " . $self->{config_file});
								log_message($self,0,"displayYoutubeDetails() section [main]");
								log_message($self,0,"displayYoutubeDetails() YOUTUBE_APIKEY=key");
								return undef;
							}
							unless ( open YOUTUBE_INFOS, "curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\" |" ) {
								log_message(3,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
							}
							else {
								my $line;
								my $i = 0;
								my $json_details;
								while(defined($line=<YOUTUBE_INFOS>)) {
									chomp($line);
									$json_details .= $line;
									log_message($self,5,"radioplay() youtubeSearch() $line");
									$i++;
								}
								if (defined($json_details) && ($json_details ne "")) {
									log_message($self,4,"radioplay() youtubeSearch() json_details : $json_details");
									my $sYoutubeInfo = decode_json $json_details;
									my %hYoutubeInfo = %$sYoutubeInfo;
										my @tYoutubeItems = $hYoutubeInfo{'items'};
										my @fTyoutubeItems = @{$tYoutubeItems[0]};
										log_message($self,4,"radioplay() youtubeSearch() tYoutubeItems length : " . $#fTyoutubeItems);
										# Check items
										if ( $#fTyoutubeItems >= 0 ) {
											my %hYoutubeItems = %{$tYoutubeItems[0][0]};
											log_message($self,4,"radioplay() youtubeSearch() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
											my @tYoutubeId = $hYoutubeItems{'id'};
											my %hYoutubeId = %{$tYoutubeId[0]};
											log_message($self,4,"radioplay() youtubeSearch() sYoutubeInfo Id : " . Dumper(%hYoutubeId));
											$sYoutubeId = $hYoutubeId{'videoId'};
											log_message($self,4,"radioplay() youtubeSearch() sYoutubeId : $sYoutubeId");
										}
										else {
											log_message($self,3,"radioplay() youtubeSearch() Invalid id : $sYoutubeId");
										}
								}
								else {
									log_message($self,3,"radioplay() youtubeSearch() curl empty result for : curl --connect-timeout 5 -G -f -s \"https://www.googleapis.com/youtube/v3/search\" -d part=\"snippet\" -d q=\"$sText\" -d key=\"$APIKEY\"");
								}
							}
							if (defined($sYoutubeId) && ($sYoutubeId ne "")) {
								my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
								my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
								unless (defined($sMsgSong)) {
									botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
									return undef;
								}
								unless ($sDurationSeconds < (12 * 60)) {
									botPrivmsg($self,$sChannel,"($sNick radio play) Youtube link duration is too long ($sDurationSeconds seconds), sorry");
									return undef;
								}
								my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_youtube=?";
								my $sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute($sYoutubeId)) {
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
											botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (cached) / https://www.youtube.com/watch?v=$id_youtube / $sMsgSong / Queued");
											logBot($self,$message,$sChannel,"play",$sText);
										}
										else {
											log_message($self,3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");	
											botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
											return undef;
										}
									}
									else {
										unless ( -d $incomingDir ) {
											log_message($self,0,"Incoming YOUTUBEDL directory : $incomingDir does not exist");
											return undef;
										}
										else {
											chdir $incomingDir;
										}
										my $ytUrl = "https://www.youtube.com/watch?v=$sYoutubeId";
										my ($sDurationSeconds,$sMsgSong) = getYoutubeDetails($self,$ytUrl);
										unless (defined($sMsgSong)) {
											botPrivmsg($self,$sChannel,"($sNick radio play) Unknown Youtube link");
											return undef;
										}
										botPrivmsg($self,$sChannel,"($sNick radio play) $sMsgSong - Please wait while downloading");
										my $timer = IO::Async::Timer::Countdown->new(
											delay => 3,
											on_expire => sub {
													log_message($self,3,"Timer start, downloading $ytUrl");
													
													unless ( open YT, "youtube-dl --extract-audio --audio-format mp3 --add-metadata $ytUrl |" ) {
														log_message($self,0,"Could not youtube-dl $ytUrl");
														return undef;
													}
													my $ytdlOuput;
													my $ytDestinationFile;
													while (defined($ytdlOuput=<YT>)) {
															chomp($ytdlOuput);
															if ( $ytdlOuput =~ /^\[ffmpeg\] Destination: (.*)$/ ) {
																$ytDestinationFile = $1;
																log_message($self,0,"Downloaded mp3 : $incomingDir/$ytDestinationFile");
																
															}
															log_message($self,3,"$ytdlOuput");
													}
													if (defined($ytDestinationFile) && ($ytDestinationFile ne "")) {			
														my $filename = $ytDestinationFile;
														my $folder = $incomingDir;
														my $id_youtube = substr($filename,-15);
														$id_youtube = substr($id_youtube,0,11);
														log_message($self,3,"Destination : $incomingDir/$ytDestinationFile");
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
															log_message($self,1,"Error : " . $DBI::errstr . " Query : " . $sQuery);
														}
														else {
															$id_mp3 = $sth->{ mysql_insertid };
															log_message($self,3,"Added : $artist - Title : $title - Youtube ID : $id_youtube");
														}
														$sth->finish;
														my $rPush = queuePushRadio($self,"$incomingDir/$ytDestinationFile");
														if (defined($rPush) && $rPush) {
															botPrivmsg($self,$sChannel,"($sNick radio play) Library ID : $id_mp3 / Youtube ID : $id_youtube (downloaded) / https://www.youtube.com/watch?v=$sYoutubeId / $sMsgSong / Queued");
															logBot($self,$message,$sChannel,"play",$sText);
														}
														else {
															log_message($self,3,"playRadio() could not queue queuePushRadio() $incomingDir/$ytDestinationFile");	
															botPrivmsg($self,$sChannel,"($sNick radio play could not queue) Already asked ?");
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
								botPrivmsg($self,$sChannel,"($sNick radio play no Youtube ID found for " . join(" ",@tArgs));
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

sub queueCount(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 | wc -w |") {
		log_message($self,0,"queueCount() Unable to connect to LIQUIDSOAP telnet port");
		return undef;
	}
	my $line;
	if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
		chomp($line);
		log_message($self,3,$line);
	}
	return $line;
}

sub isInQueueRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	my $iNbTrack = queueCount($self);
	unless ( $iNbTrack == 0 ) {
		my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
		my $line;
		if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
			unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
				log_message($self,0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
				return undef;
			}
			if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
				chomp($line);
				$line =~ s/\r//;
				$line =~ s/\n//;
				log_message($self,3,"isInQueueRadio() $line");
			}
			if ($iNbTrack > 0) {
				my @RIDS = split(/ /,$line);
				my $i;
				for ($i=0;$i<=$#RIDS;$i++) {
					unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
						log_message($self,0,"isInQueueRadio() Unable to connect to LIQUIDSOAP telnet port");
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
						log_message($self,3,"isInQueueRadio() $line");
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
			log_message($self,0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
		}
	}
	else {
		return 0;
	}
}

sub queueRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $iHarborId = getHarBorId($self);
				my $bHarbor = 0;
				if (defined($iHarborId) && ($iHarborId ne "")) {
					log_message($self,3,"Harbord ID : $iHarborId");
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"harbor_$iHarborId.status\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							log_message($self,0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						my $line;
						if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							log_message($self,3,$line);
							unless ($line =~ /^no source client connected/) {
								botPrivmsg($self,$sChannel,radioMsg($self,"Live - " . getRadioCurrentSong($self)));
								$bHarbor = 1;
							}
						}
					}
					else {
						log_message($self,0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
					}
				}
				
				my $iNbTrack = queueCount($self);
				unless ( $iNbTrack == 0 ) {
					my $sNbTrack = ( $iNbTrack > 1 ? "tracks" : "track" );
					my $line;
					if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
						unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.queue\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
							log_message($self,0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
							return undef;
						}
						if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
							chomp($line);
							$line =~ s/\r//;
							$line =~ s/\n//;
							log_message($self,3,"queueRadio() $line");
						}
						if ($iNbTrack > 0) {
							botPrivmsg($self,$sChannel,radioMsg($self,"$iNbTrack $sNbTrack in queue, RID : $line"));
							my @RIDS = split(/ /,$line);
							my $i;
							for ($i=0;($i<3 && $i<=$#RIDS);$i++) {
								unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"request.trace " . $RIDS[$i] . "\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | head -1 |") {
									log_message($self,0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
									return undef;
								}
								my $line;
								if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
									chomp($line);
									my $sMsgSong = "";
									if (( $i == 0 ) && (!$bHarbor)) {
										#Remaining time
										my $sRemainingTime = getRadioRemainingTime($self);
										log_message($self,3,"queueRadio() sRemainingTime = $sRemainingTime");
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
									log_message($self,3,"queueRadio() $line");
									my $sFolder = dirname($line);
									my $sFilename = basename($line);
									my $sBaseFilename = basename($sFilename, ".mp3");
									my $sQuery = "SELECT artist,title FROM MP3 WHERE folder=? AND filename=?";
									my $sth = $self->{dbh}->prepare($sQuery);
									unless ($sth->execute($sFolder,$sFilename)) {
										log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
									}
									else {
										if (my $ref = $sth->fetchrow_hashref()) {
											my $title = $ref->{'title'};
											my $artist = $ref->{'artist'};
											if ($i == 0) {
												unless ($bHarbor) {
													botPrivmsg($self,$sChannel,"» $artist - $title" . $sMsgSong);
												}
												else {
													botPrivmsg($self,$sChannel,"» $artist - $title");
												}
											}
											else {
												botPrivmsg($self,$sChannel,"└ $artist - $title");
											}
										}
										else {
											if ($i == 0) {
												unless ($bHarbor) {
													botPrivmsg($self,$sChannel,"» $sBaseFilename" . $sMsgSong);
												}
												else {
													botPrivmsg($self,$sChannel,"» $sBaseFilename");
												}
											}
											else {
												botPrivmsg($self,$sChannel,"└ $sBaseFilename");
											}
										}
									}
									$sth->finish;
								}
							}
						}
					}
					else {
						log_message($self,0,"queueRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});	
					}
				}
				else {
					unless ( $bHarbor ) {
						#Remaining time
						my $sRemainingTime = getRadioRemainingTime($self);
						log_message($self,3,"queueRadio() sRemainingTime = $sRemainingTime");
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
						botPrivmsg($self,$sChannel,radioMsg($self,"Global playlist - " . getRadioCurrentSong($self) . $sMsgSong));
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

sub queuePushRadio(@) {
	my ($self,$sAudioFilename) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	if (defined($sAudioFilename) && ($sAudioFilename ne "")) {
		unless (isInQueueRadio($self,$sAudioFilename)) {
			if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
				log_message($self,3,"queuePushRadio() pushing $sAudioFilename to queue");
				unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"queue.push $sAudioFilename\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
					log_message($self,0,"queuePushRadio() Unable to connect to LIQUIDSOAP telnet port");
					return undef;
				}
				my $line;
				while (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
					chomp($line);
					log_message($self,3,$line);
				}
				return 1;
			}
			else {
				log_message($self,0,"playRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
				return 0;
			}
		}
		else {
			log_message($self,3,"queuePushRadio() $sAudioFilename already in queue");
			return 0;
		}
	}
	else {
		log_message($self,3,"queuePushRadio() missing audio file parameter");
		return 0;
	}
}

sub nextRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"Master")) {
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"radio(dot)mp3.skip\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT |") {
						log_message($self,0,"queueRadio() Unable to connect to LIQUIDSOAP telnet port");
						return undef;
					}
					my $line;
					while (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
						chomp($line);
						log_message($self,3,$line);
					}
					logBot($self,$message,$sChannel,"next",@tArgs);
					sleep(6);
					displayRadioCurrentSong($self,$message,$sNick,$sChannel,@tArgs);
				}
				else {
					log_message($self,0,"nextRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
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

sub radioMsg(@) {
	my ($self,$sText) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sMsgSong = "";
	my $RADIO_HOSTNAME = $MAIN_CONF{'radio.RADIO_HOSTNAME'};
	my $RADIO_PORT = $MAIN_CONF{'radio.RADIO_PORT'};
	my $RADIO_URL = $MAIN_CONF{'radio.RADIO_URL'};
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

sub rplayRadio(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $incomingDir = $MAIN_CONF{'radio.YOUTUBEDL_INCOMING'};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};

	my ($iMatchingUserId,$iMatchingUserLevel,$iMatchingUserLevelDesc,$iMatchingUserAuth,$sMatchingUserHandle,$sMatchingUserPasswd,$sMatchingUserInfo1,$sMatchingUserInfo2) = getNickInfo($self,$message);
	if (defined($iMatchingUserId)) {
		if (defined($iMatchingUserAuth) && $iMatchingUserAuth) {
			if (defined($iMatchingUserLevel) && checkUserLevel($self,$iMatchingUserLevel,"User")) {
				my $sHarbor = getRadioHarbor($self);
				my $bRadioLive = 0;
				if (defined($sHarbor) && ($sHarbor ne "")) {
					log_message($self,3,$sHarbor);
					$bRadioLive = isRadioLive($self,$sHarbor);
				}
				if ($bRadioLive) {
					botPrivmsg($self,$sChannel,"($sNick radio rplay) Cannot queue requests while radio is live");
					return undef;
				}
				if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
					if (defined($tArgs[0]) && ($tArgs[0] eq "user") && defined($tArgs[1]) && ($tArgs[1] ne "")) {
						my $id_user = getIdUser($self,$tArgs[1]);
						unless (defined($id_user)) {
							botPrivmsg($self,$sChannel,"($sNick radio play) Unknown user " . $tArgs[0]);
							return undef;
						}
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 WHERE id_user=? ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($id_user)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
									}
									else {
										botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . ") (Library ID : $id_mp3) / $artist - $title / Queued");
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									log_message($self,3,"rplayRadio() user / could not queue queuePushRadio() $ytDestinationFile");	
									botPrivmsg($self,$sChannel,"($sNick radio rplay / user / could not queue)");
									return undef;
								}
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
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
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
									}
									else {
										botPrivmsg($self,$sChannel,"($sNick radio play artist " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									log_message($self,3,"rplayRadio() artist / could not queue queuePushRadio() $ytDestinationFile");	
									botPrivmsg($self,$sChannel,"($sNick radio rplay / artist / could not queue)");
									return undef;
								}
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick radio play user " . $tArgs[1] . " / no track found)");
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
						log_message($self,3,"rplayRadio() Query : $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
									}
									else {
										botPrivmsg($self,$sChannel,"($sNick radio play " . $sText . ") (Library ID : $id_mp3) / $artist - $title / Queued");
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									log_message($self,3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");	
									botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									return undef;
								}
							}
							else {
								botPrivmsg($self,$sChannel,"($sNick radio play $sText / no track found)");
							}
						}
						$sth->finish;
					}
					else {
						my $sQuery = "SELECT id_mp3,id_youtube,artist,title,folder,filename FROM MP3 ORDER BY RAND() LIMIT 1";
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute()) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
										botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3 YTID : $id_youtube) / $sMsgSong - https://www.youtube.com/watch?v=$id_youtube / Queued");
									}
									else {
										botPrivmsg($self,$sChannel,"($sNick radio play) (Library ID : $id_mp3) / $artist - $title / Queued");
									}
									logBot($self,$message,$sChannel,"rplay",@tArgs);
								}
								else {
									log_message($self,3,"rplayRadio() could not queue queuePushRadio() $ytDestinationFile");	
									botPrivmsg($self,$sChannel,"($sNick radio rplay / could not queue)");
									return undef;
								}
							}
						}
						$sth->finish;
					}
				}
				else {
					log_message($self,0,"rplayRadio() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
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
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,3,"$sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($tArgs[1])) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,3,"$sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,3,"$sQuery = $sQuery");
					$sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute()) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
								log_message($self,3,"$sQuery = $sQuery");
								$sth = $self->{dbh}->prepare($sQuery);
								unless ($sth->execute()) {
									log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
				unless (open CMD, "$sText | tail -n 3 |") {
					log_message($self,3,"mbExec could not issue $sText command");
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

sub getHarBorId(@) {
	my ($self) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $LIQUIDSOAP_TELNET_HOST = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_HOST'};
	my $LIQUIDSOAP_TELNET_PORT = $MAIN_CONF{'radio.LIQUIDSOAP_TELNET_PORT'};
	if (defined($LIQUIDSOAP_TELNET_HOST) && ($LIQUIDSOAP_TELNET_HOST ne "")) {
		unless (open LIQUIDSOAP_TELNET_SERVER, "echo -ne \"help\nquit\n\" | nc $LIQUIDSOAP_TELNET_HOST $LIQUIDSOAP_TELNET_PORT | grep harbor | grep status | awk '{print \$2}' | awk -F'.' {'print \$1}' | awk -F'_' '{print \$2}' |") {
			log_message($self,0,"getHarBorId() Unable to connect to LIQUIDSOAP telnet port");
			return undef;
		}
		my $line;
		if (defined($line=<LIQUIDSOAP_TELNET_SERVER>)) {
			chomp($line);
			log_message($self,3,$line);
			return $line;
		}
		else {
			log_message($self,3,"getHarBorId() No output");
		}
	}
	else {
		log_message($self,0,"getHarBorId() radio.LIQUIDSOAP_TELNET_HOST not set in " . $self->{config_file});
	}
	return undef;
}

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
						log_message($self,3,"sQuery = $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel,$nickname)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
						log_message($self,3,"sQuery = $sQuery");
						my $sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel,$nickname)) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,3,"sQuery = $sQuery");
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel)) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						$sQuery = "DELETE FROM HAILO_EXCLUSION_NICK WHERE nick like ?";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($tArgs[0])) {
							log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
				log_message($self,3,"$status tokens, expressions, previous token links and next token links");
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_channel = $ref->{'id_channel'};
			$sQuery = "UPDATE HAILO_CHANNEL SET ratio=? WHERE id_channel=?";
			$sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($ratio,$id_channel)) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				$sth->finish;
				log_message($self,3,"set_hailo_channel_ratio updated hailo chatter ratio to $ratio for $sChannel");
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
					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					$sth->finish;
					log_message($self,3,"set_hailo_channel_ratio set hailo chatter ratio to $ratio for $sChannel");
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
	log_message($self,3,"whereis() $sHostname");
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

1;