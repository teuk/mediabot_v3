use strict;
use warnings;
use Test::More;
use DBI;
use Time::Local qw(timegm);
use Mediabot::Plugin::QuoteServiceV3;
use Mediabot::PluginManager;
use Mediabot::CommandRegistry;

{
    package MB969::DBI; our @ISA = ('DBI');
    package MB969::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @args) = @_;
        my $index = push @{$db->{private_queries}}, $sql;
        die 'quote reads must remain read-only' unless $sql =~ /^\s*SELECT\b/i;
        my $sth = $db->SUPER::prepare($sql, @args);
        $sth->{private_query_index} = $index if $sth;
        return $sth;
    }
    package MB969::DBI::st; our @ISA = ('DBI::st');
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $fault = $sth->{Database}{private_fault};
        if ($fault && $sth->{private_query_index} == $fault->{query}
                && ($sth->{private_delivered}//0) >= $fault->{after}) {
            return $sth->set_err(1, 'private quote fetch detail');
        }
        my $row = $sth->SUPER::fetchrow_hashref;
        $sth->{private_delivered}++ if $row;
        return $row;
    }
    sub finish {
        my ($sth) = @_;
        $sth->{Database}{private_finished}++;
        my $result = $sth->SUPER::finish;
        # A driver may clear its error on cleanup: inspect it before finish.
        $sth->set_err(undef, undef);
        return $result;
    }
    package MB969::Bot;
    sub command_registry { $_[0]{registry} }
    package MB969::Log;
    sub log { push @{$_[0]{lines}}, $_[2]; 1 }
    package MB969::Writes;
    sub recall { $_[0]{recalls}++; return {ok => 1} }
    package MB969::Context;
    sub nick { 'Reader' }
    sub channel { '#test' }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { undef }
    sub message { bless {}, 'MB969::Message' }
    sub reply { push @{$_[0]{replies}}, $_[1]; 1 }
    sub reply_private { push @{$_[0]{notices}}, $_[1]; 1 }
}
$INC{'MB969/DBI.pm'} = __FILE__;

sub setup_1345 {
    my ($raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB969::DBI', RaiseError => $raise, PrintError => 0});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT)');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY, nickname TEXT)');
    $db->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY, id_channel INTEGER,
        id_user INTEGER, quotetext TEXT, ts TEXT, hits INTEGER)});
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do(q{INSERT INTO USER VALUES(7,'Author')});
    $db->do(q{INSERT INTO QUOTES VALUES
        (1,1,7,'needle first','2026-10-01 10:00:00',2),
        (2,1,7,'needle second','2026-10-02 10:00:00',5),
        (3,2,7,'needle other channel','2026-10-03 10:00:00',99)});
    $db->sqlite_create_function('UNIX_TIMESTAMP', 1, sub {
        return undef unless defined $_[0];
        my ($y,$m,$d,$h,$min,$s) = $_[0] =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
        return timegm($s,$min,$h,$d,$m-1,$y);
    });
    return ($db, Mediabot::Plugin::QuoteServiceV3->new(dbh => $db, random_index => sub {0}));
}
sub reset_1345 {
    my ($db, $query, $after) = @_;
    $db->{private_queries} = [];
    $db->{private_finished} = 0;
    $db->{private_fault} = defined($query) ? {query => $query, after => $after} : undef;
}
sub invoke_1345 {
    my ($service, $operation, $channel) = @_;
    return $service->$operation(channel => $channel//'#test', id => 1,
        query => 'needle', author => 'Author', limit => 2);
}

