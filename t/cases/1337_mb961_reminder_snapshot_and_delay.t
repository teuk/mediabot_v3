use strict;
use warnings;
use utf8;
BEGIN { $MB961::Clock::now = 1000; *CORE::GLOBAL::time = sub () { $MB961::Clock::now } }
use Test::More;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
use DBI;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::IRC::Sender ();
use MB881OutputFixture;

{
    package MB961::DBI; our @ISA = ('DBI');
    package MB961::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $recurrence = $sql =~ /SELECT delivered FROM REMINDERS WHERE id_reminder = \?/;
        my $fault = $recurrence ? delete($db->{private_mb1371_fault}) : undef;
        $db->{private_mb1371_inserts}++ if $db->{private_mb1371_trace} && $sql =~ /INSERT INTO REMINDERS/;
        return $db->set_err(1911, 'private recurrence prepare detail')
            if defined($fault) && $fault eq 'prepare';
        my $release = $sql =~ /UPDATE REMINDERS SET delivered = 0/;
        my $hook = $release ? 'private_mb1100_release'
            : $sql =~ /UPDATE REMINDERS SET delivered = 1/ ? 'private_mb961_claim'
            : $sql =~ /UPDATE REMINDERS SET message = \?/ ? 'private_mb961_snooze' : '';
        if ($hook && $db->{$hook}) { my $cb = delete $db->{$hook}; $cb->() }
        return $db->set_err(1901,'private release prepare detail')
            if $release && ($db->{private_mb1100_fault}//'') eq 'prepare';
        my $sth=$db->SUPER::prepare($sql, @rest);
        $sth->{private_release}=$release?1:0 if $sth;
        $sth->{private_mb1371_fault}=$fault if $sth && defined($fault);
        return $sth;
    }
    package MB961::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->set_err(1912, 'private recurrence execute detail')
            if ($sth->{private_mb1371_fault}//'') eq 'execute';
        return $sth->set_err(1902,'private release execute detail')
            if $sth->{private_release} && ($sth->{Database}{private_mb1100_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth)=@_;
        my $fault=$sth->{private_mb1371_fault}//'';
        return $sth->set_err(1913, 'private recurrence fetch detail') if $fault eq 'fetch';
        my $row=$sth->SUPER::fetchrow_hashref;
        $sth->set_err(1914, 'private recurrence row diagnostic') if $fault eq 'fetch_row';
        return $row;
    }
    sub finish {
        my ($sth)=@_;
        $sth->set_err(undef,undef) if defined($sth->{private_mb1371_fault});
        if ($sth->{private_release}) {
            $sth->{Database}{private_mb1100_finishes}++;
            $sth->set_err(undef,undef);
        }
        return $sth->SUPER::finish;
    }
    package MB961::Log; sub log { push @{$_[0]{rows}}, [@_[1..$#_]]; 1 }
    package MB961::Channel; sub get_id { 7 }
    package MB961::Bot; our @ISA = ('Mediabot');
    sub gethChannelsNicksOnChan { ('Friend', 'Sender') }
}
$INC{'MB961/DBI.pm'} = __FILE__;

my $tmp = tempdir(CLEANUP => 1);
my $serial = 0;
my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub setup_1337 {
    my ($message) = @_;
    $MB961::Clock::now = 1000; @wire = (); @warnings = ();
    my $dsn = 'dbi:SQLite:dbname=' . $tmp . '/' . ++$serial . '.sqlite';
    my $db = DBI->connect($dsn, '', '', { RaiseError => 1, PrintError => 0,
        AutoCommit => 1, sqlite_unicode => 1, RootClass => 'MB961::DBI' });
    my $peer = DBI->connect($dsn, '', '', { RaiseError => 1, PrintError => 0,
        AutoCommit => 1, sqlite_unicode => 1 });
    $db->do(q{CREATE TABLE REMINDERS (id_reminder INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER, from_nick TEXT, to_nick TEXT, message TEXT COLLATE NOCASE,
        created_at TEXT DEFAULT 'stored', delivered INTEGER DEFAULT 0)});
    $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message)
        VALUES(7,'sender','friend',?)}, undef, $message) if defined $message;
    my $bot = sub { bless { dbh => $_[0], logger => bless({}, 'MB961::Log'),
        channels => { '#test' => bless({}, 'MB961::Channel') } }, 'MB961::Bot' };
    return ($bot->($db), $db, $bot->($peer), $peer);
}
sub invoke_1337 {
    my ($bot, $entry, $method, @args) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Sender',
        channel => '#test', args => \@args);
    my $name = $entry . '::' . $method;
    no strict 'refs';
    return &{$name}($ctx);
}
sub deliver_1337 {
    my ($bot, $entry) = @_;
    no strict 'refs';
    return &{ $entry . '::deliverReminders' }($bot, 'Friend', '#test');
}

