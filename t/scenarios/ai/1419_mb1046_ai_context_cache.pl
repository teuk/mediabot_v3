use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Mediabot::AI::Request qw(build_request);
use Mediabot::External::Claude ();

{
    package MB1046::Conf;
    sub get {return 'test-placeholder' if $_[1] eq 'anthropic.API_KEY';$_[0]{values}{$_[1]}}
    package MB1046::Log;
    sub log {1}
    package MB1046::Client;
    sub execute {
        my ($self,$request)=@_;push @{$self->{bot}{requests}},Storable::dclone($request);
        return {ok=>1,provider=>'anthropic',answer=>'answer_'.scalar(@{$self->{bot}{requests}})};
    }
    sub submit {
        my ($self,$request,%opts)=@_;
        my $result=$self->execute($request);
        push @{$self->{bot}{pending}},sub {$opts{on_done}->($result)};
        return 1;
    }
    package MB1046::Bot;
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::External::_chanset_ok=sub {1};
local *Mediabot::External::Claude::_claude_can_async=sub {$_[0]{async}//0};
local *Mediabot::External::Claude::_claude_client=sub {bless {bot=>$_[0]},'MB1046::Client'};
local *Mediabot::External::Claude::_queue_irc_chunks=sub {push @{$_[0]{wire}},@{$_[2]};scalar @{$_[2]}};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},$_[2];1};
local *Mediabot::Helpers::botNotice=sub {push @{$_[0]{wire}},$_[2];1};
sub setup_1419 {
    my (%opts)=@_;
    return bless {conf=>bless({values=>{
        'anthropic.MODEL'=>'example-model-a','anthropic.TEMPERATURE'=>0.7,
        'anthropic.MAX_TOKENS'=>400,'anthropic.SYSTEM_PROMPT'=>'Be helpful.',
    }},'MB1046::Conf'),logger=>bless({},'MB1046::Log'),
        requests=>[],pending=>[],wire=>[],async=>$opts{async}//0},'MB1046::Bot';
}
sub history_1419 {
    my ($bot,$nick,$channel,$topic)=@_;$topic //='topic A';
    $bot->{_claude_history}{$nick."\0".($channel//'__private__')}=[
        {role=>'user',content=>$topic},{role=>'assistant',content=>'Earlier answer.'}];
}
sub call_1419 {
    my ($bot,$nick,$channel,$prompt)=@_;$prompt //='continue';
    Mediabot::External::Claude::claudeAI($bot,undef,$nick,$channel,$prompt);
}
sub complete_1419 {my $cb=shift @{$_[0]{pending}};$cb->() if $cb}
my $fingerprint=Mediabot::AI::Request->can('request_cache_key');
my $request=build_request(provider=>'anthropic',purpose=>'ai',model=>'example-model-a',
    system=>'Be helpful.',messages=>[{role=>'user',content=>'Bonjour 🌍'}],
    max_output_tokens=>400,temperature=>0.7,timeout_seconds=>30);
my $key=$fingerprint ? $fingerprint->($request,"Alice\0#room") : undef;
like($key//'',qr/\Aai1:[0-9a-f]{64}\z/,'shared request layer provides a versioned opaque UTF-8-safe cache key');
{
    my $before=dclone($request);my %reordered=map {$_=>$request->{$_}} reverse sort keys %$request;
    my $second=$fingerprint ? $fingerprint->(\%reordered,"Alice\0#room") : undef;
    ok(defined($key) && defined($second) && $key eq $second,
        'canonical field ordering gives the same cache key');
    is_deeply($request,$before,'fingerprinting never modifies caller-owned request data');
}
{
    my @bad=({messages=>[]}, {%$request,authorization=>'forbidden-field'});
    ok($fingerprint && !defined($fingerprint->($request,{}))
        && !defined($fingerprint->($request,''))
        && !grep({defined($fingerprint->($_,'scope'))} @bad),
        'invalid requests, extra transport fields and invalid scopes cannot produce cache keys');
}
{
    my $bot=setup_1419();history_1419($bot,'Alice','#room','topic A');call_1419($bot,'Alice','#room');
    history_1419($bot,'Alice','#room','topic B');call_1419($bot,'Alice','#room');
    is_deeply([scalar(@{$bot->{requests}}),$bot->{requests}[-1]{messages}[0]{content},
        $bot->{_claude_history}{"Alice\0#room"}[-1]{content}],
        [2,'topic B','answer_2'],'same final prompt with different preceding context gets a fresh contextual answer');
}
{
    my $bot=setup_1419();call_1419($bot,'Alice','#room');call_1419($bot,'Alice','#room');
    is_deeply([scalar(@{$bot->{requests}}),scalar(@{$bot->{requests}[-1]{messages}}),
        $bot->{_claude_history}{"Alice\0#room"}[-1]{content}],
        [2,3,'answer_2'],'repeating continue after an answer advances the conversation instead of replaying the old answer');
}
for my $target (['Bob','#room'],['Alice','#other'],['Alice',undef]) {
    my ($nick,$channel)=@$target;my $bot=setup_1419();
    call_1419($bot,'Alice','#room');call_1419($bot,$nick,$channel);
    is(scalar(@{$bot->{requests}}),2,'cache stays isolated across nickname, channel and private conversation scopes');
}
for my $change (['anthropic.MODEL','example-model-b'],['anthropic.TEMPERATURE',0.2],
        ['anthropic.MAX_TOKENS',200],['anthropic.SYSTEM_PROMPT','Different instructions.']) {
    my ($field,$value)=@$change;my $bot=setup_1419();
    call_1419($bot,'Alice','#room');$bot->{_claude_history}{"Alice\0#room"}=[];
    $bot->{conf}{values}{$field}=$value;call_1419($bot,'Alice','#room');
    is(scalar(@{$bot->{requests}}),2,"changing $field invalidates the effective request cache");
}
{
    my $bot=setup_1419();call_1419($bot,'Alice','#room','US');
    $bot->{_claude_history}{"Alice\0#room"}=[];call_1419($bot,'Alice','#room','us');
    is(scalar(@{$bot->{requests}}),2,'prompt case is preserved when it changes the actual AI request');
}
{
    my $bot=setup_1419();history_1419($bot,'Alice','#room');call_1419($bot,'Alice','#room');
    history_1419($bot,'Alice','#room');call_1419($bot,'Alice','#room');
    is_deeply([scalar(@{$bot->{requests}}),$bot->{wire},$bot->{_claude_history}{"Alice\0#room"}[-1]{role}],
        [1,['answer_1','answer_1'],'assistant'],'an identical validated replay retains the useful cache hit and completes history');
}
{
    my $bot=setup_1419(async=>1);call_1419($bot,'Alice','#room');
    ok($bot->{_claude_inflight}{"Alice\0#room"} && !@{$bot->{wire}},
        'async caller retains its in-flight guard until the delayed provider completion');
    complete_1419($bot);call_1419($bot,'Alice','#room');complete_1419($bot);
    is_deeply([scalar(@{$bot->{requests}}),$bot->{wire},
        exists($bot->{_claude_inflight}{"Alice\0#room"})?1:0],
        [2,['answer_1','answer_2'],0],'async turns also use full context and release their own conversation guard');
}
{
    my $bot=setup_1419(async=>1);call_1419($bot,'Alice','#room');complete_1419($bot);
    $bot->{_claude_history}{"Alice\0#room"}=[];call_1419($bot,'Alice','#room');
    is_deeply([scalar(@{$bot->{requests}}),scalar(@{$bot->{pending}}),$bot->{wire},
        exists($bot->{_claude_inflight}{"Alice\0#room"})?1:0],
        [1,0,['answer_1','answer_1'],0],
        'an exact async replay completes from cache without starting a worker or retaining the in-flight guard');
}
{
    my $bot=setup_1419();call_1419($bot,'Alice','#room');
    $_->{ts}=time()-61 for values %{$bot->{_claude_prompt_cache}};
    $bot->{_claude_history}{"Alice\0#room"}=[];call_1419($bot,'Alice','#room');
    is(scalar(@{$bot->{requests}}),2,'the existing sixty-second cache lifetime still expires identical requests');
}
{
    my $bot=setup_1419();$bot->{_claude_prompt_cache}{legacy}={ts=>time(),answer=>'must not be replayed'};
    my $p={prompt_key=>'legacy',history=>[],max_history=>6,model=>'example-model-a',
        sys_prompt=>'Be helpful.',max_tokens=>400,temperature=>0.7,nick=>'Alice',chan=>'#room',
        wrap_bytes=>400,max_privmsg=>2,sleep_us=>0};
    Mediabot::External::Claude::_claude_send_and_parse($bot,$p);
    ok(!@{$bot->{requests}} && !@{$p->{history}}
        && !grep({/must not be replayed/} @{$bot->{wire}}),
        'an invalid conversation cannot bypass request validation through a pre-existing cache entry');
    my $async=setup_1419(async=>1);
    $async->{_claude_prompt_cache}{legacy}={ts=>time(),answer=>'must not be replayed'};
    my $invalid={%$p,history=>[]};my $state;
    Mediabot::External::Claude::_claude_send_and_parse_async($async,$invalid,sub {$state=$_[1]});
    is_deeply([scalar(@{$async->{requests}}),$invalid->{history},$state],
        [0,[],'failure'],'async validation also rejects invalid history before consulting the cache');
}
is_deeply(\@warnings,[],'request hashing and sync/async conversation cache paths remain warning-free');

1;
