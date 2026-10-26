use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Mediabot::Plugin::FactoidWriteServiceV3;
use Mediabot::Plugin::PrincipalV3;
use Mediabot::PluginManager;
use Mediabot::CommandRegistry;

{
    package MB968::DBI; our @ISA = ('DBI');
    package MB968::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $kind = $sql =~ /SELECT/ ? 'read' : $sql =~ /DELETE/ ? 'delete' : 'write';
        push @{$db->{private_queries}}, $kind;
        my $sth = $db->SUPER::prepare(
            ($db->{private_fault}//'') eq "$kind.prepare"
                ? 'SELECT * FROM mb968_missing_table' : $sql, @rest);
        $sth->{private_kind} = $kind if $sth;
        return $sth;
    }
    package MB968::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        my $db = $sth->{Database};
        my $kind = $sth->{private_kind};
        if ($kind eq 'delete' && $db->{private_before_delete}) {
            my $before = delete $db->{private_before_delete};
            $before->();
        }
        return $sth->set_err(1, 'private execute detail')
            if ($db->{private_fault}//'') eq "$kind.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        return $sth->set_err(1, 'private fetch detail') if $fault eq 'read.fetch';
        my $row = $sth->SUPER::fetchrow_hashref;
        $sth->set_err(1, 'private late fetch detail') if $fault eq 'read.after_fetch';
        return $row;
    }
    sub rows {
        my ($sth) = @_;
        my $fault = $sth->{Database}{private_fault}//'';
        return $sth->set_err(1, 'private row-count detail') if $fault eq 'delete.rows';
        if ($fault eq 'delete.rows_with_error') {
            $sth->set_err(1, 'private row-count detail');
            return 0;
        }
        return -1 if $fault eq 'delete.unknown_rows';
        return $sth->SUPER::rows;
    }
    sub finish {
        my ($sth) = @_;
        $sth->{Database}{private_finished}++;
        return $sth->SUPER::finish;
    }
    package MB968::Log; sub log { 1 }
    package MB968::Bot;
    sub command_registry { $_[0]{registry} }
    sub getUserChannelLevel { 0 }
    package MB968::User;
    sub is_authenticated { 1 }
    sub id { 7 }
    sub nickname { 'Author' }
    sub has_level { $_[1] eq 'User' }
    package MB968::Context;
    sub nick { 'Author_' }
    sub channel { '#test' }
    sub command { $_[0]{command} }
    sub args { $_[0]{args} }
    sub is_private { 0 }
    sub user { bless {}, 'MB968::User' }
    sub message { bless {}, 'MB968::Message' }
    sub reply_private { push @{$_[0]{notices}}, $_[1]; 1 }
    sub reply { die 'factoid writes must use a notice' }
}
$INC{'MB968/DBI.pm'} = __FILE__;
my $tmp = tempdir(CLEANUP => 1);
my $serial = 0;
my $author = Mediabot::Plugin::PrincipalV3->new(
    authenticated => 1, user_id => 7, account => 'Author',
    global_level => 'user', channel_level => 0);

sub setup_1344 {
    my ($raise) = @_;
    my $dsn = 'dbi:SQLite:dbname=' . $tmp . '/' . ++$serial . '.sqlite';
    my $db = DBI->connect($dsn, '', '', {RootClass => 'MB968::DBI',
        RaiseError => $raise, PrintError => 0, AutoCommit => 1});
    my $peer = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT)');
    $peer->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $peer->do(q{CREATE TABLE FACTOID(id_factoid INTEGER PRIMARY KEY,
        id_channel INTEGER, keyword TEXT, value TEXT, created_by INTEGER)});
    $peer->do(q{INSERT INTO FACTOID VALUES
        (10,1,'spell','Original',7),(20,2,'spell','Other channel',8)});
    $db->{private_queries} = [];
    $db->{private_finished} = 0;
    my $service = Mediabot::Plugin::FactoidWriteServiceV3->new(dbh => $db);
    return ($service, $db, $peer);
}
sub invoke_1344 {
    my ($service, $op, %extra) = @_;
    return $service->$op(channel => '#test', keyword => 'spell', principal => $author,
        actor_nick => 'Author_', value => 'New value', %extra);
}

