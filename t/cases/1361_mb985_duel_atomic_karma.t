use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Storable qw(dclone);
our @DICE;
BEGIN {
    *CORE::GLOBAL::time=sub {1_900_000_000};
    *CORE::GLOBAL::rand=sub {
        return shift @DICE if defined($_[0]) && $_[0]==20 && @DICE;
        return CORE::rand($_[0] // 1);
    };
}
use Mediabot::Mediabot;
use Mediabot::Context;

# Only the SQL dialect is bridged. SQLite executes the complete statement and
# its real constraint failure; an independent connection observes committed data.
{
    package MB985::DBI; our @ISA=('DBI');
    package MB985::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;my $state=$db->{private_mb985};
        my $write=$sql =~ /INSERT INTO KARMA\b/;
        my $read=$sql =~ /SELECT score FROM KARMA\b/;
        my $kind=$write?'write':$read?'read':'other';
        if ($state) {
            $state->{prepare}{$kind}++;
            if ($state->{fault} eq $kind.'_prepare') {
                $db->set_err(2006,'DO_NOT_DISCLOSE_MB985');return;
            }
        }
        $sql =~ s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql =~ s/VALUES\(score\)/excluded.score/g;
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_mb985}={state=>$state,kind=>$kind} if $sth && $state;
        return $sth;
    }
    package MB985::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;my $data=$sth->{private_mb985};
        return $sth->SUPER::execute(@bind) unless $data;
        my ($state,$kind)=@$data{qw(state kind)};my $fault=$state->{fault};
        $state->{execute}{$kind}++;
        if ($fault eq $kind.'_execute') {$sth->set_err(2013,'DO_NOT_DISCLOSE_MB985');return}
        if ($kind eq 'write' && $fault =~ /^count_(0|1|5|negative)$/) {
            return $1 eq 'negative'?-1:$1==0?'0E0':$1;
        }
        my $rv=$sth->SUPER::execute(@bind);
        if ($fault eq $kind.'_status' && $rv) {$sth->set_err(2013,'DO_NOT_DISCLOSE_MB985');return $rv}
        if ($fault eq 'lost_ack' && $kind eq 'write' && $rv) {die "DO_NOT_DISCLOSE_MB985\n"}
        return $1 if $kind eq 'write' && $fault =~ /^count_([34])$/ && $rv;
        return $rv;
    }
    sub fetchrow_hashref {
        my ($sth,@args)=@_;my $data=$sth->{private_mb985};
        if ($data && $data->{kind} eq 'read' && $data->{state}{fault} eq 'read_fetch') {
            $sth->set_err(2013,'DO_NOT_DISCLOSE_MB985');return;
        }
        my $row=$sth->SUPER::fetchrow_hashref(@args);
        if ($data && $data->{kind} eq 'read' && $data->{state}{fault} eq 'read_fetch_status') {
            $sth->set_err(2013,'DO_NOT_DISCLOSE_MB985');
        }
        return $row;
    }
    sub finish {
        my ($sth)=@_;my $data=$sth->{private_mb985};
        return $sth->SUPER::finish unless $data;
        my ($state,$kind)=@$data{qw(state kind)};$state->{finish}{$kind}++;
        my $rv=$sth->SUPER::finish;
        $sth->set_err(undef,undef); # Cleanup must not erase an already captured failure.
        die "DO_NOT_DISCLOSE_MB985\n" if $state->{fault} eq $kind.'_finish';
        return $rv;
    }
    package MB985::Bot; our @ISA=('Mediabot');
    sub gethChannelsNicksOnChan {@{$_[0]{fixture_nicks}}}
    package MB985::IRC; sub nick_folded {'mediabot'}
    package MB985::Channel; sub get_id {1}
    package MB985::Log; sub log {push @{$_[0]{lines}},$_[2];1}
    package MB985::Metrics; sub inc {$_[0]{$_[1]}++;1}
    package MB985::Achievements;
    sub bump_progress {$_[0]{progress}{$_[2]}++;$_[0]{progress}{$_[2]}}
    sub check_duel {push @{$_[0]{duel}},[@_[1..4]];1}
    sub check_karma {push @{$_[0]{karma}},[@_[1..5]];1}
}
$INC{'MB985/DBI.pm'}=__FILE__;
no warnings qw(redefine once);
local *Mediabot::Helpers::chanset_enabled=sub {$_[0]{games_enabled}};
local *Mediabot::UserCommands::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @{$_[0]{command_logs}},[@_[2..4]];1};
my $tmp=tempdir(CLEANUP=>1);my $serial=0;
sub setup_1361 {
    my (%opts)=@_;my $dsn='dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db=DBI->connect($dsn,'','',{RootClass=>'MB985::DBI',RaiseError=>$opts{raise}//1,PrintError=>0});
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0});
    my $check=$opts{constraint}?'CHECK(score>=0)':'';
    $peer->do("CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER $check,PRIMARY KEY(id_channel,nick))");
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
    $peer->do('CREATE TABLE CALLER_WORK(value TEXT)');
    my $seed=$opts{seed}//{alice=>10,bob=>10};
    $peer->do('INSERT INTO KARMA VALUES(1,?,?)',undef,$_,$seed->{$_}) for sort keys %$seed;
    $peer->do("INSERT INTO KARMA VALUES(2,'alice',100),(2,'bob',100)");
    my $state={fault=>$opts{fault}//'',prepare=>{},execute=>{},finish=>{}};
    $db->{private_mb985}=$state;
    my $bot=Mediabot->new({dbh=>$db});bless $bot,'MB985::Bot';
    $bot->{irc}=bless {},'MB985::IRC';$bot->{games_enabled}=1;
    $bot->{fixture_nicks}=[qw(Alice Bob mediabot)];
    $bot->{channels}{'#test'}=bless {},'MB985::Channel';
    $bot->{logger}=bless {lines=>[]},'MB985::Log';
    $bot->{metrics}=bless {},'MB985::Metrics';
    $bot->{achievements}=bless {duel=>[],karma=>[],progress=>{}},'MB985::Achievements';
    $bot->{wire}=[];$bot->{command_logs}=[];
    $bot->{_duel_stats}={'#other'=>{alice=>{wins=>7}}};
    $bot->{_duel_streak}={'#other'=>{alice=>3}};
    $bot->{_duel_last_result}={'#other'=>{alice=>'win'}};
    $bot->{_duel_cooldown}={'#test'=>{},'#other'=>{"alice\0bob"=>time()+100}};
    return ($bot,$peer,$state,$db);
}
sub invoke_1361 {
    my ($entry,$bot,%opts)=@_;@DICE=@{$opts{dice}//[19,0]};$bot->{wire}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$opts{nick}//'Alice',channel=>$opts{channel}//'#test',
        command=>'duel',args=>[$opts{target}//'Bob']);$ctx->{_user_fetched}=1;
    my $ok=eval {
        if ($entry eq 'registry') {$bot->command_registry->handler_for('duel','public')->($ctx)}
        else {no strict 'refs';&{"${entry}::mbDuel_ctx"}($ctx)}
        1;
    };
    return $ok?'':$@;
}
sub rows_1361 {$_[0]->selectall_arrayref('SELECT id_channel,nick,score FROM KARMA ORDER BY id_channel,nick')}
sub state_1361 {dclone({map {$_=>$_[0]{$_}} qw(_duel_stats _duel_streak _duel_last_result _duel_cooldown achievements metrics command_logs)})}
sub text_1361 {join(' ',map {$_->[2]} @{$_[0]{wire}},map {['log','',$_]} @{$_[0]{logger}{lines}})}

for my $entry (qw(Mediabot::Games::Duel Mediabot::UserCommands Mediabot registry)) {
    for my $case (
        [{alice=>10,bob=>10},[19,0],11,9,'alice','bob'],
        [{},[19,0],1,-1,'alice','bob'],
        [{alice=>10},[19,0],11,-1,'alice','bob'],
        [{alice=>10,bob=>10},[0,19],9,11,'bob','alice'],
    ) {
        my ($seed,$dice,$alice,$bob,$winner,$loser)=@$case;
        my ($bot,$peer,$st)=setup_1361(seed=>$seed);
        is(invoke_1361($entry,$bot,dice=>$dice),'',"$entry: confirmed duel completes");
        is_deeply(rows_1361($peer),[[1,'alice',$alice],[1,'bob',$bob],[2,'alice',100],[2,'bob',100]],
            "$entry: complete score pair visible to an independent connection");
        is($st->{execute}{write},1,"$entry: pair is executed as one SQL statement");
        is($st->{finish}{write},1,"$entry: write cursor finished once");
        is($bot->{_duel_stats}{'#test'}{$winner}{wins},1,"$entry: one confirmed win");
        is($bot->{_duel_stats}{'#test'}{$loser}{losses},1,"$entry: one confirmed loss");
        is($bot->{_duel_streak}{'#test'}{$winner},1,"$entry: winning streak retained");
        is($bot->{_duel_streak}{'#test'}{$loser},-1,"$entry: losing streak retained");
        is($bot->{_duel_cooldown}{'#test'}{"alice\0bob"},time()+86400,"$entry: cooldown starts after confirmation");
        is($bot->{achievements}{duel}[0][0],$winner,"$entry: achievement follows the actual winner");
        is($bot->{achievements}{karma}[0][2],$winner eq 'alice'?$alice:$bob,"$entry: karma achievement reads the committed score");
        is($bot->{metrics}{mediabot_duel_total},1,"$entry: success metric counted once");
        is(scalar @{$bot->{command_logs}},1,"$entry: successful command logged once");
        like(text_1361($bot),qr/wins!.*\+1 karma.*-1/ ,"$entry: original public win response retained");
        like(text_1361($bot),qr/CRIT.*FUMBLE|FUMBLE.*CRIT/,"$entry: critical and fumble rules unchanged");
        $bot->{wire}=[];
        invoke_1361($entry,$bot,nick=>'Bob',target=>'Alice');
        like(text_1361($bot),qr/cooldown active/,"$entry: reverse pair cannot bypass cooldown");
        is($st->{execute}{write},1,"$entry: cooldown never repeats the score write");
    }
}

for my $entry ('Mediabot::Games::Duel','registry') {
    for my $raise (0,1) {
        for my $fault ('write_prepare','write_execute','count_0','count_1','count_5','count_negative') {
            my ($bot,$peer,$st)=setup_1361(raise=>$raise,fault=>$fault);
            my $before=rows_1361($peer);my $memory=state_1361($bot);
            is(invoke_1361($entry,$bot),'',"$entry/$raise/$fault: failure contained");
            is_deeply(rows_1361($peer),$before,"$entry/$raise/$fault: no fabricated/partial write");
            is_deeply(state_1361($bot),$memory,"$entry/$raise/$fault: no win, cooldown, hooks or success accounting");
            like(text_1361($bot),qr/Duel result not confirmed/,"$entry/$raise/$fault: explicit unconfirmed result");
            unlike(text_1361($bot),qr/wins!|DO_NOT_DISCLOSE_MB985/,"$entry/$raise/$fault: no false winner or raw driver details");
            is($st->{execute}{write}//0,$fault eq 'write_prepare'?0:1,"$entry/$raise/$fault: no automatic retry");
        }
        {
            my ($bot,$peer,$st)=setup_1361(raise=>$raise,constraint=>1,seed=>{alice=>10,bob=>0});
            my $before=rows_1361($peer);my $memory=state_1361($bot);
            is(invoke_1361($entry,$bot),'',"$entry/$raise: actual losing-row constraint failure is contained");
            is_deeply(rows_1361($peer),$before,"$entry/$raise: losing-row failure also undoes the winner's change");
            is_deeply(state_1361($bot),$memory,"$entry/$raise: actual SQL failure leaves gameplay state unchanged");
            like(text_1361($bot),qr/not confirmed/,"$entry/$raise: SQL failure cannot announce a win");
            is($st->{finish}{write},1,"$entry/$raise: failed SQL cursor still cleaned up");
        }
        for my $fault ('lost_ack','write_status') {
            my ($bot,$peer,$st)=setup_1361(raise=>$raise,fault=>$fault);my $memory=state_1361($bot);
            is(invoke_1361($entry,$bot),'',"$entry/$raise/$fault: uncertain acknowledgement is contained");
            is_deeply(rows_1361($peer),[[1,'alice',11],[1,'bob',9],[2,'alice',100],[2,'bob',100]],
                "$entry/$raise/$fault: server-side success can exist despite a lost acknowledgement");
            is_deeply(state_1361($bot),$memory,"$entry/$raise/$fault: uncertain acknowledgement is never published as success");
            is($st->{execute}{write},1,"$entry/$raise/$fault: ambiguous outcome is not retried");
            unlike(text_1361($bot),qr/wins!|DO_NOT_DISCLOSE_MB985/,"$entry/$raise/$fault: safe public outcome");
        }
    }
}

for my $fault ('write_finish','count_3','count_4','read_prepare','read_execute','read_fetch','read_status','read_fetch_status','read_finish') {
    my ($bot,$peer,$st)=setup_1361(fault=>$fault);
    is(invoke_1361('registry',$bot),'',"$fault: confirmed pair survives cleanup or optional achievement-read failure");
    is_deeply(rows_1361($peer),[[1,'alice',11],[1,'bob',9],[2,'alice',100],[2,'bob',100]],"$fault: confirmed karma pair retained");
    like(text_1361($bot),qr/wins!/,"$fault: confirmed duel stays successful");
    unlike(text_1361($bot),qr/DO_NOT_DISCLOSE_MB985/,"$fault: no raw error exposed");
    is($bot->{metrics}{mediabot_duel_total},1,"$fault: success accounting survives optional failure");
    is(scalar @{$bot->{achievements}{karma}},$fault =~ /^read_/ && $fault ne 'read_finish'?0:1,
        "$fault: only a confirmed achievement score is used");
}

for my $missing ('handle','channel','transaction') {
    my ($bot,$peer,$st,$db)=setup_1361();my $before=rows_1361($peer);my $memory=state_1361($bot);
    $bot->{dbh}=undef if $missing eq 'handle';
    $bot->{channels}={} if $missing eq 'channel';
    if ($missing eq 'transaction') {$db->begin_work;$db->do("INSERT INTO CALLER_WORK VALUES('keep')")}
    is(invoke_1361('registry',$bot),'',"$missing: missing precondition is contained");
    is_deeply(rows_1361($peer),$before,"$missing: no committed score change");
    is_deeply(state_1361($bot),$memory,"$missing: no false victory state");
    is($st->{prepare}{write}//0,0,"$missing: refused before any score statement");
    if ($missing eq 'transaction') {
        ok(!$db->{AutoCommit},'caller transaction remains open');
        is($db->selectrow_array('SELECT COUNT(*) FROM CALLER_WORK'),1,'caller pending work retained');
        is($peer->selectrow_array('SELECT COUNT(*) FROM CALLER_WORK'),0,'caller work not committed by duel');
        $db->commit;
        is_deeply(rows_1361($peer),$before,'caller commit cannot reveal an uninvited duel score change');
    }
}
{
    my ($bot,$peer,$st)=setup_1361();my $before=rows_1361($peer);my $memory=state_1361($bot);
    is(invoke_1361('registry',$bot,dice=>[9,9]),'','draw path still completes');
    like(text_1361($bot),qr/Draw! No cooldown/,'draw response unchanged');
    is_deeply(rows_1361($peer),$before,'draw changes no scores');
    is_deeply(state_1361($bot),$memory,'draw changes no winner state');
    is($st->{prepare}{write}//0,0,'draw needs no score statement');
    $bot->{_duel_streak}{'#test'}={alice=>-5,bob=>4};
    $bot->{_duel_last_result}{'#test'}={alice=>'loss',bob=>'win'};
    invoke_1361('registry',$bot);
    is($bot->{achievements}{duel}[0][3],5,'underdog hook sees losing streak before the confirmed win');
    is($bot->{_duel_streak}{'#test'}{alice},1,'underdog win starts a new winning streak');
    is($bot->{_duel_streak}{'#test'}{bob},-1,'previous winner starts a new losing streak');
}
done_testing;
