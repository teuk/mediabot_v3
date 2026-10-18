use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Mediabot::User;
use Mediabot::ChannelCommands;
use Mediabot::AI::MetaRuntime;
use Mediabot::AI::MetaActivation qw(channel_policy);
use Mediabot::AI::MetaPolicy qw(settings);
{
 package MB842Conf;sub get {$_[0]{$_[1]}}
 package MB842Logger;sub log {push @{$_[0]{lines}},$_[2]}
 package MB842Channel;sub get_id {$_[0]{id}}
 package MB842Ctx;sub bot {$_[0]{bot}}sub user {$_[0]{user}}sub nick {'Alice'}sub channel {$_[0]{channel}}sub message {undef}sub args {$_[0]{args}}
 package MB842Gen;sub capture_generation {1}
 package MB842Bot;sub getMessageNickIdentHost {('Alice','ident','example.org')}
 package MB842Client;sub submit {my ($s,$req,%o)=@_;push @{$s->{calls}},[$req,$o{on_done}];1}
}
my (@notices,@sent,@timers,@logs);
no warnings 'redefine';
local *Mediabot::ChannelCommands::botNotice=sub {push @notices,$_[2]};
local *Mediabot::ChannelCommands::logBot=sub {push @logs,[@_]};
local *Mediabot::Helpers::channel_lang=sub {'fr'};
local *Mediabot::Helpers::botNotice=sub {push @notices,$_[2]};
local *Mediabot::Helpers::botPrivmsg=sub {push @sent,$_[2];1};
sub fixture842 {
 @notices=();@sent=();@timers=();@logs=();
 my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
 $dbh->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT COLLATE NOCASE)');
 $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE)');
 $dbh->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY AUTOINCREMENT,id_channel INTEGER,id_chanset_list INTEGER)');
 $dbh->do('CREATE TABLE USER_CHANNEL(id_user INTEGER,id_channel INTEGER,level INTEGER)');
 $dbh->do("INSERT INTO CHANNEL VALUES(1,'#pilot'),(2,'#other')");
 $dbh->do("INSERT INTO CHANSET_LIST VALUES(1,'MetaAI'),(2,'chatGPT')");
 my $dir=tempdir(CLEANUP=>1);
 my $conf=bless {'meta_ai.PROVIDERS'=>'openai anthropic','openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY',
  'anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY','meta_ai.STATE_FILE'=>"$dir/memory.json"},'MB842Conf';
 my $bot=bless {dbh=>$dbh,conf=>$conf,config_file=>"$dir/mediabot.conf",
  channels=>{'#pilot'=>bless({id=>1},'MB842Channel'),'#other'=>bless({id=>2},'MB842Channel')},
  logger=>bless({lines=>[]},'MB842Logger'),wit_runtime_state=>bless({},'MB842Gen')},'MB842Bot';
 my $client=bless {calls=>[]},'MB842Client';
 my $runtime=Mediabot::AI::MetaRuntime->new(bot=>$bot,client_factory=>sub {$client},
  schedule_cb=>sub {push @timers,$_[1]},web_start=>sub {die 'no web for local fixtures'});
 $bot->{_meta_ai_runtime}=$runtime;
 return ($dbh,$conf,$bot,$client,$dir);
}
sub user842 {my ($role,$auth)=@_;my $u=Mediabot::User->new({id_user=>7,auth=>$auth});$u->{level_desc}=$role;return $u}
sub change842 {
 my ($bot,$u,$channel,$flag)=@_;
 my $ctx=bless {bot=>$bot,user=>$u,channel=>$channel,args=>[$flag]},'MB842Ctx';
 Mediabot::ChannelCommands::channelSet_ctx($ctx);
}
sub ask842 {Mediabot::AI::MetaRuntime::handle($_[0],undef,'Alice','#pilot','calcule 2+2')}
sub finish842 {
 my ($client,$answer)=@_;
 $_->[1]->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>0})}) for @{$client->{calls}}[0,1];
 $client->{calls}[2][1]->({ok=>1,answer=>encode_json({answer=>$answer,source_ids=>[]})});
}
for my $role ('Owner','Master','Administrator') {
 my ($db,$c,$b)=fixture842();change842($b,user842($role,1),'#pilot','+MetaAI');
 ok(channel_policy($b,settings($c),'#pilot')->{enabled},"authenticated $role can enable MetaAI");
 like($notices[-1],qr/applied/,'successful write is acknowledged');
 change842($b,user842($role,1),'#pilot','-MetaAI');
 ok(!channel_policy($b,settings($c),'#pilot')->{enabled},"authenticated $role can disable MetaAI");
}
for my $case (['Owner',0,500],['User',1,449],['unknown',1,0]) {
 my ($role,$auth,$level)=@$case;my ($db,$c,$b)=fixture842();
 $db->do('INSERT INTO USER_CHANNEL VALUES(7,1,?)',undef,$level);
 change842($b,user842($role,$auth),'#pilot','+MetaAI');
 ok(!channel_policy($b,settings($c),'#pilot')->{enabled},"$role auth=$auth channel=$level cannot enable MetaAI");
 unlike(join(' ',@notices),qr/applied/,'denied change has no success acknowledgement');
 is(scalar @logs,0,'denied change has no successful command log');
}
my ($db,$c,$b,$client,$dir)=fixture842();
$db->do('INSERT INTO USER_CHANNEL VALUES(7,1,450),(7,2,10)');
change842($b,user842('User',1),'#pilot','+MetaAI');
ok(channel_policy($b,settings($c),'#pilot')->{enabled},'channel level 450 can enable own channel');
change842($b,user842('User',1),'#other','+MetaAI');
ok(!channel_policy($b,settings($c),'#other')->{enabled},'channel rights do not transfer to another channel');
ok(ask842($b),'addressed question is handled by native MetaAI');
is(scalar @{$client->{calls}},2,'+MetaAI alone starts the configured contributors without old config gates');
finish842($client,'Une réponse utile. 'x35);
is(scalar @sent,1,'first answer chunk is delivered');
is(scalar @timers,1,'second answer chunk is paced');
change842($b,user842('User',1),'#pilot','-MetaAI');
change842($b,user842('User',1),'#pilot','+MetaAI');
$timers[0]->();
is(scalar @sent,1,'disable/re-enable cannot revive an already pending answer');
open my $fh,'<:raw',"$dir/memory.json" or die $!;local $/;my $state=decode_json(<$fh>);close $fh;
is(scalar(map {@{$_->{turns}}} values %{$state->{rooms}}),0,'revoked partial answer does not enter shared history');

