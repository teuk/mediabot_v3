use strict;
use warnings;
use Test::More;
use lib '.', 't/lib';
use IO::Async::Loop;
use Net::Async::IRC;
use Protocol::IRC::Message;
use Mediabot::Mediabot;
use Mediabot::Update;
use Mediabot::XAuth;
use Scalar::Util qw(refaddr);

# Evaluate the actual executable callbacks, without booting the application or
# connecting to an external network. Feed real Protocol::IRC message objects
# through Net::Async::IRC's named numeric dispatch.
open my $fh,'<','mediabot.pl' or die $!;local $/;my $source=<$fh>;close $fh;
sub extract {
 my ($name)=@_;my ($s)=$source=~/^(sub\s+\Q$name\E\s*\{.*?^\})/ms;
 die "Missing callback $name" unless defined $s;return $s;
}
{package XH838Conf;sub get{$_[0]{$_[1]}}}
{package XH838Log;sub log{push @{$_[0]{lines}},$_[2];1}}
{package XH838IRC;use mro 'c3';our @ISA=('Net::Async::IRC');sub is_connected{1}sub send_message{push @{$_[0]{sent}},[@_[1..$#_]];1}}
{package XH838Channel;sub get_description{$_[0]{description}}sub get_name{$_[0]{name}}sub get_key{''}sub get_auto_join{1}}
{package XH838Bot;our @ISA=('Mediabot');sub getServerHostname{'server.undernet.org'}sub onStartTimers{1}sub setLastRandomQuote{1}
 sub joinChannels{$_[0]{joined}++}sub joinChannel{push @{$_[0]{console}},$_[1]}sub getWhoisVar{$_[0]{whois_vars}||{}}sub get_user_from_whois{$_[0]{legacy_auth_lookup}++;return undef}
 sub botPrivmsg{push @{$_[0]{legacy}},[@_[1..$#_]]}sub getLoop{$_[0]{loop}}
}
{
 package XH838Hooks;
 our ($mediabot,$loop);
 sub log_debug_args{1}
 sub _partyline_whois_write{push @{$mediabot->{partyline_lines}},[@_];1}
}
my @hooks=qw(_irc_message_args _irc_target_is_channel on_login on_message_NOTICE on_message_RPL_WHOISUSER on_message_RPL_WHOISACCOUNT on_message_RPL_ENDOFWHOIS on_message_221);
my $compiled=eval 'package XH838Hooks; use strict; use warnings; our ($mediabot,$loop); '.join("\n",map{extract($_)}@hooks).';1;';
ok($compiled,'actual startup, notice and WHOIS/mode callbacks compile') or diag $@;
die $@ unless $compiled;
no warnings qw(redefine once);
local *Mediabot::Update::update_completion_on_login=sub{1};
my $loop=IO::Async::Loop->new;
my %bind;
for my $name (qw(on_message_RPL_WHOISUSER on_message_RPL_WHOISACCOUNT on_message_RPL_ENDOFWHOIS on_message_221 on_message_NOTICE)) {
 like($source,qr/\Q$name\E\s*=>\s*\\&\Q$name\E/,"$name registered on the real IRC constructor");
 $bind{$name}=XH838Hooks->can($name);
}
my $irc=XH838IRC->new(%bind);$irc->_set_nick('Bot');
my $conf=bless {'connection.CONN_NETWORK_TYPE'=>1,'connection.CONN_USERMODE'=>'+iwx',
 'connection.CONN_NICK'=>'PreferredNick','undernet.UNET_CSERVICE_LOGIN'=>'x@channels.undernet.org',
 'undernet.UNET_CSERVICE_USERNAME'=>'TestAccount','undernet.UNET_CSERVICE_PASSWORD'=>'YOUR_X_TEST_PASSWORD'},'XH838Conf';
my $bot=bless {conf=>$conf,irc=>$irc,logger=>bless({lines=>[]},'XH838Log'),loop=>$loop,
 channels=>{console=>bless({name=>'#console',description=>'console'},'XH838Channel')}},'XH838Bot';
my $clock=100;$bot->{xauth_controller}=Mediabot::XAuth->new(bot=>$bot,now=>sub{$clock});
$XH838Hooks::mediabot=$bot;$XH838Hooks::loop=$loop;
XH838Hooks::on_login($irc,undef,{});
is_deeply($irc->{sent},[['WHOIS',undef,'bot'],['MODE',undef,'bot','+iw']],'real startup verifies live nick and sends one valid initial mode token');
is(scalar @{$bot->{console}||[]},0,'real startup does not join console before cloak proof');
is($bot->{joined}//0,0,'real startup does not join other channels before proof');
sub feed {my($line)=@_;$irc->incoming_message(Protocol::IRC::Message->new_from_line($line))}
feed(':X!not-service@fake.example NOTICE Bot :AUTHENTICATION SUCCESSFUL as TestAccount');
is($bot->{joined}//0,0,'spoofed/localized success NOTICE cannot authenticate or join');
$bot->{whois_vars}={nick=>'Bot',sub=>'userAuthNick',caller=>'operator'};
feed(':server.undernet.org 311 Bot Bot ident actual.example * :Bot');
is($bot->{legacy_auth_lookup}//0,0,'owned self-probe cannot replay a stale bot-user authentication callback');
$bot->{whois_vars}={};
feed(':server.undernet.org 318 Bot Bot :End of WHOIS');
is($irc->{sent}[-1][0],'PRIVMSG','real WHOIS end starts LOGIN on a completed negative result');
is($irc->{sent}[-1][2],'x@channels.undernet.org','credentials use the configured server-qualified service');
$clock+=5;$bot->xauth->tick;
feed(':server.undernet.org 311 Bot Bot ident actual.example * :Bot');
feed(':server.undernet.org 330 Bot Bot TestAccount :is logged in as');
feed(':server.undernet.org 318 Bot Bot :End of WHOIS');
is($bot->xauth->status->{state},'checking_cloak','real numeric 330 drives account verification');
feed(':server.undernet.org 221 Bot +iw');
is_deeply($irc->{sent}[-2],['MODE',undef,'bot','+x'],'real mode query requests +x on actual nick');
feed(':server.undernet.org 221 Bot +iwx');
is($bot->xauth->status->{state},'authenticated','real 311/330/318/221 dispatch completes authentication and cloak');
is($bot->{joined},1,'normal channels released once by executable handlers');
is_deeply($bot->{console},['#console'],'console released after confirmed cloak');
my $sent=scalar @{$irc->{sent}};
feed(':X!cservice@undernet.org NOTICE Bot :AUTHENTICATION SUCCESSFUL as TestAccount');
is(scalar @{$irc->{sent}},$sent,'late X notice does not reset nick or duplicate joins');
like(extract('on_timer_tick'),qr/xauth->tick/,'existing five-second heartbeat drives the bounded controller');
for my $hook (qw(on_message_ERROR on_message_KILL reconnect)) {like(extract($hook),qr/xauth->reset/,'transport lifecycle invalidates pending authentication')}

# Preserve the existing Libera path; Undernet credentials are not sent there.
$conf->{'connection.CONN_NETWORK_TYPE'}=2;$conf->{'libera.LIBERA_NICKSERV_PASSWORD'}='YOUR_LIBERA_TEST_PASSWORD';
$irc->{sent}=[];delete $bot->{joined};$bot->{console}=[];
XH838Hooks::on_login($irc,undef,{});
is(scalar(grep{$_->[0] eq 'PRIVMSG'}@{$irc->{sent}}),0,'Libera startup does not send X credentials');
is_deeply($bot->{console},['#console'],'Libera keeps its existing console join');
feed(':NickServ!service@services.libera.chat NOTICE Bot :This nickname is registered');
is_deeply($bot->{legacy}[-1],['NickServ','identify YOUR_LIBERA_TEST_PASSWORD'],'existing Libera NickServ handler remains intact');
is($bot->{joined},1,'Libera joins still follow its own service flow');
done_testing;
