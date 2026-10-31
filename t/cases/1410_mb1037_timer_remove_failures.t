use strict;
use warnings;
use Test::More;
use DBI;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::Context;
use MockUser;
{
    package MB1037::Bot;
    our @ISA = ('Mediabot');
    sub botNotice {push @{$_[0]{wire}}, $_[2]; 1}
    package MB1037::Log;
    sub log {1}
    package MB1037::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD {die 'Unexpected database call'}
    sub DESTROY {}
}
my (@audit, @warnings);
local $SIG{__WARN__} = sub {push @warnings, @_};
no warnings qw(redefine once);
local *Mediabot::DBCommands::logBot = sub {push @audit, [@_[2..$#_]]; 1};
my $tmp = tempdir(CLEANUP => 1);
my $serial = 0;
sub fixture_1410 {
    my ($mode, $raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite', '', '',
        {RaiseError => $raise, PrintError => 0, AutoCommit => 1});
    $db->do('CREATE TABLE TIMERS(name TEXT PRIMARY KEY, duration INTEGER, command TEXT)');
    $db->do("INSERT INTO TIMERS VALUES('pulse',3600,'PING :timer')");
    $db->do('CREATE TABLE unrelated(value INTEGER)');
    my $loop = IO::Async::Loop->new;
    my $bot = Mediabot->new({dbh => $db}); bless $bot, 'MB1037::Bot';
    $bot->{logger} = bless({}, 'MB1037::Log');
    $bot->{loop} = $loop; $bot->{wire} = [];
    my @timers;
    for my $name (qw(pulse other)) {
        my $t = IO::Async::Timer::Periodic->new(interval => 3600, on_tick => sub {});
        $loop->add($t); $t->start;
        $bot->{hTimers}{$name} = $t; push @timers, $t;
    }
    $db->do('DROP TABLE TIMERS') if $mode eq 'prepare';
    $db->do(q{CREATE TRIGGER refuse_remove BEFORE DELETE ON TIMERS
        BEGIN SELECT RAISE(ABORT, 'fixture removal refused'); END}) if $mode eq 'execute';
    $db->do('DELETE FROM TIMERS') if $mode eq 'absent';
    if ($mode eq 'transaction') {$db->begin_work; $db->do('INSERT INTO unrelated VALUES(7)')}
    delete $bot->{dbh} if $mode eq 'no_db';
    $bot->{dbh} = bless({}, 'MB1037::NoIO') if $mode eq 'unknown' || $mode eq 'missing';
    return ($bot, $db, $loop, @timers);
}
sub invoke_1410 {
    my ($bot, $args, $user) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Operator', channel => '#test',
        command => 'remtimer', args => $args);
    $ctx->{user} = $user // MockUser->new(level => 'Owner', auth => 1);
    $ctx->{_user_fetched} = 1;
    return eval {$bot->command_registry->handler_for('remtimer', 'public')->($ctx); 1} ? '' : 'exception';
}
sub live_1410 {
    my ($bot, $timer) = @_;
    return [exists($bot->{hTimers}{pulse}) ? 1:0,
        $timer->is_running ? 1:0, $timer->loop ? 1:0];
}
sub cleanup_1410 {
    my ($db, $loop, @timers) = @_;
    $db->rollback unless $db->{AutoCommit};
    for my $t (@timers) {$t->stop; $loop->remove($t) if $t->loop}
    $db->disconnect;
}
for my $mode (qw(prepare execute)) {
    for my $raise (0,1) {
        my ($bot,$db,$loop,$timer,$other) = fixture_1410($mode,$raise);
        @audit = ();
        my $error = invoke_1410($bot,['pulse']);
        my $rows = $mode eq 'prepare' ? undef : $db->selectrow_array('SELECT COUNT(*) FROM TIMERS');
        is_deeply([$error,$bot->{wire},live_1410($bot,$timer),$rows,scalar @audit],
            ['', ['DB error while removing timer'], [1,1,1], $mode eq 'prepare' ? undef:1, 0],
            "$mode RaiseError=$raise: failed deletion is contained and keeps the native timer live");
        ok($other->is_running && $other->loop && $bot->{hTimers}{other},
            "$mode RaiseError=$raise: unrelated timer remains live");
        cleanup_1410($db,$loop,$timer,$other);
    }
}
{
    my ($bot,$db,$loop,$timer,$other) = fixture_1410('transaction',1);
    @audit = ();
    my $error = invoke_1410($bot,['pulse']);
    is_deeply([$error,$bot->{wire},live_1410($bot,$timer),$db->{AutoCommit}?1:0,
        $db->selectrow_array('SELECT COUNT(*) FROM TIMERS'),
        $db->selectrow_array('SELECT COUNT(*) FROM unrelated'),scalar @audit],
        ['', ['DB error while removing timer'], [1,1,1], 0, 1, 1, 0],
        'a caller-owned transaction cannot report a removal or stop the runtime timer');
    $db->rollback;
    is_deeply([$db->selectrow_array('SELECT COUNT(*) FROM TIMERS'),
        $db->selectrow_array('SELECT COUNT(*) FROM unrelated'),live_1410($bot,$timer)], [1,0,[1,1,1]],
        'caller rollback remains caller-owned and cannot resurrect a supposedly removed timer');
    cleanup_1410($db,$loop,$timer,$other);
}
for my $mode (qw(success absent)) {
    my ($bot,$db,$loop,$timer,$other) = fixture_1410($mode,1);
    @audit = ();
    my $error = invoke_1410($bot,['pulse']);
    my $message = $mode eq 'absent' ? 'Timer pulse removed from runtime (not found in database)' : 'Timer pulse removed';
    is_deeply([$error,$bot->{wire},live_1410($bot,$timer),
        $db->selectrow_array('SELECT COUNT(*) FROM TIMERS'),scalar @audit],
        ['',[$message],[0,0,0],0,1], "$mode: confirmed removal retains native stop/detach and one audit");
    ok($other->is_running && $other->loop && $bot->{hTimers}{other},
        "$mode: confirmed removal is scoped to the requested timer");
    cleanup_1410($db,$loop,$timer,$other);
}
{
    my ($bot,$db,$loop,$timer,$other) = fixture_1410('success',1);
    @audit = ();
    my $error = invoke_1410($bot,['pulse'],MockUser->new(level => 'User', auth => 1));
    is_deeply([$error,live_1410($bot,$timer),$db->selectrow_array('SELECT COUNT(*) FROM TIMERS'),scalar @audit],
        ['', [1,1,1],1,0], 'Owner authorization remains required before removing stored or active state');
    cleanup_1410($db,$loop,$timer,$other);
}
for my $mode (qw(no_db unknown missing)) {
    my ($bot,$db,$loop,$timer,$other) = fixture_1410($mode,1);
    @audit = ();
    my $error = invoke_1410($bot,$mode eq 'missing' ? [] : [$mode eq 'unknown' ? 'absent' : 'pulse']);
    my $notice = $mode eq 'no_db' ? 'DB error while removing timer'
        : $mode eq 'unknown' ? 'Unknown timer absent' : 'Syntax: remtimer <name>';
    is_deeply([$error,$bot->{wire},live_1410($bot,$timer),scalar @audit],
        ['',[$notice],[1,1,1],0], "$mode: invalid or unavailable removal never reaches SQL or stops a timer");
    cleanup_1410($db,$loop,$timer,$other);
}
is_deeply(\@warnings, [], 'all native removal paths are warning-free');
done_testing;
