package MB929AppleMusicFallbackFixture;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use DBI;
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::AppleMusicFallback ();
use Mediabot::ChannelCommands ();
use Mediabot::Context ();
use Mediabot::Channel ();
use Encode qw(encode);
{
    package MB929::Conf;sub get {$_[0]{$_[1]}}
    package MB929::Log;sub log {1}
    package MB929::Loop;sub add {1} sub remove {1} sub watch_process {1}
    package MB929::IRC;sub is_connected {$_[0]{connected}//1}
    package MB929::Bot;sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit}//0}
    package MB929::Runtime;sub capture_generation {$_[0]{generation}//1}
    package MB929::Principal;sub is_authenticated {$_[0]{auth}} sub id {1} sub has_level {$_[0]{admin}}
    package MB929::HTTP;
    sub request {my ($s,@args)=@_;push @{$s->{calls}},\@args;return $s->{request}->(@args)}
    sub get {my ($s,$url)=@_;push @{$s->{calls}},['GET',$url];return $s->{get}->($url)}
}
my $pkg='Mediabot::External::AppleMusicFallback';
my $apple='https://music.apple.com/fr/album/test/100?i=123';
my $spotify='https://open.spotify.com/track/0123456789ABCDEFGHIJKL';
my $youtube='https://www.youtube.com/watch?v=AbcDef01234';
sub json {JSON::PP->new->utf8->canonical->encode($_[0])}
sub copy {JSON::PP::decode_json(json($_[0]))}
sub fixture {
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $dbh->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE COLLATE NOCASE)');
    $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT UNIQUE COLLATE NOCASE)');
    $dbh->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $dbh->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    my $bot=bless({dbh=>$dbh,logger=>bless({},'MB929::Log'),loop=>bless({},'MB929::Loop'),
        conf=>bless({'tavily.API_KEY'=>'fake-search-key','main.YOUTUBE_APIKEY'=>'fake-video-key'},'MB929::Conf'),
        channels=>{'#test'=>Mediabot::Channel->new({dbh=>$dbh,id=>1,name=>'#test'})}},'MB929::Bot');
    return $bot;
}
sub enable {
    my ($bot,$channel)=@_;$channel//='#test';
    $pkg->can('register_chanset')->($bot);
    $bot->{dbh}->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT C.id_channel,L.id_chanset_list FROM CHANNEL C,CHANSET_LIST L WHERE C.name=? AND L.chanset=?',undef,$channel,'AppleMusicFallback');
}
sub metadata {{source=>'itunes-lookup',title=>'Nuit étoilée',details=>{artist=>'Björk 星',duration=>'3m 33s',type=>'song'}}}
sub record {$pkg->can('record')->(metadata(),{track_id=>123,storefront=>'fr'})}
sub command {
    my ($bot,$arg,$admin,$auth)=@_;
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#test',command=>'chanset',args=>[$arg]);
    $ctx->{user}=bless({admin=>$admin//1,auth=>$auth//1},'MB929::Principal');$ctx->{_user_fetched}=1;
    no warnings qw(redefine once);
    local *Mediabot::ChannelCommands::checkUserChannelLevel=sub {0};
    local *Mediabot::ChannelCommands::logBot=sub {1};
    local *Mediabot::ChannelCommands::botNotice=sub {1};
    return Mediabot::ChannelCommands::channelSet_ctx($ctx);
}
sub strip {my $s=$_[0];$s=~s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;$s=~s/[\x02\x0f\x16\x1d\x1f]//g;return $s}
sub provider {
    my (%a)=@_;my $bot=fixture();my @calls;my @options;my $n=0;
    delete $bot->{conf}{'main.YOUTUBE_APIKEY'} if $a{no_youtube};
    my $http=bless({calls=>\@calls,
        request=>sub {return {success=>0} if $a{http_error};return {success=>1,content=>$a{search_raw}//json({results=>$a{results}//[{url=>$spotify},{url=>$youtube}]})}},
        get=>sub {return {success=>1,content=>$a{videos_raw}//json({items=>$a{videos}//[{id=>'AbcDef01234',snippet=>{title=>'Nuit étoilée',channelTitle=>'Björk 星 - Topic'},contentDetails=>{duration=>'PT3M33S'}}]})}}},'MB929::HTTP');
    no warnings qw(redefine once);
    local *HTTP::Tiny::new=sub {my ($class,%opt)=@_;push @options,\%opt;return $http};
    local *Mediabot::External::Spotify::_spotify_fetch_sync=sub {$n++;return $a{spotify}//{title=>'Nuit étoilée',artist=>'Björk 星',duration=>'3m 33s'}};
    my $r=$pkg->can('fetch')->($bot,$a{record}//record(),$a{platform}//'spotify');
    return {urls=>$r,calls=>\@calls,options=>\@options,spotify_calls=>$n};
}
sub queue {
    my ($cb)=@_;my $bot=fixture();enable($bot);my (@jobs,@sent);
    no warnings qw(redefine once);
    local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;push @jobs,\%args;return bless({},'MB929::Worker')};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[@_[1..3]];1};
    return $cb->($bot,\@jobs,\@sent);
}
sub complete {my ($jobs)=@_;for my $j (@$jobs) {$j->{on_done}->({ok=>1,value=>[$j->{label}=~/spotify/?$spotify:$youtube]})}}
sub start {my ($b,$ch,$r)=@_;return $pkg->can('start')->($b,'Listener',$ch//'#test',$r//record())}
sub run_contracts {
    my @specs=(
        ['explicit authorized chanset, idempotence and immediate disable',sub {
            my $b=fixture();my @sql;$b->{dbh}->sqlite_trace(sub {push @sql,$_[0]});
            return 0 if $pkg->can('enabled')->($b,'#test');
            command($b,'+AppleMusicFallback',0,1);
            return 0 if $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST');
            command($b,'+AppleMusicFallback',1,0);
            return 0 if $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST');
            command($b,'+applemusicfallback');command($b,'+AppleMusicFallback');
            return 0 unless $pkg->can('enabled')->($b,'#TEST') && !$pkg->can('enabled')->($b,'#other');
            return 0 unless $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST')==1 && $pkg->can('epoch')->($b,'#test')==1;
            command($b,'-AppleMusicFallback');
            return !$pkg->can('enabled')->($b,'#test') && $pkg->can('epoch')->($b,'#test')==2 && !grep(/\A\s*(?:ALTER|CREATE|DROP|TRUNCATE)\b/i,@sql);
        }],
        ['missing catalogue, missing DB and failed SELECT never opt in',sub {
            my $b=fixture();my @sql;$b->{dbh}->sqlite_trace(sub {push @sql,$_[0]});
            my $ok=!$pkg->can('enabled')->($b,'#test') && !$pkg->can('enabled')->({},'#test');
            for my $v (undef,[],{},'Listener','#bad,other',"#bad\r\n") {$ok&&=!$pkg->can('enabled')->($b,$v)}
            $b->{dbh}->do('DROP TABLE CHANNEL_SET');
            return $ok && !$pkg->can('enabled')->($b,'#test') && !grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i,@sql);
        }],
        ['exact iTunes track only: album, incomplete, controls and references refused',sub {
            my $ok=record() && record()->{seconds}==213;
            for my $mut (sub {$_[0]{source}='page-fallback'},sub {$_[0]{source}=[]},sub {$_[0]{title}=[]},sub {$_[0]{title}="bad\r\ntext"},sub {$_[0]{details}{artist}={}},sub {$_[0]{details}{duration}=''},sub {$_[0]{details}{artist}='---'}) {
                my $m=metadata();$mut->($m);$ok&&=!$pkg->can('record')->($m,{track_id=>123,storefront=>'fr'});
            }
            return $ok && !$pkg->can('record')->(metadata(),{storefront=>'fr'});
        }],
        ['Spotify exact Unicode identity, canonical URL and request bounds',sub {
            my $r=provider();my $req=$r->{calls}[0];my $body=JSON::PP::decode_json($req->[2]{content});
            return @{$r->{urls}}==1 && $r->{urls}[0] eq $spotify && $r->{spotify_calls}==1
                && $req->[0] eq 'POST' && $req->[1] eq 'https://api.tavily.com/search'
                && $req->[2]{headers}{Authorization} eq 'Bearer fake-search-key'
                && $body->{include_domains}[0] eq 'open.spotify.com' && $body->{include_domains_mode} eq 'restrict'
                && $body->{search_depth} eq 'basic' && $body->{max_results}==3
                && !grep(!$_->{verify_SSL} || $_->{max_redirect}!=0 || $_->{max_size}!=524288,@{$r->{options}});
        }],
        ['Spotify rejects different artist, cover/live version and duration',sub {
            for my $m ({title=>'Nuit étoilée',artist=>'Other',duration=>'3m 33s'},
                {title=>'Nuit étoilée (Live)',artist=>'Björk 星',duration=>'3m 33s'},
                {title=>'Nuit étoilée',artist=>'Björk 星',duration=>'3m 37s'},
                {title=>[],artist=>'Björk 星',duration=>'3m 33s'}) {return 0 if @{provider(spotify=>$m)->{urls}}}
            return 1;
        }],
        ['Spotify tries at most two track candidates and ignores hostile URL results',sub {
            my @bad=map {{url=>$_}} ('https://open.spotify.com.evil/track/0123456789ABCDEFGHIJKL','https://open.spotify.com/album/0123456789ABCDEFGHIJKL',"$spotify\r\n",'http://127.0.0.1/');
            return 0 if provider(results=>\@bad)->{spotify_calls};
            my $r=provider(results=>[map {{url=>'https://open.spotify.com/track/'.($_ x 22)}} qw(a b c d)],spotify=>{title=>'Wrong',artist=>'Wrong',duration=>'3m 33s'});
            return $r->{spotify_calls}==2 && !@{$r->{urls}};
        }],
        ['YouTube official audio: exact title, Topic artist and duration',sub {
            my $r=provider(platform=>'youtube');
            return @{$r->{urls}}==1 && $r->{urls}[0] eq $youtube && @{$r->{calls}}==2
                && $r->{calls}[1][1]=~m{\Ahttps://www.googleapis.com/youtube/v3/videos\?id=AbcDef01234&key=fake-video-key&}
                && !grep($_->[1]=~/search\?/,@{$r->{calls}});
        }],
        ['YouTube version/artist/duration guards and official audio suffix',sub {
            for my $m (
                ['Nuit étoilée','Unrelated','PT3M33S'],['Björk 星 - Nuit étoilée (Live)','Björk 星','PT3M33S'],
                ['Nuit étoilée','Björk 星 - Topic','PT3M37S']) {
                my $r=provider(platform=>'youtube',videos=>[{id=>'AbcDef01234',snippet=>{title=>$m->[0],channelTitle=>$m->[1]},contentDetails=>{duration=>$m->[2]}}]);
                return 0 if @{$r->{urls}};
            }
            my $r=provider(platform=>'youtube',videos=>[{id=>'AbcDef01234',snippet=>{title=>'Björk 星 - Nuit étoilée (Official Audio)',channelTitle=>'Publisher'},contentDetails=>{duration=>'PT3M30S'}}]);
            return @{$r->{urls}}==1;
        }],
        ['provider errors, bad JSON, missing keys and malformed worker record stay silent',sub {
            for my $r (provider(search_raw=>'null'),provider(search_raw=>'{bad'),provider(http_error=>1),provider(platform=>'youtube',videos_raw=>'[]'),provider(platform=>'youtube',no_youtube=>1),provider(record=>{title=>[],artist=>'a',seconds=>3,key=>'x'})) {return 0 if @{$r->{urls}}}
            return !@{provider(platform=>'youtube',no_youtube=>1)->{calls}};
        }],
        ['same badges, transparent body and complete UTF-8 400-byte lines',sub {
            my $r=record();$r->{title}='星' x 180;
            for my $p (qw(spotify youtube)) {
                my $url=$p eq 'spotify'?$spotify:$youtube;my $line=$pkg->can('line')->($p,'Listener',$r,$url);
                my $badge=$p eq 'spotify'?Mediabot::External::Spotify::_spotify_badge():Mediabot::External::YouTube::_yt_label();
                return 0 unless defined($line) && index($line,"(Listener) $badge\x0f ")==0 && length(encode('UTF-8',$line))<=400
                    && $line=~/\Q$url\E\x0f\z/;
                my $body=substr($line,length("(Listener) $badge\x0f "));return 0 if $body=~/\x03|\x1f/;
            }
            return 1;
        }],
        ['off, no event loop or no search key starts no worker',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;command($b,'-AppleMusicFallback');start($b);enable($b);delete $b->{conf}{'tavily.API_KEY'};start($b);$b->{conf}{'tavily.API_KEY'}='x';delete $b->{loop};start($b);return !@$jobs && !@$sent});
        }],
        ['both providers async, one result each, duplicate completion ignored',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;start($b);return 0 unless @$jobs==2 && !@$sent;complete($jobs);complete($jobs);return @$sent==2 && !keys(%{$b->{_applemusic_fallback}{pending}}) && strip($sent->[0][1]) eq "(Listener) [Spotify] Björk 星 — Nuit étoilée · $spotify"});
        }],
        ['cache shared across channels; repeated paste in same channel deduplicated',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');start($b);start($b);complete($jobs);start($b,'#other');return @$jobs==2 && @$sent==4 && $sent->[2][0] eq '#other'});
        }],
        ['in-flight search coalesces independent recipients across channels',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');start($b);start($b,'#other');complete($jobs);return @$jobs==2 && @$sent==4});
        }],
        ['disable/re-enable revokes old epoch and keeps other recipients',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');start($b);start($b,'#other');command($b,'-AppleMusicFallback');command($b,'+AppleMusicFallback');complete($jobs);return @$sent==2 && !grep($_->[0] ne '#other',@$sent)});
        }],
        ['direct SQL disable, transport reconnect, quit and generation change revoke output',sub {
            for my $kind (qw(sql reconnect quit generation apple)) {
                my $ok=queue(sub {my ($b,$jobs,$sent)=@_;$b->{irc}=bless({},'MB929::IRC');$b->{wit_runtime_state}=bless({},'MB929::Runtime');start($b);
                    if ($kind eq 'sql') {$b->{dbh}->do('DELETE FROM CHANNEL_SET')}
                    elsif ($kind eq 'reconnect') {$b->{irc}=bless({},'MB929::IRC')}
                    elsif ($kind eq 'quit') {$b->{quit}=1}
                    elsif ($kind eq 'generation') {$b->{wit_runtime_state}{generation}=2}
                    else {$b->{dbh}->do("INSERT INTO CHANSET_LIST(chanset) VALUES('AppleMusic')")}
                    complete($jobs);return !@$sent;
                });return 0 unless $ok;
            }
            return 1;
        }],
        ['worker failures release ownership, reject malformed values and cache negative results',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');start($b);$jobs->[0]{on_done}->({ok=>0});$jobs->[1]{on_done}->({ok=>1,value=>['https://evil.invalid/']});start($b,'#other');return @$jobs==2 && !@$sent && !keys(%{$b->{_applemusic_fallback}{pending}})});
        }],
        ['worker launch exception releases all pending slots',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;no warnings 'redefine';local *Mediabot::AsyncWorker::start=sub {die "fixture launch failure\n"};start($b);return !keys(%{$b->{_applemusic_fallback}{pending}}) && !@$sent});
        }],
        ['bounded parallelism and minute launch budget',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;for my $i (1..20) {my $r=record();$r->{key}.=":$i";start($b,'#test',$r)}return 0 unless @$jobs==4;complete($jobs);for my $i (21..40) {my $r=record();$r->{key}.=":$i";start($b,'#test',$r);complete($jobs)}return @$jobs==12 && !keys(%{$b->{_applemusic_fallback}{pending}})});
        }],
        ['bounded recent-request map and TTL recovery',sub {
            return queue(sub {my ($b,$jobs,$sent)=@_;for my $i (1..400) {my $r=record();$r->{key}.=":$i";start($b,'#test',$r)}return 0 if keys(%{$b->{_applemusic_fallback}{recent}})>256;$_=time-31 for values %{$b->{_applemusic_fallback}{recent}};complete($jobs);my $r=record();$r->{key}.=':new';start($b,'#test',$r);return @$jobs==6 && keys(%{$b->{_applemusic_fallback}{recent}})==1});
        }],
    );
    push @specs,['original AppleMusic announce preserved; exact track adds two bound lookups',sub {
        my @lines;my @jobs;my $off=fixture();my $on=fixture();enable($on);
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @lines,[@_[1..2]];1};
        local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;return bless({},'MB929::Worker')};
        Mediabot::External::_handle_applemusic($off,undef,'Listener','#test',$apple);
        $jobs[0]{on_done}->({ok=>1,value=>metadata()});my $original=$lines[0][1];
        @jobs=();@lines=();Mediabot::External::_handle_applemusic($on,undef,'Listener','#test',$apple);
        return 0 unless @jobs==1 && !@lines;
        $jobs[0]{on_done}->({ok=>1,value=>metadata()});
        return 0 unless @jobs==3 && @lines==1 && $lines[0][1] eq $original;
        complete([@jobs[1,2]]);return @lines==3;
    }];
    push @specs,['original admission survives metadata delay: disable/re-enable cannot start fallback',sub {
        my $b=fixture();enable($b);my @jobs;my @lines;
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @lines,$_[2];1};
        local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;return bless({},'MB929::Worker')};
        Mediabot::External::_handle_applemusic($b,undef,'Listener','#test',$apple);
        command($b,'-AppleMusicFallback');command($b,'+AppleMusicFallback');
        $jobs[0]{on_done}->({ok=>1,value=>metadata()});return @jobs==1 && @lines==1;
    }];
    push @specs,['page/album metadata retains AppleMusic announcement without guessed matches',sub {
        my $b=fixture();enable($b);my @jobs;my @lines;
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @lines,$_[2];1};
        local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;return bless({},'MB929::Worker')};
        Mediabot::External::_handle_applemusic($b,undef,'Listener','#test',$apple);
        my $m=metadata();$m->{source}='page-fallback';$jobs[0]{on_done}->({ok=>1,value=>$m});return @jobs==1 && @lines==1;
    }];
    push @specs,['Apple metadata cache refreshes after opt-in and reaches both pending channels',sub {
        my $b=fixture();my (@jobs,@lines);
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @lines,[@_[1..2]];1};
        local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;return bless({},'MB929::Worker')};
        Mediabot::External::_handle_applemusic($b,undef,'Listener','#test',$apple);
        $jobs[0]{on_done}->({ok=>1,value=>metadata()});
        enable($b);enable($b,'#other');@jobs=();@lines=();
        Mediabot::External::_handle_applemusic($b,undef,'Listener','#test',$apple);
        Mediabot::External::_handle_applemusic($b,undef,'Listener','#other',$apple);
        return 0 unless @jobs==2 && !@lines;
        $jobs[0]{on_done}->({ok=>1,value=>metadata()});$jobs[1]{on_done}->({ok=>1,value=>metadata()});
        return 0 unless @jobs==4 && @lines==2;
        complete([@jobs[2,3]]);return @lines==6 && !keys(%{$b->{_applemusic_pending}});
    }];
    push @specs,['cache expiry and capacity, failed launches and independent provider result',sub {
        return queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');
            my $state=$b->{_applemusic_fallback}={cache=>{},pending=>{},recent=>{},starts=>[]};
            $state->{cache}{"old$_"}={until=>time+200,urls=>[]} for 1..128;
            start($b);$jobs->[0]{on_done}->({ok=>0});$jobs->[1]{on_done}->({ok=>1,value=>[$youtube]});
            return 0 unless @$sent==1 && keys(%{$state->{cache}})==128;
            $_->{until}=time-1 for values %{$state->{cache}};start($b,'#other');
            return 0 unless @$jobs==4 && !keys(%{$state->{cache}});
            complete($jobs);return @$sent==3 && !keys(%{$state->{pending}});
        });
    }];
    push @specs,['synchronous completion and undefined worker launches release pending slots',sub {
        for my $kind (0,1) {
            my $ok=queue(sub {my ($b,$jobs,$sent)=@_;
                no warnings 'redefine';local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;$a{on_done}->({ok=>1,value=>[$a{label}=~/spotify/?$spotify:$youtube]}) if $kind;return undef};
                start($b);return !keys(%{$b->{_applemusic_fallback}{pending}}) && @$sent==($kind?2:0);
            });return 0 unless $ok;
        }
        return 1;
    }];
    push @specs,['native IO::Async pipeline: three HTTP workers, no parent HTTP, delivery once and cleanup',sub {
        my $b=fixture();enable($b);$b->{loop}=IO::Async::Loop->new;
        my @sent;my $parent_http=0;my $parent=$$;
        my $response=sub {{success=>1,status=>200,content=>$_[0]}};
        my $http=bless({calls=>[],request=>sub {
            die "HTTP reached event loop" if $$==$parent;
            Time::HiRes::sleep(0.04);
            return $response->(json({results=>[{url=>$spotify},{url=>$youtube}]}));
        },get=>sub {
            my ($url)=@_;die "HTTP reached event loop" if $$==$parent;
            if ($url=~/itunes.apple.com/) {return $response->(json({results=>[{kind=>'song',trackId=>123,trackName=>'Nuit étoilée',artistName=>'Björk 星',trackTimeMillis=>213000}]}))}
            if ($url=~/googleapis.com/) {return $response->(json({items=>[{id=>'AbcDef01234',snippet=>{title=>'Nuit étoilée',channelTitle=>'Björk 星 - Topic'},contentDetails=>{duration=>'PT3M33S'}}]}))}
            if ($url=~/oembed/) {return $response->(json({}))}
            return $response->('<script id="__NEXT_DATA__" type="application/json">'.json({props=>{pageProps=>{state=>{data=>{entity=>{title=>'Nuit étoilée',artists=>[{name=>'Björk 星'}],duration=>213000}}}}}}).'</script>');
        }},'MB929::HTTP');
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @sent,$_[2];1};
        local *HTTP::Tiny::new=sub {$http};
        local *Mediabot::External::_make_http=sub {$http};
        my $begin=Time::HiRes::time();my $ok=Mediabot::External::_handle_applemusic($b,undef,'Listener','#test',$apple);
        my $elapsed=Time::HiRes::time()-$begin;
        my $until=Time::HiRes::time()+4;
        while ((keys(%{$b->{_applemusic_pending}}) || keys(%{$b->{_applemusic_fallback}{pending}//{}})) && Time::HiRes::time()<$until) {$b->{loop}->loop_once(0.01)}
        $b->{loop}->loop_once(0) for 1..4;
        return $ok && $elapsed<0.5 && !@{$http->{calls}} && @sent==3
            && strip($sent[0])=~/\[AppleMusic\]/ && grep(/\Q$spotify\E/,@sent) && grep(/\Q$youtube\E/,@sent)
            && !keys(%{$b->{_applemusic_pending}}) && !keys(%{$b->{_applemusic_fallback}{pending}});
    }];
    my @out;
    for my $s (@specs) {
        my (@warnings,$ok,$error);
        {local $SIG{__WARN__}=sub {push @warnings,@_};$ok=eval {$s->[1]->()};$error=$@;}
        push @out,{case=>$s->[0],ok=>$ok && !@warnings && !$error?1:0,(@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
    }
    return \@out;
}
1;
