package MB906AppleMusicFixture;
use strict;
use warnings;
use utf8;
use Encode qw(decode);
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();

{
    package MB906::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB906::HTTP;
    sub get {my ($s,$url)=@_;push @{$s->{calls}},$url;return shift(@{$s->{responses}})
        // {success=>0,status=>404,reason=>'fixture miss',content=>''}}
    package MB906::Bot;
    sub getLoop {$_[0]{loop}}
}
my $title='Nuit étoilée 🌙';
my $artist='Björk 星';
my $details={type=>'album',artist=>$artist,year=>'2022',duration=>'3m 33s',tracks=>12};
my $url='https://music.apple.com/fr/album/test/123456';
sub _json {JSON::PP->new->utf8->canonical->ascii($_[1]//0)->encode($_[0])}
sub _html {
    my ($ascii)=@_;
    return '<meta property="og:title" content="Album title"><script type="application/ld+json">'
        ._json({'@type'=>'MusicAlbum',byArtist=>{name=>$artist},duration=>'PT3M33S',
            datePublished=>'2022-10-22',numTracks=>12},$ascii).'</script>';
}
sub _response {{success=>1,status=>200,reason=>'OK',content=>$_[0]}}
sub _same {JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1])}
sub _context {
    my ($responses)=@_;
    return (bless({logger=>bless({lines=>[]},'MB906::Log')},'MB906::Bot'),
        bless({responses=>[@$responses],calls=>[]},'MB906::HTTP'));
}
sub _fetch {
    my ($responses,$browser)=@_;
    my ($bot,$http)=_context($responses);my $browser_calls=0;
    no warnings 'redefine';
    local *Mediabot::External::_make_http=sub {$http};
    local *Mediabot::External::URL::_fetch_url_chromium_dumpdom=sub {$browser_calls++;return $browser};
    my $out=Mediabot::External::AppleMusic::_applemusic_fetch_sync($bot,$url);
    return ($out,$http->{calls},$browser_calls);
}
sub _native {
    my ($browser)=@_;
    my ($bot,$http)=_context([$browser ? {success=>0,status=>503,reason=>'fixture fallback',content=>''}
        : _response(_html(0))]);
    $bot->{loop}=IO::Async::Loop->new;
    my (@sent,$chromium_calls);
    $chromium_calls=0;
    no warnings 'redefine';
    local *Mediabot::External::_make_http=sub {$http};
    local *Mediabot::External::URL::_fetch_url_chromium_dumpdom=sub {$chromium_calls++;return decode('UTF-8',_html(0))};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[$_[1],$_[2]];1};
    my $ret=Mediabot::External::_handle_applemusic($bot,undef,'listener','#test',$url);
    my $end=Time::HiRes::time()+3;
    while (keys(%{$bot->{_applemusic_pending}}) && Time::HiRes::time()<$end) {$bot->{loop}->loop_once(0.01)}
    $bot->{loop}->loop_once(0) for 1..2;
    my $text="(listener) [AppleMusic] Album title - by $artist - album - 2022 - 3m 33s - 12 tracks";
    my $line=$sent[0][1]//'';$line=~s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;$line=~s/[\x02\x0f\x16\x1d\x1f]//g;
    my $ok=$ret && @sent==1 && $sent[0][0] eq '#test' && $line eq $text
        && !keys(%{$bot->{_applemusic_pending}}) && !@{$http->{calls}} && $chromium_calls==0;
    my $cached=Mediabot::External::_handle_applemusic($bot,undef,'cached','#cache',$url);
    my $cache_line=$sent[1][1]//'';$cache_line=~s/^\(cached\)/(listener)/;
    $ok &&= $cached && @sent==2 && $sent[1][0] eq '#cache' && $cache_line eq $sent[0][1];
    return {ok=>$ok?1:0,display=>$line};
}
sub run_contracts {
    my @specs=(
        ['details_raw_utf8',sub {my $r=Mediabot::External::AppleMusic::_applemusic_extract_details({},_html(0));_same($r,$details)}],
        ['details_characters',sub {my $r=Mediabot::External::AppleMusic::_applemusic_extract_details({},decode('UTF-8',_html(0)));_same($r,$details)}],
        ['details_escaped',sub {my $r=Mediabot::External::AppleMusic::_applemusic_extract_details({},decode('UTF-8',_html(1)));_same($r,$details)}],
        ['details_array',sub {
            my $html='<script type="application/ld+json">'._json([[],{'@type'=>['Thing','MusicAlbum'],byArtist=>[{name=>$artist}],duration=>'PT3M33S',datePublished=>'2022',numTracks=>12}]).'</script>';
            _same(Mediabot::External::AppleMusic::_applemusic_extract_details({},decode('UTF-8',$html)),$details);
        }],
        ['malformed_json',sub {_same(Mediabot::External::AppleMusic::_applemusic_extract_details({},'<script type="application/ld+json">{bad json</script>'),{})}],
        ['null_json',sub {_same(Mediabot::External::AppleMusic::_applemusic_extract_details({},'<script type="application/ld+json">null</script>'),{})}],
        ['fetch_page_literal',sub {my ($r,$calls,$browser)=_fetch([_response(_html(0))]);_same($r->{details},$details) && $r->{title} eq 'Album title' && @$calls==1 && !$browser}],
        ['fetch_page_escaped',sub {my ($r,$calls,$browser)=_fetch([_response(_html(1))]);_same($r->{details},$details) && @$calls==1 && !$browser}],
        ['fetch_browser_characters',sub {my ($r,$calls,$browser)=_fetch([{success=>0,status=>503,reason=>'fixture fallback',content=>''}],decode('UTF-8',_html(0)));_same($r->{details},$details) && $r->{title} eq 'Album title' && @$calls==1 && $browser==1}],
    );
    for my $chars (0,1) {
        push @specs,['lookup_'.($chars?'characters':'bytes'),sub {
            my $raw=_json({results=>[{trackId=>123,kind=>'song',trackName=>$title,artistName=>$artist,collectionName=>'Record',releaseDate=>'2022-01-01',trackTimeMillis=>213000}]});
            $raw=decode('UTF-8',$raw) if $chars;
            my ($bot,$http)=_context([_response($raw)]);
            my $r=Mediabot::External::AppleMusic::_applemusic_lookup_track($bot,$http,'fr',123);
            $r && $r->{title} eq $title && _same($r->{details},{type=>'song',artist=>$artist,album=>'Record',year=>'2022',duration=>'3m 33s'}) && @{$http->{calls}}==1;
        }];
    }
    my @results;
    for my $spec (@specs) {
        my ($name,$check)=@$spec;my (@warnings,$ok,$error);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$ok=eval {$check->()};$error=$@;}
        push @results,{case=>$name,ok=>$ok && !@warnings && !$error?1:0,
            (@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
    }
    for my $browser (0,1) {
        my (@warnings,$r);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$r=eval {_native($browser)};$r||={ok=>0,error=>"$@"};}
        $r->{case}=$browser?'native_browser_result':'native_http_result';
        if (@warnings) {$r->{ok}=0;$r->{warnings}=\@warnings}
        push @results,$r;
    }
    return \@results;
}
1;