($db,$c,$b,$client,$dir)=fixture842();
ok(ask842($b),'native disabled channel consumes addressed route instead of silently invoking legacy GPT');
is(scalar @{$client->{calls}},0,'disabled channel makes no provider call');
$db->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) VALUES(1,2)');
ok(ask842($b),'legacy +chatGPT cannot bypass native MetaAI opt-in');
is(scalar @{$client->{calls}},0,'legacy flag alone starts no collective call');
$db->do('DROP TABLE CHANNEL_SET');
ok(ask842($b),'failed policy lookup is consumed safely');
is(scalar @{$client->{calls}},0,'failed lookup cannot start a paid request');

for my $op ('+','-') {
 ($db,$c,$b)=fixture842();
 $db->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) VALUES(1,1)') if $op eq '-';
 $db->do($op eq '+' ? q{CREATE TRIGGER reject_write BEFORE INSERT ON CHANNEL_SET BEGIN SELECT RAISE(ABORT,'PRIVATE_SQL_FAILURE');END}
 : q{CREATE TRIGGER reject_write BEFORE DELETE ON CHANNEL_SET BEGIN SELECT RAISE(ABORT,'PRIVATE_SQL_FAILURE');END});
 change842($b,user842('Owner',1),'#pilot',"${op}MetaAI");
 like($notices[-1],qr/Could not/,'write failure is explicitly reported');
 unlike(join(' ',@notices),qr/PRIVATE_SQL_FAILURE|applied|removed from/,'write failure exposes neither SQL detail nor false success');
 is(scalar @logs,0,'write failure has no successful action log');
 is($b->{_meta_ai_policy_epoch}{'#pilot'}//0,0,'failed write does not invalidate an unchanged policy');
 is(channel_policy($b,settings($c),'#pilot')->{enabled},$op eq '-'?1:0,'failed write leaves actual activation unchanged');
}
done_testing;
