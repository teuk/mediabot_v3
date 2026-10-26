use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;
use Mediabot::Achievements;
use Mediabot::Plugin::FactoidWriteServiceV3;
use Mediabot::Plugin::PrincipalV3;

{
    package MB970::DBI; our @ISA = ('DBI');
    package MB970::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @args) = @_;
        # SQLite equivalent of the existing MySQL UPSERT; bindings, original
        # authorship and all other statements execute against actual tables.
        $sql =~ s/ON DUPLICATE KEY UPDATE\s+value = VALUES\(value\),\s+updated_at = CURRENT_TIMESTAMP/ON CONFLICT(id_channel, keyword) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP/
            if $sql =~ /INSERT INTO FACTOID/;
        return $db->SUPER::prepare($sql, @args);
    }
    package MB970::DBI::st; our @ISA = ('DBI::st');
    package MB970::Channel; sub get_id {1}
    package MB970::Log; sub log {1}
    package MB970::Metrics;
    sub inc { $_[0]{$_[2]{op}}++; 1 }
    package MB970::Achievements; our @ISA = ('Mediabot::Achievements');
    sub _channel_id { $_[1] eq '#test' ? 1 : 2 }
    sub threshold { 1_000_000 }
    sub unlock { die 'unexpected achievement threshold' }
    sub set_progress { $_[0]{observed}{$_[1]} = $_[4]; 1 }
}
$INC{'MB970/DBI.pm'} = __FILE__;
my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, $_[2]; 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub setup_1346 {
    my ($raise) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB970::DBI', RaiseError => $raise, PrintError => 0,
        sqlite_foreign_keys => 1});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY, nickname TEXT)');
    $db->do(q{INSERT INTO USER VALUES(7,'Account'),(8,'OtherAccount')});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER, chanset TEXT)');
    $db->do('CREATE TABLE USER_CHANNEL(id_user INTEGER, id_channel INTEGER, level INTEGER)');
    $db->do(q{CREATE TABLE FACTOID(id_factoid INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER REFERENCES CHANNEL(id_channel), keyword TEXT, value TEXT,
        created_by INTEGER REFERENCES USER(id_user), created_by_nick TEXT,
        hits INTEGER DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP, UNIQUE(id_channel,keyword))});
    $db->do(q{INSERT INTO FACTOID(id_channel,keyword,value,created_by,created_by_nick)
        VALUES(2,'spell','Other channel',8,'OtherNick')});
    $db->do('CREATE TABLE QUOTES(id_channel INTEGER, id_user INTEGER)');
    $db->do('INSERT INTO QUOTES VALUES(1,7),(1,8),(2,7)');
    my $bot = bless {dbh => $db, logger => bless({},'MB970::Log'),
        channels => {'#test' => bless({},'MB970::Channel')},
        metrics => bless({},'MB970::Metrics')}, 'Mediabot';
    $bot->{achievements} = bless {bot => $bot, observed => {}}, 'MB970::Achievements';
    return ($bot, $db);
}
sub user_1346 {
    my ($id, $auth) = @_;
    return Mediabot::User->new({id_user => $id, nickname => 'Account', auth => $auth});
}
sub invoke_1346 {
    my ($entry, $command, $bot, $user, $nick, @args) = @_;
    @wire = (); @warnings = ();
    my $ctx = Mediabot::Context->new(bot => $bot, nick => $nick, channel => '#test',
        command => $command, args => \@args);
    # Real context cache of an already resolved user, including auth=0.
    $ctx->{user} = $user; $ctx->{_user_fetched} = 1;
    no strict 'refs';
    my $ok = eval { &{"${entry}::mb${command}_ctx"}($ctx); 1 };
    return $ok ? '' : $@;
}
sub fact_1346 {
    return $_[0]->selectrow_hashref(q{SELECT * FROM FACTOID
        WHERE id_channel=1 AND keyword='spell'});
}

