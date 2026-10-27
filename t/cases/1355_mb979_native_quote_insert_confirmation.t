use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use String::IRC;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;

{
    package MB979::DBI; our @ISA = ('DBI');
    package MB979::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $insert = $sql =~ /INSERT INTO QUOTES/;
        if ($insert) {
            $db->{private_attempts}++;
            die "private insert preparation detail\n"
                if ($db->{private_fault}//'') eq 'prepare_die';
            $sql = 'INSERT INTO mb979_missing_table VALUES(?)'
                if ($db->{private_fault}//'') eq 'prepare';
        }
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_insert} = $insert ? 1 : 0 if $sth;
        return $sth;
    }
    sub last_insert_id {
        my ($db,@args) = @_;
        $db->{private_id_reads}++;
        die "private inserted id detail\n" if ($db->{private_fault}//'') eq 'id_die';
        return undef if ($db->{private_fault}//'') eq 'id_undef';
        return $db->SUPER::last_insert_id(@args);
    }
    package MB979::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        return $sth->SUPER::execute(@bind) unless $sth->{private_insert};
        my $db = $sth->{Database};
        my $fault = $db->{private_fault}//'';
        $db->{private_executes}++;
        die "private insert execution detail\n" if $fault eq 'execute_die';
        # Use an actual foreign-key failure before any row is committed.
        $bind[1] = 999 if $fault eq 'execute';
        my $result = $sth->SUPER::execute(@bind);
        return $sth->set_err(1,'private lost insertion acknowledgement')
            if $fault eq 'after_commit' || $fault eq 'after_commit_finish';
        if ($fault eq 'status_error') {
            local $sth->{RaiseError} = 0;
            $sth->set_err(1,'private unconfirmed insertion status');
        }
        return $result;
    }
    sub finish {
        my ($sth) = @_;
        my $insert = $sth->{private_insert};
        my $db = $sth->{Database};
        my $fault = $db->{private_fault}//'';
        $db->{private_finished}++ if $insert;
        my $ok = $sth->SUPER::finish;
        $sth->set_err(undef,undef);
        die "private insert cleanup detail\n"
            if $insert && ($fault eq 'finish_die' || $fault eq 'after_commit_finish');
        return 0 if $insert && $fault eq 'finish_false';
        return $ok;
    }
    package MB979::Channel; sub get_id {1}
    package MB979::Log; sub log {push @{$_[0]{lines}},$_[2];1}
    package MB979::Achievements;
    sub check_community_contributions {
        my ($self,@args) = @_;
        push @{$self->{calls}},\@args;
        # A real secondary INSERT must not replace the quote id in the reply.
        $self->{dbh}->do(q{INSERT INTO AUDIT(note) VALUES('contribution')});
        return 1;
    }
}
$INC{'MB979/DBI.pm'} = __FILE__;
my $tmp = tempdir(CLEANUP=>1);
my $serial = 0;
my (@wire,@warnings,@logs);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice = sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg = sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::logBot = sub {push @logs,[@_[1..$#_]];1};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1355 {
    my ($raise,$fault) = @_;
    my $dsn = 'dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db = DBI->connect($dsn,'','',{RootClass=>'MB979::DBI',
        RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $peer = DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,
        AutoCommit=>1,sqlite_unicode=>1});
    $db->do('PRAGMA foreign_keys=ON'); $peer->do('PRAGMA foreign_keys=ON');
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $peer->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $peer->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER REFERENCES CHANNEL(id_channel),
        id_user INTEGER REFERENCES USER(id_user),quotetext TEXT)});
    $peer->do('CREATE TABLE AUDIT(id INTEGER PRIMARY KEY AUTOINCREMENT,note TEXT)');
    $peer->do(q{INSERT INTO AUDIT VALUES(900,'existing')});
    $peer->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $peer->do(q{INSERT INTO USER VALUES(7,'Account')});
    $peer->do(q{INSERT INTO QUOTES VALUES(10,1,7,'Existing quote'),(20,2,7,'Foreign quote')});
    $db->{private_fault}=$fault;
    for (qw(attempts executes finished id_reads)) {$db->{'private_'.$_}=0}
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{channels}{'#test'}=bless {},'MB979::Channel';
    $bot->{logger}=bless {lines=>[]},'MB979::Log';
    $bot->{achievements}=bless {calls=>[],dbh=>$db},'MB979::Achievements';
    return ($bot,$db,$peer);
}
sub invoke_1355 {
    my ($entry,$bot,$auth,$text) = @_;
    @wire=();@warnings=();@logs=();
    my $result;
    my $ok=eval {
        if ($entry =~ /^registry:(.+)$/) {
            my $name=$1;
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Speaker',channel=>'#test',
                command=>$name,args=>['add',$text]);
            $ctx->{_user_fetched}=1;
            if ($auth) {
                $ctx->{user}=Mediabot::User->new({id_user=>7,nickname=>'Account',auth=>1});
                $ctx->{user}{level}='User';$ctx->{user}{level_desc}='User';
            }
            $result=$bot->command_registry->handler_for($name,'public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteAdd"}($bot,undef,$auth?7:undef,
                $auth?'Account':undef,'Speaker','#test',$text);
        }
        1;
    };
    return ($ok?'':$@,$result);
}
sub visible_1355 {
    return [map {my @m=@$_;$m[2]=~s/[\x02\x0f]//g;\@m} @wire];
}
my @entries=qw(Mediabot::Quotes Mediabot registry:q registry:quote);
my $text='Un été à Poudlard 🦉';
for my $entry (@entries) {
    for my $raise (0,1) {
        for my $fault (qw(prepare prepare_die execute execute_die after_commit after_commit_finish status_error)) {
            my ($bot,$db,$peer)=setup_1355($raise,$fault);
            my $label="$entry RaiseError=$raise $fault";
            my ($error,$result)=invoke_1355($entry,$bot,1,$text);
            is($error,'',"$label: insertion error stays inside the command handler");
            is_deeply(\@wire,[['notice','Speaker','Database error while adding quote.']],
                "$label: one fixed failure notice, no false public confirmation");
            ok(!defined $result,"$label: unconfirmed insertion does not return a quote id");
            is($db->{private_attempts},1,"$label: no automatic retry");
            my $prepared=$fault =~ /^prepare/ ? 0 : 1;
            is($db->{private_finished},$prepared,"$label: allocated insertion cursor is finished once");
            is($db->{private_id_reads},0,"$label: failed insertion does not read a stale connection id");
            is_deeply($bot->{achievements}{calls},[],"$label: no contribution for an unconfirmed insertion");
            is_deeply(\@logs,[],"$label: no successful command log");
            is(scalar @warnings,0,"$label: no driver warning escapes");
            unlike(join(' ',@{$bot->{logger}{lines}}),qr/private |mb979_missing_table|FOREIGN KEY/,
                "$label: driver details stay out of runtime logs");
            my $committed=$fault =~ /^(?:after_commit|status_error)/ ? 1 : 0;
            is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES WHERE quotetext=?',undef,$text),
                $committed,"$label: independent observer distinguishes failure before/after commit");
            is($peer->selectrow_array('SELECT COUNT(*) FROM AUDIT'),1,"$label: no secondary insertion");
            $db->{private_fault}='';
            ($error,$result)=invoke_1355($entry,$bot,1,$text);
            is($error,'',"$label: next explicit command completes");
            is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES WHERE quotetext=?',undef,$text),1,
                "$label: explicit retry leaves exactly one quote");
            if ($committed) {
                like($wire[0][2]//'',qr/already exists/,"$label: retry finds the committed quote");
                is_deeply($bot->{achievements}{calls},[],"$label: duplicate does not invent a successful first acknowledgement");
                is($db->{private_attempts},1,"$label: uncertain committed write is not repeated");
            } else {
                like($wire[0][2]//'',qr/done\. \(id:/,"$label: recovery confirms the actual new insert");
                is_deeply($bot->{achievements}{calls},[['Speaker','#test',7]],"$label: recovery awards one contribution");
                is($db->{private_attempts},2,"$label: one insertion per explicit attempt");
            }
        }
        for my $fault ('','finish_die','finish_false','id_die','id_undef') {
            for my $auth (0,1) {
                my ($bot,$db,$peer)=setup_1355($raise,$fault);
                my $label="$entry RaiseError=$raise '$fault' auth=$auth";
                my ($error,$id)=invoke_1355($entry,$bot,$auth,$text);
                is($error,'',"$label: confirmed insertion survives cleanup or optional id failure");
                my $row=$peer->selectrow_hashref('SELECT * FROM QUOTES WHERE quotetext=?',undef,$text);
                ok($row && $row->{id_quotes}>20,"$label: independent observer sees the inserted quote");
                is($row?$row->{id_user}:undef,$auth?7:undef,"$label: author/anonymous identity is retained");
                my $shown=$fault =~ /^id_/ ? '?' : ($row?$row->{id_quotes}:0);
                my $prefix=$auth?'(Account) ':'';
                is($id,$shown,"$label: returned quote id precedes any secondary INSERT");
                is_deeply(visible_1355(),[['public','#test',$prefix."done. (id: $shown)"]],
                    "$label: existing public confirmation and id fallback are retained");
                is($db->{private_finished},1,"$label: insertion cursor cleaned exactly once");
                is($db->{private_attempts},1,"$label: no duplicate insertion");
                is_deeply($bot->{achievements}{calls},[['Speaker','#test',$auth?7:undef]],
                    "$label: exactly one contribution after confirmed execution");
                is(scalar @logs,1,"$label: one successful command log");
                is(scalar @warnings,0,"$label: no warning escapes");
                is($peer->selectrow_array('SELECT MAX(id) FROM AUDIT'),901,
                    "$label: contribution callback really changes the connection insert id");
                is($peer->selectrow_array('SELECT quotetext FROM QUOTES WHERE id_quotes=20'),'Foreign quote',
                    "$label: other-channel data stays intact");
                ($error)=invoke_1355($entry,$bot,$auth,$text);
                is($error,'',"$label: later duplicate remains a normal command");
                is($db->{private_attempts},1,"$label: duplicate does not reinsert");
                is(scalar @{$bot->{achievements}{calls}},1,"$label: duplicate does not award twice");
            }
        }
    }
}
done_testing;
