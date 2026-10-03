package MB813RandomQuoteFixture;
use strict;
use warnings;
use DBI;
use File::Temp qw(tempdir);
use Mediabot::RandomQuote::Runtime;
use Mediabot::AI::ConversationRuntimeState;
use MockBot;
use MockUser;
{
    package MB813::IRC;
    our @ISA=('MockIRC');
    sub is_connected {$_[0]{connected}}
}
{
    package MB813::DB;
    sub connect_isolated_handle {
        my ($self)=@_;$self->{connections}++;
        return (DBI->connect($self->{dsn},'','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1}),undef);
    }
}
{
    package MB813::Worker;
    our @jobs;
    sub start {my ($class,%args)=@_;push @jobs,\%args;return bless {},$class}
    sub complete {
        my ($class,$job,$result)=@_;
        $result ||= {ok=>1,value=>$job->{child}->()};
        $job->{on_done}->($result);return $result;
    }
}
sub new {
    my ($class)=@_;my $dir=tempdir(CLEANUP=>1);
    my $dsn="dbi:SQLite:dbname=$dir/quotes.db";
    my $dbh=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $dbh->do('CREATE TABLE CHANNEL (id_channel INTEGER PRIMARY KEY,name TEXT)');
    $dbh->do('CREATE TABLE CHANSET_LIST (id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    $dbh->do('CREATE TABLE CHANNEL_SET (id_channel INTEGER,id_chanset_list INTEGER)');
    $dbh->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $dbh->do('CREATE TABLE QUOTES (id_quotes INTEGER PRIMARY KEY,id_channel INTEGER,id_user INTEGER,quotetext TEXT,ts TEXT,hits INTEGER DEFAULT 0)');
    $dbh->do(q{INSERT INTO CHANNEL VALUES (1,'#test'),(2,'#other'),(3,'#third'),(4,'#console')});
    $dbh->do(q{INSERT INTO CHANSET_LIST VALUES (1,'RandomQuote')});
    $dbh->do(q{INSERT INTO CHANNEL_SET VALUES (1,1)});
    $dbh->do(q{INSERT INTO USER VALUES (1,'Pablo')});
    $dbh->do(q{INSERT INTO QUOTES VALUES (1,1,1,'First quote','2026-10-03',0),(2,1,NULL,'Anonymous quote','2026-10-03',0),(3,2,NULL,'Other quote','2026-10-03',0)});
    my $bot=MockBot->new(dbh=>$dbh,mock_user=>MockUser->new(auth=>1,level=>'Administrator'));
    bless $bot->{irc},'MB813::IRC';$bot->{irc}{connected}=1;$bot->{_start_time}=1;
    $bot->{db}=bless {dsn=>$dsn},'MB813::DB';
    $bot->{wit_runtime_state}=Mediabot::AI::ConversationRuntimeState->new;
    $bot->{wit_runtime_state}->mark_connected;
    $bot->{wit_runtime_state}->mark_joined('#test');
    $bot->{wit_runtime_state}->mark_joined('#other');
    my $self=bless {dir=>$dir,bot=>$bot,dbh=>$dbh,now=>1000000},$class;
    $self->{state}=Mediabot::RandomQuote::State->new(path=>"$dir/state.json",now=>sub{$self->{now}});
    $self->{runtime}=Mediabot::RandomQuote::Runtime->new(bot=>$bot,state=>$self->{state},worker_class=>'MB813::Worker');
    $bot->{randomquote_runtime}=$self->{runtime};@MB813::Worker::jobs=();return $self;
}
1;
