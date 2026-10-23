package MB930RedditFixture;
use strict;
use warnings;
use utf8;
use JSON::PP ();
use DBI;
use Encode qw(encode decode);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::Reddit ();
use Mediabot::ChannelCommands ();
use Mediabot::Context ();
use Mediabot::Channel ();
{
    package MB930::Log;sub log {1}
    package MB930::Loop;sub add {1} sub remove {1} sub watch_process {1}
    package MB930::Bot;sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit}//0}
    package MB930::Principal;sub is_authenticated {$_[0]{auth}} sub id {1} sub has_level {$_[0]{admin}}
    package MB930::IRC;sub is_connected {$_[0]{connected}//1}
    package MB930::Runtime;sub capture_generation {$_[0]{generation}//1}
    package MB930::HTTP;sub request {my ($s,@a)=@_;push @{$s->{calls}},\@a;return $s->{response}->(@a)}
}
my $url='https://www.reddit.com/r/test/comments/abc123/a_title/';
my $title='Une aurore étoilée 🌌';
my $author='Astro_Test';
my $pkg='Mediabot::External::Reddit';
sub json {JSON::PP->new->utf8->canonical->encode($_[0])}
sub info {$pkg->can('url_info')->(@_ ? $_[0] : $url)}
sub copy {JSON::PP::decode_json(json($_[0]))}
sub fixture {
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $dbh->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE COLLATE NOCASE)');
    $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT UNIQUE COLLATE NOCASE)');
    $dbh->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $dbh->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    return bless({dbh=>$dbh,logger=>bless({},'MB930::Log'),loop=>bless({},'MB930::Loop'),
        channels=>{'#test'=>Mediabot::Channel->new({dbh=>$dbh,id=>1,name=>'#test'})}},'MB930::Bot');
}
sub enable {
    my ($b,$channel)=@_;$channel//='#test';$pkg->can('register_chanset')->($b);
    $b->{dbh}->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT C.id_channel,L.id_chanset_list FROM CHANNEL C,CHANSET_LIST L WHERE C.name=? AND L.chanset=?',undef,$channel,'Reddit');
}
sub command {
    my ($b,$arg,$admin,$auth,$level)=@_;
    my $ctx=Mediabot::Context->new(bot=>$b,nick=>'Operator',channel=>'#test',command=>'chanset',args=>[$arg]);
    $ctx->{user}=bless({admin=>$admin//1,auth=>$auth//1},'MB930::Principal');$ctx->{_user_fetched}=1;
    no warnings qw(redefine once);
    local *Mediabot::ChannelCommands::checkUserChannelLevel=sub {$level//0};
    local *Mediabot::ChannelCommands::logBot=sub {1};
    local *Mediabot::ChannelCommands::botNotice=sub {1};
    return Mediabot::ChannelCommands::channelSet_ctx($ctx);
}
sub embed {
    my (%a)=@_;
    my $link=$a{url}//$url;
    return json({provider_name=>'reddit',title=>$a{title}//$title,author_name=>$a{author}//$author,
        html=>$a{html}//qq{<blockquote class="reddit-embed-bq"><a href="$link">$title</a><br>by <a href="https://www.reddit.com/user/$author/">u/$author</a> in <a href="https://www.reddit.com/r/test/">test</a></blockquote><script src="https://embed.reddit.com/widgets.js"></script>}});
}
sub post_html {
    return qq{<head><meta property="og:title" content="$title"><meta property="og:url" content="$url"></head><body><shreddit-post id="t3_abc123" post-title="$title" author="$author" subreddit-prefixed-name="r/test" score="42" comment-count="7" nsfw spoiler></shreddit-post></body>};
}
sub fetch_with {
    my ($u,$cb)=@_;my (@calls,@opts);
    my $http=bless({calls=>\@calls,response=>$cb},'MB930::HTTP');
    no warnings qw(redefine once);
    local *HTTP::Tiny::new=sub {my ($class,%a)=@_;push @opts,\%a;return $http};
    my $r=$pkg->can('fetch')->($u);
    return ($r,\@calls,\@opts);
}
sub queue {
    my ($cb)=@_;my $b=fixture();enable($b);my (@jobs,@sent);
    no warnings qw(redefine once);
    local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;push @jobs,\%a;return bless({},'MB930::Worker')};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[@_[1..3]];1};
    return $cb->($b,\@jobs,\@sent);
}
sub handle {my ($b,$channel,$u,$nick)=@_;$pkg->can('handle')->($b,undef,$nick//'Listener',$channel//'#test',$u//$url)}
sub good {{state=>'ok',kind=>'post',title=>$title,author=>$author,subreddit=>'test'}}
sub complete {my ($jobs,$value)=@_;$_->{on_done}->({ok=>1,value=>$value//good()}) for @$jobs}
sub strip {$pkg->can('_plain')->($_[0],4096)}
sub run_contracts {
    my @specs=(
        ['all public URL families and canonical alias identity',sub {
            my @posts=($url,'http://old.reddit.com/r/TEST/comments/ABC123/slug/?utm_source=share','https://new.reddit.com/comments/abc123/slug','https://m.reddit.com/r/test/comments/abc123','https://fr.reddit.com/r/test/comments/abc123/slug','https://redd.it/abc123','https://www.reddit.com/gallery/abc123','https://www.reddit.com/t3_abc123','https://www.reddit.com/user/Astro_Test/comments/abc123/slug');
            for my $u (@posts) {my $i=info($u);return 0 unless $i && $i->{kind} eq 'post' && $i->{key} eq 'post:abc123'}
            for my $case (
                ['https://www.reddit.com/r/test/','community'],['https://www.reddit.com/user/Astro_Test','profile'],['https://www.reddit.com/u/Astro_Test','profile'],
                ['https://www.reddit.com/r/test/s/AbCdEf','share'],['https://reddit.app.link/AbCdEf?source=share','share'],
                ['https://www.reddit.com/media?url=https%3A%2F%2Fi.redd.it%2FAbC.JPG','image'],['https://i.redd.it/AbC.JPG','image'],['https://preview.redd.it/AbC.jpg?width=640&s=signature','image'],['https://external-preview.redd.it/AbC.jpg','image'],['https://v.redd.it/AbC','video'],
                ['https://www.redditmedia.com/r/test/comments/abc123/slug','post'],['https://www.reddit.com/search/?q=stars&utm_source=share','link']) {
                my $i=info($case->[0]);return 0 unless $i && $i->{kind} eq $case->[1];
            }
            return info('https://www.reddit.com/s/AbCd')->{key} ne info('https://www.reddit.com/s/abcd')->{key};
        }],
        ['comments from paths, query and fragments keep their own identity',sub {
            for my $u ($url.'def456/',$url.'?comment=def456',$url.'#t1_def456','https://redd.it/abc123?comment=def456') {my $i=info($u);return 0 unless $i && $i->{kind} eq 'comment' && $i->{key} eq 'comment:abc123:def456'}
            return !info($url.'def456/?comment=other') && !info($url.'?comment=def456&comment=another') && info($url.'?utm_source=x')->{url} eq info()->{url};
        }],
        ['host spoofing, credentials, bad ports, controls and ambiguous paths refused',sub {
            for my $u ('https://reddit.com.evil/r/test','https://evilreddit.com/r/test','https://example.test/?url=https://reddit.com/r/test','file://reddit.com/r/test',
                'https://user:password@reddit.com/r/test','https://reddit.com:4430/r/test','https://reddit.com:evil/r/test',"https://reddit.com/r/test\r\n",
                'https://reddit.com/r/../login','https://reddit.com/r/%2e%2e/login','https://reddit.com/r/test%0d%0a','https://reddit.com/r/test/comments/bad!/slug','https://reddit.com/media?url=https%3A%2F%2Fevil.invalid%2Fpicture.jpg',[],undef) {return 0 if info($u)}
            return 1;
        }],
        ['authorized explicit +Reddit: registration, case, idempotence and disable',sub {
            my $b=fixture();my @sql;$b->{dbh}->sqlite_trace(sub {push @sql,$_[0]});
            command($b,'+Reddit',0,1);command($b,'+Reddit',1,0);
            return 0 if $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST');
            command($b,'+reddit',0,1,1);command($b,'+Reddit');
            return 0 unless $pkg->can('enabled')->($b,'#TEST') && !$pkg->can('enabled')->($b,'#other') && $pkg->can('epoch')->($b,'#test')==1;
            return 0 unless $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST')==1;
            command($b,'-Reddit');return !$pkg->can('enabled')->($b,'#test') && $pkg->can('epoch')->($b,'#test')==2 && !grep(/\A\s*(?:CREATE|ALTER|DROP|TRUNCATE)\b/i,@sql);
        }],
        ['missing catalogue and SQL failure never opt in',sub {
            my $b=fixture();return 0 if $pkg->can('enabled')->($b,'#test') || $pkg->can('enabled')->({},'#test');
            for my $c (undef,[],'Listener','#bad,other') {return 0 if $pkg->can('enabled')->($b,$c)}
            $b->{dbh}->do('DROP TABLE CHANNEL_SET');return !$pkg->can('enabled')->($b,'#test');
        }],
        ['public oEmbed title, author and community decoded as UTF-8 once',sub {
            for my $payload (embed(),decode('UTF-8',embed()),json(JSON::PP::decode_json(embed()))) {
                my $r=$pkg->can('parse_oembed')->($payload,info());
                return 0 unless $r && $r->{title} eq $title && $r->{author} eq $author && $r->{subreddit} eq 'test';
            }
            return 1;
        }],
        ['comment text and attribution resist quoted user/community links',sub {
            my $u=$url.'def456/';my $html=qq{<blockquote><p>Quelle étoile ! <a href="https://reddit.com/user/SomeoneElse">u/SomeoneElse</a> <a href="https://reddit.com/r/wrong">r/wrong</a></p><a href="$u">Comment</a><a href="$url">parent</a></blockquote>};
            my $r=$pkg->can('parse_oembed')->(embed(url=>$u,html=>$html),info($u));
            return 0 unless $r && $r->{kind} eq 'comment' && $r->{title}=~/Quelle étoile/ && $r->{author} eq $author && $r->{subreddit} eq 'test';
            $r=$pkg->can('parse_oembed')->(embed(url=>$u,html=>qq{<blockquote><a href="$u">Comment</a><a href="$url"></a></blockquote>}),info($u));
            return $r && $r->{context_only} && strip($pkg->can('render')->('Listener',info($u),$r))=~/Commentaire sur « \Q$title\E »/;
        }],
        ['wrong post, parent-only comment, malformed JSON/leaves and deleted comments rejected',sub {
            return 0 if $pkg->can('parse_oembed')->(embed(url=>'https://reddit.com/comments/other/'),info());
            return 0 if $pkg->can('parse_oembed')->(embed(),info($url.'def456/'));
            for my $payload ('{bad','null','[]',json({provider_name=>[],html=>{}}),json({provider_name=>'reddit',title=>[],html=>[]})) {return 0 if $pkg->can('parse_oembed')->($payload,info())}
            my $u=$url.'def456/';my $r=$pkg->can('parse_oembed')->(embed(url=>$u,html=>qq{<blockquote><p>[deleted]</p><a href="$u">Comment</a></blockquote>}),info($u));
            return $r && $r->{state} eq 'missing';
        }],
        ['public HTML metadata bound to the exact post and includes available labels/counts',sub {
            my $r=$pkg->can('parse_html')->(post_html(),info());
            return $r && $r->{title} eq $title && $r->{subreddit} eq 'test' && $r->{author} eq $author && $r->{score}==42 && $r->{comments}==7 && $r->{nsfw} && $r->{spoiler};
        }],
        ['community/profile pages do not borrow titles or counts from their feed',sub {
            for my $u ('https://reddit.com/r/test/','https://reddit.com/user/Astro_Test/') {
                my $html=post_html();$html=~s/\Q$title\E/Community header/;
                my $r=$pkg->can('parse_html')->($html,info($u));return 0 unless $r && $r->{title} eq 'Community header' && !defined($r->{score}) && !defined($r->{comments});
            }
            return 1;
        }],
        ['HTML parent post and security/login shells never impersonate a comment preview',sub {
            return 0 if $pkg->can('parse_html')->(post_html(),info($url.'def456/'));
            for my $s ('Reddit - Dive into anything','Access Denied','You have been blocked by network security','Log in to Reddit') {return 0 if $pkg->can('parse_html')->("<title>$s</title>",info())}
            my $html=post_html();$html=~s/abc123/other/g;return !$pkg->can('parse_html')->($html,info());
        }],
        ['one bounded public oEmbed request, truthful agent and no credentials/API scraping',sub {
            for my $u ('https://redd.it/abc123','https://reddit.com/gallery/abc123','https://reddit.com/comments/abc123/','https://reddit.com/user/Astro_Test/comments/abc123/slug') {
                my ($v,$requests)=fetch_with($u,sub {{success=>1,status=>200,content=>embed()}});
                return 0 unless $v->{state} eq 'ok' && $v->{subreddit} eq 'test' && @$requests==1;
                my $request=URI->new($requests->[0][1]);my %q=$request->query_form;
                return 0 unless $q{url} eq 'https://www.reddit.com/r/all/comments/abc123/';
            }
            my ($r,$calls,$opts)=fetch_with($url,sub {{success=>1,status=>200,content=>embed()}});
            return $r->{state} eq 'ok' && @$calls==1 && $calls->[0][0] eq 'GET' && $calls->[0][1]=~m{\Ahttps://www.reddit.com/oembed\?}
                && $calls->[0][1]!~/\.json|oauth/ && !exists($calls->[0][2]{headers}{Authorization})
                && $opts->[0]{verify_SSL} && $opts->[0]{max_redirect}==0 && $opts->[0]{max_size}==524288 && $opts->[0]{agent}=~/Mediabot-RedditPreview/;
        }],
        ['share links follow only Reddit hosts and resolve the exact post',sub {
            my $step=0;my ($r,$calls)=fetch_with('https://www.reddit.com/r/test/s/Token',sub {
                $step++;return {success=>0,status=>302,headers=>{location=>$url}} if $step==1;
                return {success=>1,status=>200,content=>post_html()};
            });
            return $r->{state} eq 'ok' && $r->{title} eq $title && $r->{score}==42 && @$calls==2;
        }],
        ['foreign/private/looping redirects and login pages are not bypassed',sub {
            for my $location ('https://evil.invalid/','http://127.0.0.1/','https://user:pass@reddit.com/r/test/','/r/test/s/Token') {
                my ($r,$calls)=fetch_with('https://reddit.com/r/test/s/Token',sub {{status=>302,success=>0,headers=>{location=>$location}}});
                return 0 unless $r->{state} eq 'unavailable' && @$calls<=3 && !grep($_->[1]=~/evil\.invalid|127\.0\.0\.1/,@$calls);
            }
            my ($r,$calls)=fetch_with('https://reddit.com/login?token=private',sub {die 'must not fetch login'});return $r->{state} eq 'unavailable' && !@$calls;
        }],
        ['media previews use HEAD and never download a binary image/video',sub {
            for my $u ('https://i.redd.it/Picture.JPG','https://v.redd.it/VideoId') {
                my ($r,$calls)=fetch_with($u,sub {{success=>1,status=>200,headers=>{'content-type'=>$u=~/i\.redd/?'image/jpeg':'video/mp4'}}});
                return 0 unless $r->{state} eq 'ok' && $r->{media} && @$calls==1 && $calls->[0][0] eq 'HEAD';
            }
            return 1;
        }],
        ['HTTP failures map to concise states without retries through alternate services',sub {
            for my $case ([403,'restricted'],[404,'missing'],[429,'busy'],[500,'unavailable']) {
                my ($r,$calls)=fetch_with($url,sub {{success=>0,status=>$case->[0],headers=>{'retry-after'=>'17'}}});
                return 0 unless $r->{state} eq $case->[1] && @$calls==1;
                return 0 if $case->[0]==429 && $r->{backoff}!=17;
            }
            my ($r)=fetch_with($url,sub {{success=>0,status=>429,headers=>{'retry-after'=>'invalid'}}});return $r->{backoff}==60;
        }],
        ['classy badge, theme-neutral body, balanced formatting and <=400 UTF-8 bytes',sub {
            return 0 unless $pkg->can('badge')->() eq "\x0301,07 reddit \x0f";
            my $r=good();$r->{title}='星🌌' x 500;$r->{score}=42;$r->{comments}=7;$r->{nsfw}=1;
            my $s=$pkg->can('render')->('É'x80,info(),$r);
            return length(encode('UTF-8',$s))<=400 && $s=~/\x0f\z/ && $s=~/…/ && $s=~/NSFW/
                && $s=~/\x02[^\x02]+\x02/ && $s!~/\x03.*\x03/s;
        }],
        ['metadata cannot inject IRC colours, controls, HTML or reference addresses',sub {
            my $r=good();$r->{title}="<b>A&amp;B</b>\r\n\x0304,01test\x0f";
            my $s=$pkg->can('render')->('Listener',info(),$r);my $plain=strip($s);
            return 0 unless $plain=~/A&B test/ && $plain!~/<b>|ARRAY|HASH|\r|\n/;
            for my $bad ({state=>'ok',title=>[]},{state=>'ok',title=>{}},{state=>[]},{state=>'ok',title=>'Reddit - Dive into anything'}) {
                my $out=$pkg->can('render')->('Listener',info(),$bad);return 0 unless strip($out)=~/aperçu indisponible/;
            }
            return 1;
        }],
        ['router +Reddit gate is independent and disabled URLs do not burn cache',sub {
            my $b=fixture();my $generic=0;my @jobs;
            no warnings qw(redefine once);
            local *Mediabot::External::_chanset_ok=sub {1};
            local *Mediabot::External::URL::_handle_generic_title=sub {$generic++;1};
            local *Mediabot::AsyncWorker::start=sub {my ($c,%a)=@_;push @jobs,\%a;return bless({},'MB930::Worker')};
            Mediabot::External::displayUrlTitle($b,undef,'Listener','#test',$url);
            return 0 if @jobs || $generic || keys(%{$b->{_url_display_cache}//{}});
            enable($b);Mediabot::External::displayUrlTitle($b,undef,'Listener','#test',$url);
            Mediabot::External::displayUrlTitle($b,undef,'Listener','#test','https://example.test/');
            return @jobs==1 && $generic==1;
        }],
        ['normal handler is asynchronous and completes only once',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;handle($b);return 0 unless @$jobs==1 && !@$sent;complete($jobs);complete($jobs);return @$sent==1 && !keys(%{$b->{_reddit_preview}{pending}}) && strip($sent->[0][1]) eq "(Listener) reddit $title · r/test · u/$author"});
        }],
        ['aliases deduplicate per channel; cache is shared across channels',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');handle($b);handle($b,'#test','https://redd.it/abc123');complete($jobs);handle($b,'#other');return @$jobs==1 && @$sent==2 && $sent->[1][0] eq '#other'});
        }],
        ['pending lookups coalesce separately bound channel recipients',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');handle($b);handle($b,'#other',undef,'OtherListener');complete($jobs);return @$jobs==1 && @$sent==2 && strip($sent->[1][1])=~/\A\(OtherListener\)/});
        }],
        ['disable/re-enable revokes old work while other recipients survive',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;enable($b,'#other');handle($b);handle($b,'#other');command($b,'-Reddit');command($b,'+Reddit');complete($jobs);return @$sent==1 && $sent->[0][0] eq '#other'});
        }],
        ['SQL disable, reconnect, disconnected transport, quit and generation changes revoke output',sub {
            for my $kind (qw(sql reconnect disconnected quit generation)) {
                my $ok=queue(sub {my ($b,$jobs,$sent)=@_;$b->{irc}=bless({},'MB930::IRC');$b->{wit_runtime_state}=bless({},'MB930::Runtime');handle($b);
                    if ($kind eq 'sql') {$b->{dbh}->do('DELETE FROM CHANNEL_SET')}
                    elsif ($kind eq 'reconnect') {$b->{irc}=bless({},'MB930::IRC')}
                    elsif ($kind eq 'disconnected') {$b->{irc}{connected}=0}
                    elsif ($kind eq 'quit') {$b->{quit}=1}
                    else {$b->{wit_runtime_state}{generation}=2}
                    complete($jobs);return !@$sent;
                });return 0 unless $ok;
            }
            return 1;
        }],
        ['worker failure and malformed boundary values produce one bounded unavailable preview',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;handle($b);$jobs->[0]{on_done}->({ok=>1,value=>{state=>'ok',title=>[]}});$jobs->[0]{on_done}->({ok=>0});return @$sent==1 && strip($sent->[0][1])=~/aperçu indisponible/ && !keys(%{$b->{_reddit_preview}{pending}})});
        }],
        ['launch throw, undefined return and synchronous callbacks clean up correctly',sub {
            for my $kind (qw(throw undef synchronous)) {
                my $ok=queue(sub {my ($b,$jobs,$sent)=@_;no warnings 'redefine';local *Mediabot::AsyncWorker::start=sub {my ($c,%a)=@_;die "fixture launch error\n" if $kind eq 'throw';$a{on_done}->({ok=>1,value=>good()}) if $kind eq 'synchronous';return undef};handle($b);return @$sent==1 && !keys(%{$b->{_reddit_preview}{pending}})});return 0 unless $ok;
            }
            return 1;
        }],
        ['no loop/off gate starts no worker; resource limit does not consume a rejected URL',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;delete $b->{loop};handle($b);return 0 if @$jobs;$b->{loop}=bless({},'MB930::Loop');for my $n (1..5) {handle($b,'#test',"https://redd.it/test$n")}
                return 0 unless @$jobs==4 && !exists($b->{_reddit_preview}{recent}{"#test\0post:test5"});complete($jobs);handle($b,'#test','https://redd.it/test5');return @$jobs==5;
            });
        }],
        ['minute budget, cache expiration/capacity and recent-map bound',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;
                for my $n (1..30) {handle($b,'#test',"https://redd.it/id$n");complete($jobs)}
                return 0 unless @$jobs==12;
                my $s=$b->{_reddit_preview};$s->{starts}=[];$s->{recent}={};$s->{cache}={};
                $s->{cache}{"old$_"}={until=>time+5,value=>good()} for 1..128;
                handle($b,'#test','https://redd.it/new1');complete($jobs);return 0 unless keys(%{$s->{cache}})==128;
                $_->{until}=time-1 for values %{$s->{cache}};$s->{recent}={map {("key$_",time)} (1..512)};
                return 0 if handle($b,'#test','https://redd.it/new2');
                $_=time-301 for values %{$s->{recent}};handle($b,'#test','https://redd.it/new2');return @$jobs==14 && !keys(%{$s->{cache}});
            });
        }],
        ['429 backoff prevents further HTTP workers while preserving one concise response',sub {
            queue(sub {my ($b,$jobs,$sent)=@_;handle($b);complete($jobs,{state=>'busy',backoff=>60});handle($b,'#test','https://redd.it/other');return @$jobs==1 && @$sent==2 && strip($sent->[1][1])=~/temporairement indisponible/ && $b->{_reddit_preview}{blocked_until}>time});
        }],
        ['native IO::Async worker: real parser path, no parent HTTP, completion and reaping',sub {
            my $b=fixture();enable($b);$b->{loop}=IO::Async::Loop->new;my (@sent,@workers);my $parent=$$;
            my $http=bless({calls=>[],response=>sub {die 'parent HTTP' if $$==$parent;Time::HiRes::sleep(0.04);return {success=>1,status=>200,content=>embed()}}},'MB930::HTTP');
            no warnings qw(redefine once);
            local *Mediabot::Helpers::botPrivmsg=sub {push @sent,$_[2];1};local *HTTP::Tiny::new=sub {$http};
            my $real=Mediabot::AsyncWorker->can('start');local *Mediabot::AsyncWorker::start=sub {my $w=$real->(@_);push @workers,$w;return $w};
            my $begin=Time::HiRes::time();my $ok=handle($b);my $elapsed=Time::HiRes::time()-$begin;
            my $end=Time::HiRes::time()+4;while (keys(%{$b->{_reddit_preview}{pending}}) && Time::HiRes::time()<$end) {$b->{loop}->loop_once(0.01)}
            $b->{loop}->loop_once(0) for 1..4;
            return $ok && $elapsed<0.5 && @sent==1 && strip($sent[0])=~/\Q$title\E/ && !@{$http->{calls}} && !keys(%{$b->{_reddit_preview}{pending}}) && $workers[0]{finalized};
        }],
    );
    push @specs,['pending recipient list is bounded without losing admitted channels',sub {
        queue(sub {my ($b,$jobs,$sent)=@_;handle($b);
            for my $n (1..17) {$b->{dbh}->do('INSERT INTO CHANNEL VALUES(?,?)',undef,$n+2,"#c$n");enable($b,"#c$n");handle($b,"#c$n")}
            return 0 unless @$jobs==1 && @{$b->{_reddit_preview}{pending}{'post:abc123'}{send}}==16;
            complete($jobs);return @$sent==16 && !grep($_->[0] eq '#c16' || $_->[0] eq '#c17',@$sent);
        });
    }];
    push @specs,['native timeout reaps the child and releases stream/timers/pending ownership',sub {
        my $b=fixture();enable($b);$b->{loop}=IO::Async::Loop->new;my (@sent,@workers);
        my $http=bless({calls=>[],response=>sub {Time::HiRes::sleep(5);return {success=>1,status=>200,content=>embed()}}},'MB930::HTTP');
        no warnings qw(redefine once);
        local *Mediabot::Helpers::botPrivmsg=sub {push @sent,$_[2];1};local *HTTP::Tiny::new=sub {$http};
        my $real=Mediabot::AsyncWorker->can('start');local *Mediabot::AsyncWorker::start=sub {my ($class,%a)=@_;$a{timeout}=0.05;my $w=$real->($class,%a);push @workers,$w;return $w};
        handle($b);my $end=Time::HiRes::time()+3;
        while (keys(%{$b->{_reddit_preview}{pending}}) && Time::HiRes::time()<$end) {$b->{loop}->loop_once(0.01)}
        $b->{loop}->loop_once(0) for 1..4;
        my $w=$workers[0];
        return @sent==1 && strip($sent[0])=~/aperçu indisponible/ && !keys(%{$b->{_reddit_preview}{pending}})
            && $w->{finalized} && $w->{child_done} && !$w->{stream} && !$w->{timeout_timer} && !$w->{kill_timer};
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
