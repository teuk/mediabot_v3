use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use IO::Async::Loop;
use DateTime;
use Mediabot::Mediabot;
use Mediabot::EventBus;
use Mediabot::Scheduler;
use Mediabot::CommandRegistry;
use Mediabot::PluginManager;
use Mediabot::Plugin::WordSolverV3;
{
    package MB959::WordsConf;
    sub get { $_[0]{$_[1]} }
    package MB959::WordsLog;
    sub log { push @{$_[0]{lines}}, $_[2]; 1 }
    package MB959::WordsUser;
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'AliceAccount' }
    sub has_level { $_[1] eq 'User' }
    package MB959::WordsBot;
    our @ISA = ('Mediabot');
    sub command_registry { $_[0]{registry} }
    sub getLoop { $_[0]{loop} }
    sub get_user_from_message { $_[1]{authenticated} ? bless({},'MB959::WordsUser') : undef }
    sub getUserChannelLevel { 0 }
    sub botNotice { push @{$_[0]{wire}}, ['notice', $_[1], $_[2]]; 1 }
    sub botPrivmsg { push @{$_[0]{wire}}, ['channel', $_[1], $_[2]]; 1 }
    sub plugin_channel_message { push @{$_[0]{wire}}, ['channel', $_[1], $_[2]]; 1 }
    package MB959::WordsService;
    sub solve {
        my ($self,$plugin,$channel,$rack,$cb) = @_;
        $cb->(Mediabot::Plugin::WordSolverV3->result($rack,[qw(ORIENTATES NOTAIRES NOTAIRE RAISON SERA ETE)]));
        return {accepted=>1};
    }
    sub cancel_scope {1}
    sub cancel_plugin {1}
}
my $tmp=tempdir(CLEANUP=>1);
my $loop=IO::Async::Loop->new;
my $bot=bless {registry=>Mediabot::CommandRegistry->new,loop=>$loop,event_bus=>Mediabot::EventBus->new,
    conf=>bless({'plugins.DATA_DIR'=>"$tmp/data"},'MB959::WordsConf'),wire=>[],
    logger=>bless({lines=>[]},'MB959::WordsLog')},'MB959::WordsBot';
$bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop,logger=>$bot->{logger});
my $manager=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins',v3_dictionary_service=>bless({},'MB959::WordsService'));
my @caps=qw(events.subscribe data.dictionary.read irc.reply irc.notice irc.channel_message scheduler.jobs storage.kv);
my $entry=$manager->load_package_v3('longest-word-v3',grants=>\@caps);
my $clock=100;
my $wall=DateTime->new(year=>2026,month=>10,day=>25,hour=>23,minute=>59,second=>0,time_zone=>'Europe/Paris')->epoch;
$entry->{object}{clock}=sub{$clock};$entry->{object}{wall_clock}=sub{$wall};
no warnings 'redefine';
local *Mediabot::Plugin::LongestWord::_rack=sub{'AEEINORSTT'};
local *Mediabot::PluginManager::_v3_monotonic_now=sub{$clock};
my $ctx=sub {
    my ($nick,$channel,$auth,@args)=@_;
    return Mediabot::Context->new(bot=>$bot,message=>{authenticated=>$auth},nick=>$nick,
        channel=>$channel,command=>'motlong',args=>\@args);
};
my $call=sub {
    my ($nick,$auth,@args)=@_;
    $bot->{registry}->handler_for('motlong','public')->($ctx->($nick,'#test',$auth,@args));
};
my $drain=sub { for(1..10){last unless $entry->{event_queue}->pending_count;$loop->loop_once(0)} };
my $word=sub {
    my ($nick,$text,$auth,$channel,$self)=@_;
    $bot->observe_public_word({authenticated=>$auth},$channel//'#test',$nick,$text,$self//0);
    $drain->();
};
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$word->('Alice','ORIENTATES',1);
ok(!keys %{$entry->{object}{games}},'bare word cannot start a disabled plugin');
$manager->enable('longest-word-v3');
$word->('Alice','ORIENTATES',1);
ok(!keys %{$entry->{object}{games}},'bare word cannot start an idle game');
$call->('Alice',1,'start');
is($entry->{object}{games}{'#test'}{engine}{phase},'playing','native command starts the game');
my $before_accept=@{$bot->{wire}};
$clock=100.5;$word->('Bob','RAISON',0);
is(scalar @{$bot->{wire}},$before_accept+1,'accepted bare word emits exactly one acknowledgement');
is_deeply([@{$bot->{wire}[-1]}[0,1]],['channel','#test'],'accepted bare word is announced in its own public channel');
like($bot->{wire}[-1][2],qr/^\[Mot le plus long\] Bob : RAISON retenu \(6 lettres\).*au moins 7 lettres/,'public acknowledgement identifies the player, accepted word and next minimum');
$clock=101;$word->('Alice','notaire',1);
is($entry->{object}{games}{'#test'}{engine}{players}{'u.7'}{word},'NOTAIRE','bare lowercase word goes through real core event and authenticated principal');
$clock=102;$word->('AliceNew','NOTAIRES',1);
is(scalar keys %{$entry->{object}{games}{'#test'}{engine}{players}},2,'a new authenticated nick does not add a third player');
is($entry->{object}{games}{'#test'}{engine}{players}{'u.7'}{word},'NOTAIRES','longer direct word replaces personal best');
is($entry->{object}{games}{'#test'}{engine}{players}{'n.bob'}{word},'RAISON','guest can also submit a bare word');
$clock=103;$word->('Charlie','NOTAIRE',0);
like($bot->{wire}[-1][2],qr/Non retenu.*au moins 9 lettres/,'bare shorter word receives the current strict minimum privately');
is_deeply([@{$bot->{wire}[-1]}[0,1]],['notice','Charlie'],'a rejected proposal remains private to its player');
ok(!exists($entry->{object}{games}{'#test'}{engine}{players}{'n.charlie'}),'bare rejected word cannot create a scoring player');
$clock=104;$word->('Charlie','NOTAIRES',0);
like($bot->{wire}[-1][2],qr/Non retenu.*au moins 9 lettres/,'bare equal word is rejected by the same global rule');
$clock=105;$call->('Charlie',0,'NOTAIRES');
like($bot->{wire}[-1][2],qr/Non retenu.*au moins 9 lettres/,'command proposal shares the strict round gate');
ok(!exists($entry->{object}{games}{'#test'}{engine}{players}{'n.charlie'}),'command rejection cannot create a scoring player');
$call->('Alice',1,'tirage');
like($bot->{wire}[-1][2],qr/Meilleur accepté : 8 lettres ; minimum suivant : 9/,'rack status exposes the common record and next required length');

my $before=@{$bot->{wire}};
for my $text ('hello everyone','!motlong ORIENTATES','ORIENTATES!','\x01ACTION ORIENTATES\x01','incompatible') {
    $clock++; $word->('Charlie',$text,0);
}
$word->('Charlie','ORIENTATES',0,'Someone');
$word->('Charlie','ORIENTATES',0,'#other');
$word->('Bot','ORIENTATES',0,'#test',1);
is(scalar @{$bot->{wire}},$before,'sentences, commands, incompatible words, private/other channels and self messages remain silent');
$clock=149;$word->('Max','NOTAIRES',0);
ok(!exists($entry->{object}{games}{'#test'}{engine}{players}{'n.max'}),'equal record does not create a scoring player');
$clock=150;$word->('Late','ORIENTATES',0);
ok(!exists $entry->{object}{games}{'#test'}{engine}{players}{'n.late'},'bare word at exact deadline is refused before timer tick');
my $tick=$bot->{scheduler}{_tasks}{'plugin.v3.longest-word-v3.clock'}{cb};
$wall+=65; # Tick occurs on Monday, but the round expired on Sunday.
$tick->();
ok(!exists $entry->{object}{games}{'#test'},'finished round saves cumulative and weekly scores and releases game');
$call->('AliceNew',1,'score');
like($bot->{wire}[-1][2],qr/Total : 8 pts.*2026-W44.*: 0 pts/,'personal total includes the round while new current week starts at zero');
$call->('Alice',1,'top','semaine','2026-W43');
like($bot->{wire}[-1][2],qr/2026-W43(?=.*AliceNew 8 pts)(?=.*Bob 6 pts)/,'delayed closing tick attributes points to actual round deadline week');
$call->('Alice',1,'top','total');
like($bot->{wire}[-1][2],qr/Total(?=.*1\. AliceNew 8 pts)(?=.*2\. Bob 6 pts)/,'cumulative display ranks accepted record holders');
my $wire=@{$bot->{wire}};$tick->();$tick->();
is(scalar @{$bot->{wire}},$wire,'repeated tick neither repeats result nor scores');
$clock=180;$call->('Alice',1,'start');
$clock=181;$before_accept=@{$bot->{wire}};$call->('Alice',1,'NOTAIRES');
is(scalar @{$bot->{wire}},$before_accept+1,'accepted command proposal has one acknowledgement without duplicate notice');
is_deeply([@{$bot->{wire}[-1]}[0,1]],['channel','#test'],'accepted command proposal uses the same public channel route');
like($bot->{wire}[-1][2],qr/^\[Mot le plus long\] Alice : NOTAIRES retenu \(8 lettres\).*au moins 9 lettres/,'command acknowledgement exposes the accepted improvement to everyone');
{
    my $original=\&Mediabot::PluginManager::_v3_channel_storage_commit;
    local *Mediabot::PluginManager::_v3_channel_storage_commit=sub {my $r=$original->(@_);return {ok=>0,error=>'ack_lost'} if $r->{ok};$r};
    $clock=230;$tick->();
    ok($entry->{object}{games}{'#test'}{pending_score},'uncertain persistence acknowledgement pauses game without discarding the scored round');
    like($bot->{wire}[-1][2],qr/Partie en pause/,'score persistence failure is explicit');
}
$tick->();
ok(!exists $entry->{object}{games}{'#test'},'retry recognizes round receipt and completes without double counting');
$call->('Alice',1,'score');
like($bot->{wire}[-1][2],qr/Total : 16 pts.*2026-W44.*: 8 pts/,'two rounds accumulate once, each in its own week');
$call->('Alice',1,'top','total','2');
like($bot->{wire}[-1][2],qr/Page inexistante/,'out of range leaderboard page is explicit');
$clock=260;$call->('Alice',1,'start');
$bot->observe_public_word({authenticated=>1},'#test','Alice','ORIENTATES',0);
is($entry->{event_queue}->pending_count,1,'word event is queued before deferred delivery');
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'off',config=>{rounds=>1});
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$clock=300;$call->('Alice',1,'start');$drain->();
ok(!keys %{$entry->{object}{games}{'#test'}{engine}{players}},'off/on cannot replay queued word into a new game');
$manager->set_v3_quarantine('longest-word-v3','event','irc.channel.word','#test');
$clock=301;$word->('Alice','ORIENTATES',1);
ok(!keys %{$entry->{object}{games}{'#test'}{engine}{players}},'word event quarantine cannot mutate a round');
$manager->reset_v3_quarantine('longest-word-v3','event','irc.channel.word','#test');
$clock=302;$word->('Alice','NOTAIRES',1);
ok(exists $entry->{object}{games}{'#test'}{engine}{players}{'u.7'},'released event can accept new word');
$manager->disable('longest-word-v3');$manager->unregister_plugin('longest-word-v3');
$entry=$manager->load_package_v3('longest-word-v3',grants=>\@caps);
$entry->{object}{clock}=sub{$clock};$entry->{object}{wall_clock}=sub{$wall};
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$manager->enable('longest-word-v3');
$tick=$bot->{scheduler}{_tasks}{'plugin.v3.longest-word-v3.clock'}{cb};
$call->('Alice',1,'score');
like($bot->{wire}[-1][2],qr/Total : 16 pts.*: 8 pts/,'fresh plugin instance keeps totals and drops unfinished guesses');
$call->('Alice',1,'records');
like($bot->{wire}[-1][2],qr/Meilleures parties.*8 pts/,'legacy best-match records remain separate and available');
# A later page is a view, not eviction: twelve more real guest participants.
for my $i (1..12) {
    $clock=500+$i*100;$call->('Alice',1,'start');
    $clock++;$word->(sprintf('Guest%02d',$i),'SERA',0);
    $clock+=49;$tick->();
}
$call->('Alice',1,'top','total','3');
like($bot->{wire}[-1][2],qr/3\/3.*Guest09 4 pts.*Guest12 4 pts/,'third page exposes retained participants beyond the first ten');
$call->('Alice',1,'score');
like($bot->{wire}[-1][2],qr/Total : 16 pts/,'another match does not award points to an absent participant');
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>2});
$clock=1900;$call->('Alice',1,'start');
like($bot->{wire}[-1][2],qr/Manche 1\/2.*Mot le plus long : 10 lettres/,'first round announces the dictionary maximum with its draw');
$clock=1901;$word->('Alice','NOTAIRES',1);
$clock=1950;$tick->();$clock=1958;$tick->();
like($bot->{wire}[-1][2],qr/Manche 2\/2.*Mot le plus long : 10 lettres/,'automatically started next round also announces the dictionary maximum');
unlike($bot->{wire}[-1][2],qr/ORIENTATES|NOTAIRES/,'next draw still withholds the solutions until its closing result');
is($entry->{object}{games}{'#test'}{engine}{round_best_length},0,'announcing the theoretical maximum never initializes the player record to that maximum');
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'observe',config=>{rounds=>1});
$wire=@{$bot->{wire}};$clock=2000;$word->('Alice','ORIENTATES',1);$call->('Alice',1,'start');
is(scalar @{$bot->{wire}},$wire,'observe mode remains silent and never starts games');
$manager->unregister_plugin('longest-word-v3');
done_testing;
