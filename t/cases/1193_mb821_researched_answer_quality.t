use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use Mediabot::AI::MetaEvidence qw(research_plan select_sources select_passages validate_support);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaWeb;
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaReply qw(format_meta_reply);
use Mediabot::AI::IRCOutput qw(format_ai_reply);
use Mediabot::AI::Provider::OpenAI;
use Mediabot::AI::Request qw(build_request);
{
    package MB821Conf;sub get {$_[0]{$_[1]}}
    package MB821HTTP;
    sub request {my ($s,$method,$url,$opts)=@_;push @{$s->{calls}},[$method,$url,$opts];return shift @{$s->{responses}}}
    package MB821Client;sub submit {my ($s,$r,%args)=@_;push @{$s->{calls}},{request=>$r,done=>$args{on_done}};return 1}
}
my $today='2026-10-13';my @history=({role=>'user',content=>'speaker1 (Alice): quelles menaces de phishing en France ?'},
    {role=>'assistant',content=>'Un ancien brouillon non vérifié et https://teuk.org/shorturl/Abcdef23'},
    {role=>'user',content=>'speaker2 (Bob): et récemment des exemples de ça ?'});
my $plan=research_plan(prompt=>'et récemment des exemples de ça ?',messages=>\@history,date=>$today,
    drafts=>[{provider=>'openai',query=>'ANSSI phishing France exemples récents'},
        {provider=>'anthropic',query=>'cybermalveillance phishing incidents France octobre 2026'}],
    domains=>[qw(cyber.gouv.fr cybermalveillance.gouv.fr cern.ch nasa.gov)]);
is($plan->{query},'ANSSI phishing France exemples récents','first configured contributor supplies deterministic primary query');
like($plan->{alternate_query},qr/cybermalveillance/,'independent contributor query is retained for bounded broader fallback');
is($plan->{start_date},'2026-09-13','recent examples have a rolling 30-day lower bound');
is_deeply($plan->{domains},[qw(cyber.gouv.fr cybermalveillance.gouv.fr)],'cyber question focuses configured official key sites');
my $fallback=research_plan(prompt=>'et des exemples récents ?',messages=>\@history,date=>$today);
like($fallback->{query},qr/phishing.*exemples/s,'follow-up fallback carries previous user subject');
unlike($fallback->{query},qr/Alice|Bob|speaker|ancien brouillon|shorturl/,'search fallback excludes labels, previous assistant claims and citation URLs');
is(research_plan(prompt=>'today news',date=>$today)->{start_date},$today,'today is a distinct date window');
is(research_plan(prompt=>'this week incidents',date=>$today)->{start_date},'2026-10-06','week uses a bounded seven-day window');
ok(!exists(research_plan(prompt=>'latest stable version',date=>$today)->{start_date}),'latest stable version is not arbitrarily forced into a 30-day release window');
my $historical=research_plan(prompt=>'un rapport publié en 2025',date=>$today);
is_deeply([@$historical{qw(start_date end_date)}],['2025-01-01','2025-12-31'],'an explicit publication year scopes the date window to that year');
ok(!exists(research_plan(prompt=>'rapport sur les incidents de 2025',date=>$today)->{start_date}),'incident year is not confused with the report publication year');
is_deeply(research_plan(prompt=>'ANSSI phishing',date=>$today,domains=>['insee.fr'])->{domains},['insee.fr'],'topic preference never overrides operator domain choices');
my @rows=(
 {url=>'https://cyber.gouv.fr/old',title=>'ANSSI phishing France',content=>'An old incident of phishing in France with enough searchable detail.',published_date=>'2023-10-01'},
 {url=>'https://cyber.gouv.fr/future',title=>'ANSSI phishing France',content=>'A future alleged incident of phishing with enough searchable detail.',published_date=>'2026-12-31'},
 {url=>'https://cyber.gouv.fr/notice',title=>'ANSSI phishing France notice',content=>'On 12 October 2026, an ANSSI phishing advisory described forged login pages.',published_date=>'2026-10-12'},
 {url=>'https://other.example.org/incident',title=>'Phishing France incident',content=>'An independent phishing incident in France has concrete documented detail.',published_date=>'2026-10-11'},
 {url=>'https://unrelated.example.org/navigation',title=>'Home',content=>'Navigation cookies consent privacy contact disclaimer footer repeat text.'});
