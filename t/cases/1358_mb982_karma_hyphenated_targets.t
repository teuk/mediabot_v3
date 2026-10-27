use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
BEGIN { *CORE::GLOBAL::time = sub { 1_900_000_000 } }
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB982::DBI; our @ISA=('DBI');
    package MB982::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        # Translate dialect only; the real handlers execute all writes/reads.
        $sql=~s/ON DUPLICATE KEY UPDATE score = score \+ \?/ON CONFLICT(id_channel,nick) DO UPDATE SET score = score + ?/;
        $sql=~s/INSERT IGNORE INTO KARMA_LOG/INSERT OR IGNORE INTO KARMA_LOG/;
        $sql=~s/NOW\(\)/CURRENT_TIMESTAMP/g;
        return $db->SUPER::prepare($sql,@rest);
    }
    package MB982::DBI::st; our @ISA=('DBI::st');
    package MB982::Bot; our @ISA=('Mediabot');
    sub gethChannelsNicksOnChan { @{$_[0]{fixture_nicks}} }
    package MB982::Channel; sub get_id {1}
    package MB982::Log; sub log {1}
    package MB982::Metrics; sub inc {$_[0]{counts}{$_[1]}++;1}
    package MB982::Achievements;
    sub bump_progress { $_[0]{given}{$_[2]} += $_[4]; $_[0]{given}{$_[2]} }
    sub progress {$_[0]{given}{$_[2]}//0}
    sub check_karma {push @{$_[0]{calls}},[@_[1..5]];1}
}
$INC{'MB982/DBI.pm'}=__FILE__;
my $tmp=tempdir(CLEANUP=>1);my $serial=0;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::Helpers::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Helpers::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {goto &Mediabot::Helpers::botNotice};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
local $SIG{__WARN__}=sub {push @warnings,@_};
my $long='Long-Nick-'.('x'x22);
my @targets=('Alice-Bob','Alice--Bob','Bob-','Bob--','PlainNick',$long);
my @present=(@targets,qw(Bob Carol Dave Te[u]K));

sub setup_1358 {
    my $dsn='dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db=DBI->connect($dsn,'','',{RootClass=>'MB982::DBI',
        RaiseError=>1,PrintError=>0,AutoCommit=>1});
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $peer->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER,PRIMARY KEY(id_channel,nick))');
    $peer->do('CREATE TABLE KARMA_LOG(id_channel INTEGER,nick TEXT,delta INTEGER,from_nick TEXT,score INTEGER,ts TEXT)');
    for my $name (@present) {
        $peer->do('INSERT INTO KARMA VALUES(1,?,10)',undef,lc $name);
        $peer->do('INSERT INTO KARMA VALUES(2,?,90)',undef,lc $name);
    }
    my $bot=Mediabot->new({dbh=>$db});bless $bot,'MB982::Bot';
    $bot->{fixture_nicks}=[@present];
    $bot->{channels}{'#test'}=bless {},'MB982::Channel';
    $bot->{logger}=bless {},'MB982::Log';
    $bot->{metrics}=bless {counts=>{}},'MB982::Metrics';
    $bot->{achievements}=bless {calls=>[],given=>{}},'MB982::Achievements';
    $bot->{_karma_watch}={Watcher=>[map {lc} @present]};
    return ($bot,$peer);
}
sub invoke_1358 {
    my ($entry,$bot,$voter,$op,$target,$text)=@_;
    @wire=();@warnings=();
    my $ok=eval {
        if ($entry eq 'registry') {
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$voter,channel=>'#test',
                command=>'karma',args=>[$op,$target]);
            $ctx->{_user_fetched}=1;
            $bot->command_registry->handler_for('karma','public')->($ctx);
        } else {
            no strict 'refs';
            &{"${entry}::processKarma"}($bot,$voter,'#test',defined($text)?$text:"$target$op");
        }
        1;
    };
    return $ok?'':$@;
}
sub score_1358 {$_[0]->selectrow_array('SELECT score FROM KARMA WHERE id_channel=1 AND nick=?',undef,lc $_[1])}
sub notices_1358 {[map {$_->[2]} grep {$_->[0] eq 'notice'} @wire]}

