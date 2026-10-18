use strict;
use warnings;
use Test::More;
use lib '.', 't/lib';
use MockUser;
use MockMessage;
use Mediabot::Context;
use Mediabot::Mediabot;
use Mediabot::XAuth;
{package XC838Conf;sub get{$_[0]{$_[1]}}}
{package XC838IRC;sub nick_folded{'mediabot'}sub is_connected{1}sub send_message{push @{$_[0]{sent}},[@_[1..$#_]];1}}
{package XC838Bot;our @ISA=('Mediabot');sub get_user_from_message{$_[0]{user}}}
my $conf=bless {'connection.CONN_NETWORK_TYPE'=>1,'connection.CONN_USERMODE'=>'+ix',
    'undernet.UNET_CSERVICE_LOGIN'=>'x@channels.undernet.org','undernet.UNET_CSERVICE_USERNAME'=>'TestAccount',
    'undernet.UNET_CSERVICE_PASSWORD'=>'YOUR_X_TEST_PASSWORD'},'XC838Conf';
my (%public,%private);
%public=Mediabot::_builtin_public_command_handlers();%private=Mediabot::_builtin_private_command_handlers();
my %help=Mediabot::_mbHelpInternalCommands;
my (@notices,@console,@logs);
no warnings qw(redefine once);
local *Mediabot::LoginCommands::botNotice=sub{push @notices,[$_[1],$_[2]];1};
local *Mediabot::LoginCommands::noticeConsoleChan=sub{push @console,$_[1];1};
local *Mediabot::LoginCommands::logBot=sub{push @logs,[@_[3..$#_]];1};
for my $surface ('public','private') {
 for my $name ('xauth','xlogin') {
  my $handler=$surface eq 'public'?$public{$name}:$private{$name};
  ok(ref($handler) eq 'CODE',"$surface/$name has a real handler");
  like($help{$name}{syntax},qr/\[status\]/,"$name help matches the supported syntax");
  for my $case (['Owner',1,1],['Master',1,1],['Administrator',1,0],['User',1,0],['Owner',0,0],['invalid',1,0]) {
   @notices=();@console=();@logs=();
   my $irc=bless {sent=>[]},'XC838IRC';
   my $b=bless {conf=>$conf,irc=>$irc,user=>MockUser->new(level=>$case->[0],auth=>$case->[1])},'XC838Bot';
   my $x=Mediabot::XAuth->new(bot=>$b);$b->{xauth_controller}=$x;
   $x->on_login($irc);$irc->{sent}=[];
   my $ctx=Mediabot::Context->new(bot=>$b,nick=>'operator',channel=>$surface eq 'public'?'#test':undef,
       command=>$name,args=>[],message=>MockMessage->new);
   my $ok=eval{$handler->($ctx);1};
   ok($ok,"$surface/$name/$case->[0]/$case->[1] does not throw");
   my $text=join(' ',map{$_->[1]}@notices);
   if($case->[2]) {like($text,qr/check requested/,"$surface/$name authorized request is honest about pending verification")}
   else {unlike($text,qr/check requested/,"$surface/$name denied identity cannot start authentication")}
   is(scalar @{$irc->{sent}},0,'pending check is not duplicated, including denied requests');
   unlike(join(' ',@console,map{join(' ',@$_)}@logs).$text,qr/YOUR_X_TEST_PASSWORD|TestAccount/,'credential material is absent from notices/command logs');
  }
 }
}
my $irc=bless {sent=>[]},'XC838IRC';my $b=bless {conf=>$conf,irc=>$irc,user=>MockUser->new(level=>'Master',auth=>1)},'XC838Bot';
$b->{xauth_controller}=Mediabot::XAuth->new(bot=>$b);$b->xauth->on_login($irc);$irc->{sent}=[];
my $ctx=Mediabot::Context->new(bot=>$b,nick=>'operator',command=>'xauth',args=>['status'],message=>MockMessage->new);
@notices=();$public{xauth}->($ctx);
like($notices[-1][1],qr/state=checking.*\+x=unconfirmed.*interval=300s.*verified=never/,'status distinguishes pending account and cloak confirmation');
is(scalar @{$irc->{sent}},0,'status is read-only and sends no network command');
$ctx->{args}=['OtherAccount','YOUR_OTHER_TEST_PASSWORD'];@notices=();$public{xauth}->($ctx);
like($notices[-1][1],qr/Syntax: xauth \[status\]/,'caller-supplied accounts/passwords are refused');
is(scalar @{$irc->{sent}},0,'invalid command arguments cannot send credentials');
$b->{command_registry}=Mediabot::CommandRegistry->new;
$b->_register_builtin_command_catalogue;
my $reg=$b->commands; # real catalogue installation/dispatch verifies ownership
for my $src ('public','private') {
 for my $name ('xauth','xlogin') {
  ok($reg->has_command($name,$src),"actual registry contains $src/$name");
  is($reg->command_for($name,$src)->{level},'master','catalogue exposes the actual privileged level');
 }
}
# The operator readiness tool reads a private fixture through the native parser.
use File::Temp qw(tempdir);
my $dir=tempdir(CLEANUP=>1);my $path="$dir/test.conf";
open my $cf,'>',$path or die $!;
print {$cf} "[connection]\nCONN_NETWORK_TYPE=1\nCONN_USERMODE=+iwx\n[undernet]\nUNET_CSERVICE_LOGIN=x\@channels.undernet.org\nUNET_CSERVICE_USERNAME=TestAccount\nUNET_CSERVICE_PASSWORD=YOUR_X_TEST_PASSWORD\n";
close $cf;chmod 0600,$path;
my $before=do{open my $r,'<',$path or die $!;local $/;<$r>};
open my $probe,'-|',$^X,'tools/xauth_check.pl','--conf',$path or die $!;
my $out=do{local $/;<$probe>};close $probe;
is($? >> 8,0,'offline readiness accepts valid native configuration');
like($out,qr/Periodic check: 300 seconds/,'offline readiness shows default five-minute cadence');
like($out,qr/live account and \+x are not verified/,'offline readiness never claims live success');
unlike($out,qr/YOUR_X_TEST_PASSWORD|TestAccount/,'readiness output contains no account/password values');
my $after=do{open my $r,'<',$path or die $!;local $/;<$r>};
is($after,$before,'offline readiness preserves exact private fixture bytes');
is((stat($path))[2]&0777,0600,'offline readiness retains private permissions');
done_testing;
