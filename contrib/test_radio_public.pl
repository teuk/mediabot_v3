use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use Encode qw(encode_utf8);
BEGIN {
    $INC{'Mediabot/Helpers.pm'}=__FILE__;
    package Mediabot::Helpers;
    sub chanset_enabled { return $_[0]{radio_on} }
    sub channel_lang { $_[0]{test_lang}//'en' }
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
    sub botPrivmsg { push @{$_[0]{public}},[$_[1],$_[2]] }
    sub getLoop { $_[0]{loop} }
    sub get_user_from_message { die 'Guest must not need a database account' }
}
my $dir=tempdir(CLEANUP=>1);
my $path="$dir/token";
open my $fh,'>',$path or die $!; print {$fh} 'a'x64; close $fh; chmod 0600,$path;
my $state=Mediabot::AI::ConversationRuntimeState->new;
$state->mark_connected; $state->mark_joined('#radio');
my $bot=bless {radio_on=>1,notices=>[],public=>[],loop=>bless({},'LoopFixture'),
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
        return {state=>'queued',title=>'Artist - Track',rid=>42,placement=>'waiting',position=>3};
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
    like($bot->{public}[-1][1],qr/QUEUE #3.*Artist - Track/,'success reports the confirmed rank in one themed channel message');
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
        return {protocol=>1,waiting=>[map {{title=>"Artist $_ — Track $_"}} 1..5],total=>5,preparing=>2,transferring=>0};
    };
    my $current_calls=0;
    local *Mediabot::Radio::Public::current_title=sub {$current_calls++;'Actual artist - Current song'};
    my $now=100;
    local *Mediabot::Radio::Public::queue_now=sub {$now};
    delete $bot->{$_} for qw(_radio_display_until _radio_consult_until _radio_consult_global _radio_queue_cache _radio_queue_until);
    $ctx->{channel}='#radio';$ctx->{args}=[];@calls=();$bot->{notices}=[];$bot->{public}=[];
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),'guest reads common queue');
    is(scalar @calls,0,'queue HTTP stays outside IRC parent');
    is($current_calls,0,'Icecast also stays outside IRC parent');
    is($worker{timeout},12,'worker bounded for API plus public status');
    my $r=$worker{child}->();
    is_deeply($calls[0],['GET','/v1/queue',undef],'read-only shared route, no SQL, path or caller query');
    $worker{on_done}->({value=>$r,ok=>1});
    is(scalar @{$bot->{public}},1,'one public line for initial queue');
    my $line=$bot->{public}[0][1];
    like($line,qr/ON AIR.*Actual artist - Current song/,'current title comes from Icecast');
    like($line,qr/Artist 1 - Track 1.*Artist 2 - Track 2.*Artist 3 - Track 3/,'first three ordered titles');
    unlike($line,qr/Artist [45]/,'fourth and later title omitted');
    like($line,qr/\+2/,'remaining count shown');
    like($line,qr/preparing: 2/,'preparation does not pretend to be in the waiting queue');
    is(scalar @{$bot->{notices}},0,'public queue is not duplicated by notice');
    ok(!$bot->{_radio_queue_pending},'read worker released');
    is(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),undef,'five-second caller cooldown across aliases');
    is(Mediabot::Radio::Public::inspect_queue($ctx,'queue'),undef,'same caller cannot trigger a notice flood');
    $now+=2;
    $ctx->{nick}='Guest2';$ctx->{message}{prefix}='Guest2!different@example.test';
    push @{$bot->{hChannelsNicks}{'#Radio'}},'Guest2';
    my $calls_before=@calls;
    Mediabot::Radio::Public::inspect_queue($ctx,'queue');
    is(scalar @calls,$calls_before,'burst consultation uses short cache without HTTP');
    like($bot->{notices}[-1],qr/Current song.*Artist 1/,'second caller gets the compact view privately');
    is(scalar @{$bot->{public}},1,'second caller cannot bypass channel budget');
    $ctx->{nick}='Guest';$ctx->{message}{prefix}='Guest!ident@example.test';
    $now=106;
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'queue'),'alias can refresh after five seconds');
    my $alias_result=$worker{child}->();$worker{on_done}->({value=>$alias_result,ok=>1});
    is(scalar @{$bot->{public}},1,'alias shares the minute-long public budget');
    like($bot->{notices}[-1],qr/Artist 3/,'private fallback still contains three next titles');
    $now=120;
    ok(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),'queue refresh after cooldown');
    $worker{on_done}->({value=>$r,ok=>1});
    like($bot->{notices}[-1],qr/Artist 1/,'queue refresh stays private within the public budget');
    is(scalar @{$bot->{public}},1,'queue refresh does not add public traffic');
    $now=160;
    Mediabot::Radio::Public::inspect_queue($ctx,'queue');$worker{on_done}->({value=>$r,ok=>1});
    is(scalar @{$bot->{public}},2,'a fresh public queue is allowed at sixty seconds');
    for my $change ('disconnect','disabled','part') {
        $now+=61;Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
        my ($n,$p)=(scalar @{$bot->{notices}},scalar @{$bot->{public}});
        if ($change eq 'disconnect') {$state->mark_disconnected;$state->mark_connected;$state->mark_joined('#radio')}
        elsif ($change eq 'disabled') {$bot->{radio_on}=0}
        else {$bot->{hChannelsNicks}{'#Radio'}=['bot']}
        $worker{on_done}->({value=>$r,ok=>1});
        is_deeply([scalar @{$bot->{notices}},scalar @{$bot->{public}}],[$n,$p],'no late public/private reply: '.$change);
        $bot->{radio_on}=1;$bot->{hChannelsNicks}{'#Radio'}=['bot','Guest'];
    }
    $now+=61;Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
    my $n=@{$bot->{public}};$worker{on_done}->({ok=>0});
    like($bot->{notices}[-1],qr/shared queue unavailable/,'failed HTTP is never an empty queue');
    is(scalar @{$bot->{public}},$n,'failures stay private');
    ok(!exists($bot->{_radio_queue_cache}),'failed read invalidates old cache');
    $ctx->{nick}='Outsider';$now+=6;
    is(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),undef,'outsider cannot inspect');
    $ctx->{nick}='Guest';$ctx->{channel}='Guest';
    is(Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue'),undef,'queue still requires channel membership');
    $ctx->{channel}='#radio';
    local *Mediabot::AsyncWorker::start=sub {die 'worker unavailable'};
    Mediabot::Radio::Public::inspect_queue($ctx,'radioqueue');
    ok(!$bot->{_radio_queue_pending},'failed worker start releases reads');
}
{
    my $r={protocol=>1,waiting=>[],total=>0,preparing=>1,transferring=>0};
    like(Mediabot::Radio::Public::queue_lines($r,'queue')->[0][1],qr/queue empty.*preparing: 1/,'empty queue and preparation distinguished');
    like(Mediabot::Radio::Public::queue_lines($r,'queue')->[0][1],qr/ON AIR.*title unavailable/,'missing Icecast title is explicit');
    for my $bad ({%$r,total=>1},{%$r,waiting=>'oops'},{%$r,error=>'unavailable'},{%$r,protocol=>2}) {
        ok(!Mediabot::Radio::Public::queue_lines($bad,'radioqueue'),'malformed queue does not invent a title');
    }
    $r->{waiting}=[{title=>"X\x03A\nB\x{202e}Y"}];$r->{total}=1;
    my $line=Mediabot::Radio::Public::queue_lines($r,'queue')->[0][1];
    unlike($line,qr/\n|\x{202e}|X\x03/,'untrusted IRC controls and bidi removed');
    like($line,qr/\x0307\x02\[/,'orange bracket accents match song');
    like($line,qr/\x0307\x02\[ \x0F\x021\x0307 /,'waiting rank uses the native foreground on light/dark themes');
    like($line,qr/\x0FX A B Y\x0F/,'title inherits the client theme and safely resets formatting');
    $r->{waiting}=[{title=>''}];
    like(Mediabot::Radio::Public::queue_lines($r,'nextsong')->[0][1],qr/title unavailable/,'unresolved title never exposes a path');
    $r->{on_air}='🦉東京'x200;$r->{waiting}=[map {{title=>'🪄Björk 東京'x200}} 1..6];$r->{total}=512;
    for my $command (qw(queue radioqueue nextsong)) {
        my $pairs=Mediabot::Radio::Public::queue_lines($r,$command);
        is(scalar @$pairs,1,'one compact line per consultation');
        ok(length(encode_utf8($_))<=360,'IRC byte limit including color codes and Unicode') for @{$pairs->[0]};
    }
    for my $placement (['waiting',2,qr/FILE #2/],['not_waiting',undef,qr/plus en attente/],['unknown',undef,qr/rang non confirmé/],['waiting',0,qr/rang non confirmé/]) {
        my $line=Mediabot::Radio::Public::queued_line({title=>'Michael Jackson — Billie Jean',placement=>$placement->[0],position=>$placement->[1]},'fr');
        like($line,$placement->[2],'truthful placement after acknowledged push');
        like($line,qr/Michael Jackson - Billie Jean/,'artist/song separator matches song');
        unlike($line,qr/antenne/,'queue receipt never asserts playback');
    }
}
{
    no warnings qw(redefine once);
    my (@urls,$options);
    my $response={success=>1,content=>encode_json({icestats=>{source=>[
        {listenurl=>'http://local:15000/other.mp3',title=>'Do not use'},
        {listenurl=>'http://local:8000/radio.mp3',artist=>'Paul Simon',title=>'You Can Call Me Al'}]}})};
    local *HTTP::Tiny::new=sub {shift;$options={@_};bless({},'MB734StatusHTTP')};
    local *MB734StatusHTTP::get=sub {push @urls,[@_[1..$#_]];$response};
    $bot->{conf}{'radio.RADIO_ICECAST_STATUS_BASE_URL'}='https://example.test/radio';
    is(Mediabot::Radio::Public::current_title($bot),'Paul Simon - You Can Call Me Al','exact Icecast mount supplies artist/title');
    is_deeply(\@urls,[['https://example.test/radio/status-json.xsl']],'public status receives no bearer or request fields');
    is_deeply([@{$options}{qw(timeout verify_SSL max_redirect max_size)}],[2,1,0,262144],'status request bound and TLS checked');
    for my $bad ({success=>0},{success=>1,content=>'invalid'},
        {success=>1,content=>encode_json({icestats=>{source=>{listenurl=>'http://local/other.mp3',title=>'Wrong'}}})}) {
        $response=$bad;
        is(Mediabot::Radio::Public::current_title($bot),undef,'unavailable status or missing configured mount stays unknown');
    }
}
{
    no warnings 'redefine';
    local *Mediabot::AsyncWorker::start=sub {shift;%worker=@_;bless({},'WorkerFixture')};
    my $now=1000;
    local *Mediabot::Radio::Public::queue_now=sub {$now};
    $bot->{public}=[];$bot->{notices}=[];delete $bot->{_radio_display_until};
    $ctx->{args}=['Artist'];$ctx->{channel}='#radio';
    for my $step (0,6,16) {
        $now=1000+$step;
        Mediabot::Radio::Public::submit($ctx,'rplay');
        $worker{on_progress}->({});
        like($bot->{notices}[-1],qr/request received/,'preparation stays private');
        $worker{on_done}->({value=>{state=>'queued',title=>'Artist — Track',placement=>'waiting',position=>1}});
    }
    is(scalar @{$bot->{public}},2,'success announcements share fifteen-second public spacing');
    like(join(' ',@{$bot->{notices}}),qr/QUEUE #1/,'success during public gap is still confirmed privately');
    my $line=Mediabot::Radio::Public::queue_lines({protocol=>1,total=>0,waiting=>[],preparing=>0,transferring=>0,on_air=>'Actual'},'queue')->[0][1];
    Mediabot::Radio::Public::public_or_notice($ctx,$line,'queue',0);
    is(scalar @{$bot->{public}},2,'queue respects gap following an addition');
    $now+=15;Mediabot::Radio::Public::public_or_notice($ctx,$line,'queue',0);
    is(scalar @{$bot->{public}},3,'queue can speak after the shared gap');
    $ctx->{args}=[];$bot->{test_lang}='fr';
    my $fr=Mediabot::Radio::Public::queue_lines({protocol=>1,total=>0,waiting=>[],preparing=>0,transferring=>0,on_air=>'Actual'},'queue')->[0][0];
    like($fr,qr/ANTENNE.*file vide/,'French presentation available');
    delete $bot->{test_lang};
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
{
    package MB734User;
    sub is_authenticated { $_[0]{auth} }
    sub has_level { $_[1] eq 'Administrator' ? $_[0]{level} <= 2 : $_[1] eq 'Master' && $_[0]{level} <= 1 }
}
{
    no warnings 'redefine';
    my $now=1000;
    local *Mediabot::Radio::Public::queue_now=sub {$now};
    my $user;
    local *MB734Bot::get_user_from_message=sub {$user};
    local *Mediabot::AsyncWorker::start=sub { shift; %worker=@_; return bless({},'WorkerFixture') };
    local *Mediabot::Radio::Public::call_api=sub {
        my ($url,$token,$method,$route,$body)=@_;push @calls,[$method,$route,$body];
        return {state=>'completed',title=>'Requested - Song',origin=>'queue'};
    };
    $bot->{radio_on}=1;$bot->{irc}{connected}=1;
    $bot->{hChannelsNicks}{'#Radio'}=['bot','Guest'];
    $state->mark_connected;$state->mark_joined('#radio');
    for my $level (undef,3,2,1,0) {
        $now+=70;@calls=();%worker=();
        $user=defined($level) ? bless({auth=>1,level=>$level},'MB734User') : undef;
        my $adminctx=Mediabot::Context->new(bot=>$bot,channel=>'#radio',nick=>'Guest',args=>[],
            message=>bless({prefix=>'Guest!ident@example.test'},'MB734Message'));
        my $ok=Mediabot::Radio::Public::inspect_queue($adminctx,'nextsong');
        if (!defined($level) || $level>2) {
            ok(!$ok && !%worker,'guest/User cannot start a nextsong worker');
            is(scalar @calls,0,'denial precedes HTTP');
            next;
        }
        ok($ok,'Administrator, Master and Owner can advance the radio');
        is(scalar @calls,0,'admin HTTP stays outside the IRC parent');
        my $result=$worker{child}->();
        is_deeply([@{$calls[0]}[0,1]],['POST','/v1/next'],'actual skip is a central POST');
        is_deeply([sort keys %{$calls[0][2]}],[qw(caller channel id)],'no user-supplied rank, role or local source');
        $worker{on_done}->({value=>$result,ok=>1});
        like($bot->{public}[-1][1],qr/Next · queue.*Requested - Song/,'announces the confirmed new queue track');
    }
    $now+=70;@calls=();
    $user=bless({auth=>0,level=>0},'MB734User');
    my $adminctx=Mediabot::Context->new(bot=>$bot,channel=>'#radio',nick=>'Guest',args=>[],
        message=>bless({prefix=>'Guest!ident@example.test'},'MB734Message'));
    ok(!Mediabot::Radio::Public::next_song($adminctx),'an unauthenticated Owner is refused');
    $user->{auth}=1;
    local *Mediabot::Radio::Public::call_api=sub {push @calls,['POST'];return {error=>'api_unavailable'}};
    Mediabot::Radio::Public::next_song($adminctx);
    my $result=$worker{child}->();
    is(scalar @calls,1,'lost HTTP acknowledgement never sends a second skip');
    my $public=scalar @{$bot->{public}};
    $worker{on_done}->({value=>$result,ok=>1});
    is(scalar @{$bot->{public}},$public,'ambiguous skip is never announced as success');
    like($bot->{notices}[-1],qr/not confirmed/,'uncertainty is private and explicit');
    $now+=70;Mediabot::Radio::Public::next_song($adminctx);
    $user->{level}=3;
    my $notices=scalar @{$bot->{notices}};
    $worker{on_done}->({value=>{state=>'completed',title=>'Track',origin=>'playlist'}});
    is_deeply([scalar @{$bot->{public}},scalar @{$bot->{notices}}],[$public,$notices],
        'rights revoked during work suppress privileged completion feedback');
}


{
    no warnings 'redefine';
    my $now=5000;
    my $user;
    local *Mediabot::Radio::Public::queue_now=sub {$now};
    local *MB734Bot::get_user_from_message=sub {$user};
    local *Mediabot::AsyncWorker::start=sub {shift;%worker=@_;bless({},'WorkerFixture')};
    local *Mediabot::Radio::Public::call_api=sub {
        my($url,$token,$method,$route,$body)=@_;push @calls,[$method,$route,$body];
        return {state=>'removed',mp3=>'28',title=>'Artist - Track'};
    };
    for my $level (undef,3,2,1,0) {
        $now+=70;@calls=();%worker=();
        $user=defined($level)?bless({auth=>1,level=>$level},'MB734User'):undef;
        my $masterctx=Mediabot::Context->new(bot=>$bot,channel=>'#radio',nick=>'Guest',args=>['28'],
            message=>bless({prefix=>'Guest!ident@example.test'},'MB734Message'));
        my $ok=Mediabot::Radio::Public::delete_track($masterctx);
        if (!defined($level)||$level>1) {
            ok(!$ok && !%worker,'guest, User and Administrator cannot delete a central track');
            is(scalar @calls,0,'Master denial precedes network');next;
        }
        ok($ok,'authenticated Master/Owner starts central withdrawal');
        is(scalar @calls,0,'deletion runs outside IRC parent');
        my $result=$worker{child}->();
        is_deeply([@{$calls[0]}[0,1]],['POST','/v1/tracks/remove'],'deletion uses central HTTP, no local DB or telnet');
        is_deeply([sort keys %{$calls[0][2]}],[qw(caller channel id mp3)],'only central numeric ID and request context sent');
        is($calls[0][2]{mp3},'28','central id_mp3 remains independent of local user IDs');
        my $count=scalar @{$bot->{public}};
        $worker{on_done}->({value=>$result});
        is(scalar @{$bot->{public}},$count,'withdrawal feedback is always private');
        like($bot->{notices}[-1],qr/MP3 #28 removed and blocked.*Artist - Track/,'private result identifies withdrawn track');
    }
    $user=bless({auth=>0,level=>0},'MB734User');
    my $masterctx=Mediabot::Context->new(bot=>$bot,channel=>'#radio',nick=>'Guest',args=>['28'],
        message=>bless({prefix=>'Guest!ident@example.test'},'MB734Message'));
    ok(!Mediabot::Radio::Public::delete_track($masterctx),'unauthenticated Owner cannot delete');
    $user->{auth}=1;
    for my $args ([],['-1'],['0'],['28','29'],['28;delete'],['028']) {
        $now+=70;%worker=();$masterctx->{args}=$args;
        ok(!Mediabot::Radio::Public::delete_track($masterctx) && !%worker,'invalid central ID has no worker');
    }
    $now+=70;$masterctx->{args}=['28'];
    Mediabot::Radio::Public::delete_track($masterctx);
    my $count=scalar @{$bot->{notices}};
    $user->{level}=2;
    $worker{on_done}->({value=>{state=>'removed',mp3=>'28',title=>'Track'}});
    is(scalar @{$bot->{notices}},$count,'revoked Master privileges suppress deletion feedback');
}

{
    my $line=Mediabot::Radio::Public::queued_line({title=>'Artist - Song',placement=>'waiting',position=>2,mp3=>'28'},'fr');
    like($line,qr/FILE #2.*Artist - Song.*MP3 #28/,'new addition identifies the central row for deltrack');
    unlike(Mediabot::Radio::Public::queued_line({title=>'Song',mp3=>"28\nSECRET"},'fr'),qr/SECRET|MP3/,'invalid row IDs never reach IRC');
}
{
    my $r={title=>'Stevie Wonder — Superstition',placement=>'waiting',position=>1,mp3=>'37',
           duration_seconds=>241,youtube_url=>'https://youtu.be/ftdZ363R9kQ'};
    for my $lang (qw(fr en)) {
        my $line=Mediabot::Radio::Public::queued_line($r,$lang);
        like($line,qr/\x0304\x02\[ \+ (?:FILE|QUEUE) #1 \]/,'compact red success label');
        like($line,qr/\x0F\x02Stevie Wonder - Superstition\x0F/,'title is bold in the client foreground');
        like($line,qr/4:01.*MP3 #37.*https:\/\/youtu\.be\/ftdZ363R9kQ/,'duration, central ID and selected replay URL');
        unlike($line,qr/\x03\d\d,|\x0314|\x0302|Radio \+|ajout confirmé/,'no background, forced grey/blue or long old heading');
        like($line,qr/\x1Fhttps:\/\/youtu\.be\/ftdZ363R9kQ\x0F/,'link stays clickable and uses a reset');
        for my $title ('é'x1000,'🪄東京'x1000,"\x0301,00bad\n\x{202e}"x100) {
            my $long=Mediabot::Radio::Public::queued_line({%$r,title=>$title,mp3=>'9'x19},$lang);
            ok(length(encode_utf8($long))<=360,'one bounded UTF-8 line including details');
            like($long,qr{https://youtu\.be/ftdZ363R9kQ},'long title never truncates replay URL');
            unlike($long,qr/\n|\x{202e}|\x03\d\d,/,'untrusted text cannot inject formatting or new lines');
        }
    }
    for my $url ('https://evil.invalid/abcdefghijk',"https://youtu.be/abcdefghijk\n",'http://youtu.be/abcdefghijk', ['bad']) {
        my $line=Mediabot::Radio::Public::queued_line({%$r,youtube_url=>$url},'en');
        unlike($line,qr{https?://},'untrusted/malformed replay URL is omitted');
    }
    for my $duration (-1,0,3601,'241s',{},undef) {
        my $line=Mediabot::Radio::Public::queued_line({%$r,duration_seconds=>$duration},'en');
        unlike($line,qr/4:01|60:01|241s|HASH/,'invalid duration is omitted');
        like($line,qr{https://youtu\.be/ftdZ363R9kQ},'optional detail failure keeps replay link');
    }
    my $line=Mediabot::Radio::Public::queued_line({title=>'Archive song',placement=>'unknown'},'en');
    like($line,qr/position unconfirmed.*Archive song/,'old API keeps a useful confirmation');
    unlike($line,qr{https?://|MP3|\d:\d\d},'missing details are not invented');
}
done_testing;
