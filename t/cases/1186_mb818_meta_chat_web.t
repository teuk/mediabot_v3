use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaPolicy qw(settings wants_web safe_url);
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaWeb;
{
    package MB818ChatConf;
    sub new {bless $_[1]//{},$_[0]}sub get {$_[0]{$_[1]}}
    package MB818ChatClient;
    sub new {bless {calls=>[]},$_[0]}
    sub submit {my ($s,$request,%args)=@_;push @{$s->{calls}},{request=>$request,done=>$args{on_done}};1}
    package MB818ChatHTTP;
    sub request {my ($s,$method,$url,$opts)=@_;push @{$s->{calls}},[$method,$url,$opts];
        return shift @{$s->{responses}}}
}
my $conf=MB818ChatConf->new({'openai.API_KEY'=>'openai-configured','anthropic.API_KEY'=>'claude-configured',
    'gemini.API_KEY'=>'gemini-configured'});
my $cfg=settings($conf);
ok(wants_web('qui est le président actuel ?'),'current office forces research');
ok(wants_web('what is the latest release?'),'latest release forces research');
ok(!wants_web('what is the mass of a proton?'),'stable wording does not blindly force research');
for my $url ('http://127.0.0.1/x','https://localhost/x','https://foo.local/x',
             'https://user:pass@site.org/x',"https://site.org/x\nraw",'file:///etc/passwd') {
    ok(!defined(safe_url($url)),'non-public or non-web URL rejected');
}
my (@results,@web_queries);my $client=MB818ChatClient->new;
my $engine=Mediabot::AI::MetaChat->new(client=>$client,conf=>$conf,settings=>$cfg,clock=>sub {1791892800},
    web_start=>sub {die 'stable request must not fetch the web'});
my @messages=({role=>'user',content=>'speaker1: mass of proton?'});
ok($engine->submit(prompt=>'mass of proton?',messages=>\@messages,language=>'fr',on_done=>sub {push @results,shift}),'ensemble is submitted');
is(scalar(@{$client->{calls}}),3,'all three providers are launched before any response is completed');
is_deeply([map {$_->{request}{provider}} @{$client->{calls}}],[qw(openai anthropic gemini)],'three independent providers participate');
for my $index (2,0,1) {
    $client->{calls}[$index]{done}->({ok=>1,answer=>encode_json({answer=>'1.67e-27 kg',needs_web=>JSON::PP::false,query=>''})});
    is(scalar(@results),0,'contributors do not individually emit IRC replies');
}
is(scalar(@{$client->{calls}}),4,'one synthesis starts only after the contributors finish');
like($client->{calls}[3]{request}{system},qr/Agreement between models is not evidence/,'synthesis does not treat model consensus as proof');
is($client->{calls}[3]{request}{provider},'auto','synthesis keeps provider fallback available');
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'La masse du proton vaut environ 1,67e-27 kg.',source_ids=>[]})});
is(scalar(@results),1,'exactly one final response is produced');
is(scalar(@{$results[0]{contributors}}),3,'final result retains bounded contributor metadata');
ok(!$results[0]{web_used},'stable answer is not falsely labelled as browsed');
$client->{calls}[1]{done}->({ok=>1,answer=>'late duplicate'});
is(scalar(@results),1,'duplicate callbacks cannot revive a completed request');

@results=();$client=MB818ChatClient->new;
my $sources=[{id=>1,url=>'https://www.example.org/releases',title=>'Official release',
    text=>'The latest stable release is version 9.4, published today.',date=>'2026-10-13',kind=>'page_excerpt'}];
$engine=Mediabot::AI::MetaChat->new(client=>$client,conf=>$conf,settings=>$cfg,
    web_start=>sub {my ($query,$done)=@_;push @web_queries,$query;$done->({ok=>1,sources=>$sources});1});
my @history=({role=>'user',content=>'speaker1: Tell me about ExampleSoft'},
    {role=>'assistant',content=>'ExampleSoft is a program.'},{role=>'user',content=>'speaker2: latest version?'});
$engine->submit(prompt=>'latest version?',messages=>\@history,language=>'en',on_done=>sub {push @results,shift});
for my $index (0..2) {$client->{calls}[$index]{done}->({ok=>1,answer=>encode_json({answer=>'unverified draft',
    needs_web=>JSON::PP::true,query=>'ExampleSoft latest stable release official website'})})}
