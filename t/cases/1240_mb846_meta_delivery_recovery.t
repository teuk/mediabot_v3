use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use Mediabot::AI::MetaRuntime;
use Mediabot::AI::MetaActivation qw(note_policy_change);

{
    package MB846Conf;sub get {$_[0]{$_[1]}}
    package MB846Generation;sub capture_generation {$_[0]{generation}}
    package MB846Logger;sub log {push @{$_[0]{lines}},$_[2];1}
    package MB846Bot;sub getMessageNickIdentHost {('Alice','ident','example.org')}
    package MB846Client;
    sub submit {my ($s,$request,%args)=@_;push @{$s->{calls}},{request=>$request,done=>$args{on_done}};1}
}
my (@sent,@notices,@timers,@opts);my $mode='defer';
no warnings 'redefine';
local *Mediabot::Helpers::channel_lang=sub {'en'};
local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[$_[1],$_[2]];push @opts,$_[3];1};
local *Mediabot::Helpers::botNotice=sub {push @notices,[$_[1],$_[2]];1};
sub fixture846 {
    @sent=();@notices=();@timers=();@opts=();$mode='defer';
    my $dir=tempdir(CLEANUP=>1);
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $dbh->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $dbh->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $dbh->do("INSERT INTO CHANSET_LIST VALUES(1,'MetaAI')");
    $dbh->do("INSERT INTO CHANNEL VALUES(1,'#test')");
    $dbh->do('INSERT INTO CHANNEL_SET VALUES(1,1,1)');
    my $conf=bless {'meta_ai.ENABLED'=>1,'meta_ai.PROVIDERS'=>'openai anthropic',
        'meta_ai.STATE_FILE'=>"$dir/memory.json",'openai.API_KEY'=>'fake-openai',
        'anthropic.API_KEY'=>'fake-anthropic','shorturl.PUBLIC_BASE_URL'=>'https://teuk.org/shorturl/'},'MB846Conf';
    my $bot=bless {dbh=>$dbh,conf=>$conf,config_file=>"$dir/mediabot.conf",
        wit_runtime_state=>bless({generation=>1},'MB846Generation'),
        logger=>bless({lines=>[]},'MB846Logger')},'MB846Bot';
    my $client=bless {calls=>[]},'MB846Client';
    my $r=Mediabot::AI::MetaRuntime->new(bot=>$bot,clock=>sub {1792400000},client_factory=>sub {$client},
        schedule_cb=>sub {push @timers,$_[1];die "private scheduler failure\n" if $mode eq 'throw';$mode ne 'refuse'},
        web_start=>sub {$_[1]->({ok=>1,sources=>[{id=>1,url=>'https://www.franceinfo.fr/reference',
            text=>'An official reference describes the current state and its documented observations.',kind=>'page_excerpt'}]});1},
        shorten_start=>sub {$_[1]->({mappings=>[{url=>'https://www.franceinfo.fr/reference',
            display_url=>'https://teuk.org/shorturl/Abcdef23'}]});1});
    $bot->{_meta_ai_runtime}=$r;return ($bot,$client,$r,$dir);
}
sub ask846 {Mediabot::AI::MetaRuntime::handle($_[0],undef,'Alice','#test','what are the latest official observations?')}
sub finish846 {
    my ($client,$start)=@_;
    return 0 unless $client->{calls}[$start+1] && ref($client->{calls}[$start+1]{done}) eq 'CODE';
    for my $i ($start,$start+1) {$client->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'A researched draft.',needs_web=>1})})}
    my $synthesis=$client->{calls}[$start+2];
    my ($raw)=$synthesis->{request}{system}=~/^UNTRUSTED SOURCES: ([^\n]+)/m;
    my $catalogue=decode_json($raw);my $source=$catalogue->[0];
    $synthesis->{done}->({ok=>1,answer=>encode_json({answer=>'A documented observation. 'x24,
        source_ids=>[1],basis=>'supported',support=>[{source_id=>1,passage_id=>$source->{passages}[0]{passage_id}}]})});
}
sub fire846 {my ($cb)=@_;$cb->() if ref($cb) eq 'CODE'}
sub history846 {
    my ($dir)=@_;return [] unless -e "$dir/memory.json";
    open my $fh,'<:raw',"$dir/memory.json" or die $!;local $/;my $s=decode_json(<$fh>);close $fh;
    return [map {@{$_->{turns}}} values %{$s->{rooms}}];
}
{
    my ($bot,$client,$r,$dir)=fixture846();
    ok(ask846($bot),'native +MetaAI admits the researched request');
    is(scalar @{$client->{calls}},2,'normal contributors start without extra provider calls');
    finish846($client,0);
    is(scalar @sent,1,'first answer chunk is immediate');
    is(scalar @{history846($dir)},0,'partial researched reply is absent from memory');
    my $first=$timers[0];$first->();$first->();
    is(scalar @sent,2,'replayed first arm cannot burst the labelled source line');
    is(scalar keys %{$r->{jobs}},1,'pending source line still owns the channel reservation');
    my $source_arm=$timers[1];$source_arm->();
    is(scalar @sent,3,'source follows both answer lines');
    like($sent[-1][1],qr/\ASources: \x0314FranceInfo\x0f \x0312\x1fhttps:\/\/teuk[.]org\/shorturl\/Abcdef23\x0f\z/,
        'validated shorturl and grey original-site label are preserved');
    ok(!(grep {!$_->{no_defer}} @opts),'all public lines retain the immediate-or-refused IRC policy');
    ok(!(grep {length(encode('UTF-8',$_->[1]))>400} @sent),'answer and labelled source line remain inside the IRC byte envelope');
    is(scalar @{history846($dir)},1,'only complete actual output enters shared memory');
    my $plain=join(' ',map {$_->[1]} @sent);$plain=~s/\x03\d{2}|[\x0f\x1f]//g;
    is(history846($dir)->[0]{answer},$plain,'memory retains actual delivered words and URLs without IRC styling');
    ok(ask846($bot),'following question starts normally');
    is(scalar @{$client->{calls}},5,'following request starts its own contributors');
    $source_arm->();$first->();
    is(scalar keys %{$r->{jobs}},1,'old terminal callbacks cannot release the following question');
    is(scalar @{history846($dir)},1,'old callbacks cannot commit another turn');
    is(scalar @sent,3,'old callbacks send no undefined or duplicate line');
    is(scalar(grep {/META_AI completed/} @{$bot->{logger}{lines}}),1,'old completion is not logged twice');
    finish846($client,3);fire846($timers[2]);fire846($timers[3]);
    is(scalar @{history846($dir)},2,'following question completes and records its own turn');
    is(scalar keys %{$r->{jobs}},0,'following question releases its own reservation');
}
for my $failure (qw(refuse throw)) {
    my ($bot,$client,$r,$dir)=fixture846();$mode=$failure;
    ask846($bot);ok(eval {finish846($client,0);1},"$failure: delivery setup failure stays within runtime");
    is(scalar @sent,1,"$failure: remaining text and sources are not burst or fabricated");
    is(scalar @{history846($dir)},0,"$failure: incomplete answer cannot enter history");
    is(scalar keys %{$r->{jobs}},0,"$failure: channel capacity is released");
    is(scalar(grep {/delivery_aborted/} @{$bot->{logger}{lines}}),1,"$failure: bounded aborted delivery is logged once");
    unlike(join(' ',@{$bot->{logger}{lines}},map {$_->[1]} @notices),qr/private scheduler failure/,
        "$failure: raw scheduling detail does not escape");
    my $stale=$timers[0];$mode='defer';ask846($bot);$stale->();
    is(scalar keys %{$r->{jobs}},1,"$failure: stale failed arm cannot clear replacement question");
    is(scalar @sent,1,"$failure: stale failed arm cannot send old output");
    finish846($client,3);fire846($timers[1]);fire846($timers[2]);
    is(scalar @{history846($dir)},1,"$failure: next question recovers without restart");
    is(scalar keys %{$r->{jobs}},0,"$failure: recovered reply releases capacity");
}
{
    my ($bot,$client,$r,$dir)=fixture846();ask846($bot);finish846($client,0);
    $bot->{dbh}->do('DELETE FROM CHANNEL_SET');note_policy_change($bot,'#test');
    my $stale=$timers[0];$stale->();
    is(scalar @sent,1,'revocation still stops a paced answer before sources');
    is(scalar @{history846($dir)},0,'revocation does not record a partial answer');
    is(scalar keys %{$r->{jobs}},0,'revoked delivery releases its channel');
    $bot->{dbh}->do('INSERT INTO CHANNEL_SET VALUES(1,1,1)');note_policy_change($bot,'#test');
    $stale->();is(scalar @sent,1,'re-enabling channel cannot revive revoked arm');
}
{
    my ($bot,$client,$r,$dir)=fixture846();
    local *Mediabot::AI::MetaKnowledge::answer=sub {{text=>'Private local response. 'x35,private=>1}};
    $mode='refuse';
    ok(Mediabot::AI::MetaRuntime::handle($bot,undef,'Alice','#test','what model do you use?'),
        'local private route uses the same delivery lifecycle');
    is(scalar @{$client->{calls}},0,'local response still makes no provider calls');
    is(scalar @notices,1,'first private line goes only to the requester');
    is(scalar @sent,0,'private output never falls back to channel transport');
    is(scalar keys %{$r->{jobs}},0,'private scheduling refusal also releases capacity');
    $timers[0]->();is(scalar @notices,1,'old failed private arm cannot send later notices');
    is(scalar @{history846($dir)},0,'private output never enters shared memory');
}
done_testing;
