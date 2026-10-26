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
    package MB962::DBI; our @ISA = ('DBI');
    package MB962::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        push @{ $db->{private_mb962_sql} }, $sql;
        my $kind = $sql =~ /FROM USER_SEEN/ ? 'seen'
            : $sql =~ /SELECT COUNT\(\*\) AS c/ ? 'activity' : '';
        my $actual = $sql;
        # Translate just the MySQL interval expression for SQLite. All query
        # bindings, sources, record selection and native handlers stay real.
        $actual =~ s/NOW\(\) - INTERVAL 24 HOUR/0/g;
        $actual = 'SELECT * FROM mb962_missing_table'
            if ($db->{private_mb962_fault} // '') eq "$kind.prepare" && length($kind);
        my $sth = $db->SUPER::prepare($actual, @rest);
        if ($sth) { $sth->{private_mb962_kind} = $kind; $sth->{private_mb962_fetched} = 0 }
        return $sth;
    }
    package MB962::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @bind) = @_;
        my $kind = $sth->{private_mb962_kind} // '';
        return $sth->set_err(1, 'private mb962 execute failure')
            if length($kind) && ($sth->{Database}{private_mb962_fault} // '') eq "$kind.execute";
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $kind = $sth->{private_mb962_kind} // '';
        my $fault = $sth->{Database}{private_mb962_fault} // '';
        my $n = $sth->{private_mb962_fetched}++;
        return $sth->set_err(1, 'private mb962 fetch failure')
            if length($kind) && ($fault eq "$kind.fetch" || ($fault eq "$kind.partial" && $n > 0));
        return $sth->SUPER::fetchrow_hashref;
    }
    package MB962::Conf; sub get { $_[0]{$_[1]} }
    package MB962::Log; sub log { 1 }
    package MB962::Channel; sub get_id { $_[0]{id} }
    package MB962::Bot; our @ISA = ('Mediabot');
    sub gethChannelNicks { $_[0]{online} // {} }
    sub gethChannelsNicksOnChan { @{ $_[0]{online}{$_[1]} // [] } }
}
$INC{'MB962/DBI.pm'} = __FILE__;
my (@wire, @warnings, @logs);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public', @_[1, 2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @logs, [@_[2..$#_]]; 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub setup_1338 {
    my (%args) = @_;
    @wire = (); @warnings = (); @logs = ();
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB962::DBI', RaiseError => $args{raise} // 1,
        PrintError => 0, sqlite_unicode => 1, AutoCommit => 1 });
    $db->sqlite_create_function('UNIX_TIMESTAMP', 1, sub { 0 + ($_[0] // 0) });
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE)');
    $db->do(q{INSERT INTO CHANNEL VALUES(7,'#test'),(9,'#archive'),(11,'#other')});
    $db->do(q{CREATE TABLE USER_SEEN(nick TEXT COLLATE NOCASE, channel TEXT COLLATE NOCASE,
        userhost TEXT, event_type TEXT, last_msg TEXT, new_nick TEXT, seen_at INTEGER)});
    $db->do(q{CREATE TABLE CHANNEL_LOG(id_channel INTEGER,nick TEXT,ts INTEGER,
        userhost TEXT,publictext TEXT,event_type TEXT)});
    $db->do(q{ATTACH DATABASE ':memory:' AS history});
    $db->do(q{CREATE TABLE history.CHANNEL_LOG_ARCHIVE AS SELECT * FROM CHANNEL_LOG});
    $db->do(q{INSERT INTO CHANNEL_LOG VALUES(11,'alice',3000,'alice!elsewhere@host','OTHER_CHANNEL_ONLY','quit')});
    my $conf = bless { 'mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'history',
        'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => 7,
        'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS' => 7 }, 'MB962::Conf';
    my $bot = bless { dbh => $db, conf => $conf, logger => bless({}, 'MB962::Log'),
        channels => $args{cached} ? { '#test' => bless({ id => 7 }, 'MB962::Channel') } : {},
        online => {} }, 'MB962::Bot';
    return ($bot, $db);
}
sub invoke_1338 {
    my ($entry, $bot, $channel, @args) = @_;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Operator', channel => $channel, args => \@args);
    no strict 'refs';
    my $ok = eval { &{ $entry . '::mbSeen_ctx' }($ctx); 1 };
    return $ok ? '' : $@;
}
sub stored_1338 {
    my ($db, $nick, $text) = @_;
    $db->do(q{INSERT INTO USER_SEEN VALUES(?,'#test','person!id@host','message',?,NULL,2000)}, undef, $nick, $text);
}

for my $entry (qw(Mediabot::Users::Seen Mediabot::UserCommands Mediabot)) {
    {
        my ($bot, $db) = setup_1338();
        $db->do(q{INSERT INTO history.CHANNEL_LOG_ARCHIVE VALUES(9,'alice',1000,'alice!id@host','ARCHIVE_TARGET','public')});
        is(invoke_1338($entry, $bot, '#test', 'Alice', '#archive'), '', "$entry: uncached channel lookup completes");
        like($wire[-1][2], qr/on #archive.*ARCHIVE_TARGET/, "$entry: resolves requested channel through its database identity");
        unlike(join(' ', map { $_->[2] } @wire), qr/OTHER_CHANNEL_ONLY/, "$entry: never falls back to an unrelated quit");
        is_deeply([@{ $wire[-1] }[0, 1]], ['public', '#test'], "$entry: explicit lookup replies in the caller's channel");
    }
    {
        my ($bot, $db) = setup_1338();
        is(invoke_1338($entry, $bot, undef, 'Alice', '#unknown'), '', "$entry: unknown scoped channel is handled");
        is_deeply(\@wire, [['notice', 'Operator', 'Channel unavailable.']], "$entry: unresolved channel is reported privately");
        unlike(join(' ', map { $_->[2] } @wire), qr/OTHER_CHANNEL_ONLY/, "$entry: unknown channel does not widen scope");
        ok(!grep(/FROM (?:CHANNEL_LOG|history\.CHANNEL_LOG_ARCHIVE)/, @{ $db->{private_mb962_sql} }),
            "$entry: unresolved scope never queries global history");
    }
    {
        my ($bot, $db) = setup_1338(cached => 1);
        stored_1338($db, 'alice', 'CONFIRMED_NORMAL_MESSAGE');
        is(invoke_1338($entry, $bot, '#test', 'Alice'), '', "$entry: healthy persisted lookup completes");
        like($wire[-1][2], qr/CONFIRMED_NORMAL_MESSAGE/, "$entry: healthy persisted message stays visible");
        is(scalar @logs, 1, "$entry: successful persisted lookup is logged once");
    }
    {
        my ($bot, $db) = setup_1338();
        stored_1338($db, 'a_lice', 'literal underscore');
        stored_1338($db, 'ablice', 'must not match');
        is(invoke_1338($entry, $bot, '#test', 'a_*'), '', "$entry: healthy wildcard lookup completes");
        like(join(' ', map { $_->[2] } @wire), qr/a_lice/, "$entry: wildcard retains literal underscore escaping");
        unlike(join(' ', map { $_->[2] } @wire), qr/ablice/, "$entry: literal underscore cannot match another character");
        is(scalar @logs, 1, "$entry: successful wildcard lookup is logged once");
    }
    {
        my ($bot, $db) = setup_1338();
        is(invoke_1338($entry, $bot, '#test', 'Nobody*'), '', "$entry: genuine empty wildcard read completes");
        like($wire[-1][2], qr/No nicks matching/, "$entry: empty success remains distinct from database failure");
    }
    {
        my ($bot, $db) = setup_1338();
        $bot->{online} = { '#other' => ['Alice'] };
        is(invoke_1338($entry, $bot, '#test', 'Alice'), '', "$entry: online elsewhere does not widen the current scope");
        unlike(join(' ', map { $_->[2] } @wire), qr/currently online|OTHER_CHANNEL_ONLY/, "$entry: current channel stays authoritative");
        @wire = ();
        is(invoke_1338($entry, $bot, undef, 'Alice', '#other'), '', "$entry: explicit online channel still takes the fast path");
        like($wire[-1][2], qr/Alice is currently online on #other/, "$entry: online nick casing and channel are preserved");
    }
    {
        my ($bot, $db) = setup_1338();
        $db->do(q{INSERT INTO CHANNEL_LOG VALUES(11,'old',1000,'old!id@host',?,'quit')},
            undef, "\x02Global\x0f\t\x7f" . ('y' x 550));
        is(invoke_1338($entry, $bot, undef, 'Old'), '', "$entry: global legacy quit lookup completes");
        my $text = $wire[-1][2] // '';
        unlike($text, qr/[\x00-\x1f\x7f]/, "$entry: global legacy quit is cleaned too");
        unlike($text, qr/y{250}/, "$entry: global legacy quit is bounded too");
    }
    {
        my ($bot, $db) = setup_1338();
        is(invoke_1338($entry, $bot, undef, 'Alice'), '', "$entry: legitimate private global lookup still works");
        like($wire[-1][2], qr/OTHER_CHANNEL_ONLY/, "$entry: unscoped private command retains its global fallback");
    }
    for my $source ('CHANNEL_LOG', 'history.CHANNEL_LOG_ARCHIVE') {
        my ($bot, $db) = setup_1338(cached => 1);
        my $body = "\x02Café\x0f \x0304rouge\x03\x00\r\n" . ('x' x 550);
        $db->do("INSERT INTO $source VALUES(7,'alice',1000,'alice!id\@host',?,'public')", undef, $body);
        is(invoke_1338($entry, $bot, '#test', 'Alice'), '', "$entry $source: legacy text lookup completes");
        my $text = $wire[-1][2] // '';
        unlike($text, qr/[\x00-\x1f\x7f]/, "$entry $source: legacy body cannot inject formatting or controls");
        unlike($text, qr/x{250}/, "$entry $source: legacy body uses the same display bound as USER_SEEN");
        like($text, qr/Café rouge/, "$entry $source: readable Unicode content survives cleanup");
    }
    for my $raise (0, 1) {
        for my $wild (0, 1) {
            for my $stage (qw(prepare execute fetch partial)) {
                next if $stage eq 'partial' && !$wild;
                my ($bot, $db) = setup_1338(raise => $raise);
                stored_1338($db, 'alice', 'PERSISTED_PARTIAL');
                stored_1338($db, 'alina', 'SECOND_PARTIAL');
                $db->{private_mb962_fault} = "seen.$stage";
                is(invoke_1338($entry, $bot, '#test', $wild ? 'Al*' : 'Alice'), '',
                    "$entry RaiseError=$raise wildcard=$wild $stage: SQL error is contained");
                is_deeply(\@wire, [['notice', 'Operator', 'Database error.']],
                    "$entry RaiseError=$raise wildcard=$wild $stage: SQL failure is neither absence nor a partial result");
                ok(!@logs, "$entry RaiseError=$raise wildcard=$wild $stage: failed lookup is not logged as success");
            }
        }
        for my $stage (qw(prepare execute fetch)) {
            my ($bot, $db) = setup_1338(raise => $raise, cached => 1);
            stored_1338($db, 'alice', 'CONFIRMED_LAST_MESSAGE');
            $db->{private_mb962_fault} = "activity.$stage";
            is(invoke_1338($entry, $bot, '#test', 'Alice'), '', "$entry RaiseError=$raise activity $stage: optional read cannot abort command");
            my $text = @wire ? $wire[-1][2] : '';
            like($text, qr/CONFIRMED_LAST_MESSAGE/, "$entry RaiseError=$raise activity $stage: confirmed seen result survives");
            unlike($text, qr/msg in last 24h/, "$entry RaiseError=$raise activity $stage: no unverified activity count");
        }
    }
}
done_testing;
