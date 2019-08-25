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
use POSIX 'setsid';
use Getopt::Long;
use File::Basename;
use Mediabot::Mediabot;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::IRC;
use Switch;
use Data::Dumper;

# +---------------------------------------------------------------------------+
# !          SETTINGS                                                         !
# +---------------------------------------------------------------------------+
my $CONFIG_FILE;
my $MAIN_PROG_VERSION;
my $MAIN_PROG_CHECK_CONFIG = 0;
my $MAIN_PID_FILE;
my $MAIN_PROG_DAEMON = 0;

# +---------------------------------------------------------------------------+
# !          GLOBAL VARS                                                      !
# +---------------------------------------------------------------------------+


# +---------------------------------------------------------------------------+
# !          SUBS DECLARATION                                                 !
# +---------------------------------------------------------------------------+
sub usage(@);
sub catch_hup(@);
sub catch_term(@);
sub reconnect(@);

# +---------------------------------------------------------------------------+
# !          IRC FUNCTIONS                                                    !
# +---------------------------------------------------------------------------+
sub on_timer_tick(@);
sub on_login(@);
sub on_private(@);
sub on_motd(@);
sub on_message_INVITE(@);
sub on_message_KICK(@);
sub on_message_MODE(@);
sub on_message_NICK(@);
sub on_message_NOTICE(@);
sub on_message_QUIT(@);
sub on_message_PART(@);
sub on_message_PRIVMSG(@);
sub on_message_TOPIC(@);
sub on_message_LIST(@);
sub on_message_RPL_NAMEREPLY(@);
sub on_message_RPL_ENDOFNAMES(@);
sub on_message_WHO(@);
sub on_message_WHOIS(@);
sub on_message_WHOWAS(@);
sub on_message_JOIN(@);

sub on_message_001(@);
sub on_message_002(@);
sub on_message_003(@);
sub on_message_RPL_WHOISUSER(@);

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+
my $sFullParams = join(" ",@ARGV);
my $sServer;

# Get version
unless (open VERSION, "VERSION") {
	print STDERR "Could not get version from VERSION file\n";
	$MAIN_PROG_VERSION = "Undefined";
}
else {
	my $line;
	if (defined($line=<VERSION>)) {
		chomp($line);
		$MAIN_PROG_VERSION = $line;
	}
	else {
		$MAIN_PROG_VERSION = "Undefined";
	}
}

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

unless (open PGREP, "pgrep -fl \"mediabot.pl --conf=.*$CONFIG_FILE\" |" ) {
	if (defined(my $line=<PGREP>)) {
		print STDERR "Another instance is running ($line)";
		exit 1;
	}
}

# Daemon mode actions
if ( $MAIN_PROG_DAEMON ) {
		print STDERR "Mediabot v$MAIN_PROG_VERSION starting in daemon mode\n";
		umask 0;
		open STDIN, '/dev/null'   or die "Can't read /dev/null: $!";
		open STDOUT, '>/dev/null' or die "Can't write to /dev/null: $!";
		open STDERR, '>/dev/null' or die "Can't write to /dev/null: $!";
		defined(my $pid = fork)   or die "Can't fork: $!";
		exit if $pid;
		setsid                    or die "Can't start a new session: $!";
}

my $mediabot = Mediabot->new({
	config_file => $CONFIG_FILE,
	main_prog_version => $MAIN_PROG_VERSION,
	server => $sServer,
});

# Load configuration
$mediabot->readConfigFile();

# Init log file
$mediabot->init_log();

# Check config
if ( $MAIN_PROG_CHECK_CONFIG != 0 ) {
	$mediabot->getConfig();
	$mediabot->clean_and_exit(0);
}

# Database connection
$mediabot->dbConnect();

# Check USER table and fail if not present
$mediabot->dbCheckTables();

# Log out all user at start
$mediabot->dbLogoutUsers();

# Pick IRC Server
$mediabot->pickServer();

my $loop = IO::Async::Loop->new;
$mediabot->setLoop($loop);

my $timer = IO::Async::Timer::Periodic->new(
    interval => 5,
    on_tick => \&on_timer_tick,
);
$mediabot->setMainTimerTick($timer);

