package MB937QuoteDeleteFixture;
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::Plugin::QuoteWriteServiceV3;
use Mediabot::Plugin::PrincipalV3;
{
    package MB937::DBI;
    our @ISA=('DBI');
    package MB937::DBI::db;
    our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $kind=$sql=~/\A\s*DELETE FROM QUOTES/ ? 'delete'
            :$sql=~/SELECT (?:QUOTES\.id_quotes|q\.id_quotes)/ ? 'read' : '';
        my $p=$db->{private_mb937};
        push @{$p->{sql}},$sql if $p && $kind;
        $sql='SELECT * FROM mb937_missing_table' if $p && $kind && ($p->{fault}//'') eq "$kind.prepare";
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_mb937_kind}=$kind if $sth;
        return $sth;
    }
    package MB937::DBI::st;
    our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;my $db=$sth->{Database};my $p=$db->{private_mb937};
        my $kind=$sth->{private_mb937_kind}//'';
        push @{$p->{binds}},[$kind,@bind] if $p && $kind;
        return $sth->set_err(1,'mb937 execute refusal') if $p && $kind && ($p->{fault}//'') eq "$kind.execute";
        if ($p && $kind eq 'delete' && $p->{before_delete}) {
            my $cb=delete $p->{before_delete};$cb->($db);
        }
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my $sth=shift;my $p=$sth->{Database}{private_mb937};
        return $sth->set_err(1,'mb937 fetch refusal')
            if $p && ($sth->{private_mb937_kind}//'') eq 'read' && ($p->{fault}//'') eq 'read.fetch' && !($p->{fetch_fault_used}++);
        return $sth->SUPER::fetchrow_hashref(@_);
    }
    sub rows {
        my $sth=shift;my $p=$sth->{Database}{private_mb937};
        return -1 if $p && ($sth->{private_mb937_kind}//'') eq 'delete' && ($p->{fault}//'') eq 'delete.rows';
        my $rows=$sth->SUPER::rows(@_);
        # Some callers/drivers preserve a true-zero representation. Keep the
        # native zero-row operation and vary only its returned scalar form.
        return '0E0' if $p && ($p->{fault}//'') eq 'delete.truezero' && $rows==0;
        return $rows;
    }
    sub finish {
        my $sth=shift;my $p=$sth->{Database}{private_mb937};
        ++$p->{finished} if $p && ($sth->{private_mb937_kind}//'');
        return $sth->SUPER::finish(@_);
    }
    package MB937::User;
    sub id {$_[0]{uid}}
    sub nickname {'Archivist'}
    sub level {$_[0]{admin}?2:3}
    sub level_description {$_[0]{admin}?'Administrator':'User'}
    sub is_authenticated {$_[0]{authenticated}//1}
    sub has_level {$_[1] eq 'User' || $_[0]{admin} ? 1:0}
    package MB937::Conf;
    sub get_int {$_[0]{threshold}//100}
    package MB937::Logger;
    sub log {push @{$_[0]{lines}},[@_[1..$#_]];1}
}
sub check ($$) {die "$_[1]\n" unless $_[0]}
my $json=JSON::PP->new->canonical->utf8;
sub setup {
    my (%a)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB937::DBI',RaiseError=>$a{raise}//0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,id_channel INTEGER,id_user INTEGER,quotetext TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(4,'#test'),(8,'#other')});
    $db->do('INSERT INTO QUOTES VALUES(77,4,?,?)',undef,exists($a{author})?$a{author}:5,'Un été à Poudlard 🦉');
    $db->do(q{INSERT INTO QUOTES VALUES(88,8,5,'Other channel'),(99,4,6,'Other author')});
    my $p={sql=>[],binds=>[],finished=>0,fault=>$a{fault}//''};
    $db->{private_mb937}=$p;
    my $b=bless {dbh=>$db,conf=>bless({threshold=>$a{threshold}//100},'MB937::Conf'),
        logger=>bless({lines=>[]},'MB937::Logger'),sent=>[],audits=>[],op=>$a{op}//0},'Mediabot';
    return ($b,$db,$p);
}
sub snapshot {return $json->encode($_[0]->selectall_arrayref('SELECT * FROM QUOTES ORDER BY id_quotes'))}
sub invoke {
    my ($b,%a)=@_;my ($ret,$error,@warnings);
    my $entry=$a{entry}//'legacy';my $uid=exists($a{uid})?$a{uid}:5;
    my $user=bless {uid=>$uid,admin=>$a{admin}//0,authenticated=>defined($uid)?1:0},'MB937::User';
    no warnings qw(redefine once);
    local *Mediabot::Quotes::botNotice=sub {push @{$_[0]{sent}},['NOTICE',$_[1],$_[2]];1};
    local *Mediabot::Quotes::botPrivmsg=sub {push @{$_[0]{sent}},['PRIVMSG',$_[1],$_[2]];1};
    local *Mediabot::Quotes::noticeConsoleChan=sub {1};
    local *Mediabot::Quotes::logBot=sub {push @{$_[0]{audits}},[@_[1..$#_]];1};
    local *Mediabot::Quotes::checkUserChannelLevel=sub {$_[0]{op}>=$_[4] ? 1:0};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    eval {
        if ($entry eq 'v3') {
            my $principal=defined($uid)?Mediabot::Plugin::PrincipalV3->new(authenticated=>1,
                user_id=>$uid,account=>'Archivist',global_level=>$a{admin}?'administrator':'user',channel_level=>$b->{op})
                :Mediabot::Plugin::PrincipalV3->anonymous;
            $ret=Mediabot::Plugin::QuoteWriteServiceV3->new(dbh=>$b->{dbh})->delete(
                channel=>$a{channel}//'#test',principal=>$principal,id=>$a{id}//77,delete_level=>$b->{conf}->get_int);
        } elsif ($entry eq 'context') {
            $b->{_mb937_user}=$user;
            local *Mediabot::get_user_from_message=sub {$_[0]{_mb937_user}};
            $ret=Mediabot::Quotes::mbQuotes_ctx(Mediabot::Context->new(bot=>$b,
                nick=>'Archivist',channel=>$a{channel}//'#test',message=>'command',args=>['del',$a{id}//77]));
        } else {
            my $cb=$entry eq 'facade'?\&Mediabot::mbQuoteDel:\&Mediabot::Quotes::mbQuoteDel;
            $ret=$cb->($b,'command',$uid,$user,'Archivist','Archivist',$a{channel}//'#test',$a{id}//77);
        }
        1;
    } or $error=$@;
    return {ret=>$ret,error=>$error//'',warnings=>\@warnings,sent=>$b->{sent},audits=>$b->{audits}};
}
sub deleted {my($r,$entry)=@_;return !$r->{error} && ($entry eq 'v3'
    ? ($r->{ret}{status}//'') eq 'deleted'
    : $r->{ret} && @{$r->{sent}}==1 && $r->{sent}[0][2] eq "(Archivist) deleted. (id: \x0277\x0f)" && @{$r->{audits}}==1)}
sub missing {my($r,$entry,$id)=@_;$id//=77;return !$r->{error} && ($entry eq 'v3'
    ? ($r->{ret}{status}//'') eq 'not_found'
    : !$r->{ret} && @{$r->{sent}}==1 && $r->{sent}[0][2] eq "Quote (id : $id) does not exist for channel #test" && !@{$r->{audits}})}
sub run_checks {
    my @out;my $group=sub {my($name,$cb)=@_;my$ok=eval{$cb->();1};push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('native deletion, compatibility facade, Context and v3 keep exact success and scope',sub {
        for my $entry (qw(legacy facade context v3)) {
            my($b,$db,$p)=setup();my$r=invoke($b,entry=>$entry);
            check(deleted($r,$entry),"successful deletion changed: $entry ". $json->encode($r));
            check(snapshot($db) eq $json->encode([[88,8,5,'Other channel'],[99,4,6,'Other author']]),'unrelated rows changed');
            check(!@{$r->{warnings}} && $p->{finished}==2,'statement cleanup or warning');
        }
    });
    $group->('author, administrator and configured channel-level policy remain enforced',sub {
        for my $entry (qw(legacy v3)) {
            for my $spec ([5,5,0,0,100,1],[6,5,0,0,100,0],[6,5,1,0,100,1],
                [6,5,0,100,100,1],[6,5,0,99,100,0],[6,5,0,150,200,0],
                [undef,5,0,400,100,0],[6,undef,0,0,100,0],[6,undef,1,0,100,1],[6,undef,0,400,400,1]) {
                my($uid,$author,$admin,$op,$threshold,$allow)=@$spec;
                my($b,$db,$p)=setup(author=>$author,op=>$op,threshold=>$threshold);my$before=snapshot($db);
                my$r=invoke($b,entry=>$entry,uid=>$uid,admin=>$admin);
                check(!$r->{error},"permission exception: $entry");
                check($allow?deleted($r,$entry):!deleted($r,$entry) && snapshot($db) eq $before,'permission or threshold regression');
                check($allow || @{$p->{sql}}==($entry eq 'v3' && !defined($uid)?0:1),'refused caller reached DELETE');
            }
            my($b,$db,$p)=setup();my$before=snapshot($db);my$r=invoke($b,entry=>$entry,id=>88);
            check(missing($r,$entry,88) && snapshot($db) eq $before,'cross-channel id accepted');
            for my $invalid ('bad','-1','1 OR 1=1') {
                ($b,$db,$p)=setup();$before=snapshot($db);$r=invoke($b,entry=>$entry,id=>$invalid);
                check(!deleted($r,$entry) && !@{$p->{sql}} && snapshot($db) eq $before,'invalid ID reached SQL');
            }
        }
    });
    $group->('concurrent deletion and real zero-row DELETE never produce a success or audit',sub {
        for my $entry (qw(legacy facade context v3)) {
            for my $mode (qw(deleted ignored truezero)) {
                my($b,$db,$p)=setup();
                if ($mode eq 'deleted') {$p->{before_delete}=sub {$_[0]->do('DELETE FROM QUOTES WHERE id_quotes=77')}}
                else {$db->do('CREATE TRIGGER ignore_delete BEFORE DELETE ON QUOTES WHEN OLD.id_quotes=77 BEGIN SELECT RAISE(IGNORE); END')}
                $p->{fault}='delete.truezero' if $mode eq 'truezero';
                my$r=invoke($b,entry=>$entry);
                check(missing($r,$entry),"false deletion acknowledgment: $entry $mode ".$json->encode($r));
                check($db->selectrow_array('SELECT count(*) FROM QUOTES WHERE id_quotes=77')==($mode eq 'deleted'?0:1),'zero-row state changed');
                check(!@{$r->{warnings}},'zero-row warning');
            }
        }
    });
    $group->('a quote moved to another channel between lookup and DELETE is preserved',sub {
        for my $entry (qw(legacy v3)) {
            my($b,$db,$p)=setup();$p->{before_delete}=sub {$_[0]->do('UPDATE QUOTES SET id_channel=8 WHERE id_quotes=77')};
            my$r=invoke($b,entry=>$entry);
            check(missing($r,$entry),'moved quote reported deleted');
            check($db->selectrow_array('SELECT id_channel FROM QUOTES WHERE id_quotes=77')==8,'moved quote was deleted');
        }
    });
    $group->('prepare, execute and fetch errors with RaiseError off or on are never success or absence',sub {
        for my $entry (qw(legacy v3)) {
            for my $raise (0,1) {
                for my $fault (qw(read.prepare read.execute read.fetch delete.prepare delete.execute)) {
                    my($b,$db,$p)=setup(raise=>$raise,fault=>$fault);my$before=snapshot($db);my$r=invoke($b,entry=>$entry);
                    check(!deleted($r,$entry) && !missing($r,$entry),"SQL failure mislabeled: $entry $raise $fault");
                    check(snapshot($db) eq $before,'SQL failure changed rows');
                    if ($entry eq 'legacy') {
                        check(!$r->{error} && @{$r->{sent}}==1 && $r->{sent}[0][2]=~/Database error/ && !@{$r->{audits}},'legacy error escaped or lost notice');
                    } else {check($r->{error}=~/data service unavailable/,'v3 bounded error lost')}
                    check(!@{$r->{warnings}},'SQL fault emitted warning');
                }
            }
        }
    });
    $group->('unknown affected-row counts fail closed and absent quotes remain ordinary not_found',sub {
        for my $entry (qw(legacy v3)) {
            my($b,$db,$p)=setup(fault=>'delete.rows');
            my$r=invoke($b,entry=>$entry);
            check(!deleted($r,$entry) && !missing($r,$entry),'unknown DELETE row count reported as success or absence');
            ($b,$db,$p)=setup();$db->do('DELETE FROM QUOTES WHERE id_quotes=77');$r=invoke($b,entry=>$entry);
            check(missing($r,$entry) && @{$p->{sql}}==1,'initial absence reached DELETE');
        }
    });
    $group->('v3 lookup errors cannot bypass duplicate detection and create a second quote',sub {
        for my $raise (0,1) {
            my($b,$db,$p)=setup(raise=>$raise,fault=>'read.fetch');my$before=snapshot($db);
            my$principal=Mediabot::Plugin::PrincipalV3->new(authenticated=>1,user_id=>5,account=>'Archivist',global_level=>'user');
            my$error;eval{Mediabot::Plugin::QuoteWriteServiceV3->new(dbh=>$db)->add(channel=>'#test',principal=>$principal,text=>'Un été à Poudlard 🦉');1} or $error=$@;
            check(($error//'')=~/data service unavailable/ && snapshot($db) eq $before,'failed duplicate lookup treated as missing');
        }
    });
    return \@out;
}
print $json->encode(run_checks()) unless caller;
1;
