use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use URI::Escape qw(uri_unescape);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::AsyncWorker;
use Mediabot::External ();
use Mediabot::External::YouTube ();
use Mediabot::External::URL ();

{
    package MB863::Conf;
    sub get {$_[1] eq 'main.YOUTUBE_APIKEY' ? 'LOCAL_FIXTURE_ONLY' : undef}
    package MB863::Logger;
    sub log {push @{$_[0]{lines}}, $_[2]}
    package MB863::HTTP;
    sub get {
        my ($self, $url) = @_;
        push @{$self->{calls}}, $url;
        return {success=>1,status=>200,content=>JSON::PP::encode_json({title=>'Émission locale',author_name=>'Studio'})}
            if $url =~ m{\Ahttps://www[.]youtube[.]com/oembed\?};
        die 'unexpected external route' unless $url =~ m{\Ahttps://www[.]googleapis[.]com/youtube/v3/videos\?};
        my ($id) = $url =~ /[?&]id=([A-Za-z0-9_-]{11})(?:&|\z)/;
        die 'missing exact request identity' unless defined $id;
        my $items = $self->{empty} ? [] : [{id=>$id,snippet=>{title=>"Video $id",channelTitle=>'Studio'},
            contentDetails=>{duration=>'PT1M2S'},statistics=>{viewCount=>1234}}];
        return {success=>1,status=>200,content=>JSON::PP::encode_json({items=>$items})};
    }
}
sub bot863 {
    return {conf=>bless({},'MB863::Conf'),logger=>bless({lines=>[]},'MB863::Logger'),out=>[],notices=>[]};
}
my $id='AbCdEfGh123'; my $other='ZyXwVuTs987';
my @urls=("https://youtube.com/watch?v=$id&next=https://example.test/?v=$other",
    "https://youtube.com/watch?v=$id#part&v=$other", "https://youtu.be/$id?t=10",
    "https://m.youtube.com/shorts/$id", "https://youtube.com/live/$id", "https://youtube-nocookie.com/embed/$id");

no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{out}}, [$_[1],$_[2]];1};
local *Mediabot::Helpers::noticeConsoleChan=sub {push @{$_[0]{notices}}, $_[1];1};
my $http=bless({calls=>[]},'MB863::HTTP');
local *Mediabot::External::_make_http=sub {return $http};

