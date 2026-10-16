use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaPolicy qw(settings research_kind wants_web);
use Mediabot::AI::MetaEvidence qw(research_plan);
use Mediabot::AI::MetaWeb;
use Mediabot::AI::MetaChat;

my @questions=(
    'Où trouver les horaires du musée des Confluences ?',
    'Quel outil gratuit pour découper une vidéo sous Linux ?',
    'What is the difference between an e-reader and a tablet?',
    'À quoi sert Home Assistant ?',
    'Comment aller de Lyon à Turin en train ?',
    'Who wrote The Left Hand of Darkness?',
    'Quelle est la masse du proton ?',
    'Pourquoi le ciel est bleu ?',
    'Explique les règles du jeu de go',
    'Where can I find the official OBS documentation?',
    'Combien de temps dure la visite du château de Guédelon ?',
    'Peux-tu me conseiller un lecteur de livres numériques ?');
for my $q (@questions) {ok(wants_web($q),"natural factual question starts research: $q")}
for my $q ('bonjour','merci !','quel est mon mot repère ?','what is my keyword?',
    'write a short poem','invente une histoire de dragon','traduis ce texte en anglais',
    'comment vas-tu ?','how are you?') {
    ok(!wants_web($q),"conversation or creative request does not force search: $q");
}
my $history=[{role=>'user',content=>'speaker1 (Alice): dernières élections en France'},
    {role=>'assistant',content=>'A made-up assertion about PRIVATE_OLD_TOPIC'},
    {role=>'user',content=>'speaker2 (Bob): où trouver les horaires du musée ?'}];
my $p=research_plan(prompt=>'où trouver les horaires du musée ?',messages=>$history,
    date=>'2026-10-16',domains=>['reuters.com']);
unlike($p->{query},qr/élections|France|PRIVATE_OLD_TOPIC|speaker|Alice|Bob/,'independent question cannot inherit the previous subject');
is($p->{domain_mode},'prefer','every factual subject can escape the configured domain list');
ok(!exists($p->{start_date}),'a general reference question has no news publication window');
$p=research_plan(prompt=>'et sous Windows ?',messages=>[
    {role=>'user',content=>'speaker1 (Alice): quel logiciel gratuit pour découper une vidéo ?'},
    {role=>'assistant',content=>'PRIVATE_UNVERIFIED_SOFTWARE'},
    {role=>'user',content=>'speaker2 (Bob): et sous Windows ?'}],date=>'2026-10-16');
like($p->{query},qr/vidéo.*Windows/s,'genuine follow-up keeps the previous user subject');
is($p->{kind},'software','follow-up retains a software research profile');
unlike($p->{query},qr/PRIVATE|speaker|Alice|Bob/,'no assistant assertions or speaker labels in search');

my (@calls,@responses);
$p=research_plan(prompt=>'où trouver les horaires du musée ?',date=>'2026-10-16',domains=>['reuters.com']);
@responses=({success=>1,status=>200,content=>encode_json({results=>[
    {url=>'https://museum.example.org/opening',title=>'Musée horaires',content=>'Le musée ouvre du mardi au dimanche de dix heures à dix-huit heures.'},
    {url=>'https://city.example.org/museum',title=>'Musée horaires accès',content=>'Les horaires du musée sont publiés sur le site officiel avec les fermetures exceptionnelles.'}]})},
    {success=>1,status=>200,content=>encode_json({results=>[]})});
my $web=Mediabot::AI::MetaWeb->new(api_key=>'YOUR_TAVILY_TEST_KEY',http_factory=>sub {bless {},'MB825HTTP'});
my $found=$web->search($p->{query},plan=>$p);
ok($found->{ok},'actual Search/Extract transport accepts useful non-news pages');
my $body=decode_json($calls[0][2]{content});
is($body->{include_domains_mode},'prefer','a general question uses soft preferences in the real outgoing payload');
is($body->{topic},'general','no news topic is injected');
ok(!exists($body->{start_date}) && !exists($body->{end_date}),'no news time window is injected');
is(scalar(@calls),2,'one useful search plus one extraction, with no extra planner API call');

# Exercise contributors -> broad research -> actual passage catalogue -> synthesis,
# including the case where both contributors mistakenly say no web is needed.
my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'meta_ai.PROVIDERS'=>'openai anthropic'},'MB825Conf';
for my $q (@questions) {
    my (@requests,$out,$web_count);
    my $client=bless {calls=>\@requests},'MB825Client';
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$client,
        evidence_mode=>'passage_ids',web_start=>sub {$web_count++;$_[1]->({ok=>1,sources=>$found->{sources}});1});
    $engine->submit(prompt=>$q,messages=>[{role=>'user',content=>$q}],language=>'fr',on_done=>sub {$out=shift});
    for my $i (0,1) {$requests[$i][1]->({ok=>1,answer=>encode_json({answer=>'UNVERIFIED_FACT',needs_web=>JSON::PP::false,query=>$q})})}
    is($web_count,1,'factual intent is not vetoed by learned-knowledge contributor drafts');
    my ($json)=$requests[2][0]{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
    my $rows=JSON::PP->new->decode($json);
    $requests[2][1]->({ok=>1,provider=>'openai',answer=>encode_json({answer=>'Les horaires sont publiés sur le site du musée.',
        source_ids=>[1],basis=>'supported',support=>[{source_id=>1,passage_id=>$rows->[0]{passages}[0]{passage_id}}]})});
    ok($out->{ok} && $out->{web_used} && $out->{evidence_anchors}==1,'general route retains real passage validation and cited source');
    unlike($requests[2][0]{system},qr/UNVERIFIED_FACT/,'unverified draft facts never become evidence');
}
done_testing;
package MB825HTTP;
sub request {push @calls,[@_[1..3]];shift @responses}
package MB825Conf;
sub get {$_[0]{$_[1]}}
package MB825Client;
sub submit {my ($s,$r,%args)=@_;push @{$s->{calls}},[$r,$args{on_done}];1}
