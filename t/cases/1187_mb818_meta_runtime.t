use strict;
use DBI;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use Mediabot::AI::MetaRuntime;
{
    package MB818RuntimeConf;
    sub get {$_[0]{$_[1]}}
    package MB818RuntimeGeneration;
    sub capture_generation {$_[0]{generation}}
    package MB818RuntimeLogger;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB818RuntimeBot;
    sub getMessageNickIdentHost {my ($s,$message)=@_;return @$message}
    package MB818RuntimeClient;
    sub submit {my ($s,$request,%args)=@_;push @{$s->{calls}},{request=>$request,done=>$args{on_done}};1}
}
my (@sent,@notices,@timers,@opts);my $accepted=1;my $chanset=1;my $lang='fr';my $now=1791892800;
no warnings 'redefine';
local *Mediabot::Helpers::channel_lang=sub {$lang};
local *Mediabot::Helpers::chanset_enabled=sub {$chanset};
local *Mediabot::Helpers::botPrivmsg=sub {push @opts,$_[3];return 0 unless $accepted;push @sent,[$_[1],$_[2]];1};
local *Mediabot::Helpers::botNotice=sub {push @notices,[$_[1],$_[2]];1};
sub fixture {
    @sent=();@notices=();@timers=();@opts=();$accepted=1;$chanset=1;$lang='fr';
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
        web_start=>sub {$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://www.example.org/news',text=>'A verified page excerpt.',kind=>'page_excerpt'}]});1});
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
$bot->{wit_runtime_state}{generation}=2;drafts($client,4,0);final($client,7,'Late answer',[1]);
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
$timers[0][1]->();like($sent[1][1],qr/^Sources: \x0314example\.org\x0f https:\/\/www\.example\.org\/news\z/,'label and exact verified supplied URL appear in source line');
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
done_testing;
