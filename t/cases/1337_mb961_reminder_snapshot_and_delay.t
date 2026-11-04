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
        my $release = $sql =~ /UPDATE REMINDERS SET delivered = 0/;
        my $hook = $release ? 'private_mb1100_release'
            : $sql =~ /UPDATE REMINDERS SET delivered = 1/ ? 'private_mb961_claim'
            : $sql =~ /UPDATE REMINDERS SET message = \?/ ? 'private_mb961_snooze' : '';
        if ($hook && $db->{$hook}) { my $cb = delete $db->{$hook}; $cb->() }
        return $db->set_err(1901,'private release prepare detail')
            if $release && ($db->{private_mb1100_fault}//'') eq 'prepare';
        my $sth=$db->SUPER::prepare($sql, @rest);
        $sth->{private_release}=$release?1:0 if $sth;
        return $sth;
    }
    package MB961::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        return $sth->set_err(1902,'private release execute detail')
            if $sth->{private_release} && ($sth->{Database}{private_mb1100_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_release}) {
            $sth->{Database}{private_mb1100_finishes}++;
            $sth->set_err(undef,undef);
        }
        return $sth->SUPER::finish;
    }
    package MB961::Log; sub log { 1 }
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
done_testing;