my @cases = (
    {label => 'unknown guest', user => undef, author => undef},
    {label => 'recognized account without login', user => user_1346(7,0), author => undef},
    {label => 'authenticated author', user => user_1346(7,1), author => 7},
    {label => 'authenticated other account', user => user_1346(8,1), author => 8},
    {label => 'invalid zero account id', user => user_1346(0,1), author => undef},
    {label => 'missing account id', user => user_1346(undef,1), author => undef},
);
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $raise (0,1) {
        for my $case (@cases) {
            my ($bot, $db) = setup_1346($raise);
            my $label = "$entry RaiseError=$raise $case->{label}";
            is(invoke_1346($entry,'Learn',$bot,$case->{user},'Speaker','spell','=','Original'),
                '', "$label: public learn completes with foreign keys enabled");
            my $row = fact_1346($db) || {};
            is($row->{value}, 'Original', "$label: factoid was actually stored");
            is($row->{created_by}, $case->{author}, "$label: only authenticated positive id owns the fact");
            is($row->{created_by_nick}, 'Speaker', "$label: display nick stays the actual IRC nick");
            like(join(' ',@wire), qr/Learned 'spell'/, "$label: successful storage is acknowledged");
            is($bot->{metrics}{learn}, 1, "$label: successful learn metric is retained");
            is($bot->{achievements}{observed}{quotes_contributed},
                defined($case->{author}) ? 1 : 0,
                "$label: guest cannot inherit the matched account's quote contributions");
            is($bot->{achievements}{observed}{factoids_contributed}, 1,
                "$label: real persisted factoid contribution is counted");
            is(scalar @warnings, 0, "$label: no warning escapes");

            my $nick = defined($case->{author}) ? 'RenamedSpeaker' : 'Speaker';
            is(invoke_1346($entry,'Forget',$bot,$case->{user},$nick,'spell'), '',
                "$label: creator can use the native forget path");
            ok(!fact_1346($db), "$label: actual author can remove the new factoid");
            like(join(' ',@wire), qr/Forgot 'spell'/, "$label: creator is not locked out");
            is($db->selectrow_array(q{SELECT value FROM FACTOID WHERE id_channel=2}),
                'Other channel', "$label: other channel is unchanged");
        }

        for my $original_authenticated (0,1) {
            my ($bot,$db) = setup_1346($raise);
            my $label = "$entry RaiseError=$raise upsert original_auth=$original_authenticated";
            is(invoke_1346($entry,'Learn',$bot,user_1346(7,$original_authenticated),
                'OriginalNick','spell','=','Original'), '', "$label: initial learn completes");
            my $first = fact_1346($db) || {};
            is(invoke_1346($entry,'Learn',$bot,user_1346(8,1),
                'EditorNick','spell','=','Updated'), '', "$label: another account may update the value");
            my $next = fact_1346($db) || {};
            is($next->{value}, 'Updated', "$label: existing public update behavior is retained");
            is($next->{id_factoid}, $first->{id_factoid}, "$label: row identity is retained");
            is($next->{created_by}, $original_authenticated ? 7 : undef,
                "$label: update does not acquire or replace original account ownership");
            is($next->{created_by_nick}, 'OriginalNick', "$label: original display attribution is retained");
            is($next->{created_at}, $first->{created_at}, "$label: original creation time is retained");
            is($bot->{achievements}{observed}{factoids_contributed}, 0,
                "$label: editor receives no ownership credit for another author's factoid");
            is($db->selectrow_array('SELECT COUNT(*) FROM FACTOID'), 2,
                "$label: update creates neither a duplicate nor another-channel mutation");
        }
    }
}

# Native and v3 creation now use the same account/anonymous representation.
for my $auth (0,1) {
    my ($bot,$db) = setup_1346(1);
    is(invoke_1346('Mediabot','Learn',$bot,user_1346(7,$auth),
        'Speaker','spell','=','Original'), '', "parity auth=$auth: native create completes");
    my $native = fact_1346($db) || {};
    my $principal = Mediabot::Plugin::PrincipalV3->new(authenticated => $auth,
        user_id => 7, account => 'Account', global_level => 'user', channel_level => 0);
    my $result = Mediabot::Plugin::FactoidWriteServiceV3->new(dbh => $db)->upsert(
        channel => '#test', principal => $principal, actor_nick => 'Speaker',
        keyword => 'plugin', value => 'Original');
    is($result->{status}, 'stored', "parity auth=$auth: v3 create completes");
    my $v3 = $db->selectrow_hashref(q{SELECT * FROM FACTOID WHERE keyword='plugin'});
    is($native->{created_by}, $v3->{created_by}, "parity auth=$auth: same canonical account identity");
    is($native->{created_by_nick}, $v3->{created_by_nick}, "parity auth=$auth: same display attribution");
}
done_testing;