my $irc = Net::Async::IRC->new(
  on_message_text => \&on_private,
  on_message_motd => \&on_motd,
  on_message_INVITE => \&on_message_INVITE,
  on_message_KICK => \&on_message_KICK,
  on_message_MODE => \&on_message_MODE,
  on_message_NICK => \&on_message_NICK,
  on_message_NOTICE => \&on_message_NOTICE,
  on_message_QUIT => \&on_message_QUIT,
  on_message_PART => \&on_message_PART,
  on_message_PRIVMSG => \&on_message_PRIVMSG,
  on_message_TOPIC => \&on_message_TOPIC,
  on_message_LIST => \&on_message_LIST,
  on_message_RPL_NAMEREPLY => \&on_message_RPL_NAMEREPLY,
  on_message_RPL_ENDOFNAMES => \&on_message_RPL_ENDOFNAMES,
  on_message_WHO => \&on_message_WHO,
  on_message_WHOIS => \&on_message_WHOIS,
  on_message_WHOWAS => \&on_message_WHOWAS,
  on_message_JOIN => \&on_message_JOIN,
  
  on_message_001 => \&on_message_001,
  on_message_002 => \&on_message_002,
  on_message_003 => \&on_message_003,
  on_message_RPL_WHOISUSER => \&on_message_RPL_WHOISUSER,
);

$mediabot->setIrc($irc);

$loop->add($irc);

my $sConnectionNick = $mediabot->getConnectionNick();
my $sServerPass = $mediabot->getServerPass();
my $sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : $sServerPass );
my $bNickTriggerCommand =$mediabot->getNickTrigger();
$mediabot->log_message(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

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
sub usage(@) {
        my ($strErr) = @_;
        if (defined($strErr)) {
                print STDERR "Error : " . $strErr . "\n";
        }
        print STDERR "Usage: " . basename($0) . "--conf <config_file> [--check] [--daemon] [--server <hostname>]\n";
        exit 4;
}

sub on_timer_tick(@) {
	my @params = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	#$mediabot->log_message(3,"---------------------------------------------------------------");
	#$mediabot->log_message(3,Dumper(@params));
	#$mediabot->log_message(3,"---------------------------------------------------------------");
	$mediabot->log_message(4,"on_timer_tick() tick");
	# update pid file
	my $sPidFilename = $MAIN_CONF{'main.MAIN_PID_FILE'};
	unless (open PID, ">$sPidFilename") {
		print STDERR "Could not open $sPidFilename for writing.\n";
	}
	else {
		print PID "$$";
		close PID;
	}
	unless ($irc->is_connected) {
		if ($mediabot->getQuit()) {
			$mediabot->log_message(0,"Disconnected from server");
			$mediabot->clean_and_exit(0);
		}
		else {
			$mediabot->setServer(undef);
			$loop->stop;
			$mediabot->log_message(0,"Lost connection to server. Waiting 300 seconds to reconnect");
			sleep 300;
			reconnect();
		}
	}
}

sub on_message_NOTICE(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($who, $what) = @{$hints}{qw<prefix_name text>};
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	my @tArgs = $message->args;
	if (defined($who) && ($who ne "")) {
		if (defined($tArgs[0]) && (substr($tArgs[0],0,1) eq '#')) {
			$mediabot->log_message(0,"-$who:" . $tArgs[0] . "- $what");
			$mediabot->logBotAction($message,"notice",$sNick,$tArgs[0],$what);
		}
		else {
			$mediabot->log_message(0,"-$who- $what");
		}
		if (defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ( $MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1 ) && defined($MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'} ne "") && defined($MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'} ne "") && defined($MAIN_CONF{'undernet.UNET_CSERVICE_PASSWORD'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_PASSWORD'} ne "")) {
			# Undernet CService login
			my $sSuccesfullLoginFrText = "AUTHENTIFICATION R.USSIE pour " . $MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'};
			my $sSuccesfullLoginEnText = "AUTHENTICATION SUCCESSFUL as " . $MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'};
			if (($who eq "X") && (($what =~ /USSIE/) || ($what eq $sSuccesfullLoginEnText)) && defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1) && ($MAIN_CONF{'connection.CONN_USERMODE'} =~ /x/)) {
				$self->write("MODE " . $self->nick_folded . " +x\x0d\x0a");
				$self->change_nick( $MAIN_CONF{'connection.CONN_NICK'} );
				$mediabot->joinChannels();
		  }
		}
		elsif (defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ( $MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 2 ) && defined($MAIN_CONF{'freenode.FREENODE_NICKSERV_PASSWORD'}) && ($MAIN_CONF{'freenode.FREENODE_NICKSERV_PASSWORD'} ne "")) {
			if (($who eq "NickServ") && (($what =~ /This nickname is registered/) && defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 2))) {
				$mediabot->botPrivmsg("NickServ","identify " . $MAIN_CONF{'freenode.FREENODE_NICKSERV_PASSWORD'});
				$mediabot->joinChannels();
		  }
		}
	}
	else {
		$mediabot->log_message(0,"$what");
	}
}

