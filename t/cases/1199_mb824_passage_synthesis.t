use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::Request qw(build_request validate_request);
use Mediabot::AI::Provider::OpenAI;
use Mediabot::AI::Provider::Anthropic;
use Mediabot::AI::Provider::Gemini;
use Mediabot::AI::Client;
{
    package MB824Conf;sub get {$_[0]{$_[1]}}
    package MB824Client;sub submit {my ($s,$r,%a)=@_;push @{$s->{calls}},{request=>$r,done=>$a{on_done}};1}
    package MB824HTTP;sub request {return {success=>1,status=>200,content=>JSON::PP::encode_json(
        {candidates=>[{content=>{parts=>[{text=>'OK'}]}}]})}}
}
my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'gemini.API_KEY'=>'YOUR_GEMINI_TEST_KEY','meta_ai.OPENAI_MODEL'=>'gpt-4o'},'MB824Conf';
sub fixture {
    my (%opts)=@_;my (@out,@events);my $searches=0;
    my $client=bless {calls=>[]},'MB824Client';
    my $sources=[{id=>1,url=>'https://tukaani.org/xz-backdoor/',text=>
        'XZ Utils 5.6.0 and 5.6.1 release archives contained the CVE-2024-3094 backdoor. Clean releases were published later.'},
        {id=>2,url=>'https://example.org/vendor',text=>'Use the supported corrected packages supplied by the distribution vendor.'}];
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$client,
        evidence_mode=>'passage_ids',on_event=>sub {push @events,shift},
        web_start=>sub {$searches++;$_[1]->({ok=>1,sources=>$sources});1});
    $engine->submit(prompt=>'détaille CVE-2024-3094',language=>$opts{language}//'fr',
        messages=>[{role=>'user',content=>'speaker1 (Alice): détaille CVE-2024-3094'}],on_done=>sub {push @out,shift});
    for my $i (0..2) {
        $client->{calls}[$i]{done}->($i==2 && $opts{gemini_fails}
            ? {ok=>0,status=>503,error=>'http_error',failure_category=>'service_unavailable',transient_retries=>1}
            : {ok=>1,answer=>encode_json({answer=>'UNVERIFIED_DRAFT_MUST_NOT_BE_EVIDENCE',needs_web=>0})});
    }
    return ($client,\@out,\@events,\$searches,$sources);
}
sub selected {
    my ($client,$index,%more)=@_;
    my ($json)=$client->{calls}[$index]{request}{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
    my $rows=decode_json($json);
    return {answer=>'XZ Utils 5.6.0 et 5.6.1 étaient concernées ; utiliser les paquets corrigés de sa distribution.',
        source_ids=>[map {$_->{id}} @$rows],basis=>'supported',support=>[map {
            +{source_id=>$_->{id},passage_id=>$_->{passages}[0]{passage_id}}
        } @$rows],%more};
}
sub complete {my ($c,$index,$value,$provider)=@_;
    $c->{calls}[$index]{done}->({ok=>1,status=>200,provider=>$provider//'openai',answer=>encode_json($value)});}
my ($client,$out,$events,$searches,$sources)=fixture();
my $request=$client->{calls}[3]{request};
is($request->{purpose},'meta_synthesis_passages','researched IRC synthesis uses the catalogue selection purpose');
ok(!defined(validate_request($request)),'neutral request accepts the bounded catalogue metadata');
like($request->{system},qr/Select the supplied passage IDs/,'model selects real supplied proof IDs');
unlike($request->{system},qr/UNVERIFIED_DRAFT_MUST_NOT_BE_EVIDENCE/,'unverified factual drafts do not enter proof catalogue');
complete($client,3,selected($client,3));
ok($out->[0]{ok} && $out->[0]{evidence_anchors}==2,'direct passage selection completes with two locally resolved proofs');
is($out->[0]{citation_repair},0,'normal passage selection has no quote-recopy correction');
is($out->[0]{evidence_method},'passage_ids','result identifies the catalogue method');
is(scalar(@{$client->{calls}}),4,'three contributors plus one synthesis; no additional normal API call');
is($$searches,1,'only original research is used');
is_deeply([map {$_->{url}} @{$out->[0]{sources}}],[map {$_->{url}} @$sources],'source URLs remain bound to actual cited destinations');
is($events->[-1]{reason},'passage_ids','accepted catalogue selection is observable');
is($events->[-1]{action},'accepted','successful proof selection is not confused with a retry');

for my $provider (qw(openai anthropic gemini)) {
    ($client,$out,$events,$searches)=fixture(gemini_fails=>1);
    complete($client,3,{answer=>'PRIVATE_REJECTED_PROSE',source_ids=>[1],basis=>'supported',support=>[
        {source_id=>1,quote=>'A translated/paraphrased quote that should never be accepted.'}]},$provider);
    is(scalar(@$out),0,'free-text proof cannot bypass the selected-ID contract');
    is($client->{calls}[4]{request}{purpose},'meta_passage_repair','one bounded format correction is available');
    is($client->{calls}[4]{request}{provider},$provider,'correction stays on the actual synthesis provider');
    is_deeply($client->{calls}[4]{request}{passage_ids},$client->{calls}[3]{request}{passage_ids},'same immutable ID set is used for correction');
    unlike($client->{calls}[4]{request}{system},qr/PRIVATE_REJECTED_PROSE|translated\/paraphrased quote/,'rejected content is not recycled as evidence');
    complete($client,4,selected($client,4),$provider);
    ok($out->[0]{ok} && $out->[0]{citation_repair} && $out->[0]{degraded},'valid corrected catalogue result retains degraded contributor metadata');
    is(scalar(@{$client->{calls}}),5,'no third synthesis or contributor repeat');
    is($$searches,1,'correction does not repeat the web search');
}
($client,$out,$events)=fixture();
my $bad=selected($client,3);$bad->{support}[0]{passage_id}='s1p99-000000000000';
complete($client,3,$bad);
is($out->[0]{error},'unsupported_web_answer','invented catalogue ID is rejected immediately');
is($out->[0]{evidence_error},'unknown_passage','unknown ID has an explicit bounded reason');
is(scalar(@{$client->{calls}}),4,'invented ID has no correction cascade');
($client,$out,$events)=fixture();$bad=selected($client,3);
$bad->{support}[0]{passage_id}=$bad->{support}[1]{passage_id};complete($client,3,$bad);
ok(!$out->[0]{ok},'known passage from wrong source cannot be substituted');
($client,$out,$events,$searches,$sources)=fixture();my $selection=selected($client,3);
$sources->[0]{text}.=' A changed page after catalogue construction.';complete($client,3,$selection);
is($out->[0]{evidence_error},'source_changed','changed live source cannot validate an old catalogue');

for my $language (qw(fr en)) {
    ($client,$out)=fixture(language=>$language);
    complete($client,3,selected($client,3,basis=>'insufficient',answer=>'PRIVATE_UNSUPPORTED_ASSERTION'));
    ok($out->[0]{ok},'honest insufficient evidence remains an accepted limited reply');
    unlike($out->[0]{answer},qr/PRIVATE_UNSUPPORTED_ASSERTION/,'unsupported prose is replaced before IRC delivery');
    like($out->[0]{answer},$language eq 'fr'?qr/ne permettent pas d’établir/:qr/do not establish/,'limitation follows channel language');
}

my @ids=@{$request->{passage_ids}};
for my $purpose (qw(meta_synthesis_passages meta_passage_repair)) {
    my $r=build_request(provider=>'auto',purpose=>$purpose,model=>'gpt-4o',passage_ids=>\@ids,
        messages=>[{role=>'user',content=>'Question'}],max_output_tokens=>2048,timeout_seconds=>5);
    my $payload=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($r,{api_style=>'responses'}));
    my $schema=$payload->{text}{format}{schema};
    is_deeply($schema->{properties}{support}{items}{required},[qw(source_id passage_id)],'OpenAI requires references rather than regenerated proof text');
    is_deeply($schema->{properties}{support}{items}{properties}{passage_id}{enum},\@ids,'strict schema permits only this actual catalogue');
    ok(!exists($schema->{properties}{support}{items}{properties}{quote}),'free-text proof field cannot enter strict response schema');
    ok($payload->{text}{format}{strict},'strict structured outputs preserved');
    for my $adapter (\&Mediabot::AI::Provider::Anthropic::build_payload,\&Mediabot::AI::Provider::Gemini::build_payload) {
        my $explicit={%$r,provider=>$adapter==\&Mediabot::AI::Provider::Anthropic::build_payload?'anthropic':'gemini'};
        my $body=decode_json($adapter->($explicit));
        ok(!exists($body->{passage_ids}),'neutral proof metadata never becomes an unsupported provider API field');
    }
    my $ai=Mediabot::AI::Client->new(conf=>$conf,http_factory=>sub {bless {},'MB824HTTP'});
    my $plan=$ai->_prepare_plan({%$r,provider=>'gemini'});
    ok($plan->{providers}[0]{attempts}[0]{transient_retry},'new Gemini purpose retains its existing bounded transient retry policy');
}
for my $ids (undef,[],['bad'],[$ids[0],$ids[0]],[(($ids[0])x121)],{}) {
    my $r={%$request,passage_ids=>$ids};
    ok(defined(validate_request($r)),'malformed request catalogue metadata cannot bypass neutral validation');
}
ok(defined(validate_request({%$request,purpose=>'meta_draft'})),'ordinary requests cannot accidentally carry catalogue metadata');

# Exercise real forked provider workers and a researched synthesis worker.
# HTTP is fake; provider payload building, decoding, neutral dispatch and the
# programme's catalogue resolution are the actual production implementations.
require IO::Async::Loop;
require Time::HiRes;
my $loop=IO::Async::Loop->new;
my $ai=Mediabot::AI::Client->new(conf=>$conf,loop_owner=>{loop=>$loop},
    config_overrides=>{'openai.API_URL'=>'https://api.openai.com/v1/responses','openai.MODEL'=>'gpt-4o'},
    http_factory=>sub {bless {},'MB824ParallelHTTP'});
my @async;
my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$ai,evidence_mode=>'passage_ids',
    web_start=>sub {$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://tukaani.org/xz-backdoor/',
        text=>'XZ Utils 5.6.0 and 5.6.1 contained the CVE-2024-3094 backdoor.'}]});1});
