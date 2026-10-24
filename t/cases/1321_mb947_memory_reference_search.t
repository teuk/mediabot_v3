use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode FB_CROAK);
use Mediabot::UserCommands;
use Mediabot::Context;

{
    package MB947::Channel;
    sub get_id { $_[0]{id} }
    package MB947::Conf;
    sub get { $_[0]{$_[1]} }
    package MB947::DB;
    sub prepare {
        my ($db, $sql) = @_;
        my $kind = $sql =~ /FROM QUOTES/ ? 'quotes' : 'factoids';
        push @{$db->{reads}}, {sql => $sql, kind => $kind};
        die 'private prepare error' if ($db->{failure} // '') eq "$kind.prepare";
        my $rows = $db->{$kind};
        return bless {db => $db, kind => $kind, rows => [map { +{%$_} } @$rows]}, 'MB947::Statement';
    }
    package MB947::Statement;
    sub execute {
        my ($s, @bind) = @_;
        $s->{db}{reads}[-1]{bind} = \@bind;
        return if ($s->{db}{failure} // '') eq "$s->{kind}.execute";
        return 1;
    }
    sub fetchrow_hashref {
        my ($s) = @_;
        die 'private fetch error' if ($s->{db}{failure} // '') eq "$s->{kind}.fetch";
        return shift @{$s->{rows}};
    }
    sub err { ($_[0]{db}{failure} // '') eq "$_[0]{kind}.err" ? 1 : 0 }
    sub finish { $_[0]{db}{finished}++; 1 }
    package MB947::Wrapper;
    sub ensure_connected { $_[0]{dbh} }
}

my (@notices, %gates, $gate_error);
my $make = sub {
    @notices = (); %gates = (OnThisDay => 1, Factoids => 1); $gate_error = '';
    return {
        dbh => bless({reads => [], quotes => [
            {id => 42, text => 'Le café du salon', author => 'Alice', date => '2024-02-29'},
            {id => 41, text => 'A saved anonymous quote', author => 'Unknown', date => '2023-03-01'},
        ], factoids => [
            {keyword => 'cafe', text => 'Our café reference', author => 'Pablo', date => '2026-10-24'},
        ]}, 'MB947::DB'),
        channels => {'#test' => bless({id => 37}, 'MB947::Channel')},
        conf => bless({'main.MAIN_PROG_CMD_CHAR' => '!'}, 'MB947::Conf'),
    };
};
my $run = sub {
    my ($bot, $args, $channel) = @_;
    return Mediabot::UserCommands::mbMemory_ctx(Mediabot::Context->new(
        bot => $bot, nick => 'Max_', channel => $channel // '#test',
        command => 'memory', args => $args // ['find', 'café']));
};
my $output = sub { join '\n', map { $_->[1] } @notices };
{
    no warnings 'redefine';
    local *Mediabot::Helpers::chanset_enabled = sub {
        my ($bot, $channel, $name) = @_;
        die 'policy unavailable' if $gate_error eq $name;
        return $gates{$name};
    };
    local *Mediabot::UserCommands::botNotice = sub { push @notices, [$_[1], $_[2]]; 1 };
    local *Mediabot::UserCommands::botPrivmsg = sub { die 'search must stay private' };
    local *Mediabot::Helpers::channel_log_gather = sub { die 'search must not read raw channel logs' };

    my $bot = $make->();
    ok($run->($bot), 'native memory find reads saved channel references');
    is(scalar @{$bot->{dbh}{reads}}, 2, 'one bounded read for each enabled collection');
    is(scalar @notices, 3, 'one short private result per matching reference');
    ok(@notices && !grep({ $_->[0] ne 'Max_' } @notices), 'all results go only to the requesting nick');
    like($output->(), qr/!q view 42 \| 2024-02-29 \| by Alice \| Le café du salon/,
        'quote carries stable recall command, date, author and Unicode excerpt');
    like($output->(), qr/!q view 41.*by Unknown/, 'anonymous quotes retain neutral attribution');
    like($output->(), qr/!factoid cafe \| 2026-10-24 \| by Pablo/,
        'factoid links to private detail and can be current, unlike historical day selection');
    ok(!grep({$_->{bind}[0] != 37 || $_->{sql} !~ /WHERE [qf]\.id_channel = \?/} @{$bot->{dbh}{reads}}),
        'both collections bind only the known current channel identity');
    ok(!grep({$_->{sql} !~ /LIMIT 4/ || $_->{sql} !~ /LEFT\(.*512/} @{$bot->{dbh}{reads}}),
        'SQL caps both returned rows and excerpt fields');
    ok(!grep({$_->{sql} =~ /CHANNEL_LOG|UPDATE|INSERT|DELETE|hits\s*=/i} @{$bot->{dbh}{reads}}),
        'lookup never reads raw conversation logs or changes counters and records');
    is($bot->{dbh}{finished}, 2, 'both successful reads release their statements');

    $bot = $make->(); $run->($bot, ['find', '50%_!', "O'Reilly"]);
    is_deeply($bot->{dbh}{reads}[0]{bind}, [37, '%50!%!_!!%', "%O'Reilly%"],
        'quotes bind literal percent, underscore, escape character and apostrophe');
    is_deeply($bot->{dbh}{reads}[1]{bind}, [37, '%50!%!_!!%', '%50!%!_!!%', "%O'Reilly%", "%O'Reilly%"],
        'each factoid word can match keyword or value, with literal LIKE metacharacters');
    like($bot->{dbh}{reads}[1]{sql} // '', qr/\) AND \(f\.keyword LIKE/,
        'multiple words must all match rather than broadening into unrelated results');
    unlike(join(' ', map { $_->{sql} } @{$bot->{dbh}{reads}}), qr/50%_|O'Reilly/,
        'search text never becomes SQL syntax');

    $bot = $make->(); $bot->{conf}{'main.MAIN_PROG_CMD_CHAR'} = '.'; $run->($bot);
    like($output->(), qr/\.q view 42.*\.factoid cafe/, 'recall links follow the actual command prefix');
    $bot = $make->(); $bot->{conf}{'main.MAIN_PROG_CMD_CHAR'} = "!\n"; $run->($bot);
    like($output->(), qr/!q view 42/, 'an invalid configured prefix cannot inject a command line');

    $bot = $make->(); $gates{Factoids} = 0; $run->($bot);
    is(scalar @{$bot->{dbh}{reads}}, 1, '-Factoids prevents any factoid read');
    like($output->(), qr/not searched/, 'a disabled collection is not presented as empty');
    unlike($output->(), qr/Our café|!factoid cafe/, 'disabled factoid content never appears');
    $bot = $make->(); $gate_error = 'Factoids'; $run->($bot);
    is(scalar @{$bot->{dbh}{reads}}, 1, 'unavailable Factoids policy also refuses that collection');
    for my $state (qw(disabled unavailable)) {
        $bot = $make->();
        $gates{OnThisDay} = 0 if $state eq 'disabled';
        $gate_error = 'OnThisDay' if $state eq 'unavailable';
        $run->($bot);
        is(scalar @{$bot->{dbh}{reads}}, 0, "$state memory policy prevents all content reads");
        is(scalar @notices, 0, "$state memory policy does not leak results");
    }

    for my $args (['find'], ['find', 'x'], ['find', 'a' x 161],
        ['find', ('word') x 7], ['find', ('é') x 81], ['find', "hello\nworld"],
        ['find', "hi\x03there"], ['find', {}], ['find', undef]) {
        $bot = $make->(); $run->($bot, $args);
        is(scalar @{$bot->{dbh}{reads}}, 0, 'invalid or over-budget input cannot start a search');
        like($output->(), qr/Syntax: memory find/, 'invalid search input gets useful syntax');
    }
    $bot = $make->(); $run->($bot, ['FIND', 'hello', 'world']);
    is(scalar @{$bot->{dbh}{reads}}, 2, 'find subcommand is case insensitive');
    for my $channel ('Max_', '#other') {
        $bot = $make->(); $run->($bot, ['find', 'hello'], $channel);
        is(scalar @{$bot->{dbh}{reads}}, 0, 'PM and unknown channel cannot select another channel');
    }
    $bot = $make->(); $bot->{channels}{'#test'}{id} = '37 OR 1=1'; $run->($bot);
    is(scalar @{$bot->{dbh}{reads}}, 0, 'malformed channel identity has no database fallback');

    $bot = $make->(); $bot->{dbh}{quotes} = []; $bot->{dbh}{factoids} = []; $run->($bot);
    is_deeply(\@notices, [['Max_', 'Quotes: no matches.'], ['Max_', 'Factoids: no matches.']],
        'genuinely empty collections are distinguished individually');
    for my $failure (qw(quotes.prepare quotes.execute quotes.fetch quotes.err factoids.execute)) {
        $bot = $make->(); $bot->{dbh}{failure} = $failure; $run->($bot);
        like($output->(), qr/lookup unavailable/, "$failure stays an explicit collection failure");
        unlike($output->(), qr/no matches|private .* error/, 'failure neither fabricates emptiness nor exposes raw errors');
        like($output->(), $failure =~ /^quotes/ ? qr/!factoid cafe/ : qr/!q view 42/,
            'the independently available collection remains useful');
    }
    $bot = $make->(); $bot->{db} = bless({dbh => $bot->{dbh}}, 'MB947::Wrapper');
    $bot->{dbh} = bless({reads => [], quotes => [], factoids => []}, 'MB947::DB');
    $run->($bot);
    like($output->(), qr/!q view 42/, 'search uses the current reconnected handle, not a stale compatibility handle');
    is(scalar @{$bot->{dbh}{reads}}, 0, 'stale handle remains untouched');
    $bot = $make->(); $bot->{db} = bless({}, 'MB947::Wrapper'); $run->($bot);
    like($output->(), qr/database unavailable/, 'failed reconnection cannot fall back to a stale handle');
    is(scalar @{$bot->{dbh}{reads}}, 0, 'failed reconnection performs no data reads');

    $bot = $make->();
    $bot->{dbh}{quotes} = [map { +{id => $_, text => 'q' x 1000, author => 'A', date => '2020-01-01'} } 1..4];
    $bot->{dbh}{factoids} = [map { +{keyword => "key$_", text => 'f' x 1000, author => 'B'} } 1..4];
    $run->($bot);
    is(scalar @notices, 8, 'at most three results and one refinement hint per collection');
    is(scalar(grep { $_->[1] =~ /refine your search/ } @notices), 2, 'a fourth match is a sentinel, not a false exact total');
    unlike($output->(), qr/!q view 4\b|!factoid key4\b/, 'overflow rows are never dumped');
    ok(!grep({ length(encode('UTF-8', $_->[1])) > 310 } @notices), 'long excerpts keep complete recall links within one short NOTICE');
    $bot = $make->(); $bot->{dbh}{quotes} = [map { +{id=>$_} } 1..5]; $run->($bot);
    like($output->(), qr/Quotes: lookup unavailable/, 'an unexpected driver row overflow cannot become an unbounded response');

    $bot = $make->();
    $bot->{dbh}{quotes}[0]{text} = encode('UTF-8', ('été ') x 70) . "\r\n\x01ACTION hidden\x01";
    $bot->{dbh}{quotes}[0]{author} = "Alice\x03\x01";
    $run->($bot);
    like($notices[0][1] // '', qr/été/, 'legacy UTF-8 byte fields are decoded once');
    ok(!grep({ $_->[1] =~ /[\x00-\x1f\x7f]/ } @notices), 'stored formatting, CTCP and line breaks cannot style or split output');
    ok(eval { decode('UTF-8', encode('UTF-8', $notices[0][1]), FB_CROAK); 1 }, 'Unicode truncation stays valid at the wire boundary');
    $bot = $make->(); $bot->{dbh}{factoids}[0]{keyword} = "cafe\n!forget other"; $run->($bot);
    like($output->(), qr/Factoids: lookup unavailable/, 'malformed stored keys never create misleading recall commands');
}
done_testing;