sub on_login(@) {
	my ( $self, $message, $hints ) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	$mediabot->log_message(0,"on_login() Connected to irc server " . $mediabot->getServerHostname());
	$mediabot->setQuit(0);
	$mediabot->setConnectionTimestamp(time);
	
	# Undernet : authentication to channel service if credentials are defined
	if (defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ( $MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1 ) && defined($MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'} ne "") && defined($MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'} ne "") && defined($MAIN_CONF{'undernet.UNET_CSERVICE_PASSWORD'}) && ($MAIN_CONF{'undernet.UNET_CSERVICE_PASSWORD'} ne "")) {
		$mediabot->log_message(0,"on_login() Logging to " . $MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'});
		$mediabot->botPrivmsg($MAIN_CONF{'undernet.UNET_CSERVICE_LOGIN'},"login " . $MAIN_CONF{'undernet.UNET_CSERVICE_USERNAME'} . " "  . $MAIN_CONF{'undernet.UNET_CSERVICE_PASSWORD'});
  }
  
  # Set user modes
  if (defined($MAIN_CONF{'connection.CONN_USERMODE'})) {
  	if ( substr($MAIN_CONF{'connection.CONN_USERMODE'},0,1) eq '+') {  		
  		my $sUserMode = $MAIN_CONF{'connection.CONN_USERMODE'};
  		if (defined($MAIN_CONF{'connection.CONN_NETWORK_TYPE'}) && ( $MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1 )) {
  			$sUserMode =~ s/x//;
  		}
  		$mediabot->log_message(0,"on_login() Setting user mode $sUserMode");
  		$self->write("MODE " . $MAIN_CONF{'connection.CONN_NICK'} . " +" . $sUserMode . "\x0d\x0a");
  	}
  }
  
  # First join console chan
  my ($id_channel,$name,$chanmode,$key) = $mediabot->getConsoleChan();
  unless (defined($id_channel)) {
  	$mediabot->log_message(0,"Warning no console channel defined, run configure again or read documentation");
  }
  else {
  	$mediabot->joinChannel($name,$key);
  }
  
  # Join other channels
  unless ((($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 1) && ($MAIN_CONF{'connection.CONN_USERMODE'} =~ /x/)) || (($MAIN_CONF{'connection.CONN_NETWORK_TYPE'} == 2) && defined($MAIN_CONF{'freenode.FREENODE_NICKSERV_PASSWORD'}) && ($MAIN_CONF{'freenode.FREENODE_NICKSERV_PASSWORD'} ne ""))) {
		$mediabot->joinChannels();
	}
	$loop->add( $timer );
	$timer->start;
}

sub on_private(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($who, $what) = @{$hints}{qw<prefix_name text>};
	$mediabot->log_message(2,"on_private() -$who- $what");
}

sub on_message_INVITE(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($inviter_nick,$invited_nick,$target_name) = @{$hints}{qw<inviter_nick invited_nick target_name>};
	unless ($self->is_nick_me($inviter_nick)) {
		$mediabot->log_message(0,"* $inviter_nick invites you to join $target_name");
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
		$mediabot->log_message(0,"$invited_nick has been invited to join $target_name");
	}
}

