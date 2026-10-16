use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaPolicy qw(wants_web research_kind settings);
use Mediabot::AI::MetaEvidence qw(research_plan select_sources);
use Mediabot::AI::MetaWeb;
use Mediabot::AI::MetaChat;
my @requests=(
    'Je voudrais comprendre la différence entre météo et climat',
    'Paris Lyon en train', 'I need information about the Library of Alexandria',
    'L’âge de l’Univers', 'La capitale de la Croatie', 'Marie Curie prix Nobel',
    'Besoin d’aide pour choisir une liseuse', 'Aide-moi à préparer une randonnée en Bretagne',
    'Un endroit pour voir des aurores boréales', 'La signification de ce proverbe : pierre qui roule',
    'Tell me about the history of jazz', 'Explain how tides work',
    'J’aimerais savoir comment conserver du basilic', 'Mont Saint-Michel accès en vélo',
    'Je cherche les règles officielles du go', 'Les horaires du musée aujourd’hui',
    'Le prochain passage de la comète de Halley', 'Les différences entre une SARL et une SAS',
    'How does a heat pump work?', 'A comparison of induction and ceramic cooktops',
    'A recipe for risotto without wine', 'My name server does not resolve this domain',
    'Mon code Python produit une erreur de syntaxe', 'À quelle heure ouvre ce musée ?',
    'The author of The Left Hand of Darkness', 'Les formalités pour voyager au Canada',
    'Help me choose a telescope', 'Calculate the current cost of a solar installation',
    'Convertis 2 bitcoins en euros', 'Le mécanisme des vaccins à ARN messager',
    'Je veux des informations sur les stations spatiales', 'La différence entre un logiciel libre et gratuit');
for my $q (@requests) {ok(wants_web($q),"open-domain request researches without special vocabulary: $q")}
for my $q ('salut ça va ?', 'hey! how are you?', 'merci pour ta réponse',
    'peux-tu me raconter une histoire ?', 'tu peux m’écrire un poème ?',
    'c’est parfait', 'ça marche', 'tu es là ?', '', '...','merci beaucoup !','ok','yes','salut !','mon mot repère est hibou',
    'quel est mon mot repère ?','remember my keyword','what is my name?',
    'je m’appelle Christophe','calcule 2+2','12 / 3','convertis 2 km en mètres',
    'traduis ce texte en anglais','peux-tu m’écrire un poème ?',
    'can you write a poem?','résume ce texte : bonjour tout le monde') {
    ok(!wants_web($q),"local conversational task does not force public research: $q");
}
my $date='2026-10-16';
my $p=research_plan(prompt=>'et pour les enfants ?',date=>$date,messages=>[
    {role=>'user',content=>'speaker1 (Alice): préparer une visite au musée des Confluences'},
    {role=>'assistant',content=>'UNVERIFIED_ASSISTANT_TOPIC'},
    {role=>'user',content=>'speaker2 (Bob): merci beaucoup !'},
    {role=>'assistant',content=>'Avec plaisir.'},
    {role=>'user',content=>'speaker1 (Alice): et pour les enfants ?'}]);
like($p->{query},qr/visite au musée.*enfants/s,'follow-up resolves through an intervening acknowledgement');
unlike($p->{query},qr/merci|UNVERIFIED|speaker|Alice|Bob/,'acknowledgements, assistant assertions and labels are not search subjects');
$p=research_plan(prompt=>'La capitale de la Croatie',date=>$date,messages=>[
    {role=>'user',content=>'speaker1: dernier débat politique'},
    {role=>'assistant',content=>'UNVERIFIED_POLITICAL_DETAIL'},
    {role=>'user',content=>'speaker2: La capitale de la Croatie'}]);
