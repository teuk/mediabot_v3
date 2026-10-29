use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
use Time::HiRes ();
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1008::DBI; our @ISA=('DBI');
    package MB1008::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $write=$sql=~/INSERT INTO TRIVIA_SCORES/;
        if ($write) {
            $db->{private_prepares}++;
            return $db->set_err(1,'private score prepare detail') if ($db->{private_fault}//'') eq 'prepare';
        }
        $sql=~s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql=~s/NOW\(\)/CURRENT_TIMESTAMP/g;
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_write}=$write if $sth;
        return $sth;
    }
    package MB1008::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->SUPER::execute(@bind) unless $sth->{private_write};
        my $db=$sth->{Database};my $fault=$db->{private_fault}//'';
        $db->{private_executes}++;
        push @{$db->{private_binds}},[@bind];
        return $sth->set_err(1,'private score execute detail') if $fault eq 'execute';
        return '0E0' if $fault eq 'zero_rows';
        return -1 if $fault eq 'unknown_count';
        my $result=$sth->SUPER::execute(@bind);
        $db->{private_actual_writes}++;
        return $sth->set_err(1,'private score lost acknowledgement') if $fault eq 'lost_ack';
        $sth->set_err(1,'private score flagged acknowledgement') if $fault eq 'error_flag';
        return 2 if $fault eq 'affected_two' || $fault eq 'error_flag';
        return $result;
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_write}) {
            $sth->{Database}{private_finished}++;
            $sth->set_err(undef,undef);
            die "private score cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        return $sth->SUPER::finish;
    }
    package MB1008::Channel; sub get_id {$_[0]{id}}
    package MB1008::Log;
    sub log {push @{$_[0]{entries}},[@_[1,2]];die "private logger detail\n" if $_[0]{fail};1}
    package MB1008::Metrics; sub inc {$_[0]{counts}{$_[1]}++}
    package MB1008::Awards; sub check_trivia {push @{$_[0]{calls}},[@_[1..4]];1}
}
$INC{'MB1008/DBI.pm'}=__FILE__;
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Time::HiRes::time=sub {1001};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::_ach_progress=sub {5};
my $resolve=\&Mediabot::Helpers::channel_id_cached;
local *Mediabot::Helpers::channel_id_cached=sub {
    die "private channel lookup detail\n" if ($_[0]{private_resolution}//'') eq 'throw';
    return undef if ($_[0]{private_resolution}//'') eq 'missing';
    return $resolve->(@_);
};
my $other={active=>1,answer=>'rome',deadline=>2000,scores=>{Bob=>9}};
sub setup_1383 {
    my ($raise,$lang)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1008::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1});
    $db->do('CREATE TABLE TRIVIA_SCORES(id_channel INTEGER,nick TEXT,score INTEGER,last_correct TEXT,PRIMARY KEY(id_channel,nick))');
    $db->do("INSERT INTO TRIVIA_SCORES VALUES(1,'alice',40,'2026-10-29'),(2,'alice',90,'2026-10-29')");
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{channels}={'#test'=>bless({id=>1},'MB1008::Channel')};
    $bot->{wire}=[];$bot->{logger}=bless {entries=>[]},'MB1008::Log';
    $bot->{metrics}=bless {counts=>{}},'MB1008::Metrics';
    $bot->{achievements}=bless {calls=>[]},'MB1008::Awards';
    $bot->{_trivia}={'#test'=>{active=>1,answer=>'paris',answer_display=>'Paris',
        scores=>{Alice=>4},hint_given=>1,started=>1000,deadline=>1030,language=>$lang},'#other'=>dclone($other)};
    return ($bot,$db);
}
sub invoke_1383 {
    my ($bot)=@_;
    my $ok=eval {
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','Paris');
        Mediabot::Games::Trivia::checkTriviaAnswer($bot,'Alice','#test','Paris');
        1;
    };
    return $ok?'':"$@";
}
sub snapshot_1383 {
    my ($bot,$db,$error)=@_;
    return dclone({error=>$error,wire=>$bot->{wire},active=>$bot->{_trivia}{'#test'}{active},
        scores=>$bot->{_trivia}{'#test'}{scores},stored=>$db->selectall_arrayref(
            'SELECT id_channel,nick,score FROM TRIVIA_SCORES ORDER BY id_channel'),
        prepares=>$db->{private_prepares}//0,executes=>$db->{private_executes}//0,
        writes=>$db->{private_actual_writes}//0,finished=>$db->{private_finished}//0,
        binds=>$db->{private_binds}//[],autocommit=>$db->{AutoCommit}?1:0,
        metrics=>$bot->{metrics}{counts},logs=>$bot->{logger}{entries},
        awards=>$bot->{achievements}{calls},other=>$bot->{_trivia}{'#other'}});
}
sub expected_1383 {
    my ($lang,$confirmed,$written,$prepare,$execute,$finish,$autocommit)=@_;$autocommit//=1;
    my $reply=$lang eq 'fr'?'Bonne réponse, Alice ! La réponse était : Paris  (score : 5)'
        :'Correct, Alice! The answer was: Paris  (score: 5)';
    my @wire=(['public','#test',$reply]);
    push @wire,['notice','Alice',$lang eq 'fr'
        ?'Point de manche compté, mais son enregistrement au classement n’a pas pu être confirmé.'
        :'Round point counted, but its leaderboard save could not be confirmed.'] unless $confirmed;
    my $metrics={mediabot_trivia_correct_total=>1};$metrics->{mediabot_trivia_db_saves_total}=1 if $confirmed;
    return {error=>'',wire=>\@wire,active=>0,scores=>{Alice=>5},stored=>[[1,'alice',40+$written],[2,'alice',90]],
        prepares=>$prepare,executes=>$execute,writes=>$written,finished=>$finish,
        binds=>$execute?[[1,'alice']]:[],autocommit=>$autocommit,metrics=>$metrics,
        logs=>$confirmed?[]:[[1,'checkTriviaAnswer(): score save unconfirmed']],awards=>[['Alice','#test',5,1]],other=>$other};
}
for my $lang (qw(en fr)) {
    for my $raise (0,1) {
        my (@actual,@expected);
        for my $fault (qw(prepare execute zero_rows unknown_count lost_ack error_flag)) {
            my ($bot,$db)=setup_1383($raise,$lang);$db->{private_fault}=$fault;
            my $error=invoke_1383($bot);$db->{private_fault}='';
            push @actual,[$fault,snapshot_1383($bot,$db,$error)];
            push @expected,[$fault,expected_1383($lang,0,$fault=~/^(?:lost_ack|error_flag)$/?1:0,
                1,$fault eq 'prepare'?0:1,$fault eq 'prepare'?0:1)];
        }
        is_deeply(\@actual,\@expected,"$lang RaiseError=$raise: unconfirmed writes never count as saved; the round continues with one private warning and no retry");
    }
}
{
    my (@actual,@expected);
    for my $lang (qw(en fr)) {
        for my $fault ('','affected_two') {
            my ($bot,$db)=setup_1383(1,$lang);$db->{private_fault}=$fault;
            push @actual,snapshot_1383($bot,$db,invoke_1383($bot));
            push @expected,expected_1383($lang,1,1,1,1,1);
        }
    }
    is_deeply(\@actual,\@expected,'confirmed affected counts one and two retain the single saved point, success metric, awards and existing EN/FR output');
}
{
    my (@actual,@expected);
    for my $lang (qw(en fr)) {
        my ($bot,$db)=setup_1383(1,$lang);$db->{private_cleanup_failure}=1;$bot->{logger}{fail}=1;
        push @actual,snapshot_1383($bot,$db,invoke_1383($bot));
        push @expected,expected_1383($lang,1,1,1,1,1);
    }
    is_deeply(\@actual,\@expected,'cleanup failure alone cannot turn a confirmed increment into a failed save or prevent the round acknowledgement');
}
{
    my ($bot,$db)=setup_1383(0,'fr');$db->{private_fault}='execute';
    $db->{private_cleanup_failure}=1;$bot->{logger}{fail}=1;
    my $error=invoke_1383($bot);$db->{private_fault}='';
    is_deeply(snapshot_1383($bot,$db,$error),expected_1383('fr',0,0,1,1,1),
        'cleanup and logger failures cannot escape the score-write boundary or hide its private warning');
}
{
    my (@actual,@expected);
    for my $scope (qw(no_database missing throw transaction)) {
        my ($bot,$db)=setup_1383(1,'en');
        delete $bot->{dbh} if $scope eq 'no_database';
        $bot->{private_resolution}=$scope if $scope eq 'missing' || $scope eq 'throw';
        $db->begin_work if $scope eq 'transaction';
        push @actual,[$scope,snapshot_1383($bot,$db,invoke_1383($bot))];
        push @expected,[$scope,expected_1383('en',0,0,0,0,0,$scope eq 'transaction'?0:1)];
        $db->rollback if $scope eq 'transaction';
    }
    is_deeply(\@actual,\@expected,'missing database/channel and a foreign transaction cannot become saved points or trigger an unowned commit/rollback');
}
is_deeply(\@warnings,[],'persistence result handling emits no warnings');
done_testing;
