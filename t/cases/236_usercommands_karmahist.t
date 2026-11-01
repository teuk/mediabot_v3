use strict;
use warnings;
use Test::More;
use DBI;
BEGIN { *CORE::GLOBAL::time = sub { 5000 } }
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package KarmaHistory::DBI; our @ISA=('DBI');
    package KarmaHistory::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $st=$db->SUPER::prepare($sql,@rest);
        $st->{private_kh_fault}=$db->{private_kh_fault} if $st;
        return $st;
    }
    package KarmaHistory::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($st,@bind)=@_;
        push @{$st->{Database}{private_kh_queries}},[$st->{Statement},\@bind]
            if $st->{Statement}=~/SELECT.*FROM KARMA_LOG/s;
        return $st->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($st,@rest)=@_;
        if (($st->{private_kh_fault}//'') eq 'fetch' && ++$st->{private_kh_reads}==3) {
            $st->set_err(1105,'fixture fetch failed');
            return undef;
        }
        return $st->SUPER::fetchrow_hashref(@rest);
    }
    sub finish {
        my ($st)=@_;
        $st->set_err(undef,undef); # Cleanup may clear the preceding fetch error.
        my $ok=$st->SUPER::finish;
        die "fixture cleanup failed\n" if ($st->{private_kh_fault}//'') eq 'finish';
        return $ok;
    }
    package KarmaHistory::Channel; sub get_id {1}
    package KarmaHistory::Metrics; sub inc {$_[0]{counts}{$_[1]}++;1}
}
$INC{'KarmaHistory/DBI.pm'}=__FILE__;
my (@wire,@logs,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,[$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @logs,[@_[3,4]];1};
local *Mediabot::UserCommands::_seconds_to_human=sub {"$_[0]s"};
local $SIG{__WARN__}=sub {push @warnings,@_};

my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
    RootClass=>'KarmaHistory::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1});
$db->sqlite_create_function('UNIX_TIMESTAMP',1,sub {$_[0]});
$db->do('CREATE TABLE KARMA_LOG(id_karma_log INTEGER PRIMARY KEY,id_channel INTEGER,nick TEXT COLLATE NOCASE,delta INTEGER,from_nick TEXT,score INTEGER,ts INTEGER)') or die $db->errstr;
for my $i(1..26) {
    $db->do('INSERT INTO KARMA_LOG VALUES(?,1,?,?,?,?,?)',undef,
        $i,$i<=6?'bob':'alice',$i%2?-1:1,"voter$i",$i,1000+$i) or die $db->errstr;
}
$db->do("INSERT INTO KARMA_LOG VALUES(100,2,'bob',1,'other-channel',999,4000)") or die $db->errstr;
my $bot=Mediabot->new({dbh=>$db});
$bot->{channels}{'#test'}=bless {},'KarmaHistory::Channel';
$bot->{metrics}=bless {counts=>{}},'KarmaHistory::Metrics';
my $handler=$bot->command_registry->handler_for('karmahist','public');
sub invoke_history {
    my ($channel,@args)=@_;
    @wire=();$db->{private_kh_queries}=[];
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
        command=>'karmahist',args=>\@args);
    $ctx->{_user_fetched}=1;
    $handler->($ctx);
}
sub voters { [map {$_->[1]=~/ by (\S+) / ? $1:()} @wire] }
sub memory_vote {my ($who,$ts)=@_;{nick=>'bob',delta=>'+1',score=>9,from=>$who,ts=>$ts}}

invoke_history('#test');
is_deeply(voters(),[map {"voter$_"} reverse 22..26],'native registry returns the five newest database votes in descending order');
like(join(' ',map {$_->[1]} @wire),qr/\(\+3\/-2\).*voter26 .*3974s ago/s,'header summarizes only displayed votes and their ages remain accurate');
invoke_history('#test','BOB');
is_deeply(voters(),[map {"voter$_"} reverse 2..6],'nick filtering precedes the SQL limit and retains older matching history');
is_deeply($db->{private_kh_queries}[-1][1],[1,'bob'],'channel and normalized nick remain bound SQL parameters');
for my $i(27,28) {$db->do("INSERT INTO KARMA_LOG VALUES(?,1,'alice',1,?,?,2000)",undef,$i,"voter$i",$i) or die $db->errstr}
invoke_history('#test');
is_deeply(voters(),[qw(voter28 voter27 voter26 voter25 voter24)],'equal timestamps are ordered by the existing history primary key');
my $quoted=q{bob' OR 1=1 --};
invoke_history('#test',$quoted);
is_deeply([$db->{private_kh_queries}[-1][1],voters(),$db->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG')],
    [[1,lc($quoted)],[],29],'quoted filter stays literal, returns no foreign rows and performs no write');
$bot->{_karma_log}{'#test'}=[memory_vote('memory-only',4900)];
invoke_history('#test');
is_deeply(voters(),[qw(voter28 voter27 voter26 voter25 voter24)],'healthy persistent history takes precedence over the memory fallback');
$db->{private_kh_fault}='fetch';
invoke_history('#test');
is_deeply([voters(),scalar(grep {/\[memory\]/} map {$_->[1]} @wire)],
    [['memory-only'],1],'a partial fetch is discarded before cleanup clears its error, then memory is labeled honestly');
$db->{private_kh_fault}='finish';
invoke_history('#test');
is_deeply(voters(),[qw(voter28 voter27 voter26 voter25 voter24)],'a cleanup exception cannot discard a fully successful read or escape the command');
$db->{private_kh_fault}=undef;
$db->do('DROP TABLE KARMA_LOG') or die $db->errstr;
$bot->{_karma_log}{'#test'}=[memory_vote('mid',200),memory_vote('old',100),memory_vote('new',300)];
invoke_history('#test');
is_deeply(voters(),[qw(new mid old)],'missing optional table falls back to timestamp-ordered memory');
$bot->{_karma_log}{'#test'}=[memory_vote('first',200),memory_vote('second',200)];
invoke_history('#test');
is_deeply(voters(),[qw(second first)],'same-second memory votes keep reverse insertion order');
$bot->{_karma_log}={'#a'=>[memory_vote('a-old',100),memory_vote('a-new',400)],
    '#b'=>[memory_vote('b-old',200),memory_vote('b-new',300)]};
invoke_history(undef);
is_deeply([voters(),[map {$_->[0]} @wire]],[[qw(a-new b-new b-old a-old)],[('Reader')x5]],
    'private history merges channel timestamps before limiting and replies only to the caller');
invoke_history(undef,'absent');
my @unmatched_private=@wire;
$bot->{_karma_log}={};
invoke_history('#test');
is_deeply([\@unmatched_private,\@wire],[[['Reader',"Reader: no karma history for 'absent'."]],
    [['#test','Reader: no karma history yet on #test.']]],
    'unmatched private and empty channel histories keep their own reply destinations and labels');
is_deeply(\@warnings,[],'native query, dispatch and fallback paths complete without warnings');
$db->disconnect;
done_testing;
