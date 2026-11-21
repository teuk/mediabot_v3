use strict;
use DBI;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use IO::Async::Loop;
use Mediabot::AsyncWorker;
use Mediabot::AI::MetaRuntime;
use Mediabot::External ();
{
    package MB818RuntimeConf;
    sub get {$_[0]{$_[1]}}
    package MB818RuntimeGeneration;
    sub capture_generation {$_[0]{generation}}
    sub casemapping {$_[0]{casemapping}//'rfc1459'}
    package MB818RuntimeLogger;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB818RuntimeBot;
    sub getMessageNickIdentHost {my ($s,$message)=@_;return @$message}
    sub gethChannelsNicksOnChan {return @{$_[0]{nicks}{lc $_[1]}||[]}}
    package MB818RuntimeClient;
    sub submit {my ($s,$request,%args)=@_;push @{$s->{calls}},{request=>$request,done=>$args{on_done}};1}
    package MB818RuntimeYouTube;
    sub get {my ($self,$url)=@_;push @{$self->{calls}},$url;return $self->{response}}
    package MB818RuntimePreviewWorker;
    sub cancel {$_[0]{cancelled}++;1}
}
my (@sent,@notices,@timers,@opts,@queries);my $accepted=1;my $chanset=1;my $lang='fr';my $now=1791892800;
no warnings 'redefine';
local *Mediabot::Helpers::channel_lang=sub {$lang};
local *Mediabot::Helpers::chanset_enabled=sub {$chanset};
local *Mediabot::Helpers::botPrivmsg=sub {push @opts,$_[3];return 0 unless $accepted;push @sent,[$_[1],$_[2]];1};
local *Mediabot::Helpers::botNotice=sub {push @notices,[$_[1],$_[2]];1};
sub fixture {
    @sent=();@notices=();@timers=();@opts=();@queries=();$accepted=1;$chanset=1;$lang='fr';
    my $dir=tempdir(CLEANUP=>1);
    my $conf=bless {'meta_ai.ENABLED'=>1,'meta_ai.CHANNELS'=>'#test #other','meta_ai.STATE_FILE'=>"$dir/state.json",
        'openai.API_KEY'=>'fake-openai','anthropic.API_KEY'=>'fake-claude','gemini.API_KEY'=>'fake-gemini',
        'connection.CONN_SERVER_NETWORK'=>'test-network'},'MB818RuntimeConf';
    my $client=bless {calls=>[]},'MB818RuntimeClient';
    my $gate_db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $gate_db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    my $bot=bless {dbh=>$gate_db,conf=>$conf,config_file=>"$dir/mediabot.conf",
        wit_runtime_state=>bless({generation=>1},'MB818RuntimeGeneration'),
        logger=>bless({lines=>[]},'MB818RuntimeLogger')},'MB818RuntimeBot';
    my $runtime=Mediabot::AI::MetaRuntime->new(bot=>$bot,clock=>sub {$now},
        client_factory=>sub {$client},schedule_cb=>sub {push @timers,[@_]},
        web_start=>sub {push @queries,$_[0];$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://www.example.org/news',text=>'A verified page excerpt.',kind=>'page_excerpt'}]});1});
    $bot->{_meta_ai_runtime}=$runtime;
    return ($bot,$client,$runtime,$dir);
}
sub ask {Mediabot::AI::MetaRuntime::handle($_[0],[$_[1],'ident','public.example.org'],$_[1],$_[2],$_[3])}
sub drafts {my ($client,$start,$web)=@_;for my $i ($start..$start+2) {
    $client->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>$web?1:0,query=>'official latest update'})});
}}
sub final {my ($client,$index,$answer,$ids)=@_;$client->{calls}[$index]{done}->({ok=>1,
    answer=>encode_json({answer=>$answer,source_ids=>$ids//[],basis=>'supported',
        support=>[map {
            my $id=$_;my ($json)=$client->{calls}[$index]{request}{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
            my $catalogue=decode_json($json);my ($source)=grep {$_->{id}==$id} @$catalogue;
            +{source_id=>$id,passage_id=>$source->{passages}[0]{passage_id}}
        } @{$ids//[]}]})});}
sub history {my ($dir)=@_;return [] unless -e "$dir/state.json";
    open my $fh,'<:raw',"$dir/state.json" or die $!;local $/;my $state=decode_json(<$fh>);close $fh;
    return [map {@{$_->{turns}}} values %{$state->{rooms}}];}
my ($bot,$client,$runtime,$dir)=fixture();
$bot->{conf}{'meta_ai.ENABLED'}=0;
ok(!ask($bot,'Alice','#test','traduis ce texte en anglais'),'disabled mode preserves legacy route');
is(scalar(@{$client->{calls}}),0,'disabled mode makes no API call');
$bot->{conf}{'meta_ai.ENABLED'}=1;$chanset=0;
ok(!ask($bot,'Alice','#test','traduis ce texte en anglais'),'existing channel chatGPT gate is respected');
$chanset=1;
ok(!ask($bot,'Alice','#elsewhere','traduis ce texte en anglais'),'allowlist blocks unlisted channels');
ok(ask($bot,'Alice','#TEST','traduis ce texte en anglais'),'case-folded allowed channel starts collective mode');
is(scalar(@{$client->{calls}}),3,'runtime launches three independent contributor requests');
ask($bot,'Bob','#test','a follow-up');
like($notices[-1][1],qr/déjà en cours/,'another participant cannot start an overlapping job in the same channel');
drafts($client,0,0);final($client,3,'Une réponse utile. 'x60);
is(scalar(@sent),1,'first line is emitted immediately');
is(scalar(@timers),1,'second line waits for a timer');
is($timers[0][0],1.5,'configured default pacing is 1.5 seconds');
is(scalar(@{history($dir)}),0,'unfinished delivery is not retained in history');
ok($opts[0]{no_defer},'a flooded answer cannot be deferred beyond its generation gate');
$timers[0][1]->();
is(scalar(@sent),2,'second line is sent once');
ok(!grep(length(encode('UTF-8',$_->[1]))>400,@sent),'every emitted line respects 400 UTF-8 bytes');
is(scalar(@{history($dir)}),1,'completed delivered exchange is stored');
is(history($dir)->[0]{answer},join(' ',map {$_->[1]} @sent),'history retains the actual compact delivered answer');
is(scalar(keys %{$runtime->{jobs}}),0,'delivery releases channel job');
ask($bot,'Bob','#test','and for me?');
like($client->{calls}[4]{request}{messages}[0]{content},qr/^speaker1 \(Alice\):/,'prior participant is labelled in shared context');
like($client->{calls}[4]{request}{messages}[-1]{content},qr/^speaker2 \(Bob\):/,'different participant has a distinct stable label');
$bot->{wit_runtime_state}{generation}=2;drafts($client,4,0);
is(scalar(@{$client->{calls}}),7,'old generation stops before launching a paid synthesis');
is(scalar(@sent),2,'response from an old connection/channel generation is discarded');
is(scalar(keys %{$runtime->{jobs}}),0,'discarded response releases its job');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','traduis ce texte en anglais');drafts($client,0,0);final($client,3,'Long response. 'x70);
$bot->{conf}{'meta_ai.ENABLED'}=0;$timers[0][1]->();
is(scalar(@sent),1,'disabling the mode cancels the pending second line');
is(scalar(@{history($dir)}),0,'partially delivered answer is not saved as a complete exchange');

($bot,$client,$runtime,$dir)=fixture();$accepted=0;ask($bot,'Alice','#test','traduis ce texte en anglais');drafts($client,0,0);final($client,3,'Rejected answer');
is(scalar(@sent),0,'flood refusal sends no line');
is(scalar(@{history($dir)}),0,'flood-refused answer never enters memory');
is(scalar(keys %{$runtime->{jobs}}),0,'flood refusal releases the job');

($bot,$client,$runtime,$dir)=fixture();$runtime->{client_factory}=sub {die 'private exception'};
ask($bot,'Alice','#test','traduis ce texte en anglais');
is(scalar(keys %{$runtime->{jobs}}),0,'client construction failure cannot wedge the channel');
unlike($notices[-1][1],qr/private exception/,'private setup error is not exposed to IRC');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','mon mot repère : Alice');drafts($client,0,0);final($client,3,'Alice reply');
ask($bot,'Bob','#test','mon mot repère : Bob');drafts($client,4,0);final($client,7,'Bob reply');
Mediabot::AI::MetaRuntime::note_rename($bot,'Alice','Alicia','ident','public.example.org');
$bot->{conf}{'meta_ai.ENABLED'}=0;
ok(ask($bot,'Alicia','#test','/forget'),'participant can erase their history even after mode is disabled');
is(scalar(@{history($dir)}),1,'forget removes only the renamed participant’s exchanges');
is(history($dir)->[0]{prompt},'mon mot repère : Bob','other participant history is preserved');
is(scalar(@{$client->{calls}}),8,'forget makes no provider call');

($bot,$client,$runtime,$dir)=fixture();$lang='en';ask($bot,'Alice','#test','latest update?');drafts($client,0,1);final($client,3,'Verified current update.',[1]);
is(scalar(@sent),1,'web answer precedes its sources');
$timers[0][1]->();like($sent[1][1],qr/^Sources: \x0314example\.org\x0f \x0312\x1fhttps:\/\/www\.example\.org\/news\x0f\z/,'the direct verified URL is blue and underlined in the delivered source line');
ok(!grep($_->[1]=~/[\x00\r\n\x01]/,@sent),'answers contain no CTCP framing or embedded IRC line breaks');

($bot,$client,$runtime,$dir)=fixture();$bot->{conf}{'meta_ai.RATE_MAX'}=1;ask($bot,'Alice','#test','calcule 2+2');drafts($client,0,0);final($client,3,'Done');
ask($bot,'Bob','#test','second');like($notices[-1][1],qr/limite/,'channel rate budget applies across participants');
is(scalar(@{$client->{calls}}),4,'rate refusal does not call providers');
open my $source,'<','mediabot.pl' or die $!;local $/;my $main=<$source>;close $source;
like($main,qr/MetaRuntime::handle\(\$mediabot,\$message,\$who,\$where/,'actual addressed IRC route calls the collective runtime');
like($main,qr/MetaRuntime::note_rename/,'actual IRC nick event preserves observed identity changes');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','latest update?');drafts($client,0,1);
$client->{calls}[3]{done}->({ok=>0,error=>'http_error',status=>503});
like($bot->{logger}{lines}[-1],qr/^\[WARN\] META_AI failed code=web_synthesis_failed contributors=3 degraded=0 web_attempted=1 citation_repair=0$/,
    'failed research synthesis leaves a bounded diagnostic code');
like($notices[-1][1],qr/vérifier/,'research synthesis failure has a research-specific notice');
is(scalar(@{history($dir)}),0,'failed research is not saved to conversation history');
is(scalar(keys %{$runtime->{jobs}}),0,'failed research releases its channel job');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','latest update?');drafts($client,0,1);final($client,3,'Uncited draft',[]);
is(scalar(@sent),0,'uncited initial synthesis emits no IRC message');
final($client,4,'Corrected sourced answer',[1]);
$timers[0][1]->();
like($bot->{logger}{lines}[-1],qr/^META_AI completed contributors=3 web=1 degraded=0 citation_repair=1 anchors=1 shorturls=0$/,
    'successful correction exposes only bounded completion metadata');
is(scalar(@{history($dir)}),1,'only corrected delivered answer is committed to memory');
unlike(join(' ',@{$bot->{logger}{lines}}),qr/Alice|Corrected sourced answer|example\.org/,
    'diagnostic metadata excludes identity, answer and source URLs');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','latest update?');
$client->{calls}[0]{done}->({ok=>1,status=>200,answer=>encode_json({answer=>'Draft',needs_web=>1})});
$client->{calls}[1]{done}->({ok=>1,status=>200,answer=>encode_json({answer=>'Draft',needs_web=>1})});
$client->{calls}[2]{done}->({ok=>0,status=>503,error=>'http_error',failure_category=>'service_unavailable',transient_retries=>1});
like(join('\n',@{$bot->{logger}{lines}}),qr/META_AI provider=gemini outcome=api_failure status=503 error=http_error category=service_unavailable retries=1/,
    'actual runtime names the unavailable contributor with bounded API metadata');
my $bad=encode_json({answer=>'PRIVATE_UNGROUNDED_CLAIM',source_ids=>[1],basis=>'supported',
    support=>[{source_id=>1,quote=>'A completely invented source passage.'}]});
$client->{calls}[3]{done}->({ok=>1,provider=>'openai',answer=>$bad});
is(scalar(@sent),0,'initial mismatched evidence cannot reach IRC');
is(scalar(@{history($dir)}),0,'initial mismatched evidence cannot enter memory');
is(scalar(keys %{$runtime->{jobs}}),1,'one correction retains the existing channel job');
$client->{calls}[4]{done}->({ok=>1,provider=>'openai',answer=>$bad});
is(scalar(@sent),0,'repeated mismatched evidence cannot reach IRC');
is(scalar(@{history($dir)}),0,'repeated mismatched evidence cannot enter memory');
is(scalar(keys %{$runtime->{jobs}}),0,'final evidence rejection releases the channel job');
like($bot->{logger}{lines}[-1],qr/failed code=web_evidence_mismatch contributors=2 degraded=1 web_attempted=1 citation_repair=1$/,
    'failure metadata retains successful contributors, degradation, web attempt and correction');
like(join('\n',@{$bot->{logger}{lines}}),qr/META_AI evidence=invalid action=retry.*META_AI evidence=invalid action=rejected/s,
    'free-text quote instead of requested passage selection is rejected, even after one correction');
unlike(join(' ',@{$bot->{logger}{lines}},map {$_->[1]} @notices),qr/PRIVATE_UNGROUNDED_CLAIM|invented source passage|Alice|example\.org/,
    'provider and evidence logs/notices contain no rejected content or identities');

($bot,$client,$runtime,$dir)=fixture();ask($bot,'Alice','#test','latest update?');drafts($client,0,1);
$client->{calls}[3]{done}->({ok=>1,provider=>'anthropic',answer=>$bad});
final($client,4,'The corrected answer.',[1]);
is(scalar(@sent),1,'validated regenerated answer starts normal paced delivery');
$timers[0][1]->();
is(scalar(@{history($dir)}),1,'only fully delivered regenerated answer enters memory');
unlike(history($dir)->[0]{answer},qr/PRIVATE_UNGROUNDED_CLAIM/,'rejected first synthesis is not retained');
# MB1325: delivered social replies feed the same memory used by later turns.
($bot,$client,$runtime,$dir)=fixture();
for my $turn (["je prends mon café sans sucre",'Ton café a donc renoncé à toute douceur.'],
              ['tu te souviens de mon café ?','Sans sucre, comme ton réveil apparemment.']) {
    my $start=scalar @{$client->{calls}};
    ok(ask($bot,'Alice','#test',$turn->[0]),'addressed social turn enters MetaAI');
    if ($start) {
        my $messages=encode_json($client->{calls}[$start]{request}{messages});
        like($messages,qr/sans sucre/,'next social turn receives earlier user detail');
        like($messages,qr/Ton caf/, 'next social turn receives delivered assistant context');
    }
    for my $i ($start..$start+2) {
        $client->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'Un café héroïque.',
            task_type=>'conversation',needs_web=>JSON::PP::false,query=>''})});
    }
    like($client->{calls}[$start+3]{request}{system},qr/CHAT INTENT/,'runtime selects chat synthesis');
    final($client,$start+3,$turn->[1]);
    while (my $timer=shift @timers) {$timer->[1]->()}
}
is(scalar @{history($dir)},2,'both fully delivered social exchanges are retained');
like(join(' ',@{$bot->{logger}{lines}}),qr/META_AI intent=chat/,'route is logged without conversational content');
my $start=scalar @{$client->{calls}};
ok(ask($bot,'Alice','#test','quelle est la dernière version de Debian ?'),'factual follow-up after chat is admitted');
drafts($client,$start,1);
like($client->{calls}[$start+3]{request}{system},qr/UNTRUSTED SOURCES/,'factual turn returns to evidence synthesis');
unlike($client->{calls}[$start+3]{request}{system},qr/CHAT INTENT/,'chat style is not sticky across turns');
final($client,$start+3,'Une réponse vérifiée.',[1]);
while (my $timer=shift @timers) {$timer->[1]->()}
is(scalar @{history($dir)},3,'researched reply still commits through normal delivery');
like(join(' ',@{$bot->{logger}{lines}}),qr/META_AI intent=research/,'research route remains observable');

($bot,$client,$runtime,$dir)=fixture();
$bot->{nicks}={'#test'=>['Papillon','Te[u]K','Bystander'],'#other'=>['OtherNick']};
for my $case (
    ['Qui est papillon ?', 'Papillon'],
    ['Et lui ?', 'Papillon'],
    ['Te{u}K est là ?', 'Te[u]K'],
) {
    my ($prompt,$live_nick)=@$case;
    my $start=@{$client->{calls}};
    ok(ask($bot,'Alice','#test',$prompt),'addressed question about a channel member is admitted');
    my $draft=$client->{calls}[$start]{request}{system};
    like($draft,qr/^CURRENT IRC NICKNAMES: \["\Q$live_nick\E"\]/m,
        'contributors receive the matched live nick, including on a follow-up');
    unlike($draft,qr/Bystander|OtherNick|public\.example\.org/,
        'unmentioned nicks, other channels and hostnames stay out of the prompt');
    drafts($client,$start,1); # A model's mistaken interpretation must not launch a butterfly search.
    my $synthesis=$client->{calls}[$start+3]{request}{system};
    like($synthesis,qr/CHAT INTENT.*CURRENT IRC NICKNAMES: \["\Q$live_nick\E"\]/s,
        'room-bound misclassification selects the conversational synthesis with the live referent');
    final($client,$start+3,'Local chat reply.',$synthesis =~ /CHAT INTENT/ ? [] : [1]);
    while (my $timer=shift @timers) {$timer->[1]->()}
}
is_deeply(\@queries,[],'local nick questions never reach web search');
is_deeply([map {$_->[1]} @sent], [('Local chat reply.') x 3],
    'local nick questions have no emitted source line');
unlike(encode_json(history($dir)),qr/CURRENT IRC NICKNAMES|Bystander/,
    'per-request nick hints are not persisted in conversation memory');

for my $case (
    ['#test','Que mange un papillon ?',0],
    ['#other','Qui est Papillon ?',0],
    ['#test','Papillon, quelle est la météo ?',1],
    ['#test','Papillon, pourquoi le ciel est bleu ?',1],
    ['#test','Qui est Papillon ? Donne tes sources.',1],
) {
    my ($channel,$prompt,$known)=@$case;
    ($bot,$client,$runtime,$dir)=fixture();
    $bot->{nicks}={'#test'=>['Papillon']};
    ask($bot,'Alice',$channel,$prompt);
    my $system=$client->{calls}[0]{request}{system};
    is(($system =~ /^CURRENT IRC NICKNAMES: \["Papillon"\]/m ? 1:0),$known,
        'member detection distinguishes an ordinary noun or another channel');
    drafts($client,0,1);
    is(scalar(@queries),1,'factual or explicit verification request still enters research');
    final($client,3,'Réponse vérifiée.',[1]);
    while (my $timer=shift @timers) {$timer->[1]->()}
    like($sent[-1][1],qr/^Sources : /,'researched answers still have a source line');
}

sub complete_addressed_turn {
    my ($bot,$client,$prompt)=@_;
    my $start=@{$client->{calls}};
    ok(ask($bot,'Alice','#test',$prompt),'follow-up scenario enters MetaAI');
    my $system='';
    if (@{$client->{calls}}>$start) {
        $system=$client->{calls}[$start]{request}{system};
        drafts($client,$start,1);
        if (my $synthesis=$client->{calls}[$start+3]) {
            my $research=$synthesis->{request}{system} =~ /UNTRUSTED SOURCES/;
            final($client,$start+3,'Test answer.',$research ? [1] : []);
        }
    }
    while (my $timer=shift @timers) {$timer->[1]->()}
    return $system;
}

($bot,$client,$runtime,$dir)=fixture();
$bot->{nicks}={'#test'=>['Papillon','About']};
$bot->{conf}{'meta_ai.RATE_MAX'}=8;
complete_addressed_turn($bot,$client,'Qui est Papillon ?');
complete_addressed_turn($bot,$client,'Merci !');
for my $prompt ('Et lui ?', 'Et lui ?', 'What about him?') {
    like(complete_addressed_turn($bot,$client,$prompt),qr/^CURRENT IRC NICKNAMES: \["Papillon"\]/m,
        'a bare follow-up retains the live nick through brief intervening turns');
}
is_deeply(\@queries,[],'a chain of room follow-ups never launches research');
ok(!grep($_->[1] =~ /^Sources : /,@sent),'the room follow-ups publish no source lines');
is(scalar @{history($dir)},5,'all five delivered turns use the existing memory');
unlike(complete_addressed_turn($bot,$client,'Il pleut à Brest ?'),qr/^CURRENT IRC NICKNAMES:/m,
    'a new question starting with an impersonal pronoun does not skip back to the old nick');
like($sent[-1][1],qr/^Sources : /,'the independent weather question can still use sources');

($bot,$client,$runtime,$dir)=fixture();
$bot->{nicks}={'#test'=>['Papillon','Renard']};
complete_addressed_turn($bot,$client,'Qui est Papillon et Renard ?');
my $before_clarification=@{$client->{calls}};
complete_addressed_turn($bot,$client,'Et lui ?');
is(scalar @{$client->{calls}},$before_clarification,'ambiguous nick follow-up needs no provider');
is_deeply(\@queries,[],'ambiguous nick follow-up needs no web search');
is($sent[-1][1],'Tu parles de qui ?','ambiguous nick follow-up asks for clarification on IRC');
like(complete_addressed_turn($bot,$client,'Je parle de Papillon.'),qr/^CURRENT IRC NICKNAMES: \["Papillon"\]/m,
    'an explicit nick resumes the conversation after clarification');
is(scalar @{history($dir)},3,'the clarification uses normal delivery and releases the job');

($bot,$client,$runtime,$dir)=fixture();
$bot->{nicks}={'#test'=>['Papillon']};
complete_addressed_turn($bot,$client,'Qui est Papillon ?');
complete_addressed_turn($bot,$client,'Papillon, quelle est la météo à Brest ?');
unlike(complete_addressed_turn($bot,$client,'Et lui ?'),qr/^CURRENT IRC NICKNAMES:/m,
    'a factual topic change does not carry over an old IRC nick');
complete_addressed_turn($bot,$client,'Donne-moi des sources sur la météo à Brest.');
like($sent[-1][1],qr/^Sources : /,'an explicit source request still reaches the evidence route');

($bot,$client,$runtime,$dir)=fixture();
$lang='en';
$bot->{conf}{'meta_ai.WEB_MODE'}='off';
complete_addressed_turn($bot,$client,'What about her?');
is_deeply($client->{calls},[],'a bare pronoun without any previous subject needs no provider');
is_deeply([map {$_->[1]} @sent],['Who do you mean?'],'clarification follows the channel language');

($bot,$client,$runtime,$dir)=fixture();
$bot->{nicks}={'#test'=>['Papillon']};
complete_addressed_turn($bot,$client,'Qui est Papillon ?');
$bot->{nicks}{'#test'}=[];
unlike(complete_addressed_turn($bot,$client,'Et lui ?'),qr/^CURRENT IRC NICKNAMES:/m,
    'a departed nickname is no longer supplied as a live referent');

($bot,$client,$runtime,$dir)=fixture();
$bot->{conf}{'meta_ai.WEB_MODE'}='always';
complete_addressed_turn($bot,$client,'Et elle ?');
is(scalar @queries,1,'always mode retains forced research');

($bot,$client,$runtime,$dir)=fixture();
$bot->{conf}{'meta_ai.RATE_MAX'}=12;
complete_addressed_turn($bot,$client,'Quelle est la dernière version de Debian ?');
my $debian_sources=$sent[-1][1];
complete_addressed_turn($bot,$client,'Merci !');
my $calls_before_recall=@{$client->{calls}};
my $queries_before_recall=@queries;
my $sent_before_recall=@sent;
complete_addressed_turn($bot,$client,'Tes sources ?');
is_deeply([map {$_->[1]} @sent[$sent_before_recall..$#sent]],[$debian_sources],
    'a bare source request resends the verified styled IRC line on its own after a thank-you');
complete_addressed_turn($bot,$client,'Et tes sources ?');
is(scalar @{$client->{calls}},$calls_before_recall,'repeated source recall makes no model calls');
is(scalar @queries,$queries_before_recall,'repeated source recall starts no new search');
is(scalar @{history($dir)},2,'source recall leaves the substantive turn in conversation memory');

my $callback;
$runtime->{shorten_start}=sub {$callback=$_[1]};
ask($bot,'Bob','#test','Tes sources ?');
my $sent_before_forget=@sent;
ask($bot,'Alice','#test','/forget');
$callback->({}) if $callback;
is(scalar @sent,$sent_before_forget,'forget cancels pending source recall');
$runtime->{shorten_start}=undef;
complete_addressed_turn($bot,$client,'Sources ?');
like($sent[-1][1],qr/Quel point veux-tu que je vérifie/,'forgotten sources cannot be recalled');

($bot,$client,$runtime,$dir)=fixture();
complete_addressed_turn($bot,$client,'Quelle est la dernière version de Debian ?');
$lang='en';
my $sent_before_other=@sent;
ok(ask($bot,'Bob','#other','Your sources?'),'source recall is handled on another enabled channel');
is_deeply([map {$_->[1]} @sent[$sent_before_other..$#sent]],
    ['I have no verified sources for that reply. What would you like me to check?'],
    'the other channel receives a clarification in English, with no cross-channel citations');
is(scalar @{$client->{calls}},4,'the clarification does not call a contributor');

($bot,$client,$runtime,$dir)=fixture();
complete_addressed_turn($bot,$client,'Quelle est la dernière version de Debian ?');
ask($bot,'Alice','#test','mon mot repère : hibou');
drafts($client,4,0);
final($client,7,'Chat reply with https://example.org/unverified');
complete_addressed_turn($bot,$client,'Sources ?');
like($sent[-1][1],qr/Quel point veux-tu que je vérifie/,
    'an intervening chat turn blocks recall of older sources and unverified links');
is(scalar @queries,1,'the latest unsourced reply does not trigger a search without a topic');

for my $prompt (
    'en faite tes chelou toi',
    'sa tombe bien mediabot, quand tu a rien a repondre, tu pourrais fermer ta gueule ?',
    'tu sais qui ta ramené a ce diner mediabot ? et ce que ca veux dire ?',
    "tu me dis que tu es la pour m'aidé a ce moqué des autres ?",
    'aide moi et fournis des informations utiles stp',
    "n'empêche que Villeret est excellent",
    'tu pense que ton proprietaire est lunaire ?',
    'tes sources sont merdiques',
    'imagine que Papillon et Renard jouent aux cartes, qui mène actuellement ?',
) {
    ($bot,$client,$runtime,$dir)=fixture();
    $bot->{nicks}={'#test'=>['Papillon','Renard']};
    complete_addressed_turn($bot,$client,'tu connais le principe du diner de cons ?');
    my $calls=@{$client->{calls}};
    my $lines=@sent;
    complete_addressed_turn($bot,$client,$prompt);
    like($client->{calls}[$calls+3]{request}{system},qr/CHAT INTENT:.*sarcasm/,
        'the latest social turn selects the conversational voice after factual context');
    is(scalar @queries,1,'over-eager research votes do not browse for an in-room line');
    is_deeply([map {$_->[1]} @sent[$lines..$#sent]],['Test answer.'],
        'social turn emits only its conversational response');
}

for my $prompt (
    'tes sources sont merdiques, cite les sources officielles sur la réforme',
    'qui a chanté « Ah si tu pouvais fermer ta gueule » ?',
    'n’empêche que Villeret est excellent, qui a réalisé Le Dîner de cons ?',
) {
    ($bot,$client,$runtime,$dir)=fixture();
    complete_addressed_turn($bot,$client,$prompt);
    is(scalar @queries,1,'a real verification question still enters research');
    like($sent[-1][1],qr/^Sources : /,'supported research still delivers styled references');
}

($bot,$client,$runtime,$dir)=fixture();
ask($bot,'Alice','#test','Qui a réalisé Le Dîner de cons ?');
drafts($client,0,1);
my ($catalogue)=$client->{calls}[3]{request}{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
my $passage=decode_json($catalogue)->[0]{passages}[0]{passage_id};
$client->{calls}[3]{done}->({ok=>1,answer=>encode_json({answer=>'A fact that the page did not establish.',
    basis=>'insufficient',source_ids=>[1],support=>[{source_id=>1,passage_id=>$passage}]})});
while (my $timer=shift @timers) {$timer->[1]->()}
is_deeply([map {$_->[1]} @sent],[q{Je n’ai rien trouvé de fiable sur ce point.}],
    'a verified evidence limit is brief and emits no unrelated citation');
ok(!exists(history($dir)->[0]{source_urls}),'insufficient findings cannot be recalled as delivered references');

{
    ($bot,$client,$runtime,$dir)=fixture();
    $bot->{loop}=IO::Async::Loop->new;
    my $video='https://www.youtube.com/watch?v=AbCdEfGh123&feature='.('x'x120);
    my $duplicate='https://youtu.be/AbCdEfGh123';
    my $alias='https://go.example.org/shorturl/ABCD2345';
    $bot->{conf}{'shorturl.PUBLIC_BASE_URL'}='https://go.example.org/shorturl/';
    $bot->{conf}{'meta_ai.MAX_JOBS'}=1;
    $bot->{conf}{'meta_ai.RATE_MAX'}=8;
    $bot->{conf}{'meta_ai.GLOBAL_RATE_MAX'}=12;
    $runtime->{shorten_start}=sub {$_[1]->({mappings=>[{url=>$video,display_url=>$alias}]})};
    $runtime->{web_start}=sub {$_[1]->({ok=>1,sources=>[
        {id=>1,url=>$video,text=>'The official recording documents the question and its supporting facts.'},
        {id=>2,url=>$duplicate,text=>'Another permissible link to the same recording of the event.'},
        {id=>3,url=>'https://www.youtube.com/shorts/ZyXwVuTs987',text=>'A third recording that will not be cited.'},
    ]});1};
    my (@workers,@http);
    local *Mediabot::AsyncWorker::start=sub {my (undef,%args)=@_;my $job=bless \%args,'MB818RuntimePreviewWorker';push @workers,$job;return $job};
    local *Mediabot::External::_make_http=sub {bless {calls=>\@http,response=>{success=>1,
        content=>encode_json({title=>'Émission '.('🎬'x145)."\x01ACTION",author_name=>'Studio '.('é'x90)})}},'MB818RuntimeYouTube'};
    ask($bot,'Alice','#test','Trouve la vidéo officielle de l’événement.');
    drafts($client,0,1);
    final($client,3,'Une explication longue. 'x50,[1,2]);
    is(scalar @workers,0,'the optional lookup does not delay the answer');
    while (my $timer=shift @timers) {$timer->[1]->()}
    is(scalar @sent,3,'a two-line answer and its source line are sent first');
    like($sent[2][1],qr/\Q$alias\E/,'citation visibly uses the verified short URL');
    is(scalar @workers,1,'one worker prepares previews for displayed sources');
    ok(!keys %{$runtime->{jobs}},'delivered sources immediately free the answer slot');
    SKIP: {
        skip 'source preview worker did not start', 25 unless @workers;
        my $work=shift @workers;
        my $other_start=@{$client->{calls}};
        ask($bot,'Bob','#other','Traduis ce passage en anglais.');
        my $other_started=@{$client->{calls}}==$other_start+3;
        ok($other_started,'a pending preview does not consume the global answer slot');
        ok(!$work->{cancelled},'a question in another channel leaves the preview current');
        my $preview=$work->{child}->();
        $work->{on_done}->({ok=>1,value=>$preview});
        $work->{on_done}->({ok=>1,value=>$preview});
        is(scalar @http,1,'duplicate variants and uncited videos do not cause more lookups');
        like($http[0],qr{\Ahttps://www\.youtube\.com/oembed\?.*AbCdEfGh123},
            'oEmbed uses the original YouTube identity without an API key');
        is(scalar @sent,4,'one separate preview line follows the existing lines');
        my $preview_line=$sent[3] ? $sent[3][1] : '';
        like($preview_line,qr/Émission.*by Studio/s,'preview uses YouTube title and channel metadata');
        unlike($preview_line,qr/[\x00\x01\r\n]/,'remote fields cannot inject IRC commands or lines');
        cmp_ok(length(encode('UTF-8',$preview_line)),'<=',400,'long Unicode metadata fits a single IRC message');
        unlike(history($dir)->[0]{answer},qr/Émission/,'preview is not stored as conversation or evidence');
        is_deeply(history($dir)->[0]{source_urls},[$video,$duplicate],'memory keeps the displayed original destinations');
        is(scalar keys %{$runtime->{jobs}},$other_started?1:0,'completing a preview leaves other channel jobs alone');
        if ($other_started) {
            drafts($client,$other_start,0);
            final($client,$other_start+3,'A translated line.');
            @sent=grep {$_->[0] ne '#other'} @sent;
        }
        my $turns=scalar @{history($dir)};

        ask($bot,'Alice','#test','Tes sources ?');
        is(scalar @workers,1,'source recall also adds a preview for the displayed video');
        my $before=@sent;
        $bot->{wit_runtime_state}{generation}++;
        (shift @workers)->{on_done}->({ok=>1,value=>$preview});
        is(scalar @sent,$before,'a stale connection cannot publish the late preview');
        is_deeply($runtime->{previews},{},'a stale preview releases its presentation slot');
        is(scalar @{history($dir)},$turns,'source recall leaves the original answer in memory');

        ask($bot,'Alice','#test','Tes sources ?');
        my $old=shift @workers;
        my $next_start=@{$client->{calls}};
        ask($bot,'Alice','#test','Trouve la vidéo complète.');
        my $next_started=@{$client->{calls}}==$next_start+3;
        ok($next_started,'a new question is admitted during metadata lookup in the same channel');
        is($old->{cancelled}//0,1,'new question cancels the superseded preview worker');
        $before=@sent;
        $old->{on_done}->({ok=>1,value=>$preview});
        is(scalar @sent,$before,'obsolete callback cannot publish the previous preview');
        is(scalar keys %{$runtime->{jobs}},1,'obsolete callback cannot release the new answer slot');
        SKIP: {
            skip 'follow-up was not admitted', 6 unless $next_started;
            drafts($client,$next_start,1);
            final($client,$next_start+3,'La vidéo complète est ici.',[1]);
            while (my $timer=shift @timers) {$timer->[1]->()}
            my $pending=shift @workers;
            ok($pending,'the new reply starts its own preview');
            ask($bot,'Alice','#test','/forget');
            is($pending->{cancelled}//0,1,'forget cancels an outstanding preview');
            $before=@sent;
            $pending->{on_done}->({ok=>1,value=>$preview});
            is(scalar @sent,$before,'late preview does not escape forget');
            is_deeply($runtime->{previews},{},'forget clears the preview slot');
            ok(!keys %{$runtime->{jobs}},'forget leaves no answer job behind');
            ok(!grep($_->{name} eq 'Alice',@{history($dir)}),'forgotten turns remain erased');
        }
    }
}
done_testing;
