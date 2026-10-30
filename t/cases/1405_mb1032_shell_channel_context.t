use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Loop;
use DBI;
use Mediabot::Partyline;
use Mediabot::Channel;
use Mediabot::Scheduler;
use Mediabot::Log;
use Mediabot::Helpers ();
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1032::Out;
    sub write { $_[0]{text}.=$_[1]; 1 }
    package MB1032::IRC;
    sub is_connected { 1 }
    package MB1032::Runtime;
    sub snapshot { {channel_joined=>1,runtime_active=>1,irc_connected=>1} }
    package MB1032::Bot;
    sub gethChannelsNicksOnChan { Mediabot::Helpers::gethChannelsNicksOnChan(@_) }
    package MB1032::Plugins;
    sub channel_diagnostic_snapshot {
        my ($self,$channel)=@_;$self->{seen}=$channel;
        return {state=>'observed',loaded_v3=>1,legacy_loaded=>0,unavailable=>0,omitted=>0,packages=>[
            {name=>'game-v3',state=>'observed',lifecycle=>'enabled',policy=>'active',
             decision=>'allow',missing_capabilities=>0,quarantined_resources=>0,
             retained_failures=>0,password=>'PRIVATE_FIXTURE_DATA'}]};
    }
}
my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
my $loop=IO::Async::Loop->new;
my $scheduler=Mediabot::Scheduler->new(loop=>$loop);
$scheduler->add(name=>'radio.refresh',interval=>300,cb=>sub {});
my $logger=Mediabot::Log->new(debug_level=>5);
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE CHANNEL (id_channel INTEGER, name TEXT)');
$dbh->do('CREATE TABLE CHANSET_LIST (id_chanset_list INTEGER, chanset TEXT)');
$dbh->do('CREATE TABLE CHANNEL_SET (id_channel_set INTEGER, id_chanset_list INTEGER, id_channel INTEGER)');
$dbh->do('CREATE TABLE RSS_FEED (id_channel INTEGER, last_error_at TEXT)');
$dbh->do("INSERT INTO CHANNEL VALUES (1,'#Test'),(2,'#Other')");
$dbh->do("INSERT INTO CHANSET_LIST VALUES (1,'MixCloud')");
$dbh->do('INSERT INTO CHANNEL_SET VALUES (1,1,1)');
my @queries;$dbh->sqlite_trace(sub {push @queries,$_[0]});
my $bot=bless {loop=>$loop,logger=>$logger,scheduler=>$scheduler,dbh=>$dbh,
    irc=>bless({},'MB1032::IRC'),wit_runtime_state=>bless({},'MB1032::Runtime'),
    plugin_manager=>bless({},'MB1032::Plugins'),_start_time=>time()-60,
    channels=>{map {lc($_->[1])=>Mediabot::Channel->new({id=>$_->[0],name=>$_->[1],
        topic=>"Musique — été\e[31m",description=>'Local test',timezone=>'Europe/Paris',
        key=>'PRIVATE_FIXTURE_DATA'})} ([1,'#Test'],[2,'#Other'])},
    hChannelsNicks=>{'#Test'=>[map {sprintf('nick%02d',$_)} 1..25]}},'MB1032::Bot';
my $out=bless {text=>''},'MB1032::Out';my $chat=bless {text=>''},'MB1032::Out';
my $party=bless {bot=>$bot,loop=>$loop,users=>{
    10=>{authenticated=>1,level=>0,login=>'teuk'},
    11=>{authenticated=>1,level=>1,login=>'other'}},streams=>{10=>$out,11=>$chat}},'Mediabot::Partyline';
