package MB1334::Case1374;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Storable qw(dclone);
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB999::DBI; our @ISA = ('DBI');
    package MB999::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $read = $sql =~ /SELECT\s+r\.id_reminder\b/i;
        my $cancel = $sql =~ /\A\s*(?:UPDATE|DELETE FROM)\s+REMINDERS\b/i;
        my $quota = $sql =~ /SELECT\s+COUNT\(\*\) AS cnt FROM REMINDERS/i;
        return $db->set_err(1,'private reminder prepare detail')
            if ($read && ($db->{private_fault}//'') eq 'prepare')
                || ($quota && ($db->{private_fault}//'') eq 'quota_prepare')
                || ($cancel && ($db->{private_fault}//'') eq 'cancel_prepare');
        my $sth = $db->SUPER::prepare($sql, @rest);
        if ($sth) {
            $sth->{private_read} = $read ? 1 : 0;
            $sth->{private_quota} = $quota ? 1 : 0;
            $sth->{private_cancel} = $cancel ? 1 : 0;
        }
        return $sth;
    }
    package MB999::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        $sth->{private_fetched} = 0;
        return $sth->set_err(1,'private reminder execute detail')
            if ($sth->{private_read} && ($sth->{Database}{private_fault}//'') eq 'execute')
                || ($sth->{private_quota} && ($sth->{Database}{private_fault}//'') eq 'quota_execute')
                || ($sth->{private_cancel} && ($sth->{Database}{private_fault}//'') eq 'cancel_execute');
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth, @rest) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        if ($sth->{private_quota}) {
            return $sth->set_err(1,'private reminder quota detail') if $fault eq 'quota_fetch';
            return undef if $fault eq 'quota_missing';
            return {cnt=>undef} if $fault eq 'quota_null';
        }
        return $sth->set_err(1,'private reminder fetch detail')
            if $sth->{private_read} && ($fault eq 'fetch_first'
                || ($fault eq 'fetch_after_one' && $sth->{private_fetched}));
        my $row = $sth->SUPER::fetchrow_hashref(@rest);
        $sth->{private_fetched}++ if $row;
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        if ($sth->{private_quota}) {
            $sth->{Database}{private_quota_finished}++;
            $sth->set_err(undef,undef);
            die "private quota cleanup detail\n" if $sth->{Database}{private_quota_cleanup_failure};
        }
        if ($sth->{private_read}) {
            $sth->{Database}{private_finished}++;
            $sth->set_err(undef,undef); # cleanup must not erase a failed-read decision
            die "private cleanup detail\n" if $sth->{Database}{private_cleanup_failure};
        }
        if ($sth->{private_cancel}) {
            $sth->{Database}{private_cancel_finished}++;
            if (($sth->{Database}{private_fault}//'') eq 'cancel_finish') {
                $sth->SUPER::finish;
                die "private cancel cleanup detail\n";
            }
        }
        return $sth->SUPER::finish;
    }
    package MB999::Log;
    sub log {
        push @{$_[0]{entries}}, [@_[1,2]];
        die "private logger detail\n" if $_[0]{fail};
        return 1;
    }
}
$INC{'MB999/DBI.pm'} = __FILE__;
my (@wire, @audit, @warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
sub setup_1374 {
    my ($raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RootClass=>'MB999::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('INSERT INTO CHANNEL VALUES(7,\'#test\'),(8,\'#else\')');
    $db->do('CREATE TABLE REMINDERS(id_reminder INTEGER PRIMARY KEY,id_channel INTEGER,
        from_nick TEXT,to_nick TEXT,message TEXT,created_at TEXT DEFAULT "created",delivered INTEGER DEFAULT 0)');
    my @rows = (
        [1,7,'alice','caller','Incoming A','2026-10-28 10:01',0],
        [2,7,'bob','caller','Incoming Bêta','2026-10-28 10:02',0],
        [3,8,'charlie','caller','Incoming elsewhere','2026-10-28 10:03',0],
        [4,7,'caller','zoé','Outgoing A','2026-10-28 10:04',0],
        [5,7,'caller','eve','Outgoing B','2026-10-28 10:05',0],
        [6,8,'caller','mallory','Outgoing elsewhere','2026-10-28 10:06',0],
        [7,7,'caller','caller','Already delivered','2026-10-28 10:07',1],
        [8,7,'outsider','stranger','Unrelated','2026-10-28 10:08',0]);
    $db->do('INSERT INTO REMINDERS VALUES(?,?,?,?,?,?,?)',undef,@$_) for @rows;
    my $bot = Mediabot->new({}); $bot->{dbh} = $db;
    $bot->{logger} = bless {entries=>[]}, 'MB999::Log';
    return ($bot,$db);
}
sub rows_1374 { $_[0]->selectall_arrayref('SELECT * FROM REMINDERS ORDER BY id_reminder') }
sub invoke_1374 {
    my ($bot, $kind, $channel, $nick, $alias) = @_;
    @wire = (); @audit = (); $bot->{logger}{entries} = [];
    my $command = $alias // ($kind eq 'remindlist' ? 'remindlist' : 'remind');
    my $args = $kind eq 'remindlist' ? [] : [$kind];
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>$nick//'Caller',channel=>$channel,
        command=>$command,args=>$args);
    my $ok = eval { $bot->command_registry->handler_for($command,'public')->($ctx); 1 };
    return $ok ? '' : "$@";
}
for my $kind (qw(show list remindlist)) {
    for my $raise (0,1) {
        my (@actual,@expected);
        for my $fault (qw(prepare execute fetch_first fetch_after_one)) {
            my ($bot,$db) = setup_1374($raise); my $before = rows_1374($db);
            $db->{private_fault} = $fault;
            # Cover both SQL scopes without duplicating the entire fault matrix.
            my $error = invoke_1374($bot,$kind,$raise ? undef : '#test');
            $db->{private_fault} = '';
            my $operation = $kind eq 'remindlist' ? 'mbRemindList_ctx()' : "mbRemind_ctx($kind)";
            push @actual, [$fault,$error,dclone(\@wire),dclone(\@audit),
                dclone($bot->{logger}{entries}),$db->{private_finished}//0,rows_1374($db)];
            push @expected, [$fault,'',[['notice','Caller','Database error.']],[],
                [[1,"$operation database read failed."]],$fault eq 'prepare' ? 0 : 1,$before];
        }
        is_deeply(\@actual,\@expected,
            "$kind RaiseError=$raise: failed prepare/execute/fetch never escapes or publishes empty/partial data");
    }
}
for my $kind (qw(show list remindlist)) {
    my ($bot,$db) = setup_1374(1); my $before = rows_1374($db);
    my (@actual,@expected);
    # MB1356: every IRC channel prefix must retain the same SQL scope.
    for my $channel ('#test','&test','!ABCDEtest','+test',undef,'') {
        $db->do('UPDATE CHANNEL SET name=? WHERE id_channel=7',undef,$channel)
            if defined($channel) && length($channel);
        my $error = invoke_1374($bot,$kind,$channel);
        my @ids = $kind eq 'show' ? (1,2) : (4,5);
        push @ids, $kind eq 'show' ? 3 : 6 unless defined($channel) && length($channel);
        my @rows = map { $before->[$_-1] } @ids;
        my @lines = $kind eq 'show' ? ('Reminders set for you:')
            : $kind eq 'list' ? ('Pending reminders:')
            : (scalar(@rows).' pending reminder(s) you have set:');
        push @lines, map { $kind eq 'show' ? "  [#$_->[0]] from $_->[2]: $_->[4]"
            : $kind eq 'list' ? "  [#$_->[0]] for $_->[3]: $_->[4]"
            : "  #$_->[0] -> $_->[3]: \"$_->[4]\"" } @rows;
        push @actual, [$error,dclone(\@wire),dclone(\@audit),rows_1374($db)];
        push @expected, ['', [map { ['notice','Caller',$_] } @lines], [],$before];
    }
    is_deeply(\@actual,\@expected,"$kind: healthy channel and private reads preserve scope, order, text and data");
}
# A valid but unknown channel must not silently become a private/global read.
{
    my ($bot,$db)=setup_1374(1); my $before=rows_1374($db);
    my (@actual,@expected);
    for my $channel ('#missing','&missing','!ABCDEmissing','+missing') {
        for my $kind (qw(show list remindlist)) {
            my $error=invoke_1374($bot,$kind,$channel,undef,$kind eq 'remindlist' ? undef : 'tell');
            push @actual,[$error,dclone(\@wire),dclone(\@audit)];
            push @expected,['',[['notice','Caller',$kind eq 'show'
                ? 'No pending reminders set for you.' : 'No pending reminders.']],[]];
        }
    }
    is_deeply([\@actual,rows_1374($db)],[\@expected,$before],
        'unknown channels remain scoped, including tell, without exposing other-channel reminders');
}
# Native nicklist lookup must accept an online nick without USER/USER_SEEN rows.
for my $command (qw(remind tell)) {
    for my $channel ('#TeSt','&TeSt','!ABCDEtest','+TeSt') {
        my ($bot,$db)=setup_1374(1); my $before=rows_1374($db);
        $db->do('UPDATE CHANNEL SET name=? WHERE id_channel=7',undef,$channel);
        $db->do('CREATE TABLE USER_SEEN(nick TEXT)');
        $db->do('CREATE TABLE USER(nickname TEXT)');
        $bot->{hChannelsNicks}={lc($channel)=>['Caller','Friend'],'#else'=>['Elsewhere']};
        my (@actual,@expected);
        for my $target ('Friend','Elsewhere','Unknown') {
            @wire=(); @audit=();
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>$channel,
                command=>$command,args=>[$target,'Un café']);
            my $ok=eval {$bot->command_registry->handler_for($command,'public')->($ctx);1};
            push @actual,[$ok?'':"$@",dclone(\@wire),dclone(\@audit)];
            push @expected,$target eq 'Friend'
                ? ['',[['notice','Caller','Reminder set for Friend.']],
                    [[$channel,'remind','Friend: Un café']]]
                : ['',[['notice','Caller',"Unknown nick '$target'. The remind was not created."]],[]];
        }
        is_deeply([\@actual,rows_1374($db)],
            [\@expected,[@$before,[9,7,'caller','friend','Un café','created',0]]],
            "$command on $channel: native local nicklist creates only the intended pending reminder");
    }
}
{
    my ($bot,$db) = setup_1374(1);
    my $error = invoke_1374($bot,'show','#test',undef,'tell');
    is_deeply([$error,\@wire,\@audit],['',[
        ['notice','Caller','Reminders set for you:'],
        ['notice','Caller','  [#1] from alice: Incoming A'],
        ['notice','Caller','  [#2] from bob: Incoming Bêta']],[]],
        'tell alias still reaches the protected incoming-reminder read');
}
{
    my ($bot,$db) = setup_1374(1); my @actual;
    for my $kind (qw(show list remindlist)) {
        my $error = invoke_1374($bot,$kind,undef,'Nobody');
        push @actual, [$error,dclone(\@wire),dclone($bot->{logger}{entries})];
    }
    is_deeply(\@actual,[map { ['', [['notice','Nobody',$_]], []] }
        ('No pending reminders set for you.','No pending reminders.','No pending reminders.')],
        'confirmed empty reads retain the existing absence notices');
}
{
    my (@failed,@healthy,@expected_failed,@expected_healthy);
    for my $kind (qw(show list remindlist)) {
        my ($bot,$db) = setup_1374(1); my $before = rows_1374($db);
        my $error = invoke_1374($bot,$kind,'#test'); my $healthy = dclone(\@wire);
        $db->{private_cleanup_failure} = 1; $bot->{logger}{fail} = 1;
        $db->{private_fault} = 'fetch_after_one';
        $error = invoke_1374($bot,$kind,'#test'); $db->{private_fault} = '';
        push @failed, [$error,dclone(\@wire),dclone(\@audit),rows_1374($db)];
        push @expected_failed, ['', [['notice','Caller','Database error.']],[],$before];
        $error = invoke_1374($bot,$kind,'#test');
        push @healthy, [$error,dclone(\@wire),dclone($bot->{logger}{entries}),rows_1374($db)];
        push @expected_healthy, ['', $healthy, [], $before];
    }
    is_deeply(\@failed,\@expected_failed,
        'cleanup and logger failures cannot hide a failed read or publish its first row');
    is_deeply(\@healthy,\@expected_healthy,
        'cleanup failure alone does not turn a confirmed complete read into an error');
}
sub cancel_1374 {
    my ($bot,$cmd,@args)=@_;
    @wire=();@audit=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>'#test',
        command=>$cmd,args=>['cancel',@args]);
    my $ok=eval {$bot->command_registry->handler_for($cmd,'public')->($ctx);1};
    return [$ok?'':"$@",dclone(\@wire),dclone(\@audit)];
}
for my $cmd (qw(remind tell)) {
    my ($bot,$db)=setup_1374(1);
    my $before=rows_1374($db);
    my @actual;
    for my $args ([],['all','extra'],['4','extra'],['４'],['0'],['18446744073709551616']) {
        push @actual,cancel_1374($bot,$cmd,@$args);
    }
    is_deeply([\@actual,rows_1374($db)],
        [[map {['',[['notice','Caller','Syntax: remind cancel <id>|all  (see !remindlist)']],[]]} 1..6],$before],
        "$cmd: invalid syntax cannot cancel a single reminder or all reminders");

    @actual=map {cancel_1374($bot,$cmd,$_)} qw(4 4 1 ALL all);
    my @expected_rows=map {my @row=@$_;$row[6]=2 if $row[0]>=4 && $row[0]<=6;\@row} @$before;
    is_deeply([\@actual,rows_1374($db)],
        [[
            ['', [['notice','Caller','Reminder #4 cancelled.']], [['#test','remind_cancel','4']]],
            ['', [['notice','Caller','Reminder #4 not found or already delivered.']], []],
            ['', [['notice','Caller','Reminder #1 not found or already delivered.']], []],
            ['', [['notice','Caller','2 pending reminder(s) cancelled.']], [['#test','remind_cancel','all']]],
            ['', [['notice','Caller','0 pending reminder(s) cancelled.']], []],
        ],\@expected_rows],
        "$cmd: single and bulk cancellation only mark the caller's pending rows, with truthful counts and audit");
}
{
    my (@actual,@expected);
    for my $raise (0,1) {for my $fault (qw(cancel_prepare cancel_execute cancel_finish)) {
        my ($bot,$db)=setup_1374($raise);
        my $before=rows_1374($db);
        $db->{private_fault}=$fault;
        my $result=cancel_1374($bot,$raise ? 'tell' : 'remind','all');
        $db->{private_fault}='';
        my $saved=$fault eq 'cancel_finish';
        my $want=$saved ? ['', [['notice','Caller','3 pending reminder(s) cancelled.']], [['#test','remind_cancel','all']]]
            : ['', [['notice','Caller','Database error.']], []];
        my @rows=map {my @row=@$_;$row[6]=2 if $saved && $row[0]>=4 && $row[0]<=6;\@row} @$before;
        push @actual,[$raise,$fault,$result,rows_1374($db),$db->{private_cancel_finished}//0];
        push @expected,[$raise,$fault,$want,\@rows,$fault eq 'cancel_prepare' ? 0 : 1];
    }}
    is_deeply(\@actual,\@expected,'DBI errors stay private, statements finish, and a cleanup exception cannot undo a confirmed cancellation');
}
# MB1357: a failed quota read is not an empty quota and must never insert.
for my $raise (0,1) {
    my (@actual,@expected);
    for my $fault (qw(quota_prepare quota_execute quota_fetch quota_missing quota_null quota_fetch_cleanup healthy_cleanup)) {
        my ($bot,$db)=setup_1374($raise); my $before=rows_1374($db);
        $bot->{hChannelsNicks}={'#test'=>['Caller','Friend']};
        $db->{private_fault}=$fault eq 'quota_fetch_cleanup' ? 'quota_fetch' : $fault;
        $db->{private_quota_cleanup_failure}=1 if $fault =~ /cleanup/;
        $bot->{logger}{fail}=1 if $fault eq 'quota_fetch_cleanup';
        my $command=$raise ? 'tell' : 'remind';
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>'#test',
            command=>$command,args=>['Friend','Un café']);
        @wire=(); @audit=();
        my $ok=eval {$bot->command_registry->handler_for($command,'public')->($ctx);1};
        my $error=$ok?'':"$@";
        $db->{private_fault}='';
        my $saved=$fault eq 'healthy_cleanup';
        push @actual,[$fault,$error,dclone(\@wire),dclone(\@audit),rows_1374($db),$db->{private_quota_finished}//0];
        push @expected,[$fault,'',[['notice','Caller',$saved ? 'Reminder set for Friend.' : 'Database error.']],
            $saved ? [['#test','remind','Friend: Un café']] : [],
            $saved ? [@$before,[9,7,'caller','friend','Un café','created',0]] : $before,
            $fault eq 'quota_prepare' ? 0 : 1];
    }
    is_deeply(\@actual,\@expected,"quota RaiseError=$raise: failed reads stop writes; cleanup cannot erase their outcome");
}
for my $command (qw(remind tell)) {
    my (@actual,@expected);
    for my $pending (0,9,10) {
        my ($bot,$db)=setup_1374(1);
        $db->do("DELETE FROM REMINDERS WHERE from_nick='caller' AND delivered=0");
        $db->do('INSERT INTO REMINDERS VALUES(?,?,?,?,?,?,?)',undef,100+$_,
            $_%2 ? 7 : 8,'caller','friend','Queued','created',0) for 1..$pending;
        $db->do("INSERT INTO REMINDERS VALUES(500,7,'caller','friend','Cancelled','created',2)");
        my $before=rows_1374($db);
        $bot->{hChannelsNicks}={'#test'=>['Caller','Friend']};
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Caller',channel=>'#test',
            command=>$command,args=>['Friend','Un café']);
        @wire=(); @audit=();
        my $ok=eval {$bot->command_registry->handler_for($command,'public')->($ctx);1};
        my $saved=$pending<10;
        push @actual,[$pending,$ok?'':"$@",dclone(\@wire),dclone(\@audit),rows_1374($db)];
        push @expected,[$pending,'',[['notice','Caller',$saved ? 'Reminder set for Friend.'
            : 'You already have 10 pending reminders. Cancel some before adding more.']],
            $saved ? [['#test','remind','Friend: Un café']] : [],
            $saved ? [@$before,[501,7,'caller','friend','Un café','created',0]] : $before];
    }
    is_deeply(\@actual,\@expected,"$command: quota counts pending reminders across channels, excluding other senders and completed rows");
}
is_deeply(\@warnings,[],'reminder reads, quotas and cancellations emit no warnings');
1;
