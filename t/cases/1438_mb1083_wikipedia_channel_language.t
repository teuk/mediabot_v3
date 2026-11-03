use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK);
use JSON::PP;
use URI;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Time::HiRes ();
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::External::Wikipedia;
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

{
    package MB1083::Conf;
    sub get {$_[0]{$_[1]}}
    package MB1083::Loop;
    sub add {1} sub remove {1}
    package MB1083::IRC;
    sub is_connected {1}
    package MB1083::Runtime;
    sub capture_generation {$_[0]{generation}}
    package MB1083::Bot;
    our @ISA=('Mediabot');
    sub getLoop {$_[0]{loop}}
    sub getQuit {$_[0]{quit}//0}
    sub botPrivmsg {die "fixture transport failed\n" if $_[0]{throw};push @{$_[0]{sent}},['public',$_[1],$_[2],$$];1}
    sub botNotice {push @{$_[0]{sent}},['private',$_[1],$_[2],$$];1}
    package MB1083::HTTP;
    sub get {
        my ($s,$url,$options)=@_;push @{$s->{calls}},[$url,$options];
        die "fixture network failed\n" if $s->{throw};
        return $s->{response};
    }
}
my $W='Mediabot::External::Wikipedia';
my $json=JSON::PP->new->utf8->canonical;
my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::External::SearchCommand::enabled=sub {1};
local *Mediabot::Helpers::chanset_enabled=sub {
    my ($bot,$channel,$name)=@_;
    return $bot->{flags}{lc($channel).'/'.$name}//0;
};
sub bot1083 {
    return bless {conf=>bless({'main.LANG'=>'en'},'MB1083::Conf'),
        loop=>bless({},'MB1083::Loop'),irc=>bless({},'MB1083::IRC'),
        flags=>{},sent=>[],command_registry=>Mediabot::CommandRegistry->new},'MB1083::Bot';
}
sub ctx1083 {
    my ($bot,$args,$channel)=@_;$channel//='#i/o';
    return Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,command=>'wikipedia',args=>$args);
}
sub doc1083 {return {query=>{pages=>[{pageid=>42,ns=>0,title=>'Café',extract=>'Une boisson préparée avec du café.',@_}]}}}
sub response1083 {return {success=>1,status=>200,content=>$json->encode($_[0])}}