$engine->submit(prompt=>'CVE-2024-3094',messages=>[{role=>'user',content=>'CVE-2024-3094'}],
    on_done=>sub {push @async,shift});
is(scalar(@async),0,'provider HTTP work does not synchronously block the parent loop');
my $deadline=Time::HiRes::time()+12;
$loop->loop_once(0.05) while !@async && Time::HiRes::time()<$deadline;
is(scalar(@async),1,'actual workers finish one collective result');
ok($async[0]{ok} && $async[0]{evidence_method} eq 'passage_ids','real synthesis worker returns usable catalogue references');
is_deeply($async[0]{contributors},[qw(openai anthropic gemini)],'three real provider workers participate');
is($async[0]{citation_repair},0,'normal worker flow needs no copied quote or extra synthesis');
done_testing;

package MB824ParallelHTTP;
sub request {
    my ($self,$method,$url,$opts)=@_;
    my $body=JSON::PP::decode_json($opts->{content});
    my $provider=$url=~/anthropic/?'anthropic':$url=~/googleapis/?'gemini':'openai';
    my $system=$provider eq 'anthropic'?$body->{system}:$provider eq 'gemini'
        ?$body->{systemInstruction}{parts}[0]{text}:$body->{instructions};
    Time::HiRes::sleep(0.03);
    my $text;
    if ($system=~/^UNTRUSTED SOURCES: ([^\n]+)/m) {
        my $sources=JSON::PP::decode_json($1);
        my $id=$sources->[0]{passages}[0]{passage_id};
        die 'catalogue missing from actual strict schema' unless grep {$_ eq $id}
            @{$body->{text}{format}{schema}{properties}{support}{items}{properties}{passage_id}{enum}};
        $text=JSON::PP::encode_json({answer=>'XZ Utils 5.6.0 et 5.6.1 étaient concernées.',source_ids=>[1],basis=>'supported',
            support=>[{source_id=>1,passage_id=>$id}]});
    }
    else {$text=JSON::PP::encode_json({answer=>'Independent worker draft',needs_web=>0})}
    my $result=$provider eq 'anthropic'?{content=>[{type=>'text',text=>$text}]}
        :$provider eq 'gemini'?{candidates=>[{content=>{parts=>[{text=>$text}]}}]}
        :{output=>[{type=>'message',content=>[{type=>'output_text',text=>$text}]}]};
    return {success=>1,status=>200,content=>JSON::PP::encode_json($result)};
}
