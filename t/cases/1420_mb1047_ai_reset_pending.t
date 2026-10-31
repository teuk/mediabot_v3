use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::External::Claude ();

{
    package MB1047::Conf;
    sub get { return 'test-placeholder' if $_[1] eq 'anthropic.API_KEY'; $_[0]{values}{$_[1]} }
    package MB1047::Log;
    sub log { push @{$_[0]{rows}}, $_[2]; 1 }
    package MB1047::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    package MB1047::Client;
    sub submit {
        my ($self,$request,%opts)=@_;
        push @{$self->{bot}{requests}}, Storable::dclone($request);
        push @{$self->{bot}{pending}}, $opts{on_done};
        return 1;
    }
    package MB1047::Context;
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub message { undef }
    sub args { [$_[0]{command}] }
    package MB1047::Bot;
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::External::_chanset_ok=sub {1};
local *Mediabot::External::Claude::_claude_can_async=sub {1};
local *Mediabot::External::Claude::_claude_client=sub {bless {bot=>$_[0]},'MB1047::Client'};
local *Mediabot::External::Claude::_queue_irc_chunks=sub {push @{$_[0]{wire}},@{$_[2]};scalar @{$_[2]}};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},$_[2];1};
local *Mediabot::Helpers::botNotice=sub {push @{$_[0]{wire}},$_[2];1};
sub bot_1420 {
    return bless {conf=>bless({values=>{
        'anthropic.MODEL'=>'example-model','anthropic.TEMPERATURE'=>0.7,
        'anthropic.MAX_TOKENS'=>400,'anthropic.SYSTEM_PROMPT'=>'Be helpful.',
    }},'MB1047::Conf'),logger=>bless({rows=>[]},'MB1047::Log'),
        metrics=>bless({},'MB1047::Metrics'),requests=>[],pending=>[],wire=>[]},'MB1047::Bot';
}
sub ask_1420 {
    my ($bot,$prompt,$nick,$channel)=@_; $nick //='Alice';
    Mediabot::External::Claude::claudeAI($bot,undef,$nick,$channel,$prompt);
}
sub clear_1420 {
    my ($bot,$command,$nick,$channel)=@_;$nick //='Alice';
    Mediabot::External::Claude::claude_ctx(bless {
        bot=>$bot,command=>$command,nick=>$nick,channel=>$channel,
    },'MB1047::Context');
}
sub finish_1420 {
    my ($bot,$index,$result)=@_;
    $result //={ok=>1,provider=>'anthropic',answer=>'answer_'.($index+1)};
    my $complete=$bot->{pending}[$index];
    $complete->($result) if ref($complete) eq 'CODE';
}
my $key="Alice\0#room";
{
    my $bot=bot_1420();ask_1420($bot,'old prompt','Alice','#room');
    my $old_history=$bot->{_claude_history}{$key};
    $bot->{_claude_persona}{"alice\0#room"}='Friendly';
    $bot->{_claude_pinned}{"alice\0#room"}='Keep this pin';
    clear_1420($bot,'reset','Alice','#room');
    ok(!exists($bot->{_claude_history}{$key}) && !exists($bot->{_claude_inflight}{$key}),
        'reset clears history and releases only the caller conversation immediately');
    is_deeply([$bot->{_claude_persona}{"alice\0#room"},$bot->{_claude_pinned}{"alice\0#room"}],
        ['Friendly','Keep this pin'],'reset preserves persona and pin as before');
    $bot->{wire}=[];finish_1420($bot,0);
    is_deeply($bot->{wire},[],'a successful pre-reset completion emits no stale IRC answer');
    ok(!exists($bot->{_claude_history}{$key}) && !keys(%{$bot->{_claude_prompt_cache}//{}}),
        'discarded completion cannot recreate history or populate the answer cache');
    is_deeply($old_history,[{role=>'user',content=>'old prompt'}],
        'discarded completion does not append an assistant answer even to detached history');
}
{
    my $bot=bot_1420();ask_1420($bot,'old prompt','Alice','#room');
    clear_1420($bot,'reset','Alice','#room');$bot->{wire}=[];
    ask_1420($bot,'fresh prompt','Alice','#room');
    is_deeply([scalar(@{$bot->{requests}}),$bot->{requests}[-1]{messages}],
        [2,[{role=>'user',content=>'fresh prompt'}]],'a new request can start immediately with a fresh context');
    my $new_owner=$bot->{_claude_inflight}{$key};$bot->{wire}=[];
    finish_1420($bot,0);
    ok(exists($bot->{_claude_inflight}{$key}) && $bot->{_claude_inflight}{$key} eq $new_owner,
        'an old completion cannot release the replacement request lock');
    is_deeply([$bot->{wire},$bot->{_claude_history}{$key}],
        [[],[{role=>'user',content=>'fresh prompt'}]],'old-first completion leaves the replacement history and output untouched');
    finish_1420($bot,1);
    is_deeply([$bot->{wire},$bot->{_claude_history}{$key}[-1],exists($bot->{_claude_inflight}{$key})?1:0],
        [['answer_2'],{role=>'assistant',content=>'answer_2'},0],'the replacement request completes normally and releases its own lock');
    is(scalar(keys %{$bot->{_claude_prompt_cache}//{}}),1,'only the current answer enters the cache');
}
{
    my $bot=bot_1420();ask_1420($bot,'old prompt','Alice','#room');
    clear_1420($bot,'reset','Alice','#room');ask_1420($bot,'fresh prompt','Alice','#room');
    finish_1420($bot,1);my $history=dclone($bot->{_claude_history});
    my $cache=dclone($bot->{_claude_prompt_cache}//{});$bot->{wire}=[];
    finish_1420($bot,0);
    is_deeply([$bot->{wire},$bot->{_claude_history},$bot->{_claude_prompt_cache}//{}],
        [[],$history,$cache],'new-first completion is also preserved when the old result arrives last');
}
{
    my $bot=bot_1420();ask_1420($bot,'old prompt','Alice','#room');
    clear_1420($bot,'reset','Alice','#room');ask_1420($bot,'fresh prompt','Alice','#room');
    $bot->{wire}=[];my $metrics=dclone($bot->{metrics});
    finish_1420($bot,0,{ok=>0,error=>'timeout'});
    is_deeply([$bot->{wire},$bot->{metrics},$bot->{_claude_history}{$key}],
        [[],$metrics,[{role=>'user',content=>'fresh prompt'}]],
        'obsolete failures do not emit errors, count as current failures or roll back the new prompt');
    ok(exists($bot->{_claude_inflight}{$key}),'obsolete failure keeps the new request serialized');
    finish_1420($bot,1);
}
{
    my $bot=bot_1420();ask_1420($bot,'old prompt','Alice','#room');
    $bot->{_claude_persona}{"alice\0#room"}='Friendly';
    $bot->{_claude_pinned}{"alice\0#room"}='A pin';
    $bot->{_ai_last_active}{"alice\0#room"}=time();
    clear_1420($bot,'forget','Alice','#room');
    ok(!exists($bot->{_claude_history}{$key}) && !exists($bot->{_claude_inflight}{$key})
        && !exists($bot->{_claude_persona}{"alice\0#room"})
        && !exists($bot->{_claude_pinned}{"alice\0#room"})
        && !exists($bot->{_ai_last_active}{"alice\0#room"}),
        'forget invalidates pending work and clears its existing history/persona/pin/activity scope');
    $bot->{wire}=[];finish_1420($bot,0);
    is_deeply([$bot->{wire},$bot->{_claude_prompt_cache}//{}],[[],{}],
        'a pre-forget answer stays silent and cannot enter the cache');
}
{
    my $bot=bot_1420();
    ask_1420($bot,'Alice public','Alice','#room');ask_1420($bot,'Bob public','Bob','#room');
    ask_1420($bot,'Alice elsewhere','Alice','#other');ask_1420($bot,'Alice private','Alice',undef);
    clear_1420($bot,'forget','Alice',undef);
    ok(exists($bot->{_claude_inflight}{$key}) && exists($bot->{_claude_inflight}{"Bob\0#room"})
        && exists($bot->{_claude_inflight}{"Alice\0#other"})
        && !exists($bot->{_claude_inflight}{"Alice\0__private__"}),
        'private forget preserves all other users and channel request owners');
    $bot->{wire}=[];finish_1420($bot,3);finish_1420($bot,1);finish_1420($bot,2);finish_1420($bot,0);
    is_deeply($bot->{wire},['answer_2','answer_3','answer_1'],
        'other conversations still complete normally while the forgotten private result is discarded');
}
{
    my $bot=bot_1420();ask_1420($bot,'first','Alice','#room');ask_1420($bot,'too early','Alice','#room');
    is(scalar(@{$bot->{requests}}),1,'normal pending requests still reject overlapping prompts');
    $bot->{wire}=[];finish_1420($bot,0);
    my $history=dclone($bot->{_claude_history});my $metrics=dclone($bot->{metrics});
    finish_1420($bot,0);
    is_deeply([$bot->{wire},$bot->{_claude_history},$bot->{metrics}],
        [['answer_1'],$history,$metrics],'duplicate completion cannot append, count or emit an answer twice');
}
{
    my $bot=bot_1420();ask_1420($bot,'failed','Alice','#room');
    finish_1420($bot,0,{ok=>0,error=>'timeout'});
    is_deeply([$bot->{_claude_history}{$key},exists($bot->{_claude_inflight}{$key})?1:0,
        $bot->{metrics}{mediabot_claude_errors_total}],
        [[],0,1],'a current failure still rolls back its orphan prompt and releases its own lock');
    ask_1420($bot,'retry','Alice','#room');
    is(scalar(@{$bot->{requests}}),2,'a failed current request can be retried normally');
    finish_1420($bot,1);
}
{
    my $bot=bot_1420();my @operator_output;
    Mediabot::External::Claude::claudeAI($bot,undef,'Alice',undef,
        sub {push @operator_output,@_},'operator prompt');
    clear_1420($bot,'reset','Alice',undef);finish_1420($bot,0);
    is_deeply(\@operator_output,[],'reset also retires a pending plain-text operator callback');
}
{
    my $bot=bot_1420();clear_1420($bot,'reset','Alice','#room');clear_1420($bot,'forget','Alice','#room');
    ok(!keys(%{$bot->{_claude_inflight}//{}}) && !keys(%{$bot->{_claude_history}//{}}),
        'repeated resets without pending work leave no session-generation registry behind');
}
is_deeply(\@warnings,[],'pending-request ownership and reset/forget completions remain warning-free');
done_testing;
