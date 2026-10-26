use strict;
use warnings;
use utf8;
BEGIN { $MB963::Clock::now = 0; *CORE::GLOBAL::time = sub () { $MB963::Clock::now } }
use Test::More;
use DBI;
use DateTime;
use POSIX ();
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB963::Log; sub log { 1 }
    package MB963::Channel; sub get_id { 7 }
    package MB963::Bot; our @ISA = ('Mediabot');
    sub gethChannelsNicksOnChan { ('Friend', 'Sender') }
}
my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub epoch_1339 {
    my ($zone, $stamp) = @_;
    my ($y, $mo, $d, $h, $mi, $s) = split /[- :]/, $stamp;
    return DateTime->new(year => $y, month => $mo, day => $d, hour => $h,
        minute => $mi, second => $s // 0, time_zone => $zone)->epoch;
}
sub setup_1339 {
    @wire = (); @warnings = ();
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1 });
    $db->do(q{CREATE TABLE REMINDERS(id_reminder INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER, from_nick TEXT, to_nick TEXT, message TEXT,
        created_at TEXT DEFAULT 'stored', delivered INTEGER DEFAULT 0)});
    my $bot = bless { dbh => $db, logger => bless({}, 'MB963::Log'),
        channels => { '#test' => bless({}, 'MB963::Channel') } }, 'MB963::Bot';
    return ($bot, $db);
}
sub invoke_1339 {
    my ($entry, $bot, @args) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Sender', channel => '#test', args => \@args);
    no strict 'refs';
    &{ $entry . '::mbRemind_ctx' }($ctx);
}
sub deliver_1339 {
    my ($entry, $bot) = @_;
    no strict 'refs';
    &{ $entry . '::deliverReminders' }($bot, 'Friend', '#test');
}
sub pending_1339 {
    my ($db) = @_;
    my $row = $db->selectrow_hashref('SELECT * FROM REMINDERS WHERE delivered=0 ORDER BY id_reminder DESC LIMIT 1');
    my ($due) = $row ? $row->{message} =~ /\[at:(\d+)\]/ : ();
    return ($due, $row);
}

