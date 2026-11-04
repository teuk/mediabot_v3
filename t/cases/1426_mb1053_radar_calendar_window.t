use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
use Time::Local qw(timegm);
use Storable qw(dclone);

{
    package MB1053::DBI; our @ISA=('DBI');
    package MB1053::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $kind=$sql =~ /SELECT\s+DATE\(cl\.ts\)/ ? 'history'
            : $sql =~ /SUM\(IF/ ? 'rate' : $sql =~ /AS m\b/ ? 'silence'
            : $sql =~ /AS first\b/ ? 'newcomers' : $sql =~ /hours_silent/ ? 'ghosts'
            : $sql =~ /ORDER BY c DESC/ ? 'talkers' : '';
        my $state=$db->{private_mb1053};
        if ($kind) {push @{$state->{prepared}},$kind}
        if ($kind eq ($state->{kind}//'history') && ($state->{fault}//'') eq 'prepare') {
            return $db->set_err(1901,'local prepare failure');
        }
        $sql =~ s/NOW\(\)\s*-\s*INTERVAL\s+(\d+)\s+(DAY|HOUR)/DATETIME(NOW(), '-$1 $2')/ig;
        $sql =~ s/CURDATE\(\)\s*-\s*INTERVAL\s+\?\s+DAY/DATETIME(CURDATE(), '-' || ? || ' day')/ig;
        $sql =~ s/CURDATE\(\)\s*\+\s*INTERVAL\s+1\s+DAY/DATETIME(CURDATE(), '+1 day')/ig;
        $sql =~ s/TIMESTAMPDIFF\((MINUTE|HOUR),/TIMESTAMPDIFF('$1',/g;
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth && $kind) {
            $sth->{private_mb1053}=$state;$sth->{private_mb1053_kind}=$kind;
            $sth->{private_mb1053_fetched}=0;
        }
        return $sth;
    }
    package MB1053::DBI::st; our @ISA=('DBI::st');
    sub targeted {
        my ($sth)=@_;
        return ($sth->{private_mb1053_kind}//'') eq ($sth->{private_mb1053}{kind}//'history');
    }
    sub execute {
        my ($sth,@bind)=@_;
        push @{$sth->{private_mb1053}{binds}},[$sth->{private_mb1053_kind},@bind]
            if $sth->{private_mb1053_kind};
        return $sth->set_err(1902,'local execute failure')
            if $sth->targeted && ($sth->{private_mb1053}{fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth)=@_;
        if ($sth->targeted) {
            my $fault=$sth->{private_mb1053}{fault}//'';
            return $sth->set_err(1903,'local partial fetch failure')
                if $fault eq 'fetch_before' || ($fault eq 'fetch' && $sth->{private_mb1053_fetched}++);
            return undef if $fault eq 'missing_aggregate';
        }
        return $sth->SUPER::fetchrow_hashref;
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_mb1053_kind}) {
            push @{$sth->{private_mb1053}{finished}},$sth->{private_mb1053_kind};
        }
        die "local cleanup failure\n" if $sth->targeted && $sth->{private_mb1053}{finish_error};
        return $sth->SUPER::finish;
    }
    package MB1102::IRC;
    sub nick_folded {'bot'}
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
    $db->sqlite_create_function('IF',3,sub {$_[0]?$_[1]:$_[2]});
    $db->sqlite_create_function('TIMESTAMPDIFF',3,sub {
        my ($unit,$from,$to)=@_;return undef unless defined($from)&&defined($to);
        my @epoch=map {
            my @n=/\A(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)\z/;
            timegm($n[5],$n[4],$n[3],$n[2],$n[1]-1,$n[0]);
        } ($from,$to);
        return int(($epoch[1]-$epoch[0])/($unit eq 'HOUR'?3600:60));
    });
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE)');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{CREATE TABLE CHANNEL_LOG(id_channel INTEGER,ts TEXT,event_type TEXT,nick TEXT COLLATE NOCASE)});
    for my $row (@$rows) {
        my ($stamp,$count,$kind,$cid,$nick)=@$row;
        for (1..$count) {$db->do('INSERT INTO CHANNEL_LOG VALUES(?,?,?,?)',undef,$cid//1,$stamp,$kind//'public',$nick//'Reader')}
    }
    return (Mediabot->new({dbh=>$db}),$db);
}
sub invoke_1426 {
    my ($bot,$days,$entry)=@_;
    $entry //='Mediabot';@wire=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#test',command=>'radar',args=>defined($days)?[$days]:[]);
    no strict 'refs';
    my $ok=eval {$entry eq 'registry' ? $bot->command_registry->handler_for('radar','public')->($ctx) : &{$entry.'::mbRadar_ctx'}($ctx);1};
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

# Standard reports: real SQLite queries, fault injection at the DBI boundary.
sub standard_1426 {
    my ($empty)=@_;
    my @rows=(['2026-11-01 09:15:00',3,'public',1,'Alice'],
        ['2026-11-01 08:00:00',2,'action',1,'Bob'],
        ['2026-10-31 00:00:00',1,'public',1,'Ancien'],
        ['2026-11-01 09:59:00',20,'join',1,'Other'],
        ['2026-11-01 09:59:00',30,'public',2,'Other']);
    my ($b,$h)=fixture_1426('2026-11-01',$empty?[]:\@rows);
    $b->{irc}=bless {},'MB1102::IRC';
    $b->{_test_nicks}=$empty?[]:[qw(Alice Bob Ancien Never Bot)];
    $b->{_karma_log}{'#test'}=[map {{ts=>time()-60,delta=>$_<4?'+1':'-1'}} 0..4]
        unless $empty;
    return ($b,$h);
}
local *Mediabot::gethChannelsNicksOnChan=sub {@{$_[0]{_test_nicks}//[]}};
my $standard=[
    ['public','#test',"📡 \x02Radar\x02 on #test:"],
    ['public','#test','  🔥 rate: 3 msgs/last-hour (avg 0/h over 24h) - SPIKE x14.4'],
    ['public','#test','  😴 last public msg: 45m ago'],
    ['public','#test','  🆕 newcomers (24h): Bob, Alice'],
    ['public','#test','  👻 silent ghosts: Never (9999h), Ancien (34h)'],
    ['public','#test','  ⚡ karma vortex (1h): 5 votes (+4 / -1)'],
    ['public','#test',"  🎙️ loudest (1h): Alice:3"],
];
my @kinds=qw(rate silence newcomers ghosts talkers);
{
    my (@actual,@expected);
    for my $entry (qw(Mediabot::Stats::Radar Mediabot::UserCommands Mediabot registry)) {
        my ($b,$h)=standard_1426();
        push @actual,[invoke_1426($b,undef,$entry),dclone(\@wire),dclone($h->{private_mb1053})];
        push @expected,['',$standard,{prepared=>[ @kinds ],finished=>[ @kinds ],binds=>[
            map {[$_,'#test',($_ eq 'ghosts'?qw(Alice Bob Ancien Never):())]} @kinds]}];
        $h->disconnect;
    }
    for my $nicks ([],['Never','Bot']) {
        my ($b,$h)=standard_1426(1);$b->{_test_nicks}=$nicks;
        push @actual,[invoke_1426($b,undef),dclone(\@wire)];
        push @expected,['',[
            ['public','#test',"📡 \x02Radar\x02 on #test:"],
            ['public','#test',"  〰️ rate: 0 msgs/last-hour (avg 0/h over 24h) - calm"],
            (@$nicks?(['public','#test','  👻 silent ghosts: Never (9999h)']):()),
        ]];
        $h->disconnect;
    }
    is_deeply(\@actual,\@expected,'standard report preserves exact formatting, binds, channel/event scope, zero activity, unknown-history ghosts and all native entry points');
}
{
    my (@actual,@expected);
    for my $raise (0,1) {
        for my $kind (@kinds) {
            for my $fault (qw(prepare execute fetch_before fetch),($kind=~/^(rate|silence)$/?'missing_aggregate':())) {
                my ($b,$h)=standard_1426();$h->{RaiseError}=$raise;
                my $state=$h->{private_mb1053}={kind=>$kind,fault=>$fault};
                push @actual,[invoke_1426($b,undef,'registry'),dclone(\@wire),
                    $state->{prepared}[-1],scalar(grep {$_ eq $kind} @{$state->{finished}//[]})];
                push @expected,['',[['notice','Operator','Database error.']],$kind,$fault eq 'prepare'?0:1];
                $h->{private_mb1053}={};
                push @actual,[invoke_1426($b,undef,'registry'),dclone(\@wire)];
                push @expected,['',$standard];
                $h->disconnect;
            }
        }
    }
    is_deeply(\@actual,\@expected,'each failed or partial standard read emits one private error, publishes no report, cleans its statement and recovers on the next invocation');
}
{
    my (@actual,@expected);
    for my $raise (0,1) {
        for my $kind (@kinds) {
            for my $fault ('','fetch') {
                my ($b,$h)=standard_1426();$h->{RaiseError}=$raise;
                $h->{private_mb1053}={kind=>$kind,fault=>$fault,finish_error=>1};
                push @actual,[invoke_1426($b,undef),dclone(\@wire)];
                push @expected,['',$fault?[['notice','Operator','Database error.']]:$standard];
                $h->disconnect;
            }
        }
    }
    is_deeply(\@actual,\@expected,'cleanup exceptions preserve completely read standard reports and never replace the original fetch failure');
}
is_deeply(\@warnings,[],'native calendar and standard reports, empty data and database failures are warning-free');
done_testing;