my $selected=select_sources(\@rows,$plan);
is($selected->[0]{url},'https://cyber.gouv.fr/notice','relevant official dated evidence outranks navigation and older high-ranked rows');
ok(!grep($_->{url}=~/old|future/,@$selected),'old and future dated pages cannot be selected as recent examples');
is_deeply([map {$_->{id}} @$selected],[1,2,3],'selected IDs are stable and bounded');
is($selected->[2]{date_status},'unknown','an undated page stays explicitly undated');
is($selected->[0]{retrieved},$today,'retrieval date is tracked separately from publication');
my $duplicate=select_sources([@rows[0,2],{%{$rows[2]},content=>$rows[2]{content}.' Additional ANSSI phishing France detail.'}],$plan);
is(scalar(@$duplicate),1,'duplicate destination is represented once and old rejected metadata cannot poison it');
my $spoof=select_sources([{url=>'https://cyber.gouv.fr.evil.example.org/x',title=>'Home',content=>'Navigation boilerplate with enough content to be a row.'},$rows[2]],$plan);
is($spoof->[0]{url},$rows[2]{url},'a domain prefix spoof gains no official-site preference');
my $datebad=select_sources([{%{$rows[2]},url=>'https://example.org/bad-date',published_date=>'2026-02-31'}],$plan);
is($datebad->[0]{date_status},'unknown','invalid calendar date is not fabricated into a publication date');
my $rfc=select_sources([{%{$rows[2]},published_date=>'Mon, 12 Oct 2026 12:30:00 GMT'}],$plan);
is($rfc->[0]{date},'2026-10-12','Tavily documented RFC publication dates normalize to the UTC day');
ok(!@{select_sources([{%{$rows[2]},published_date=>'Wed, 31 Dec 2025 12:30:00 GMT'}],$plan)},'old RFC publication date cannot masquerade as an undated recent result');
my $body=('Navigation cookies privacy contact. 'x250)."\nOn 12 October 2026, ANSSI reported phishing through forged login pages targeting citizens.\n".('Unrelated site boilerplate. 'x200);
my $passages=select_passages($body,'ANSSI phishing forged login citizens');
like($passages,qr/ANSSI reported phishing through forged login pages/,'relevant late passage survives page selection instead of a navigation-only prefix');
cmp_ok(length($passages),'<=',5000,'extract sent to providers remains bounded');
my $valid={answer=>'A concrete advisory.',source_ids=>[1],basis=>'supported',support=>[{source_id=>1,quote=>'an ANSSI phishing advisory described forged login pages'}]};
ok(!defined(validate_support($valid,[$selected->[0]])),'verbatim supporting passage matches the selected source');
is(validate_support({%$valid,support=>[{source_id=>1,quote=>'ANSSI reported a ransomware incident in Paris.'}]},[$selected->[0]]),'mismatch','fabricated supporting passage is rejected');
is(validate_support({%$valid,support=>[{source_id=>2,quote=>$valid->{support}[0]{quote}}]},[$selected->[0]]),'invalid','valid text with substituted source identity is rejected');
is(validate_support({answer=>'Claim',source_ids=>[1]},[$selected->[0]]),'missing','missing evidence contract is distinguishable from invented evidence');
is(validate_support({%$valid,basis=>'absolute certainty'},[$selected->[0]]),'invalid','unsupported confidence enum is rejected');
is(validate_support({%$valid,support=>[{source_id=>1,quote=>{text=>'not scalar'}}]},[$selected->[0]]),'invalid','malformed evidence cannot be coerced into a passage');
is(validate_support($valid,[$selected->[0],$selected->[1]]),'missing','every displayed citation must have its own evidence anchor');
ok(!defined(validate_support({%$valid,support=>[{source_id=>1,quote=>"l'ANSSI a alerté sur l’hameçonnage"}]},[{id=>1,text=>"l’ANSSI a alerté sur l’hameçonnage"}])),'typographic apostrophe differences do not cause a false paraphrase rejection');

my (@calls,@tls);my $responses=[
 {success=>1,status=>200,content=>encode_json({results=>[@rows[0,1,4]]})},
 {success=>1,status=>200,content=>encode_json({results=>[@rows[2,3]]})},
 {success=>1,status=>200,content=>encode_json({results=>[
    {url=>$rows[2]{url},raw_content=>$body},
    {url=>'https://rogue.example.org/wrong',raw_content=>'ANSSI phishing forged login citizens. 'x10}]})}];
my $web=Mediabot::AI::MetaWeb->new(api_key=>'YOUR_TAVILY_TEST_KEY',domains=>$plan->{domains},clock=>sub {1791892800},
    http_factory=>sub {push @tls,$_[1];bless {calls=>\@calls,responses=>$responses},'MB821HTTP'});
