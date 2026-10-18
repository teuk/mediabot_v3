use strict;
use warnings;
use Test::More;
use Mediabot::XAuth;
{package X838Conf;sub get{$_[0]{$_[1]}}}
{package X838IRC;sub nick_folded{$_[0]{nick}}sub is_connected{$_[0]{connected}}sub send_message{my $s=shift;die 'transport failed' if $s->{fail};push @{$s->{sent}},[@_];return 1}}
{package X838Log;sub log{push @{$_[0]{lines}},$_[2]}}
{package X838Bot;sub joinChannels{$_[0]{joins}++}sub joinChannel{$_[0]{console}++}sub getLoop{return undef}}
{package X838Timer;sub stop{$_[0]{stopped}++}}
{package X838Chan;sub get_description{'console'}sub get_name{'#console'}sub get_key{''}}
sub fixture {
    my (%overrides)=@_;my $now=100;
    my $conf=bless {'connection.CONN_NETWORK_TYPE'=>1,'connection.CONN_USERMODE'=>'+iwx',
        'undernet.UNET_CSERVICE_LOGIN'=>'x@channels.undernet.org',
        'undernet.UNET_CSERVICE_USERNAME'=>'TestAccount',
        'undernet.UNET_CSERVICE_PASSWORD'=>'YOUR_X_TEST_PASSWORD',%overrides},'X838Conf';
    my $irc=bless {nick=>'Bot',connected=>1,sent=>[]},'X838IRC';
    my $b=bless {conf=>$conf,irc=>$irc,logger=>bless({lines=>[]},'X838Log'),channels=>{console=>bless({},'X838Chan')}},'X838Bot';
    my $x=Mediabot::XAuth->new(bot=>$b,now=>sub{$now});
    return ($x,$b,$irc,\$now);
}
sub numeric {my ($x,$irc,$n,@args)=@_;return $x->numeric($irc,$n,'server.undernet.org',\@args)}
sub whois {
    my ($x,$irc,$account)=@_;my $n=$irc->{nick};
    numeric($x,$irc,'311',$n,$n,'ident','real.example','*','bot');
    numeric($x,$irc,'330',$n,$n,$account,'is logged in as') if defined $account;
    numeric($x,$irc,'318',$n,$n,'End of WHOIS');
}
sub count {my ($irc,$verb)=@_;return scalar grep{$_->[0] eq $verb}@{$irc->{sent}}}
my ($x,$b,$irc,$clock)=fixture();
ok($x->defer_joins,'configured +x defers channel joins');
is($x->connect_modes,'+iw','initial modes exclude x until authentication');
ok($x->on_login($irc),'login callback starts account verification');
is_deeply($irc->{sent}[0],['WHOIS',undef,'Bot'],'query uses the actual connected nickname');
is(count($irc,'PRIVMSG'),0,'no password sent before complete negative account proof');
is($b->{joins}//0,0,'no channel joins before account/mode confirmation');
whois($x,$irc,undef);
is_deeply($irc->{sent}[-1],['PRIVMSG',undef,'x@channels.undernet.org','LOGIN TestAccount YOUR_X_TEST_PASSWORD'],'complete unauthenticated WHOIS sends configured credentials to the server-qualified service');
is($x->status->{state},'login_pending','queuing LOGIN does not claim successful authentication');
is(count($irc,'MODE'),0,'LOGIN does not optimistically request +x');
$x->request;$x->tick;is(count($irc,'PRIVMSG'),1,'manual and periodic requests share the in-flight login');
$$clock+=5;$x->tick;is(count($irc,'WHOIS'),2,'login is followed by a fresh WHOIS');
whois($x,$irc,'testaccount');
is_deeply($irc->{sent}[-1],['MODE',undef,'Bot'],'matching server account triggers a mode query');
is($b->{joins}//0,0,'matching account alone cannot release cloaked joins');
numeric($x,$irc,'221','Bot','+iw');
is_deeply([@{$irc->{sent}}[-2,-1]],[['MODE',undef,'Bot','+x'],['MODE',undef,'Bot']],'missing cloak requests +x and then confirmation');
is($b->{joins}//0,0,'sending +x is not mode confirmation');
numeric($x,$irc,'221','Bot','+iwx');
is($x->status->{state},'authenticated','account and cloak confirmed');
is($x->status->{cloak},1,'status reports confirmed cloak');
is($b->{joins},1,'normal channels released once');is($b->{console},1,'console also waits for confirmed cloak');
my $sent=@{$irc->{sent}};$$clock+=299;$x->tick;is(scalar @{$irc->{sent}},$sent,'no request before five-minute interval');
$$clock++;$x->tick;is(count($irc,'WHOIS'),3,'five-minute heartbeat verifies the current account');
whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+x');
is(count($irc,'PRIVMSG'),1,'healthy verification never resends credentials');is($b->{joins},1,'healthy periodic check does not repeat joins');
$$clock+=300;$x->tick;whois($x,$irc,undef);
is(count($irc,'PRIVMSG'),2,'lost account automatically starts a new login');
$$clock+=5;$x->tick;whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+x');
is($x->status->{state},'authenticated','periodic recovery is verified normally');is($b->{joins},1,'recovery does not duplicate initial joins');
like(join(' ',@{$b->{logger}{lines}}),qr/XAUTH state=authenticated reason=verified/,'bounded verification event is logged');
unlike(join(' ',@{$b->{logger}{lines}}),qr/YOUR_X_TEST_PASSWORD|TestAccount|LOGIN /,'controller logs never contain account/password payloads');

# A complete negative reply is required. Notices, a cloak hostname, another
# nickname, a user prefix, another transport or a missing 311 cannot prove it.
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);
ok(!$x->numeric($irc,'330','X!cservice@undernet.org',['Bot','Bot','TestAccount']),'user-prefixed proof rejected');
ok(!numeric($x,$irc,'330','Bot','Bot','TestAccount'),'account line before WHOIS user rejected');
ok(!numeric($x,$irc,'318','Bot','Bot','end'),'end without user proof rejected');
whois($x,$irc,'SomeOtherAccount');
is($x->status->{state},'account_mismatch','wrong account reported explicitly');
is(count($irc,'PRIVMSG'),0,'wrong account never causes repeated login attempts');is($b->{joins}//0,0,'wrong account cannot release joins');
$x->request;numeric($x,$irc,'311','Bot','Other','i','x','*','other');numeric($x,$irc,'318','Bot','Other','end');
is(count($irc,'PRIVMSG'),0,'unrelated WHOIS cannot cause a login');
$$clock+=20;$x->tick;is($x->status->{state},'unverified','timeout remains unverified');
is(count($irc,'PRIVMSG'),0,'timeout does not infer logout or send credentials');

($x,$b,$irc,$clock)=fixture();$x->on_login($irc);whois($x,$irc,undef);$$clock+=5;$x->tick;whois($x,$irc,undef);
for(1..10){$x->request;whois($x,$irc,undef)}
is(count($irc,'PRIVMSG'),1,'failed credentials have a five-minute resend floor even for manual requests');
$$clock+=300;$x->tick;whois($x,$irc,undef);is(count($irc,'PRIVMSG'),2,'later retry is bounded and recoverable');

($x,$b,$irc,$clock)=fixture();$x->on_login($irc);whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+i');numeric($x,$irc,'221','Bot','+i');
is($x->status->{state},'cloak_unconfirmed','failed +x is visible');is($b->{joins}//0,0,'failed +x cannot leak protected autojoins');
is(scalar(grep{$_->[0] eq 'MODE' && ($_->[3]//'') eq '+x'}@{$irc->{sent}}),1,'one mode attempt per verification');

($x,$b,$irc,$clock)=fixture('connection.CONN_USERMODE'=>'+iw');
ok($x->defer_joins,'configured Undernet authentication gates joins even when +x is not requested');$x->on_login($irc);whois($x,$irc,'TestAccount');
is(count($irc,'MODE'),0,'+x is never requested unless configured');is(count($irc,'PRIVMSG'),0,'already authenticated startup is reused');
is($b->{joins}//0,1,'verified account releases auth-only joins without requesting a cloak');
is($x->status->{state},'authenticated','account still verified without a cloak request');
for my $m ('+i-x','+x-x') {($x,$b,$irc,$clock)=fixture('connection.CONN_USERMODE'=>$m);ok(!$x->status->{want_x},"negative x respected in $m")}

($x,$b,$irc,$clock)=fixture('undernet.UNET_CSERVICE_CHECK_INTERVAL'=>0);
$x->on_login($irc);whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+x');$sent=@{$irc->{sent}};$$clock+=3600;$x->tick;
is(scalar @{$irc->{sent}},$sent,'zero disables periodic verification, retaining connect/manual paths');
ok($x->request,'manual check works when periodic checks disabled');
for my $row ([1,60],[99999,3600],['bad',300]) {
 ($x,$b,$irc,$clock)=fixture('undernet.UNET_CSERVICE_CHECK_INTERVAL'=>$row->[0]);is($x->status->{interval},$row->[1],'interval is validated and bounded');
}
for my $row (['connection.CONN_NETWORK_TYPE',2],['undernet.UNET_CSERVICE_LOGIN','X'],['undernet.UNET_CSERVICE_USERNAME',"bad\r\nJOIN #bad"],['undernet.UNET_CSERVICE_PASSWORD',"bad\nQUIT"],['undernet.UNET_CSERVICE_PASSWORD','']) {
 ($x,$b,$irc,$clock)=fixture($row->[0]=>$row->[1]);ok(!$x->on_login($irc),'wrong network or invalid/missing credentials disable login');$x->tick;$x->request;
 is(scalar @{$irc->{sent}},0,'invalid configuration sends no IRC command');
}
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);my $old=$irc;
$irc=bless {nick=>'NewBot',connected=>1,sent=>[]},'X838IRC';$b->{irc}=$irc;
whois($x,$old,'TestAccount');is($b->{joins}//0,0,'stale transport cannot release joins');
$x->tick;is(scalar @{$irc->{sent}},0,'replacement transport waits for its real login callback');
$x->on_login($irc);whois($x,$irc,undef);like($irc->{sent}[-1][3],qr/^LOGIN /,'reconnected session authenticates afresh');
$irc->{connected}=0;$$clock+=5;$x->tick;is($x->status->{state},'disconnected','disconnect clears connection-bound status');
$sent=@{$irc->{sent}};$$clock+=1000;$x->tick;is(scalar @{$irc->{sent}},$sent,'no offline retries');
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);$irc->{nick}='Changed';$x->tick;
is_deeply($irc->{sent}[-1],['WHOIS',undef,'Changed'],'nick change probes the actual new nick');
whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Changed','+x');is($x->status->{state},'authenticated','renamed bot recovers verification');
($x,$b,$irc,$clock)=fixture();$irc->{fail}=1;ok(!$x->on_login($irc),'transport exception is contained');is($x->status->{state},'send_failed','transport failure remains visible');
# Reject inconsistent account evidence rather than inferring a logout.
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);
numeric($x,$irc,'311','Bot','Bot','ident','host','*','Bot');
numeric($x,$irc,'330','Bot','Bot','TestAccount');
numeric($x,$irc,'330','Bot','Bot','OtherAccount');
numeric($x,$irc,'318','Bot','Bot','end');
is($x->status->{state},'unverified','contradictory account replies remain unknown');
is(count($irc,'PRIVMSG'),0,'contradictory replies cannot trigger credential transmission');
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);
numeric($x,$irc,'311','Bot','Bot','ident','TestAccount.users.undernet.org','*','Bot');
numeric($x,$irc,'318','Bot','Bot','end');
is(count($irc,'PRIVMSG'),1,'a cloak hostname alone does not prove account authentication');
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+x');
my $join_timer=bless {},'X838Timer';$b->{_join_timers}=[$join_timer];
$b->{conf}{'undernet.UNET_CSERVICE_CHECK_INTERVAL'}=600;$x->tick;
is($join_timer->{stopped}//0,0,'same-transport configuration refresh preserves released paced JOIN timers');
is(scalar @{$b->{_join_timers}},1,'refresh retains the pending join schedule');
whois($x,$irc,'TestAccount');numeric($x,$irc,'221','Bot','+x');
is($b->{joins},1,'refreshing configuration does not repeat completed initial joins');
($x,$b,$irc,$clock)=fixture();$x->on_login($irc);whois($x,$irc,'TestAccount');
my $sent_before=scalar @{$irc->{sent}};
numeric($x,$irc,'221','Other','+x');
is(scalar @{$irc->{sent}},$sent_before,'mode replies for another recipient are ignored');
is($b->{joins}//0,0,'unrelated mode reply cannot release joins');
for my $bad_mode ('+iwx bad', ['+iw','+x']) {
 ($x,$b,$irc,$clock)=fixture('connection.CONN_USERMODE'=>$bad_mode);
 ok($x->defer_joins,'malformed mode settings cannot silently bypass the requested cloak gate');
 ok(!$x->on_login($irc),'malformed user mode configuration is rejected');
 is(scalar @{$irc->{sent}},0,'invalid modes send neither credentials nor commands');
}
done_testing;
