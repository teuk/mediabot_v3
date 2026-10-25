use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use IO::Async::Loop;
use Mediabot::Scheduler;
use Mediabot::EventBus;
use Mediabot::CommandRegistry;
use Mediabot::PluginManager;
use Mediabot::Plugin::WordSolverV3;
{
    package MB959::RuntimeConf;
    sub get {$_[0]{$_[1]}}
    package MB959::RuntimeLog;
    sub log {push @{$_[0]{lines}},$_[2];1}
    package MB959::RuntimeBot;
    sub events { $_[0]{events} }
    sub command_registry {$_[0]{registry}}
    sub getLoop {$_[0]{loop}}
    sub plugin_channel_message {push @{$_[0]{wire}},['channel',$_[1],$_[2]];1}
    package MB959::RuntimeCaller;
    sub nick {$_[0]{nick} // 'Alice'}
    sub channel {$_[0]{channel} // '#test'}
    sub args {$_[0]{args} // []}
    sub is_private {0}
    sub reply {push @{$_[0]{wire}},['reply',$_[0]->channel,$_[1]];1}
    sub reply_private {push @{$_[0]{wire}},['notice',$_[0]->nick,$_[1]];1}
    package MB959::RuntimeService;
    sub solve {
        my ($s,$plugin,$channel,$letters,$cb)=@_;
        push @{$s->{calls}},[$plugin,$channel,$letters,$cb];
        $cb->(Mediabot::Plugin::WordSolverV3->result($letters,$s->{words} || [qw(ORIENTATES NOTAIRES RAISON SERA ETE)])) unless $s->{hold};
        return {accepted=>1};
    }
    sub cancel_scope {push @{$_[0]{cancelled}},$_[2];1}
    sub cancel_plugin {$_[0]{disabled}++;1}
}
my $tmp=tempdir(CLEANUP=>1);
my $loop=IO::Async::Loop->new;
my $bot=bless {events=>Mediabot::EventBus->new,registry=>Mediabot::CommandRegistry->new, loop=>$loop, wire=>[],
    conf=>bless({'plugins.DATA_DIR'=>"$tmp/data"},'MB959::RuntimeConf'),
    logger=>bless({lines=>[]},'MB959::RuntimeLog')},'MB959::RuntimeBot';
$bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop,logger=>$bot->{logger});
my $service=bless {calls=>[],cancelled=>[]},'MB959::RuntimeService';
my $m=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins',v3_dictionary_service=>$service);
my @caps=qw(events.subscribe data.dictionary.read irc.reply irc.notice irc.channel_message scheduler.jobs storage.kv);
my $p=$m->load_package_v3('longest-word-v3',grants=>\@caps);
my $clock=100;
$p->{object}{clock}=sub {$clock};
no warnings 'redefine';
local *Mediabot::Plugin::LongestWord::_rack=sub {'AEEINORSTT'};
my $handler=$bot->{registry}->handler_for('motlong','public');
my $caller=bless {wire=>$bot->{wire}},'MB959::RuntimeCaller';
$handler->($caller);
is(scalar @{$service->{calls}},0,'loaded package starts disabled');
$m->set_v3_channel_policy('longest-word-v3','#test',mode=>'observe',config=>{rounds=>1});
$m->enable('longest-word-v3');$handler->($caller);
is(scalar @{$service->{calls}},0,'observe has no game mutations or dictionary load');
is(scalar @{$bot->{wire}},0,'observe stays silent');
$m->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$handler->($caller);
is(scalar @{$service->{calls}},1,'public command reaches native capability facade');
is($p->{object}{games}{'#test'}{engine}{phase},'playing','dictionary completion opens the round');
like($bot->{wire}[0][2],qr/Manche 1\/1.*Mot le plus long : 10 lettres.*50s/,'draw includes the solver maximum length and duration through the native reply sink');
unlike($bot->{wire}[0][2],qr/ORIENTATES|NOTAIRES/,'opening announcement does not reveal dictionary solutions');
my $call=sub {my ($nick,@args)=@_;$caller->{nick}=$nick;$caller->{args}=\@args;$handler->($caller)};
$clock=101;$call->('Bob','NOTAIRES');
$clock=102;$call->('Max','NOTAIRES');
my $engine=$p->{object}{games}{'#test'}{engine};
$clock=103;$call->('Alice','ORIENTATES');
is(scalar keys %{$engine->{players}},2,'only strictly improving words create round participants');
is(scalar grep($_->[0] eq 'reply' && $_->[2] =~ /retenu/,@{$bot->{wire}}),2,'each accepted improvement has one public acknowledgement');
is(scalar grep($_->[0] eq 'notice',@{$bot->{wire}}),1,'equal rejected word alone receives a private notice');
ok(!exists $p->{object}{games}{'#test'},'maximum immediately finishes and saves a one-round match');
$caller->{channel}='#other';$clock=104;$call->('Elsewhere','ORIENTATES');
is(scalar @{$service->{calls}},1,'unconfigured channel cannot borrow a running game');
$caller->{channel}='#test';
my $tick=$bot->{scheduler}{_tasks}{'plugin.v3.longest-word-v3.clock'}{cb};
$clock=150;$tick->();
ok(!exists $p->{object}{games}{'#test'},'scheduler closes finite match and releases state');
like(join(' ',map {$_->[2]} @{$bot->{wire}}),qr/Alice 13 pts.*Bob 8 pts/,'native game scores accepted record improvements only');
my $n=@{$bot->{wire}};$tick->();
is(scalar @{$bot->{wire}},$n,'repeated scheduler tick cannot repeat final score');
$call->('Alice','top');
like($bot->{wire}[-1][2],qr/Alice 13 pts/,'records persist through the actual KV repository');
ok(-f "$tmp/data/v3-longest-word-v3.json",'records are saved by the core outside the dictionary');
$clock=180;$service->{hold}=1;$call->('Alice','start');
my $late=$service->{calls}[-1][3];
$m->set_v3_channel_policy('longest-word-v3','#test',mode=>'off',config=>{rounds=>1});
ok(!exists $p->{object}{games}{'#test'},'off immediately discards an unfinished game');
$m->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$n=@{$bot->{wire}};
$late->(Mediabot::Plugin::WordSolverV3->result('AEEINORSTT',['ORIENTATES']));
is(scalar @{$bot->{wire}},$n,'off/on cannot revive an older dictionary callback');
$clock=210;$call->('Alice','start');
$clock=211;$call->('Bob','stop');
ok(exists $p->{object}{games}{'#test'},'another anonymous user cannot stop the match');
$clock=212;$call->('Alice','stop');
ok(!exists $p->{object}{games}{'#test'},'initiator can stop a preparing match');
ok(@{$service->{cancelled}}>=3,'policy edits and explicit stop cancel scoped lookups');
$clock=240;$call->('Alice','start');
$late=$service->{calls}[-1][3];
$m->disable('longest-word-v3');
ok($service->{disabled},'native disable cancels dictionary workers');
ok(!keys %{$p->{object}{games}},'native stop hook clears all game state');
$n=@{$bot->{wire}};$late->({ok=>1,letters=>'AEEINORSTT',words=>['ORIENTATES']});
is(scalar @{$bot->{wire}},$n,'disabled completion is inert');
$m->unregister_plugin('longest-word-v3');
$handler->($caller);
is(scalar @{$bot->{wire}},$n,'retained command handler is inert after unload');
ok(!$bot->{registry}->has_command('motlong','public'),'unload removes only its command');
my $again=$m->load_package_v3('longest-word-v3',grants=>\@caps);
$m->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1});
$m->enable('longest-word-v3');
$caller->{args}=['top'];$bot->{registry}->handler_for('motlong','public')->($caller);
like($bot->{wire}[-1][2],qr/Alice 13 pts/,'records survive unloading and loading a fresh plugin instance');
is($bot->{registry}->has_command('longest','public'),1,'English alias is mounted through the same native registry');
$again->{object}{clock}=sub {$clock};
$service->{hold}=0;$service->{words}=[qw(STOP TOP PAIRE)];
{
    local *Mediabot::Plugin::LongestWord::_rack=sub {'STOPAEIIRN'};
    $clock=300;$caller->{args}=['start'];$caller->{nick}='Alice';
    $bot->{registry}->handler_for('motlong','public')->($caller);
    $clock=301;$caller->{args}=['mot','STOP'];
    $bot->{registry}->handler_for('motlong','public')->($caller);
    is($again->{object}{games}{'#test'}{engine}{players}{'n.alice'}{word},'STOP',
        'explicit word syntax can submit a reserved control word');
    is($again->{object}{games}{'#test'}{engine}{phase},'playing','reserved word proposal cannot stop a game');
}
my $authority=$again->{metadata}{plugin_context};
my $probe=Mediabot::Plugin::InvocationV3->new(nick=>'Alice',channel=>'#test',command=>'motlong',args=>[],
    authority=>$authority,activation=>'on',reply_sink=>sub {1},notice_sink=>sub {1});
$m->set_v3_quarantine('longest-word-v3','command','motlong','#test');
my $before=@{$service->{calls}};
my $blocked=$authority->dictionary_solve($probe,'AEEINORSTT',sub {die 'quarantined callback escaped'});
is($blocked->{error},'quarantined','retained invocation cannot start a quarantined read');
is(scalar @{$service->{calls}},$before,'quarantine is checked before launching dictionary work');
$m->unregister_plugin('longest-word-v3');
done_testing;