# Two actual DBI connections: the snooze completes after delivery's SELECT,
# before its conditional UPDATE. All three public function facades are real.
# MB1058: aliases are proved in 1431; run each scenario once on its owner.
for my $entry ('Mediabot::CommunityState') {
    for my $prefix ('', '[daily:09:00] ', '[weekly:1:09:00] ') {
        my ($bot, $db, $peer_bot, $peer) = setup_1337($prefix . '[at:100] Un café');
        $db->{private_mb961_claim} = sub {
            invoke_1337($peer_bot, $entry, 'mbRemindSnooze_ctx', '1', '1h');
        };
        deliver_1337($bot, $entry);
        is(scalar(grep { $_->[0] eq 'public' } @wire), 0,
            "$entry $prefix: stale delivery cannot override a completed snooze");
        is($db->selectrow_array('SELECT delivered FROM REMINDERS WHERE id_reminder=1'), 0,
            "$entry $prefix: snoozed reminder remains pending");
        is($db->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1'),
            '[at:4600] ' . $prefix . 'Un café', "$entry $prefix: new deadline and body survive");
        @wire = ();
        $MB961::Clock::now = 4600;
        deliver_1337($bot, $entry);
        deliver_1337($bot, $entry);
        is(scalar(grep { $_->[0] eq 'public' } @wire), 1,
            "$entry $prefix: postponed reminder is delivered once when actually due");
        is(scalar @warnings, 0, "$entry $prefix: race emits no Perl warnings");
    }
    my ($bot, $db, $peer_bot) = setup_1337('Un café');
    $db->{private_mb961_snooze} = sub {
        invoke_1337($peer_bot, $entry, 'mbRemindSnooze_ctx', '1', '2h');
    };
    invoke_1337($bot, $entry, 'mbRemindSnooze_ctx', '1', '1h');
    is($db->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1'),
        '[at:8200] Un café', "$entry: later stale snooze cannot erase the confirmed two-hour snooze");
    like($wire[-1][2], qr/changed or is no longer pending/,
        "$entry: stale snooze reports the conflict without false success");
}

for my $args (
    (map { ['Friend', 'in', ('9' x 300) . $_, 'texte'] } qw(h m d w)),
    ['Friend', 'in', '0h', 'texte'],
    ['Friend', 'in', '0m', 'texte'],
    ['!', 'Friend'],
    ['daily', '09:00', 'Friend'],
    ['weekly', 'mon', '09:00', 'Friend'],
    ['Friend', 'in', '1h', ('é' x 506)],
) {
    my ($bot, $db) = setup_1337();
    invoke_1337($bot, 'Mediabot::CommunityState', 'mbRemind_ctx', @$args);
    is($db->selectrow_array('SELECT COUNT(*) FROM REMINDERS'), 0,
        'invalid or oversized reminder never reaches INSERT: ' . join(' ', map { length($_)>32 ? substr($_,0,12).'...' : $_ } @$args));
    unlike(join(' ', map { $_->[2] } @wire), qr/Reminder set for/,
        'invalid reminder is never acknowledged as created');
    is(scalar @warnings, 0, 'invalid reminder is refused without numeric warnings');
}