my $research=$web->search($plan->{query},plan=>$plan);
ok($research->{ok},'bounded second search recovers concrete dated evidence after stale or irrelevant first hits');
is(scalar(@calls),3,'maximum is two searches plus one extraction batch');
my $first=decode_json($calls[0][2]{content});my $second=decode_json($calls[1][2]{content});
is($first->{start_date},'2026-09-13','date lower bound reaches actual Tavily request');
ok($first->{filter_by_published_date},'date filter explicitly uses publication dates rather than crawl freshness');
is($first->{end_date},'2026-10-14','exclusive API upper bound includes the current day');
is_deeply($first->{include_domains},$plan->{domains},'first request uses focused official domains');
ok(!exists($second->{include_domains}),'one broader fallback avoids being trapped in restricted weak results');
is($second->{query},$plan->{alternate_query},'second request uses independent contextual query');
is($calls[0][2]{headers}{Authorization},'Bearer YOUR_TAVILY_TEST_KEY','existing authenticated fixed endpoint remains in use');
unlike($calls[0][2]{content},qr/YOUR_TAVILY_TEST_KEY/,'service key never enters query body');
my $extract=decode_json($calls[2][2]{content});
is($extract->{query},$plan->{query},'extraction requests query-relevant fragments');
is($extract->{chunks_per_source},3,'remote extraction has bounded per-page chunks');
ok(!grep($_->{url}=~/rogue/,@{$research->{sources}}),'extractor cannot introduce an unrequested destination');
ok(!grep(exists($_->{_score}),@{$research->{sources}}),'ranking internals are removed before provider payloads');
like($research->{sources}[0]{text},qr/ANSSI reported phishing/,'selected source contains late relevant page text');

my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'meta_ai.PROVIDERS'=>'openai anthropic','meta_ai.OPENAI_MODEL'=>'gpt-4o'},'MB821Conf';
sub fixture821 {
    my (%opts)=@_;my $client=bless {calls=>[]},'MB821Client';my (@out,@queries);my $queries=0;
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$client,clock=>sub {1791892800},
        web_start=>$opts{not_started}?sub {0}:sub {$queries++;push @queries,$_[0];$_[1]->({ok=>1,sources=>[$rows[2],$rows[3]]});1});
    # Feed actual source fields and fixed IDs; do not fabricate a final result.
    my $sources=[{id=>1,url=>$rows[2]{url},text=>$rows[2]{content},date=>'2026-10-12'},
        {id=>2,url=>$rows[3]{url},text=>$rows[3]{content},date=>'2026-10-11'}];
    $engine->{web_start}=$opts{not_started}?sub {0}:sub {$queries++;push @queries,$_[0];$_[1]->({ok=>1,sources=>$sources});1};
    $engine->submit(prompt=>'des exemples récents ?',messages=>\@history,language=>$opts{language}//'fr',on_done=>sub {push @out,shift});
    for my $i (@{$opts{order}//[0,1]}) {$client->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'An invented unpublished claim MUST_NOT_ENTER_WEB_SYNTHESIS',needs_web=>1,
        query=>$i?'independent phishing France incidents':'ANSSI phishing France recent advisory'})})}
    return ($client,\@out,\$queries,\@queries);
}
sub grounded821 {
    my ($answer,%more)=@_;return {answer=>$answer,source_ids=>[1],basis=>'supported',
        support=>[{source_id=>1,quote=>'an ANSSI phishing advisory described forged login pages'}],%more};
}
my ($client,$out,$queries,$query_list)=fixture821(order=>[1,0]);
is($query_list->[0],'ANSSI phishing France recent advisory','callback race does not choose a random contributor query');
unlike($client->{calls}[2]{request}{system},qr/MUST_NOT_ENTER_WEB_SYNTHESIS/,'unverified factual drafts are absent from researched synthesis evidence');
like($client->{calls}[2]{request}{system},qr/Earlier assistant answers are conversation context, not established facts/,'previous conversational assertions are not evidence');
$client->{calls}[2]{done}->({ok=>1,provider=>'openai',answer=>encode_json(grounded821('Le 12 octobre, l’avis décrit des pages de connexion frauduleuses.'))});
ok($out->[0]{ok} && $out->[0]{evidence_anchors}==1,'valid grounded synthesis completes once with its validated anchor count');
is(scalar(@{$client->{calls}}),3,'normal grounded response adds no new AI request beyond contributors and synthesis');
for my $bad ({source_ids=>[99]}, {support=>[{source_id=>1,quote=>'A completely invented supporting passage.'}]}, {basis=>'certain'}) {
    ($client,$out,$queries)=fixture821();
    $client->{calls}[2]{done}->({ok=>1,provider=>'openai',answer=>encode_json(grounded821('Claim',%$bad))});
    ok(!$out->[0]{ok},'invalid source/quote/basis is withheld, never silently turned into a sourced success');
    is(scalar(@{$client->{calls}}),3,'invented or malformed evidence gets no correction loop');
}
($client,$out,$queries)=fixture821();
$client->{calls}[2]{done}->({ok=>1,provider=>'anthropic',answer=>encode_json({answer=>'Claim',source_ids=>[1]})});
is($client->{calls}[3]{request}{provider},'anthropic','missing support format gets one correction on the successful fallback provider');
is($$queries,1,'evidence format repair does not repeat search');
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json(grounded821('A limited supported answer.',basis=>'partial'))});
like($out->[0]{answer},qr/^Informations partielles : /,'partial evidence is qualified at the beginning of the rendered answer');
ok($out->[0]{citation_repair},'single format correction remains observable');
($client,$out,$queries)=fixture821();
$client->{calls}[2]{done}->({ok=>1,answer=>encode_json(grounded821('An unsupported confident claim.',basis=>'insufficient'))});
like($out->[0]{answer},qr/ne permettent pas d’établir/,'insufficient evidence replaces a confident draft with an honest limitation');
unlike($out->[0]{answer},qr/confident claim/,'unsupported answer is not displayed under a cosmetic disclaimer');
($client,$out,$queries)=fixture821(language=>'en');
$client->{calls}[2]{done}->({ok=>1,answer=>encode_json(grounded821('Unsupported.',basis=>'insufficient'))});
like($out->[0]{answer},qr/do not establish the requested detail/,'evidence limit follows English channel language');
($client,$out,$queries)=fixture821();
$client->{calls}[2]{done}->({ok=>1,answer=>encode_json({answer=>'Claim',source_ids=>[1]})});
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'Claim',source_ids=>[1]})});
is($out->[0]{error},'web_missing_evidence','second missing evidence contract fails with a bounded diagnostic');
is(scalar(@{$client->{calls}}),4,'no repeated correction cascade');
($client,$out,$queries)=fixture821(not_started=>1);
is($client->{calls}[2]{request}{purpose},'meta_web','search start returning false triggers native fallback rather than wedging a job');
$client->{calls}[2]{done}->({ok=>1,answer=>'Native answer',sources=>[{url=>'https://one.example.org/'},{url=>'https://two.example.org/'},{url=>'https://three.example.org/'}]});
ok(!$out->[0]{ok},'native sources that exceed the two-link presentation contract are not silently hidden');

