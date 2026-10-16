use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaReply qw(format_meta_reply);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::Client;
{
    package MB826EditorialConf;sub get {$_[0]{$_[1]}}
    package MB826EditorialClient;sub submit {my ($s,$r,%a)=@_;push @{$s->{calls}},[$r,$a{on_done}];1}
}
my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'gemini.API_KEY'=>'YOUR_GEMINI_TEST_KEY','meta_ai.OPENAI_MODEL'=>'gpt-4o'},'MB826EditorialConf';
sub fixture {
    my ($q,%opt)=@_;my (@calls,@out);
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),
        client=>bless({calls=>\@calls},'MB826EditorialClient'),evidence_mode=>'passage_ids',
        web_start=>sub {$_[1]->($opt{web_fails}?{ok=>0}:{ok=>1,sources=>[
            {id=>1,url=>'https://project.example.org/overview',text=>'The core application is free and can operate locally without a subscription.'},
            {id=>2,url=>'https://project.example.org/integrations',text=>'Some integrations depend on external cloud services and require an Internet connection.'}]});1});
    $engine->submit(prompt=>$q,messages=>[{role=>'user',content=>$q}],language=>$opt{language}//'fr',on_done=>sub {push @out,shift});
    for my $i (0..2) {$calls[$i][1]->({ok=>1,provider=>(qw(openai anthropic gemini))[$i],answer=>encode_json({answer=>'UNVERIFIED_DRAFT',needs_web=>0})})}
    return (\@calls,\@out);
}
for my $q ('À quoi sert ce système, est-il gratuit et fonctionne-t-il sans Internet ?',
    'The difference between an e-reader and a tablet', 'Je voudrais comprendre les marées',
    'How can I travel from Lyon to Turin without a car?', 'Un endroit où observer le ciel près de Lyon') {
    my ($calls,$out)=fixture($q);
    my $request=$calls->[3][0];
    is($request->{purpose},'meta_synthesis_passages','general editorial synthesis uses real proof catalogue');
    like($request->{system},qr/cover the actual request/,'actual synthesis receives multi-part answer requirements');
    like($request->{system},qr/available on the official website/,'actual model is told why a generic destination sentence is empty');
    like($request->{system},qr/condition or limitation supported by the evidence/,'practical detail must be grounded, never fabricated to fill room');
    like($request->{system},qr/Web knowledge is open-domain/,'editorial scope is not tied to software or vulnerabilities');
    unlike($request->{system},qr/UNVERIFIED_DRAFT/,'editorial improvement does not turn contributor assertions into evidence');
    my ($json)=$request->{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
    my $sources=JSON::PP->new->decode($json);
    my $answer='Le cœur est gratuit et fonctionne localement sans abonnement. Certaines intégrations nécessitent toutefois Internet parce qu’elles dépendent du cloud du fabricant.';
    $calls->[3][1]->({ok=>1,provider=>'openai',answer=>JSON::PP->new->encode({answer=>$answer,source_ids=>[1,2],basis=>'supported',support=>[
        map {+{source_id=>$_->{id},passage_id=>$_->{passages}[0]{passage_id}}} @$sources]})});
    ok($out->[0]{ok} && $out->[0]{evidence_anchors}==2,'multi-part output retains both real source anchors');
    is($out->[0]{answer},$answer,'useful qualification reaches final output intact');
    my $lines=format_meta_reply($out->[0]{answer});
    like(join(' ',@$lines),qr/Certaines intégrations nécessitent toutefois Internet/,'qualification survives compact IRC formatting');
    ok(@$lines<=2 && !grep(length(encode('UTF-8',$_))>400,@$lines),'two-line UTF-8 envelope is unchanged');
    is(scalar(@$calls),4,'three contributors and one synthesis; no editorial retry or extra provider call');
}
my ($calls,$out)=fixture('Je cherche une définition précise',web_fails=>1,language=>'en');
is($calls->[3][0]{purpose},'meta_web','failed shared research still uses native search fallback');
like($calls->[3][0]{system},qr/ANSWER QUALITY: cover the actual request/,'native fallback receives the same editorial policy');
like($calls->[3][0]{system},qr/never authorizes invented sources/,'quality requests cannot weaken reference or rights boundaries');
$calls->[3][1]->({ok=>1,answer=>'A concrete definition with its practical use.',sources=>[{url=>'https://official.example.org/reference'}]});
ok($out->[0]{ok} && $out->[0]{web_used},'native reply still requires actual cited source metadata');

# Real concurrent provider workers and actual adapter payloads. The HTTP bodies
# are fixtures: these tests establish wiring, not live generated prose quality.
require IO::Async::Loop;
require Time::HiRes;
my $loop=IO::Async::Loop->new;
my $ai=Mediabot::AI::Client->new(conf=>$conf,loop_owner=>{loop=>$loop},
    config_overrides=>{'openai.API_URL'=>'https://api.openai.com/v1/responses','openai.MODEL'=>'gpt-4o'},
    http_factory=>sub {bless {},'MB826EditorialHTTP'});
my @async;
my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$ai,evidence_mode=>'passage_ids',
    web_start=>sub {$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://official.example.org/tides',
        text=>'Tides are caused mainly by gravitational interactions with the Moon and the Sun.'}]});1});
$engine->submit(prompt=>'Je voudrais comprendre les marées',messages=>[{role=>'user',content=>'Je voudrais comprendre les marées'}],
    on_done=>sub {push @async,shift});
is(scalar(@async),0,'general informational requests do not synchronously block the IRC loop');
my $deadline=Time::HiRes::time()+12;
$loop->loop_once(0.05) while !@async && Time::HiRes::time()<$deadline;
is(scalar(@async),1,'real workers produce one final general response');
ok($async[0]{ok} && $async[0]{web_used} && $async[0]{evidence_anchors}==1,'real researched worker flow preserves proof resolution');
is_deeply($async[0]{contributors},[qw(openai anthropic gemini)],'all three provider contributors remain active');
is($async[0]{citation_repair},0,'ordinary editorial improvement adds no repair call');
done_testing;
package MB826EditorialHTTP;
sub request {
    my ($self,$method,$url,$opts)=@_;
    my $body=JSON::PP::decode_json($opts->{content});
    my $provider=$url=~/anthropic/?'anthropic':$url=~/googleapis/?'gemini':'openai';
    my $system=$provider eq 'anthropic'?$body->{system}:$provider eq 'gemini'?$body->{systemInstruction}{parts}[0]{text}:$body->{instructions};
    my $text;
    if ($system=~/^UNTRUSTED SOURCES: ([^\n]+)/m) {
        my $json=$1;
        die 'editorial contract missing in real payload' unless $system=~/ANSWER QUALITY: cover the actual request/;
        my $sources=JSON::PP->new->decode($json);my $passage=$sources->[0]{passages}[0]{passage_id};
        $text=JSON::PP::encode_json({answer=>'Tides mainly result from the gravitational influence of the Moon and the Sun.',source_ids=>[1],basis=>'supported',
            support=>[{source_id=>1,passage_id=>$passage}]});
    }
    else {$text=JSON::PP::encode_json({answer=>'Independent explanatory draft.',needs_web=>0})}
    my $response=$provider eq 'anthropic'?{content=>[{type=>'text',text=>$text}]}
        :$provider eq 'gemini'?{candidates=>[{content=>{parts=>[{text=>$text}]}}]}
        :{output=>[{type=>'message',content=>[{type=>'output_text',text=>$text}]}]};
    return {success=>1,status=>200,content=>JSON::PP::encode_json($response)};
}