for my $args (['Friend', 'Un café'], ['Friend', 'in', '2h30m', 'Un café'],
        ['daily', '09:00', 'Friend', 'Un café'], ['weekly', 'mon', '09:00', 'Friend', 'Un café'],
        ['!', 'Friend', 'Un café']) {
    my ($bot, $db) = setup_1337();
    invoke_1337($bot, 'Mediabot::CommunityState', 'mbRemind_ctx', @$args);
    is($db->selectrow_array('SELECT COUNT(*) FROM REMINDERS'), 1, 'documented reminder form is still created');
    like($wire[-1][2], qr/Reminder set for Friend/, 'valid reminder is acknowledged');
    my $message = $db->selectrow_array('SELECT message FROM REMINDERS');
    like($message, qr/Un café\z/, 'Unicode reminder text is preserved');
    like($message, qr/\[at:10000\]/, 'relative two-hour thirty-minute delay is exact') if $args->[1] eq 'in';
    is(scalar @warnings, 0, 'valid reminder form emits no warnings');
}

{
    my ($bot, $db) = setup_1337();
    invoke_1337($bot, 'Mediabot::CommunityState', 'mbRemind_ctx', 'Friend', 'in', '1h', ('é' x 502));
    my ($message) = $db->selectrow_array('SELECT message FROM REMINDERS');
    is(length($message // ''), 512, 'final 512-character boundary remains accepted with UTF-8 text');
    like($message // '', qr/\A\[at:4600\] /, 'boundary message still has an exact future timestamp');
    is(scalar @warnings, 0, 'maximum valid reminder emits no warnings');
}
# MB1100: use the actual outgoing policy/queue and capture only IRC effects.
sub native_output_1100 {
    my ($bot)=@_;my $output=MB881OutputFixture::new_bot();
    $bot->{$_}=$output->{$_} for qw(policy blocked events logger irc metrics);
    $bot->{_badword_cache}{'#test'}={ts=>time(),words=>[]};
}
sub states_1100 {$_[0]->selectall_arrayref('SELECT id_reminder,id_channel,message,delivered FROM REMINDERS ORDER BY id_reminder')}
MB881OutputFixture::with_policy(sub {
    local *Mediabot::UserCommands::botPrivmsg=\&Mediabot::IRC::Sender::botPrivmsg;
    for my $refusal (qw(badword full_queue)) {
        my (@actual,@expected);
        for my $raise (0,1) {
            for my $prefix ('','[daily:09:00] ','[weekly:1:09:00] ') {
                my $stored=$prefix.'[at:100] Un café';
                my ($bot,$db,undef,$peer)=setup_1337($stored);native_output_1100($bot);
                $db->{RaiseError}=$raise;
                $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message)
                    VALUES(8,'sender','friend','Other channel')});
                if ($refusal eq 'badword') {$bot->{_badword_cache}{'#test'}{words}=['café']}
                else {
                    $bot->{policy}{AntiFlood}=1;$bot->{blocked}=1;
                    $bot->{_flood_outq}{'#test'}={items=>[map {['privmsg',"queued$_"]} 1..30],armed=>0};
                }
                deliver_1337($bot,'Mediabot::CommunityState');
                my $refused=[states_1100($db),scalar @{$bot->{irc}{wire}},
                    scalar(grep {$_->[0] eq 'history'} @{$bot->{events}})];
                $bot->{_badword_cache}{'#test'}{words}=[];$bot->{blocked}=0;
                $bot->{_flood_outq}{'#test'}={items=>[],armed=>0};
                deliver_1337($bot,'Mediabot::CommunityState');
                deliver_1337($bot,'Mediabot::CommunityState');
                my $rows=states_1100($db);
                my $next=@$rows>2?$rows->[-1][2]:'';my ($due)=$next=~/\[at:(\d+)\]/;
                my ($history)=grep {$_->[0] eq 'history'} @{$bot->{events}};
                my $tag=$prefix eq ''?'':$prefix=~/daily/?' [daily 09:00]':' [weekly Mon 09:00]';
                push @actual,[$refused,scalar @{$bot->{irc}{wire}},$history?$history->[5]:'',
                    $rows->[0][3],$rows->[1],scalar @$rows,
                    $prefix eq ''?1:defined($due) && $due>time() && $next=~/\A\Q$prefix\E.*Un café\z/?1:0,
                    scalar @warnings];
                push @expected,[[[[1,7,$stored,0],[2,8,'Other channel',0]],0,0],
                    1,"Friend: reminder from sender (stored)$tag: Un café",1,[2,8,'Other channel',0],
                    $prefix eq ''?2:3,1,0];
                $db->disconnect;$peer->disconnect;
            }
        }
        is_deeply(\@actual,\@expected,
            "$refusal: real output refusal keeps original pending tags, scope and recurrence; recovery delivers once with RaiseError on/off");
    }
    {
        my ($bot,$db,undef,$peer)=setup_1337('Un café');native_output_1100($bot);
        $bot->{policy}{AntiFlood}=1;$bot->{blocked}=1;
        $bot->{_flood_outq}{'#test'}={items=>[map {['privmsg',"queued$_"]} 1..29],armed=>0};
        deliver_1337($bot,'Mediabot::CommunityState');deliver_1337($bot,'Mediabot::CommunityState');
        my $accepted=[scalar @{$bot->{irc}{wire}},scalar @{$bot->{_flood_outq}{'#test'}{items}},
            $db->selectrow_array('SELECT delivered FROM REMINDERS WHERE id_reminder=1')];
        $bot->{blocked}=0;
        Mediabot::Helpers::_drain_flood_queue($bot,'#test') for 1..30;
        my $before=MB881::IRC->can('do_PRIVMSG');my @uncertain;
        for my $position (qw(before after)) {
            my ($b,$d,undef,$p)=setup_1337('Un café');native_output_1100($b);
            my $calls=0;
            local *MB881::IRC::do_PRIVMSG=sub {
                $calls++;$before->(@_) if $position eq 'after';die "transport outcome unknown\n";
            };
            my $ok=eval {deliver_1337($b,'Mediabot::CommunityState');1};
            my $error=$@;
            deliver_1337($b,'Mediabot::CommunityState');
            push @uncertain,[$ok?1:0,$error eq "transport outcome unknown\n"?1:0,$calls,
                scalar @{$b->{irc}{wire}},$d->selectrow_array('SELECT delivered FROM REMINDERS WHERE id_reminder=1')];
            $d->disconnect;$p->disconnect;
        }
        is_deeply([$accepted,scalar @{$bot->{irc}{wire}},
            scalar(grep {$_->[0] eq 'history' && $_->[5]=~/Friend: reminder/} @{$bot->{events}}),\@uncertain],
            [[0,30,1],30,1,[[0,1,1,0,1],[0,1,1,1,1]]],
            'accepted deferred output stays claimed and sends once; exceptions before/after a wire attempt keep at-most-once state and propagate');
        $db->disconnect;$peer->disconnect;
    }
    {
        my (@actual,@expected);
        for my $raise (0,1) {
            for my $change (qw(prepare execute cancel body body_case delete stale_snapshot)) {
                my ($bot,$db,undef,$peer)=setup_1337('[at:100] Un café');native_output_1100($bot);
                $db->{RaiseError}=$raise;$bot->{_badword_cache}{'#test'}{words}=['café'];
                $db->{private_mb961_claim}=sub {
                    $peer->do(q{UPDATE REMINDERS SET message='[at:100] un café' WHERE id_reminder=1});
                } if $change eq 'stale_snapshot';
                $db->{private_mb1100_fault}=$change if $change eq 'prepare' || $change eq 'execute';
                $db->{private_mb1100_release}=sub {
                    $peer->do('UPDATE REMINDERS SET delivered=2 WHERE id_reminder=1') if $change eq 'cancel';
                    $peer->do(q{UPDATE REMINDERS SET message='Changed body' WHERE id_reminder=1}) if $change eq 'body';
                    $peer->do(q{UPDATE REMINDERS SET message='[at:100] un café' WHERE id_reminder=1}) if $change eq 'body_case';
                    $peer->do('DELETE FROM REMINDERS WHERE id_reminder=1') if $change eq 'delete';
                };
                my $ok=eval {deliver_1337($bot,'Mediabot::CommunityState');1};
                my @errors=map {$_->[1]} grep {$_->[0]==1} @{$bot->{logger}{rows}};
                push @actual,[$ok?1:0,states_1100($db),scalar @{$bot->{irc}{wire}},
                    scalar(grep {/private release/} @errors),scalar @errors,
                    $db->{private_mb1100_finishes}//0,scalar @warnings];
                push @expected,[1,$change eq 'delete'?[]:[[1,7,$change eq 'body'?'Changed body':$change eq 'body_case' || $change eq 'stale_snapshot'?'[at:100] un café':'[at:100] Un café',
                    $change eq 'cancel'?2:$change eq 'stale_snapshot'?0:1]],0,0,$change eq 'stale_snapshot'?0:1,
                    $change eq 'prepare' || $change eq 'stale_snapshot'?0:1,0];
                $db->disconnect;$peer->disconnect;
            }
        }
        is_deeply(\@actual,\@expected,
            'requeue SQL failures stay bounded and nonthrowing; conditional release cannot overwrite cancellation, a changed body or deletion');
    }
});
# MB1340: a case-insensitive SQL collation must not let a stale snooze
# overwrite another connection's message, even when only its case changed.
for my $raise (0,1) {
    for my $prefix ('','[daily:09:00] ','[weekly:1:09:00] ') {
        my $original=$prefix.'[at:100] Un café';
        my $changed=$prefix.'[at:100] UN café';
        my ($bot,$db,undef,$peer)=setup_1337($original);
        $db->{RaiseError}=$raise;
        $db->{private_mb961_snooze}=sub {
            $peer->do('UPDATE REMINDERS SET message=? WHERE id_reminder=1',undef,$changed);
        };
        invoke_1337($bot,'Mediabot::CommunityState','mbRemindSnooze_ctx','1','1h');
        is_deeply($peer->selectrow_arrayref('SELECT message,delivered FROM REMINDERS WHERE id_reminder=1'),
            [$changed,0],"case-only concurrent edit survives stale snooze (RaiseError=$raise, $prefix)");
        like($wire[-1][2],qr/changed or is no longer pending/,'conflict is reported without a false success');
        @wire=();
        invoke_1337($bot,'Mediabot::CommunityState','mbRemindSnooze_ctx','1','1h');
        my $expected='[at:4600] '.$prefix.'UN café';
        is($peer->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1'),$expected,
            'fresh snooze retains the changed text and recurrence');
        like($wire[-1][2],qr/snoozed for/,'fresh snooze is acknowledged');
        invoke_1337($bot,'Mediabot::CommunityState','mbRemindSnooze_ctx','1','1h');
        is($peer->selectrow_array('SELECT message FROM REMINDERS WHERE id_reminder=1'),$expected,
            'identical repeat remains idempotent');
        is(scalar @warnings,0,'race and recovery emit no warnings');
    }
}
# MB1341: snooze moves [at:] before recurrence; listing must decode both orders.
for my $case (['',''],['[daily:09:00] ',' [daily 09:00]'],['[weekly:1:09:00] ',' [weekly Mon 09:00]']) {
    my ($prefix,$label)=@$case;
    for my $urgent ('','[!] ') {
        my $stored=$prefix.'[at:4600] '.$urgent.'Un café';
        my ($bot,$db)=setup_1337($stored);
        $db->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
        $db->do("INSERT INTO CHANNEL VALUES(7,'#test')");
        for my $phase ('created','snoozed') {
            invoke_1337($bot,'Mediabot::CommunityState','mbRemindSnooze_ctx','1','1h') if $phase eq 'snoozed';
            my $before=$db->selectrow_arrayref('SELECT message,delivered FROM REMINDERS WHERE id_reminder=1');
            @wire=();
            invoke_1337($bot,'Mediabot::CommunityState','mbRemindList_ctx');
            my $line=$wire[1][2] // '';
            my ($body)=$line=~/: "(.*)"/;
            is_deeply([scalar @wire,$wire[1][0],$wire[1][1],$body,
                $line=~/\[in /?1:0,
                $label eq '' || index($line,$label)>=0 ? 1:0,
                $line=~/\[URGENT\]/?1:0,
                $line=~/\[(?:at|daily|weekly):/?1:0],
                [2,'notice','Sender','Un café',1,1,$urgent?1:0,0],
                "$phase $prefix $urgent: list retains deadline, recurrence and urgency without raw tags");
            is_deeply($db->selectrow_arrayref('SELECT message,delivered FROM REMINDERS WHERE id_reminder=1'),
                $before,'listing does not rewrite or deliver the stored reminder');
        }
    }
}
# MB1371: a post-send read failure or absent/non-delivered row cannot authorize
# another occurrence. Drive the real DBI query and retain two-connection changes.
for my $prefix ('[daily:09:00] ', '[weekly:1:09:00] ') {
    for my $raise (0,1) {
        for my $case (qw(prepare execute fetch fetch_row cancelled deleted pending confirmed)) {
            my $stored=$prefix.'[at:100] Un café';
            my ($bot,$db,undef,$peer)=setup_1337($stored);
            $db->{RaiseError}=$raise;
            $peer->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message)
                VALUES(7,'sender','friend','Next reminder'),(8,'sender','friend','Other channel')});
            my $fault=$case=~/\A(?:prepare|execute|fetch|fetch_row)\z/ ? 1:0;
            $db->{private_mb1371_fault}=$case if $fault;
            $db->{private_mb1371_trace}=1;
            local *Mediabot::UserCommands::botPrivmsg=sub {
                push @wire, ['public', @_[1,2]];
                if (@wire==1) {
                    $peer->do('DELETE FROM REMINDERS WHERE id_reminder=1') if $case eq 'deleted';
                    $peer->do('UPDATE REMINDERS SET delivered=? WHERE id_reminder=1',undef,
                        $case eq 'cancelled'?2:0) if $case eq 'cancelled' || $case eq 'pending';
                }
                return 1;
            };
            my $ok=eval { deliver_1337($bot,'Mediabot::CommunityState'); 1 };
            my $error=$@;
            my $rows=states_1100($peer);
            my $next=$case eq 'confirmed' ? pop @$rows : undef;
            my ($due)=$next ? $next->[2]=~/\[at:([0-9]+)\]/ : ();
            my @expected=($case eq 'deleted'?():([1,7,$stored,$case eq 'cancelled'?2:$case eq 'pending'?0:1]),
                [2,7,'Next reminder',1],[3,8,'Other channel',0]);
            my @errors=map {$_->[1]} grep {$_->[0]==1} @{$bot->{logger}{rows}//[]};
            my $tag=$prefix=~/daily/?' [daily 09:00]':' [weekly Mon 09:00]';
            is_deeply([$ok?1:0,$error,$rows,[@wire],[@warnings],
                $db->{private_mb1371_inserts}//0,\@errors,
                $case ne 'confirmed' || ($next && $next->[0]==4 && $next->[1]==7 && $next->[3]==0
                    && defined($due) && $due>time() && $next->[2] eq $prefix."[at:$due] Un café") ? 1:0],
                [1,'',\@expected,
                 [['public','#test',"Friend: reminder from sender (stored)$tag: Un café"],
                  ['public','#test','Friend: reminder from sender (stored): Next reminder']],[],
                 $case eq 'confirmed'?1:0,
                 $fault?['deliverReminders: recurrence state unavailable id=1']:[],1],
                "$prefix RaiseError=$raise $case: only a confirmed delivered occurrence recurs, and the next reminder is still delivered");
            if ($fault) {
                # A new occurrence on the same handle can recur after recovery;
                # the already-sent occurrence remains claimed, never resent.
                $peer->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message)
                    VALUES(7,'sender','friend',?)},undef,$stored);
                @wire=(); $bot->{logger}{rows}=[];
                deliver_1337($bot,'Mediabot::CommunityState');
                deliver_1337($bot,'Mediabot::CommunityState');
                is_deeply([scalar @wire,$db->{private_mb1371_inserts}//0,
                    $peer->selectcol_arrayref('SELECT delivered FROM REMINDERS WHERE id_channel=7 ORDER BY id_reminder'),
                    [grep {$_->[0]==1} @{$bot->{logger}{rows}//[]}],[@warnings]],
                    [1,1,[1,1,1,0],[],[]],
                    'same-handle recovery schedules a new reminder once without replaying the uncertain occurrence');
            }
            $db->disconnect; $peer->disconnect;
        }
    }
}
# MB1373: snooze must include its replacement timestamp in the VARCHAR(512)
# character budget, just like creation. Read through the second connection to
# verify the stored body and state; no replacement may be attempted on refusal.
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $glyph ('x', 'é', '🪄') {
        my (@actual, @expected);
        for my $case (
            ['plain_boundary', '', '', 512],
            ['plain_overflow', '', '', 513],
            ['created_full', '', '', 528],
            ['growing_timestamp', '[at:1] ', '', 513],
            ['daily_boundary', '[daily:09:00] [at:1] ', '[daily:09:00] ', 512],
            ['weekly_overflow', '[weekly:1:09:00] [at:1] ', '[weekly:1:09:00] ', 513],
            ['urgent_boundary', '[!] ', '[!] ', 512],
            ['same_width', '[at:1800000000] ', '', 512],
        ) {
            my ($label, $old_prefix, $kept_prefix, $size) = @$case;
            my $next_prefix = '[at:1800003600] ' . $kept_prefix;
            my $body = $glyph x ($size - length($next_prefix) - 4) . ' END';
            my $original = $old_prefix . $body;
            my ($bot, $db, undef, $peer) = setup_1337($label eq 'created_full' ? undef : $original);
            $MB961::Clock::now = 1800000000;
            if ($label eq 'created_full') {
                invoke_1337($bot, $entry, 'mbRemind_ctx', 'Friend', $body);
            }
            $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message)
                VALUES(8,'sender','friend','Other channel'),(7,'other','friend','Other owner')});
            my $before = $peer->selectall_arrayref('SELECT * FROM REMINDERS ORDER BY id_reminder');
            my $updates = 0;
            $db->{private_mb961_snooze} = sub { $updates++ };
            @wire = ();
            my $result = invoke_1337($bot, $entry, 'mbRemindSnooze_ctx', '1', '1h');
            my $after = $peer->selectall_arrayref('SELECT * FROM REMINDERS ORDER BY id_reminder');
            my $valid = $size <= 512;
            my $wanted = $valid ? $next_prefix . $body : $original;
            my $response = $valid ? 'Reminder #1 snoozed for 1h00m.'
                : 'Cannot snooze: message too long with the new deadline (max 512 chars).';
            # Compare every persisted field, including unrelated rows, while
            # keeping failure output compact for long Unicode messages.
            $before->[0][4] = $wanted;
            push @actual, [$label, $result ? 1 : 0, $updates,
                Test::More::eq_array($after, $before) ? 1 : 0,
                [@wire], scalar @warnings];
            push @expected, [$label, $valid ? 1 : 0, $valid ? 1 : 0, 1,
                [['notice', 'Sender', $response]], 0];
            $db->disconnect; $peer->disconnect;
        }
        is_deeply(\@actual, \@expected,
            "$entry $glyph: snooze preserves full text, accepts 512 characters and refuses overflow before UPDATE");
    }
}
done_testing;
