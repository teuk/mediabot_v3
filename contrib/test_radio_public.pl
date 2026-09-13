use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
BEGIN {
    $INC{'Mediabot/Helpers.pm'}=__FILE__;
    package Mediabot::Helpers;
    sub chanset_enabled { return $_[0]{radio_on} }
    sub channel_lang { 'en' }
}
use Mediabot::Radio::Public;
use Mediabot::Context;
use Mediabot::AI::ConversationRuntimeState;
{
    package MB734Conf; sub get { $_[0]{$_[1]} }
    package MB734IRC; sub is_connected { $_[0]{connected} } sub nick_folded { 'bot' }
    package MB734Message; sub prefix { $_[0]{prefix} }
    package MB734Bot;
    sub botNotice { push @{$_[0]{notices}},$_[2] }
    sub botPrivmsg { die 'No public radio feedback allowed' }
    sub getLoop { $_[0]{loop} }
    sub get_user_from_message { die 'Guest must not need a database account' }
}
my $dir=tempdir(CLEANUP=>1);
my $path="$dir/token";
open my $fh,'>',$path or die $!; print {$fh} 'a'x64; close $fh; chmod 0600,$path;
my $state=Mediabot::AI::ConversationRuntimeState->new;
$state->mark_connected; $state->mark_joined('#radio');
my $bot=bless {radio_on=>1,notices=>[],loop=>bless({},'LoopFixture'),
    irc=>bless({connected=>1},'MB734IRC'),
    wit_runtime_state=>$state,
    hChannelsNicks=>{'#Radio'=>['bot','Guest']},
    conf=>bless({'radio.RADIO_API_ENABLED'=>'1','radio.RADIO_API_TOKEN_FILE'=>$path},'MB734Conf')},'MB734Bot';
my $ctx=Mediabot::Context->new(bot=>$bot,channel=>'#radio',nick=>'Guest',
    message=>bless({prefix=>'Guest!ident@example.test'},'MB734Message'),
    args=>['https://youtu.be/abcdefghijk']);
