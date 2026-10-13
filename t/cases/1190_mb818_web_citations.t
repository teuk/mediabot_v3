use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaChat;
use Mediabot::AI::Provider::OpenAI;
use Mediabot::AI::Request qw(build_request);
{
    package MB818CiteConf;
    sub get {$_[0]{$_[1]}}
    package MB818CiteClient;
    sub submit {my ($self,$r,%opts)=@_;push @{$self->{calls}},{request=>$r,done=>$opts{on_done}};1}
}
my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'meta_ai.PROVIDERS'=>'openai anthropic','meta_ai.OPENAI_MODEL'=>'gpt-4o'},'MB818CiteConf';
my $sources=[{id=>1,url=>'https://example.org/election',text=>'Evidence about an electoral calendar.',kind=>'page_excerpt'},
             {id=>2,url=>'https://other.example.org/election',text=>'Independent context about institutions.',kind=>'search_excerpt'}];
sub fixture {
    my $client=bless {calls=>[]},'MB818CiteClient';my @results;my $searches=0;
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$client,
        web_start=>sub {$searches++;$_[1]->({ok=>1,sources=>$sources});1});
    $engine->submit(prompt=>'que penses-tu des présidentielles de 2027',language=>'fr',
        messages=>[{role=>'user',content=>'speaker1: que penses-tu des présidentielles de 2027'}],
        on_done=>sub {push @results,shift});
    for my $i (0..1) {$client->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>1,query=>'France electoral calendar'})})}
    return ($client,\@results,\$searches);
}
my ($client,$results,$searches)=fixture();
is($client->{calls}[2]{request}{purpose},'meta_synthesis_web','researched synthesis has its own schema purpose');
like($client->{calls}[2]{request}{system},qr/nonempty source_ids array/,'nonempty references are explicit in the synthesis prompt');
like($client->{calls}[2]{request}{system},qr/separate supported facts from your analysis/,'future election opinions remain separate from facts');
$client->{calls}[2]{done}->({ok=>1,provider=>'openai',answer=>encode_json({answer=>'Grounded analysis.',source_ids=>[]})});
is(scalar(@$results),0,'observed empty citation result is withheld before correction');
is(scalar(@{$client->{calls}}),4,'empty citations cause exactly one additional synthesis request');
is($client->{calls}[3]{request}{purpose},'meta_citation_repair','correction uses the strict citation purpose');
is($client->{calls}[3]{request}{provider},'openai','correction stays on successful synthesis provider');
is($$searches,1,'correction does not repeat search');
is_deeply($client->{calls}[3]{request}{messages},$client->{calls}[2]{request}{messages},'correction preserves conversation context');
like($client->{calls}[3]{request}{system},qr/selected from \[1, 2\]/,'correction states the exact supplied ID set');
$client->{calls}[3]{done}->({ok=>1,provider=>'openai',answer=>encode_json({answer=>'A supported analysis.',source_ids=>[2]})});
is(scalar(@$results),1,'corrected answer completes only once');
ok($results->[0]{ok} && $results->[0]{web_used},'corrected answer is researched');
is_deeply($results->[0]{sources},[$sources->[1]],'only evidence actually selected by synthesis is linked');
is_deeply($results->[0]{contributors},[qw(openai anthropic)],'both contributors survive citation correction');
ok($results->[0]{citation_repair},'repair is observable as bounded metadata');
$client->{calls}[2]{done}->({ok=>1,answer=>encode_json({answer=>'Late reply',source_ids=>[1]})});
is(scalar(@$results),1,'duplicate initial callbacks cannot revive a completed correction');