sub on_message_KICK(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($kicker_nick,$target_name,$kicked_nick,$text) = @{$hints}{qw<kicker_nick target_name kicked_nick text>};
	if ($self->is_nick_me($kicked_nick)) {
		$mediabot->log_message(0,"* you were kicked from $target_name by $kicker_nick ($text)");
		$mediabot->joinChannel($target_name);
	}
	else {
		$mediabot->log_message(2,"$target_name: $kicked_nick was kicked by $kicker_nick ($text)");
		$mediabot->channelNicksRemove($target_name,$kicked_nick);
	}
	$mediabot->logBotAction($message,"kick",$kicker_nick,$target_name,"$kicked_nick ($text)");
}

sub on_message_MODE(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name,$modechars,$modeargs) = @{$hints}{qw<target_name modechars modeargs>};
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	my @tArgs = $message->args;
	if ( substr($target_name,0,1) eq '#' ) {
		shift @tArgs;
		my $sModes = $tArgs[0];
		shift @tArgs;
		my $sTargetNicks = join(" ",@tArgs);
		$mediabot->log_message(2,"<$target_name> $sNick sets mode $sModes $sTargetNicks");
		$mediabot->logBotAction($message,"mode",$sNick,$target_name,"$sModes $sTargetNicks");
	}
	else {
		$mediabot->log_message(2,"$target_name sets mode " . $tArgs[1]);
	}
}