{
    my $b=bot1083();$b->{flags}={'#fr/LangFR'=>1,'#es/LangES'=>1,'#both/LangFR'=>1,'#both/LangES'=>1};
    my @langs=map {$W->can('_language')->($b,$_)} ('#fr','#es','#both','#plain');
    $b->{conf}{'main.LANG'}='PT-BR';push @langs,$W->can('_language')->($b,'#plain');
    $b->{conf}{'main.LANG'}='bad.example/path';push @langs,$W->can('_language')->($b,'#plain');
    my @queries=map {scalar $W->can('_query')->($_)} (['café','noir'],[encode('UTF-8','café noir')],['0'],
        [],["bad\nline"],['x'x161],[{}],["\xff"]);
    is_deeply([\@langs,\@queries],[['fr','es','fr','en','pt','en'],
        ['café noir','café noir','0',undef,undef,undef,undef,undef]],
        'channel language policy and regional normalization are shared; keyword text is bounded and decoded once');
}
{
    my (@options,@calls);
    my $http=bless {calls=>\@calls,response=>response1083(doc1083(fullurl=>'https://other.invalid/private'))},'MB1083::HTTP';
    local *Mediabot::External::_make_http=sub {push @options,{@_};$http};
    my $text=$W->can('_lookup_sync')->('café & thé ☕','fr');
    my $bytes=$W->can('_lookup_sync')->(encode('UTF-8','café & thé ☕'),'fr');
    my $uri=URI->new($calls[0][0]);my %q=$uri->query_form;
    is_deeply([$uri->scheme,$uri->host,$uri->path,decode('UTF-8',$q{gsrsearch}),
        [@q{qw(action generator gsrnamespace gsrlimit formatversion explaintext exintro)}],
        [@{$options[0]}{qw(timeout verify_SSL max_size max_redirect)}],
        $text eq $bytes?1:0,$text],
        ['https','fr.wikipedia.org','/w/api.php','café & thé ☕',
         ['query','search','0','1','2','1','1'],[8,1,131072,0],1,
         '[📚 Wikipédia/fr] Café — Une boisson préparée avec du café. · https://fr.wikipedia.org/?curid=42'],
        'one verified HTTPS Action API query encodes Unicode once and formats the requested edition with a trusted article link');
}
{
    my @calls;my $http=bless {calls=>\@calls},'MB1083::HTTP';
    local *Mediabot::External::_make_http=sub {$http};
    my @got;
    for my $res (undef,{success=>0,status=>503}, {success=>1,content=>'not json'},
        {success=>1,content=>'x'x(131072+1)},response1083({error=>{code=>'badquery'}}),
        response1083({query=>{pages=>{}}}),response1083(doc1083(pageid=>-1)),
        response1083(doc1083(ns=>1)),response1083(doc1083(title=>[]))) {
        $http->{response}=$res;push @got,$W->can('_lookup_sync')->('test','fr');
    }
    $http->{throw}=1;push @got,$W->can('_lookup_sync')->('test','fr');$http->{throw}=0;
    $http->{response}=response1083({batchcomplete=>JSON::PP::true});push @got,$W->can('_lookup_sync')->('test','fr');
    $http->{response}=response1083({query=>{pages=>[]}});push @got,$W->can('_lookup_sync')->('test','es');
    is_deeply(\@got,[(('wikipedia : recherche temporairement indisponible.')x10),
        'wikipedia : aucun article trouvé.','wikipedia: no se encontró ningún artículo.'],
        'HTTP failures, excessive or malformed JSON and invalid pages remain unavailable; genuine empty searches are localized separately');
}
{
    my $text=$W->can('_result_message')->(doc1083(title=>'📚é'x180,extract=>"texte\n\1\3".('👩‍💻 é 'x300)),'fr');
    my $bare=$W->can('_result_message')->(doc1083(extract=>undef),'en');
    ok(_irc_wire_bytes($text)<=400 && $text!~/[\x00-\x1f\x7f]/
        && $text=~/https:\/\/fr\.wikipedia\.org\/\?curid=42\z/
        && eval {decode('UTF-8',encode('UTF-8',$text),FB_CROAK);1}
        && $bare eq '[📚 Wikipedia/en] Café · https://en.wikipedia.org/?curid=42',
        'long Unicode text stays within one 400-byte sanitized reply with an intact link; articles without an extract still have a title and link');
}
{
    my $b=bot1083();$b->{flags}{'#i/o/LangFR'}=1;
    $b->_register_builtin_command_catalogue;
    my $entry=$b->commands->command_for('wikipedia','public');
    my @jobs;
    local *Mediabot::AsyncWorker::start=sub {my ($class,%job)=@_;push @jobs,\%job;bless {},'MB1083::Worker'};
    $entry->{handler}->(ctx1083($b,['Marie','Curie']));
    my $during=scalar @{$b->{sent}};
    $jobs[0]{on_done}->({ok=>1,value=>{message=>'résultat français'}});
    $entry->{handler}->(ctx1083($b,[]));$entry->{handler}->(ctx1083($b,["bad\nline"]));
    is_deeply([$entry->{level},$entry->{metadata}{syntax},$entry->{metadata}{migration_fallback}//0,
        $during,scalar(@jobs),$jobs[0]{label},$jobs[0]{timeout},$b->{sent},scalar(keys %{$b->{_wikipedia_pending}})],
        ['public','wikipedia <keyword>',0,0,1,'wikipedia lookup',12,
         [['public','#i/o','résultat français',$$],['private','Reader','Syntaxe : wikipedia <mot-clé>',$$],
          ['private','Reader','wikipedia : recherche invalide ou trop longue.',$$]],0],
        'the actual built-in registry handler and Context launch asynchronously, reply publicly and validate privately without unnecessary workers');
}
{
    my $b=bot1083();my @jobs;
    local *Mediabot::AsyncWorker::start=sub {my ($class,%job)=@_;push @jobs,\%job;bless {},'MB1083::Worker'};
    $W->can('mbWikipedia_ctx')->(ctx1083($b,['one']));$W->can('mbWikipedia_ctx')->(ctx1083($b,['two']));
    $W->can('mbWikipedia_ctx')->(ctx1083($b,['three']));
    my $peak=scalar keys %{$b->{_wikipedia_pending}};
    $jobs[1]{on_done}->({ok=>1,value=>{message=>'second'}});$jobs[1]{on_done}->({ok=>1,value=>{message=>'duplicate'}});
    $W->can('mbWikipedia_ctx')->(ctx1083($b,['four']));
    $jobs[0]{on_done}->({ok=>0,error=>'timeout'});$jobs[2]{on_done}->({ok=>1,value=>{message=>'fourth'}});
    is_deeply([$peak,scalar(@jobs),[map {$_->[2]} @{$b->{sent}}],scalar(keys %{$b->{_wikipedia_pending}})],
        [2,3,['wikipedia: searches are busy; try again shortly.','second','wikipedia: search temporarily unavailable.','fourth'],0],
        'two global reservations bound launches, out-of-order completion frees the right slot and duplicate callbacks cannot deliver twice');
}
{
    my @got;my $http_calls=0;
    local *Mediabot::External::_make_http=sub {$http_calls++;die 'must stay in child'};
    for my $mode (qw(die undef done-die done-undef)) {
        my $b=bot1083();
        local *Mediabot::AsyncWorker::start=sub {
            my ($class,%job)=@_;
            $job{on_done}->({ok=>1,value=>{message=>'inline'}}) if $mode=~/^done/;
            die "fixture launch failed\n" if $mode=~/die$/;
            return undef;
        };
        $W->can('mbWikipedia_ctx')->(ctx1083($b,['test']));
        push @got,[[map {$_->[2]} @{$b->{sent}}],scalar(keys %{$b->{_wikipedia_pending}})];
    }
    my $offline=bot1083();delete $offline->{loop};$W->can('mbWikipedia_ctx')->(ctx1083($offline,['test']));
    is_deeply([\@got,$http_calls,[map {$_->[2]} @{$offline->{sent}}]],
        [[[['wikipedia: search temporarily unavailable.'],0],[['wikipedia: search temporarily unavailable.'],0],
          [['inline'],0],[['inline'],0]],0,['wikipedia: search temporarily unavailable.']],
        'launch failure or no loop never runs blocking HTTP in the parent; inline completion remains single-use');
}
{
    my @got;
    for my $payload (undef,[],{message=>[]},{message=>''},{message=>'x'x401},{message=>"bad\nline"}) {
        my $b=bot1083();my $job;
        local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;$job=\%args;bless {},'MB1083::Worker'};
        $W->can('mbWikipedia_ctx')->(ctx1083($b,['test']));
        $job->{on_done}->({ok=>1,value=>$payload});push @got,$b->{sent}[0][2];
    }
    my $b=bot1083();$b->{throw}=1;my $job;
    local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;$job=\%args;bless {},'MB1083::Worker'};
    $W->can('mbWikipedia_ctx')->(ctx1083($b,['test']));my $ok=eval {$job->{on_done}->({ok=>1,value=>{message=>'valid'}});1};
    is_deeply([\@got,$ok?1:0,scalar(keys %{$b->{_wikipedia_pending}})],
        [[('wikipedia: search temporarily unavailable.')x6],1,0],
        'untrusted worker result shapes and a throwing reply cannot escape completion or leak capacity');
}
{
    my @counts;
    for my $change (qw(connection generation quit cancel)) {
        my $b=bot1083();$b->{wit_runtime_state}=bless {generation=>1},'MB1083::Runtime';my $job;
        local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;$job=\%args;bless {},'MB1083::Worker'};
        $W->can('mbWikipedia_ctx')->(ctx1083($b,['test']));
        $b->{irc}=bless {},'MB1083::IRC' if $change eq 'connection';
        $b->{wit_runtime_state}{generation}=2 if $change eq 'generation';$b->{quit}=1 if $change eq 'quit';
        $job->{on_done}->($change eq 'cancel'?{ok=>0,cancelled=>1,error=>'cancelled'}:{ok=>1,value=>{message=>'stale'}});
        push @counts,[scalar(@{$b->{sent}}),scalar(keys %{$b->{_wikipedia_pending}})];
    }
    is_deeply(\@counts,[[0,0],[0,0],[0,0],[1,0]],
        'connection replacement, channel generation and shutdown suppress stale delivery; worker cancellation completes with a bounded failure and releases capacity');
}
{
    my $b=bot1083();$b->{flags}{'#i/o/LangFR'}=1;$b->{loop}=IO::Async::Loop->really_new;
    local *Mediabot::External::_make_http=sub {bless {calls=>[],response=>response1083(doc1083(title=>"Worker $$"))},'MB1083::HTTP'};
    my $responsive=0;my $tick=IO::Async::Timer::Countdown->new(delay=>0,on_expire=>sub {$responsive++});
    $b->{loop}->add($tick);$tick->start;
    $W->can('mbWikipedia_ctx')->(ctx1083($b,['test']));
    my $deadline=Time::HiRes::time()+5;
    $b->{loop}->loop_once(.02) while !@{$b->{sent}} && Time::HiRes::time()<$deadline;
    $b->{loop}->remove($tick);
    my ($child)=($b->{sent}[0][2]//'')=~/Worker (\d+)/;
    ok($responsive==1 && defined($child) && $child!=$$ && $b->{sent}[0][0] eq 'public'
        && $b->{sent}[0][3]==$$ && scalar(keys %{$b->{_wikipedia_pending}})==0 && !@warnings,
        'real fork/pipe lookup returns through the parent Context while the native loop stays responsive, without TCP or warnings');
}
done_testing;