for my $mode (qw(public radio)) {
    for my $url (@urls) {
        my $bot=bot863();$http->{calls}=[];
        my ($ok,$duration,$message);
        if ($mode eq 'public') {$ok=Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#test',$url)}
        else {($duration,$message)=Mediabot::External::YouTube::getYoutubeDetails($bot,$url);$ok=defined $message}
        ok($ok,"$mode: metadata request succeeds");
        is(scalar @{$http->{calls}},1,"$mode: one metadata request");
        like($http->{calls}[0] // '',qr/[?&]id=\Q$id\E&/,"$mode: API receives exactly the selected outer identity");
        my $visible=$mode eq 'public' ? $bot->{out}[0][1] // '' : $message // '';
        like($visible,qr/Video \Q$id\E/,"$mode: displayed title belongs to selected video");
        unlike($visible,qr/\Q$other\E/,"$mode: nested/fragment identity is not displayed");
        if ($mode eq 'public') {
            is($bot->{out}[0][0],'#test','public details keep their channel');
            ok(exists $bot->{_yt_cache}{$id},'public metadata cache uses the exact identity');
        } else {is($duration,62,'radio duration contract remains seconds')}
    }
}

# A stale selector must not even consume an unrelated live video cache entry.
{
    my $bot=bot863();$bot->{_yt_cache}{$other}={ts=>time(),msg=>'Wrong cached video'};$http->{calls}=[];
    my $url="https://youtube.com/watch?v=$id#v=$other";
    Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#test',$url);
    is(scalar @{$http->{calls}},1,'fragment cannot redirect lookup into another video cache');
    like($bot->{out}[0][1] // '',qr/Video \Q$id\E/,'cold selected video gets its own metadata');
    is($bot->{_yt_cache}{$other}{msg},'Wrong cached video','unrelated cache entry survives');
    Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Second','#i/o',"https://youtu.be/$id");
    is(scalar @{$http->{calls}},1,'fresh metadata cache remains shared across equivalent supported URL forms');
    like($bot->{out}[-1][1],qr/^\(Second\).*Video \Q$id\E/,'cache response retains the current caller');
    is($bot->{out}[-1][0],'#i/o','cache response retains the current channel');
}
for my $mode (qw(public radio)) {
    for my $url ("https://youtu.be/${id}EXTRA", "https://youtube.com/watch?v=$id&v=$other",
        "https://youtube.com/watch?next=https://example.test/?v=$id", "https://youtube.com/watch-later?v=$id",
        "https://example.test/?u=https://youtube.com/watch?v=$id") {
        my $bot=bot863();$http->{calls}=[];
        $bot->{_yt_cache}{$id}={ts=>time(),msg=>'Cached prefix video'};
        my $result=$mode eq 'public'
            ? Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#test',$url)
            : Mediabot::External::YouTube::getYoutubeDetails($bot,$url);
        ok(!defined($result),"$mode: unsupported identity is refused");
        is(scalar @{$http->{calls}},0,"$mode: refused identity makes no metadata/fallback request");
        is(scalar @{$bot->{out}},0,"$mode: refused identity emits no unrelated cached title");
    }
}

# Actual URL-title routing, its +Youtube gate and anti-repeat admission.
{
    my $bot=bot863();$http->{calls}=[];my $enabled=1;
    local *Mediabot::External::_chanset_ok=sub {return $enabled && $_[2] eq 'Youtube'};
    my $url="https://youtube.com/watch?v=$id#part&v=$other";
    ok(Mediabot::External::URL::displayUrlTitle($bot,undef,'Caller','#test',"Look $url"),'real URL dispatcher admits supported video');
    like($bot->{out}[0][1] // '',qr/Video \Q$id\E/,'real dispatcher and metadata handler agree on identity');
    is(scalar @{$http->{calls}},1,'router performs one metadata request');
    Mediabot::External::URL::displayUrlTitle($bot,undef,'Caller','#test',"Look $url");
    is(scalar @{$bot->{out}},1,'ordinary same-channel anti-repeat remains effective');
    $enabled=0;
    Mediabot::External::URL::displayUrlTitle($bot,undef,'Caller','#i/o',$url);
    is(scalar @{$bot->{out}},1,'disabled channel never publishes metadata');
    is(scalar @{$http->{calls}},1,'disabled channel does not reach API');
}
{
    my $bot=bot863();$http->{calls}=[];local $http->{empty}=1;
    ok(Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#test',
        "https://youtube.com/watch?v=$id#part&v=$other"),'empty API items retain existing oEmbed fallback');
    is(scalar @{$http->{calls}},2,'fallback follows exactly one metadata request');
    like(uri_unescape($http->{calls}[1] // ''),qr{url=https://www[.]youtube[.]com/watch\?v=\Q$id\E\z},
        'fallback canonical watch URL retains the same selected video');
    like($bot->{out}[0][1] // '',qr/Émission locale/,'fallback retains international title');
}

# Native fork/pipe completion carries the actual metadata result, with only
# HTTP IO substituted. The child cannot contact an external API.
{
    my $loop=IO::Async::Loop->really_new;my $result;
    my $worker=Mediabot::AsyncWorker->start(loop=>$loop,timeout=>3,max_output=>8192,
        child=>sub {
            my $bot=bot863();$http->{calls}=[];
            Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#test',
                "https://youtube.com/watch?v=$id#part&v=$other");
            return {out=>$bot->{out},calls=>$http->{calls}};
        },on_done=>sub {$result=$_[0]});
    ok($worker,'native metadata worker starts');
    my $deadline=Time::HiRes::time()+5;
    $loop->loop_once(.01) while !defined($result) && Time::HiRes::time()<$deadline;
    ok($result && $result->{ok},'native metadata worker completes successfully');
    like($result->{value}{calls}[0] // '',qr/[?&]id=\Q$id\E&/,'worker transport retains exact API video ID');
    like($result->{value}{out}[0][1] // '',qr/Video \Q$id\E/,'worker result retains matching public title');
    is($result->{value}{out}[0][0],'#test','worker result keeps original destination');
}
done_testing;