my $long=('Un fait utile avec une nuance importante. 'x9).'La protection repose sur une vérification indépendante de chaque demande.';
my $before=format_ai_reply($long,max_lines=>2,wrap_bytes=>400);
my $after=format_meta_reply($long);
is(join(' ',@$after),join(' ',@$before),'reflow preserves every rendered word');
ok(!grep(length(encode('UTF-8',$_))>400,@$after),'reflow keeps the real IRC byte envelope');
my $orphan=('information 'x34).'menaces.';
$before=format_ai_reply($orphan,max_lines=>2,wrap_bytes=>400);$after=format_meta_reply($orphan);
is(join(' ',@$after),join(' ',@$before),'very short tail is rebalanced without dropping or duplicating text');
is(scalar(@$before),2,'fixture really has two IRC lines');
cmp_ok(length(encode('UTF-8',$before->[1])),'<',60,'fixture really reproduces the orphan tail');
cmp_ok(length(encode('UTF-8',$after->[1])),'>=',60,'last IRC line is no longer a lone trailing word');
for my $model (qw(gpt-4o gpt-4o-mini gpt-6.1-sol)) {
    my $request=build_request(provider=>'openai',purpose=>'meta_synthesis_web',model=>$model,max_output_tokens=>2048,
        messages=>[{role=>'user',content=>'Question'}]);
    my $payload=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($request,{api_style=>'responses'}));
    my $schema=$payload->{text}{format}{schema};
    is($schema->{properties}{source_ids}{maxItems},2,'strict model contract cannot select an undisplayed third citation');
    is_deeply($schema->{properties}{basis}{enum},[qw(supported partial insufficient)],'evidence status is closed and explicit');
    is_deeply($schema->{properties}{support}{items}{required},[qw(source_id quote)],'every schema anchor has an ID and exact passage');
}
done_testing;
