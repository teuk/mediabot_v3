use strict;
use warnings;
use Test::More;
use Mediabot::UserCommands;
use Mediabot::Context;

{
    package MB946::Channel;
    sub get_id { 37 }
    package MB946::Conf;
    sub get { $_[0]{$_[1]} }
}

my (@queries, @notices, $failure, $empty, $enabled);
my $make = sub {
    @queries = (); @notices = (); $failure = ''; $empty = 0; $enabled = 1;
    return { dbh => bless({}, 'MB946::DB'),
        channels => { '#test' => bless({}, 'MB946::Channel') },
        conf => bless({'main.MAIN_PROG_CMD_CHAR' => '!'}, 'MB946::Conf') };
};
my $run = sub {
    my ($bot, $args, $channel) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Pablo',
        channel => $channel || '#test', command => 'memory', args => $args);
    return Mediabot::UserCommands::mbMemory_ctx($ctx);
};

{
    no warnings 'redefine';
    local *Mediabot::Helpers::chanset_enabled = sub { $enabled };
    local *Mediabot::UserCommands::botNotice = sub { push @notices, [$_[1], $_[2]]; 1 };
    local *Mediabot::UserCommands::botPrivmsg = sub { die 'memory cannot broadcast channel history' };
    local *Mediabot::Helpers::channel_log_gather = sub {
        my ($bot, $dbh, $sql, $bind, $callback, $scope) = @_;
        push @queries, { sql => $sql, bind => [@$bind], scope => $scope };
        die 'wrong channel identity' unless $bind->[0] == 37;
        die 'wrong archive policy' unless $scope eq 'content';
        my $stage = $sql =~ /COUNT\(\*\) AS msgs/ ? 'summary'
            : $sql =~ /GROUP BY nick/ ? 'voices'
            : $sql =~ /CHAR_LENGTH\(publictext\)/ ? 'excerpt' : 'selection';
        return {live_ok => 0, tainted => 0} if $failure eq $stage;
        if ($stage eq 'selection') {
            $callback->({ts => '2024-02-29 10:00:00', uts => 1709200800}, 'CHANNEL_LOG');
        }
        elsif ($stage eq 'summary') {
            my $day = $bind->[1];
            # Model the database's calendar boundary, not the host timezone.
            my $age_guard = $sql =~ /ts < CURDATE\(\) - INTERVAL 30 DAY/;
            unless ($empty || ($age_guard && $day ge '2026-09-24')) {
                $callback->({msgs => 2, people => 2}, 'CHANNEL_LOG');
                $callback->({msgs => 5, people => 3}, 'archive.CHANNEL_LOG_ARCHIVE');
            }
        }
        elsif ($stage eq 'voices') {
            $callback->({nick => 'Alice', c => 2}, 'CHANNEL_LOG');
            $callback->({nick => 'Alice', c => 5}, 'archive.CHANNEL_LOG_ARCHIVE');
            $callback->({nick => 'Bob', c => 1}, 'archive.CHANNEL_LOG_ARCHIVE');
        }
        else {
            $callback->({nick => 'Alice', event_type => 'public',
                publictext => 'A remembered channel sentence with enough context.'},
                'archive.CHANNEL_LOG_ARCHIVE');
        }
        return {live_ok => 1, tainted => 0};
    };

    my $bot = $make->();
    ok($run->($bot, ['2024-02-29']), 'a valid leap day can be revisited through the native public command');
    is(scalar @notices, 3, 'one request returns at most a summary, excerpt and navigation line');
    ok(@notices && !grep({ $_->[0] ne 'Pablo' } @notices), 'every result remains a private notice to the caller');
    like(join(' ', map { $_->[1] } @notices), qr/2024-02-29: 7 messages, 3 people, most active: Alice/,
        'the requested day merges live and allowed archive activity');
    like(join(' ', map { $_->[1] } @notices), qr/remembered channel sentence/,
        'a permitted archive excerpt accompanies the day');
    like($notices[-1][1] // '', qr/!memory 2024-02-29.*!onthisday 02-29.*!yearbook 2024/,
        'the day links to repeat lookup, calendar anniversary and annual community summary');
    is(scalar @queries, 3, 'a chosen date bypasses first/last/random timestamp selection');
    ok(@queries && !grep({ $_->{scope} ne 'content' || $_->{bind}[0] != 37 } @queries),
        'all reads keep the current channel identity and archive content policy');
    ok(@queries && !grep({ $_->{bind}[1] ne '2024-02-29' } @queries),
        'the requested date is bound to every day query');
    ok(@queries && !grep({ $_->{sql} !~ /ts < DATE_ADD\(\?, INTERVAL 1 DAY\)/ } @queries),
        'the date remains an indexed half-open day range');

    for my $args (['2023-02-29'], ['1900-02-29'], ['2024-04-31'], ['2024-00-10'],
        ['2024-12-00'], ['2024-1-01'], ['0000-01-01'], ["2024-02-29\n"],
        ['2024-02-29 OR 1=1'], ['2024-02-29', 'extra'], [{}]) {
        $bot = $make->(); $run->($bot, $args);
        is(scalar @queries, 0, 'malformed dates and extra arguments never reach historical storage');
        like($notices[0] ? $notices[0][1] : '', qr/Syntax: memory \[YYYY-MM-DD\]/,
            'invalid calendar input gets explicit syntax instead of a random memory');
    }
    $bot = $make->();
    $run->($bot, ['2000-02-29']);
    like($notices[0] ? $notices[0][1] : '', qr/2000-02-29:/, 'Gregorian century leap days remain valid');

    for my $day ('2026-09-24', '2026-10-24', '2099-01-01') {
        $bot = $make->(); $run->($bot, [$day]);
        is(scalar @notices, 1, 'recent and future dates cannot disclose an excerpt');
        like($notices[0] ? $notices[0][1] : '', qr/No suitable.*older than 30 days.*\Q$day\E/,
            'the existing thirty-day exclusion also applies to targeted lookup');
    }

    $bot = $make->(); $empty = 1; $run->($bot, ['2024-03-01']);
    like($notices[0] ? $notices[0][1] : '', qr/No suitable.*2024-03-01/,
        'an empty requested day never silently substitutes another day');
    is(scalar @queries, 1, 'an empty day stops after its bounded summary read');
    for my $stage (qw(summary voices excerpt selection)) {
        $bot = $make->(); $failure = $stage;
        $run->($bot, $stage eq 'selection' ? [] : ['2024-02-29']);
        is_deeply(\@notices, [['Pablo', 'memory: history lookup unavailable.']],
            "$stage failure is reported as unavailable rather than fabricated empty history");
    }

    $bot = $make->(); $bot->{conf}{'main.MAIN_PROG_CMD_CHAR'} = '.';
    $run->($bot, ['2024-02-29']);
    like($notices[-1] ? $notices[-1][1] : '', qr/\.memory 2024-02-29.*\.onthisday 02-29.*\.yearbook 2024/,
        'navigation follows the actual instance command prefix');
    $bot = $make->(); $run->($bot, ['1999-12-31']);
    unlike($notices[-1] ? $notices[-1][1] : '', qr/yearbook/,
        'navigation does not advertise an annual year outside yearbook support');

    $bot = $make->(); $run->($bot, []);
    like($notices[0] ? $notices[0][1] : '', qr/2024-02-29:/, 'no argument retains the native random journey');
    like($notices[-1] ? $notices[-1][1] : '', qr/!memory 2024-02-29/,
        'a randomly discovered day can be revisited explicitly');
    ok(scalar @queries > 3, 'the random path retains its bounded seek selection');

    $bot = $make->(); $enabled = 0; $run->($bot, ['2024-02-29']);
    is(scalar @queries, 0, 'a disabled OnThisDay feature cannot be bypassed with a date');
    is(scalar @notices, 0, 'disabled history remains silent');
    $bot = $make->(); $run->($bot, ['2024-02-29'], 'Pablo');
    is(scalar @queries, 0, 'private invocation cannot select any channel history');
    $bot = $make->(); $run->($bot, ['2024-02-29'], '#other');
    is(scalar @queries, 0, 'an unknown current channel never falls back to another channel');
}
done_testing;
