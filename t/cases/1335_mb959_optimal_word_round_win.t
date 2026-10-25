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
        $self->{calls}++;
        if ($self->{hold}) { push @{$self->{pending}}, [$rack,$cb]; return {accepted=>1} }
        $cb->(Mediabot::Plugin::WordSolverV3->result($rack,[qw(LOUPS LOUPAS POUFFAS MAFFLUS)]));
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
my $manager=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins',v3_dictionary_service=>my $service=bless({calls=>0,pending=>[]},'MB959::WordsService'));
my @caps=qw(events.subscribe data.dictionary.read irc.reply irc.notice irc.channel_message scheduler.jobs storage.kv);
my $entry=$manager->load_package_v3('longest-word-v3',grants=>\@caps);
my $clock=100;
my $wall=DateTime->new(year=>2026,month=>10,day=>25,hour=>23,minute=>59,second=>40,time_zone=>'Europe/Paris')->epoch;
$entry->{object}{clock}=sub{$clock};$entry->{object}{wall_clock}=sub{$wall};
no warnings 'redefine';
local *Mediabot::Plugin::LongestWord::_rack=sub{'FFMOASLUOP'};
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
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>2});
$manager->enable('longest-word-v3');
$call->('Alice',1,'start');
like($bot->{wire}[-1][2],qr/Manche 1\/2.*Mot le plus long : 7 lettres/,'user rack starts with the true seven-letter target');
my $game=$entry->{object}{games}{'#test'};
$clock=101;$word->('Alice','loups',1);
is($game->{engine}{phase},'playing','five letters do not end a seven-letter round');
$clock=102;$word->('Alice','loupas',1);
is($game->{engine}{completed},0,'six-letter improvement waits for the maximum or deadline');
$word->('Bob','POUFFAI',0);
is($game->{engine}{completed},0,'seven letters absent from the dictionary cannot win');
$service->{hold}=1;
my $start=@{$bot->{wire}};
$clock=103;$wall+=3;$word->('Alice','pouffas',1);
my @win=@{$bot->{wire}}[$start..$#{$bot->{wire}}];
is($game->{engine}{completed},1,'dictionary maximum closes immediately without a scheduler tick');
is($game->{engine}{players}{'u.7'}{score},10,'seven letters plus the configured three-point bonus are credited immediately');
is($game->{engine}{players}{'u.7'}{tops},1,'top is counted exactly once');
is($game->{engine}{phase},'preparing','next dictionary request starts immediately after saving the won round');
is($service->{calls},2,'next round does not wait for the previous deadline or eight-second pause');
like(join(' ',map {$_->[2]} @win),qr/Alice : POUFFAS retenu.*7 points \+ 3 de bonus = 10 points.*Manche remportée/,'public win names the player and spells out the bonus');
unlike(join(' ',map {$_->[2]} @win),qr/au moins 8|Temps écoulé|Dernières secondes/,'top winner is never asked for an impossible improvement or told time expired');
is(scalar grep($_->[0] ne 'channel' || $_->[1] ne '#test',@win),0,'winner and result messages stay public in their own channel');
$call->('Alice',1,'score');
like($bot->{wire}[-1][2],qr/Total : 10 pts.*2026-W43.*: 10 pts/,'early win is saved in the actual Sunday week despite a Monday planned deadline');
my $tick=$bot->{scheduler}{_tasks}{'plugin.v3.longest-word-v3.clock'}{cb};
$tick->();$tick->();
is($game->{engine}{players}{'u.7'}{score},10,'ticks during asynchronous next-draw preparation cannot rescore the winner');

# A proposal received before the new draw must not leak into that draw, even
# when the injected clock gives the old close and new open identical timestamps.
$bot->observe_public_word({authenticated=>0},'#test','Bob','MAFFLUS',0);
my ($rack,$ready)=@{shift @{$service->{pending}}};
$ready->(Mediabot::Plugin::WordSolverV3->result($rack,[qw(LOUPS LOUPAS POUFFAS MAFFLUS)]));
like($bot->{wire}[-1][2],qr/Manche 2\/2.*Mot le plus long : 7 lettres/,'next draw opens immediately when its asynchronous result arrives');
is($game->{engine}{round_best_length},0,'new round starts at zero after an early win');
my $before=@{$bot->{wire}};$drain->();
is($game->{engine}{round_best_length},0,'queued old-round maximum cannot win the new draw');
is(scalar @{$bot->{wire}},$before,'old proposal produces no new-round output');
$clock=104;$word->('Bob','LOUPS',0);
is($game->{engine}{round_best_length},5,'a fresh shorter word is accepted after the new draw');

{
    my $original=\&Mediabot::PluginManager::_v3_channel_storage_commit;
    local *Mediabot::PluginManager::_v3_channel_storage_commit=sub {
        my $result=$original->(@_);
        return $result->{ok} ? {ok=>0,error=>'ack_lost'} : $result;
    };
    $clock=105;$wall+=60;$call->('Alice',1,'POUFFAS');
    ok($game->{pending_score},'command-route maximum pauses on an uncertain save acknowledgement');
    is($game->{engine}{phase},'done','last-round maximum completes the match immediately');
    is($game->{engine}{players}{'u.7'}{score},20,'second maximum adds its length and bonus once');
    like($bot->{wire}[-1][2],qr/Partie en pause/,'save failure is explicit');
    is($service->{calls},2,'no new draw starts before score persistence is confirmed');
}
$tick->();
ok(!exists($entry->{object}{games}{'#test'}),'receipt retry finalizes the match without another round');
$call->('Alice',1,'score');
like($bot->{wire}[-1][2],qr/Total : 20 pts.*2026-W44.*: 10 pts/,'two early wins persist exactly once in their actual weeks');
$call->('Alice',1,'top','semaine','2026-W43');
like($bot->{wire}[-1][2],qr/Alice 10 pts/,'first early win stays in its original week');
$clock=200;$before=@{$bot->{wire}};$tick->();$tick->();
is(scalar @{$bot->{wire}},$before,'old deadlines and repeated ticks cannot repeat results or bonuses');

$service->{hold}=0;
$manager->set_v3_channel_policy('longest-word-v3','#test',mode=>'on',config=>{rounds=>1,top_bonus=>5});
$clock=250;$call->('Alice',1,'start');
my $custom=$entry->{object}{games}{'#test'};
$clock=251;$start=@{$bot->{wire}};$call->('Alice',1,'POUFFAS');
is($custom->{engine}{players}{'u.7'}{score},12,'configured five-point bonus replaces the default instead of adding a second bonus');
like(join(' ',map {$_->[2]} @{$bot->{wire}}[$start..$#{$bot->{wire}}]),qr/7 points \+ 5 de bonus = 12 points/,'command-route public win reports the configured bonus');
ok(!exists($entry->{object}{games}{'#test'}),'custom-bonus final round also finishes immediately');
$manager->unregister_plugin('longest-word-v3');
done_testing;
