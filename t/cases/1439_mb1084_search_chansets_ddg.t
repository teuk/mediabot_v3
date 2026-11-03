use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use JSON::PP;
use Encode qw(encode decode);
use File::Temp qw(tempdir);
use IO::Async::Loop;
use Time::HiRes ();
use URI;
use Mediabot::Mediabot;
use Mediabot::Channel;
use Mediabot::ChannelCommands ();
use Mediabot::Context;
use Mediabot::External::DuckDuckGo ();
use Mediabot::External::Chromium ();
use Mediabot::External::SearchCommand ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

{
    package MB1084::Conf;sub get {$_[0]{$_[1]}}
    package MB1084::Log;sub log {1}
    package MB1084::IRC;sub is_connected {1}
    package MB1084::Loop;sub add {1}sub remove {1}sub watch_process {1}
    package MB1084::User;sub is_authenticated {$_[0]{auth}}sub has_level {$_[0]{admin}}sub id {1}
    package MB1084::Bot;
    our @ISA=('Mediabot');
    sub getLoop {$_[0]{loop}}sub getQuit {0}
    sub botPrivmsg {push @{$_[0]{sent}},['public',$_[1],$_[2],$$];1}
    sub botNotice {push @{$_[0]{sent}},['private',$_[1],$_[2],$$];1}
    package MB1084::HTTP;
    sub record {
        my ($s,$method,$url,$target)=@_;my $row={pid=>$$,method=>$method,url=>$url,target=>$target};
        push @{$s->{calls}},$row;
        if ($s->{trace}) {open my $fh,'>>:raw',$s->{trace} or die $!;print {$fh} JSON::PP::encode_json($row)."\n";close $fh or die $!}
    }
    sub get {
        my ($s,$url)=@_;$s->record('GET',$url);
        if ($url=~m{\Ahttps://api\.duckduckgo\.com/}) {
            return $s->{instant_response} if $s->{instant_response};
            return $s->{instant} ? {success=>1,status=>202,content=>JSON::PP->new->utf8->encode($s->{instant})}
                : {success=>0,status=>503};
        }
        return $s->{response}//{success=>1,status=>200,content=>Encode::encode('UTF-8',$s->{html})};
    }
    sub request {
        my ($s,$method,$url,$options)=@_;my $body=JSON::PP::decode_json($options->{content});
        $s->record($method,$url,$body->{url});my $id=chr(64+(++$s->{serial})).'bcdef23';
        return {success=>0,status=>503} if $s->{short_fail};
        return {success=>1,status=>201,content=>JSON::PP::encode_json({protocol=>1,id=>$id,url=>$body->{url},short_url=>'https://teuk.org/shorturl/'.$id})};
    }
    package MB1084::BrokenDB;sub prepare {die 'fixture read failed'}
    package MB1084::ReadDB;sub prepare {$_[0]{statement}}
    package MB1084::Statement;
    sub execute {1}
    sub fetchrow_arrayref {die 'fixture fetch failed' if $_[0]{throw};$_[0]{row}}
    sub err {$_[0]{error}}
    sub finish {$_[0]{finished}++;1}
}
my $P='Mediabot::External::SearchCommand';my $D='Mediabot::External::DuckDuckGo';
no warnings qw(redefine once);
local *Mediabot::ChannelCommands::checkUserChannelLevel=sub {0};
local *Mediabot::ChannelCommands::logBot=sub {1};
local *Mediabot::ChannelCommands::botNotice=sub {1};
sub bot1084 {
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE COLLATE NOCASE)');
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT UNIQUE COLLATE NOCASE)');
    $db->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $db->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    return bless {dbh=>$db,logger=>bless({},'MB1084::Log'),loop=>bless({},'MB1084::Loop'),
        irc=>bless({},'MB1084::IRC'),sent=>[],command_registry=>Mediabot::CommandRegistry->new,
        conf=>bless({'main.LANG'=>'fr','shorturl.API_URL'=>'https://teuk.org/shorturl/api/v1/links',
            'shorturl.PUBLIC_BASE_URL'=>'https://teuk.org/shorturl/','shorturl.API_KEY'=>('a'x64)},'MB1084::Conf'),
        channels=>{'#test'=>Mediabot::Channel->new({dbh=>$db,id=>1,name=>'#test'})}},'MB1084::Bot';
}
sub ctx1084 {my ($b,$cmd,@args)=@_;return Mediabot::Context->new(bot=>$b,nick=>'Reader',channel=>'#test',command=>$cmd,args=>\@args)}
sub set1084 {
    my ($b,$flag,$admin,$auth)=@_;my $ctx=ctx1084($b,'chanset',$flag);
    $ctx->{user}=bless {admin=>$admin//1,auth=>$auth//1},'MB1084::User';$ctx->{_user_fetched}=1;
    Mediabot::ChannelCommands::channelSet_ctx($ctx);
}
my $html=<<'HTML';
<html><body>
<a href="https://nav.example.org/">navigation</a>
<div class="result result--ad"><a class="result__a" href="https://ads.example.org/">advertisement</a></div>
<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.debian.org%2F&amp;rut=tracking">Debian &amp; café</a><a class="result__snippet">Le système <b>libre</b> 🌀.</a></div>
<div class="result"><a class="result__a" href="https://www.debian.org/">duplicate</a></div>
<div class="result"><a class="result__a" href="javascript:alert(1)">bad</a></div>
<div class="result"><a class="result__a" href="https://wiki.debian.org/Debian13">Debian 13</a><span class="result__snippet">La documentation.</span></div>
<div class="result"><a class="result__a" href="https://third.example.org/">third</a><span class="result__snippet">Troisième résultat.</span></div>
<div class="result"><a class="result__a" href="https://fourth.example.org/">fourth</a></div>
</body></html>
HTML
{
    my $b=bot1084();my @sql;$b->{dbh}->sqlite_trace(sub {push @sql,$_[0]});
    set1084($b,'+Wikipedia',0,1);set1084($b,'+ddg',1,0);
    my $before=$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST');
    set1084($b,'+wIkIpEdIa');set1084($b,'+DDG');set1084($b,'+ddg');
    my @on=map {$P->can('enabled')->($b,'#TEST',$_)} ('Wikipedia','ddg');
    set1084($b,'-WIKIPEDIA');
    is_deeply([$before,\@on,$P->can('enabled')->($b,'#test','Wikipedia'),$P->can('enabled')->($b,'#test','ddg'),
        $P->can('enabled')->($b,'#other','ddg'),$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST'),
        $P->can('epoch')->($b,'#test','ddg'),scalar(grep {/\A\s*(?:CREATE|ALTER|DROP|TRUNCATE)\b/i} @sql)],
        [0,[1,1],0,1,0,2,1,0],
        'real authorized chanset registers both canonical rows once, independently by channel, with no DDL or writes by unauthorized users');
}
{
    my $b=bot1084();my $starts=0;
    local *Mediabot::AsyncWorker::start=sub {$starts++;die 'unexpected worker'};
    Mediabot::External::Wikipedia::mbWikipedia_ctx(ctx1084($b,'wikipedia','test'));
    $D->can('mbDDG_ctx')->(ctx1084($b,'ddg','test'));
    my $broken=bless {dbh=>bless({},'MB1084::BrokenDB')},'MB1084::Bot';
    my @reads;
    for my $case ({row=>[7],error=>1},{row=>[]},{row=>['invalid']},{row=>[7],throw=>1}) {
        my $statement=bless $case,'MB1084::Statement';
        my $probe=bless {dbh=>bless({statement=>$statement},'MB1084::ReadDB')},'MB1084::Bot';
        push @reads,[$P->can('enabled')->($probe,'#test','ddg'),$statement->{finished}//0];
    }
    is_deeply([$starts,scalar(@{$b->{sent}}),$P->can('enabled')->($broken,'#test','ddg'),
        $P->can('enabled')->($b,'#test','foreign'),defined($P->can('register_chanset')->($b,'foreign'))?1:0,\@reads],
        [0,0,0,0,0,[[0,1],[0,1],[0,1],[0,1]]], 'both searches default off; absent, failed or malformed policy reads finish without launching work, and unknown names cannot create rows');
}
{
    my @observed;
    for my $name ('Wikipedia','ddg') {
        my $b=bot1084();set1084($b,'+'.$name);my $job;
        local *Mediabot::AsyncWorker::start=sub {my ($c,%args)=@_;$job=\%args;bless {},'MB1084::Worker'};
        my $ctx=ctx1084($b,lc($name),'test');
        $name eq 'Wikipedia'?Mediabot::External::Wikipedia::mbWikipedia_ctx($ctx):$D->can('mbDDG_ctx')->($ctx);
        set1084($b,'-'.$name);set1084($b,'+'.$name);
        $job->{on_done}->({ok=>1,value=>{message=>'stale',state=>'ok',hits=>[{title=>'stale',url=>'https://example.org/'}]}});
        push @observed,[scalar(@{$b->{sent}}),scalar(keys %{$b->{'_'.lc($name).'_pending'}}),$job->{term_grace},$job->{force_grace}];
    }
    is_deeply(\@observed,[[0,0,0.2,1],[0,0,18,19]], 'disable then re-enable revokes both old attempts even though the flag is on again, and releases their capacity');
}

# Modern wrappers deliberately have no .result class or article tag.
my $modern=<<'HTML';
<html><body><main><section>
<div><div><a data-testid="result-title-a" href="https://duckduckgo.com/y.js?ad_domain=ads.example.org&amp;u3=https%3A%2F%2Fwww.bing.com%2Faclick">Paid training</a></div><div data-result="snippet">AD EXCERPT</div></div>
<div><div><a data-testid="result-title-a" href="https://www.linux.org/pages/download/">Download Linux</a></div><div data-testid="result-snippet"><span>Linux downloads.</span></div><a data-testid="result-title-a" href="https://www.linux.org/pages/download/">mobile duplicate</a></div>
<div><div><a data-testid="result-title-a" href="https://fr.wikipedia.org/wiki/Linux">Linux — Wikipédia</a></div><div data-result="snippet">Le système Linux.</div></div>
<div><a data-testid="result-title-a" href="https://missing.example.org/">No snippet</a></div>
<div><div><a data-testid="result-title-a" href="https://kernel.org/">The Linux Kernel Archives</a></div><div class="result-snippet">The Linux kernel.</div></div>
<div><a data-testid="result-title-a" href="https://fourth.example.org/">fourth</a><div data-result="snippet">Fourth excerpt.</div></div>
</section></main></body></html>
HTML
my @modern_hits=(
    {title=>'Download Linux',excerpt=>'Linux downloads.',url=>'https://www.linux.org/pages/download/'},
    {title=>'Linux — Wikipédia',excerpt=>'Le système Linux.',url=>'https://fr.wikipedia.org/wiki/Linux'},
    {title=>'The Linux Kernel Archives',excerpt=>'The Linux kernel.',url=>'https://kernel.org/'}
);
{
    my $value=$D->can('_parse')->(encode('UTF-8',$html));
    my $rendered=$D->can('_parse')->(encode('UTF-8',$modern),rendered=>1);
    my @bad=map {defined($D->can('_result_url')->($_))?1:0} (
        '//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2F&uddg=https%3A%2F%2Fb.example%2F',
        'https://duckduckgo.com.evil/l/?uddg=javascript:bad','https://user:pass@example.org/','file:///tmp/a',"https://example.org/\n",
        'https://duckduckgo.com/y.js?u3=https%3A%2F%2Fads.example.org%2F','https://www.bing.com/aclick?u=ad',
        'https://duckduckgo.com/%79.js','https://duckduckgo.com/?q=linux');
    is_deeply([$value,$rendered,\@bad],[{state=>'ok',hits=>[
        {title=>'Debian & café',excerpt=>'Le système libre 🌀.',url=>'https://www.debian.org/'},
        {title=>'Debian 13',excerpt=>'La documentation.',url=>'https://wiki.debian.org/Debian13'},
        {title=>'third',excerpt=>'Troisième résultat.',url=>'https://third.example.org/'}]},
        {state=>'ok',hits=>\@modern_hits},[0,1,0,0,0,0,0,0,0]],
        'legacy and opaque modern cards yield three distinct organic destinations with their OWN snippets; ads, missing snippets and duplicate titles cannot borrow a neighbour');
}
{
    my @values=map {$D->can('_parse')->($_)->{state}} (
        '<div class="no-results"><h1>No results</h1></div>','<form id="challenge-form">verify</form>',
        '<html>unexpected layout</html>','x'x(256*1024+1),"\xff");
    my $large='<!--'.('x'x270000).'-->'.$modern;
    my $legitimate=$modern;$legitimate=~s/Linux downloads\./CAPTCHA documentation./;
    push @values,$D->can('_parse')->($large)->{state},$D->can('_parse')->($large,rendered=>1)->{state},
        $D->can('_parse')->('x'x(2*1024*1024),rendered=>1)->{state},
        $D->can('_parse')->($legitimate,rendered=>1)->{state},
        $D->can('_parse')->($modern.'<form id="challenge-form"></form>',rendered=>1)->{state};
    is_deeply(\@values,['missing','unavailable','unavailable','unavailable','unavailable',
        'unavailable','ok','unavailable','ok','unavailable'],
        'HTTP and rendered DOM have separate finite limits; actual challenge nodes block, while an ordinary snippet mentioning CAPTCHA is still valid');
}
{
    my $b=bot1084();my @calls;my @options;my @browser;
    my $http=bless {html=>$html,calls=>\@calls},'MB1084::HTTP';
    local *Mediabot::External::_make_http=sub {push @options,{@_};$http};
    local *Mediabot::URLShortener::_default_http=sub {$http};
    my $native_browser=$D->can('_browser_lookup');
    my $browser_value={state=>'unavailable'};
    local *Mediabot::External::DuckDuckGo::_browser_lookup=sub {push @browser,[@_[1,2]];$browser_value};
    my $value=$D->can('_lookup_sync')->($b,'café & thé ☕','fr');
    my $uri=URI->new($calls[0]{url});my %query=$uri->query_form;
    my $first_browser_count=@browser;
    $http->{response}={success=>1,status=>202,content=>'<form id="challenge-form">verify</form>'};
    $browser_value=$D->can('_parse')->($modern,rendered=>1);
    my $modern_value=$D->can('_lookup_sync')->($b,'linux','fr');
    $browser_value={state=>'unavailable'};
    my $fallback=$D->can('_lookup_sync')->($b,'autre recherche','es');
    $http->{instant}={Heading=>'Eggdrop',AbstractText=>'Eggdrop est un bot IRC.',AbstractURL=>'https://fr.wikipedia.org/wiki/Eggdrop'};
    my $preview=$D->can('_lookup_sync')->($b,'eggdrop','fr');
    my ($api_call)=grep {$_->{method} eq 'GET' && $_->{url}=~/api\.duckduckgo\.com.*q=eggdrop/} @calls;
    my $api_uri=URI->new($api_call->{url}//'https://missing.invalid/');my %api_query=$api_uri->query_form;
    my ($api_options)=grep {$_->{max_size}==131072} @options;
    my @invalid;
    for my $response ({success=>1,status=>202,content=>'not json'},
        {success=>1,status=>200,content=>'x'x131073},
        {success=>1,status=>200,content=>JSON::PP::encode_json({Heading=>[],AbstractText=>'text',AbstractURL=>'https://example.org/'})},
        {success=>1,status=>200,content=>JSON::PP::encode_json({Heading=>'Eggdrop',AbstractText=>'text',AbstractURL=>'file:///tmp/private'})},
        {success=>1,status=>200,content=>JSON::PP::encode_json({Redirect=>'https://example.org/'})},
        {success=>1,status=>200,content=>JSON::PP::encode_json({Heading=>'query',AbstractText=>'text',AbstractURL=>'https://duckduckgo.com/?q=query'})},
        {success=>1,status=>503,content=>JSON::PP::encode_json($http->{instant})}) {
        $http->{instant_response}=$response;
        push @invalid,defined($D->can('_instant_preview')->('eggdrop','fr')) ? 1:0;
    }
    my ($native_cancel,%native_options);
    {
        local *Mediabot::External::Chromium::_fetch_url_chromium_dumpdom=sub {
            my ($bot,$url,%opts)=@_;%native_options=%opts;
            $SIG{TERM}->();return encode('UTF-8',$modern);
        };
        $native_cancel=$native_browser ? $native_browser->($b,'linux','fr') : {};
    }
    my $before_cancel=@calls;$browser_value={state=>'cancelled'};
    my $cancel=$D->can('_lookup_sync')->($b,'cancelled','fr');
    is_deeply([$uri->host,decode('UTF-8',$query{q}),$query{kl},[@{$options[0]}{qw(verify_SSL max_redirect timeout max_size)}],
        $first_browser_count,$value->{source},$modern_value->{source},[map {$_->{excerpt}} @{$modern_value->{hits}}],
        [map {$_->{target}} grep {$_->{method} eq 'POST'} @calls],
        $fallback->{state},$preview->{state},$preview->{hits}[0]{excerpt},
        $api_uri->host,[@api_query{qw(q format no_html no_redirect kl)}],
        [@{$api_options//{}}{qw(verify_SSL max_redirect timeout max_size)}],\@invalid,$cancel->{state},scalar(@calls)-$before_cancel,
        $native_cancel->{state},[@native_options{qw(alarm_timeout virtual_time_budget max_stdout max_stderr lang)}]],
        ['html.duckduckgo.com','café & thé ☕','fr-fr',[1,0,8,262144],0,'html','chromium',
         [map {$_->{excerpt}} @modern_hits],
         ['https://www.debian.org/','https://wiki.debian.org/Debian13','https://third.example.org/',
          (map {$_->{url}} @modern_hits),'https://fr.wikipedia.org/wiki/Eggdrop'],
         'unavailable','preview','Eggdrop est un bot IRC.','api.duckduckgo.com',
         ['eggdrop','json','1','1','fr-fr'],[1,0,8,131072],[0,0,0,0,0,0,0],'cancelled',1,'cancelled',[15,7000,2097152,32768,'fr-FR']],
        'HTTP 202 falls through to rendered organic results before any abstract; shortening receives only real targets and cancellation stops API/shortener work');
}
{
    my $base='https://teuk.org/shorturl/';
    my @hits=map {{title=>'Article '.$_,url=>'https://example.org/'.$_,
        display_url=>$base.chr(64+$_).'bcdef23',excerpt=>'Extrait '.$_.' '.('é'x400)}} 1..3;
    my $reply=$D->can('_render')->({state=>'ok',hits=>\@hits},'fr',$base);
    my @plain=map {my $s=$_;$s=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$s=~s/[\x02\x0f\x1f]//g;$s} @{$reply//[]};
    my $three=ref($reply) eq 'ARRAY' && @$reply==3 && !(grep {_irc_wire_bytes($_)>400} @$reply);
    for my $i (0..2) {
        $three &&= $plain[$i]=~/\A\[🦆 DDG\] @{[$i+1]}\. Article @{[$i+1]} — Extrait @{[$i+1]} /
            && $reply->[$i]=~/\x0312\x1f\Q$hits[$i]{display_url}\E\x1f\x0f/
            && $reply->[$i]=~/\x02Article @{[$i+1]}\x02/;
    }
    my @long_hits=map {{title=>'👩‍💻 é 'x200,url=>'https://example.org/'.$_.'?'.('a'x245),excerpt=>"texte\n\1\3".('🌀'x800)}} 1..3;
    my $long=$D->can('_render')->({state=>'ok',hits=>\@long_hits},'fr',$base);
    my $long_ok=ref($long) eq 'ARRAY' && @$long==3 && !(grep {_irc_wire_bytes($_)>400 || /[\x00-\x01\x04-\x0e\x10-\x1e\x7f]/} @$long);
    $long_ok &&= $long->[$_]=~/\Q$long_hits[$_]{url}\E/ for 0..2;
    my $foreign=$D->can('_render')->({state=>'ok',hits=>[{%{$hits[0]},display_url=>'https://foreign.example.org/'}]},'fr',$base);
    my $query=$D->can('_render')->({state=>'ok',hits=>[{title=>'query',excerpt=>'text',url=>'https://duckduckgo.com/?q=query',display_url=>$base.'Abcdef23'}]},'fr',$base);
    my $four=$D->can('_render')->({state=>'ok',hits=>[@hits,$hits[0]]},'fr',$base);
    my $empty=$D->can('_render')->({state=>'preview',hits=>[{%{$hits[0]},excerpt=>''}]},'fr',$base);
    my @previews;
    for my $lang ('fr','en','es') {
        my $preview=$D->can('_render')->({state=>'preview',hits=>[
            {title=>'Eggdrop',excerpt=>'An IRC bot.',url=>'https://en.wikipedia.org/wiki/Eggdrop',display_url=>$base.'Abcdef23'}]},$lang,$base);
        my $plain=ref($preview) eq 'ARRAY' && @$preview==1 ? $preview->[0] : '';
        $plain=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$plain=~s/[\x02\x0f\x1f]//g;push @previews,$plain;
    }
    is_deeply([$three?1:0,$long_ok?1:0,defined($foreign)?1:0,defined($query)?1:0,defined($four)?1:0,defined($empty)?1:0,\@previews],
        [1,1,0,0,0,0,[map {'[🦆 DDG] Eggdrop — An IRC bot. · '.$base.'Abcdef23'} 1..3]],
        'exactly three previews each keep their own snippet, bold title and whole blue underlined target within 400 bytes; no extra overview or Aperçu label');
}
{
    my $b=bot1084();set1084($b,'+ddg');$b->_register_builtin_command_catalogue;
    my $entry=$b->commands->command_for('ddg','public');my $dir=tempdir(CLEANUP=>1);my $trace="$dir/http.jsonl";
    # A real fork/exec browser emits modern DOM, not a mocked parser return.
    my $heavy_html='<html><body><main><div><a data-testid="result-title-a" href="https://duckduckgo.com/y.js?ad_domain=ads.example.org">AD</a><span data-result="snippet">AD EXCERPT</span></div>';
    for my $i (1..3) {
        my $url='https://example.org/'.$i.'?'.('a'x1900);
        $heavy_html.='<div><header><a data-testid="result-title-a" href="'.$url.'">Article '.$i.' '.('📚'x500)
            .'</a></header><span data-result="snippet">Extrait '.$i.' '.('🌀'x800).'</span></div>';
    }
    $heavy_html.='</main></body></html>';
    my $large_payload=length(JSON::PP->new->utf8->encode($D->can('_parse')->($heavy_html,rendered=>1)))>16384 ? 1:0;
    my $dom="$dir/dom.html";open my $df,'>:raw',$dom or die $!;print {$df} encode('UTF-8',$heavy_html);close $df or die $!;
    my $binary="$dir/chromium";open my $bf,'>:raw',$binary or die $!;print {$bf} '#!'.$^X."\n".<<'BROWSER';
use strict;use warnings;use JSON::PP;
open my $log,'>>:raw',$ENV{MB1089_BROWSER_TRACE} or die $!;
print {$log} JSON::PP::encode_json({pid=>$$,argv=>\@ARGV})."\n";close $log or die $!;
open my $dom,'<:raw',$ENV{MB1089_BROWSER_DOM} or die $!;binmode STDOUT,':raw';local $/;print scalar <$dom>;
BROWSER
    close $bf or die $!;chmod 0700,$binary;
    local $ENV{MB1089_BROWSER_TRACE}="$dir/browser.jsonl";local $ENV{MB1089_BROWSER_DOM}=$dom;
    local *Mediabot::External::Chromium::_chromium_binary=sub {$binary};
    local *Mediabot::External::Chromium::_chromium_profile_base=sub {"$dir/profiles"};
    my $http=bless {response=>{success=>1,status=>202,content=>'<form id="challenge-form"></form>'},calls=>[],trace=>$trace},'MB1084::HTTP';
    local *Mediabot::External::_make_http=sub {$http};local *Mediabot::URLShortener::_default_http=sub {$http};
    $b->{loop}=IO::Async::Loop->really_new;
    $entry->{handler}->(ctx1084($b,'ddg','Debian','13'));
    my $deadline=Time::HiRes::time()+5;
    $b->{loop}->loop_once(.02) while @{$b->{sent}}<3 && Time::HiRes::time()<$deadline;
    my @calls;if (-f $trace) {open my $fh,'<:raw',$trace or die $!;@calls=map {JSON::PP::decode_json($_)} <$fh>;close $fh}
    my $browser;if (-f $ENV{MB1089_BROWSER_TRACE}) {open my $fh,'<:raw',$ENV{MB1089_BROWSER_TRACE} or die $!;$browser=JSON::PP::decode_json(<$fh>);close $fh}
    my $browser_ok=$browser && $browser->{pid}!=$$ && grep {$_ eq '--lang=fr-FR'} @{$browser->{argv}};
    $browser_ok &&= $browser->{argv}[-1] eq 'https://duckduckgo.com/?q=Debian%2013&ia=web&kl=fr-fr';
    my $snippets=@{$b->{sent}}==3;
    $snippets &&= $b->{sent}[$_][2]=~/Extrait @{[$_+1]} / for 0..2;
    is_deeply([$entry->{level},$entry->{metadata}{migration_fallback}//0,$large_payload,scalar(@calls),
        (grep {$_->{pid}==$$} @calls)?1:0,$browser_ok?1:0,$snippets?1:0,
        [map {[$_->[0],$_->[1],$_->[3]]} @{$b->{sent}}],scalar(keys %{$b->{_ddg_pending}})],
        ['public',0,1,4,0,1,1,[map {['public','#test',$$]} 1..3],0],
        'native worker plus native browser exec survives HTTP 202 and returns three separate owned previews; only the child shortens their actual targets');
}
done_testing;