($client,$results,$searches)=fixture();
$client->{calls}[2]{done}->({ok=>1,provider=>'anthropic',answer=>encode_json({answer=>'Draft synthesis.',source_ids=>[]})});
is($client->{calls}[3]{request}{provider},'anthropic','fallback Claude synthesis is repaired by Claude');
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'Still uncited.',source_ids=>[]})});
is($results->[0]{error},'web_missing_citations','second omission is an explicit failure');
is(scalar(@{$client->{calls}}),4,'no correction loop after repeated missing references');
is($$searches,1,'repeated missing references never refetch evidence');
ok(!exists($results->[0]{answer}) && !exists($results->[0]{sources}),'uncited answer and arbitrary links are not exposed');

for my $ids ([99],[1,99],['https://invented.example.org/'],{id=>1},undef) {
    ($client,$results,$searches)=fixture();
    $client->{calls}[2]{done}->({ok=>1,answer=>encode_json({answer=>'Claim',source_ids=>$ids})});
    is($results->[0]{error},'unsupported_web_answer','invented or malformed source references remain rejected');
    is(scalar(@{$client->{calls}}),3,'invalid references are not silently corrected into valid citations');
}
($client,$results,$searches)=fixture();
$client->{calls}[2]{done}->({ok=>1,answer=>encode_json({answer=>'No source_ids property.'})});
is($client->{calls}[3]{request}{purpose},'meta_citation_repair','an omitted source field gets the same one correction');
$client->{calls}[3]{done}->({ok=>0,error=>'http_error',status=>503});
is($results->[0]{error},'web_synthesis_failed','failed correction never becomes a sourced success');
is(scalar(@{$client->{calls}}),4,'failed correction has no retry cascade');

for my $result ({ok=>0,error=>'http_error',status=>503},{ok=>1,answer=>'plain non-JSON output'}) {
    ($client,$results,$searches)=fixture();$client->{calls}[2]{done}->($result);
    is($results->[0]{error},'web_synthesis_failed','research synthesis failure is classified as a web stage');
    is(scalar(@{$client->{calls}}),3,'network or malformed synthesis is not retried as missing citations');
}

for my $model (qw(gpt-4o gpt-4o-mini gpt-6.1-sol)) {
    for my $purpose (qw(meta_synthesis_web meta_citation_repair)) {
        my $r=build_request(provider=>'openai',purpose=>$purpose,model=>$model,
            messages=>[{role=>'user',content=>'Question'}],max_output_tokens=>2048);
        my $p=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($r,{api_style=>'responses'}));
        my $format=$p->{text}{format};
        is($format->{type},'json_schema',"$model $purpose uses Responses structured outputs");
        ok($format->{strict},'schema adherence is explicit');
        is($format->{schema}{properties}{source_ids}{minItems},1,'researched schema prohibits an empty source array');
        is_deeply($format->{schema}{properties}{source_ids}{items}{enum},[1,2,3],'schema has only bounded evidence IDs');
        is_deeply($format->{schema}{required},[qw(answer source_ids)],'answer and references are required');
        ok(!$format->{schema}{additionalProperties},'unexpected schema fields are prohibited');
        ok(!$p->{store},'structured output retains remote-storage opt-out');
    }
}
for my $purpose (qw(meta_probe meta_draft meta_synthesis meta_web)) {
    my $r=build_request(provider=>'openai',purpose=>$purpose,model=>'gpt-4o',
        messages=>[{role=>'user',content=>'Question'}],max_output_tokens=>2048);
    my $p=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($r,{api_style=>'responses'}));
    ok(!exists($p->{text}),"$purpose retains its existing response format");
    my $legacy=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($r));
    ok(!exists($legacy->{text}) && !exists($legacy->{response_format}),'legacy Chat Completions has no new schema');
}
for my $model (qw(gpt-4o-2024-05-13 ft:gpt-4o:example)) {
    my $r=build_request(provider=>'openai',purpose=>'meta_synthesis_web',model=>$model,
        messages=>[{role=>'user',content=>'Question'}],max_output_tokens=>2048);
    my $p=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($r,{api_style=>'responses'}));
    ok(!exists($p->{text}),'unsupported old/fine-tuned models retain prompt-only citation contract');
}
done_testing;
