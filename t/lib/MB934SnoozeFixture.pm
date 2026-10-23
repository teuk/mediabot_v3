package MB934SnoozeFixture;
use strict;
use warnings;
use utf8;
BEGIN { $MB934::Clock::now=1000; *CORE::GLOBAL::time=sub () {$MB934::Clock::now} }
use DBI;
use JSON::PP;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
{
    package MB934::DBI;
    our @ISA=('DBI');
    package MB934::DBI::db;
    our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;my $kind='';my $index=0;
        if ($sql =~ /SELECT message FROM REMINDERS/) {$kind='read';$index=++$db->{private_mb934_reads}}
        if ($sql =~ /UPDATE REMINDERS SET message = \?/) {$kind='update';$db->{private_mb934_updates}++}
        my $fault=$db->{private_mb934_fault}//'';
        $sql='SELECT * FROM mb934_missing_table' if $fault eq "$kind.prepare.$index" && length($kind);
        my $sth=$db->SUPER::prepare($sql,@rest);
        if ($sth) {$sth->{private_mb934_kind}=$kind;$sth->{private_mb934_index}=$index}
        return $sth;
    }
    package MB934::DBI::st;
    our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;my $db=$sth->{Database};my $kind=$sth->{private_mb934_kind}//'';
        my $index=$sth->{private_mb934_index}//0;
        return $sth->set_err(1,'mb934 execute refusal')
            if length($kind) && ($db->{private_mb934_fault}//'') eq "$kind.execute.$index";
        if ($kind eq 'update' && $db->{private_mb934_before_update}) {
            my $hook=delete $db->{private_mb934_before_update};$hook->($db,@bind);
        }
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my $sth=shift;my $db=$sth->{Database};my $kind=$sth->{private_mb934_kind}//'';
        my $index=$sth->{private_mb934_index}//0;
        return $sth->set_err(1,'mb934 fetch refusal')
            if length($kind) && ($db->{private_mb934_fault}//'') eq "$kind.fetch.$index";
        return $sth->SUPER::fetchrow_hashref(@_);
    }
    package MB934::Channel;
    sub get_id {$_[0]{id}}
    package MB934::Logger;
    sub log {1}
}
my $json=JSON::PP->new->canonical->utf8;
# Force scalar argument context: a failed regex in list context otherwise
# disappears and can shift the diagnostic string into the condition slot.
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub setup {
    my (%args)=@_;$MB934::Clock::now=1000;
    my $dir=tempdir(CLEANUP=>1);
    my $db=DBI->connect("dbi:SQLite:dbname=$dir/reminders.sqlite",'','',
        {RaiseError=>$args{raise}//0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1,RootClass=>'MB934::DBI'});
    $db->do('CREATE TABLE REMINDERS (id_reminder INTEGER PRIMARY KEY AUTOINCREMENT,id_channel INTEGER,from_nick TEXT,to_nick TEXT,message TEXT,created_at TEXT DEFAULT "1970-01-01 00:00:00",delivered INTEGER DEFAULT 0)');
    $db->do('INSERT INTO REMINDERS(id_reminder,id_channel,from_nick,to_nick,message) VALUES(1,7,?,?,?)',undef,'operator','friend',$args{message}//'Un café à préparer');
    $db->do(q{INSERT INTO REMINDERS(id_reminder,id_channel,from_nick,to_nick,message) VALUES(2,7,'other','not-friend','Other owner'),(3,8,'operator','elsewhere','Other channel')});
    my $bot=bless {dbh=>$db,logger=>bless({},'MB934::Logger'),
        channels=>{'#test'=>bless({id=>7},'MB934::Channel')}},'Mediabot';
    return ($bot,$db,$dir);
}
sub snapshot {my ($db)=@_;return $json->encode($db->selectall_arrayref('SELECT * FROM REMINDERS ORDER BY id_reminder',{Slice=>{}}))}
sub invoke {
    my ($bot,%args)=@_;my (@wire,@warnings,$result,$error);
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$args{nick}//'Operator',
        channel=>$args{private}?undef:'#test',args=>$args{args}//['1','1h']);
    no warnings qw(redefine once);
    local *Mediabot::UserCommands::botNotice=sub {push @wire,[@_[1..$#_]];1};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $entry=$args{entry}//'module';
    eval {$result=$entry eq 'module'?Mediabot::CommunityState::mbRemindSnooze_ctx($ctx)
            :$entry eq 'imported'?Mediabot::UserCommands::mbRemindSnooze_ctx($ctx)
            :Mediabot::mbRemindSnooze_ctx($ctx);1} or $error=$@;
    return {result=>$result,error=>$error//'',wire=>\@wire,warnings=>\@warnings};
}
sub snoozed {my ($r)=@_;return !$r->{error} && $r->{result} && @{$r->{wire}}==1 && $r->{wire}[0][1]=~/snoozed for/}
sub no_op_trigger {$_[0]->do(q{CREATE TRIGGER ignore_unchanged BEFORE UPDATE OF message ON REMINDERS WHEN NEW.message=OLD.message BEGIN SELECT RAISE(IGNORE); END})}
sub run_checks {
    my @out;my $group=sub {my ($name,$cb)=@_;my $ok=eval {$cb->();1};push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('documented delays, optional plus and unit order retain exact future timestamps',sub {
        for my $entry (qw(module imported main)) {
            for my $pair (['1h',3600],['30m',1800],['2h30m',9000],['1d',86400],['1s',1],['+1h',3600],['30m1h',5400],['0d0h1s',1]) {
                my ($b,$db)=setup();my $r=invoke($b,entry=>$entry,args=>['1',$pair->[0]],private=>1);
                check(snoozed($r),"valid delay refused: $entry $pair->[0]");
                my $msg=$db->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1');
                check($msg eq '[at:'.(1000+$pair->[1]).'] Un café à préparer','wrong due date or Unicode text');
                check(!@{$r->{warnings}},'valid delay warning');
            }
        }
    });
    $group->('negative, fractional, partial, duplicate, zero and unrepresentable delays never write',sub {
        for my $delay ('-1h','1.5h','prefix1h','1h-tail','1h30h','1m2m','1h2','1h+2m','1e3s','0s','0d0h','1H','9'x400 . 'd') {
            my ($b,$db)=setup();my $before=snapshot($db);my $r=invoke($b,args=>['1',$delay]);
            check(!$r->{error} && !$r->{result} && @{$r->{wire}}==1 && $r->{wire}[0][1]=~/Invalid delay/,"bad delay accepted: $delay");
            check(snapshot($db) eq $before && !($db->{private_mb934_reads}//0) && !($db->{private_mb934_updates}//0),'invalid delay reached persistence');
            check(!@{$r->{warnings}},'invalid delay warning');
        }
    });
    $group->('delivery, cancellation, deletion or ownership changes cannot yield a false snooze',sub {
        for my $raise (0,1) {
            for my $action ('delivered','cancelled','deleted','owner') {
                my ($b,$db)=setup(raise=>$raise);
                $db->{private_mb934_before_update}=sub {
                    my ($db)=@_;
                    $db->do($action eq 'deleted'?'DELETE FROM REMINDERS WHERE id_reminder=1'
                        :$action eq 'owner'?q{UPDATE REMINDERS SET from_nick='other' WHERE id_reminder=1}
                        :'UPDATE REMINDERS SET delivered='.($action eq 'cancelled'?2:1).' WHERE id_reminder=1');
                };
                my $r=invoke($b);
                check(!$r->{error} && !$r->{result} && @{$r->{wire}}==1 && $r->{wire}[0][1]!~/snoozed/,"false success after $action");
                my $row=$db->selectrow_hashref('SELECT * FROM REMINDERS WHERE id_reminder=1');
                check(!$row || $row->{message} eq 'Un café à préparer','snooze overwrote claimed reminder');
            }
        }
    });
    $group->('a successful zero-row no-op remains an idempotent snooze after a fresh read',sub {
        for my $raise (0,1) {
            my ($b,$db)=setup(raise=>$raise,message=>'[at:4600] Un café à préparer');no_op_trigger($db);
            my $before=snapshot($db);my $r=invoke($b);
            check(snoozed($r) && snapshot($db) eq $before,'idempotent zero-row snooze refused');
        }
    });
    $group->('prepare, execute, fetch and update failures report errors without success or mutation',sub {
        for my $raise (0,1) {
            for my $fault ('read.prepare.1','read.execute.1','read.fetch.1','update.prepare.0','update.trigger') {
                my ($b,$db)=setup(raise=>$raise);my $before=snapshot($db);
                $db->{private_mb934_fault}=$fault;
                $db->do(q{CREATE TRIGGER reject_update BEFORE UPDATE ON REMINDERS BEGIN SELECT RAISE(ABORT,'mb934 update rejected'); END}) if $fault eq 'update.trigger';
                my $r=invoke($b);
                check(!$r->{error} && !$r->{result} && @{$r->{wire}}==1 && $r->{wire}[0][1]=~/DB error/,"SQL failure mishandled: $fault RaiseError=$raise");
                check(snapshot($db) eq $before,'SQL error changed reminder');
            }
        }
    });
    $group->('failed zero-row confirmation never turns uncertainty into success',sub {
        for my $raise (0,1) {
            for my $fault (qw(read.prepare.2 read.execute.2 read.fetch.2)) {
                my ($b,$db)=setup(raise=>$raise,message=>'[at:4600] Un café à préparer');no_op_trigger($db);
                $db->{private_mb934_fault}=$fault;my $r=invoke($b);
                check(!$r->{error} && !$r->{result} && @{$r->{wire}}==1 && $r->{wire}[0][1]=~/DB error/,'unverified no-op acknowledged');
            }
        }
    });
    $group->('arguments and reminder ownership remain guarded across module facades',sub {
        for my $entry (qw(module imported main)) {
            for my $args ([],['1'],['no-id','1h'],['1','1h','unexpected'],[{},'1h'],['1',{}]) {
                my ($b,$db)=setup();my $before=snapshot($db);my $r=invoke($b,entry=>$entry,args=>$args);
                check(!$r->{error} && !$r->{result} && snapshot($db) eq $before && $r->{wire}[0][1]=~/Syntax:/,'malformed arguments changed state');
            }
            for my $id (2,999) {
                my ($b,$db)=setup();my $before=snapshot($db);my $r=invoke($b,entry=>$entry,args=>["$id",'1h']);
                check(!$r->{error} && !$r->{result} && snapshot($db) eq $before && $r->{wire}[0][1]=~/not found/,'foreign/missing reminder changed');
            }
        }
    });
    $group->('recurrence tags survive snooze and actual delivery waits until the due epoch',sub {
        for my $prefix ('','[daily:09:00] ','[weekly:1:09:00] ') {
            my ($b,$db)=setup(message=>$prefix.'[at:2000] [!] Un café à préparer');
            my $r=invoke($b,args=>['1','30m']);check(snoozed($r),'recurring snooze refused');
            my $msg=$db->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1');
            check($msg eq '[at:2800] '.$prefix.'[!] Un café à préparer','recurrence/body changed');
            my @wire;no warnings qw(redefine once);
            local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,[@_[1..$#_]];1};
            Mediabot::CommunityState::deliverReminders($b,'Friend','#test');check(!@wire,'early delivery after snooze');
            $MB934::Clock::now=2800;Mediabot::CommunityState::deliverReminders($b,'Friend','#test');
            check(@wire==1 && $wire[0][1]=~/Un café à préparer/ && $wire[0][1]!~/\[at:/,'due reminder not delivered cleanly');
        }
    });
    return \@out;
}
unless (caller) {print $json->encode(run_checks()),"\n"}
1;
