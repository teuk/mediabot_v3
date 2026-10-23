package MB935TimerAddFixture;
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr weaken);
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Mediabot::Mediabot;
use Mediabot::Context;
{
    package MB935::DBI;
    our @ISA=('DBI');
    package MB935::DBI::db;
    our @ISA=('DBI::db');
    sub begin_work {
        my $db=shift;$db->{private_mb935_begin}++;
        return $db->set_err(1,'MB935 begin refused') if $db->{private_mb935_fault} eq 'begin';
        return $db->SUPER::begin_work(@_);
    }
    sub commit {
        my $db=shift;$db->{private_mb935_commit}++;
        $db->{private_mb935_commit_hook}->() if $db->{private_mb935_commit_hook};
        return $db->SUPER::commit(@_);
    }
    sub rollback {my $db=shift;$db->{private_mb935_rollback}++;$db->SUPER::rollback(@_)}
    sub prepare {
        my ($db,$sql,@rest)=@_;my $kind=$sql =~ /SELECT 1 FROM TIMERS/ ? 'read'
            : $sql =~ /INSERT INTO TIMERS/ ? 'insert' : '';
        $db->{private_mb935_sql}++ if length($kind);
        $sql='SELECT * FROM mb935_missing_table'
            if length($kind) && $db->{private_mb935_fault} eq "$kind.prepare";
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_mb935_kind}=$kind if $sth;
        return $sth;
    }
    package MB935::DBI::st;
    our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;my $kind=$sth->{private_mb935_kind}//'';
        return $sth->set_err(1,'MB935 execute refused')
            if length($kind) && $sth->{Database}{private_mb935_fault} eq "$kind.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_array {
        my $sth=shift;
        return $sth->set_err(1,'MB935 fetch refused')
            if ($sth->{private_mb935_kind}//'') eq 'read'
                && $sth->{Database}{private_mb935_fault} eq 'read.fetch';
        return $sth->SUPER::fetchrow_array(@_);
    }
    package MB935::Principal;
    sub is_authenticated {$_[0]{auth}}
    sub has_level {$_[0]{owner} && $_[1] eq 'Owner'}
    package MB935::Bot;
    our @ISA=('Mediabot');
    sub botNotice {push @{$_[0]{notices}},[@_[1..$#_]];1}
    package MB935::IRC;
    sub is_connected {$_[0]{connected}}
    sub write {push @{$_[0]{wire}},$_[1];1}
    package MB935::Logger;
    sub log {push @{$_[0]{lines}},[@_[1..$#_]];1}
}
my $json=JSON::PP->new->canonical->utf8;
my $new=IO::Async::Timer::Periodic->can('new');
my $add=IO::Async::Loop->can('add');
my $start=IO::Async::Timer::Periodic->can('start');
my $stop=IO::Async::Timer::Periodic->can('stop');
my $remove=IO::Async::Loop->can('remove');
sub check ($$) {die "$_[1]\n" unless $_[0]}
sub rows {$_[0]->selectall_arrayref('SELECT name,duration,command FROM TIMERS ORDER BY name')}
sub peer_rows {
    my ($dir)=@_;my $db=DBI->connect("dbi:SQLite:dbname=$dir/timers.sqlite",'','',
        {RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    my $out=rows($db);$db->disconnect;return $out;
}
sub setup {
    my (%a)=@_;my $dir=tempdir(CLEANUP=>1);my $loop=IO::Async::Loop->really_new;
    my $db=DBI->connect("dbi:SQLite:dbname=$dir/timers.sqlite",'','',
        {RootClass=>'MB935::DBI',RaiseError=>$a{raise}//0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->{private_mb935_fault}='';$db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE TIMERS(id_timers INTEGER PRIMARY KEY,name TEXT UNIQUE,duration INTEGER NOT NULL,command TEXT NOT NULL)');
    $db->do('CREATE TABLE PARENT(id INTEGER PRIMARY KEY)');
    $db->do('CREATE TABLE GUARD(id INTEGER REFERENCES PARENT(id) DEFERRABLE INITIALLY DEFERRED)');
    $db->do('CREATE TABLE OUTER_WORK(value TEXT)');
    $db->do(q{INSERT INTO TIMERS(name,duration,command) VALUES('existing',3600,'PING existing')});
    my $bot=bless {loop=>$loop,dbh=>$db,hTimers=>{},notices=>[],
        logger=>bless({lines=>[]},'MB935::Logger'),
        irc=>bless({connected=>1,wire=>[]},'MB935::IRC')},'MB935::Bot';
    my $old=$new->('IO::Async::Timer::Periodic',interval=>3600,on_tick=>sub {});
    $add->($loop,$old);$start->($old);$bot->{hTimers}{existing}=$old;
    return {bot=>$bot,db=>$db,dir=>$dir,loop=>$loop,old=>$old};
}
sub invoke {
    my ($s,%a)=@_;my $b=$s->{bot};my (@warnings,@callbacks,@weak,%fresh,@audit);
    my ($result,$error);my $stage=$a{stage}//'';my $cleanup_failed=0;
    my $ctx=Mediabot::Context->new(bot=>$b,nick=>'Operator',command=>'addtimer',
        args=>$a{args}//['fresh',5,'PRIVMSG','#test',':été nouveau']);
    $ctx->{_user_fetched}=1;
    $ctx->{user}=bless {auth=>!$a{unauthenticated},owner=>!$a{low_level}},'MB935::Principal';
    no warnings qw(redefine once);
    local $SIG{__WARN__}=sub {push @warnings,@_};
    local *Mediabot::DBCommands::logBot=sub {push @audit,[@_[3..$#_]];1};
    local *IO::Async::Timer::Periodic::new=sub {
        die "MB935 constructor refused\n" if $stage eq 'new';
        my ($class,%args)=@_;push @callbacks,$args{on_tick};
        # Only the probe's first deadline is immediate; interval stays real.
        my $t=$new->($class,%args,first_interval=>0);
        $fresh{refaddr($t)}=1;push @weak,$t;weaken($weak[-1]);return $t;
    };
    local *IO::Async::Loop::add=sub {
        my ($l,$t)=@_;return $add->(@_) unless $fresh{refaddr($t)};
        die "MB935 add refused before attach\n" if $stage eq 'add-before';
        my $r=$add->(@_);
        die "MB935 add refused after attach\n" if $stage eq 'add-after';return $r;
    };
    local *IO::Async::Timer::Periodic::start=sub {
        my $t=shift;return $start->($t,@_) unless $fresh{refaddr($t)};
        die "MB935 start refused before arm\n" if $stage eq 'start-before';
        my $r=$start->($t,@_);
        $callbacks[-1]->() if $a{early_callback};
        $a{during_start}->($s,$t) if $a{during_start};
        die "MB935 start refused after arm\n" if $stage eq 'start-after';return $r;
    };
    local *IO::Async::Timer::Periodic::stop=sub {
        my $r=$stop->(@_);
        die "MB935 cleanup stop refused after side effect\n"
            if ($a{cleanup}//'') eq 'stop' && !$cleanup_failed++;
        return $r;
    };
    local *IO::Async::Loop::remove=sub {
        my $r=$remove->(@_);
        die "MB935 cleanup remove refused after side effect\n"
            if ($a{cleanup}//'') eq 'remove' && !$cleanup_failed++;
        return $r;
    };
    eval {$result=($a{entry}//'module') eq 'module'
        ? Mediabot::DBCommands::mbAddTimer_ctx($ctx) : Mediabot::mbAddTimer_ctx($ctx);1}
        or $error=$@;
    return {result=>$result,error=>$error//'',warnings=>\@warnings,callbacks=>\@callbacks,weak=>\@weak,audit=>\@audit};
}
sub added {my ($s,$r)=@_;return !$r->{error} && $r->{result} && @{$r->{audit}}==1
    && @{$s->{bot}{notices}}==1 && $s->{bot}{notices}[0][1]=~/Timer fresh added/}
sub intact {
    my ($s)=@_;
    return $json->encode(rows($s->{db})) eq $json->encode([['existing',3600,'PING existing']])
        && keys(%{$s->{bot}{hTimers}})==1 && refaddr($s->{old})==refaddr($s->{bot}{hTimers}{existing})
        && $s->{old}->is_running && $s->{db}{AutoCommit} && !@{$s->{bot}{irc}{wire}};
}
sub dispose {
    my ($s)=@_;delete $s->{db}{private_mb935_commit_hook};
    for my $t (values %{$s->{bot}{hTimers}}) {eval {$stop->($t)};eval {$remove->($s->{loop},$t)}}
    $s->{bot}{hTimers}={};$s->{db}->disconnect;
}
sub run_checks {
    my @out;my $group=sub {my ($name,$cb)=@_;my $ok=eval {$cb->();1};
        push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    $group->('successful additions preserve Unicode, interval, confirmation and both facades',sub {
        for my $entry (qw(module imported)) {
            my $s=setup();my $r=invoke($s,entry=>$entry);
            check(added($s,$r),"success failed: $r->{error}");
            check($json->encode(peer_rows($s->{dir})) eq $json->encode([
                ['existing',3600,'PING existing'],['fresh',5,'PRIVMSG #test :été nouveau']]),'wrong persisted timer');
            check(($s->{db}{private_mb935_commit}//0)==1 && $s->{db}{AutoCommit},'addition not committed');
            $s->{loop}->loop_once(0.01);
            check(@{$s->{bot}{irc}{wire}}==1 && $s->{bot}{irc}{wire}[0] eq "PRIVMSG #test :été nouveau\r\n",'native timer delivery changed');
            check($s->{old}->is_running && !@{$r->{warnings}},'existing timer or warnings changed');dispose($s);
        }
    });
    $group->('native construction, loop attachment and start failures leave no persistent or live timer',sub {
        for my $stage (qw(new add-before add-after start-before start-after)) {
            for my $cleanup ('','stop','remove') {
                my $s=setup();my $r=invoke($s,stage=>$stage,cleanup=>$cleanup);
                check(!$r->{error} && !$r->{result},"uncaught/accepted $stage: $r->{error}");
                check(intact($s) && !@{$r->{audit}},"partial timer survived $stage/$cleanup");
                check(!grep(defined,@{$r->{weak}}),'failed timer retained');
                $_->() for @{$r->{callbacks}};
                $s->{loop}->loop_once(0.01);
                check(!@{$s->{bot}{irc}{wire}},'failed attempt delivered late');
                $s->{bot}{notices}=[];check(added($s,invoke($s)),'retry blocked by failed add');dispose($s);
            }
        }
    });
    $group->('SQL lookup, begin, insert and native commit failures are contained in both error modes',sub {
        for my $raise (0,1) {
            for my $fault (qw(read.prepare read.execute read.fetch begin insert.prepare insert.execute commit)) {
                my $s=setup(raise=>$raise);$s->{db}{private_mb935_fault}=$fault;
                $s->{db}->do(q{CREATE TRIGGER bad_commit AFTER INSERT ON TIMERS BEGIN INSERT INTO GUARD VALUES(99); END}) if $fault eq 'commit';
                my $r=invoke($s);
                check(!$r->{error} && !$r->{result},"SQL $fault/$raise escaped or succeeded: $r->{error}");
                my $notice=$fault =~ /^read[.]/ ? 'DB error while checking timer' : 'DB error while adding timer';
                check(@{$s->{bot}{notices}}==1 && $s->{bot}{notices}[0][1] eq $notice,
                    "SQL $fault/$raise has misleading diagnostic");
                check(intact($s) && !@{$r->{audit}},"SQL $fault/$raise left state");
                check(!grep(defined,@{$r->{weak}}),'SQL failure retained fresh timer');
                $s->{db}{private_mb935_fault}='';
                $s->{db}->do('DROP TRIGGER bad_commit') if $fault eq 'commit';
                $s->{bot}{notices}=[];check(added($s,invoke($s)),"SQL $fault/$raise retry failed");dispose($s);
            }
        }
    });
    $group->('an outer transaction is never committed or rolled back by addtimer',sub {
        my $s=setup();$s->{db}->begin_work;$s->{db}->do(q{INSERT INTO OUTER_WORK VALUES('caller')});
        my $r=invoke($s);
        check(!$r->{error} && !$r->{result} && !$s->{db}{AutoCommit},'outer transaction disturbed');
        check(!$s->{db}{private_mb935_commit} && !$s->{db}{private_mb935_rollback},'foreign transaction completed');
        check(!$s->{db}{private_mb935_sql} && $s->{db}{private_mb935_begin}==1,'foreign transaction reached add SQL');
        check(@{rows($s->{db})}==1 && $s->{db}->selectrow_array('SELECT COUNT(*) FROM OUTER_WORK')==1,'foreign work changed');
        $s->{db}->commit;check($s->{db}->selectrow_array('SELECT COUNT(*) FROM OUTER_WORK')==1,'foreign work lost');dispose($s);
    });
    $group->('a provisional or superseded callback cannot emit IRC output',sub {
        my $s=setup();my $hidden=0;
        $s->{db}{private_mb935_commit_hook}=sub {
            $hidden=1 if !exists($s->{bot}{hTimers}{fresh}) && @{peer_rows($s->{dir})}==1
                && !@{$s->{bot}{irc}{wire}};
        };
        my $r=invoke($s,early_callback=>1);
        check(added($s,$r) && $hidden,'timer published or emitted before commit');
        $_->() for @{$r->{callbacks}};
        check(@{$s->{bot}{irc}{wire}}==1,'committed callback failed');
        $s->{bot}{irc}{wire}=[];
        my $owned=delete $s->{bot}{hTimers}{fresh};$stop->($owned);$remove->($s->{loop},$owned);
        $s->{bot}{hTimers}{fresh}=$s->{old};
        $_->() for @{$r->{callbacks}};
        check(!@{$s->{bot}{irc}{wire}},'old callback sent for replacement');
        delete $s->{bot}{hTimers}{fresh};undef $owned;
        check(!grep(defined,@{$r->{weak}}),'retained callback kept removed timer alive');
        my $weak_bot=$s->{bot};weaken($weak_bot);dispose($s);delete $s->{bot};
        check(!defined($weak_bot),'retained callback kept bot alive');
    });
    $group->('access, validation and duplicate checks do not disturb existing timers',sub {
        for my $args ([],['bad name',5,'PING','x'],['fresh',4,'PING','x'],['fresh',86401,'PING','x'],
            ['fresh',5,'EXEC','x'],['fresh',5,'PRIVMSG','x'x256],['existing',5,'PING','x']) {
            my $s=setup();my $r=invoke($s,args=>$args);
            check(!$r->{error} && !$r->{result} && intact($s),'invalid/duplicate addition changed state');dispose($s);
        }
        for my $denied (qw(low_level unauthenticated)) {
            my $s=setup();my $r=invoke($s,$denied=>1);
            check(!$r->{error} && !$r->{result} && intact($s) && !$s->{db}{private_mb935_sql},'denied caller touched SQL');dispose($s);
        }
        my $s=setup();$s->{bot}{hTimers}{fresh}=$s->{old};my $r=invoke($s);
        check(!$r->{error} && !$r->{result} && !$s->{db}{private_mb935_sql},'runtime duplicate touched SQL');
        delete $s->{bot}{hTimers}{fresh};dispose($s);
        $s=setup();$s->{db}->do(q{INSERT INTO TIMERS(name,duration,command) VALUES('fresh',60,'PING db-only')});
        $r=invoke($s);check(!$r->{error} && !$r->{result} && !$s->{db}{private_mb935_begin},'DB duplicate began mutation');dispose($s);
    });
    $group->('the native timer still refuses disconnected and multiline IRC output',sub {
        for my $text ("bad\rINJECT","bad\nINJECT","bad\0INJECT",'disconnected') {
            my $s=setup();$s->{bot}{irc}{connected}=0 if $text eq 'disconnected';
            my $r=invoke($s,args=>['fresh',5,'PRIVMSG','#test',":$text"]);
            check(added($s,$r),'guarded timer was not added');
            $s->{loop}->loop_once(0.01);
            check(!@{$s->{bot}{irc}{wire}},'unsafe or disconnected output sent');dispose($s);
        }
    });
    $group->('removal retains database-first behavior and cleans an already absent row',sub {
        for my $missing (0,1) {
            my $s=setup();$s->{db}->do(q{DELETE FROM TIMERS WHERE name='existing'}) if $missing;
            my $ctx=Mediabot::Context->new(bot=>$s->{bot},nick=>'Operator',args=>['existing']);
            $ctx->{_user_fetched}=1;$ctx->{user}=bless {auth=>1,owner=>1},'MB935::Principal';
            no warnings 'redefine';local *Mediabot::DBCommands::logBot=sub {1};
            my $result=Mediabot::DBCommands::mbRemTimer_ctx($ctx);
            check($result && !keys(%{$s->{bot}{hTimers}}) && !$s->{old}->is_running,'remtimer left runtime state');
            check(!@{rows($s->{db})},'remtimer left DB row');dispose($s);
        }
    });
    return \@out;
}
unless (caller) {print $json->encode(run_checks()),"\n"}
1;