sub quiet_1405 (&) {my ($cb)=@_;open my $sink,'>',\my $captured or die $!;local *STDOUT=$sink;$cb->()}
sub line_1405 {
    my ($line)=@_;$out->{text}='';$party->{users}{10}{rate_window}=0;
    quiet_1405 {$party->_handle_line($out,10,$line)};
    return $out->{text};
}
line_1405('.console 3');
quiet_1405 {$party->_cmd_console($chat,11,'3')};
$chat->{text}='';line_1405('.command #test');
like($out->{text},qr/mediabot\[#Test\]:\/> /,'entry resolves canonical channel identity and puts it in the prompt');
is($chat->{text},'','context entry never becomes a generic dot-command broadcast');
quiet_1405 {$party->{users}{11}{rate_window}=0;$party->_handle_line($chat,11,'.command #Other')};
is_deeply([$party->{users}{10}{command_shell}{channel},$party->{users}{11}{command_shell}{channel}],
    ['#Test','#Other'],'each authenticated connection owns its channel context');
quiet_1405 {$party->{users}{11}{rate_window}=0;$party->_handle_line($chat,11,'exit')};
$out->{text}='';$chat->{text}='';
$party->_broadcast('background presence');
quiet_1405 {$party->_broadcast_chat(11,'background chat',11);$logger->log(1,'background console')};
is($out->{text},'','all native broadcasts, chat and existing console hook stay silent in shell mode');
like($chat->{text},qr/background presence.*background console/s,'ordinary chat session keeps receiving broadcasts and console-independent activity');
is($party->{users}{10}{console_level},3,'shell suppression preserves the requested console level');
like(line_1405('channel'),qr/#Test.*id 1.*Europe\/Paris.*Joined: yes/s,'channel inspection uses the selected cached identity');
unlike($out->{text},qr/PRIVATE_FIXTURE_DATA|\e/,'channel projection omits keys and removes untrusted terminal controls');
like(line_1405('topic'),qr/Cached topic: Musique/,'topic observation stays explicitly cached');
like(line_1405('who 2'),qr/nick21.*nick25.*25 entry\/entries, page 2\/2/s,'cached nick listing is paginated');
like(line_1405('who | sort -r | head 2'),qr/nick25.*nick24.*2 entry/s,'read pipelines sort and cap channel observations');
like(line_1405('who | tail 2'),qr/nick24.*nick25/s,'tail uses the same bounded read pipeline');
like(line_1405('channels | grep -i other'),qr/#Other.*1 entry/s,'channel discovery supports literal filters');
like(line_1405('status'),qr/GLOBAL.*Uptime: \d+s.*IRC connected: yes.*Schedulers: 1/s,'runtime status distinguishes global tasks from channel context');
is(scalar @queries,0,'context selection, cache inspections and status perform no SQL');
like(line_1405('plugins'),qr/game-v3:.*policy=active.*decision=allow/s,'plugin observations use the existing channel projection');
is($bot->{plugin_manager}{seen},'#Test','plugin projection receives the canonical selected channel');
unlike($out->{text},qr/PRIVATE_FIXTURE_DATA/,'extra provider fields never cross the shell projection');
like(line_1405('chansets | grep MixCloud'),qr/MixCloud=on/,'persisted flags use the existing parameterized diagnostic');
like(line_1405('diagnose | head 3'),qr/Database: fresh.*3 entry/s,'diagnose renders the existing bounded channel report');
ok(!(grep {!/\ASELECT\b/i} @queries),'diagnostic actions issue only SELECT statements');
$dbh->do('UPDATE CHANNEL SET id_channel=9 WHERE id_channel=1');
like(line_1405('diagnose'),qr/Database channel identity changed/,
    'fresh diagnostic identity cannot silently replace the selected cached identity');
$dbh->do('UPDATE CHANNEL SET id_channel=1 WHERE id_channel=9');
like(line_1405('use #missing'),qr/not in the registered cache/,'unknown channel selection fails explicitly');
is($party->{users}{10}{command_shell}{channel},'#Test','failed selection preserves the previous context');
line_1405('who');my $old=$party->{users}{10}{command_shell}{serial};line_1405('use #Other');
like(line_1405("!$old"),qr/History context changed/,'history cannot silently replay into another channel');
line_1405('use #Test');$bot->{channels}{'#test'}=Mediabot::Channel->new({id=>3,name=>'#Test'});
like(line_1405('who'),qr/identity changed/,'removed/recreated channel identity requires explicit reselection');
line_1405('use -');like(line_1405('who'),qr/Select a channel first/,'global context cannot invent a target channel');
like(line_1405('ps stopped'),qr/s1.*radio.refresh/s,'stopped schedule filter remains global');
line_1405('cd workers');line_1405('cd schedulers');line_1405('cd /schedulers');
like(line_1405('cd -'),qr{/workers>},'cd - returns to the previous successful directory');
like(line_1405('help use'),qr/use #channel/,'targeted help explains context selection');
line_1405('history clear');like(line_1405("!$old"),qr/not available/,'history clear invalidates old replay numbers');
line_1405('pwd');ok($party->{users}{10}{command_shell}{serial}>$old,'history clear never reuses sequence numbers');
is(line_1405('clear'),"\e[2J\e[Hmediabot:/workers> ",'clear resets the terminal and restores its prompt');
line_1405('exit');$out->{text}='';
$party->_broadcast('after exit');quiet_1405 {$logger->log(1,'console resumed')};
like($out->{text},qr/after exit.*console resumed/s,'exit restores broadcast and console delivery without replaying muted output');
unlike($out->{text},qr/background/,'suppressed background events are discarded, never replayed');
line_1405('.command #Other');line_1405('.console off');line_1405('exit');
is($party->{users}{10}{console_level},undef,'an explicit console change inside shell survives exit');
unlike($chat->{text},qr/\.console off/,'dot-command announcements from a shell remain private');
line_1405('.command #missing');ok(!$party->{users}{10}{command_mode},'failed entry does not activate command mode');
$chat->{text}='';line_1405('.command #Other trailing');
is_deeply([$party->{users}{10}{command_mode}//0,$chat->{text}],
    [0,''],'malformed entry stays private and does not activate command mode');
is_deeply(\@warnings,[],'quiet shell, native broadcasts and context observations are warning-free');
$dbh->disconnect;
done_testing;