for my $raise (0, 1) {
    for my $op (qw(upsert delete)) {
        for my $fault (qw(read.prepare read.execute read.fetch read.after_fetch)) {
            my ($service, $db, $peer) = setup_1344($raise);
            $db->{private_fault} = $fault;
            my $result;
            my $ok = eval { $result = invoke_1344($service, $op); 1 };
            my $error = $@;
            my $label = "$op $fault RaiseError=$raise";
            ok(!$ok, "$label: failed lookup is not absence or success");
            is($error, "FactoidWriteServiceV3: data service unavailable\n",
                "$label: no SQL or driver detail escapes");
            ok(!defined $result, "$label: no successful detached result");
            is_deeply($db->{private_queries}, ['read'], "$label: no mutation attempted");
            is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID'), 2,
                "$label: original and other-channel facts survive");
            is($db->{private_finished}, $fault eq 'read.prepare' ? 0 : 1,
                "$label: prepared cursor is finished");
        }
    }
    for my $fault (qw(delete.prepare delete.execute delete.rows delete.rows_with_error delete.unknown_rows)) {
        my ($service, $db, $peer) = setup_1344($raise);
        $db->{private_fault} = $fault;
        my $result;
        my $ok = eval { $result = invoke_1344($service, 'delete'); 1 };
        my $error = $@;
        ok(!$ok, "$fault RaiseError=$raise: unconfirmed delete is rejected");
        is($error, "FactoidWriteServiceV3: data service unavailable\n",
            "$fault: fixed error even after a committed but unconfirmed delete");
        ok(!defined $result, "$fault: no false deleted outcome");
        is_deeply($db->{private_queries}, ['read', 'delete'], "$fault: no implicit retry");
        is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_channel=2'), 1,
            "$fault: other channel remains intact");
        is($db->{private_finished}, $fault eq 'delete.prepare' ? 1 : 2,
            "$fault: all prepared cursors are finished");
        is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_channel=1'),
            $fault =~ /prepare|execute/ ? 1 : 0,
            "$fault: observed database state reflects whether DELETE actually ran");
    }
    for my $race (qw(none removed replaced)) {
        my ($service, $db, $peer) = setup_1344($raise);
        $db->{private_before_delete} = sub {
            $peer->do('DELETE FROM FACTOID WHERE id_factoid=10');
            $peer->do(q{INSERT INTO FACTOID VALUES(11,1,'spell','Replacement',8)})
                if $race eq 'replaced';
        } if $race ne 'none';
        my $result = invoke_1344($service, 'delete');
        is($result->{status}, $race eq 'none' ? 'deleted' : 'not_found',
            "$race RaiseError=$raise: success reflects the exact authorized row");
        is($result->{ok}, 1, "$race: confirmed no-op keeps the idempotent API");
        is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_channel=1'),
            $race eq 'replaced' ? 1 : 0, "$race: replacement is never deleted");
        is($peer->selectrow_array('SELECT value FROM FACTOID WHERE id_factoid=20'),
            'Other channel', "$race: other channel is unchanged");
    }
    my ($service, $db, $peer) = setup_1344($raise);
    is(invoke_1344($service, 'delete', keyword => 'missing')->{status}, 'not_found',
        "RaiseError=$raise: genuinely missing factoid stays idempotent");
    is(invoke_1344($service, 'upsert', channel => '#missing')->{error}, 'channel_unavailable',
        "RaiseError=$raise: genuinely missing channel stays distinct");

    my $bot = bless {registry => Mediabot::CommandRegistry->new,
        logger => bless({}, 'MB968::Log')}, 'MB968::Bot';
    for my $name (qw(factoid factoids learn forget whatis)) {
        $bot->{registry}->register_command(name => $name, source => 'public',
            handler => sub { die 'on mode must not fall back to a native write' },
            category => 'core', metadata => {builtin => 1, dispatch => 'registry',
                syntax => $name, migration_fallback => 1});
    }
    my $manager = Mediabot::PluginManager->new(bot => $bot, plugin_dir => 'plugins',
        v3_factoid_write_service => $service);
    $manager->load_package_v3('factoids-v3', grants => [
        qw(data.factoids.read data.factoids.write irc.reply irc.notice)]);
    $manager->set_v3_channel_policy('factoids-v3', '#test', mode => 'on');
    $manager->enable('factoids-v3');
    for my $command (qw(learn forget)) {
        $db->{private_fault} = 'read.fetch';
        my $ctx = bless {command => $command, notices => [], args => $command eq 'learn'
            ? ['spell', '=', 'value'] : ['spell']}, 'MB968::Context';
        my $handler = $bot->{registry}->handler_for($command, 'public');
        my $ok = eval { $handler->($ctx); 1 };
        ok($ok, "$command RaiseError=$raise: runtime contains the service error");
        is_deeply($ctx->{notices}, [$command eq 'learn'
            ? 'learn: could not store the factoid.' : 'forget: delete failed.'],
            "$command: actual plugin reports failure instead of absence or success");
    }
    for my $race (qw(none removed replaced unknown)) {
        $peer->do('DELETE FROM FACTOID WHERE id_channel=1');
        $peer->do(q{INSERT INTO FACTOID VALUES(10,1,'spell','Original',7)});
        $db->{private_fault} = $race eq 'unknown' ? 'delete.rows' : '';
        $db->{private_before_delete} = sub {
            $peer->do('DELETE FROM FACTOID WHERE id_factoid=10');
            $peer->do(q{INSERT INTO FACTOID VALUES(11,1,'spell','Replacement',8)})
                if $race eq 'replaced';
        } if $race eq 'removed' || $race eq 'replaced';
        my $ctx = bless {command => 'forget', notices => [], args => ['spell']}, 'MB968::Context';
        my $handler = $bot->{registry}->handler_for('forget', 'public');
        my $ok = eval { $handler->($ctx); 1 };
        ok($ok, "$race RaiseError=$raise: actual forget command completes");
        is_deeply($ctx->{notices}, [$race eq 'none' ? "Forgot 'spell' on #test."
            : $race eq 'unknown' ? 'forget: delete failed.' : "I don't know 'spell'."],
            "$race: no successful forget notice without a confirmed removal");
        is($peer->selectrow_array('SELECT COUNT(*) FROM FACTOID WHERE id_factoid=11'),
            $race eq 'replaced' ? 1 : 0, "$race: command preserves concurrent replacement");
    }
    $manager->unregister_plugin('factoids-v3');
}
done_testing;
