use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
use Encode qw(encode);
our $NOW;
BEGIN {$NOW=1_000_000;*CORE::GLOBAL::time=sub () {$NOW}}
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::External ();
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1003::HTTP;
    sub get {
        my ($self,$url)=@_;
        die "unexpected offline weather destination\n" unless $url=~m{\Ahttps://wttr[.]in/Paris\?};
        push @{$self->{calls}},$url;
        $main::NOW+=$self->{elapsed};
        return {%{$self->{response}}};
    }
    package MB1003::Conf;
    sub get {$_[1] eq 'main.MAIN_PROG_URL'?'https://project.example.invalid/':undef}
    package MB1003::Log;sub log {push @{$_[0]{rows}},[@_[1..$#_]];1}
}
my ($http,@wire,@audit,@warnings,@clients);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::External::_make_http=sub {push @clients,{@_};$http};
local *Mediabot::External::getIdChansetList=sub {7};
local *Mediabot::External::getIdChannelSet=sub {8};
local *Mediabot::Helpers::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Helpers::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Helpers::logBot=sub {push @audit,[@_[2..$#_]];1};
sub setup_1378 {
    my ($age,$elapsed,$response)=@_;
    $NOW=1_000_000;@wire=();@audit=();
    $http=bless {calls=>[],elapsed=>$elapsed,response=>$response},'MB1003::HTTP';
    my $bot=Mediabot->new({});
    $bot->{conf}=bless {},'MB1003::Conf';$bot->{logger}=bless {rows=>[]},'MB1003::Log';
    $bot->{_weather_cache}={paris=>{ts=>$NOW-$age,text=>'Stored Paris'}};
    return $bot;
}
sub invoke_1378 {
    my ($bot,$command)=@_;$command//='weather';
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',
        command=>$command,args=>['Paris']);
    $bot->command_registry->handler_for($command,'public')->($ctx);
    return dclone([\@wire,\@audit,scalar(@{$http->{calls}}),$bot->{_weather_cache}]);
}
my $down={success=>0,status=>503};
my $fresh={success=>1,status=>200,content=>'Fresh Paris'};
{
    my (@actual,@expected);
    for my $age (0,180) {
        my $bot=setup_1378($age,0,$down);my $before=dclone($bot->{_weather_cache});
        push @actual,invoke_1378($bot);
        push @expected,[[['public','#test','Stored Paris']],[],0,$before];
    }
    is_deeply(\@actual,\@expected,'fresh cache keeps the inclusive zero-to-180-second window without HTTP or audit');
}
{
    my $bot=setup_1378(-10,0,$fresh);
    is_deeply(invoke_1378($bot),[[['public','#test','Fresh Paris']],
        [['#test','weather','Paris']],1,{paris=>{ts=>$NOW,text=>'Fresh Paris'}}],
        'future-dated cache is refreshed instead of being treated as fresh until the clock catches up');
}
{
    my (@actual,@expected);
    for my $age (181,900) {
        my $bot=setup_1378($age,0,$down);my $before=dclone($bot->{_weather_cache});
        push @actual,invoke_1378($bot,'meteo');
        push @expected,[[['public','#test','Stored Paris  (cached)']],[],1,$before];
    }
    is_deeply(\@actual,\@expected,'valid stale fallback retains text and the inclusive 900-second limit through meteo');
}
{
    my $bot=setup_1378(900,1,$down);my $before=dclone($bot->{_weather_cache});
    is_deeply(invoke_1378($bot),[[['public','#test','Weather service unavailable (HTTP 503), try again later.']],[],1,$before],
        'cache that expires during a failed HTTP request is not displayed as valid fallback');
}
{
    my $bot=setup_1378(899,2,{success=>1,status=>200,content=>'Unknown location'});
    my $before=dclone($bot->{_weather_cache});
    is_deeply(invoke_1378($bot),[[['public','#test',"No answer from wttr.in for 'Paris'. Try again later."]],[],1,$before],
        'provider-unhappy fallback also checks age after the request finishes');
}
{
    my $bot=setup_1378(400,-500,$down);my $before=dclone($bot->{_weather_cache});
    is_deeply(invoke_1378($bot),[[['public','#test','Weather service unavailable (HTTP 503), try again later.']],[],1,$before],
        'clock rollback during HTTP cannot turn a now-future cache entry into a stale fallback');
}
{
    my (@actual,@expected);
    for my $elapsed (4,-5) {
        my $bot=setup_1378(901,$elapsed,$fresh);
        my $result=invoke_1378($bot);
        push @actual,$result;
        push @expected,[[['public','#test','Fresh Paris']],[['#test','weather','Paris']],1,
            {paris=>{ts=>$NOW,text=>'Fresh Paris'}}];
    }
    is_deeply(\@actual,\@expected,'successful responses are dated when stored, including a clock adjustment during HTTP');
}
{
    my $bot=setup_1378(0,0,$fresh);delete $bot->{_weather_cache}{paris}{ts};
    is_deeply(invoke_1378($bot),[[['public','#test','Fresh Paris']],[['#test','weather','Paris']],1,
        {paris=>{ts=>$NOW,text=>'Fresh Paris'}}],
        'undated cache is repaired by normal fetching with the existing successful output and audit');
}

# Exercise the registered command and its cache, not a copied parser.
{
    my (@actual,@expected);
    my $weather="Genève : ☀️ +18°C | vent <5 km/h | 💧70%";
    for my $line ($weather,encode('UTF-8',$weather),'x' x 2048) {
        my $bot=setup_1378(300,2,{success=>1,status=>200,
            headers=>{'content-type'=>'text/plain; charset=utf-8'},content=>" \r\n$line\r\n "});
        push @actual,invoke_1378($bot);
        push @expected,[[['public','#test',$line]],[['#test','weather','Paris']],1,
            {paris=>{ts=>$NOW,text=>$line}}];
        push @actual,[$clients[-1]{max_size},$clients[-1]{timeout},$clients[-1]{verify_SSL},$clients[-1]{agent}];
        push @expected,[16384,4,1,'mediabot_v3 weather/1.0 (+https://project.example.invalid/)'];
        push @actual,invoke_1378($bot);
        push @expected,[[['public','#test',$line],['public','#test',$line]],
            [['#test','weather','Paris']],1,{paris=>{ts=>$NOW,text=>$line}}];
    }
    {
        no warnings 'redefine';local *MB1003::Conf::get=sub {undef};
        my $bot=setup_1378(300,0,$fresh);invoke_1378($bot);
        push @actual,$clients[-1]{agent};
        push @expected,'mediabot_v3 weather/1.0 (+https://github.com/teuk/mediabot_v3)';
    }
    is_deeply(\@actual,\@expected,'single-line weather keeps Unicode, UTF-8 bytes, comparisons, bounded HTTP and both project User-Agents');
}
{
    my (@actual,@expected);
    my @bad=(
        '<!DOCTYPE html><html><body>upstream failed</body></html>',
        '<form action="/challenge">verification required</form>',
        "Paris: sunny\nLyon: rainy","Paris: sunny\rLyon: rainy",
        'x' x 2049,"☀" x 683,encode('UTF-8',"☀" x 683),
        '', 'Unknown location', 'Please try again later', 'Service unavailable',
        undef, [], {}, map {"Paris: $_ sunny"} map {chr} (0..9,11,12,14..31,127),
    );
    my @responses=(map {{success=>1,status=>200,content=>$_}} @bad);
    push @responses,map {{success=>1,status=>200,content=>'apparently plain',
        headers=>{'content-type'=>$_}}} ('text/html; charset=utf-8','application/json','application/xhtml+xml');
    for my $response (@responses) {
        for my $age (undef,300,899,901) {
            my $bot=setup_1378($age//300,defined($age)&&$age==899?2:0,$response);
            delete $bot->{_weather_cache}{paris} unless defined $age;
            my $before=dclone($bot->{_weather_cache});
            my $out=defined($age)&&$age==300?'Stored Paris  (cached)':"No answer from wttr.in for 'Paris'. Try again later.";
            push @actual,invoke_1378($bot,'meteo');
            push @expected,[[['public','#test',$out]],[],1,$before];
            push @actual,$bot->{logger}{rows};
            push @expected,[[2,'displayWeather_ctx(): wttr response rejected']];
            # A failed body must not become a fresh cache hit on the next call.
            $http->{response}=$fresh;$http->{elapsed}=0;
            push @actual,invoke_1378($bot);
            push @expected,[[['public','#test',$out],['public','#test','Fresh Paris']],
                [['#test','weather','Paris']],2,{paris=>{ts=>$NOW,text=>'Fresh Paris'}}];
        }
    }
    is_deeply(\@actual,\@expected,'invalid provider success never reaches IRC, cache or audit; fallback expiry and next-call recovery remain exact');
}
is_deeply(\@warnings,[],'weather cache timing emits no warnings');
done_testing;
