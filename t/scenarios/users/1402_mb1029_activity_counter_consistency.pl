use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
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
        $sql =~ s/DATE_SUB\(NOW\(\), INTERVAL 60 MINUTE\)/'2026-10-01 11:00:00'/g;
        $sql =~ s/DATE_SUB\(NOW\(\), INTERVAL 0*24 HOUR\)/'2026-09-30 12:00:00'/g;
        $sql =~ s/NOW\(\) - INTERVAL 14 DAY/'2026-09-17 12:00:00'/g;
        $sql =~ s/TIMESTAMPDIFF\(MINUTE, cl\.ts, NOW\(\)\)/(unixepoch('2026-10-01 12:30:00') - unixepoch(cl.ts)) \/ 60/g;
        my $monthly = $sql =~ /SELECT DATE_FORMAT/;
        my $active = $sql =~ /SELECT cl\.nick, COUNT\(\*\) AS mc/;
        $sql = 'SELECT * FROM mb1346_missing_table'
            if $monthly && ($db->{private_monthstats_fault} // '') eq 'prepare';
        $sql = 'SELECT * FROM mb1347_missing_table'
            if $active && ($db->{private_active_fault} // '') eq 'prepare';
        my $sth = $db->SUPER::prepare($sql, @rest);
        if ($sth && $monthly) {
            $sth->{private_monthstats} = 1;
            $sth->{private_fetched} = 0;
        }
        if ($sth && $active) {
            $sth->{private_active} = 1;
            $sth->{private_fetched} = 0;
        }
        return $sth;
    }
    package MB1029::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        return $sth->set_err(1, 'private monthly execute failure')
            if $sth->{private_monthstats} && ($sth->{Database}{private_monthstats_fault} // '') eq 'execute';
        return $sth->set_err(1, 'private active execute failure')
            if $sth->{private_active} && ($sth->{Database}{private_active_fault} // '') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        if ($sth->{private_monthstats}) {
            my $fault = $sth->{Database}{private_monthstats_fault} // '';
            my $fetched = $sth->{private_fetched}++;
            return $sth->set_err(1, 'private monthly fetch failure')
                if $fault eq 'fetch' || ($fault eq 'partial' && $fetched > 0);
        }
        return $sth->SUPER::fetchrow_hashref;
    }
    sub finish {
        my ($sth) = @_;
        $sth->{Database}{private_monthstats_finished}++ if $sth->{private_monthstats};
        $sth->{Database}{private_active_finished}++ if $sth->{private_active};
        return $sth->SUPER::finish;
    }
    sub fetchrow_array {
        my ($sth) = @_;
        if ($sth->{private_active}) {
            my $fault = $sth->{Database}{private_active_fault} // '';
            my $fetched = $sth->{private_fetched}++;
            if ($fault eq 'fetch' || ($fault eq 'partial' && $fetched >= 30)) {
                $sth->set_err(1, 'private active fetch failure');
                return; # DBI array fetch errors return an empty list.
            }
        }
        return $sth->SUPER::fetchrow_array;
    }
    package MB1029::Channel;
    sub get_id {1}
    sub get_timezone {'UTC'}
    package MB1029::Conf;
    sub get {$_[0]{$_[1]}}
}
$INC{'MB1029/DBI.pm'} = __FILE__;

