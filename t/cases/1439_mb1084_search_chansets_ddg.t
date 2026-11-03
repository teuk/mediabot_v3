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
        push @observed,[scalar(@{$b->{sent}}),scalar(keys %{$b->{'_'.lc($name).'_pending'}})];
    }
    is_deeply(\@observed,[[0,0],[0,0]], 'disable then re-enable revokes both old attempts even though the flag is on again, and releases their capacity');
}
{
    my $value=$D->can('_parse')->(encode('UTF-8',$html));
    my @bad=map {defined($D->can('_result_url')->($_))?1:0} (
        '//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2F&uddg=https%3A%2F%2Fb.example%2F',
        'https://duckduckgo.com.evil/l/?uddg=javascript:bad','https://user:pass@example.org/','file:///tmp/a',"https://example.org/\n");
    is_deeply([$value,\@bad],[{state=>'ok',hits=>[
        {title=>'Debian & café',excerpt=>'Le système libre 🌀.',url=>'https://www.debian.org/'},
        {title=>'Debian 13',excerpt=>'La documentation.',url=>'https://wiki.debian.org/Debian13'},
        {title=>'third',excerpt=>'Troisième résultat.',url=>'https://third.example.org/'}]},[0,1,0,0,0]],
        'exactly three ranked unique organic links survive Unicode/entity decoding; the fourth, ads/navigation/duplicates and unsafe redirects are excluded');
}
{
    my @values=map {$D->can('_parse')->($_)->{state}} (
        '<div class="no-results"><h1>No results</h1></div>','<form id="challenge-form">verify</form>',
        '<html>unexpected layout</html>','x'x(256*1024+1),"\xff");
    is_deeply(\@values,['missing','unavailable','unavailable','unavailable','unavailable'],
        'only an explicit empty-result page is empty; challenges, unknown markup, oversized bodies and invalid UTF-8 remain unavailable');
}
{
    my $b=bot1084();my @calls;my @options;
    my $http=bless {html=>$html,calls=>\@calls},'MB1084::HTTP';
    local *Mediabot::External::_make_http=sub {push @options,{@_};$http};
    local *Mediabot::URLShortener::_default_http=sub {$http};
    my $value=$D->can('_lookup_sync')->($b,'café & thé ☕','fr');
    my $uri=URI->new($calls[0]{url});my %query=$uri->query_form;
    $http->{response}={success=>1,status=>202,content=>'<form id="challenge-form">verify</form>'};
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
        my $instant=$D->can('_instant_preview');push @invalid,$instant && defined($instant->('eggdrop','fr')) ? 1:0;
    }
    is_deeply([$uri->host,decode('UTF-8',$query{q}),$query{kl},[@{$options[0]}{qw(verify_SSL max_redirect timeout max_size)}],
        [map {$_->{display_url}} @{$value->{hits}}],[map {$_->{target}} grep {$_->{method} eq 'POST'} @calls],
        $fallback->{state},exists($preview->{search})?1:0,$preview->{state},$preview->{hits}[0]{excerpt},
        $api_uri->host,[@api_query{qw(q format no_html no_redirect kl)}],
        [@{$api_options//{}}{qw(verify_SSL max_redirect timeout max_size)}],\@invalid],
        ['html.duckduckgo.com','café & thé ☕','fr-fr',[1,0,8,262144],
         ['https://teuk.org/shorturl/Abcdef23','https://teuk.org/shorturl/Bbcdef23','https://teuk.org/shorturl/Cbcdef23'],
         ['https://www.debian.org/','https://wiki.debian.org/Debian13','https://third.example.org/','https://fr.wikipedia.org/wiki/Eggdrop'],
         'unavailable',0,'preview','Eggdrop est un bot IRC.','api.duckduckgo.com',
         ['eggdrop','json','1','1','fr-fr'],[1,0,8,131072],[0,0,0,0,0,0,0]],
        'shortening receives only the three ranked destinations or the one real preview source; blocked searches never fabricate or shorten a keyword-search URL');
}
{
    my $base='https://teuk.org/shorturl/';
    my @hits=map {{title=>'Article '.$_,url=>'https://example.org/'.$_,
        display_url=>$base.chr(64+$_).'bcdef23',excerpt=>'Extrait '.('é'x400)}} 1..3;
    my $reply=$D->can('_render')->({state=>'ok',hits=>\@hits},'fr',$base);
    my @plain=map {my $s=$_;$s=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$s=~s/[\x02\x0f\x1f]//g;$s} @{$reply//[]};
    my $packed=@$reply==2 && !(grep {_irc_wire_bytes($_)>400} @$reply)
        && $plain[0]=~/\A\[🦆 DDG\] Aperçu : Article 1 — Extrait /
        && $plain[1] eq '[🦆 DDG] '.join(' | ',map {$_ .'. Article '.$_.' · '.$base.chr(64+$_).'bcdef23'} 1..3)
        && $reply->[1]=~/\x0312\x1f\Q$base\EAbcdef23\x1f\x0f/
        && $reply->[1]=~/\x0312\x1f\Q$base\ECbcdef23\x1f\x0f/;
    my @long_hits=map {{title=>'👩‍💻 é 'x200,url=>'https://example.org/'.$_.'?'.('a'x245),excerpt=>"texte\n\1\3".('🌀'x800)}} 1..3;
    my $long=$D->can('_render')->({state=>'ok',hits=>\@long_hits},'fr',$base);
    my $long_ok=ref($long) eq 'ARRAY' && @$long==4 && !(grep {_irc_wire_bytes($_)>400 || /[\x00-\x01\x04-\x0e\x10-\x1e\x7f]/} @$long);
    $long_ok &&= $long->[$_]=~/\Q$long_hits[$_-1]{url}\E/ for 1..3;
    my $foreign=$D->can('_render')->({state=>'ok',hits=>[{%{$hits[0]},display_url=>'https://foreign.example.org/'}]},'fr',$base);
    my $query=$D->can('_render')->({state=>'ok',hits=>[{title=>'query',url=>'https://duckduckgo.com/?q=query',display_url=>$base.'Abcdef23'}]},'fr',$base);
    my $four=$D->can('_render')->({state=>'ok',hits=>[@hits,$hits[0]]},'fr',$base);
    my $empty=$D->can('_render')->({state=>'preview',hits=>[{%{$hits[0]},excerpt=>''}]},'fr',$base);
    my @previews;
    for my $lang ('fr','en','es') {
        my $preview=$D->can('_render')->({state=>'preview',hits=>[
            {title=>'Eggdrop',excerpt=>'An IRC bot.',url=>'https://en.wikipedia.org/wiki/Eggdrop',display_url=>$base.'Abcdef23'}]},$lang,$base);
        my $plain=ref($preview) eq 'ARRAY' && @$preview==1 ? $preview->[0] : '';
        $plain=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$plain=~s/[\x02\x0f\x1f]//g;push @previews,$plain;
    }
    is_deeply([$packed?1:0,$long_ok?1:0,defined($foreign)?1:0,defined($query)?1:0,defined($four)?1:0,defined($empty)?1:0,\@previews],
        [1,1,0,0,0,0,[map {'[🦆 DDG] '.$_.' : Eggdrop — An IRC bot. · '.$base.'Abcdef23'}
            ('Aperçu seul (EN)','Preview only','Solo vista previa (EN)')]],
        'brief preview plus three ranked targets use two IRC lines with short URLs; whole long destinations wrap without loss, and no search-link fallback survives');
}
{
    my $b=bot1084();set1084($b,'+ddg');$b->_register_builtin_command_catalogue;
    my $entry=$b->commands->command_for('ddg','public');my $dir=tempdir(CLEANUP=>1);my $trace="$dir/http.jsonl";
    # Three valid Unicode-rich hits exceed the old 16-KiB worker envelope.
    my $heavy_html='<html><body>';
    for my $i (1..3) {
        my $url='https://example.org/'.$i.'?'.('a'x1900);
        $heavy_html.='<div class="result"><a class="result__a" href="'.$url.'">Article '.$i.' '.('📚'x500)
            .'</a><span class="result__snippet">'.('🌀'x800).'</span></div>';
    }
    $heavy_html.='</body></html>';
    my $large_payload=length(JSON::PP->new->utf8->encode($D->can('_parse')->($heavy_html)))>16384 ? 1:0;
    my $http=bless {html=>$heavy_html,calls=>[],trace=>$trace},'MB1084::HTTP';
    local *Mediabot::External::_make_http=sub {$http};local *Mediabot::URLShortener::_default_http=sub {$http};
    $b->{loop}=IO::Async::Loop->really_new;
    $entry->{handler}->(ctx1084($b,'ddg','Debian','13'));
    my $deadline=Time::HiRes::time()+5;
    $b->{loop}->loop_once(.02) while @{$b->{sent}}<2 && Time::HiRes::time()<$deadline;
    my @calls;if (-f $trace) {open my $fh,'<:raw',$trace or die $!;@calls=map {JSON::PP::decode_json($_)} <$fh>;close $fh}
    is_deeply([$entry->{level},$entry->{metadata}{migration_fallback}//0,$large_payload,scalar(@calls),
        (grep {$_->{pid}==$$} @calls)?1:0,[map {[$_->[0],$_->[1],$_->[3]]} @{$b->{sent}}],
        scalar(keys %{$b->{_ddg_pending}})],
        ['public',0,1,4,0,[['public','#test',$$],['public','#test',$$]],0],
        'native fork/pipe returns one preview and three compact ranked targets in two IRC replies, with all three exact shortening requests in the child');
}
done_testing;