# Expectations are explicit calendar dates, resolved independently by DateTime.
my @cases = (
    ['Europe/Paris', '2026-03-28 14:00:00', '09:00', 'sun', '2026-03-29 09:00:00'],
    ['Europe/Paris', '2026-03-29 00:30:00', '09:00', 'sun', '2026-03-29 09:00:00'],
    ['Europe/Paris', '2026-10-24 14:00:00', '09:00', 'sun', '2026-10-25 09:00:00'],
    ['Europe/Paris', '2026-10-25 00:30:00', '09:00', 'sun', '2026-10-25 09:00:00'],
    ['Europe/Paris', '2026-12-31 14:00:00', '09:00', 'fri', '2027-01-01 09:00:00'],
    ['UTC', '2026-03-28 14:00:00', '09:00', 'sun', '2026-03-29 09:00:00'],
    ['UTC', '2026-10-24 14:00:00', '09:00', 'sun', '2026-10-25 09:00:00'],
    ['Australia/Lord_Howe', '2026-10-03 14:00:00', '09:00', 'sun', '2026-10-04 09:00:00'],
    ['Australia/Lord_Howe', '2026-04-04 14:00:00', '09:00', 'sun', '2026-04-05 09:00:00'],
    ['Europe/Paris', '2028-02-28 14:00:00', '09:00', 'tue', '2028-02-29 09:00:00'],
    ['Europe/Paris', '2026-10-26 08:58:59', '09:00', 'mon', '2026-10-26 09:00:00'],
    ['Europe/Paris', '2026-10-26 08:59:00', '09:00', undef, '2026-10-27 09:00:00'],
    # A skipped local time rolls forward by the DST gap, preserving minutes.
    ['Europe/Paris', '2026-03-29 00:30:00', '02:30', 'sun', '2026-03-29 03:30:00'],
);
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $case (@cases) {
        my ($zone, $start, $hhmm, $dow, $expected) = @$case;
        local $ENV{TZ} = $zone; POSIX::tzset();
        for my $kind (qw(daily at weekly)) {
            next if $kind eq 'weekly' && !defined $dow;
            my ($bot, $db) = setup_1339();
            $MB963::Clock::now = epoch_1339($zone, $start);
            my @args = $kind eq 'daily' ? ('daily', $hhmm, 'Friend', 'Un café')
                : $kind eq 'weekly' ? ('weekly', $dow, $hhmm, 'Friend', 'Un café')
                : ('Friend', 'at', $hhmm, 'Un café');
            invoke_1339($entry, $bot, @args);
            my ($due, $row) = pending_1339($db);
            my $label = "$entry $zone $start $kind $hhmm";
            is($due, epoch_1339($zone, $expected), "$label: correct local calendar deadline");
            like($row->{message} // '', qr/Un café\z/, "$label: text is preserved");
            # Drive the actual delivery against the independently expected time.
            $MB963::Clock::now = epoch_1339($zone, $expected) - 1;
            deliver_1339($entry, $bot);
            is(scalar(grep { $_->[0] eq 'public' } @wire), 0, "$label: no early delivery");
            $MB963::Clock::now++;
            deliver_1339($entry, $bot);
            is(scalar(grep { $_->[0] eq 'public' } @wire), 1, "$label: delivered at the requested local time");
            is(scalar @warnings, 0, "$label: no warnings");
        }
    }
    for my $case (
        ['2026-03-28 09:00:00', 'daily', '2026-03-29 09:00:00'],
        ['2026-10-24 09:00:00', 'daily', '2026-10-25 09:00:00'],
        ['2026-03-22 09:00:00', 'weekly', '2026-03-29 09:00:00'],
        ['2026-10-18 09:00:00', 'weekly', '2026-10-25 09:00:00'],
    ) {
        local $ENV{TZ} = 'Europe/Paris'; POSIX::tzset();
        my ($start, $kind, $expected) = @$case;
        my ($bot, $db) = setup_1339();
        $MB963::Clock::now = epoch_1339('Europe/Paris', $start);
        my $tag = $kind eq 'daily' ? '[daily:09:00]' : '[weekly:0:09:00]';
        $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message) VALUES(7,'sender','friend',?)},
            undef, "$tag [at:$MB963::Clock::now] Un café");
        deliver_1339($entry, $bot);
        my ($due, $row) = pending_1339($db);
        is($due, epoch_1339('Europe/Paris', $expected), "$entry $start: reinserted $kind retains local time across DST");
        like($row->{message} // '', qr/\Q$tag\E.*Un café\z/, "$entry: recurrence tag and Unicode text survive reinsertion");
        deliver_1339($entry, $bot);
        is(scalar(grep { $_->[0] eq 'public' } @wire), 1, "$entry: recurrence is not delivered twice");
    }
    {
        local $ENV{TZ} = 'Europe/Paris'; POSIX::tzset();
        my ($bot, $db) = setup_1339();
        # Specify UTC instants to avoid ambiguous test expectations in the fold.
        $MB963::Clock::now = epoch_1339('UTC', '2026-10-25 00:10:00');
        invoke_1339($entry, $bot, 'daily', '02:30', 'Friend', 'Un café');
        my ($due) = pending_1339($db);
        is($due, epoch_1339('UTC', '2026-10-25 00:30:00'), "$entry: repeated 02:30 selects its first occurrence");
        $MB963::Clock::now = epoch_1339('UTC', '2026-10-25 00:30:00');
        deliver_1339($entry, $bot);
        ($due) = pending_1339($db);
        is($due, epoch_1339('UTC', '2026-10-26 01:30:00'), "$entry: daily recurrence goes to tomorrow at 02:30 CET");
        $MB963::Clock::now = epoch_1339('UTC', '2026-10-25 01:30:00');
        deliver_1339($entry, $bot);
        is(scalar(grep { $_->[0] eq 'public' } @wire), 1, "$entry: repeated clock hour cannot deliver daily reminder twice");
    }
    {
        local $ENV{TZ} = 'Europe/Paris'; POSIX::tzset();
        my ($bot, $db) = setup_1339();
        $MB963::Clock::now = epoch_1339('Europe/Paris', '2026-10-26 08:59:00');
        invoke_1339($entry, $bot, 'weekly', 'mon', '09:00', 'Friend', 'Un café');
        my ($due) = pending_1339($db);
        is($due, epoch_1339('Europe/Paris', '2026-11-02 09:00:00'), "$entry: weekly creation preserves the existing sixty-second guard");
    }
    for my $args (['in', '1d', 86400], ['in', '1w', 604800], ['tomorrow', 86400]) {
        local $ENV{TZ} = 'Europe/Paris'; POSIX::tzset();
        my ($bot, $db) = setup_1339();
        $MB963::Clock::now = epoch_1339('Europe/Paris', '2026-03-28 14:00:00');
        my @tokens = @$args; my $duration = pop @tokens;
        invoke_1339($entry, $bot, 'Friend', @tokens, 'Un café');
        my ($due) = pending_1339($db);
        is($due, $MB963::Clock::now + $duration, "$entry: relative duration remains elapsed seconds across DST");
    }
    for my $tag ('[daily:99:99]', '[weekly:9:09:00]') {
        local $ENV{TZ} = 'Europe/Paris'; POSIX::tzset();
        my ($bot, $db) = setup_1339();
        $MB963::Clock::now = epoch_1339('Europe/Paris', '2026-10-26 12:00:00');
        $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message) VALUES(7,'sender','friend',?)}, undef, "$tag Un café");
        my $ok = eval { deliver_1339($entry, $bot); 1 };
        ok($ok, "$entry: invalid stored recurrence cannot throw out of delivery");
        is($db->selectrow_array('SELECT COUNT(*) FROM REMINDERS WHERE delivered=0'), 0,
            "$entry: invalid recurrence is not reinserted with a bogus timestamp");
    }
}
done_testing;
