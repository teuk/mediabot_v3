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
    sub get {my ($s,$url)=@_;$s->record('GET',$url);return $s->{response}//{success=>1,status=>200,content=>Encode::encode('UTF-8',$s->{html})}}
    sub request {
        my ($s,$method,$url,$options)=@_;my $body=JSON::PP::decode_json($options->{content});
        $s->record($method,$url,$body->{url});my $id=++$s->{serial}==1?'Abcdef23':'Bbcdef23';
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
<div class="result"><a class="result__a" href="https://third.example.org/">third</a></div>
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
        {title=>'Debian 13',excerpt=>'La documentation.',url=>'https://wiki.debian.org/Debian13'}]},[0,1,0,0,0]],
        'ranked organic links and plain snippets survive Unicode/entity decoding; ads/navigation/duplicates are skipped and redirects unwrap exactly one target');
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
    is_deeply([$uri->host,decode('UTF-8',$query{q}),$query{kl},[@{$options[0]}{qw(verify_SSL max_redirect timeout max_size)}],
        [map {$_->{display_url}} @{$value->{hits}}],[map {$_->{target}} grep {$_->{method} eq 'POST'} @calls],
        $fallback->{state},$fallback->{hits}[0]{title}],
        ['html.duckduckgo.com','café & thé ☕','fr-fr',[1,0,8,262144],
         ['https://teuk.org/shorturl/Abcdef23','https://teuk.org/shorturl/Bbcdef23'],
         ['https://www.debian.org/','https://wiki.debian.org/Debian13','https://duckduckgo.com/?q=autre%20recherche&kl=es-es'],
         'search_link','autre recherche'],
        'search and shortening preserve exact result destinations; a challenge returns a distinct browser-search state with the original query and its region');
}
{
    my $base='https://teuk.org/shorturl/';
    my $value={state=>'ok',hits=>[{title=>'📚é'x200,excerpt=>"texte\n\1\3".('👩‍💻 é 'x300),url=>'https://example.org/',display_url=>$base.'Abcdef23'}]};
    my $lines=$D->can('_render')->($value,'fr',$base);my $text=$lines->[0];
    $value->{hits}[0]{display_url}='https://foreign.example.org/wrong';my $foreign=$D->can('_render')->($value,'fr',$base);
    $value->{hits}[0]{display_url}=$value->{hits}[0]{url}='https://example.org/'.('a'x500);
    my $long=$D->can('_render')->($value,'fr',$base);
    my @searches;
    for my $lang ('fr','en','es') {
        my $reply=$D->can('_render')->({state=>'search_link',hits=>[
            {title=>'la vitesse de la lumière',excerpt=>'must not be an unavailable result',
             url=>'https://duckduckgo.com/?q=test',display_url=>$base.'Abcdef23'}]},$lang,$base);
        my $plain=ref($reply) eq 'ARRAY' && @$reply==1 ? $reply->[0] : '';
        $plain=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$plain=~s/[\x02\x0f\x1f]//g;
        push @searches,$plain;
    }
    is_deeply([(@$lines==1 && _irc_wire_bytes($text)<=400 && $text!~/[\x00-\x01\x04-\x0e\x10-\x1e\x7f]/
        && $text=~/\x0300,02\[🦆 DDG\]\x0f/ && $text=~/\x0312\x1f\Q$base\EAbcdef23\x1f\x0f\z/
        && !defined($foreign) && $long->[0]=~/raccourcisseur indisponible/)?1:0,\@searches],
        [1,[map {"[🦆 DDG] $_".'la vitesse de la lumière · '.$base.'Abcdef23'} ('Recherche : ','Search: ','Búsqueda: ')]],
        'themed links remain bounded and validated; a browser search is labelled with its query in each language, without a fake rank or failure excerpt');
}
{
    my $b=bot1084();set1084($b,'+ddg');$b->_register_builtin_command_catalogue;
    my $entry=$b->commands->command_for('ddg','public');my $dir=tempdir(CLEANUP=>1);my $trace="$dir/http.jsonl";
    my $http=bless {html=>$html,calls=>[],trace=>$trace},'MB1084::HTTP';
    local *Mediabot::External::_make_http=sub {$http};local *Mediabot::URLShortener::_default_http=sub {$http};
    $b->{loop}=IO::Async::Loop->really_new;
    $entry->{handler}->(ctx1084($b,'ddg','Debian','13'));
    my $deadline=Time::HiRes::time()+5;
    $b->{loop}->loop_once(.02) while @{$b->{sent}}<2 && Time::HiRes::time()<$deadline;
    my @calls;if (-f $trace) {open my $fh,'<:raw',$trace or die $!;@calls=map {JSON::PP::decode_json($_)} <$fh>;close $fh}
    is_deeply([$entry->{level},$entry->{metadata}{migration_fallback}//0,scalar(@calls),
        (grep {$_->{pid}==$$} @calls)?1:0,[map {[$_->[0],$_->[1],$_->[3]]} @{$b->{sent}}],
        scalar(keys %{$b->{_ddg_pending}})],
        ['public',0,3,0,[['public','#test',$$],['public','#test',$$]],0],
        'actual native ddg handler, policy, HTTP client and shortener run through one real fork/pipe; all network stays in the child and both IRC replies in the parent');
}
done_testing;