my @operations = qw(by_id count random search by_author random_by_author stats top);
for my $raise (0, 1) {
    my ($db, $service) = setup_1345($raise);
    for my $op (@operations) {
        reset_1345($db);
        my $good = invoke_1345($service, $op);
        ok($good->{ok}, "$op RaiseError=$raise: healthy read succeeds");
        if (exists $good->{record}) {
            is($good->{record}->id, 1, "$op: actual scoped record is retained");
        } elsif (exists $good->{records}) {
            is_deeply([sort map {$_->id} @{$good->{records}}], [1,2],
                "$op: complete result excludes another channel");
        } else {
            is($good->{count}, 2, "$op: healthy aggregate is scoped");
        }
        reset_1345($db);
        my $empty = invoke_1345($service, $op, '#empty');
        ok($empty->{ok}, "$op: confirmed absence stays successful");
        ok(exists($empty->{record}) ? !defined($empty->{record})
            : exists($empty->{records}) ? !@{$empty->{records}} : $empty->{count} == 0,
            "$op: confirmed absence keeps its existing representation");

        for my $query (1, ($op =~ /^(?:random|random_by_author|stats)$/ ? 2 : ())) {
            for my $after (0, 1) {
                reset_1345($db, $query, $after);
                my $result;
                my $ok = eval { $result = invoke_1345($service, $op); 1 };
                my $error = $@;
                my $label = "$op query=$query after=$after RaiseError=$raise";
                ok(!$ok, "$label: incomplete read is rejected");
                is($error, "QuoteServiceV3: data service unavailable\n",
                    "$label: fixed error without raw driver details");
                ok(!defined($result), "$label: neither empty nor partial success escapes");
                is($db->{private_finished}, $query, "$label: every prepared cursor is finished");
                is(scalar @{$db->{private_queries}}, $query, "$label: failed read stops later queries");
            }
        }
    }

    my $writes = bless {recalls => 0}, 'MB969::Writes';
    my $bot = bless {registry => Mediabot::CommandRegistry->new,
        logger => bless({lines => []}, 'MB969::Log')}, 'MB969::Bot';
    for my $name (qw(q quote quotecount topquote halloffame)) {
        $bot->{registry}->register_command(name => $name, source => 'public',
            handler => sub {die 'on mode must not fall back to the native handler'},
            category => 'core', metadata => {builtin => 1, dispatch => 'registry',
                syntax => $name, migration_fallback => 1});
    }
    my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => 'plugins',
        v3_quote_service => $service, v3_quote_write_service => $writes);
    $manager->load_package_v3('quotes-v3', grants => [
        qw(data.quotes.read data.quotes.write irc.reply irc.notice)]);
    $manager->set_v3_channel_policy('quotes-v3', '#test', mode => 'on');
    $manager->enable('quotes-v3');
    for my $case (
        ['q', ['v',1], 1, 'Database error while reading quote.'],
        ['q', ['s','needle'], 1, 'Database error during search.'],
        ['q', ['r'], 3, 'Database error while reading quote.'],
        ['q', ['stats'], 2, 'Database error while reading quote stats.'],
        ['quote', ['Author'], 2, 'Database error while reading quote.'],
        ['quotecount', [], 1, 'Database error.'],
        ['topquote', [], 1, 'topquote: database unavailable.'],
    ) {
        my ($name, $args, $query, $notice) = @$case;
        reset_1345($db, $query, 1);
        my $ctx = bless {command => $name, args => $args, replies => [], notices => []}, 'MB969::Context';
        my $handler = $bot->{registry}->handler_for($name, 'public');
        my $ok = eval {$handler->($ctx); 1};
        my $label = "$name @$args RaiseError=$raise";
        ok($ok, "$label: actual command contains the data failure");
        is_deeply($ctx->{notices}, [$notice], "$label: command reports the existing database error");
        is_deeply($ctx->{replies}, [], "$label: no partial citation or misleading public response");
        is($writes->{recalls}, 0, "$label: failed reads cannot increment recall counters");
        unlike(join('\n', @{$bot->{logger}{lines}}), qr/private quote fetch detail/,
            "$label: driver details do not reach runtime logs");
    }
    reset_1345($db);
    my $ctx = bless {command => 'q', args => ['v',1], replies => [], notices => []}, 'MB969::Context';
    $bot->{registry}->handler_for('q', 'public')->($ctx);
    like(join(' ', @{$ctx->{replies}}), qr/needle first/, 'healthy command recovers with actual quote');
    is_deeply($ctx->{notices}, [], 'healthy command has no database error notice');
    is($writes->{recalls}, 1, 'only the healthy recall reaches the existing accounting service');
    $manager->unregister_plugin('quotes-v3');
}
done_testing;
