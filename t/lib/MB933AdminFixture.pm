package MB933AdminFixture;
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;

# Native temporary databases, not production connections. Only INSERT IGNORE
# and NOW() are adapted for SQLite. Triggers and deferred constraints
# cause real SQL failures. begin and last_insert_id refusals use DBI fault hooks.
{
    package MB933::DBI;
    our @ISA=('DBI');
    package MB933::DBI::db;
    our @ISA=('DBI::db');
    sub begin_work {
        my $s=shift;$s->{private_mb933_begin}++;
        return $s->set_err(1,'mb933 begin rejected') if $s->{private_mb933_begin_fail};
        $s->SUPER::begin_work(@_);
    }
    sub commit {my $s=shift;$s->{private_mb933_commit}++;$s->SUPER::commit(@_)}
    sub rollback {my $s=shift;$s->{private_mb933_rollback}++;$s->SUPER::rollback(@_)}
    sub last_insert_id {
        my $s=shift;$s->{private_mb933_id_reads}++;
        return undef if $s->{private_mb933_id_fail};
        $s->SUPER::last_insert_id(@_);
    }
    sub prepare {
        my ($s,$sql,@rest)=@_;
        $sql =~ s/INSERT IGNORE INTO/INSERT OR IGNORE INTO/;
        my $fault=$s->{private_mb933_prepare_fail}//'';
        $sql='SELECT * FROM mb933_missing_table' if length($fault) && $sql =~ /INSERT (?:OR IGNORE )?INTO \Q$fault\E\b/;
        $s->SUPER::prepare($sql,@rest);
    }
    package MB933::DBI::st;
    our @ISA=('DBI::st');
    package MB933::Logger;
    sub log {push @{$_[0]{rows}},[$_[1],$_[2]];1}
    package MB933::Channel;
    sub get_id {$_[0]{id}}
    sub get_description {''}
    package MB933::Timer;
    sub stop {$_[0]{stopped}++;1}
    package MB933::IRC;
    sub nick_folded {'mediabot'}
    sub send_message {push @{$_[0]{sent}},[@_[1..$#_]];1}
    package MB933::Message;
    sub prefix {'Operator!operator@example.test'}
}
my $json=JSON::PP->new->utf8->canonical;
my @links=qw(CHANNEL_BAN CHANNEL_SET CHANNEL_LOG BADWORDS QUOTES USER_CHANNEL);
my @tables=('USER','USER_HOSTMASK','CHANNEL','CHANNEL_PURGED',@links,'GUARD','OUTER_WORK');
sub check {die "$_[1]\n" unless $_[0]}
sub db_state {
    my ($db)=@_;
    return $json->encode({map {$_=>$db->selectall_arrayref("SELECT * FROM $_ ORDER BY 1,2")} @tables});
}
sub peer_state {
    my ($dir)=@_;
    my $db=DBI->connect("dbi:SQLite:dbname=$dir/admin.sqlite",'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $out=db_state($db);$db->disconnect;return $out;
}
sub cache_state {
    my ($b)=@_;
    return $json->encode({channels=>[sort keys %{$b->{channels}}],
        timers=>{map {$_=>0+($b->{channel_nicklist_timers}{$_}{stopped}//0)} keys %{$b->{channel_nicklist_timers}}},
        map {$_=>$b->{$_}} qw(hChannelsNicks _badword_cache _af_params _chan_flood _chan_flood_conf _cmd_cooldown _cmd_cooldown_conf _chanset_cache _uchan_level_cache _quote_last_rand _quotegame _karma_log _duel_stats _duel_cooldown _duel_streak _duel_last_result _quote_bynick_last _karma_brigade _karma_cooldown _ignore_cache)});
}
sub setup {
    my ($raise)=@_;my $dir=tempdir(CLEANUP=>1);
    my $db=DBI->connect("dbi:SQLite:dbname=$dir/admin.sqlite",'','',
        {RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1,RootClass=>'MB933::DBI'});
    $db->sqlite_create_function('NOW',0,sub {'2026-10-23 12:00:00'});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY AUTOINCREMENT,creation_date TEXT,nickname TEXT UNIQUE,password TEXT,username TEXT,id_user_level INTEGER,auth INTEGER)');
    $db->do('CREATE TABLE USER_HOSTMASK (id_user_hostmask INTEGER PRIMARY KEY AUTOINCREMENT,id_user INTEGER,hostmask TEXT)');
    $db->do('CREATE TABLE CHANNEL (id_channel INTEGER PRIMARY KEY,name TEXT,auto_join INTEGER,chanmode TEXT,description TEXT,`key` TEXT)');
    $db->do('CREATE TABLE CHANNEL_PURGED (id_channel_purged INTEGER PRIMARY KEY AUTOINCREMENT,id_channel INTEGER,name TEXT,description TEXT,`key` TEXT,chanmode TEXT,auto_join INTEGER,purged_by TEXT,purged_at TEXT)');
    $db->do("CREATE TABLE $_ (id_row INTEGER PRIMARY KEY,id_channel INTEGER,value TEXT)") for @links;
    $db->do('CREATE TABLE GUARD (id INTEGER REFERENCES CHANNEL(id_channel) DEFERRABLE INITIALLY DEFERRED,label TEXT)');
    $db->do('CREATE TABLE OUTER_WORK (id INTEGER,label TEXT)');
    $db->do("INSERT INTO USER VALUES (9,'old','Existing',NULL,NULL,4,0)");
    $db->do("INSERT INTO CHANNEL VALUES (7,'#MiXeD',1,'+nt','Target','private-key'),(8,'#other',0,'+n','Other',NULL)");
    $db->do("INSERT INTO $_ VALUES (1,7,'target'),(2,8,'other')") for @links;
    my $logger=bless {rows=>[]},'MB933::Logger';
    my $bot=bless {dbh=>$db,logger=>$logger,irc=>bless({sent=>[]},'MB933::IRC'),
        channels=>{'#mixed'=>bless({id=>7},'MB933::Channel'),'#other'=>bless({id=>8},'MB933::Channel')},
        hChannelsNicks=>{'#MiXeD'=>{One=>1},'#mixed'=>{One=>1},'#other'=>{Other=>1}},
        channel_nicklist_timers=>{'#MiXeD'=>bless({},'MB933::Timer'),'#mixed'=>bless({},'MB933::Timer'),'#other'=>bless({},'MB933::Timer')},
    },'Mediabot';
    for my $cache (qw(_badword_cache _af_params _chan_flood _chan_flood_conf _cmd_cooldown _cmd_cooldown_conf _quote_last_rand _quotegame _karma_log _duel_stats _duel_cooldown _duel_streak _duel_last_result _karma_cooldown)) {
        $bot->{$cache}={'#MiXeD'=>1,'#mixed'=>1,'#other'=>2};
    }
    $bot->{_chanset_cache}={"#MiXeD\0a"=>1,"#mixed\0b"=>1,"#other\0c"=>2};
    $bot->{_uchan_level_cache}={"1\0#mixed"=>1,"2\0#other"=>2};
    $bot->{_quote_bynick_last}={'#MiXeD:One'=>1,'#mixed:one'=>1,'#other:Other'=>2};
    $bot->{_karma_brigade}={'brigade:One:#mixed'=>1,'brigade:Other:#other'=>2};
    $bot->{_ignore_cache}={at=>100,masks=>[]};
    return ($bot,$db,$dir);
}
sub invoke {
    my ($bot,$op,%args)=@_;
    my (@wire,@audit,@warnings,$result,$error);
    my $user=Mediabot::User->new({id_user=>1,nickname=>'Operator',auth=>$args{unauthenticated}?0:1});
    $user->{level_desc}=$args{low_level}?'User':'Owner';
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Operator',channel=>'#test',
        args=>$args{args}//($op eq 'purge'?['#MiXeD']:['New','*!new@example.test']),
        message=>bless({},'MB933::Message'),command=>$op);
    $ctx->{user}=$user;$ctx->{_user_fetched}=1;
    no warnings qw(redefine once);
    my $notice=sub {push @wire,[@_[1..$#_]];1};
    local *Mediabot::botNotice=$notice;
    local *Mediabot::UserCommands::botNotice=$notice;
    local *Mediabot::LoginCommands::botNotice=$notice;
    local *Mediabot::ChannelCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local *Mediabot::LoginCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    eval {
        $result=$op eq 'purge'
            ? ($args{imported}?Mediabot::purgeChannel_ctx($ctx):Mediabot::ChannelCommands::purgeChannel_ctx($ctx))
            : $op eq 'add' ? Mediabot::UserCommands::addUser_ctx($ctx)
            : $op eq 'register' ? Mediabot::LoginCommands::mbRegister_ctx($ctx)
            : Mediabot::Helpers::userAdd($bot,$args{mask},$args{nickname}//'Étoile',$args{password},$args{level}//'User',$args{username});
        1;
    } or $error=$@;
    return {result=>$result,error=>$error//'',wire=>\@wire,audit=>\@audit,warnings=>\@warnings};
}
sub trigger {
    my ($db,$table,$event,$body)=@_;
    $db->do("CREATE TRIGGER refuse_write BEFORE $event ON $table BEGIN $body; END");
}
sub run_checks {
    my ($suite)=@_;my @out;
    my $group=sub {my ($name,$cb)=@_;my $ok=eval {$cb->();1};push @out,{name=>$name,ok=>$ok?1:0,detail=>$ok?'':"$@"}};
    if ($suite eq 'add') {
        $group->('account and initial hostmask commit together with original level/password semantics',sub {
            for my $raise (0,1) {
                for my $level ('Owner','Master','Administrator','User','unknown') {
                    my ($b,$db,$dir)=setup($raise);my $r=invoke($b,'helper',mask=>'*!n@example.test',level=>$level,username=>'login-name');
                    check(!$r->{error} && $r->{result}==10,'userAdd success');
                    my $row=$db->selectrow_hashref('SELECT * FROM USER WHERE id_user=10');
                    my %levels=(Owner=>1,Master=>2,Administrator=>3,User=>4,unknown=>4);
                    check($row->{nickname} eq 'Étoile' && $row->{username} eq 'login-name' && $row->{id_user_level}==$levels{$level} && !$row->{auth} && !defined($row->{password}),'user fields changed');
                    check($db->selectrow_array('SELECT id_user FROM USER_HOSTMASK')==10,'mask bound to wrong id');
                    check($db->{private_mb933_id_reads}==1 && peer_state($dir) eq db_state($db),'id capture or durable commit');
                }
            }
            my ($b,$db)=setup(0);my $r=invoke($b,'helper',password=>'fixture-password',mask=>undef);
            my $stored=$db->selectrow_array('SELECT password FROM USER WHERE id_user=?',undef,$r->{result});
            check(Mediabot::Auth::password_matches('fixture-password',$stored),'password format changed');
            check($db->selectrow_array('SELECT COUNT(*) FROM USER_HOSTMASK')==0,'optional mask changed');
        });
        $group->('SQL, missing-id and commit failures leave no orphan user or false success',sub {
            for my $raise (0,1) {
                for my $fault ('USER','USER_HOSTMASK','prepare','id','commit') {
                    my ($b,$db,$dir)=setup($raise);my $before=db_state($db);
                    if ($fault eq 'prepare') {$db->{private_mb933_prepare_fail}='USER_HOSTMASK'}
                    elsif ($fault eq 'id') {$db->{private_mb933_id_fail}=1}
                    elsif ($fault eq 'commit') {trigger($db,'USER_HOSTMASK','INSERT',"INSERT INTO GUARD VALUES(999,'commit rejected')")}
                    else {trigger($db,$fault,'INSERT',"SELECT RAISE(ABORT,'mb933 write rejected')")}
                    my $r=invoke($b,'helper',mask=>'*!n@example.test');
                    check(!$r->{error} && !defined($r->{result}),"false userAdd success/exception: $fault RaiseError=$raise");
                    check(db_state($db) eq $before && peer_state($dir) eq $before,"orphan after $fault");
                    check(!grep({$_->[1]=~/created user/} @{$b->{logger}{rows}}),'created success logged on failure');
                    check($json->encode($b->{logger}{rows}) !~ /fixture-password/,'password leaked to diagnostic');
                    check($db->{private_mb933_rollback}==1,'owned transaction not rolled back');
                }
            }
        });
        $group->('failed begin and caller-owned work are preserved without rollback or commit',sub {
            for my $raise (0,1) {
                for my $outer (0,1) {
                    my ($b,$db,$dir)=setup($raise);
                    if ($outer) {$db->begin_work;$db->do("INSERT INTO OUTER_WORK VALUES(1,'caller pending')")}
                    else {$db->{private_mb933_begin_fail}=1}
                    my $before=db_state($db);my $committed=peer_state($dir);
                    my $r=invoke($b,'helper',mask=>'*!n@example.test');
                    check(!$r->{error} && !defined($r->{result}),'begin refusal escaped or succeeded');
                    check(db_state($db) eq $before && peer_state($dir) eq $committed,'caller state changed');
                    check(!($db->{private_mb933_commit}//0) && !($db->{private_mb933_rollback}//0),'caller work ended');
                    $db->rollback if $outer;
                }
            }
        });
        $group->('adduser and initial Owner registration report failure then permit a clean retry',sub {
            for my $op ('add','register') {
                my ($b,$db)=setup(0);$db->do('DELETE FROM USER') if $op eq 'register';
                trigger($db,'USER_HOSTMASK','INSERT',"SELECT RAISE(ABORT,'mb933 mask rejected')");
                my @args=$op eq 'register'?('FirstOwner','fixture-password'):('New','-n','*!n@example.test');
                my $r=invoke($b,$op,args=>\@args);
                check(!$r->{error} && @{$r->{wire}}==1 && $r->{wire}[0][1] eq ($op eq 'add'?'Unable to add user New':'Register failed'),'false success notification');
                check($db->selectrow_array('SELECT COUNT(*) FROM USER')==($op eq 'add'?1:0),'failed registration left a user');
                $db->do('DROP TRIGGER refuse_write');
                $r=invoke($b,$op,args=>$op eq 'register'?\@args:['New','*!n@example.test']);
                check(!$r->{error} && grep({$_->[1]=~/^(?:User New added|Registered FirstOwner as Owner)/} @{$r->{wire}}),'clean retry failed');
            }
        });
    }
    elsif ($suite eq 'purge') {
        $group->('committed purge archives original fields and clears only target channel state',sub {
            for my $imported (0,1) {
                my ($b,$db,$dir)=setup(0);my $r=invoke($b,'purge',imported=>$imported);
                check(!$r->{error} && $db->selectrow_array('SELECT COUNT(*) FROM CHANNEL WHERE id_channel=7')==0,'purge failed');
                for my $table (@links) {check($db->selectrow_array("SELECT COUNT(*) FROM $table WHERE id_channel=7")==0 && $db->selectrow_array("SELECT COUNT(*) FROM $table WHERE id_channel=8")==1,'cascade scope')}
                my $archive=$db->selectrow_hashref('SELECT * FROM CHANNEL_PURGED');
                check($archive->{name} eq '#MiXeD' && $archive->{key} eq 'private-key' && $archive->{description} eq 'Target' && $archive->{purged_by} eq 'Operator','archive fields changed');
                check(!exists($b->{channels}{'#mixed'}) && exists($b->{channels}{'#other'}) && !exists($b->{_badword_cache}{'#mixed'}) && $b->{_badword_cache}{'#other'}==2,'cache scope');
                check(!exists($b->{channel_nicklist_timers}{'#mixed'}) && exists($b->{channel_nicklist_timers}{'#other'}),'timer scope');
                check(@{$b->{irc}{sent}}==1 && $b->{irc}{sent}[0][0] eq 'PART' && $r->{wire}[0][1] eq 'Channel #MiXeD purged.','success delivery changed');
                check(peer_state($dir) eq db_state($db),'purge not committed');
            }
        });
        $group->('archive, cascade and deferred commit failures preserve rows, caches and IRC membership',sub {
            for my $raise (0,1) {
                for my $fault ('archive',@links,'CHANNEL','prepare','commit') {
                    my ($b,$db,$dir)=setup($raise);my $before=db_state($db);my $cache=cache_state($b);
                    if ($fault eq 'archive') {trigger($db,'CHANNEL_PURGED','INSERT',"SELECT RAISE(ABORT,'mb933 archive rejected')")}
                    elsif ($fault eq 'prepare') {$db->{private_mb933_prepare_fail}='CHANNEL_PURGED'}
                    elsif ($fault eq 'commit') {$db->do("INSERT INTO GUARD VALUES(7,'retain channel')");$before=db_state($db)}
                    else {trigger($db,$fault,'DELETE',"SELECT RAISE(ABORT,'mb933 delete rejected')")}
                    my $r=invoke($b,'purge');
                    check(!$r->{error} && @{$r->{wire}}==1 && $r->{wire}[0][1] eq 'Database error during purge -- channel not deleted.',"false purge success/exception: $fault RaiseError=$raise");
                    check(db_state($db) eq $before && peer_state($dir) eq $before,'partial purge rows');
                    check(cache_state($b) eq $cache && !@{$b->{irc}{sent}} && !@{$r->{audit}},'purge published failure');
                    check($db->{private_mb933_rollback}==1,'purge did not roll back');
                    my @errors=grep {$_->[1]=~/purgeChannel_ctx: transaction failed/} @{$b->{logger}{rows}};
                    check(@errors==1 && $errors[0][1]=~/failed for #MiXeD: \S/,'original purge diagnostic lost');
                }
            }
        });
        $group->('begin refusals and caller transactions cause no PART, cache cleanup or foreign rollback',sub {
            for my $raise (0,1) {
                for my $outer (0,1) {
                    my ($b,$db,$dir)=setup($raise);
                    if ($outer) {$db->begin_work;$db->do("INSERT INTO OUTER_WORK VALUES(1,'caller pending')")}
                    else {$db->{private_mb933_begin_fail}=1}
                    my $before=db_state($db);my $committed=peer_state($dir);my $cache=cache_state($b);
                    my $r=invoke($b,'purge');
                    check(!$r->{error} && @{$r->{wire}}==1 && $r->{wire}[0][1]=~/Database error/,'begin refusal succeeded');
                    check(db_state($db) eq $before && peer_state($dir) eq $committed,'caller rows changed');
                    check(cache_state($b) eq $cache && !@{$b->{irc}{sent}} && !@{$r->{audit}},'begin failure published');
                    check(!($db->{private_mb933_commit}//0) && !($db->{private_mb933_rollback}//0),'caller work ended');
                    $db->rollback if $outer;
                }
            }
        });
        $group->('zero-row cascades and access/argument guards retain existing behavior',sub {
            my ($b,$db)=setup(0);$db->do("DELETE FROM $_ WHERE id_channel=7") for @links;
            my $r=invoke($b,'purge');check(!$r->{error} && $r->{wire}[0][1] eq 'Channel #MiXeD purged.','zero-row deletes refused');
            for my $args ({args=>[]},{args=>['not-a-channel']},{args=>['#unknown']},{low_level=>1},{unauthenticated=>1}) {
                my ($b,$db)=setup(0);my $before=db_state($db);my $cache=cache_state($b);
                my $r=invoke($b,'purge',%$args);
                check(!$r->{error} && db_state($db) eq $before && cache_state($b) eq $cache && !@{$b->{irc}{sent}} && !($db->{private_mb933_begin}//0),'blocked purge touched state');
            }
        });
    }
    else {die "unknown suite $suite"}
    return \@out;
}
unless (caller) {print $json->encode(run_checks($ARGV[0]//'add')),"\n"}
1;
