use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use FindBin qw($Bin);
use Mediabot::External::TikTok ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);
no warnings qw(redefine once);
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my $p='Mediabot::External::TikTok';
sub call {my $f=shift; $p->can($f)->(@_)}
my $url='https://www.tiktok.com/@ramish.art/video/7684738550595652885';
my $info=call('url_info',$url);
for my $u ($url,$url.'?is_from_webapp=1&sender_device=pc#x',
    'http://tiktok.com/@ramish.art/video/7684738550595652885/',
    'https://m.tiktok.com/@ramish.art/video/7684738550595652885',
    'https://www.tiktok.com.:443/@ramish.art/video/7684738550595652885') {
    is_deeply(call('url_info',$u),$info,'post identity drops tracking and normalizes public aliases');
}
for my $pair (["https://vm.tiktok.com/ZM123/",'short'],["https://vt.tiktok.com/ZS123/",'short'],
    ['https://www.tiktok.com/t/Z123/','short'],['https://www.tiktok.com/@artist/photo/123','photo'],
    ['https://www.tiktok.com/@artist','profile'],['https://www.tiktok.com/@artist/live','live'],
    ['https://www.tiktok.com/player/v1/123','video'],['https://www.tiktok.com/embed/v2/123','video'],
    ['https://www.tiktok.com/share/video/123','video'],['https://m.tiktok.com/v/123.html','video'],['https://www.tiktok.com/%40artist/video/123','video'],
    ['https://www.tiktok.com/tag/art','link'],['https://www.tiktok.com/music/sound-123','link']) {
    is(call('url_info',$pair->[0])->{kind},$pair->[1],'public URL variant classified');
}
for my $bad (undef,[],"$url\n",'https://tiktok.com.evil/@a/video/1','https://eviltiktok.com/',
    'file://tiktok.com/@a/video/1','https://user:pass@tiktok.com/@a/video/1',
    'https://tiktok.com:bad/@a/video/1','https://tiktok.com:444/@a/video/1',
    'https://example.org/?url='.$url,'https://localhost/','https://tiktok.com\\@localhost/',
    'https://ads.tiktok.com/','https://vm.tiktok.com/a/b') {
    ok(!defined(call('url_info',$bad)),'unsafe or non-public preview URL rejected');
}
for my $generic ('TikTok - Make Your Day','TikTok','Make Your Day','Log in | TikTok',
    'Watch and discover millions of videos','Verify to continue') {
    ok(!defined(call('caption',$generic)),'generic shell caption suppressed');
}
is(call('plain',"Caf&eacute; &amp; thé\n\x0304rouge\x0f\x{202e} test"),'Café & thé rouge test','entities, UTF-8 and IRC controls sanitized');
is(call('caption',[]),undef,'structured caption refused');
my $item={id=>$info->{id},desc=>'Un château 🏰 &amp; des chevaliers',author=>{uniqueId=>'ramish.art',nickname=>'Artramish'},
    video=>{duration=>16},stats=>{playCount=>298600,diggCount=>33200}};
