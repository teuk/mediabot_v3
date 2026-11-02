use strict;
use warnings;
use utf8;
use Test::More;
BEGIN { our $wall=1_900_000_000; *CORE::GLOBAL::time=sub {$main::wall} }
use Mediabot::Mediabot;
use Mediabot::Partyline;
use Mediabot::Helpers ();
use Mediabot::IRC::CommandThrottle ();
use Storable qw(dclone);
{
    package Cooldown335::Conf;
    sub get {$_[1] eq 'antiflood.CHANFLOOD_MAX_COMMANDS' ? 1 : undef}
    package Cooldown335::Log;
    sub log {push @{$_[0]{rows}},$_[2];1}
    package Cooldown335::Metrics;
    sub inc {++$_[0]{$_[1]};1}
    package Cooldown335::Stream;
    sub write {$_[0]{text}.=$_[1];1}
    package Cooldown335::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD {die 'Unexpected database or IRC operation'}
    sub DESTROY {}
}
my ($bot,$mono,@calls,@notices,@warnings,@console);
no warnings qw(redefine once);
local *Time::HiRes::clock_gettime=sub {$mono};
local *Mediabot::botNotice=sub {push @notices,[@_[1,2]];1};
local *Mediabot::Helpers::noticeConsoleChan=sub {push @console,$_[1];1};
local $SIG{__WARN__}=sub {push @warnings,@_};
sub setup335 {
    $mono=1000;$main::wall=1_900_000_000;@calls=();@notices=();@console=();
    $bot=Mediabot->new({conf=>bless({},'Cooldown335::Conf'),dbh=>bless({},'Cooldown335::NoIO')});
    $bot->{logger}=bless {rows=>[]},'Cooldown335::Log';
    $bot->{metrics}=bless {},'Cooldown335::Metrics';
    $bot->{irc}=bless {},'Cooldown335::NoIO';
    for my $name (qw(ai claude login ident auth moduser)) {
        my $entry=$bot->commands->command_for($name,'private') or die "Missing native private $name";
        $bot->commands->register_command(name=>$entry->{name},source=>'private',replace=>1,
            aliases=>[$bot->commands->aliases_for($entry->{name},'private')],
            handler=>sub {my ($ctx)=@_;push @calls,[$ctx->nick,$ctx->command,$ctx->is_private?1:0];1});
    }
}
sub invoke335 {$bot->mbCommandPrivate(undef,$_[0],$_[1],'PRIVATE_PROMPT_MARKER')}
sub waits335 {return [map {my ($wait)=$_->[1]=~/wait (\d+)s/;[$_->[0],$wait]} @notices]}
sub slots335 {return $bot->{_private_cmd_cooldown}//{}}

setup335();
is_deeply([Mediabot::Helpers::checkChanFlood($bot,'#test'),
    Mediabot::Helpers::checkChanFlood($bot,'#TEST'),scalar(@console)], [0,1,1],
    'public AF4 still shares its channel threshold and notification');
setup335();invoke335('Alice','ai');invoke335('Alice','ai');
is_deeply([\@calls,waits335()],[[['Alice','ai',1]],[['Alice',10]]],
    'native private dispatcher reserves before its handler and blocks a repeated expensive command');
setup335();invoke335('Te[u]K','ai');invoke335('TE{U}K','AI');
is_deeply([scalar(@calls),waits335(),[sort keys %{slots335()}]],
    [1,[['TE{U}K',10]],['ai:te{u}k']],
    'letter casing and RFC1459-equivalent nick spellings cannot create a private bypass');
setup335();invoke335('Alice','ai');invoke335('Bob','ai');
is_deeply([scalar(@calls),Mediabot::Helpers::checkCmdCooldown($bot,'#test','ai'),
    Mediabot::Helpers::checkCmdCooldown($bot,'#TEST','ai'),
    Mediabot::Helpers::checkCmdCooldown($bot,'#other','ai'),scalar(keys %{slots335()})],
    [2,0,10,0,2],'private users and public channels retain independent cooldown scopes');
setup335();invoke335('Alice','ai');invoke335('Alice','CLAUDE');
my @public_alias=(Mediabot::Helpers::checkCmdCooldown($bot,'#test','claude'),
    Mediabot::Helpers::checkCmdCooldown($bot,'#test','ai'));
my $stream=bless {text=>''},'Cooldown335::Stream';
my $party=bless {bot=>$bot,users=>{1=>{authenticated=>1,login=>'Owner',nick=>'Owner',level=>0}},
    streams=>{1=>$stream}},'Mediabot::Partyline';
$party->_handle_line($stream,1,'.cmdcooldown #TeSt CLAUDE 7');
is_deeply([scalar(@calls),waits335(),\@public_alias,$bot->{_cmd_cooldown_conf},
    Mediabot::Helpers::checkCmdCooldown($bot,'#test','ai'),
    Mediabot::Helpers::checkCmdCooldown($bot,'#test','claude')],
    [1,[['Alice',10]],[0,10],{'#test'=>{ai=>7}},0,7],
    'Claude and ai share their private/public cooldown and native partyline operator setting');
setup335();invoke335('Alice','ai');$mono=1009.25;invoke335('Alice','ai');
$mono=1009.9;invoke335('Alice','ai');
is_deeply([scalar(@calls),waits335(),slots335()->{'ai:alice'}],
    [1,[['Alice',1],['Alice',1]],1010],
    'fractional remaining time rounds up and blocked calls never extend the reservation');
$mono=1010;invoke335('Alice','ai');
is_deeply([scalar(@calls),slots335()->{'ai:alice'}],[2,1020],
    'the exact private deadline admits one new invocation and replaces its expired reservation');
setup335();invoke335('Alice','ai');$main::wall-=3600;$mono+=10;invoke335('Alice','ai');
is_deeply([scalar(@calls),scalar(@notices)],[2,0],
    'wall-clock changes cannot prolong a private cooldown measured by the monotonic clock');
setup335();invoke335('Alice','ai');invoke335('Alice','ai');
invoke335('Alice',$_) for (qw(login ident auth moduser)) x 2;
is_deeply([scalar(@calls),scalar(@notices),exists($bot->{_chan_flood})?1:0,
    exists($bot->{_nick_flood})?1:0],[9,1,0,0],
    'login, identification, auth and account administration remain dispatchable without a public/nick flood gate');
setup335();
{
    local $Mediabot::IRC::CommandThrottle::MAX_PRIVATE_COOLDOWNS=2;
    invoke335('Alice','ai');$mono+=3;invoke335('Bob','ai');
    my $before=dclone(slots335());invoke335('Cara','ai');invoke335('Alice','ai');
    is_deeply([scalar(@calls),waits335(),slots335()],
        [2,[['Cara',7],['Alice',7]],$before],
        'a full private map rejects new admission without evicting an active caller or growing state');
    $mono=1010;invoke335('Cara','ai');
    is_deeply([scalar(@calls),slots335()],
        [3,{'ai:bob'=>1013,'ai:cara'=>1020}],
        'expiry reclaims private capacity before admitting the next caller');
}
setup335();
my @unscoped=map {Mediabot::Helpers::checkCmdCooldown($bot,$_,'ai')} (undef,'','Caller','&room');
push @unscoped,Mediabot::Helpers::checkCmdCooldown($bot,undef,'ai',undef,[]),
    Mediabot::Helpers::checkCmdCooldown($bot,undef,'userinfo',undef,'Alice');
is_deeply([\@unscoped,exists($bot->{_private_cmd_cooldown})?1:0,
    exists($bot->{_cmd_cooldown})?1:0],[[0,0,0,0,0,0],0,0],
    'legacy calls without an explicit private actor and commands without a cooldown allocate no state');
setup335();invoke335('Alice','ai');invoke335('Alice','claude');invoke335('Alice','ai');
is_deeply([$bot->{metrics}{mediabot_cmdcooldown_blocks_total},scalar(@calls),\@warnings,
    scalar(grep {/PRIVATE_PROMPT_MARKER/} @{$bot->{logger}{rows}})], [2,1,[],0],
    'blocked attempts feed existing metrics without executing handlers, leaking prompts or warning');
done_testing;
