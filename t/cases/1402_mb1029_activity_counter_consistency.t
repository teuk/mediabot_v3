use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

{
    package MB1029::DBI; our @ISA = ('DBI');
    package MB1029::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        push @{$db->{private_queries}}, $sql;
        # Only adapt MySQL's date spelling to a fixed SQLite test calendar.
        # WHERE, bindings, grouping, counts and ordering run in the real DBI engine.
        $sql =~ s/DATE_SUB\(NOW\(\), INTERVAL 12 MONTH\)/'2025-10-30 12:00:00'/g;
        return $db->SUPER::prepare($sql, @rest);
    }
    package MB1029::DBI::st; our @ISA = ('DBI::st');
    package MB1029::Channel;
    sub get_id {1}
    sub get_timezone {'UTC'}
}
$INC{'MB1029/DBI.pm'} = __FILE__;

my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub {push @wire, ['public', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::botNotice = sub {push @wire, ['notice', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::logBot = sub {1};
local $SIG{__WARN__} = sub {push @warnings, @_};

sub setup_1402 {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass=>'MB1029::DBI', RaiseError=>1, PrintError=>0, AutoCommit=>1,
        sqlite_unicode=>1,
    });
    $db->sqlite_create_function('DATE_FORMAT', 2, sub {substr($_[0], 0, 7)});
    $db->sqlite_create_function('regexp', 2, sub {
        my ($pattern, $text) = @_;
        return defined($text) && $text =~ /$pattern/ ? 1 : 0;
    });
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT)');
    $db->do('INSERT INTO CHANNEL VALUES(1, ?), (2, ?)', undef, '#test', '#other');
    $db->do('CREATE TABLE CHANNEL_LOG(id_channel INTEGER, nick TEXT COLLATE NOCASE, ts TEXT, event_type TEXT, publictext TEXT)');
    $db->do('CREATE TABLE USER_SEEN(nick TEXT, seen_at TEXT, event_type TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER, nickname TEXT)');
    $db->do('CREATE TABLE KARMA(id_channel INTEGER, nick TEXT, score INTEGER)');
    my $bot = Mediabot->new({});
    $bot->{dbh} = $db;
    $bot->{channels}{'#test'} = bless {}, 'MB1029::Channel';
    return ($bot, $db);
}
sub add_1402 {
    my ($db, $nick, $count, $text, $month, $channel, $type) = @_;
    $db->do('INSERT INTO CHANNEL_LOG VALUES(?, ?, ?, ?, ?)', undef,
        $channel//1, $nick, ($month//'2026-10').'-01 12:00:00', $type//'public', $text//'hello')
        for 1..$count;
}
sub invoke_1402 {
    my ($bot, $command, $nick, @args) = @_;
    @wire=();
    my $ctx = Mediabot::Context->new(bot=>$bot, command=>$command,
        nick=>$nick, channel=>'#test', args=>\@args);
    $bot->command_registry->handler_for($command, 'public')->($ctx);
    return [map {[@$_]} @wire];
}
sub bars_1402 {chr(0x2588) x $_[0] . chr(0x2591) x (4-$_[0])}
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 3, 'hi', '2026-09');
    add_1402($db, 'bOB', 2, 'hi', '2026-09');
    add_1402($db, 'ALICE', 2, 'hi', '2026-10');
    add_1402($db, 'Bob', 4, 'hi', '2026-10');
    add_1402($db, 'Alice', 20, 'unrelated channel', '2026-10', 2);
    add_1402($db, 'Alice', 20, 'outside window', '2020-01');
    $db->do('PRAGMA query_only = ON');
    my $before = $db->selectall_arrayref('SELECT * FROM CHANNEL_LOG');
    my $expected = [
        ['public', '#test', 'alice vs bob on #test (last 12 months):'],
        ['public', '#test', '  alice//bob — 2026-09 '.bars_1402(3).'/'.bars_1402(2)
            .'  2026-10 '.bars_1402(2).'/'.bars_1402(4)],
    ];
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'Alice', 'vs', 'Bob'), $expected,
        'native monthly comparison retains real mixed-case grouped counts, channel and date scope');
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'ALICE', 'VS', 'bOB'), $expected,
        'changing requested nickname case cannot change the monthly chart');
    my $single = invoke_1402($bot, 'monthstats', 'Caller', 'Alice');
    is_deeply($single, [
        ['public', '#test', 'alice on #test (last 12 months):'],
        ['public', '#test', '  2026-09 '.chr(0x2588)x5 .' 3  2026-10 '
            .chr(0x2588)x3 .chr(0x2591)x2 .' 2'],
    ], 'single-nickname chart keeps its existing scale and counts');
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'Nobody', 'vs', 'Absent'),
        [['public', '#test', 'No data found for nobody or absent on #test.']],
        'a genuinely empty comparison keeps its absence response');
    is_deeply($db->selectall_arrayref('SELECT * FROM CHANNEL_LOG'), $before,
        'monthly statistics remain read-only');
}
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 2);
    add_1402($db, 'Bob', 1);
    # Both accepted stats spellings are excluded from the displayed counter.
    add_1402($db, 'Alice', 1, '!stats');
    add_1402($db, 'Bob', 5, '  M  STATS Alice');
    add_1402($db, 'Carol', 9, '!stats Bob');
    add_1402($db, 'Other', 20, 'hi', '2026-10', 2);
    add_1402($db, 'Presence', 20, undef, undef, undef, 'join');
    $db->do('PRAGMA query_only = ON');
    my $out = invoke_1402($bot, 'stats', 'Alice');
    is_deeply([map {my $s=$_->[2]; [$s=~/alice: 2 messages \(66\.7%\) on #test/?1:0,
            $s=~/\| rank: #1\z/?1:0, $_->[0], $_->[1]]} @$out],
        [[1,1,'public','#test']],
        'own stats do not count the current command as a better-ranked participant');
    $out = invoke_1402($bot, 'stats', 'Caller', 'Bob');
    like($out->[0][2], qr/\Abob: 1 message \(33\.3%\).*\| rank: #2\z/,
        'rank uses the same stats-command exclusions as the displayed count and denominator');
}
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 1);
    $db->do('UPDATE CHANNEL_LOG SET publictext = NULL');
    add_1402($db, 'Alice', 1, 'waves', undef, undef, 'action');
    add_1402($db, 'Bob', 2, '!statsman');
    add_1402($db, 'Carol', 3, 'm statsman');
    $db->do('PRAGMA query_only = ON');
    my @ranks;
    for my $nick (qw(Alice Bob Carol)) {
        my $out = invoke_1402($bot, 'stats', $nick);
        push @ranks, $out->[0][2]=~/\| rank: #([0-9]+)\z/ ? 0+$1 : undef;
    }
    is_deeply(\@ranks, [2,2,1],
        'ties, actions, NULL text and ordinary words beginning with stats retain their existing counts');
}
is_deeply(\@warnings, [], 'native activity handlers emit no warnings');
done_testing;