sub on_message_NICK(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my %hChannelsNicks = ();
	if (defined($mediabot->gethChannelNicks())) {
		%hChannelsNicks = %{$mediabot->gethChannelNicks()};
	}
	my ($old_nick,$new_nick) = @{$hints}{qw<old_nick new_nick>};
	if ($self->is_nick_me($old_nick)) {
		$mediabot->log_message(0,"* Your nick is now $new_nick");
		$self->_set_nick($new_nick);
	}
	else {
		$mediabot->log_message(2,"* $old_nick is now known as $new_nick");
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

sub on_message_QUIT(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my %hChannelsNicks = ();
	if (defined($mediabot->gethChannelNicks())) {
		%hChannelsNicks = %{$mediabot->gethChannelNicks()};
	}
	my ($text) = @{$hints}{qw<text>};
	unless(defined($text)) { $text="";}
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	if (defined($text) && ($text ne "")) {
		$mediabot->log_message(2," * Quits: $sNick ($sIdent\@$sHost) ($text)");
		$mediabot->logBotAction($message,"quit",$sNick,undef,$text);
	}
	else {
		$mediabot->log_message(2," * Quits: $sNick ($sIdent\@$sHost) ()");
		$mediabot->logBotAction($message,"quit",$sNick,undef,"");
	}
	for my $sChannel (keys %hChannelsNicks) {
	  $mediabot->channelNicksRemove($sChannel,$sNick);
	}
}

sub on_message_PART(@){
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name,$text) = @{$hints}{qw<target_name text>};
	unless(defined($text)) { $text="";}
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	my @tArgs = $message->args;
	shift @tArgs;
	if (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		$mediabot->log_message(2,"<$target_name> * Parts: $sNick ($sIdent\@$sHost) (" . $tArgs[0] . ")");
		$mediabot->logBotAction($message,"part",$sNick,$target_name,$tArgs[0]);
	}
	else {
		$mediabot->log_message(2,"<$target_name> * Parts: $sNick ($sIdent\@$sHost)");
		$mediabot->logBotAction($message,"part",$sNick,$target_name,"");
		$mediabot->channelNicksRemove($target_name,$sNick);
	}
}

sub on_message_PRIVMSG(@) {
	my ($self, $message, $hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($who, $where, $what) = @{$hints}{qw<prefix_nick targets text>};
	if ( substr($where,0,1) eq '#' ) {
		# Message on channel
		if (defined($MAIN_CONF{'main.MAIN_PROG_LIVE'}) && ($MAIN_CONF{'main.MAIN_PROG_LIVE'} =1)) {
			$mediabot->log_message(0,"[LIVE] $where: <$who> $what");
		}
		my ($sCommand,@tArgs) = split(/\s+/,$what);
		if (substr($what, 0, 1) eq $MAIN_CONF{'main.MAIN_PROG_CMD_CHAR'}) {
        $sCommand = substr($sCommand,1);
        $sCommand =~ tr/A-Z/a-z/;
        if (defined($sCommand) && ($sCommand ne "")) {
        	$mediabot->mbCommandPublic($message,$where,$who,$sCommand,@tArgs);
        }
		}
		elsif (($sCommand eq $self->nick_folded) && $bNickTriggerCommand) {
			$what =~ s/^\S+\s*//;
			($sCommand,@tArgs) = split(/\s+/,$what);
			$sCommand =~ tr/A-Z/a-z/;
      if (defined($sCommand) && ($sCommand ne "")) {
      	$mediabot->mbCommandPublic($message,$where,$who,$sCommand,@tArgs);
      }
		}
		elsif ( ( $what =~ /http.*:\/\/www\.youtube\..*\/watch/i ) || ( $what =~ /http.*:\/\/m\.youtube\..*\/watch/i ) || ( $what =~ /http.*:\/\/youtu\.be.*/i ) ) {
			my $id_chanset_list = $mediabot->getIdChansetList("Youtube");
			if (defined($id_chanset_list)) {
				my $id_channel_set = $mediabot->getIdChannelSet($where,$id_chanset_list);
				if (defined($id_channel_set)) {
					$mediabot->displayYoutubeDetails($message,$who,$where,$what);
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
			if (defined($MAIN_CONF{'main.MAIN_PROG_LIVE'}) && ($MAIN_CONF{'main.MAIN_PROG_LIVE'} =1)) {
				$mediabot->log_message(0,"[LIVE] $where: <$who> $what");
			}
		}
		my ($sCommand,@tArgs) = split(/\s+/,$what);
    $sCommand =~ tr/A-Z/a-z/;
    $mediabot->log_message(3,"sCommands = $sCommand");
    if (defined($sCommand) && ($sCommand ne "")) {
    	switch($sCommand) {
    		case /^debug$/i		{ 
														$mediabot->mbDebug($message,$who,@tArgs);
													}
				case "restart"		{ 
														if ($MAIN_PROG_DAEMON) {
										    			$mediabot->mbRestart($message,$who,($sFullParams));
										    		}
										    		else {
										    			$mediabot->botNotice($who,"restart command can only be used in daemon mode (use --daemon to launch the bot)");
										    		}
													}
				case "jump"				{ 
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
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name,$text) = @{$hints}{qw<target_name text>};
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	unless(defined($text)) { $text="";}
	$mediabot->log_message(2,"<$target_name> * $sNick changes topic to '$text'");
	$mediabot->logBotAction($message,"topic",$sNick,$target_name,$text);
}

sub on_message_LIST(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name) = @{$hints}{qw<target_name>};
	$mediabot->log_message(2,"on_message_LIST() $target_name");
}

sub on_message_RPL_NAMEREPLY(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
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

sub on_message_RPL_ENDOFNAMES(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name) = @{$hints}{qw<target_name>};
	$mediabot->log_message(2,"on_message_RPL_ENDOFNAMES() $target_name");
	$mediabot->sethChannelsNicksEndOnChan($target_name,1);
}

sub on_message_WHO(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name) = @{$hints}{qw<target_name>};
	$mediabot->log_message($2,"on_message_WHO() $target_name");
}

sub on_message_WHOIS(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	$mediabot->log_message(3,Dumper($message));
	my ($target_name) = @{$hints}{qw<target_name>};
	$mediabot->log_message(2,"on_message_WHOIS() $target_name");
}

sub on_message_WHOWAS(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my ($target_name) = @{$hints}{qw<target_name>};
	$mediabot->log_message(2,"on_message_WHOWAS() $target_name");
}

sub on_message_JOIN(@) {
	my ($self,$message,$hints) = @_;
	my %MAIN_CONF = %{$mediabot->getMainConf()};
	my %hChannelsNicks = ();
	if (defined($mediabot->gethChannelNicks())) {
		%hChannelsNicks = %{$mediabot->gethChannelNicks()};
	}
	my ($target_name) = @{$hints}{qw<target_name>};
	my ($sNick,$sIdent,$sHost) = $mediabot->getMessageNickIdentHost($message);
	if ( $sNick eq $self->nick ) {
		$mediabot->log_message(2," * Now talking in $target_name");
	}
	else {
		$mediabot->log_message(2,"<$target_name> * Joins $sNick ($sIdent\@$sHost)");
		$mediabot->userOnJoin($message,$target_name,$sNick);
		push @{$hChannelsNicks{$target_name}}, $sNick;
		$mediabot->sethChannelNicks(\%hChannelsNicks);
	}
	$mediabot->logBotAction($message,"join",$sNick,$target_name,"");
}

sub on_message_001(@) {
	my ($self,$message,$hints) = @_;
	my ($text) = @{$hints}{qw<text>};
	$mediabot->log_message($self,0,"001 $text");
}

sub on_message_002(@) {
	my ($self,$message,$hints) = @_;
	my ($text) = @{$hints}{qw<text>};
	$mediabot->log_message($self,0,"002 $text");
}

sub on_message_003(@) {
	my ($self,$message,$hints) = @_;
	my ($text) = @{$hints}{qw<text>};
	$mediabot->log_message($self,0,"003 $text");
}

sub on_motd(@) {
	my ($self,$message,$hints) = @_;
	my @motd_lines = @{$hints}{qw<motd>};
	foreach my $line (@{$motd_lines[0]}) {
		$mediabot->log_message($self,0,"-motd- $line");
	}
}

sub on_message_RPL_WHOISUSER(@) {
	my ($self,$message,$hints) = @_;
	my %WHOIS_VARS = %{$mediabot->getWhoisVar()};
	my @tArgs = $message->args;
	my $sHostname = $tArgs[3];
	my ($target_name,$ident,$host,$flags,$realname) = @{$hints}{qw<target_name ident host flags realname>};
	$mediabot->log_message(0,"$target_name is $ident\@$sHostname $flags $realname");
	if (defined($WHOIS_VARS{'nick'}) && ($WHOIS_VARS{'nick'} eq $target_name) && defined($WHOIS_VARS{'sub'}) && ($WHOIS_VARS{'sub'} ne "")) {
		switch($WHOIS_VARS{'sub'}) {
			case "userVerifyNick" {
				$mediabot->log_message(3,"WHOIS userVerifyNick");
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
				$mediabot->log_message(3,"WHOIS userAuthNick");
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
								$mediabot->log_message(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
				$mediabot->log_message(3,"WHOIS userAccessChannel");
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
								$mediabot->log_message(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
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
		}
	}
}

sub reconnect(@) {
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
	  on_message_text => \&on_private,
	  on_message_motd => \&on_motd,
	  on_message_INVITE => \&on_message_INVITE,
	  on_message_KICK => \&on_message_KICK,
	  on_message_MODE => \&on_message_MODE,
	  on_message_NICK => \&on_message_NICK,
	  on_message_NOTICE => \&on_message_NOTICE,
	  on_message_QUIT => \&on_message_QUIT,
	  on_message_PART => \&on_message_PART,
	  on_message_PRIVMSG => \&on_message_PRIVMSG,
	  on_message_TOPIC => \&on_message_TOPIC,
	  on_message_LIST => \&on_message_LIST,
	  on_message_RPL_NAMEREPLY => \&on_message_RPL_NAMEREPLY,
	  on_message_RPL_ENDOFNAMES => \&on_message_RPL_ENDOFNAMES,
	  on_message_WHO => \&on_message_WHO,
	  on_message_WHOIS => \&on_message_WHOIS,
	  on_message_WHOWAS => \&on_message_WHOWAS,
	  on_message_JOIN => \&on_message_JOIN,
	  
	  on_message_001 => \&on_message_001,
	  on_message_002 => \&on_message_002,
	  on_message_003 => \&on_message_003,
	  on_message_RPL_WHOISUSER => \&on_message_RPL_WHOISUSER,
	);

	$mediabot->setIrc($irc);

	$loop->add($irc);

	$sConnectionNick = $mediabot->getConnectionNick();
	$sServerPass = $mediabot->getServerPass();
	$sServerPassDisplay = ( $sServerPass eq "" ? "none defined" : $sServerPass );
	$bNickTriggerCommand =$mediabot->getNickTrigger();
	$mediabot->log_message(0,"Trying to connect to " . $mediabot->getServerHostname() . ":" . $mediabot->getServerPort() . " (pass : $sServerPassDisplay)");

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