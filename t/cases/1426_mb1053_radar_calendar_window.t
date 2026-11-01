use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB1053::DBI; our @ISA=('DBI');
    package MB1053::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $history=$sql =~ /SELECT\s+DATE\(cl\.ts\)/ ? 1:0;
        my $state=$db->{private_mb1053};
        if ($history && ($state->{fault}//'') eq 'prepare') {
            return $db->set_err(1901,'local prepare failure');
        }
        $sql =~ s/NOW\(\)\s*-\s*INTERVAL\s+(\d+)\s+DAY/DATETIME(NOW(), '-$1 day')/ig;
        $sql =~ s/CURDATE\(\)\s*-\s*INTERVAL\s+\?\s+DAY/DATETIME(CURDATE(), '-' || ? || ' day')/ig;
        $sql =~ s/CURDATE\(\)\s*\+\s*INTERVAL\s+1\s+DAY/DATETIME(CURDATE(), '+1 day')/ig;
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth && $history) {$sth->{private_mb1053}=$state;$sth->{private_mb1053_fetched}=0}
        return $sth;
    }
    package MB1053::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->set_err(1902,'local execute failure')
            if ($sth->{private_mb1053}{fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth)=@_;
        return $sth->set_err(1903,'local partial fetch failure')
            if ($sth->{private_mb1053}{fault}//'') eq 'fetch'
                && $sth->{private_mb1053_fetched}++;
        return $sth->SUPER::fetchrow_hashref;
    }
    sub finish {
        my ($sth)=@_;
        die "local cleanup failure\n" if $sth->{private_mb1053}{finish_error};
        return $sth->SUPER::finish;
    }
}
$INC{'MB1053/DBI.pm'}=__FILE__;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',@_[1,2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',@_[1,2]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub fixture_1426 {
    my ($today,$rows)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB1053::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->{private_mb1053}={};
    $db->sqlite_create_function('CURDATE',0,sub {$today});
    $db->sqlite_create_function('NOW',0,sub {"$today 10:00:00"});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE)');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{CREATE TABLE CHANNEL_LOG(id_channel INTEGER,ts TEXT,event_type TEXT)});
    for my $row (@$rows) {
        my ($stamp,$count,$kind,$cid)=@$row;
        for (1..$count) {$db->do('INSERT INTO CHANNEL_LOG VALUES(?,?,?)',undef,$cid//1,$stamp,$kind//'public')}
    }
    return (bless({dbh=>$db},'Mediabot'),$db);
}
sub invoke_1426 {
    my ($bot,$days,$entry)=@_;
    $entry //='Mediabot';@wire=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#test',args=>[$days]);
    no strict 'refs';
    my $ok=eval {&{$entry.'::mbRadar_ctx'}($ctx);1};
    return $ok ? '' : "$@";
}
sub view_1426 {
    my ($error)=@_;
    my $text=join ' ',map {$_->[2]} @wire;
    my ($spark,$total,$avg)=$text =~ /📈 (\S+)\s+·\s+total (\d+) msgs\s+·\s+avg (\d+)\/d/;
    my ($best,$best_n,$worst,$worst_n)=$text =~ /best:\s+(\S+) \((\d+) msgs\).*worst:\s+(\S+) \((\d+) msgs\)/;
    return [$error,$spark,$total,$avg,$best,$best_n,$worst,$worst_n,
        [map {[$_->[0],$_->[1]]} @wire]];
}
sub wanted_1426 {
    return ['',@_,[(['public','#test']) x 3]];
}
my @rows=(
    ['2026-10-25 23:59:59',7],['2026-10-26 00:00:00',1],
    ['2026-10-29 18:00:00',3],['2026-11-01 09:00:00',2,'action'],
    ['2026-11-02 00:00:00',10],['2026-11-01 08:00:00',20,'join'],
    ['2026-11-01 08:00:00',20,'public',2]);
my $seven=wanted_1426('▃▁▁█▁▁▅',6,1,'2026-10-29',3,'2026-10-27',0);
my $thirty=wanted_1426(('▁'x22).'█▂▁▁▄▁▁▃',13,0,'2026-10-25',7,'2026-10-03',0);
my ($bot,$db)=fixture_1426('2026-11-01',\@rows);
for my $case (
    ['1d',wanted_1426('█',2,2,'2026-11-01',2,'2026-11-01',2)],
    ['2d',wanted_1426('▁█',2,1,'2026-11-01',2,'2026-10-31',0)],
    ['7D',$seven],['30d',$thirty],['0d',wanted_1426('█',2,2,'2026-11-01',2,'2026-11-01',2)],['999d',$thirty]) {
    is_deeply(view_1426(invoke_1426($bot,$case->[0])),$case->[1],
        "$case->[0]: calendar bars, total, average and extrema share the exact bounded window");
}
for my $tz ('Pacific/Kiritimati','America/Los_Angeles') {
    local $ENV{TZ}=$tz;
    is_deeply(view_1426(invoke_1426($bot,'7d')),$seven,"database calendar remains authoritative under host TZ=$tz");
}
for my $entry (qw(Mediabot::Stats::Radar Mediabot::UserCommands Mediabot)) {
    is_deeply(view_1426(invoke_1426($bot,'7d',$entry)),$seven,"$entry: the real historical facade uses the same calendar view");
}
$db->disconnect;
for my $case (
    ['2026-03-30','2026-03-28','2026-03-29'],
    ['2026-10-26','2026-10-24','2026-10-25'],
    ['2028-03-01','2028-02-28','2028-02-29'],
    ['2027-01-01','2026-12-30','2026-12-31']) {
    my ($today,$first,$silent)=@$case;
    my ($b,$h)=fixture_1426($today,[[$first.' 12:00:00',1],[$today.' 09:00:00',1]]);
    is_deeply(view_1426(invoke_1426($b,'3d')),
        wanted_1426('█▁█',2,1,$first,1,$silent,0),"$today: calendar dates retain silent days across DST, leap/year boundaries");
    $h->disconnect;
}
{
    my ($b,$h)=fixture_1426('2026-11-01',[]);
    is_deeply([invoke_1426($b,'7d'),\@wire],
        ['',[['public','#test',"📡 \x02Radar\x02 #test: no data in last 7d"]]],
        'confirmed empty history retains the existing no-data response');
    $h->disconnect;
}
for my $raise (0,1) {
    for my $fault (qw(prepare execute fetch)) {
        my ($b,$h)=fixture_1426('2026-11-01',\@rows);
        $h->{RaiseError}=$raise;$h->{private_mb1053}{fault}=$fault;
        is_deeply([invoke_1426($b,'7d'),\@wire],['',[['notice','Operator','Database error.']]],
            "$fault RaiseError=$raise: failed or partial history is never rendered as a valid chart");
        $h->disconnect;
    }
}
for my $fault ('','fetch') {
    my ($b,$h)=fixture_1426('2026-11-01',\@rows);
    $h->{private_mb1053}={fault=>$fault,finish_error=>1};
    my $error=invoke_1426($b,'7d');
    if ($fault) {
        is_deeply([$error,\@wire],['',[['notice','Operator','Database error.']]],
            'cleanup failure cannot replace the original partial-read failure');
    } else {
        is_deeply(view_1426($error),$seven,'cleanup failure cannot discard a completely read calendar view');
    }
    $h->disconnect;
}
is_deeply(\@warnings,[],'native calendar, empty and database-failure paths are warning-free');
done_testing;