like($web_queries[0],qr/ExampleSoft/,'model-generated standalone query resolves a follow-up subject');
is_deeply($client->{calls}[0]{request}{messages},\@history,'contributors share multi-speaker history');
like($client->{calls}[3]{request}{system},qr/Official release/,'actual extracted source evidence enters synthesis');
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'The latest stable release is 9.4.',source_ids=>[1]})});
ok($results[0]{web_used},'answer carries actual research status');
is_deeply($results[0]{sources},$sources,'output links are tied to supplied source IDs');

@results=();$client=MB818ChatClient->new;
$engine=Mediabot::AI::MetaChat->new(client=>$client,conf=>$conf,settings=>$cfg,
    web_start=>sub {my ($query,$done)=@_;$done->({ok=>0});$done->({ok=>0});1});
$engine->submit(prompt=>'today?',messages=>\@messages,language=>'en',on_done=>sub {push @results,shift});
for my $index (0..2) {$client->{calls}[$index]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>1,query=>'today official news'})})}
is(scalar(@{$client->{calls}}),4,'failed shared search launches native web exactly once');
is($client->{calls}[3]{request}{purpose},'meta_web','fallback explicitly requires native browsing');
$client->{calls}[3]{done}->({ok=>1,answer=>'Verified current fact.',sources=>[{url=>'https://www.example.org/news',title=>'Official'}]});
ok($results[0]{ok} && $results[0]{web_used},'native web fallback requires real citation metadata');

@results=();$client=MB818ChatClient->new;
$engine=Mediabot::AI::MetaChat->new(client=>$client,conf=>$conf,settings=>$cfg,
    web_start=>sub {$_[1]->({ok=>1,sources=>$sources});1});
$engine->submit(prompt=>'today?',messages=>\@messages,language=>'en',on_done=>sub {push @results,shift});
for my $index (0..2) {$client->{calls}[$index]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>1,query=>'official'})})}
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'Claim with a made-up reference.',source_ids=>[99]})});
is($results[0]{error},'unsupported_web_answer','invented source ID fails rather than manufacturing a URL');

@results=();$client=MB818ChatClient->new;
$engine=Mediabot::AI::MetaChat->new(client=>$client,conf=>$conf,settings=>$cfg);
$engine->submit(prompt=>'stable',messages=>\@messages,on_done=>sub {push @results,shift});
for my $index (0..2) {$client->{calls}[$index]{done}->({ok=>0,error=>'http_error'})}
is($results[0]{error},'all_providers_failed','total outage is explicit');
is(scalar(@{$client->{calls}}),3,'total outage causes no retry storm');

my (@http_calls,@tls);my $responses=[
    {success=>1,status=>200,content=>encode_json({results=>[
        {url=>'https://127.0.0.1/private',title=>'unsafe',content=>'x'x80},
        {url=>'https://www.example.org/releases',title=>'Official',content=>'A searchable excerpt with enough concrete information for grounding.',published_date=>'2026-10-13'},
        {url=>'https://other.example.org/releases',title=>'Another source',content=>'A second searchable excerpt with independent source information.'} ]})},
    {success=>1,status=>200,content=>encode_json({results=>[
        {url=>'https://www.example.org/releases',raw_content=>'A read page with sufficient detail. '.('Concrete evidence. 'x12)},
        {url=>'https://rogue.example.org/injected',raw_content=>'Unrequested content. 'x50} ]})},
];
my $web=Mediabot::AI::MetaWeb->new(api_key=>'fake-search-credential',domains=>['example.org'],
    http_factory=>sub {my %opts=@_;push @tls,$opts{verify_SSL};
        bless {calls=>\@http_calls,responses=>$responses},'MB818ChatHTTP'});
my $research=$web->search('ExampleSoft latest release');
ok($research->{ok},'shared search returns usable evidence');
is($http_calls[0][1],'https://api.tavily.com/search','search uses fixed HTTPS API endpoint');
is_deeply(decode_json($http_calls[0][2]{content})->{include_domains},['example.org'],'key-site preference reaches search');
is($http_calls[0][2]{headers}{Authorization},'Bearer fake-search-credential','search key uses authorization header');
unlike($http_calls[0][2]{content},qr/fake-search-credential/,'search credential is not in body');
ok(!grep(!$_,@tls),'both search and extraction verify TLS');
is(scalar(@{$research->{sources}}),2,'unsafe source is discarded');
is($research->{sources}[0]{kind},'page_excerpt','successful page extraction is distinct from search snippets');
is($research->{sources}[1]{kind},'search_excerpt','failed extraction retains its honest evidence type');
unlike(join(' ',map {$_->{text}} @{$research->{sources}}),qr/Unrequested/,'extractor cannot substitute an unrequested page');
done_testing;
