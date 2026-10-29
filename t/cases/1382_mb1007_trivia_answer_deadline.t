use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
our $NOW;
BEGIN { *CORE::GLOBAL::time=sub {defined($NOW)?int($NOW):CORE::time()} }
use Time::HiRes ();
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1007::DBI; our @ISA=('DBI');
    package MB1007::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $write=$sql=~/INSERT INTO TRIVIA_SCORES/;
        $sql=~s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql=~s/NOW\(\)/CURRENT_TIMESTAMP/g;
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_score_write}=$write if $sth;
        return $sth;
    }
    package MB1007::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{Database}{private_writes}++ if $sth->{private_score_write};
        return $sth->SUPER::execute(@bind);
    }
    package MB1007::Conf; sub get {$_[0]{$_[1]}}
    package MB1007::Log; sub log {1}
    package MB1007::Channel; sub get_id {$_[0]{id}}
    package MB1007::Metrics; sub inc {$_[0]{counts}{$_[1]}++}
    package MB1007::Awards; sub check_trivia {push @{$_[0]{calls}},[@_[1..4]];1}
}
$INC{'MB1007/DBI.pm'}=__FILE__;
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Time::HiRes::time=sub {$NOW};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
local *Mediabot::UserCommands::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {1};
local *Mediabot::UserCommands::_ach_progress=sub {push @{$_[0]{progress}},[@_[1..3]];41};
local *Mediabot::UserCommands::_trivia_fetch_async=sub {
    my ($bot,$cat,$diff,$done)=@_;$bot->{ready}=$done;1
};
my $other={active=>1,answer=>'rome',answer_display=>'Rome',deadline=>2000,scores=>{Bob=>7}};
sub setup_1382 {
    my ($lang,$timeout)=@_;$timeout//=30;$NOW=1000.125;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB1007::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $db->do('CREATE TABLE TRIVIA_SCORES(id_channel INTEGER,nick TEXT,score INTEGER,last_correct TEXT,PRIMARY KEY(id_channel,nick))');
    $db->do("INSERT INTO TRIVIA_SCORES VALUES(1,'alice',40,'2026-10-28'),(2,'alice',90,'2026-10-28')");
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{conf}=bless {'main.TRIVIA_TIMEOUT'=>$timeout},'MB1007::Conf';
    $bot->{logger}=bless {},'MB1007::Log';
    $bot->{metrics}=bless {counts=>{}},'MB1007::Metrics';
    $bot->{achievements}=bless {calls=>[]},'MB1007::Awards';
    $bot->{channels}={map {$_->[0]=>bless({id=>$_->[1]},'MB1007::Channel')} ['#test',1],['#other',2]};
    $bot->{wire}=[];$bot->{progress}=[];$bot->{_trivia}{'#other'}=dclone($other);
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>'#test',command=>'trivia',args=>[$lang]);
    $bot->command_registry->handler_for('trivia','public')->($ctx);
    $NOW=1000.75;
    $bot->{ready}->({ok=>1,question=>{question=>'Capital of France?',correct_answer=>'Paris',
        incorrect_answers=>['Rome','Berlin','Madrid'],category=>'Geography',difficulty=>'easy'}});
    $bot->{wire}=[];$bot->{metrics}{counts}={};
    $bot->{_trivia}{'#test'}{scores}={Alice=>4};
    return $bot;
}
sub snapshot_1382 {
    my ($bot)=@_;my $game=$bot->{_trivia}{'#test'};
    return dclone({wire=>$bot->{wire},active=>$game->{active},scores=>$game->{scores},
        stored=>$bot->{dbh}->selectall_arrayref('SELECT id_channel,nick,score FROM TRIVIA_SCORES ORDER BY id_channel'),
        writes=>$bot->{dbh}{private_writes}//0,metrics=>$bot->{metrics}{counts},
        awards=>$bot->{achievements}{calls},progress=>$bot->{progress},other=>$bot->{_trivia}{'#other'}});
}
sub expected_1382 {
    my ($text,$won)=@_;
    return {wire=>[['public','#test',$text]],active=>0,scores=>{Alice=>$won?5:4},
        stored=>[[1,'alice',$won?41:40],[2,'alice',90]],writes=>$won?1:0,
        metrics=>$won?{mediabot_trivia_correct_total=>1,mediabot_trivia_db_saves_total=>1}:{mediabot_trivia_timeout_total=>1},
        awards=>$won?[['Alice','#test',41,29.75]]:[],progress=>$won?[['trivia_correct','Alice','#test']]:[],other=>$other};
}
{
    my (@actual,@expected);
    for my $lang (qw(en fr)) {
        for my $timeout (30,120,0) {
            my $bot=setup_1382($lang,$timeout);my $g=$bot->{_trivia}{'#test'};
            push @actual,[@$g{qw(started deadline timeout language)}];
            my $seconds=$timeout||30;
            push @expected,[1000.75,1000.75+$seconds,$seconds,$lang];
        }
    }
    is_deeply(\@actual,\@expected,'each ready question receives its full configured duration from one fractional start time, in both languages');
}
{
    my (@actual,@expected);
    for my $lang (qw(en fr)) {
        my $bot=setup_1382($lang);$bot->{_trivia}{'#test'}{deadline}=1030.75;
        $bot->{_trivia}{'#test'}{hint_given}=1;$NOW=1030.5;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','Paris');
        Mediabot::Games::Trivia::checkTriviaAnswer($bot,'Alice','#test','Paris');
        push @actual,snapshot_1382($bot);
        my $text=$lang eq 'fr'?"Bonne réponse, Alice ! \x0303[FACILE]\x0f La réponse était : Paris  (score : 5)"
            :"Correct, Alice! \x0303[EASY]\x0f The answer was: Paris  (score: 5)";
        push @expected,expected_1382($text,1);
    }
    is_deeply(\@actual,\@expected,'a correct answer just before the deadline earns exactly one session point, persisted point and achievement event');
}
for my $case ([1030.75,'Paris','the exact deadline'],[1030.875,'Paris','a fractional instant after the deadline'],[1031.75,'wrong','a later message']) {
    my ($when,$answer,$label)=@$case;my (@actual,@expected);
    for my $lang (qw(en fr)) {
        my $bot=setup_1382($lang);$bot->{_trivia}{'#test'}{deadline}=1030.75;$NOW=$when;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test',$answer);
        Mediabot::Games::Trivia::checkTriviaAnswer($bot,'Alice','#test','Paris');
        push @actual,snapshot_1382($bot);
        my $text=$lang eq 'fr'?"Temps écoulé ! \x0303[FACILE]\x0f La réponse était : Paris (Geography)"
            :"Time's up! \x0303[EASY]\x0f The answer was: Paris (Geography)";
        push @expected,expected_1382($text,0);
    }
    is_deeply(\@actual,\@expected,"$label: one localized timeout, no score write or award, and other channel preserved");
}
{
    my (@actual,@expected);
    for my $lang (qw(en fr)) {
        my $bot=setup_1382($lang);$bot->{_trivia}{'#test'}{deadline}=1030.75;$NOW=1020.75;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','wrong');
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','still wrong');
        $bot->{_trivia}{'#test'}{active}=0;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','Paris');
        my $state=snapshot_1382($bot);push @actual,[$state,$bot->{_trivia}{'#test'}{hint_given}];
        my $e=expected_1382($lang eq 'fr'?'Indice : p____':'Hint: p____',0);$e->{metrics}={};
        push @expected,[$e,1];
    }
    is_deeply([\@actual,\@warnings],[\@expected,[]],'wrong answers keep the single half-time hint, inactive questions remain inert and clocks emit no warnings');
}
done_testing;