is($p->{query},'La capitale de la Croatie','independent fragment does not inherit the preceding subject');
is($p->{domain_mode},'prefer','open-domain requests keep soft preferences');
for my $q ('Les horaires du musée aujourd’hui','Météo à Lyon cette semaine',
    'Les règles actuelles pour voyager au Canada','Je cherche un logiciel récent de dessin',
    'The train timetable this week','Le prix actuel de ce produit') {
    my $p=research_plan(prompt=>$q,date=>$date);
    ok(!exists($p->{start_date}),"current fact does not demand a recently published page: $q");
    my $rows=select_sources([{url=>'https://official.example.org/reference',title=>'Official reference',
        content=>'Official information covering the requested reference question, rules, timetable and opening hours.',
        published_date=>'2020-01-01'}],$p);
    is(scalar(@$rows),1,'an older official reference page remains eligible');
}
for my $q ('les actualités aujourd’hui','today news','des exemples récents de fraude',
    'this week incidents','des articles récents sur le climat') {
    ok(exists(research_plan(prompt=>$q,date=>$date)->{start_date}),"explicit recent reports retain a publication window: $q");
}
is(research_plan(prompt=>'un rapport publié en 2025',date=>$date)->{start_date},'2025-01-01','explicit publication year is preserved');

my (@http,@responses);
my $plan=research_plan(prompt=>'Les horaires du musée aujourd’hui',date=>$date,domains=>['reuters.com']);
@responses=({success=>1,status=>200,content=>encode_json({results=>[
    {url=>'https://museum.example.org/hours',title=>'Museum opening hours',content=>'The museum opening hours and holiday exceptions are documented on this official reference page.',published_date=>'2020-01-01'},
    {url=>'https://museum.example.org/visit',title=>'Museum visit hours',content=>'Museum visits and opening hours are listed here along with access conditions for visitors.',published_date=>'2021-01-01'}]})},
    {success=>1,status=>200,content=>encode_json({results=>[]})},
    {success=>1,status=>200,content=>encode_json({results=>[]})});
my $web=Mediabot::AI::MetaWeb->new(api_key=>'YOUR_TAVILY_TEST_KEY',http_factory=>sub {bless {},'MB826RequestHTTP'});
my $found=$web->search($plan->{query},plan=>$plan);
ok($found->{ok},'real Search/Extract route can use reference pages older than today');
my $parameters=decode_json($http[0][2]{content});
ok(!exists($parameters->{start_date}) && !exists($parameters->{filter_by_published_date}),'real outgoing request has no false publication freshness filter');
is($parameters->{include_domains_mode},'prefer','real search can reach non-news sites');
cmp_ok(scalar(@http),'<=',3,'general research retains two searches plus one extraction maximum');

my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'meta_ai.PROVIDERS'=>'openai anthropic'},'MB826RequestConf';
for my $q (@requests) {
    my (@calls,@out,$web_calls);
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),
        client=>bless({calls=>\@calls},'MB826RequestClient'),evidence_mode=>'passage_ids',
        web_start=>sub {$web_calls++;$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://official.example.org/reference',
            text=>'This official source contains the reference information supporting the example response.'}]});1});
    $engine->submit(prompt=>$q,messages=>[{role=>'user',content=>$q}],on_done=>sub {push @out,shift});
    for my $i (0,1) {$calls[$i][1]->({ok=>1,answer=>encode_json({answer=>'UNVERIFIED_DRAFT_FACT',needs_web=>0})})}
    is($web_calls,1,'no learned-knowledge draft can veto broad factual research');
    my ($json)=$calls[2][0]{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
    my $source=JSON::PP->new->decode($json)->[0];
    $calls[2][1]->({ok=>1,provider=>'openai',answer=>encode_json({answer=>'A concise supported reference answer.',source_ids=>[1],basis=>'supported',
        support=>[{source_id=>1,passage_id=>$source->{passages}[0]{passage_id}}]})});
    ok($out[0]{ok} && $out[0]{web_used} && $out[0]{evidence_anchors}==1,'broad response retains exact locally resolved evidence');
    is(scalar(@calls),3,'two configured contributors plus one synthesis; no extra routing or editorial request');
}
done_testing;
package MB826RequestConf;
sub get {$_[0]{$_[1]}}
package MB826RequestClient;
sub submit {my ($s,$r,%a)=@_;push @{$s->{calls}},[$r,$a{on_done}];1}
package MB826RequestHTTP;
sub request {push @http,[@_[1..3]];shift @responses}
