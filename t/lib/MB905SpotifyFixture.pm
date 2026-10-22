package MB905SpotifyFixture;
use strict;
use warnings;
use utf8;
use Encode qw(encode);
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();

{
    package MB905::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB905::HTTP;
    sub get {
        my ($s,$url)=@_;push @{$s->{calls}},$url;
        return {success=>1,status=>200,reason=>'OK',content=>shift(@{$s->{bodies}})//'<title>Spotify</title>'};
    }
    package MB905::Bot;
    sub getLoop {$_[0]{loop}}
}
my $title = 'Aube Étoilée 🌙';
my $artist = 'Björk & Co';
my $album = 'Échos';
my $url = 'https://open.spotify.com/track/AbCdEfGhIjKlMnOpQrSt01';
sub _json {JSON::PP->new->utf8->canonical->ascii($_[1]//0)->encode($_[0])}
sub _next {
    my ($entity,$ascii)=@_;
    return '<script id="__NEXT_DATA__" type="application/json">'
        ._json({props=>{pageProps=>{state=>{data=>{entity=>$entity}}}}},$ascii).'</script>';
}
sub _ld {
    my ($entity,$ascii)=@_;
    return '<script type="application/ld+json">'._json($entity,$ascii).'</script>';
}
sub _specs {
    my $next={title=>$title,artists=>[{name=>$artist}],album=>{name=>$album},
        releaseDate=>{isoString=>'2022-11-04T00:00:00Z'},duration=>423387};
    my $ld={name=>$title,byArtist=>{name=>$artist},inAlbum=>{name=>$album},
        datePublished=>'2022-11-04',duration=>'PT7M3S'};
    my $empty=_json({title=>undef,author_name=>undef});
    my $shell='<title>Spotify</title>';
    my @specs;
    for my $ascii (0,1) {
        my $label=$ascii?'escaped':'literal';
        push @specs,
            ['oembed_'.$label,[_json({title=>$title,author_name=>$artist},$ascii),$shell],
                {type=>'track',title=>$title,artist=>$artist},2],
            ['next_'.$label,[$empty,_next($next,$ascii)],
                {type=>'track',title=>$title,artist=>$artist,album=>$album,year=>'2022',duration=>'7m 03s'},2],
            ['ld_'.$label,[$empty,_ld($ld,$ascii)],
                {type=>'track',title=>$title,artist=>$artist,album=>$album,year=>'2022',duration=>'7m 03s'},2],
            ['page_'.$label,[$empty,$shell,_ld($ld,$ascii)],
                {type=>'track',title=>$title,artist=>$artist,album=>$album,year=>'2022',duration=>'7m 03s'},3];
    }
    push @specs,
        ['oembed_bad_fields',[_json({title=>{},author_name=>[]}),_next($next,1)],
            {type=>'track',title=>$title,artist=>$artist,album=>$album,year=>'2022',duration=>'7m 03s'},2],
        ['next_bad_fields',[$empty,_next({title=>{},name=>'Recovered',artists=>[{},[],JSON::PP::true,{name=>'Valid'}],
            album=>{name=>{}},releaseDate=>{isoString=>'2022-01-01'},duration=>123000},1)],
            {type=>'track',title=>'Recovered',artist=>'Valid',album=>undef,year=>'2022',duration=>'2m 03s'},2],
        ['ld_bad_fields',[$empty,_ld({name=>'Recovered',byArtist=>[{name=>{}},[],JSON::PP::true,{name=>'Valid'}],
            inAlbum=>{name=>[]},duration=>'PT2M3S'},1)],
            {type=>'track',title=>'Recovered',artist=>'Valid',album=>undef,duration=>'2m 03s'},2],
        ['invalid_json', ['{bad json','<title>Spotify</title>','<title>Spotify</title>'],{type=>'track'},3];
    return \@specs;
}
sub _equal {JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1])}
sub _fetch {
    my ($bodies)=@_;
    no warnings 'redefine';
    my $http=bless {bodies=>[@$bodies],calls=>[]},'MB905::HTTP';
    local *Mediabot::External::_make_http=sub {$http};
    local *Mediabot::External::_fetch_url_chromium_dumpdom=sub {die 'Unexpected Chromium call'};
    my $bot=bless {logger=>bless({lines=>[]},'MB905::Log')},'MB905::Bot';
    my $info=Mediabot::External::Spotify::_spotify_fetch_sync($bot,$url,'track','AbCdEfGhIjKlMnOpQrSt01');
    return ($info,$http->{calls});
}
sub _native {
    my ($spec)=@_;
    my ($name,$bodies,$expected)=@$spec;
    my $loop=IO::Async::Loop->new;
    my $http=bless {bodies=>[@$bodies],calls=>[]},'MB905::HTTP';
    my @sent;
    my $bot=bless {loop=>$loop,logger=>bless({lines=>[]},'MB905::Log')},'MB905::Bot';
    no warnings 'redefine';
    local *Mediabot::External::_make_http=sub {$http};
    local *Mediabot::External::_fetch_url_chromium_dumpdom=sub {die 'Unexpected Chromium call'};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[$_[1],$_[2]];1};
    my $ret=Mediabot::External::_handle_spotify($bot,undef,'listener','#test',$url.'?si=fixture');
    my $deadline=Time::HiRes::time()+3;
    while (keys(%{$bot->{_spotify_pending}}) && Time::HiRes::time()<$deadline) {$loop->loop_once(0.01)}
    $loop->loop_once(0) for 1..2;
    my $display=@sent ? $sent[0][1] : '';
    $display=~s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $display=~s/[\x02\x0f\x16\x1d\x1f]//g;
    my $text="(listener) [Spotify] $expected->{title} - by $expected->{artist}";
    $text.=" - album $expected->{album}" if defined $expected->{album};
    $text.=" - $expected->{year}" if defined $expected->{year};
    $text.=" - $expected->{duration}" if defined $expected->{duration};
    return {case=>'native_'.$name,ok=>$ret && @sent==1 && $sent[0][0] eq '#test' && $display eq $text
        && !keys(%{$bot->{_spotify_pending}}) && !@{$http->{calls}}
        && join('',@{$bot->{logger}{lines}})!~/completion failed/ ? 1:0,
        display=>$display};
}
sub run_contracts {
    my @results;
    for my $spec (@{_specs()}) {
        my ($name,$bodies,$expected,$calls)=@$spec;
        my (@warnings,$ok,$error,$info,$seen);
        {local $SIG{__WARN__}=sub {push @warnings,@_};
         $ok=eval {($info,$seen)=_fetch($bodies);_equal($info,$expected) && @$seen==$calls
             && $seen->[0]=~m{/oembed\?} && $seen->[1]=~m{/embed/track/}}; $error=$@;}
        push @results,{case=>$name,ok=>$ok && !@warnings && !$error?1:0,
            (!$ok?(actual=>$info,requests=>$seen):()),(@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
    }
    {
        my %info=(type=>'track');
        my $bot=bless {logger=>bless({lines=>[]},'MB905::Log')},'MB905::Bot';
        my $raw=_next({title=>$title,artists=>[{name=>$artist}],duration=>123000},0);
        my (@warnings,$ok,$error);
        {local $SIG{__WARN__}=sub {push @warnings,@_};
         $ok=eval {
             Mediabot::External::Spotify::_spotify_extract_jsonish($bot,\%info,$raw,'raw-bytes');
             my $same=_equal(\%info,{type=>'track',title=>$title,artist=>$artist,duration=>'2m 03s'});
             my ($legacy)=_fetch([_json({title=>undef}),
                 '{"type":"track","name":"Fallback","artists":[{"name":"Studio"}],"album":{"cover":{"url":"https://example.test/img"},"name":"Record"}}']);
             $same && _equal($legacy,{type=>'track',title=>'Fallback',artist=>'Studio',album=>'Record'});
         };$error=$@;}
        push @results,{case=>'raw_byte_compatibility',ok=>$ok && !@warnings && !$error?1:0,
            (@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
    }
    for my $spec (@{_specs()}) {
        next unless $spec->[0]=~/^(?:oembed_literal|next_literal|ld_literal|next_escaped|oembed_bad_fields)$/;
        my (@warnings,$r);
        {local $SIG{__WARN__}=sub {push @warnings,@_};
         $r=eval {_native($spec)}; $r||={case=>'native_'.$spec->[0],ok=>0,error=>"$@"};}
        if (@warnings) {$r->{ok}=0;$r->{warnings}=\@warnings}
        push @results,$r;
    }
    return \@results;
}
1;
