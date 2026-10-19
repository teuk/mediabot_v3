use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::AI::MetaPolicy qw(wants_web research_kind research_needed is_acknowledgement);

my $weight='si tu pese 104.6 kg et que tu perds 10kg et tu en reprends 5 etc , en combien de cycles arrives tu a 91?';
my @local=(
    $weight,
    'Si je pèse 104,6 kg, je perds 10 kg puis reprends 5 kg par cycle : combien de cycles pour passer sous 91 kg ?',
    'If I start at 104.6 kg and lose 10 then regain 5, how many cycles to reach 91?',
    'J’ai 100 billes, je perds 10 puis en gagne 5 : combien après 3 cycles ?',
    'Calcule 20 + 5', '104.6 - 10 + 5', 'convertis 2 kg en grammes',
    "wie geht's", 'wie geht’s ?', 'wie gehts?', 'hallo, wie geht es dir ?',
    'gut und du ?', 'danke !', '¿qué tal?', 'come stai ?',
    'traduis ce texte en anglais', 'traduis : les prix actuels et les sources officielles',
    'translate "check the latest sources" into French',
    q{traduis 'les prix actuels' en anglais}, 'corrige mon code source',
    'résume ce texte : voici des nouvelles de notre médecin',
    'mon mot repère est bitcoin', 'my keyword is latest version',
);
for my $prompt (@local) {
    ok(!wants_web($prompt),"self-contained input does not request research: $prompt");
    is(research_kind($prompt),'general','no technical/research profile is invented');
    ok(!research_needed(prompt=>$prompt,kind=>'cve',minimum=>2,
        drafts=>[{needs_web=>1,task_type=>'factual'},{needs_web=>1,task_type=>'factual'}]),
        'an inherited topic or overcautious contributors cannot force a self-contained task onto the web');
}
ok(is_acknowledgement("wie geht's"),'German greeting is conversation, not a dictionary lookup');
ok(!is_acknowledgement('hallo, quelle est la dernière version de Debian ?'),'greeting followed by a factual request remains a question');

my @research=(
    'pourquoi le ciel devient-il rouge au coucher du soleil ?',
    'La capitale de la Croatie', 'Paris Lyon en train',
    'Quels sont les candidats principaux à la présidentielle 2027 ?',
    'Les horaires du musée d’Orsay ce dimanche et faut-il réserver ?',
    'Et combien coûte l’entrée ?', 'what is the latest release?',
    'Quel logiciel libre pour modifier un PDF sous Linux ?',
    'comment configurer cette API ?', 'détail de CVE-2024-3094',
    'Convertis 2 bitcoins en euros', 'Calculate the current cost of a solar installation',
    'Je perds 10 kg et reprends 5 : est-ce dangereux pour ma santé ?',
    'Si je prends 2 médicaments, quel dosage est recommandé ?',
    'Calcule mes impôts sur 100000 euros',
    'Traduis le contenu de https://example.org/article',
    'traduis ce texte et cite tes sources',
    'Vérifie ce calcul sur le web : 2 + 2',
    'calcule 2+2 et donne des références officielles',
    'Écris un résumé des dernières actualités',
);
for my $prompt (@research) {
    ok(wants_web($prompt),"external factual/explicit request remains researchable: $prompt");
    ok(research_needed(prompt=>$prompt,kind=>research_kind($prompt),minimum=>2,
        drafts=>[{needs_web=>0,task_type=>'factual'},{needs_web=>0,task_type=>'factual'}]),
        'needs_web=false alone never vetoes factual research');
}
for my $prompt (@research[3..$#research]) {
    ok(research_needed(prompt=>$prompt,kind=>research_kind($prompt),minimum=>2,
        drafts=>[{needs_web=>0,task_type=>'calculation'},{needs_web=>0,task_type=>'calculation'}]),
        'strong factual and explicit requests resist erroneous local classifications');
}
my $free='How would you phrase this more politely? Please leave me alone.';
my $pair=[{task_type=>'transformation',needs_web=>0},{task_type=>'transformation',needs_web=>0}];
ok(!research_needed(prompt=>$free,drafts=>$pair,minimum=>2),'independent contributor routing handles wording beyond fixed patterns');
ok(research_needed(prompt=>$free,drafts=>$pair,minimum=>3),'a configured higher quorum is retained');
ok(research_needed(prompt=>$free,drafts=>[$pair->[0]],minimum=>1),'a single model cannot suppress broad research through classification');
ok(research_needed(prompt=>$free,drafts=>[$pair->[0],{needs_web=>0}]),'a missing task label does not opt out of research');
ok(research_needed(prompt=>$free,drafts=>[$pair->[0],{task_type=>'factual',needs_web=>0}]),'a factual contributor prevents semantic local routing');
ok(research_needed(prompt=>$free,drafts=>[$pair->[0],{task_type=>'translation',needs_web=>0}]),'disagreeing task classifications retain research');
ok(research_needed(prompt=>$free,drafts=>[$pair->[0],{task_type=>'transformation',needs_web=>1}]),'a semantic local request with unresolved verification retains research');
ok(research_needed(prompt=>$weight,mode=>'always',drafts=>$pair),'explicit always mode remains authoritative');
ok(!research_needed(prompt=>$weight,mode=>'off',drafts=>$pair),'web off still permits pure arithmetic');
done_testing;
