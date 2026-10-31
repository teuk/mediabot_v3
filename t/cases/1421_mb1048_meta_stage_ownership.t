use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaRuntime;
use Mediabot::AI::MetaActivation qw(note_policy_change);
{
    package MB1048::Conf;
    sub get {$_[0]{$_[1]}}
    package MB1048::Generation;
    sub capture_generation {$_[0]{value}}
    package MB1048::Logger;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB1048::Bot;
    sub getMessageNickIdentHost {my ($self,$message)=@_;return @$message}
    package MB1048::Client;
    sub submit {
        my ($self,$request,%opts)=@_;
        push @{$self->{calls}},{request=>$request,done=>$opts{on_done}};
        return 1;
    }
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::Helpers::channel_lang=sub {'fr'};
local *Mediabot::Helpers::chanset_enabled=sub {$_[0]{enabled}};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{sent}},[$_[1],$_[2]];1};
local *Mediabot::Helpers::botNotice=sub {push @{$_[0]{notices}},[$_[1],$_[2]];1};
sub fixture_1421 {
    my $dir=tempdir(CLEANUP=>1);
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    my $conf=bless {'meta_ai.ENABLED'=>1,'meta_ai.CHANNELS'=>'#test #other',
        'meta_ai.STATE_FILE'=>"$dir/state.json",'connection.CONN_SERVER_NETWORK'=>'test-network',
        map {($_.'.API_KEY'=>'test-placeholder')} qw(openai anthropic gemini)},'MB1048::Conf';
    my $bot=bless {dbh=>$db,conf=>$conf,config_file=>"$dir/mediabot.conf",enabled=>1,
        wit_runtime_state=>bless({value=>1},'MB1048::Generation'),
        logger=>bless({lines=>[]},'MB1048::Logger'),sent=>[],notices=>[]},'MB1048::Bot';
    my $f={bot=>$bot,client=>bless({calls=>[]},'MB1048::Client'),dir=>$dir,
        searches=>[],web=>[],timers=>[],presentation=>[]};
    my $runtime=Mediabot::AI::MetaRuntime->new(bot=>$bot,clock=>sub {1791892800},
        client_factory=>sub {$f->{client}},
        web_start=>sub {push @{$f->{searches}},$_[0];push @{$f->{web}},$_[1];1},
        schedule_cb=>sub {push @{$f->{timers}},$_[1];1},
        shorten_start=>sub {push @{$f->{presentation}},$_[1];1});
    $f->{runtime}=$runtime;$bot->{_meta_ai_runtime}=$runtime;
    return $f;
}
sub ask_1421 {
    my ($f,$prompt,$channel,$nick)=@_;$channel//='#test';$nick//='Alice';
    Mediabot::AI::MetaRuntime::handle($f->{bot},[$nick,'ident','public.example.org'],$nick,$channel,$prompt);
}
sub respond_1421 {
    my ($f,$index,$result)=@_;my $call=$f->{client}{calls}[$index];
    $call->{done}->($result) if $call && ref($call->{done}) eq 'CODE';
}
sub drafts_1421 {
    my ($f,$start,$research)=@_;
    for my $i ($start..$start+2) {respond_1421($f,$i,{ok=>1,answer=>encode_json({
        answer=>'Draft',task_type=>$research?'factual':'calculation',needs_web=>$research?1:0,
        query=>'official requested information'})})}
}
sub web_1421 {
    my ($f,$ok)=@_;my $callback=$f->{web}[0];return unless ref($callback) eq 'CODE';
    $callback->($ok?{ok=>1,sources=>[{id=>1,url=>'https://www.example.org/info',
        text=>'A documented detail from the official source.',kind=>'page_excerpt'}]}:{ok=>0});
}
sub final_1421 {
    my ($f,$index,$answer,$sourced)=@_;my @support;
    my $call=$f->{client}{calls}[$index];return unless $call;
    if ($sourced) {
        my ($json)=$call->{request}{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
        my $rows=defined($json)?decode_json($json):[];
        push @support,{source_id=>1,passage_id=>$rows->[0]{passages}[0]{passage_id}} if @$rows;
    }
    respond_1421($f,$index,{ok=>1,answer=>encode_json({answer=>$answer,
        source_ids=>$sourced?[1]:[],basis=>'supported',support=>\@support})});
}
sub turns_1421 {
    my ($f)=@_;return [] unless -f "$f->{dir}/state.json";
    open my $fh,'<:raw',"$f->{dir}/state.json" or die $!;local $/;
    my $state=decode_json(<$fh>);close $fh;
    return [map {@{$_->{turns}}} values %{$state->{rooms}}];
}
{
    my $f=fixture_1421();ask_1421($f,'calcule 2+2');ask_1421($f,'/forget');
    ok(!exists($f->{runtime}{jobs}{'#test'}),'forget releases its obsolete shared-conversation job immediately');
    ask_1421($f,'calcule 3+3');
    is(scalar(@{$f->{client}{calls}}),6,'a fresh collective request starts without waiting for the old contributors');
    my $owner=$f->{runtime}{jobs}{'#test'};drafts_1421($f,0,1);
    is_deeply([scalar(@{$f->{searches}}),scalar(@{$f->{client}{calls}})],[0,6],
        'obsolete contributors launch neither research nor synthesis');
    ok(exists($f->{runtime}{jobs}{'#test'}) && $f->{runtime}{jobs}{'#test'} eq $owner,
        'obsolete completion cannot release the replacement job');
    drafts_1421($f,3,0);final_1421($f,6,'Le résultat est 6.');
    like(join(' ',map {$_->[1]} @{$f->{bot}{sent}}),qr/est 6/,
        'replacement synthesis is delivered normally');
    my $turns=turns_1421($f);
    is_deeply([scalar(@$turns),$turns->[0]{prompt},scalar(keys %{$f->{runtime}{jobs}})],
        [1,'calcule 3+3',0],'only the current delivered turn is committed and its own job is released');
}
for my $change (
    ['channel permission',sub {$_[0]{bot}{enabled}=0}],
    ['configuration signature',sub {$_[0]{bot}{conf}{'meta_ai.MAX_TOKENS'}=4096}],
    ['runtime generation',sub {$_[0]{bot}{wit_runtime_state}{value}++}],
    ['MetaAI policy epoch',sub {note_policy_change($_[0]{bot},'#test')}],
) {
    my ($label,$revoke)=@$change;my $f=fixture_1421();ask_1421($f,'latest update?');$revoke->($f);
    drafts_1421($f,0,1);
    is_deeply([scalar(@{$f->{client}{calls}}),scalar(@{$f->{searches}}),
        scalar(keys %{$f->{runtime}{jobs}}),$f->{bot}{sent},$f->{bot}{notices}],
        [3,0,0,[],[]],"a revoked $label stops the chain quietly at contributor completion");
}
for my $success (0,1) {
    my $f=fixture_1421();ask_1421($f,'latest update?');drafts_1421($f,0,1);
    is(scalar(@{$f->{searches}}),1,'an active factual request still starts one shared search');
    ask_1421($f,'/forget');web_1421($f,$success);
    is_deeply([scalar(@{$f->{client}{calls}}),$f->{bot}{sent},turns_1421($f)],
        [3,[],[]],$success?'a stale search success cannot start synthesis':'a stale search failure cannot start native web fallback');
}
{
    my $f=fixture_1421();ask_1421($f,'latest update?');drafts_1421($f,0,1);web_1421($f,1);
    is($f->{client}{calls}[3]{request}{purpose},'meta_synthesis_passages','active research retains passage-based evidence synthesis');
    note_policy_change($f->{bot},'#test');final_1421($f,3,'An unsupported answer.');
    is_deeply([scalar(@{$f->{client}{calls}}),$f->{bot}{sent},turns_1421($f),scalar(keys %{$f->{runtime}{jobs}})],
        [4,[],[],0],'a stale synthesis cannot launch citation repair, publish or retain evidence');
}
{
    my $f=fixture_1421();ask_1421($f,'latest update?');drafts_1421($f,0,1);web_1421($f,0);
    is($f->{client}{calls}[3]{request}{purpose},'meta_web','an active failed search retains its native web fallback');
    $f->{bot}{wit_runtime_state}{value}++;
    respond_1421($f,3,{ok=>1,answer=>'An obsolete researched answer.',
        sources=>[{url=>'https://www.example.org/info',text=>'A documented detail.'}]});
    is_deeply([$f->{bot}{sent},turns_1421($f),scalar(keys %{$f->{runtime}{jobs}})],
        [[],[],0],'obsolete native web results are also retired before publication');
}
{
    my $f=fixture_1421();ask_1421($f,'calcule 2+2');drafts_1421($f,0,0);
    final_1421($f,3,'Une réponse assez longue. 'x70);
    is_deeply([scalar(@{$f->{bot}{sent}}),scalar(@{$f->{timers}})],[1,1],
        'a current multi-line answer retains paced delivery');
    ask_1421($f,'/forget');ask_1421($f,'calcule 3+3');my $owner=$f->{runtime}{jobs}{'#test'};
    $f->{timers}[0]->() if ref($f->{timers}[0]) eq 'CODE';
    ok(scalar(@{$f->{bot}{sent}})==1 && exists($f->{runtime}{jobs}{'#test'})
        && $f->{runtime}{jobs}{'#test'} eq $owner,
        'a retired delivery arm sends no further line and cannot unlock a replacement');
    drafts_1421($f,4,0);final_1421($f,7,'Le résultat est 6.');
    is(scalar(@{turns_1421($f)}),1,'an interrupted partial answer never enters shared memory');
}
{
    my $f=fixture_1421();ask_1421($f,'latest update?');drafts_1421($f,0,1);web_1421($f,1);
    final_1421($f,3,'A supported detail.',1);
    is(scalar(@{$f->{presentation}}),1,'accepted researched output still enters source presentation');
    ask_1421($f,'/forget');ask_1421($f,'calcule 3+3');my $owner=$f->{runtime}{jobs}{'#test'};
    $f->{presentation}[0]->({}) if ref($f->{presentation}[0]) eq 'CODE';
    ok(!@{$f->{bot}{sent}} && exists($f->{runtime}{jobs}{'#test'})
        && $f->{runtime}{jobs}{'#test'} eq $owner,
        'stale source presentation cannot publish or release the fresh job');
}
{
    my $f=fixture_1421();ask_1421($f,'calcule 2+2');ask_1421($f,'calcule 3+3','#other','Bob');
    ask_1421($f,'/forget');my $owner=$f->{runtime}{jobs}{'#other'};drafts_1421($f,0,0);
    ok(exists($f->{runtime}{jobs}{'#other'}) && $f->{runtime}{jobs}{'#other'} eq $owner,
        'forget and obsolete completion preserve another channel job');
    drafts_1421($f,3,0);final_1421($f,6,'Le résultat est 6.');
    is_deeply([map {$_->[0]} @{$f->{bot}{sent}}],['#other'],'the other channel still completes normally');
}
for my $guard (sub {0},sub {die 'private guard failure'}) {
    my $f=fixture_1421();my @results;
    my $engine=Mediabot::AI::MetaChat->new(client=>$f->{client},conf=>$f->{bot}{conf},
        settings=>Mediabot::AI::MetaPolicy::settings($f->{bot}{conf}));
    $engine->submit(prompt=>'calcule 2+2',messages=>[{role=>'user',content=>'calcule 2+2'}],
        is_current=>$guard,on_done=>sub {push @results,$_[0]});
    is_deeply([scalar(@{$f->{client}{calls}}),scalar(@results),$results[0]{error}],
        [0,1,'cancelled'],'a false or failed caller predicate completes once without launching paid stages');
}
is_deeply(\@warnings,[],'stage guards, ownership and retained callbacks remain warning-free');
done_testing;
