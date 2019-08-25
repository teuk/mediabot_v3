package Mediabot;
 
use strict;
use warnings;
use diagnostics;
use Config::Simple;
use Date::Format;
use Data::Dumper;
use DBI;
use Switch;
use Memory::Usage;
use IO::Async::Timer::Periodic;
use String::IRC;
use JSON;
use POSIX 'setsid';

sub new {
	my ($class,$args) = @_;
	my $self = bless {
		config_file => $args->{config_file},
		main_prog_version => $args->{main_prog_version},
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

sub getConfig(@) {
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
		if (my $ref = $sth->fetchrow_hashref()) {
			$id_channel = $ref->{'id_channel'};
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
		else {
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
			log_message($self,0,"$sTo:<" . $self->{irc}->nick_folded . "> $sMsg");
			logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
		}
		else {
			$eventtype = "private";
			log_message($self,0,"-> *$sTo* $sMsg");
		}
		$self->{irc}->do_PRIVMSG( target => $sTo, text => $sMsg );
	}
	else {
		log_message($self,0,"botPrivmsg() ERROR no target specified to send $sMsg");
	}
}

sub botAction(@) {
	my ($self,$sTo,$sMsg) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $eventtype = "action";
	if (substr($sTo, 0, 1) eq '#') {
		log_message($self,0,"$sTo:<" . $self->{irc}->nick_folded . ">ACTION $sMsg");
		logBotAction($self,undef,$eventtype,$self->{irc}->nick_folded,$sTo,$sMsg);
	}
	else {
		$eventtype = "private";
		log_message($self,0,"-> *$sTo* ACTION $sMsg");
	}
	$self->{irc}->do_PRIVMSG( target => $sTo, text => "\1ACTION $sMsg\1" );
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my %hTimers;
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
	
	# Set timers at startup
	$sQuery = "SELECT * FROM TIMERS";
	$sth = $self->{dbh}->prepare($sQuery);
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
		log_message($self,3,"getNickInfo() iMatchingUserId is undefined with this host : " . $message->prefix);
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
	my ($self,$message,$sChannel,$sNick,$sCommand,@tArgs)	= @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $bFound = 0;
	switch($sCommand) {
		case /^die$/i				{ $bFound = 1;
													mbQuit($self,$message,$sNick,@tArgs);
												}
		case /^nick$/i			{ $bFound = 1;
													mbChangeNick($self,$message,$sNick,@tArgs);
												}
		case /^addtimer$/i	{ $bFound = 1;
													mbAddTimer($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^remtimer$/i	{ $bFound = 1;
													mbRemTimer($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^timers$/i		{ $bFound = 1;
													mbTimers($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^msg$/i				{ $bFound = 1;
													msgCmd($self,$message,$sNick,@tArgs);
												}
		case /^say$/i				{ $bFound = 1;
													sayChannel($self,$message,$sNick,@tArgs);
												}
		case /^act$/i				{ $bFound = 1;
													actChannel($self,$message,$sNick,@tArgs);
												}
		case /^cstat$/i			{ $bFound = 1;
													userCstat($self,$message,$sNick,@tArgs);
												}
		case /^status$/i		{ $bFound = 1;
													mbStatus($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^adduser$/i		{ $bFound = 1;
													addUser($self,$message,$sNick,@tArgs);
												}
		case /^users$/i			{ $bFound = 1;
													userStats($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^userinfo$/i	{ $bFound = 1;
													userInfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addhost$/i		{ $bFound = 1;
													addUserHost($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addchan$/i		{ $bFound = 1;
													addChannel($self,$message,$sNick,@tArgs);
												}
		case /^chanset$/i		{ $bFound = 1;
													channelSet($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^purge$/i			{ $bFound = 1;
													purgeChannel($self,$message,$sNick,@tArgs);
												}
		case /^part$/i			{ $bFound = 1;
													channelPart($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^join$/i			{ $bFound = 1;
													channelJoin($self,$message,$sNick,@tArgs);
												}
		case /^add$/i				{ $bFound = 1;
													channelAddUser($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^del$/i				{ $bFound = 1;
													channelDelUser($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^modinfo$/i		{ $bFound = 1;
													userModinfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^op$/i				{ $bFound = 1;
													userOpChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^deop$/i			{ $bFound = 1;
													userDeopChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^invite$/i		{ $bFound = 1;
													userInviteChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^voice$/i			{ $bFound = 1;
													userVoiceChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^devoice$/i		{ $bFound = 1;
													userDevoiceChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^kick$/i			{ $bFound = 1;
													userKickChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topic$/i			{ $bFound = 1;
													userTopicChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^showcommands$/i	{ $bFound = 1;
													userShowcommandsChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chaninfo$/i	{ $bFound = 1;
													userChannelInfo($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chanlist$/i	{ $bFound = 1;
													channelList($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^whoami$/i		{ $bFound = 1;
													userWhoAmI($self,$message,$sNick,@tArgs);
												}
		case /^auth$/i			{ $bFound = 1;
													userAuthNick($self,$message,$sNick,@tArgs);
												}
		case /^verify$/i		{ $bFound = 1;
													userVerifyNick($self,$message,$sNick,@tArgs);
												}
		case /^access$/i		{ $bFound = 1;
													userAccessChannel($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addcmd$/i		{ $bFound = 1;
													mbDbAddCommand($self,$message,$sNick,@tArgs);
												}
		case /^remcmd$/i		{ $bFound = 1;
													mbDbRemCommand($self,$message,$sNick,@tArgs);
												}
		case /^modcmd$/i		{ $bFound = 1;
													mbDbModCommand($self,$message,$sNick,@tArgs);
												}
		case /^mvcmd$/i			{ $bFound = 1;
													mbDbMvCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{ $bFound = 1;
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^showcmd$/i		{ $bFound = 1;
													mbDbShowCommand($self,$message,$sNick,@tArgs);
												}
		case /^version$/i		{ $bFound = 1;
													log_message($self,0,"mbVersion() by $sNick on $sChannel");
													botPrivmsg($self,$sChannel,$MAIN_CONF{'main.MAIN_PROG_NAME'} . $self->{main_prog_version});
													logBot($self,$message,undef,"version",undef);
												}
		case /^chanstatlines$/i	{ $bFound = 1;
														channelStatLines($self,$message,$sChannel,$sNick,@tArgs);
													}
		case /^whotalk$/i		{ $bFound = 1;
														whoTalk($self,$message,$sChannel,$sNick,@tArgs);
												}
		case /^countcmd$/i	{ $bFound = 1;
														mbCountCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topcmd$/i		{ $bFound = 1;
														mbTopCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^searchcmd$/i	{ $bFound = 1;
														mbDbSearchCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^lastcmd$/i		{ $bFound = 1;
														mbLastCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^owncmd$/i		{ $bFound = 1;
														mbDbOwnersCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^addcatcmd$/i	{ $bFound = 1;
														mbDbAddCategoryCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^chcatcmd$/i	{ $bFound = 1;
														mbDbChangeCategoryCommand($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^topsay$/i		{ $bFound = 1;
														userTopSay($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^checkhostchan$/i		{ $bFound = 1;
															mbDbCheckHostnameNickChan($self,$message,$sNick,$sChannel,@tArgs);
														}
		case /^checkhost$/i	{ $bFound = 1;
															mbDbCheckHostnameNick($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^checknick$/i	{ $bFound = 1;
													mbDbCheckNickHostname($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^greet$/i			{ $bFound = 1;
													userGreet($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^nicklist$/i	{ $bFound = 1;
														channelNickList($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^rnick$/i			{ $bFound = 1;
														randomChannelNick($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^birthdate$/i	{ $bFound = 1;
														displayBirthDate($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^colors$/i		{ $bFound = 1;
														mbColors($self,$message,$sNick,$sChannel,@tArgs);
												}
		case /^seen$/i			{ $bFound = 1;
														mbSeen($self,$message,$sNick,$sChannel,@tArgs);
												}
		else								{
													#$bFound = mbPluginCommand(\%MAIN_CONF,$LOG,$dbh,$irc,$message,$sChannel,$sNick,$sCommand,@tArgs);
													unless ( $bFound ) {
														$bFound = mbDbCommand($self,$message,$sChannel,$sNick,$sCommand,@tArgs);
													}
													unless ( $bFound ) {
														my $what = join(" ",($sCommand,@tArgs));
														switch($what) {
															case /how\s+old\s+are\s+you|how\s+old\s+r\s+you|how\s+old\s+r\s+u/i {
																$bFound = 1;
																displayBirthDate($self,$message,$sNick,$sChannel,@tArgs);
															}
														}
													}
												}
	}
	unless ( $bFound ) {
		log_message($self,1,"Public command '$sCommand' not found");
	}
	else {
		#my %GLOBAL_HASH;
		#$GLOBAL_HASH{'WHOIS_VARS'} = \%WHOIS_VARS;
		#$GLOBAL_HASH{'hTimers'} = \%hTimers;
		#return %GLOBAL_HASH;
	}
}

sub mbCommandPrivate(@) {
	my ($self,$message,$sNick,$sCommand,@tArgs)	= @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $bFound = 0;
	switch($sCommand) {
		case /^die$/i				{ $bFound = 1;
													mbQuit($self,$message,$sNick,@tArgs);
												}
		case /^nick$/i			{ $bFound = 1;
													mbChangeNick($self,$message,$sNick,@tArgs);
												}
		case /^addtimer$/i	{ $bFound = 1;
													mbAddTimer($self,$message,undef,$sNick,@tArgs);
												}
		case /^remtimer$/i	{ $bFound = 1;
													mbRemTimer($self,$message,undef,$sNick,@tArgs);
												}
		case /^timers$/i		{ $bFound = 1;
													mbTimers($self,$message,undef,$sNick,@tArgs);
												}
		case /^register$/i	{ $bFound = 1;
													mbRegister($self,$message,$sNick,@tArgs);
												}
		case /^dump$/i			{ $bFound = 1;
													dumpCmd($self,$message,$sNick,@tArgs);
												}
		case /^msg$/i				{ $bFound = 1;
													msgCmd($self,$message,$sNick,@tArgs);
												}
		case /^say$/i				{ $bFound = 1;
													sayChannel($self,$message,$sNick,@tArgs);
												}
		case /^act$/i				{ $bFound = 1;
													actChannel($self,$message,$sNick,@tArgs);
												}
		case /^status$/i		{ $bFound = 1;
													mbStatus($self,$message,$sNick,undef,@tArgs);
												}
		case /^login$/i			{ $bFound = 1;
													userLogin($self,$message,$sNick,@tArgs);
												}
		case /^pass$/i			{ $bFound = 1;
													userPass($self,$message,$sNick,@tArgs);
												}
		case /^ident$/i			{ $bFound = 1;
													userIdent($self,$message,$sNick,@tArgs);
												}
		case /^cstat$/i			{ $bFound = 1;
													userCstat($self,$message,$sNick,@tArgs);
												}
		case /^adduser$/i		{ $bFound = 1;
													addUser($self,$message,$sNick,@tArgs);
												}
		case /^users$/i			{ $bFound = 1;
													userStats($self,$message,$sNick,undef,@tArgs);
												}
		case /^userinfo$/i	{ $bFound = 1;
													userInfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^addhost$/i		{ $bFound = 1;
													addUserHost($self,$message,$sNick,undef,@tArgs);
												}
		case /^addchan$/i		{ $bFound = 1;
													addChannel($self,$message,$sNick,@tArgs);
												}
		case /^chanset$/i		{ $bFound = 1;
													channelSet($self,$message,$sNick,undef,@tArgs);
												}
		case /^purge$/i			{ $bFound = 1;
													purgeChannel($self,$message,$sNick,@tArgs);
												}
		case /^part$/i			{ $bFound = 1;
													channelPart($self,$message,$sNick,undef,@tArgs);
												}
		case /^join$/i			{ $bFound = 1;
													channelJoin($self,$message,$sNick,@tArgs);
												}
		case /^add$/i				{ $bFound = 1;
													channelAddUser($self,$message,$sNick,undef,@tArgs);
												}
		case /^del$/i				{ $bFound = 1;
													channelDelUser($self,$message,$sNick,undef,@tArgs);
												}
		case /^modinfo$/i		{ $bFound = 1;
													userModinfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^op$/i				{ $bFound = 1;
													userOpChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^deop$/i			{ $bFound = 1;
													userDeopChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^invite$/i		{ $bFound = 1;
													userInviteChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^voice$/i			{ $bFound = 1;
													userVoiceChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^devoice$/i		{ $bFound = 1;
													userDevoiceChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^kick$/i			{ $bFound = 1;
													userKickChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^topic$/i			{ $bFound = 1;
													userTopicChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^showcommands$/i	{ $bFound = 1;
													userShowcommandsChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^chaninfo$/i	{ $bFound = 1;
													userChannelInfo($self,$message,$sNick,undef,@tArgs);
												}
		case /^chanlist$/i	{ $bFound = 1;
													channelList($self,$message,$sNick,undef,@tArgs);
												}
		case /^whoami$/i		{ $bFound = 1;
													userWhoAmI($self,$message,$sNick,@tArgs);
												}
		case /^verify$/i		{ $bFound = 1;
													userVerifyNick($self,$message,$sNick,@tArgs);
												}
		case /^auth$/i			{ $bFound = 1;
													userAuthNick($self,$message,$sNick,@tArgs);
												}
		case /^access$/i		{ $bFound = 1;
													userAccessChannel($self,$message,$sNick,undef,@tArgs);
												}
		case /^addcmd$/i		{ $bFound = 1;
													mbDbAddCommand($self,$message,$sNick,@tArgs);
												}
		case /^remcmd$/i		{ $bFound = 1;
													mbDbRemCommand($self,$message,$sNick,@tArgs);
												}
		case /^modcmd$/i		{ $bFound = 1;
													mbDbModCommand($self,$message,$sNick,@tArgs);
												}
		case /^showcmd$/i		{ $bFound = 1;
													mbDbShowCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{ $bFound = 1;
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^mvcmd$/i			{ $bFound = 1;
													mbDbMvCommand($self,$message,$sNick,@tArgs);
												}
		case /^chowncmd$/i	{ $bFound = 1;
													mbChownCommand($self,$message,$sNick,@tArgs);
												}
		case /^countcmd$/i	{ $bFound = 1;
														mbCountCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^topcmd$/i		{ $bFound = 1;
														mbTopCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^searchcmd$/i	{ $bFound = 1;
														mbDbSearchCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^lastcmd$/i		{ $bFound = 1;
														mbLastCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^owncmd$/i		{ $bFound = 1;
														mbDbOwnersCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^addcatcmd$/i	{ $bFound = 1;
														mbDbAddCategoryCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^chcatcmd$/i	{ $bFound = 1;
														mbDbChangeCategoryCommand($self,$message,$sNick,undef,@tArgs);
												}
		case /^topsay$/i		{ $bFound = 1;
														userTopSay($self,$message,$sNick,undef,@tArgs);
												}
		case /^checkhostchan$/i		{ $bFound = 1;
															mbDbCheckHostnameNickChan($self,$message,$sNick,undef,@tArgs);
														}
		case /^checkhost$/i	{ $bFound = 1;
															mbDbCheckHostnameNick($self,$message,$sNick,undef,@tArgs);
												}
		case /^checknick$/i	{ $bFound = 1;
													mbDbCheckNickHostname($self,$message,$sNick,undef,@tArgs);
												}
		case /^greet$/i			{ $bFound = 1;
													userGreet($self,$message,$sNick,undef,@tArgs);
												}
		case /^nicklist$/i	{ $bFound = 1;
														channelNickList($self,$message,$sNick,undef,@tArgs);
												}
		case /^rnick$/i			{ $bFound = 1;
														randomChannelNick($self,$message,$sNick,undef,@tArgs);
												}
		case /^chanstatlines$/i	{ $bFound = 1;
														channelStatLines($self,$message,undef,$sNick,@tArgs);
													}
		case /^whotalk$/i		{ $bFound = 1;
														whoTalk($self,$message,undef,$sNick,@tArgs);
												}
		case /^birthdate$/i	{ $bFound = 1;
														displayBirthDate($self,$message,$sNick,undef,@tArgs);
												}
		#else								{
		#											$bFound = mbPluginCommand(\%MAIN_CONF,$LOG,$dbh,$irc,$message,undef,$sNick,$sCommand,@tArgs);
		#										}
	}
	unless ( $bFound ) {
		log_message($self,3,$message->prefix . " Private command '$sCommand' not found");
	}
	else {
		#my %GLOBAL_HASH;
		#$GLOBAL_HASH{'WHOIS_VARS'} = \%WHOIS_VARS;
		#$GLOBAL_HASH{'hTimers'} = \%hTimers;
		#return %GLOBAL_HASH;
		return undef;
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
				log_message($self,3,"Checking uptime");
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
				# Uptime
				my $iUptime = time - $self->{iConnectionTimestamp};
				my $days = int($iUptime / 86400);
				my $hours = int(($iUptime - ( $days * 86400 )) / 3600);
				$hours = sprintf("%02d",$hours);
				my $minutes = int(($iUptime - ( $days * 86400 ) - ( $hours * 3600 )) / 60);
				$minutes = sprintf("%02d",$minutes);
				my $seconds = int($iUptime - ( $days * 86400 ) - ( $hours * 3600 ) - ( $minutes * 60 ));
				$seconds = sprintf("%02d",$seconds);
				my $sAnswer = "$days days, $hours" . "h" . "$minutes" . "mn" . "$seconds" . "s";
				
				
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
				unless (defined($sAnswer)) {
					$sAnswer = "Unknown";
				}
				botNotice($self,$sNick,$MAIN_CONF{'main.MAIN_PROG_NAME'} . " v" . $self->{main_prog_version} . " Uptime : $sAnswer");
				botNotice($self,$sNick,"Memory usage (VM $fVmSize MB) (Resident Set $fResSetSize MB) (Shared Memory $fSharedMemSize MB) (Data and Stack $fDataStackSize MB)");
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
					botNotice($self,$sNick,"Utilisateurs authentifiés : " . $sAuthUserStr);
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
					if ((getUserLevel($self,$iMatchingUserLevel) eq "Master") && ($sLevel eq "Owner")) {
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

sub getIdUser(@) {
	my ($self,$sUserHandle) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sQuery = "SELECT id_user FROM USER WHERE nickname=?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sUserHandle)) {
		log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_user = $ref->{'id_user'};
			$sth->finish;
			return $id_user;
		}
		else {
			$sth->finish;
			return undef;
		}
	}
}

sub getUserLevel(@) {
	my ($self,$level) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
								botNotice($self,$sNick,"User : $sUser (Id: $id_user - $sDescription) - created $creation_date - last login $last_login");
								my $sPasswordSet = (defined($sPassword) ? "Password set" : "Password is not set" );
								my $sLoggedIn = (($auth) ? "logged in" : "not logged in" );
								botNotice($self,$sNick,"$sPasswordSet ($sLoggedIn)");
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
						my $sQuery = "SELECT nickname FROM USER WHERE hostmasks LIKE '%" . $tArgs[1] . "%'";
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
																			log_message($self,0,"chansetFlag $sChannel $sChansetAction$sChansetValue");
																			my $id_chanset_list = getIdChansetList($self,$sChansetValue);
																			unless (defined($id_chanset_list)) {
																				botNotice($self,$sNick,"Undefined flag $sChansetValue");
																				logBot($self,$message,$sChannel,"chanset",($sChannel,"Undefined flag $sChansetValue"));
																				return undef;
																			}
																			my $id_channel_set = getIdChannelSet($self,$sChannel,$id_chanset_list);
																			if ( $sChansetAction eq "+" ) {
																				if (defined($id_channel_set)) {
																					botNotice($self,$sNick,"Flag +$sChansetValue is already set for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Flag +$sChansetValue is already set"));
																					return undef;
																				}
																				my $sQuery = "INSERT INTO CHANNEL_SET (id_channel,id_chanset_list) VALUES (?,?)";
																				my $sth = $self->{dbh}->prepare($sQuery);
																				unless ($sth->execute($id_channel,$id_chanset_list)) {
																					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																				}
																				else {
																					logBot($self,$message,$sChannel,"chanset",("Flag $sChansetValue set"));
																				}
																				$sth->finish;
																				return $id_channel;
																			}
																			else {
																				unless (defined($id_channel_set)) {
																					botNotice($self,$sNick,"Flag $sChansetValue is not set for $sChannel");
																					logBot($self,$message,$sChannel,"chanset",("Flag $sChansetValue is not set"));
																					return undef;
																				}
																				my $sQuery = "DELETE FROM CHANNEL_SET WHERE id_channel_set=?";
																				my $sth = $self->{dbh}->prepare($sQuery);
																				unless ($sth->execute($id_channel_set)) {
																					log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
																				}
																				else {
																					logBot($self,$message,$sChannel,"chanset",("Flag $sChansetValue unset"));
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	botNotice($self,$sNick,"Syntax: modinfo [#channel] greet <user> <greet>");
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
																				my $sGreet = join(" ",@tArgs);
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a op $sChannel command");
						$self->{irc}->send_message("MODE",undef,($sChannel,"+o",$tArgs[0]));
						logBot($self,$message,$sChannel,"op",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: op #channel <nick>");
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a deop $sChannel command");
						$self->{irc}->send_message("MODE",undef,($sChannel,"-o",$tArgs[0]));
						logBot($self,$message,$sChannel,"deop",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: deop #channel <nick>");
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued an invite $sChannel command");
						$self->{irc}->send_message("INVITE",undef,($tArgs[0],$sChannel));
						logBot($self,$message,$sChannel,"invite",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued an invite $sChannel command");
						$self->{irc}->send_message("INVITE",undef,($sNick,$sChannel));
						logBot($self,$message,$sChannel,"invite",($sNick));
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a voice $sChannel command");
						$self->{irc}->send_message("MODE",undef,($sChannel,"+v",$tArgs[0]));
						logBot($self,$message,$sChannel,"voice",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: voice #channel <nick>");
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $id_channel = getIdChannel($self,$sChannel);
					if (defined($id_channel)) {
						log_message($self,0,"$sNick issued a devoice $sChannel command");
						$self->{irc}->send_message("MODE",undef,($sChannel,"-v",$tArgs[0]));
						logBot($self,$message,$sChannel,"devoice",@tArgs);
						return $id_channel;
					}
					else {
						botNotice($self,$sNick,"Channel $sChannel does not exist");
						return undef;
					}
				}
				else {
					botNotice($self,$sNick,"Syntax: devoice #channel <nick>");
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
				while (my $ref = $sth->fetchrow_hashref()) {
					my $chanset = $ref->{'chanset'};
					$sChansetFlags .= "+$chanset ";
					$i++;
				}
				if ( $i ) {
					botNotice($self,$sNick,$sChansetFlags);
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
				log_message($self,3,$sQuery);
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
				if ( $actionType eq 'PRIVMSG' ) {
					if ( $actionTo eq '%c' ) {
						if (defined($tArgs[0])) {
							my $sArgs = join(" ",@tArgs);
							unless ( $actionDo =~ /%{2,}n/ ) {
								$actionDo =~ s/%n/$sArgs/g;
							}
						}
						else {
							unless ( $actionDo =~ /%{2,}n/ ) {
								$actionDo =~ s/%n/$sNick/g;
							}
						}
						if ( $actionDo =~ /[^%]*%r/ ) {
							my $sRandomNick = getRandomNick($self,$sChannel);
							$actionDo =~ s/%r/$sRandomNick/g;
						}
						if ( $actionDo =~ /[^%]*%R/ ) {
							my $sRandomNick = getRandomNick($self,$sChannel);
							$actionDo =~ s/%R/$sRandomNick/g;
						}
						if ( $actionDo =~ /[^%]*%s/ ) {
							my $sCommandWithSpaces = $sCommand;
							$sCommandWithSpaces =~ s/_/ /g;
							$actionDo =~ s/%s/$sCommandWithSpaces/g;
						}
						if ( $actionDo =~ /[^%]*%b/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%b/true/g;
							}
							else {
								$actionDo =~ s/%b/false/g;
							}
						}
						if ( $actionDo =~ /[^%]*%B/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%B/true/g;
							}
							else {
								$actionDo =~ s/%B/false/g;
							}
						}
						if ( $actionDo =~ /[^%]*%on/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%on/oui/g;
							}
							else {
								$actionDo =~ s/%on/non/g;
							}
						}
						$actionDo =~ s/[^%]*%c/$sChannel/g;
						$actionDo =~ s/[^%]*%N/$sNick/g;
						my @tActionDo = split(/ /,$actionDo);
						my $pos;
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /%d/ ) {
								$tActionDo[$pos] = int(rand(10) + 1);
							}
						}
						$actionDo = join(" ",@tActionDo);
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /[^%]%dd/ ) {
								$tActionDo[$pos] = int(rand(90) + 10);
							}
						}
						$actionDo = join(" ",@tActionDo);
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /[^%]%ddd/ ) {
								$tActionDo[$pos] = int(rand(900) + 100);
							}
						}
						$actionDo = join(" ",@tActionDo);
						botPrivmsg($self,$sChannel,$actionDo);
					}
					return 1;
				}
				elsif ( $actionType eq 'ACTION' ) {
					if ( $actionTo eq '%c' ) {
						if (defined($tArgs[0])) {
							my $sNickAction = join(" ",@tArgs);
							$actionDo =~ s/%{2,}/%%/g;
							$actionDo =~ s/[^%]*%n/$sNickAction/g;
						}
						else {
							$actionDo =~ s/%{2,}/%%/g;
							$actionDo =~ s/[^%]*%n/$sNick/g;
						}
						if ( $actionDo =~ /[^%]*%r/ ) {
							my $sRandomNick = getRandomNick($self,$sChannel);
							$actionDo =~ s/%r/$sRandomNick/g;
						}
						if ( $actionDo =~ /[^%]*%R/ ) {
							my $sRandomNick = getRandomNick($self,$sChannel);
							$actionDo =~ s/%R/$sRandomNick/g;
						}
						if ( $actionDo =~ /[^%]*%s/ ) {
							my $sCommandWithSpaces = $sCommand;
							$sCommandWithSpaces =~ s/_/ /g;
							$actionDo =~ s/%s/$sCommandWithSpaces/g;
						}
						if ( $actionDo =~ /[^%]*%b/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%b/true/g;
							}
							else {
								$actionDo =~ s/%b/false/g;
							}
						}
						if ( $actionDo =~ /[^%]*%B/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%B/true/g;
							}
							else {
								$actionDo =~ s/%B/false/g;
							}
						}
						if ( $actionDo =~ /[^%]*%on/ ) {
							my $iTrueFalse = int(rand(2));
							if ( $iTrueFalse == 1 ) {
								$actionDo =~ s/%on/oui/g;
							}
							else {
								$actionDo =~ s/%on/non/g;
							}
						}
						$actionDo =~ s/[^%]*%c/$sChannel/g;
						$actionDo =~ s/[^%]*%N/$sNick/g;
						my @tActionDo = split(/ /,$actionDo);
						my $pos;
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /%d/ ) {
								$tActionDo[$pos] = int(rand(10) + 1);
							}
						}
						$actionDo = join(" ",@tActionDo);
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /[^%]%dd/ ) {
								$tActionDo[$pos] = int(rand(90) + 10);
							}
						}
						$actionDo = join(" ",@tActionDo);
						for ($pos=0;$pos<=$#tActionDo;$pos++) {
							if ( $tActionDo[$pos] =~ /[^%]%ddd/ ) {
								$tActionDo[$pos] = int(rand(900) + 100);
							}
						}
						$actionDo = join(" ",@tActionDo);
						botAction($self,$sChannel,$actionDo);
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
			my $sQuery = "SELECT * FROM PUBLIC_COMMANDS WHERE action LIKE '%" . $sCommand . "%' ORDER BY command LIMIT 20";
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
				if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
					my $sQuery = "SELECT event_type,publictext,count(publictext) as hit FROM CHANNEL,CHANNEL_LOG WHERE (event_type='public' OR event_type='action') AND CHANNEL.id_channel=CHANNEL_LOG.id_channel AND name=? AND nick like ? GROUP BY publictext ORDER by hit DESC LIMIT 30";
					my $sth = $self->{dbh}->prepare($sQuery);
					unless ($sth->execute($sChannel,$tArgs[0])) {
						log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
					}
					else {
						my $sTopSay = $tArgs[0] . " : ";
						my $i = 0;
						while (my $ref = $sth->fetchrow_hashref()) {
							my $publictext = $ref->{'publictext'};
							my $event_type = $ref->{'event_type'};
							my $hit = $ref->{'hit'};
							$publictext =~ s/(.)/(ord($1) == 1) ? "" : $1/egs;
							unless (($publictext =~ /^\s*$/) || ($publictext eq ':)') || ($publictext eq ';)') || ($publictext eq ':p') || ($publictext eq ':P') || ($publictext eq ':d') || ($publictext eq ':D') || ($publictext eq ':o') || ($publictext eq ':O') || ($publictext eq '(:') || ($publictext eq '(;') || ($publictext =~ /lol/i) || ($publictext eq 'xD') || ($publictext eq 'XD') || ($publictext eq 'heh') || ($publictext eq 'hah') || ($publictext eq 'huh') || ($publictext eq 'hih') || ($publictext eq '!bang') || ($publictext eq '!reload') || ($publictext eq '!tappe') || ($publictext eq '!duckstats') || ($publictext eq '=D') || ($publictext eq '=)') || ($publictext eq ';p') || ($publictext eq ':>') || ($publictext eq ';>')) {
								if ( $event_type eq "action" ) {
									$sTopSay .= String::IRC->new("$publictext ($hit) ")->bold;
								}
								else {
									$sTopSay .= "$publictext ($hit) ";
								}
								$i++;
							}
						}
						if ( $i ) {
							unless ($isPrivate) {
								botPrivmsg($self,$sChannelDest,substr($sTopSay,0,300));
							}
							else {
								botNotice($self,$sNick,substr($sTopSay,0,300));
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
					botNotice($self,$sNick,"Syntax: topsay [#channel] <nick>");
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
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
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
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
			my $sQuery = "SELECT greet FROM USER,USER_CHANNEL,CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND CHANNEL.id_channel=USER_CHANNEL.id_channel AND name=? AND nickname=?";
			my $sth = $self->{dbh}->prepare($sQuery);
			unless ($sth->execute($sChannel,$tArgs[0])) {
				log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
			}
			else {
				if (my $ref = $sth->fetchrow_hashref()) {
					my $greet = $ref->{'greet'};
					if (defined($greet)) {
						unless ($isPrivate) {
							botPrivmsg($self,$sChannelDest,"greet on $sChannel (" . $tArgs[0] . ") $greet");
						}
						else {
							botNotice($self,$sNick,"greet on $sChannel (" . $tArgs[0] . ") $greet");
						}
					}
					else {
						unless ($isPrivate) {
							botPrivmsg($self,$sChannelDest,"No greet for " . $tArgs[0] . " on $sChannel");
						}
						else {
							botNotice($self,$sNick,"No greet for " . $tArgs[0] . " on $sChannel");
						}
					}
				}
				else {
					unless ($isPrivate) {
						botPrivmsg($self,$sChannelDest,"No greet for " . $tArgs[0] . " on $sChannel");
					}
					else {
						botNotice($self,$sNick,"No greet for " . $tArgs[0] . " on $sChannel");
					}
				}
				my $sNoticeMsg = $message->prefix . " greet on " . $tArgs[0] . " for $sChannel";
				logBot($self,$message,$sChannelDest,"greet",$sNoticeMsg);
				$sth->finish;
		}
	}
	else {
		botNotice($self,$sNick,"Syntax: greet [#channel] <nick>");
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

sub displayYoutubeDetails(@) {
	my ($self,$message,$sNick,$sChannel,$sText) = @_;
	my %MAIN_CONF = %{$self->{MAIN_CONF}};
	my $sYoutubeId;
	log_message($self,3,"displayYoutubeDetails() $sText");
	if ( $sText =~ /http.*:\/\/www\.youtube\..*\/watch/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch\?v=//;
		#my $sTempYoutubeId = ($sText =~ m/^.*(http:\/\/[^ ]+).*$]/)[0];
	}
	elsif ( $sText =~ /http.*:\/\/m\.youtube\..*\/watch/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*watch\?v=//;
	}
	elsif ( $sText =~ /http.*:\/\/youtu\.be.*/i ) {
		$sYoutubeId = $sText;
		$sYoutubeId =~ s/^.*youtu\.be\///;
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
		unless ( open YOUTUBE_INFOS, "curl -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\" |" ) {
			log_message(0,"displayYoutubeDetails() Could not get YOUTUBE_INFOS from API using $APIKEY");
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
				my %hYoutubeItems = %{$tYoutubeItems[0][0]};
				log_message($self,4,"displayYoutubeDetails() sYoutubeInfo Items : " . Dumper(%hYoutubeItems));
				$sViewCount = "vue $hYoutubeItems{'statistics'}{'viewCount'} fois";
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
					botPrivmsg($self,$sChannel,$sMsgSong);
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
				log_message($self,3,"displayYoutubeDetails() curl empty result for : curl -f -s \"https://www.googleapis.com/youtube/v3/videos?id=$sYoutubeId&key=$APIKEY&part=snippet,contentDetails,statistics,status\"");
			}
		}
	}
	else {
		log_message($self,3,"displayYoutubeDetails() sYoutubeId could not be determined");
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
		my $commandQuit;
		my $userhostQuit;
		my $argsQuit;
		
		my $sQuery = "SELECT * FROM EVENT_LOG WHERE nick like ? ORDER BY ts DESC LIMIT 1";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute()) {
			log_message($self,1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $sCommandText;
			if (my $ref = $sth->fetchrow_hashref()) {
				$tsQuit = $ref->{'ts'};
				$commandQuit = $ref->{'command'};
				$userhostQuit = $ref->{'userhost'};
				$argsQuit = $ref->{'args'};
			}
		}
		
		my $tsPart;
		my $channelPart;
		my $msgPart;
		my $userhostPart;
		# Part vars from CHANNEL_LOG
		$sQuery = "SELECT * FROM USER,CHANNEL_LOG,CHANNEL WHERE CHANNEL.id_channel=CHANNEL_LOG.id_channel AND CHANNEL.name like ? AND nick like ? AND event_type='part' ORDER BY ts DESC LIMIT 1";
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
			}
		}
		
		unless (defined($tsQuit)) { $tsQuit = 0; }
		unless (defined($tsPart)) { $tsQuit = 0; }
		if (( $tsQuit == 0) && ( $tsPart == 0)) {
			botPrivmsg($self,$sChannel,"I don't remember nick ". $tArgs[0]);
		}
		else {
			if ( $tsPart >= $tsQuit ) {
				my $sDatePart = time2str("%m/%d/%Y %H:%M:%S", $tsPart);
				botPrivmsg($self,$sChannel,$tArgs[0] . "($userhostPart) was last seen parting $sChannel : $sDatePart ($msgPart)");
			}
			elsif ( $tsQuit != 0) {
				my $sDateQuit = time2str("%m/%d/%Y %H:%M:%S", $tsQuit);
				botPrivmsg($self,$sChannel,$tArgs[0] . "($userhostQuit) was last seen quitting : $sDateQuit ($argsQuit)");
			}
			else {
				
			}
		}
		
		logBot($self,$message,$sChannel,"seen",@tArgs);
		$sth->finish;
	}
}

1;