ok(Mediabot::Radio::Public::enabled($ctx),'explicit +Radio capability');
ok(Mediabot::Radio::Public::present($ctx),'caller and bot membership, folded channel');
is(Mediabot::Radio::Public::fold('Te[u]K'),'te{u}k','RFC1459 nick folding');
is(Mediabot::Radio::Public::endpoint('http://127.0.0.1:8765/'),'http://127.0.0.1:8765','single host needs no TLS');
is(Mediabot::Radio::Public::endpoint('https://radio.example/api'),'https://radio.example/api','remote HTTPS prefix');
for my $url ('http://teuk.org:8765','https://user:pass@teuk.org/api','https://teuk.org/api?token=x',
             'https://teuk.org/#x',"https://teuk.org/\nHeader:x",'https://teuk.org:99999') {
    ok(!eval {Mediabot::Radio::Public::endpoint($url);1},'reject unsafe API URL');
}
is(Mediabot::Radio::Public::token($path),'a'x64,'private token file accepted');
chmod 0644,$path;
ok(!eval {Mediabot::Radio::Public::token($path);1},'world readable token refused');
chmod 0600,$path;
symlink $path,"$dir/link";
ok(!eval {Mediabot::Radio::Public::token("$dir/link");1},'symbolic token refused');
my %worker;
my @calls;
{
    no warnings 'redefine';
    local *Mediabot::AsyncWorker::start=sub { shift; %worker=@_; return bless({},'WorkerFixture') };
    local *Mediabot::Radio::Public::call_api=sub {
        my ($url,$token,$method,$route,$body)=@_; push @calls,[$method,$route,$body];
        return {state=>'queued',title=>'Artist - Track',rid=>42};
    };
    ok(Mediabot::Radio::Public::submit($ctx,'play'),'guest request accepted without user lookup');
    ok(ref($worker{child}) eq 'CODE','network runs in supervised child');
    is(scalar(@calls),0,'IRC parent never calls HTTP');
    my $result=$worker{child}->(sub{});
    is($calls[0][0],'POST','request uses POST');
    is($calls[0][1],'/v1/requests','bounded request endpoint');
    is_deeply([sort keys %{$calls[0][2]}],[sort qw(id caller channel action query)],'no remote UID or path or instance spoof');
    like($calls[0][2]{caller},qr/\A[a-f0-9]{64}\z/,'host identity hashed');
    $worker{on_done}->({value=>$result,ok=>1});
    like($bot->{notices}[-1],qr/added to the queue/,'success reports queue, not playback');
    is(scalar(keys %{$bot->{_radio_api_pending}}),0,'completion releases pending slot');
    $ctx->{args}=['Michael','Jackson','Billie','Jean'];
    @calls=();
    Mediabot::Radio::Public::submit($ctx,'play');
    $result=$worker{child}->(sub{});
    is($calls[0][2]{action},'play','text play remains play, not random catalogue lookup');
    is($calls[0][2]{query},'Michael Jackson Billie Jean','artist/title reach central API verbatim');
    $worker{on_done}->({value=>$result,ok=>1});
    @calls=();
    Mediabot::Radio::Public::submit($ctx,'rplay');
    $result=$worker{child}->(sub{});
    is($calls[0][2]{action},'rplay','rplay keeps its random catalogue operation');
    $worker{on_done}->({value=>$result,ok=>1});
    $ctx->{args}=['https://youtu.be/abcdefghijk'];
    $bot->{radio_on}=0;
    is(Mediabot::Radio::Public::submit($ctx,'play'),undef,'+Radio off does not submit');
    $bot->{radio_on}=1;
    $ctx->{nick}='Outsider';
    is(Mediabot::Radio::Public::submit($ctx,'play'),undef,'nonmember cannot submit');
    $ctx->{nick}='Guest';
    Mediabot::Radio::Public::submit($ctx,'play');
    my $count=@{$bot->{notices}};
    $state->mark_disconnected; $state->mark_connected; $state->mark_joined('#radio');
    $worker{on_done}->({value=>$result,ok=>1});
    is(scalar(@{$bot->{notices}}),$count,'reconnection suppresses stale reply');
    for my $case (
        [{error=>'caller_cooldown',retry_after=>83}, qr/Wait another 83 s/],
        [{error=>'channel_cooldown',retry_after=>4}, qr/Wait another 4 s/],
        [{error=>'request_pending'}, qr/previous request is still/],
        [{error=>'service_queue_full'}, qr/queue is full/],
        [{state=>'failed',code=>'no_matching_track'}, qr/No catalogue track matches/],
        [{state=>'failed',code=>'no_youtube_match'}, qr/No suitable video found/],
        [{state=>'failed',code=>'youtube_search_failed'}, qr/YouTube search is unavailable/],
        [{state=>'failed',code=>'catalogue_tracks_unavailable'}, qr/audio file is unavailable/],
        [{state=>'failed',code=>'youtube_auth_required'}, qr/refresh its cookies/],
        [{state=>'failed',code=>'youtube_rate_limited'}, qr/rate-limiting downloads/],
        [{state=>'failed',code=>'youtube_paused'}, qr/existing catalogue tracks remain available/],
        [{state=>'failed',code=>'youtube_no_data'}, qr/no audio data/],
        [{state=>'failed',code=>'duplicate_track'}, qr/already requested/],
        [{state=>'failed',code=>'storage_full'}, qr/Insufficient radio storage/],
    ) {
        Mediabot::Radio::Public::submit($ctx,'rplay');
        $worker{on_done}->({value=>$case->[0],ok=>1});
        like($bot->{notices}[-1],$case->[1],'specific private error, no invented two-minute queue delay');
    }
    $ctx->{channel}='Guest';
    ok(!Mediabot::Radio::Public::enabled($ctx),'private message never enables public mode');
}
{
    no warnings 'redefine';
    local *Mediabot::AsyncWorker::start=sub { shift; %worker=@_; return bless({},'WorkerFixture') };
    local *Mediabot::Radio::Public::call_api=sub {
        my ($url,$token,$method,$route,$body)=@_; push @calls,[$method,$route,$body];
        return {protocol=>1,waiting=>[{title=>'Artist — Track'}],total=>1,preparing=>2,transferring=>0};
    };
    my $now=100;
    local *Mediabot::Radio::Public::queue_now=sub {$now};
    $ctx->{channel}='#radio';$ctx->{args}=[];@calls=();$bot->{notices}=[];
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),'guest reads common queue');
    is(scalar @calls,0,'queue HTTP stays outside IRC parent');
    is($worker{timeout},10,'short bounded worker');
    my $r=$worker{child}->();
    is_deeply($calls[0],['GET','/v1/queue',undef],'read-only shared route, no SQL, filesystem or caller query');
    $worker{on_done}->({value=>$r,ok=>1});
    like($bot->{notices}[0],qr/1 waiting.*preparing: 2/,'waiting and preparing are separate');
    like($bot->{notices}[1],qr/Artist — Track/,'pending title in private notice');
    unlike(join(' ',@{$bot->{notices}}),qr/playing.*Artist/,'waiting title never claims current playback');
    ok(!$bot->{_radio_queue_pending},'read worker released');
    is(Mediabot::Radio::Public::inspect_queue($ctx,'nextsong'),undef,'shared five-second consultation cooldown');
    is(Mediabot::Radio::Public::inspect_queue($ctx,'queue'),undef,'alias shares radioqueue cooldown');
    $now+=6;
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'queue'),'queue alias uses the common HTTP view');
    my $alias_result=$worker{child}->();
    $worker{on_done}->({value=>$alias_result,ok=>1});
    like($bot->{notices}[-2],qr/Artist — Track/,'queue alias includes pending titles by NOTICE');
    $now+=6;
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'nextsong'),'nextsong after cooldown');
    $worker{on_done}->({value=>$r,ok=>1});
    like($bot->{notices}[-2],qr/next waiting request — Artist/,'next means waiting request');
    like($bot->{notices}[-1],qr/Live input keeps priority/,'no invented airtime or automatic skip');
    for my $change ('disconnect','disabled','part') {
        $now+=6;Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
        my $n=@{$bot->{notices}};
        if ($change eq 'disconnect') {$state->mark_disconnected;$state->mark_connected;$state->mark_joined('#radio')}
        elsif ($change eq 'disabled') {$bot->{radio_on}=0}
        else {$bot->{hChannelsNicks}{'#Radio'}=['bot']}
        $worker{on_done}->({value=>$r,ok=>1});
        is(scalar(@{$bot->{notices}}),$n,'late queue reply suppressed: '.$change);
        $bot->{radio_on}=1;$bot->{hChannelsNicks}{'#Radio'}=['bot','Guest'];
    }
    $now+=6;Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
    $worker{on_done}->({ok=>0});
    like($bot->{notices}[-1],qr/shared queue unavailable/,'failed HTTP is never an empty queue');
    $ctx->{nick}='Outsider';$now+=6;
    is(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),undef,'outsider cannot inspect');
    $ctx->{nick}='Guest';$ctx->{channel}='Guest';
    is(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),undef,'public queue requires channel membership');
    $ctx->{channel}='#radio';
    local *Mediabot::AsyncWorker::start=sub {die 'worker unavailable'};
    Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
    ok(!$bot->{_radio_queue_pending},'failed worker start does not permanently lock reads');
}
{
    my $r={protocol=>1,waiting=>[],total=>0,preparing=>1,transferring=>0};
    like(Mediabot::Radio::Public::queue_lines($r,'nextsong')->[0][1],qr/0 waiting.*preparing: 1/,'empty actual queue can coexist with preparation');
    for my $bad ({%$r,total=>1},{%$r,waiting=>'oops'},{%$r,error=>'unavailable'},{%$r,protocol=>2}) {
        ok(!Mediabot::Radio::Public::queue_lines($bad,'radioqueue'),'malformed queue does not invent a title');
    }
    $r->{waiting}=[{title=>"\x03A\nB\x{202e}"}];$r->{total}=1;
    unlike(Mediabot::Radio::Public::queue_lines($r,'radioqueue')->[1][1],qr/[\x03\n\x{202e}]/,'IRC controls and bidi removed');
    $r->{waiting}=[{title=>''}];
    like(Mediabot::Radio::Public::queue_lines($r,'nextsong')->[0][1],qr/title unavailable/,'unresolved request remains visible without a private path');
}
{
    # Exercise the real dispatcher body without loading a live bot or DB.
    open my $source,'<','Mediabot/Mediabot.pm' or die $!;
    local $/;my $text=<$source>;close $source;
    my ($dispatch)=$text =~ /^(sub _dispatch_radio \{.*?^\})/ms;
    ok($dispatch && eval('package MB734Router; '.$dispatch.'; 1'),'actual radio dispatcher compiles in fixture');
    no warnings qw(redefine once);
    my (@routed,@local);
    my $radio_enabled=1;
    local *Mediabot::Radio::Public::inspect_queue=sub {push @routed,$_[1];1};
    local *Mediabot::Radio::Public::enabled=sub {$radio_enabled};
    local *MB734Router::radioQueue_ctx=sub {push @local,'radioqueue'};
    local *MB734Router::radioNext_ctx=sub {push @local,'nextsong'};
    MB734Router::_dispatch_radio($ctx,$_) for qw(radioqueue nextsong queue);
    is_deeply(\@routed,[qw(radioqueue nextsong queue)],'all shared commands route to HTTP on +Radio');
    is_deeply(\@local,[],'remote radio channel never touches local Liquidsoap');
    {
        local *Mediabot::Radio::Public::inspect_queue=sub {return};
        MB734Router::_dispatch_radio($ctx,$_) for qw(radioqueue nextsong queue);
        is_deeply(\@local,[],'HTTP refusal never falls back to local player controls');
    }
    $radio_enabled=0;
    MB734Router::_dispatch_radio($ctx,'queue');
    is_deeply(\@local,[],'queue alias has no administrative meaning outside +Radio');
    MB734Router::_dispatch_radio($ctx,$_) for qw(radioqueue nextsong);
    is_deeply(\@local,[qw(radioqueue nextsong)],'historical local Master controls retained outside +Radio');
}
done_testing;
