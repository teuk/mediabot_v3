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

{
    package MB961::DBI; our @ISA = ('DBI');
    package MB961::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $hook = $sql =~ /UPDATE REMINDERS SET delivered = 1/ ? 'private_mb961_claim'
            : $sql =~ /UPDATE REMINDERS SET message = \?/ ? 'private_mb961_snooze' : '';
        if ($hook && $db->{$hook}) { my $cb = delete $db->{$hook}; $cb->() }
        return $db->SUPER::prepare($sql, @rest);
    }
    package MB961::DBI::st; our @ISA = ('DBI::st');
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
        id_channel INTEGER, from_nick TEXT, to_nick TEXT, message TEXT,
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
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
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
done_testing;
