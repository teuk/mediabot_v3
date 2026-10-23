package MB932AchievementFixture;
use strict;
use warnings;
use DBI;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(getcwd);
use Mediabot::Achievements;

# Execute the production methods through native DBI. Only MySQL's DELETE JOIN,
# date functions and UPSERT spelling are adapted to SQLite. Triggers, the SQL
# authorizer and deferred foreign keys cause real prepare/execute/commit
# failures, with both DBI error modes. A begin refusal uses DBI's set_err API.
{
    package MB932::DBI;
    our @ISA = ('DBI');
    package MB932::DBI::db;
    our @ISA = ('DBI::db');
    sub begin_work {
        my $s=shift; $s->{private_mb932_begin}++;
        return $s->set_err(1,'begin rejected') if $s->{private_mb932_begin_fail};
        $s->SUPER::begin_work(@_);
    }
    sub commit { my $s=shift; $s->{private_mb932_commit}++; $s->SUPER::commit(@_) }
    sub rollback { my $s=shift; $s->{private_mb932_rollback}++; $s->SUPER::rollback(@_) }
    sub prepare {
        my ($s,$sql,@rest)=@_;
        if ($sql =~ /DELETE a[up]\s+FROM (ACHIEVEMENT_\w+) a[up].*?WHERE p.id_channel = \?\s+AND a[up]\.(.*)/s) {
            $sql = "DELETE FROM $1 WHERE id_achievement_profile IN "
                 . '(SELECT id_achievement_profile FROM ACHIEVEMENT_PROFILE WHERE id_channel = ?) AND ' . $2;
        }
        if ($sql =~ /ON DUPLICATE KEY UPDATE/) {
            $sql =~ s/ON DUPLICATE KEY UPDATE/ON CONFLICT DO UPDATE SET/;
            $sql =~ s/VALUES\((\w+)\)/excluded.$1/g;
            $sql =~ s/\bLEAST\(/MIN(/g;
            $sql =~ s/\bGREATEST\(/MAX(/g;
        }
        if (($s->{private_mb932_prepare_fail} // '') ne ''
            && $sql =~ /INSERT INTO \Q$s->{private_mb932_prepare_fail}\E\b/) {
            $sql = 'SELECT * FROM mb932_nonexistent_table';
        }
        return $s->SUPER::prepare($sql,@rest);
    }
    package MB932::DBI::st;
    our @ISA = ('DBI::st');
    package MB932::Logger;
    sub log { push @{$_[0]{rows}}, $_[2]; 1 }
}

my $json=JSON::PP->new->canonical->utf8;
my @tables=qw(CHANNEL ACHIEVEMENT_PROFILE ACHIEVEMENT_IDENTITY ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS COMMIT_GUARD OUTER_WORK);
sub check { die "$_[1]\n" unless $_[0] }
sub dump_db {
    my ($db)=@_;
    return $json->encode({map {$_=>$db->selectall_arrayref("SELECT * FROM $_ ORDER BY 1,2")} @tables});
}
sub dump_cache {
    my ($a)=@_;
    return $json->encode({map {$_=>$a->{$_}} qw(_profiles _identity_exact _nick_channel_profile _channel_ids _channel_names _unlocks_by_profile _progress_by_profile _pending_checks _pending_order _msg_check_ts _hourband_check_ts)});
}
sub committed_db {
    my ($dir)=@_;
    my $reader=DBI->connect("dbi:SQLite:dbname=$dir/ach.sqlite",'','',
        {RaiseError=>1,PrintError=>0,AutoCommit=>1});
    my $out=dump_db($reader);$reader->disconnect;return $out;
}
sub setup {
    my ($raise)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $db=DBI->connect("dbi:SQLite:dbname=$dir/ach.sqlite",'','',
        {RaiseError=>$raise,PrintError=>0,AutoCommit=>1,RootClass=>'MB932::DBI'});
    $db->sqlite_create_function('NOW',0,sub {1000});
    $db->sqlite_create_function('UNIX_TIMESTAMP',1,sub {$_[0]});
    $db->sqlite_create_function('FROM_UNIXTIME',1,sub {$_[0]});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE CHANNEL (id_channel INTEGER PRIMARY KEY, name TEXT)');
    $db->do('CREATE TABLE ACHIEVEMENT_PROFILE (id_achievement_profile INTEGER PRIMARY KEY AUTOINCREMENT, id_channel INTEGER, id_user INTEGER, display_nick TEXT, created_at INTEGER, last_seen_at INTEGER)');
    $db->do('CREATE TABLE ACHIEVEMENT_IDENTITY (id_achievement_identity INTEGER PRIMARY KEY AUTOINCREMENT, id_achievement_profile INTEGER, id_channel INTEGER, nick TEXT, userhost TEXT, first_seen_at INTEGER, last_seen_at INTEGER, UNIQUE(id_channel,nick,userhost))');
    $db->do('CREATE TABLE ACHIEVEMENT_UNLOCK (id_achievement_profile INTEGER, achievement_id TEXT, unlocked_at INTEGER, PRIMARY KEY(id_achievement_profile,achievement_id))');
    $db->do('CREATE TABLE ACHIEVEMENT_PROGRESS (id_achievement_profile INTEGER, progress_kind TEXT, progress_value INTEGER, updated_at INTEGER, PRIMARY KEY(id_achievement_profile,progress_kind))');
    $db->do('CREATE TABLE COMMIT_GUARD (id INTEGER REFERENCES ACHIEVEMENT_PROFILE(id_achievement_profile) DEFERRABLE INITIALLY DEFERRED, label TEXT)');
    $db->do('CREATE TABLE OUTER_WORK (id INTEGER, label TEXT)');
    $db->do("INSERT INTO CHANNEL VALUES (1,'#one'),(2,'#two')");
    $db->do("INSERT INTO ACHIEVEMENT_PROFILE VALUES (1,1,7,'Keep',100,100),(2,1,NULL,'Drop',200,200),(3,2,9,'Other',300,300)");
    $db->do(q{INSERT INTO ACHIEVEMENT_IDENTITY VALUES (1,1,1,'Keep','k@h',100,200),(2,2,1,'Drop','d@h',50,250),(3,3,2,'Other','o@h',100,200)});
    $db->do("INSERT INTO ACHIEVEMENT_UNLOCK VALUES (1,'first_msg',200),(2,'first_msg',100),(2,'night_owl',300),(3,'night_owl',400)");
    $db->do("INSERT INTO ACHIEVEMENT_PROGRESS VALUES (1,'msg_count',5,100),(2,'msg_count',9,200),(2,'night_messages',20,200),(3,'night_messages',30,300)");
    my $logger=bless {rows=>[]},'MB932::Logger';
    my $a=bless {storage=>'db',bot=>{dbh=>$db},logger=>$logger,path=>"$dir/legacy.json",
        _pending_checks=>{one=>{channel=>'#one'},two=>{channel=>'#two'}},
        _pending_order=>['one','two'],_msg_check_ts=>{"drop\0#one"=>99,"other\0#two"=>88},
        _hourband_check_ts=>{"drop\0#one"=>99}},'Mediabot::Achievements';
    $a->_load_db;
    return ($a,$db,$dir);
}
sub invoke {
    my ($a,$op)=@_;
    return $a->_merge_profiles(1,2) if $op eq 'merge';
    return $a->reset_channel_hourbands('#one',1) if $op eq 'reset';
    return $a->_import_legacy_json_if_present if $op eq 'import';
    die "unknown operation $op";
}
sub legacy {
    my ($a,$new)=@_;
    my $nick=$new ? 'New' : 'Drop';
    my $bytes=$json->encode({version=>2,profiles=>{"$nick\0#one"=>{first_msg=>50}},progress=>{msg_count=>{"$nick\0#one"=>25}}});
    open my $fh,'>:raw',$a->{path} or die $!;
    print {$fh} $bytes; close $fh or die $!;
    return $bytes;
}
sub failed {
    my ($a,$op)=@_;
    my ($r,$err,@warnings);
    { local $@; local $SIG{__WARN__}=sub {push @warnings,@_};
      $r=eval {invoke($a,$op)}; $err=$@ }
    # SQLite may report AutoCommit=true after a deferred commit failure even
    # though native rollback is still required. Verify the restored rows below.
    die join('',@warnings) if grep {!/^rollback ineffective with AutoCommit enabled/} @warnings;
    return $op eq 'merge' ? defined($r) && $r==2 : $op eq 'reset' ? !!$err : !$r;
}
sub trigger {
    my ($db,$table,$event,$when,$body)=@_;
    $db->do("CREATE TRIGGER fail_write BEFORE $event ON $table WHEN $when BEGIN $body; END");
}
sub run_checks {
    my @results;
    my $group=sub {
        my ($name,$body)=@_;
        my $ok=eval {$body->();1};
        push @results,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"};
    };
    $group->('merge preserves oldest unlocks, maximum progress, aliases and other channel',sub {
        for my $raise (0,1) {
            my ($a,$db,$dir)=setup($raise);
            check(invoke($a,'merge')==1,'merge success');
            check($db->selectrow_array("SELECT unlocked_at FROM ACHIEVEMENT_UNLOCK WHERE id_achievement_profile=1 AND achievement_id='first_msg'")==100,'oldest unlock');
            check($db->selectrow_array("SELECT progress_value FROM ACHIEVEMENT_PROGRESS WHERE id_achievement_profile=1 AND progress_kind='msg_count'")==9,'maximum progress');
            check($db->selectrow_array('SELECT COUNT(*) FROM ACHIEVEMENT_PROFILE WHERE id_achievement_profile=2')==0,'drop removed');
            check($db->selectrow_array("SELECT id_achievement_profile FROM ACHIEVEMENT_IDENTITY WHERE nick='Drop'")==1,'alias moved');
            check(exists($a->{_unlocks_by_profile}{3}{night_owl}) && exists($a->{_unlocks_by_profile}{1}{night_owl}),'cache reloaded');
            check($a->{_identity_exact}{"1\0drop\0d\@h"}==1,'exact alias cache retained');
            check(committed_db($dir) eq dump_db($db),'merge was not committed');
            check($db->{AutoCommit} && $db->{RaiseError}==$raise,'DBI attributes restored');
        }
    });
    $group->('every failed merge copy or deletion rolls back all tables and caches',sub {
        for my $raise (0,1) {
            for my $step ([qw(ACHIEVEMENT_UNLOCK INSERT)], [qw(ACHIEVEMENT_PROGRESS INSERT)], [qw(ACHIEVEMENT_IDENTITY INSERT)], map {[$_,'DELETE']} qw(ACHIEVEMENT_IDENTITY ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS ACHIEVEMENT_PROFILE)) {
                my ($a,$db)=setup($raise);
                my $before=dump_db($db); my $cache=dump_cache($a);
                if ($step->[0] eq 'ACHIEVEMENT_IDENTITY' && $step->[1] eq 'DELETE') {
                    # All aliases have already moved, so this valid DELETE is
                    # normally a successful 0E0. Deny the statement itself.
                    $db->sqlite_set_authorizer(sub {$_[0]==9 && $_[1] eq 'ACHIEVEMENT_IDENTITY' ? 1 : 0});
                }
                else {
                    trigger($db,@$step,($step->[1] eq 'INSERT'?'NEW':'OLD').'.id_achievement_profile='.($step->[1] eq 'INSERT'?1:2),"SELECT RAISE(ABORT,'write rejected')");
                }
                check(failed($a,'merge'),"merge reported success for @$step RaiseError=$raise");
                $db->sqlite_set_authorizer(undef);
                check(dump_db($db) eq $before,"partial merge for @$step RaiseError=$raise");
                check(dump_cache($a) eq $cache,'failed merge cache changed');
                check($db->{AutoCommit} && $db->{RaiseError}==$raise,'failure attributes restored');
            }
        }
    });
    $group->('native prepare failures preserve merge and import state',sub {
        for my $op ('merge','import') {
            for my $raise (0,1) {
                my ($a,$db)=setup($raise); legacy($a,0) if $op eq 'import';
                my $before=dump_db($db); my $cache=dump_cache($a);
                $db->{private_mb932_prepare_fail}='ACHIEVEMENT_PROGRESS';
                check(failed($a,$op),'prepare failure reported success');
                $db->{private_mb932_prepare_fail}='';
                check(dump_db($db) eq $before && dump_cache($a) eq $cache,'prepare failure changed state');
                check(-f $a->{path},'failed import archived live JSON') if $op eq 'import';
            }
        }
    });
    $group->('reset removes only hour-band merit and matching pending work',sub {
        my ($a,$db)=setup(0);
        my $r=invoke($a,'reset');
        check($r->{unlocks}==1 && $r->{progress}==1,'reset row counts');
        check(exists($a->{_unlocks_by_profile}{2}{first_msg}) && !exists($a->{_unlocks_by_profile}{2}{night_owl}) && exists($a->{_unlocks_by_profile}{3}{night_owl}),'reset scope');
        check($json->encode($a->{_pending_order}) eq '["two"]' && exists($a->{_msg_check_ts}{"other\0#two"}),'pending scope');
        $r=invoke($a,'reset'); check($r->{unlocks}==0 && $r->{progress}==0,'zero-row success');
    });
    $group->('reset second-write failure retains SQL merit and pending caches',sub {
        for my $raise (0,1) {
            my ($a,$db)=setup($raise);my $before=dump_db($db);my $cache=dump_cache($a);
            trigger($db,'ACHIEVEMENT_PROGRESS','DELETE','OLD.id_achievement_profile=2',"SELECT RAISE(ABORT,'reset rejected')");
            check(failed($a,'reset'),'failed reset did not throw');
            check(dump_db($db) eq $before && dump_cache($a) eq $cache,'failed reset changed merit/cache');
        }
    });
    $group->('import archives JSON only after committed merit, retaining oldest and maximum',sub {
        for my $new (0,1) {
            my ($a,$db)=setup(0);legacy($a,$new);
            check(invoke($a,'import')==1,'import success');
            my $nick=$new?'New':'Drop';
            my $pid=$db->selectrow_array('SELECT id_achievement_profile FROM ACHIEVEMENT_PROFILE WHERE display_nick=?',undef,$nick);
            check($db->selectrow_array("SELECT unlocked_at FROM ACHIEVEMENT_UNLOCK WHERE id_achievement_profile=? AND achievement_id='first_msg'",undef,$pid)==50,'import timestamp');
            check($a->{_progress_by_profile}{msg_count}{$pid}==25,'import progress cache');
            my @archives=glob($a->{path}.'.migrated-*');
            check(!-f $a->{path} && @archives==1,'archive after success');
        }
    });
    $group->('every failed legacy write retains live JSON and rolls back ghost profiles',sub {
        for my $raise (0,1) {
            for my $table (qw(ACHIEVEMENT_PROFILE ACHIEVEMENT_IDENTITY ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS)) {
                my ($a,$db)=setup($raise);my $bytes=legacy($a,1);
                my $before=dump_db($db);my $cache=dump_cache($a);
                trigger($db,$table,'INSERT','1',"SELECT RAISE(ABORT,'import rejected')");
                check(failed($a,'import'),"import reported success for $table RaiseError=$raise");
                check(dump_db($db) eq $before && dump_cache($a) eq $cache,'failed import changed state');
                open my $fh,'<:raw',$a->{path} or die 'live JSON disappeared';local $/;
                check(<$fh> eq $bytes,'live JSON changed');
                my @archives=glob($a->{path}.'.migrated-*');check(!@archives,'failed import archived');
            }
        }
    });
    $group->('native deferred commit failures roll back each operation before publication',sub {
        for my $op ('merge','reset','import') {
            for my $raise (0,1) {
                my ($a,$db,$dir)=setup($raise);legacy($a,1) if $op eq 'import';
                my $before=dump_db($db);my $cache=dump_cache($a);
                my ($table,$event)=$op eq 'merge'?('ACHIEVEMENT_PROFILE','DELETE'):$op eq 'reset'?('ACHIEVEMENT_PROGRESS','DELETE'):('ACHIEVEMENT_PROGRESS','INSERT');
                trigger($db,$table,$event,'1',"INSERT INTO COMMIT_GUARD VALUES (999,'reject commit')");
                check(failed($a,$op),"$op commit failure reported success RaiseError=$raise");
                check(($db->{private_mb932_rollback}//0)==1,'commit failure did not roll back owned transaction');
                check(dump_db($db) eq $before && dump_cache($a) eq $cache,'commit failure changed state');
                check(committed_db($dir) eq $before,'commit failure changed durable state');
                check($db->{RaiseError}==$raise,'commit failure changed DBI error mode');
                check(-f $a->{path},'commit failure archived JSON') if $op eq 'import';
            }
        }
    });
    $group->('caller-owned transactions are neither changed, committed nor rolled back',sub {
        for my $op ('merge','reset','import') {
            for my $raise (0,1) {
                my ($a,$db,$dir)=setup($raise);legacy($a,1) if $op eq 'import';
                $db->begin_work; $db->do("INSERT INTO OUTER_WORK VALUES (1,'caller pending')");
                my $before=dump_db($db);my $cache=dump_cache($a);
                my $committed=committed_db($dir);
                check(failed($a,$op),"$op entered caller transaction RaiseError=$raise");
                check(!$db->{AutoCommit} && !($db->{private_mb932_commit}//0) && !($db->{private_mb932_rollback}//0),'caller transaction ended');
                check(dump_db($db) eq $before && dump_cache($a) eq $cache,'caller pending state changed');
                check(committed_db($dir) eq $committed,'caller pending work became committed');
                check(-f $a->{path},'caller transaction archived JSON') if $op eq 'import';
                $db->rollback;
            }
        }
    });
    $group->('begin refusal performs no writes, rollback, cache publication or JSON archival',sub {
        for my $op ('merge','reset','import') {
            for my $raise (0,1) {
                my ($a,$db)=setup($raise);legacy($a,1) if $op eq 'import';
                my $before=dump_db($db);my $cache=dump_cache($a);
                $db->{private_mb932_begin_fail}=1;
                check(failed($a,$op),"$op ignored failed begin RaiseError=$raise");
                check($db->{AutoCommit} && !($db->{private_mb932_commit}//0) && !($db->{private_mb932_rollback}//0),'failed begin ended transaction');
                check(dump_db($db) eq $before && dump_cache($a) eq $cache,'failed begin changed state');
                check(-f $a->{path},'failed begin archived JSON') if $op eq 'import';
            }
        }
    });
    $group->('archive import leaves historical files untouched and merges repeated merit',sub {
        my ($a,$db,$dir)=setup(0);my $bytes=legacy($a,0);
        make_path("$dir/live/var","$dir/live.1/var");
        my $archive="$dir/live.1/var/achievements.json";
        rename($a->{path},$archive) or die $!;
        my $cwd=getcwd();chdir "$dir/live" or die $!;
        $a->{path}='var/achievements.json';
        my $ok=eval {
            check($a->_import_legacy_json_if_present(include_archives=>1)==1,'archive-only import');
            check($a->_import_legacy_json_if_present(include_archives=>1)==1,'archive replay');
            1;
        };
        my $error=$@;chdir $cwd or die $!;die $error unless $ok;
        open my $fh,'<:raw',$archive or die $!;local $/;check(<$fh> eq $bytes,'historical bytes changed');
        check($a->{_progress_by_profile}{msg_count}{2}==25,'archive merit duplicated or lost');
    });
    return \@results;
}

unless (caller) {
    print $json->encode(run_checks()),"\n";
}
1;