for my $entry (qw(Mediabot::Karma Mediabot::UserCommands Mediabot registry)) {
    for my $op ($entry eq 'registry' ? ('+','-','++','--') : ('++','--')) {
        for my $target (@targets) {
            my ($bot,$peer)=setup_1358();my $label="$entry $target $op";
            my $delta=$op=~/\+/?1:-1;
            is(invoke_1358($entry,$bot,'Voter',$op,$target),'',"$label: real handler completes");
            is(score_1358($peer,$target),10+$delta,"$label: full intended target changes");
            is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE id_channel=1 AND score!=10'),1,
                "$label: no suffix or unrelated nick is changed");
            is(score_1358($peer,'Bob'),10,"$label: Bob does not receive a vote intended for a compound nick");
            is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE id_channel=2 AND score!=90'),0,
                "$label: another channel is untouched");
            is_deeply($peer->selectall_arrayref('SELECT nick,delta,from_nick,score FROM KARMA_LOG'),
                [[lc($target),$delta,'Voter',10+$delta]],"$label: persisted history records the exact target");
            is($bot->{_karma_log}{'#test'}[0]{nick},lc($target),"$label: memory history agrees");
            is($bot->{achievements}{calls}[0][0],lc($target),"$label: achievement hook receives the intended target");
            is(scalar @{$bot->{achievements}{calls}},1,"$label: one achievement callback");
            is($bot->{metrics}{counts}{mediabot_karma_votes_total},1,"$label: one vote attempt");
            like(join(' ',@{notices_1358()}),qr/\[karmawatch\] \Q@{[lc $target]}\E received/,
                "$label: watchers are notified for the same target");
            is(scalar @warnings,0,"$label: no warning escapes");
        }
    }
}

for my $entry (qw(Mediabot::Karma Mediabot::UserCommands Mediabot)) {
    for my $text ('Absent-Bob++','Absent-Bob--',('X'x35).'Bob++','Alice-Bob+++','Alice-Bob--again') {
        my ($bot,$peer)=setup_1358();
        is(invoke_1358($entry,$bot,'Voter','++','Alice-Bob',$text),'',"$entry $text: rejected token completes");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE score NOT IN(10,90)'),0,
            "$entry $text: no suffix fallback or overlong partial target");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),0,"$entry $text: no false history");
        is(scalar @wire,0,"$entry $text: no false announcement");
    }
    for my $voter ('Alice-Bob','ALICE-BOB','Alice-Bob[away]') {
        my ($bot,$peer)=setup_1358();
        is(invoke_1358($entry,$bot,$voter,'++','Alice-Bob'),'',"$entry $voter: self-vote handler completes");
        is(score_1358($peer,'Bob'),10,"$entry $voter: rejected self-vote cannot mutate Bob");
        is(score_1358($peer,'Alice-Bob'),10,"$entry $voter: self-vote stays blocked");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),0,"$entry $voter: no self-vote persisted");
        like(join(' ',map {$_->[2]} @wire),qr/can't change your own karma/,
            "$entry $voter: original self-vote response retained");
    }
}

{
    my ($bot,$peer)=setup_1358();
    is(invoke_1358('registry',$bot,'Voter','+','Alice-Bob'),'', 'explicit compound vote starts cooldown');
    invoke_1358('Mediabot::Karma',$bot,'Voter','++','ALICE-BOB');
    is(score_1358($peer,'Alice-Bob'),11,'case changes cannot bypass the same-target cooldown');
    is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),1,'cooldown does not duplicate history');
    $bot->{_karma_cooldown}{'#test'}{'voter:alice-bob'}=time()-31;
    invoke_1358('Mediabot::Karma',$bot,'Voter','--','Alice-Bob');
    is(score_1358($peer,'Alice-Bob'),10,'expired cooldown allows the next genuine compound vote');
    is(score_1358($peer,'Bob'),10,'cooldown recovery never redirects to a suffix');
}
{
    my ($bot,$peer)=setup_1358();
    invoke_1358('Mediabot::Karma',$bot,'Voter','++','Alice-Bob',
        'Thanks Alice-Bob++! PlainNick--, Carol++ Dave--');
    is_deeply($peer->selectall_arrayref('SELECT nick,delta FROM KARMA_LOG ORDER BY rowid'),
        [['alice-bob',1],['plainnick',-1],['carol',1]],'punctuation and three-vote cap retained');
    is(score_1358($peer,'Dave'),10,'fourth token stays outside the per-message cap');
}
{
    my ($bot,$peer)=setup_1358();
    invoke_1358('Mediabot::Karma',$bot,"Voter$_",'++','Alice-Bob') for 1..5;
    invoke_1358('Mediabot::Karma',$bot,'Voter6','++','Alice-Bob','Alice-Bob++ PlainNick--');
    is(score_1358($peer,'Alice-Bob'),15,'sixth distinct voter still triggers brigade protection');
    is(score_1358($peer,'PlainNick'),9,'brigade refusal does not suppress a later valid target');
    is(score_1358($peer,'Bob'),10,'brigade tracking does not substitute the suffix');
    is($bot->{metrics}{counts}{mediabot_karma_brigade_blocks},1,'compound target brigade is counted once');
}
done_testing;