sub html { '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">'.JSON::PP->new->encode({__DEFAULT_SCOPE__=>{'webapp.video-detail'=>{itemInfo=>{itemStruct=>$_[0]}}}}).'</script>' }
my $rich=call('parse_html',html($item),$info);
is($rich->{caption},'Un château 🏰 & des chevaliers','hydration caption decoded');
is($rich->{owner},'@ramish.art','verified post author');
is_deeply([@{$rich}{qw(seconds views likes)}],[16,298600,33200],'duration and statistics retained');
my $wrong={%$item,id=>'123',desc=>'WRONG VIDEO'};
ok(!defined(call('parse_html',html($wrong),$info)->{caption}),'recommendation with different id ignored');
my $sigi='<script id="SIGI_STATE">'.JSON::PP->new->encode({ItemModule=>{$info->{id}=>$item}}).'</script>';
is_deeply(call('parse_html',$sigi,$info),$rich,'legacy SIGI data supported');
my $photo={%$item,imagePost=>{images=>[]}};
is(call('parse_html',html($photo),$info)->{kind},'photo','photo album marker retained');
my $meta=q{<meta content="A &quot;nice&quot; clip" property="og:description"><meta name='og:title' content='TikTok - Make Your Day'>};
is(call('parse_html',$meta,$info)->{caption},'A "nice" clip','HTML metadata handles attribute order and entities');
is_deeply(call('parse_html','<script id="SIGI_STATE">{broken</script>',$info),{},'broken JSON harmless');
is_deeply(call('parse_html','x' x (1024*1024+1),$info),{},'oversized document refused');
my $profile=call('url_info','https://www.tiktok.com/@artist');
my $profile_html='<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">'.JSON::PP->new->encode({__DEFAULT_SCOPE__=>{'webapp.user-detail'=>{userInfo=>{user=>{uniqueId=>'artist',nickname=>'Artist',signature=>'Art &amp; music'},stats=>{followerCount=>1234}}}}}).'</script>';
is(call('parse_html',$profile_html,$profile)->{caption},'Art & music','profile biography');
is(call('parse_html',$profile_html,$profile)->{followers},1234,'profile followers');
is_deeply(call('parse_html',$profile_html,{%$profile,owner=>'@other'}),{},'other profile ignored');
my $old_oembed=JSON::PP->new->encode({title=>'An older embed',author_name=>'Artist',author_url=>'https://www.tiktok.com/@artist'});
is(call('parse_oembed',$old_oembed,$info)->{caption},'An older embed','traditional oEmbed metadata supported');
my $new_oembed=JSON::PP->new->encode({embed_product_id=>$info->{id},html=>'<iframe></iframe>'});
ok(!defined(call('parse_oembed',$new_oembed,$info)->{caption}),'iframe-only response never treated as caption');
is_deeply(call('parse_oembed','{"embed_product_id":"999","title":"wrong"}',$info),{},'mismatched embed refused');
my $huge=call('parse_oembed',JSON::PP->new->encode({title=>'🏰'x4000,author_name=>'é'x4000}),$info);
cmp_ok(length(JSON::PP::encode_json($huge)),'<',8192,'oversized metadata shrunk before worker serialization');
my $line=call('render','Vincent',$info,$rich);
like($line,qr/\[TikTok\].*\@ramish\.art.*Artramish.*château.*0:16.*298\.6k.*33\.2k/,'compact rich presentation');
unlike($line,qr/Make Your Day/,'no generic landing title');
my $fallback=call('render','Vincent',$info,{});
like($fallback,qr/\@ramish\.art.*aperçu indisponible/,'honest author-aware fallback');
for my $n (1,100,1000) {
    my $s=call('render','N'x100,$info,{%$rich,author=>'é'x100,caption=>'🏰'x$n});
    cmp_ok(_irc_wire_bytes($s),'<=',400,'UTF-8 output stays within 400-byte envelope');
    like($s,qr/\x0f\z/,'formatting reset at end');
}
{
    package MB1195::HTTP;
    sub get {my($s,$u)=@_;push @{$s->{calls}},$u;my $r=shift @{$s->{responses}};die 'simulated network failure' if !defined $r;return $r}
    package MB1195::Bot; sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit}//0}
    package MB1195::Loop; sub add {1} sub remove {1} sub watch_process {1}
    package MB1195::IRC; sub is_connected {1}
    package MB1195::Runtime; sub capture_generation {$_[0]{generation}}
}
sub fetch_fixture {
    my($u,@responses)=@_;
    my $http=bless {calls=>[],responses=>\@responses},'MB1195::HTTP';
    local *Mediabot::External::TikTok::_http=sub {$http};
    return [call('fetch',$u),$http->{calls}];
}
my $ok={success=>1,status=>200,content=>html($item)};
my $f=fetch_fixture($url,$ok);
is($f->[0]{caption},$rich->{caption},'fetch uses real parser');
is(scalar @{$f->[1]},1,'rich page needs only one request');
$f=fetch_fixture('https://vm.tiktok.com/Z123/',{status=>302,headers=>{location=>$url.'?tracking=1'}},$ok);
is($f->[0]{caption},$rich->{caption},'short link resolved to rich video');
is_deeply($f->[1],['https://vm.tiktok.com/Z123/',$url],'redirect tracking stripped');
$f=fetch_fixture($url,{success=>0,status=>403},{success=>1,content=>$old_oembed});
is($f->[0]{caption},'An older embed','oEmbed fallback after page refusal');
like($f->[1][1],qr{\Ahttps://www.tiktok.com/oembed\?url=https%3A},'fixed oEmbed endpoint, encoded URL');
for my $bad ('http://127.0.0.1/','https://example.org/','https://tiktok.com.evil/','https://user@www.tiktok.com/') {
    $f=fetch_fixture('https://vm.tiktok.com/Z123/',{status=>302,headers=>{location=>$bad}});
    is(scalar @{$f->[1]},1,'unsafe redirect never requested');
}
$f=fetch_fixture('https://vm.tiktok.com/Z123/',{status=>302,headers=>{location=>'/Z123/'}});
is(scalar @{$f->[1]},1,'redirect loop bounded');
$f=fetch_fixture($url,undef,undef);
ok(!$f->[0]{caption},'network exceptions produce honest fallback');
# Deterministic worker adapter: exercise parent lifecycle, not network or timers.
sub bot {bless {loop=>bless({},'MB1195::Loop'),irc=>bless({},'MB1195::IRC'),on=>1,
    wit_runtime_state=>bless({generation=>1},'MB1195::Runtime')},'MB1195::Bot'}
my (@jobs,@sent);
my $real_start=Mediabot::AsyncWorker->can('start');
local *Mediabot::External::TikTok::enabled=sub {$_[0]{on}};
local *Mediabot::AsyncWorker::start=sub {my($class,%a)=@_;push @jobs,\%a;bless {},'MB1195::Worker'};
local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[@_[1..3]];1};
# The production Helpers module is intentionally not loaded: transport is a test seam.
local $INC{'Mediabot/Helpers.pm'}=__FILE__;
sub handle {call('handle',$_[0],undef,$_[2]//'Vincent',$_[1]//'#test',$_[3]//$url)}
my $b=bot();
ok(handle($b),'worker admitted');
is(scalar @jobs,1,'one worker');is(scalar @sent,0,'no premature output');
handle($b);is(scalar @jobs,1,'duplicate same channel suppressed');
handle($b,'#other','Other');is(scalar @jobs,1,'other channel shares pending fetch');
is(scalar @{$b->{_tiktok_preview}{pending}{$info->{key}}{send}},2,'both recipients retained');
$jobs[0]{on_done}->({ok=>1,value=>$rich});
is(scalar @sent,2,'both channels get completion');
like($sent[1][1],qr/^\(Other\)/,'recipient nick never cached');
is_deeply($sent[0][2],{no_defer=>1},'preview obeys bounded nondeferred delivery');
$jobs[0]{on_done}->({ok=>1,value=>$rich});is(scalar @sent,2,'duplicate completion inert');
handle($b,'#third');is(scalar @jobs,1,'cache avoids worker');is(scalar @sent,3,'cache serves new channel');
for my $change (sub {$_[0]{on}=0},sub {$_[0]{quit}=1},sub {$_[0]{irc}=bless {},'MB1195::IRC'},sub {$_[0]{wit_runtime_state}{generation}++}) {
    my $c=bot();handle($c);my $job=$jobs[-1];my $count=@sent;$change->($c);
    $job->{on_done}->({ok=>1,value=>$rich});is(scalar @sent,$count,'stale or disabled recipient suppressed');
}
my $c=bot();$c->{on}=0;my $count=@jobs;ok(!handle($c),'disabled chanset refuses work');is(scalar @jobs,$count,'no job when disabled');
$c=bot();delete $c->{loop};ok(!handle($c),'missing loop never invokes synchronous HTTP');
$c=bot();
{
    local *Mediabot::AsyncWorker::start=sub {die 'setup failure'};
    my $before=@sent;ok(handle($c),'setup failure handled');is(scalar @sent,$before+1,'setup failure gives fallback');
    is(scalar keys %{$c->{_tiktok_preview}{pending}},0,'setup failure releases pending');
}
$c=bot();
for my $n (1..5) {handle($c,'#test','N',"https://www.tiktok.com/\@a/video/$n")}
is(scalar keys %{$c->{_tiktok_preview}{pending}},4,'concurrent worker cap');
$c=bot();
for my $n (1..12) {
    handle($c,'#test','N',"https://www.tiktok.com/\@a/video/$n");
    $jobs[-1]{on_done}->({ok=>1,value=>$rich});
}
$count=@jobs;handle($c,'#test','N','https://www.tiktok.com/@a/video/99');
is(scalar @jobs,$count,'launch rate bounded even with immediate completion');
$c=bot();handle($c);
for my $n (1..20) {handle($c,"#channel$n")}
is(scalar @{$c->{_tiktok_preview}{pending}{$info->{key}}{send}},16,'pending recipient fanout bounded');
$c=bot();handle($c);$jobs[-1]{on_done}->({ok=>0,error=>'timeout'});
like($sent[-1][1],qr/aperçu indisponible/,'timeout does not emit generic title');
cmp_ok($c->{_tiktok_preview}{cache}{$info->{key}}{until}-time,'<=',30,'negative cache short-lived');
# Expired state is reclaimed on next admission without a timer.
$c->{_tiktok_preview}{recent}={old=>time-301};
$c->{_tiktok_preview}{cache}={old=>{until=>time-1,value=>{}}};
handle($c,'#new');
ok(!exists($c->{_tiktok_preview}{recent}{old}) && !exists($c->{_tiktok_preview}{cache}{old}),'stale cache and repeat entries reclaimed');
# Real fork/pipe/IO::Async completion: a public-page fixture is fetched only
# in the child; the IRC loop remains available while that child is delayed.
{
    local *Mediabot::AsyncWorker::start=$real_start;
    my $parent=$$;
    local *Mediabot::External::TikTok::_http=sub {
        die 'HTTP attempted in parent' if $$==$parent;
        select undef,undef,undef,0.05;
        return bless {calls=>[],responses=>[$ok]},'MB1195::HTTP';
    };
    my $real=bot();$real->{loop}=IO::Async::Loop->new;
    my $before=@sent;my $started=Time::HiRes::time();
    ok(handle($real),'real worker launched');
    is(scalar @sent,$before,'launch does not synchronously deliver a result');
    my $ticks=0;
    while (@sent==$before && Time::HiRes::time()-$started<3) { $real->{loop}->loop_once(0.02);$ticks++ }
    is(scalar @sent,$before+1,'real worker delivers parsed metadata');
    like($sent[-1][1],qr/château/,'real pipe preserves Unicode caption');
    is(scalar keys %{$real->{_tiktok_preview}{pending}},0,'real worker pending state released');
}
# Exercise the exact dispatcher body while replacing unrelated provider seams.
open my $fh,'<:encoding(UTF-8)',"$Bin/../../Mediabot/External/URL.pm" or die $!;
my $src=do {local $/;<$fh>};
my ($dispatch)=$src =~ /(sub displayUrlTitle \{.*?\n\}\n)/s;die 'dispatcher missing' unless $dispatch;
{
    package MB1195::Router;
    sub _extract_url {$_[0]} sub _url_display_cache_gate {1}
    sub _handle_generic_title {'generic'}
    package MB1195::Log;sub log {1}
}
eval 'package MB1195::Router;use strict;use warnings;'.$dispatch;die $@ if $@;
local *Mediabot::External::MixCloud::is_mixcloud_url=sub {0};
local *Mediabot::External::Reddit::is_reddit_url=sub {0};
local *Mediabot::External::_is_youtube_url=sub {undef};
local *Mediabot::External::_chanset_ok=sub {$_[0]{on}};
local *Mediabot::External::TikTok::handle=sub {'tiktok'};
my $router={logger=>bless({},'MB1195::Log'),on=>1};
is(MB1195::Router::displayUrlTitle($router,undef,'N','#c',$url),'tiktok','real dispatcher owns TikTok');
is(MB1195::Router::displayUrlTitle($router,undef,'N','#c','https://example.org/'),'generic','other host remains generic');
$router->{on}=0;
is(MB1195::Router::displayUrlTitle($router,undef,'N','#c',$url),undef,'UrlTitle guard before TikTok handler');
done_testing;
