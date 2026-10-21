use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Mediabot::External ();

{
    package MB867YTConf;
    sub get { $_[1] eq 'main.YT_SEARCH_RESULTS' ? ($_[0]{limit} // 3) : 'LOCAL_FIXTURE_ONLY' }
    package MB867YTLog;
    sub log { 1 }
    package MB867YTHTTP;
    sub get {
        my ($self, $url) = @_;
        push @{$self->{calls}}, $url;
        die "unexpected HTTP request\n" unless @{$self->{queue}};
        return shift @{$self->{queue}};
    }
    package MB867YTContext;
    sub bot { $_[0]{bot} }
    sub nick { 'Caller' }
    sub channel { '#i/o' }
    sub args { ['local fixture'] }
    sub message { undef }
}

sub response867 { return {success=>1,status=>200,content=>JSON::PP::encode_json($_[0])} }
sub video867 {
    my ($id) = @_;
    return {id=>{videoId=>$id},snippet=>{title=>"Video $id",channelTitle=>'Studio'}};
}
sub metadata867 {
    return {id=>$_[0],contentDetails=>{duration=>'P1DT2H3M4S'},statistics=>{viewCount=>'1234'}};
}

no warnings qw(redefine once);
local *Mediabot::External::_chanset_ok = sub { $_[2] eq 'Youtube' };
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1],$_[2]]; 1 };
local *Mediabot::Helpers::botNotice = sub { push @{$_[0]{notices}}, $_[2]; 1 };
local *Mediabot::Helpers::logBot = sub { $_[0]{logged}++; 1 };
my $http = bless {queue=>[],calls=>[]}, 'MB867YTHTTP';
local *Mediabot::External::_make_http = sub { $http };

sub run867 {
    my ($mode, $limit, @bodies) = @_;
    $http->{queue}=[map {response867($_)} @bodies]; $http->{calls}=[];
    my $bot={conf=>bless({limit=>$limit},'MB867YTConf'),logger=>bless({},'MB867YTLog'),out=>[],notices=>[]};
    my (@warnings,$result);
    my $ok;
    { local $SIG{__WARN__}=sub {push @warnings,@_};
      $ok=eval {
        $result=$mode eq 'public'
            ? Mediabot::External::YouTube::displayYoutubeDetails($bot,undef,'Caller','#i/o','https://youtu.be/AbCdEfGh123')
            : Mediabot::External::YouTube::ytSearch_ctx(bless({bot=>$bot},'MB867YTContext'));
        1;
      };
    }
    my $error=$@;
    return {ok=>$ok,error=>$error,result=>$result,bot=>$bot,calls=>[@{$http->{calls}}],warnings=>\@warnings};
}

for my $root ([],[{}],JSON::PP::true,JSON::PP::false,'text',42,undef) {
    my $r=run867('public',3,$root);
    ok($r->{ok},'public metadata refuses a non-object root without exception') or diag($r->{error});
    ok(!defined($r->{result}),'non-object metadata is unavailable');
    is(scalar @{$r->{bot}{out}},0,'non-object metadata never emits a fabricated title');
    is(scalar @{$r->{calls}},1,'non-object metadata does not trigger another HTTP request');
    is_deeply($r->{warnings},[],'non-object metadata produces no warning');
}

my $id='AbCdEfGh123'; my $second='ZyXwVuTs987';
my @bad=(undef,7,'bad',[],{}, {id=>'bad'}, {id=>{videoId=>[]},snippet=>{}},
    {id=>{videoId=>'short'},snippet=>{}}, {id=>{videoId=>$id},snippet=>[]});

for my $case (
    ['search entries', {items=>[@bad,video867($id)]}, {items=>[metadata867($id)]}],
    ['metadata entries', {items=>[video867($id)]}, {items=>[@bad,metadata867($id)]}],
    ['metadata containers', {items=>[video867($id)]}, {items=>[{id=>$id,contentDetails=>'bad',statistics=>[]}]}],
    ['title fields', {items=>[{id=>{videoId=>$id},snippet=>{title=>[],channelTitle=>{}}}]}, {items=>[]}],
) {
    my ($name,$search,$meta)=@$case;
    my $r=run867('search',3,$search,$meta);
    ok($r->{ok},"$name: command contains malformed fields") or diag($r->{error});
    is($r->{result},1,"$name: valid video remains usable");
    is(scalar @{$r->{bot}{out}},2,"$name: one header and one video");
    is(scalar @{$r->{calls}},2,"$name: one search and one metadata request");
    my $visible=join('\n',map {$_->[1]} @{$r->{bot}{out}});
    like($visible,qr{https://youtu[.]be/\Q$id\E},"$name: selected identity remains exact");
    unlike($visible,qr/(?:HASH|ARRAY)\(0x/,"$name: reference internals are not shown");
    is_deeply($r->{warnings},[],"$name: no uncontrolled warnings");
    if ($name eq 'search entries') {
        like($visible,qr/1 result\(s\)/,'header counts only usable videos');
        like($visible,qr/26:03:04/,'day durations retain their existing compact rendering');
        like($visible,qr/1[.]2k views/,'views retain the shared formatter');
        is($r->{bot}{logged},1,'successful search still logs once');
    }
}

{
    my $r=run867('search',3,{items=>\@bad});
    ok($r->{ok},'an entirely unusable response is contained') or diag($r->{error});
    is(scalar @{$r->{calls}},1,'no metadata request is made without usable IDs');
    is(scalar @{$r->{bot}{out}},1,'no usable IDs produce only the no-results reply');
    like($r->{bot}{out}[0][1] // '',qr/No results/,'no-results reply remains useful');
    ok(!exists $r->{bot}{_yt_cache}{'search:local fixture'},'unusable responses are not cached');
}

for my $limit (1,3,5) {
    my @ids=map {sprintf('Video%06d',$_)} 1..8;
    my $r=run867('search',$limit,{items=>[video867($ids[0]),map {video867($_)} @ids]},
        {items=>[map {metadata867($_)} reverse @ids]});
    ok($r->{ok},"limit $limit: oversized provider response is contained") or diag($r->{error});
    is(scalar @{$r->{bot}{out}},$limit+1,"limit $limit: duplicate/extra entries cannot increase the message count");
    my $expected=join(',',@ids[0..$limit-1]);
    like($r->{calls}[1] // '',qr/[?&]id=\Q$expected\E&/,"limit $limit: metadata requests only distinct admitted IDs in search order");
    for my $index (0..$limit-1) {
        like($r->{bot}{out}[$index+1][1] // '',qr{youtu[.]be/\Q$ids[$index]\E},"limit $limit: displayed order remains search order");
    }
    $http->{calls}=[];
    Mediabot::External::YouTube::ytSearch_ctx(bless({bot=>$r->{bot}},'MB867YTContext'));
    is(scalar @{$http->{calls}},0,"limit $limit: ordinary cache reuse still avoids HTTP");
    is(scalar @{$r->{bot}{out}},2*($limit+1),"limit $limit: cache replay retains the bounded batch");
}

{
    my $r=run867('public',3,{items=>[{snippet=>{title=>'Local title',channelTitle=>'Studio'},
        contentDetails=>{duration=>'PT1M2S'},statistics=>{viewCount=>'1234'}}]});
    ok($r->{ok} && $r->{result},'healthy public metadata still succeeds');
    like($r->{bot}{out}[0][1] // '',qr/Local title/,'healthy public title is preserved');
    is($r->{bot}{out}[0][0],'#i/o','public output retains its destination');
}
done_testing;