my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub {push @wire, ['public', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::botNotice = sub {push @wire, ['notice', $_[1], $_[2]]; 1};
local *Mediabot::UserCommands::logBot = sub {1};
local $SIG{__WARN__} = sub {push @warnings, @_};

sub setup_1402 {
    my ($channel) = @_;
    $channel //= '#test';
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass=>'MB1029::DBI', RaiseError=>1, PrintError=>0, AutoCommit=>1,
        sqlite_unicode=>1,
    });
    $db->sqlite_create_function('DATE_FORMAT', 2, sub {substr($_[0], 0, 7)});
    # The stats projection now asks SQL for the epoch paired with its date.
    # This private fixture's SQL calendar is UTC, independent of host TZ.
    $db->sqlite_create_function('UNIX_TIMESTAMP', 1, sub {
        my ($value)=@_;
        return undef unless defined($value)
            && $value =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\z/;
        my ($y,$m,$d,$h,$min,$sec)=($1,$2,$3,$4,$5,$6);
        require Time::Local;
        return Time::Local::timegm($sec,$min,$h,$d,$m-1,$y);
    });
    $db->sqlite_create_function('regexp', 2, sub {
        my ($pattern, $text) = @_;
        return defined($text) && $text =~ /$pattern/ ? 1 : 0;
    });
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT)');
    $db->do('INSERT INTO CHANNEL VALUES(1, ?), (2, ?)', undef, $channel, '#other');
    $db->do('CREATE TABLE CHANNEL_LOG(id_channel_log INTEGER PRIMARY KEY,
        id_channel INTEGER, nick TEXT COLLATE NOCASE, ts TEXT, event_type TEXT, publictext TEXT)');
    $db->do('CREATE TABLE USER_SEEN(nick TEXT, seen_at TEXT, event_type TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER, nickname TEXT)');
    $db->do('CREATE TABLE KARMA(id_channel INTEGER, nick TEXT, score INTEGER)');
    my $bot = Mediabot->new({});
    $bot->{dbh} = $db;
    $bot->{channels}{lc $channel} = bless {}, 'MB1029::Channel';
    return ($bot, $db);
}
sub add_1402 {
    my ($db, $nick, $count, $text, $month, $channel, $type) = @_;
    $db->do('INSERT INTO CHANNEL_LOG(id_channel, nick, ts, event_type, publictext) VALUES(?, ?, ?, ?, ?)', undef,
        $channel//1, $nick, ($month//'2026-10').'-01 12:00:00', $type//'public', $text//'hello')
        for 1..$count;
}
sub invoke_1402 {
    my ($bot, $command, $nick, @args) = @_;
    return invoke_on_1402($bot, '#test', $command, $nick, @args);
}
sub invoke_on_1402 {
    my ($bot, $channel, $command, $nick, @args) = @_;
    @wire=();
    my $ctx = Mediabot::Context->new(bot=>$bot, command=>$command,
        nick=>$nick, channel=>$channel, args=>\@args);
    $bot->command_registry->handler_for($command, 'public')->($ctx);
    return [map {[@$_]} @wire];
}
sub bars_1402 {chr(0x2588) x $_[0] . chr(0x2591) x (4-$_[0])}
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 3, 'hi', '2026-09');
    add_1402($db, 'bOB', 2, 'waves', '2026-09', undef, 'action');
    add_1402($db, 'ALICE', 2, 'waves', '2026-10', undef, 'action');
    add_1402($db, 'Bob', 4, 'hi', '2026-10');
    add_1402($db, 'Alice', 20, 'unrelated channel', '2026-10', 2);
    add_1402($db, 'Alice', 20, 'outside window', '2020-01');
    # MB1383: presence and channel state must not inflate bars or create a month.
    add_1402($db, 'Alice', 12, undef, '2026-10', undef, 'join');
    add_1402($db, 'Bob', 15, undef, '2026-10', undef, 'mode');
    add_1402($db, 'ALICE', 1, undef, '2026-08', undef, 'part');
    add_1402($db, 'Quiet', 1, undef, '2026-10', undef, 'join');
    add_1402($db, 'Quiet', 1, undef, '2026-10', undef, 'quit');
    $db->do('PRAGMA query_only = ON');
    my $before = $db->selectall_arrayref('SELECT * FROM CHANNEL_LOG');
    my $expected = [
        ['public', '#test', 'alice vs bob on #test (last 12 months):'],
        ['public', '#test', '  alice//bob — 2026-09 '.bars_1402(3).'/'.bars_1402(2)
            .'  2026-10 '.bars_1402(2).'/'.bars_1402(4)],
    ];
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'Alice', 'vs', 'Bob'), $expected,
        'monthly comparison counts messages and actions with mixed case, channel and date scope');
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'ALICE', 'VS', 'bOB'), $expected,
        'changing requested nickname case cannot change the monthly chart');
    my $single = invoke_1402($bot, 'monthstats', 'Caller', 'Alice');
    is_deeply($single, [
        ['public', '#test', 'alice on #test (last 12 months):'],
        ['public', '#test', '  2026-09 '.chr(0x2588)x5 .' 3  2026-10 '
            .chr(0x2588)x3 .chr(0x2591)x2 .' 2'],
    ], 'single-nickname chart scales speech counts and excludes presence-only months');
    is_deeply(invoke_1402($bot, 'monthstats', 'Quiet'), [
        ['public', '#test', 'quiet: no data in last 12 months on #test.'],
    ], 'a caller with only presence events has no monthly speech data');
    is_deeply(invoke_1402($bot, 'monthstats', 'Caller', 'Quiet', 'vs', 'Absent'), [
        ['public', '#test', 'No data found for quiet or absent on #test.'],
    ], 'a comparison with only presence events has no monthly speech data');
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
# MB1380: the caller's bonus rank uses the same channel types as IRC routing.
for my $channel ('#test', '&test', '+test', '!test') {
    my ($bot, $db) = setup_1402($channel);
    add_1402($db, 'Leader', 3);
    add_1402($db, 'Caller', 1, 'waves', undef, undef, 'action');
    add_1402($db, 'Caller', 5, 'elsewhere', undef, 2);
    add_1402($db, 'Caller', 7, undef, undef, undef, 'join');
    $db->do('PRAGMA query_only = ON');
    my @ranking = (
        ['public', $channel, "Top 1 on $channel (4 msgs):"],
        ['public', $channel, sprintf('  1. %-16s 3 msgs (75.0%%)', 'Leader')],
    );
    is_deeply(invoke_on_1402($bot, $channel, 'top', 'cALLER', '1'), [
        @ranking, ['public', $channel, '  (your rank: #2 — 1 msg(s), 25.0%)'],
    ], "top adds the caller's own scoped rank on $channel");
    is_deeply(invoke_on_1402($bot, $channel, 'top', 'Leader', '1'), \@ranking,
        "top does not repeat a caller already displayed on $channel");
    is_deeply(invoke_on_1402($bot, $channel, 'top', 'Absent', '1'), \@ranking,
        "top does not report a rank for a caller without messages on $channel");
}
# MB1381: a caller tied at the cutoff keeps a distinct place in top's ordering.
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Leader', 4);
    add_1402($db, 'Alpha', 2);
    add_1402($db, 'Zulu', 1);
    add_1402($db, 'ZULU', 1, 'waves', undef, undef, 'action');
    $db->do('PRAGMA query_only = ON');
    my $leader = ['public', '#test', sprintf('  1. %-16s 4 msgs (50.0%%)', 'Leader')];
    my $alpha = ['public', '#test', sprintf('  2. %-16s 2 msgs (25.0%%)', 'Alpha')];
    my $personal = ['public', '#test', '  (your rank: #3 — 2 msg(s), 25.0%)'];
    is_deeply(invoke_1402($bot, 'top', 'ZULU', '2'), [
        ['public', '#test', 'Top 2 on #test (8 msgs):'], $leader, $alpha, $personal,
    ], 'top reports the caller tied with the last displayed nickname at the next position');
    is_deeply(invoke_1402($bot, 'top', 'ZULU', '1'), [
        ['public', '#test', 'Top 1 on #test (8 msgs):'], $leader, $personal,
    ], 'a tie below the cutoff still uses the same position and case-folded ordering');
    is_deeply(invoke_1402($bot, 'top', 'ZULU', '3'), [
        ['public', '#test', 'Top 3 on #test (8 msgs):'], $leader, $alpha,
        ['public', '#test', sprintf('  3. %-16s 2 msgs (25.0%%)', 'Zulu')],
    ], 'including the tied caller in the main rows shows the same rank without a duplicate');
}
# MB1382: numeric activity options use the same digit alphabet as Perl and SQL.
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 3);
    add_1402($db, 'Bob', 1);
    add_1402($db, 'Alice', 5, 'outside the interval', '2026-09');
    $db->do('PRAGMA query_only = ON');

    my $digits = 'Use ASCII digits (0-9) for numeric arguments.';
    my @invalid = (
        ['top',     ['٢'],                       $digits],
        ['top',     ['1２'],                      $digits],
        ['top',     ['1٢H'],                      $digits],
        ['top',     ['2', 'nobots', '２d'],         $digits],
        ['active',  ['٢٤H'],                      $digits],
        ['active',  ['1２d'],                      $digits],
        ['compare', ['Alice', 'Bob', '1٢W'],      "Unknown period '1٢w'. Use: 7d, 4w, 3m, 1y, all"],
        ['compare', ['Alice', 'Bob', '２y'],       "Unknown period '２y'. Use: 7d, 4w, 3m, 1y, all"],
    );
    for my $case (@invalid) {
        my ($command, $args, $notice) = @$case;
        my $before_queries = scalar @{$db->{private_queries}};
        my $before_warnings = scalar @warnings;
        my $output = invoke_1402($bot, $command, 'Caller', @$args);
        is_deeply([$output, scalar(@{$db->{private_queries}}) - $before_queries,
            scalar(@warnings) - $before_warnings], [[['notice', 'Caller', $notice]], 0, 0],
            "$command @$args rejects non-ASCII digits privately before query or conversion");
    }
    is_deeply(invoke_1402($bot, 'top', 'Alice', '002', '024H'), [
        ['public', '#test', 'Top 2 on #test (last 024h) (4 msgs):'],
        ['public', '#test', sprintf('  1. %-16s 3 msgs (75.0%%)', 'Alice')],
        ['public', '#test', sprintf('  2. %-16s 1 msg (25.0%%)', 'Bob')],
    ], 'top still accepts an ASCII zero-padded limit and a case-insensitive relative period');
    is_deeply(invoke_1402($bot, 'active', 'Alice', '024H'), [
        ['public', '#test', 'Active in last 024h on #test: Alice(3), Bob(1) (2 nick(s))'],
    ], 'active retains the time filter for an ASCII zero-padded period');
    is_deeply(invoke_1402($bot, 'compare', 'Alice', 'Alice', 'Bob', '02W'), [
        ['public', '#test', '[last 02w] alice: 3 msg(s) (75%) | bob: 1 msg(s) (25%) | alice leads by 2 msg(s)'],
    ], 'compare still multiplies a valid ASCII week count and retains the period label');
}
# MB1384: last must break same-second ties before LIMIT and after merging.
{
    my ($bot, $db) = setup_1402();
    $db->do("ATTACH DATABASE ':memory:' AS history");
    $db->do('CREATE TABLE history.CHANNEL_LOG_ARCHIVE(id_channel_log INTEGER PRIMARY KEY,
        id_channel INTEGER, nick TEXT COLLATE NOCASE, ts TEXT, event_type TEXT, publictext TEXT)');
    my $ts = '2026-10-01 12:00:00';
    for my $row (
        [101, 1, 'Alice', $ts, 'public', 'live one'],
        [102, 1, 'alice', $ts, 'public', 'live two'],
        [105, 1, 'Alice', $ts, 'public', 'live five'],
        [107, 1, 'Alice', '2026-10-01 11:59:59', 'public', 'older despite a higher id'],
        [108, 2, 'Alice', $ts, 'public', 'other channel'],
        [109, 1, 'Bob', $ts, 'public', 'other nick'],
        [110, 1, 'Alice', $ts, 'join', 'presence'],
        [111, 1, 'Alice', $ts, 'public', ''],
    ) {
        $db->do('INSERT INTO CHANNEL_LOG VALUES(?, ?, ?, ?, ?, ?)', undef, @$row);
    }
    for my $row (
        [103, 1, 'Alice', $ts, 'public', 'archive three'],
        [104, 1, 'alice', $ts, 'public', 'archive four'],
        [106, 1, 'ALICE', $ts, 'action', 'archive six'],
    ) {
        $db->do('INSERT INTO history.CHANNEL_LOG_ARCHIVE VALUES(?, ?, ?, ?, ?, ?)', undef, @$row);
    }
    $db->do('PRAGMA query_only = ON');
    is_deeply(invoke_1402($bot, 'last', 'Caller', 'Alice'), [
        ['public', '#test', 'alice last said (30m ago, 12:00 on #test): "live five"'],
    ], 'last takes the newest live row when several messages share a second');
    $bot->{conf} = bless {
        'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'history',
        'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS' => 30,
    }, 'MB1029::Conf';
    is_deeply(invoke_1402($bot, 'last', 'Caller', 'Alice'), [
        ['public', '#test', 'alice last said (30m ago, 12:00 on #test): "archive six"'],
    ], 'last takes the newest row across the live and archive queries');
    is_deeply(invoke_1402($bot, 'last', 'Caller', 'ALICE', '3'), [
        ['public', '#test', 'Last 3 message(s) from alice on #test:'],
        map { ['public', '#test', "  (30m ago [12:00]) $_"] } ('archive four', 'live five', 'archive six'),
    ], 'last 3 applies the merged cutoff and displays tied messages from oldest to newest');
    is_deeply(invoke_1402($bot, 'last', 'Caller', 'Alice', '5'), [
        ['public', '#test', 'Last 5 message(s) from alice on #test:'],
        map { ['public', '#test', "  (30m ago [12:00]) $_"] }
            ('live two', 'archive three', 'archive four', 'live five', 'archive six'),
    ], 'last keeps timestamp priority and the existing channel, author and speech filters');
}
# MB1346: failed reads must not masquerade as empty or partial monthly charts.
for my $raise (0, 1) {
    for my $compare (0, 1) {
        for my $stage (qw(prepare execute fetch partial)) {
            my ($bot, $db) = setup_1402();
            add_1402($db, 'Alice', 3, 'hi', '2026-09');
            add_1402($db, 'Bob', 2, 'hi', '2026-10');
            add_1402($db, 'Alice', 1, 'hi', '2026-10');
            $db->{RaiseError} = $raise;
            $db->{private_monthstats_fault} = $stage;
            $db->{private_monthstats_finished} = 0;
            $db->do('PRAGMA query_only = ON');
            my @args = $compare ? ('Alice', 'vs', 'Bob') : ('Alice');
            my $ok = eval { invoke_1402($bot, 'monthstats', 'Caller', @args); 1 };
            is_deeply([$ok ? '' : $@, \@wire, $db->{private_monthstats_finished}],
                ['', [['notice', 'Caller', 'Database error.']], $stage eq 'prepare' ? 0 : 1],
                "RaiseError=$raise comparison=$compare $stage: contain failure, discard chart and finish statement");
            $db->{private_monthstats_fault} = '';
            my $recovered = invoke_1402($bot, 'monthstats', 'Caller', @args);
            is(scalar(grep { $_->[0] eq 'public' && $_->[2] =~ /2026-09.*2026-10/ } @$recovered), 1,
                'next successful read publishes both months after a transient failure');
        }
    }
}
# MB1347: the displayed top 30 is not the complete set of active nicks.
{
    my ($bot, $db) = setup_1402();
    add_1402($db, "Speaker$_", 33 - $_) for 1..31;
    add_1402($db, 'Old', 1);
    $db->do("UPDATE CHANNEL_LOG SET ts = '2026-10-01 10:00:00' WHERE nick = 'Old'");
    add_1402($db, 'Elsewhere', 50, 'other channel', '2026-10', 2);
    my @online = ('sPEAKER31', 'Quiet', 'Old', 'Elsewhere');
    local *Mediabot::gethChannelsNicksOnChan = sub { @online };
    $db->do('PRAGMA query_only = ON');
    my $out = invoke_1402($bot, 'active', 'Caller', 'now');
    is_deeply($out->[1], ['public', '#test',
        'Present but silent in last 60min: Elsewhere, Old, Quiet (3 nick(s))'],
        'online speaker beyond the top 30 is not silent; channel, time and nick case still apply');
    like($out->[0][2], qr/\AActive in last 60min on #test: .* \(30 nick\(s\)\)\z/,
        'now still displays at most 30 ranked nicks');
    @online = ('sPEAKER31');
    is(scalar(@{invoke_1402($bot, 'active', 'Caller', 'now')}), 1,
        'no silent line when the only online nick is an active speaker beyond the display cap');
    $out = invoke_1402($bot, 'active', 'Caller');
    is_deeply([scalar(@$out), $out->[0][2] =~ /\AActive in last 24h.* \(30 nick\(s\)\)\z/ ? 1 : 0],
        [1, 1], 'ordinary active queries retain their top-30 display without an online comparison');
    for my $raise (0, 1) {
        for my $stage (qw(prepare execute fetch partial)) {
            $db->{RaiseError} = $raise;
            $db->{private_active_fault} = $stage;
            $db->{private_active_finished} = 0;
            my $ok = eval { invoke_1402($bot, 'active', 'Caller', 'now'); 1 };
            is_deeply([$ok ? '' : $@, \@wire, $db->{private_active_finished}],
                ['', [['notice', 'Caller', 'Database error.']], $stage eq 'prepare' ? 0 : 1],
                "active RaiseError=$raise $stage: incomplete reads never classify an unread speaker as silent");
        }
    }
    $db->{private_active_fault} = '';
    @online = ();
    $out = invoke_1402($bot, 'active', 'Caller', 'now');
    is_deeply([scalar(@$out), $out->[0][2] =~ /\AActive in last 60min.* \(30 nick\(s\)\)\z/ ? 1 : 0],
        [1, 1], 'a successful read recovers after faults and retains the cap with no online nicklist');
}
{
    my ($bot, $db) = setup_1402();
    local *Mediabot::gethChannelsNicksOnChan = sub { ('Quiet') };
    is_deeply(invoke_1402($bot, 'active', 'Caller', 'now'), [
        ['public', '#test', 'No activity in last 60min on #test.'],
        ['public', '#test', 'Present but silent in last 60min: Quiet (1 nick(s))'],
    ], 'a confirmed empty hourly result still reports genuine silence');
}
# MB1361: joining or changing channel state is not speaking.
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Alice', 2);
    add_1402($db, 'ALICE', 1, 'waves', undef, undef, 'action');
    add_1402($db, 'Bob', 2, 'waves', undef, undef, 'action');
    add_1402($db, 'Boundary', 1);
    $db->do("UPDATE CHANNEL_LOG SET ts = '2026-10-01 11:00:00' WHERE nick = 'Boundary'");
    add_1402($db, 'Yesterday', 4);
    $db->do("UPDATE CHANNEL_LOG SET ts = '2026-09-30 14:00:00' WHERE nick = 'Yesterday'");
    add_1402($db, 'Old', 30, 'outside both windows', '2020-01');
    add_1402($db, 'Elsewhere', 40, 'other channel', '2026-10', 2);
    for my $type (qw(join part quit nick mode topic kick)) {
        add_1402($db, 'Quiet', 10, 'not a message', undef, undef, $type);
        add_1402($db, 'Alice', 10, 'not a message', undef, undef, $type);
    }
    local *Mediabot::gethChannelsNicksOnChan = sub {
        ('aLICE', 'bOB', 'Boundary', 'Quiet', 'Old', 'Elsewhere', 'Yesterday')
    };
    $db->do('PRAGMA query_only = ON');
    my $before = $db->selectall_arrayref('SELECT * FROM CHANNEL_LOG');
    is_deeply(invoke_1402($bot, 'active', 'Caller', 'now'), [
        ['public', '#test', 'Active in last 60min on #test: Alice(3), Bob(2), Boundary(1) (3 nick(s))'],
        ['public', '#test', 'Present but silent in last 60min: Elsewhere, Old, Quiet, Yesterday (4 nick(s))'],
    ], 'active now counts messages and actions only, preserving hour boundary, channel and nick case');
    is_deeply(invoke_1402($bot, 'active', 'Caller'), [
        ['public', '#test', 'Active in last 24h on #test: Yesterday(4), Alice(3), Bob(2), Boundary(1) (4 nick(s))'],
    ], 'ordinary active rankings also exclude presence events without changing the time window');
    is_deeply($db->selectall_arrayref('SELECT * FROM CHANNEL_LOG'), $before,
        'filtering active reports leaves presence and message history intact');
}
{
    my ($bot, $db) = setup_1402();
    add_1402($db, 'Quiet', 1, undef, undef, undef, 'join');
    local *Mediabot::gethChannelsNicksOnChan = sub { ('Quiet') };
    is_deeply(invoke_1402($bot, 'active', 'Caller', 'now'), [
        ['public', '#test', 'No activity in last 60min on #test.'],
        ['public', '#test', 'Present but silent in last 60min: Quiet (1 nick(s))'],
    ], 'a channel with only a join has no speech activity and retains its silent online nick');
}
# MB1378: the compact active lists are wire-byte budgets, not character counts.
for my $sample (['ASCII','x'], ['accent','é'], ['CJK','界'], ['emoji','😀']) {
    my ($label,$glyph)=@$sample;
    for my $bytes (0,1) {
        my ($bot,$db)=setup_1402();
        my @nicks=map {sprintf('u%02d',$_).($glyph x 10)} 1..20;
        add_1402($db,$nicks[$_],20-$_) for 0..$#nicks;
        $db->{sqlite_unicode}=!$bytes;
        $db->do('PRAGMA query_only = ON');
        my $before=$db->selectall_arrayref('SELECT * FROM CHANNEL_LOG');
        for my $silent (0,1) {
            my @online=$silent?map {s/^u/q/r} @nicks:();
            @online=map {encode('UTF-8',$_)} @online if $bytes;
            local *Mediabot::gethChannelsNicksOnChan=sub {@online};
            my $out=invoke_1402($bot,'active','Caller', $silent?('now'):());
            my $line=$out->[$silent][2];
            my $wire=utf8::is_utf8($line)?encode('UTF-8',$line):$line;
            my $decoded=eval {decode('UTF-8',$wire,FB_CROAK|LEAVE_SRC)};
            my $prefix=$silent?'Present but silent in last 60min: ':'Active in last 24h on #test: ';
            my $suffix=' (20 nick(s))';
            my $list=defined($decoded)&&index($decoded,$prefix)==0
                && substr($decoded,-length($suffix)) eq $suffix
                ?substr($decoded,length($prefix),length($decoded)-length($prefix)-length($suffix)):undef;
            my $original=$silent?join(', ',map {s/^u/q/r} @nicks)
                :join(', ',map {$nicks[$_].'('.(20-$_).')'} 0..$#nicks);
            my $truncated=length(encode('UTF-8',$original))>350;
            my $limit=$silent?353:350; # Existing silent budget appends its three dots.
            diag("$label bytes=$bytes silent=$silent: invalid UTF-8 or exceeded $limit-byte list budget")
                if !defined($list) || length(encode('UTF-8',$list))>$limit;
            my $shown=$list//'';$shown=~s/\.\.\.\z// if $truncated;
            is_deeply([scalar(@$out),$out->[$silent][0],$out->[$silent][1],
                defined($list)?1:0,length(encode('UTF-8',$list//''))<=$limit?1:0,
                $truncated?(($list//'') =~ /\.\.\.\z/?1:0):(($list//'') eq $original?1:0),
                length($shown)>0 && index($original,$shown)==0?1:0],
                [$silent?2:1,'public','#test',1,1,1,1],
                "$label bytes=$bytes silent=$silent: native active output keeps its layout, count, UTF-8 prefix and byte budget");
        }
        is_deeply($db->selectall_arrayref('SELECT * FROM CHANNEL_LOG'),$before,
            "$label bytes=$bytes: compact output never modifies stored activity");
    }
}
# Preserve the exact historical ASCII thresholds, including untruncated 350 bytes.
for my $size (349,350,351) {
    my ($bot,$db)=setup_1402();
    my @nicks=map {sprintf('u%02d',$_).('x' x 19)} 1..15;
    # Make the silent list exactly $size bytes while every nick stays short.
    my $excess=length(join(', ',@nicks))-$size;
    substr($nicks[-1],-$excess)='' if $excess>0;
    my @online=@nicks;
    local *Mediabot::gethChannelsNicksOnChan=sub {@online};
    my $out=invoke_1402($bot,'active','Caller','now');
    my $list=join(', ',@nicks);
    my $expected=$size>350?substr($list,0,350).'...':$list;
    is($out->[1][2],"Present but silent in last 60min: $expected (15 nick(s))",
        "silent ASCII $size-byte boundary keeps its established layout");
}
for my $size (349,350,351) {
    my ($bot,$db)=setup_1402();
    my @nicks=map {sprintf('u%02d',$_).('x' x 19)} 1..13;
    my $list=join(', ',map {$nicks[$_].'('.(13-$_).')'} 0..$#nicks);
    substr($nicks[-1],-(length($list)-$size))='';
    add_1402($db,$nicks[$_],13-$_) for 0..$#nicks;
    $db->do('PRAGMA query_only = ON');
    my $out=invoke_1402($bot,'active','Caller');
    $list=join(', ',map {$nicks[$_].'('.(13-$_).')'} 0..$#nicks);
    my $expected=$size>350?substr($list,0,347).'...':$list;
    is($out->[0][2],"Active in last 24h on #test: $expected (13 nick(s))",
        "ranked ASCII $size-byte boundary keeps its established layout");
}
is_deeply(\@warnings, [], 'native activity handlers emit no warnings');
1;
