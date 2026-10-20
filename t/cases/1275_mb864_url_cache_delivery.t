use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::URL ();

{
    package MB864DeliveryLog;sub log {1}
    package MB864DeliveryConf;
    sub get {$_[1] eq 'main.YOUTUBE_APIKEY' ? 'LOCAL_FIXTURE_ONLY' : undef}
    package MB864DeliveryHTTP;
    sub get {
        my ($self,$url)=@_;push @{$self->{calls}},$url;
        if ($url =~ m{\Ahttps://www[.]googleapis[.]com/youtube/v3/videos\?id=([A-Za-z0-9_-]{11})&}) {
            return {success=>1,status=>200,content=>JSON::PP::encode_json({items=>[{
                snippet=>{title=>"Video $1",channelTitle=>'Studio'},
                contentDetails=>{duration=>'PT1M2S'},statistics=>{viewCount=>1234}}]})};
        }
        die 'unexpected HTTP destination in offline test'
            unless $url =~ m{\Ahttps://(?:www[.])?(?:example[.]test|instagram[.]com)/}i;
        my ($label)=$url =~ m{/((?:Report|report)|(?:AbC123|abc123))/?(?:[?#]|\z)};
        die 'unexpected resource in offline test' unless defined $label;
        return {success=>1,status=>200,headers=>{'content-type'=>'text/html'},
            content=>Encode::encode('UTF-8',"<html><head><title>Émission $label</title></head></html>")};
    }
}
sub delivery_bot {
    return {logger=>bless({},'MB864DeliveryLog'),conf=>bless({},'MB864DeliveryConf'),out=>[]};
}
my $http=bless({calls=>[]},'MB864DeliveryHTTP');our $enabled=1;
no warnings qw(redefine once);
local *Mediabot::External::_make_http=sub {$http};
local *Mediabot::External::_chanset_ok=sub {$enabled};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{out}},[$_[1],$_[2]];1};
my $dispatch=\&Mediabot::External::URL::displayUrlTitle;

{
    my $bot=delivery_bot();$http->{calls}=[];
    for my $path (qw(Report report)) {
        ok($dispatch->($bot,undef,'Reader','#test',"Look https://example.test/$path"),"generic $path reaches actual title reader");
    }
    is_deeply($http->{calls},['https://example.test/Report','https://example.test/report'],
        'generic HTTP receives both original case-distinct URLs');
    like(($bot->{out}[0] // [])->[1] // '',qr/Émission Report/,'first generic title retains resource and UTF-8');
    like(($bot->{out}[1] // [])->[1] // '',qr/Émission report/,'second generic title belongs to the second resource');
    $dispatch->($bot,undef,'Other','#TEST','HTTPS://EXAMPLE.TEST/report');
    is(scalar @{$http->{calls}},2,'scheme/host/channel case variation does not fetch a repeat');
    is(scalar @{$bot->{out}},2,'repeat does not emit another title');
    $dispatch->($bot,undef,'Second','#i/o','https://example.test/report');
    is(scalar @{$bot->{out}},3,'another channel may display the same URL');
    is($bot->{out}[-1][0],'#i/o','generic title keeps current destination');
    like($bot->{out}[-1][1],qr/Second.*Émission report/,'generic title keeps current caller');
}
{
    my $bot=delivery_bot();$http->{calls}=[];local $enabled=0;
    $dispatch->($bot,undef,'Reader','#test','https://example.test/Report');
    is(scalar keys %{$bot->{_url_display_cache} // {}},0,'disabled feature never consumes repeat admission');
    is(scalar @{$http->{calls}},0,'disabled feature makes no HTTP request');
    $enabled=1;
    ok($dispatch->($bot,undef,'Reader','#test','https://example.test/Report'),'enabling allows the previously refused URL immediately');
    $dispatch->($bot,undef,'Reader','#test','http://127.0.0.1/Report');
    is(scalar @{$http->{calls}},1,'existing private literal guard still blocks HTTP');
    is(scalar keys %{$bot->{_url_display_cache}},1,'private literal does not consume admission');
}
{
    my $bot=delivery_bot();$http->{calls}=[];
    for my $id (qw(AbCdEfGh123 abcdefgh123)) {
        ok($dispatch->($bot,undef,'Reader','#test',"https://youtube.com/watch?v=$id"),"YouTube $id is independently admitted");
    }
    is(scalar @{$http->{calls}},2,'case-distinct video IDs each reach the Data API');
    like($http->{calls}[0] // '',qr/id=AbCdEfGh123&/,'first video request keeps exact ID');
    like($http->{calls}[1] // '',qr/id=abcdefgh123&/,'second video request keeps its own ID');
    like(($bot->{out}[0] // [])->[1] // '',qr/Video AbCdEfGh123/,'first title matches first video');
    like(($bot->{out}[1] // [])->[1] // '',qr/Video abcdefgh123/,'second title matches second video');
    $dispatch->($bot,undef,'Reader','#TEST','HTTPS://YOUTUBE.COM/watch?v=abcdefgh123');
    is(scalar @{$bot->{out}},2,'scheme/host variation still suppresses video repeat');
    $dispatch->($bot,undef,'Second','#i/o','https://youtube.com/watch?v=abcdefgh123');
    is(scalar @{$http->{calls}},2,'another channel reuses the correct existing video metadata cache');
    like($bot->{out}[-1][1],qr/^\(Second\).*Video abcdefgh123/,'video cache replay keeps caller and case-correct title');
    is($bot->{out}[-1][0],'#i/o','video cache replay keeps current channel');
}
{
    my $bot=delivery_bot();$http->{calls}=[];
    for my $pair (['AbC123','#test'],['abc123','#i/o']) {
        my ($id,$channel)=@$pair;
        ok($dispatch->($bot,undef,'Reader',$channel,"https://instagram.com/p/$id/"),"Instagram $id reaches its actual fetch/format path");
    }
    is_deeply($http->{calls},['https://instagram.com/p/AbC123/','https://instagram.com/p/abc123/'],
        'Instagram cache does not replay a different post after admission');
    like(($bot->{out}[0] // [])->[1] // '',qr/Émission AbC123/,'first Instagram post retains matching title');
    like(($bot->{out}[1] // [])->[1] // '',qr/Émission abc123/,'second Instagram post retains its own matching title');
    $dispatch->($bot,undef,'Second','#i/o','HTTPS://INSTAGRAM.COM/p/AbC123/');
    is(scalar @{$http->{calls}},2,'Instagram scheme/host variation reuses the matching metadata entry');
    like($bot->{out}[-1][1],qr/^\(Second\).*Émission AbC123/,'Instagram cache replay uses current caller');
    is($bot->{out}[-1][0],'#i/o','Instagram cache replay uses current destination');
    $_->{ts}=time()-601 for values %{$bot->{_instagram_cache}};
    $dispatch->($bot,undef,'Third','#third','https://instagram.com/p/abc123/');
    is(scalar @{$http->{calls}},3,'expired Instagram metadata is fetched again');
    like($bot->{out}[-1][1],qr/^\(Third\).*Émission abc123/,'expiry refresh retains the selected post');
}

# Real Instagram AsyncWorker fork/pipe: two case-distinct posts may be pending
# together, while a matching pending URL still coalesces across channels.
{
    my $bot=delivery_bot();my $loop=IO::Async::Loop->really_new;$bot->{loop}=$loop;
    for my $id (qw(AbC123 abc123)) {
        ok(Mediabot::External::URL::_handle_instagram($bot,undef,'Reader','#test',"https://instagram.com/p/$id/"),"native Instagram $id launch is accepted");
    }
    is(scalar keys %{$bot->{_instagram_pending}},2,'case-distinct native requests own separate pending slots');
    ok(Mediabot::External::URL::_handle_instagram($bot,undef,'Waiting','#i/o','HTTPS://INSTAGRAM.COM/p/AbC123/'),
        'matching pending request retains ordinary coalescing');
    is(scalar keys %{$bot->{_instagram_pending}},2,'host spelling does not create a redundant worker');
    my $deadline=Time::HiRes::time()+8;
    $loop->loop_once(.01) while keys(%{$bot->{_instagram_pending}}) && Time::HiRes::time()<$deadline;
    is(scalar keys %{$bot->{_instagram_pending}},0,'native completions release both pending slots');
    is(scalar @{$bot->{out}},2,'both distinct native posts complete exactly once');
    my $lines=join("\n",map {$_->[1]} @{$bot->{out}});
    like($lines,qr/Émission AbC123/,'first post survives actual worker transport');
    like($lines,qr/Émission abc123/,'second post survives actual worker transport');
    is_deeply([map {$_->[0]} @{$bot->{out}}],['#test','#test'],'pending coalescing does not redirect original deliveries');
}
done_testing;
