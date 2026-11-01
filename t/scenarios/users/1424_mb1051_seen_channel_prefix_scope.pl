use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB1051::DBI; our @ISA = ('DBI');
    package MB1051::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        $sql =~ s/NOW\(\) - INTERVAL 24 HOUR/0/g;
        return $db->SUPER::prepare($sql, @rest);
    }
    package MB1051::DBI::st; our @ISA = ('DBI::st');
    package MB1051::Conf; sub get {$_[0]{$_[1]}}
    package MB1051::Log; sub log {1}
    package MB1051::Channel; sub get_id {7}
    package MB1051::Bot; our @ISA = ('Mediabot');
    sub gethChannelNicks {$_[0]{online}}
    sub gethChannelsNicksOnChan {@{$_[0]{online}{$_[1]} // []}}
}
$INC{'MB1051/DBI.pm'} = __FILE__;
my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub {push @wire, ['notice', @_[1,2]]; 1};
local *Mediabot::UserCommands::botPrivmsg = sub {push @wire, ['public', @_[1,2]]; 1};
local *Mediabot::UserCommands::logBot = sub {1};
local $SIG{__WARN__} = sub {push @warnings, @_};

sub fixture_1424 {
    my ($channel) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RootClass=>'MB1051::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->sqlite_create_function('UNIX_TIMESTAMP',1,sub {0 + ($_[0] // 0)});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE)');
    $db->do('INSERT INTO CHANNEL VALUES(7,?),(9,?)',undef,$channel,'#other');
    $db->do(q{CREATE TABLE USER_SEEN(nick TEXT COLLATE NOCASE,channel TEXT COLLATE NOCASE,
        userhost TEXT,event_type TEXT,last_msg TEXT,new_nick TEXT,seen_at INTEGER)});
    $db->do(q{CREATE TABLE CHANNEL_LOG(id_channel INTEGER,nick TEXT,ts INTEGER,
        userhost TEXT,publictext TEXT,event_type TEXT)});
    $db->do(q{ATTACH DATABASE ':memory:' AS history});
    $db->do(q{CREATE TABLE history.CHANNEL_LOG_ARCHIVE AS SELECT * FROM CHANNEL_LOG});
    my $bot = bless {dbh=>$db,logger=>bless({},'MB1051::Log'),online=>{},
        conf=>bless({'mysql.CHANNEL_LOG_ARCHIVE_DBNAME'=>'history',
            'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS'=>7,
            'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'=>7},'MB1051::Conf'),
        channels=>{lc($channel)=>bless({},'MB1051::Channel')}},'MB1051::Bot';
    return ($bot,$db);
}
sub stored_1424 {
    my ($db,$channel,$nick,$text,$time) = @_;
    $db->do(q{INSERT INTO USER_SEEN VALUES(?,?,'person!id@host','message',?,NULL,?)},
        undef,$nick,$channel,$text,$time);
}
sub invoke_1424 {
    my ($bot,$channel,@args) = @_;
    @wire = ();
    Mediabot::mbSeen_ctx(Mediabot::Context->new(bot=>$bot,nick=>'Operator',
        channel=>$channel,args=>\@args));
    return join ' ', map {$_->[2]} @wire;
}
sub outcome_1424 {
    my ($text,$wanted) = @_;
    return [$text =~ $wanted ? 1:0, $text =~ /FORBIDDEN|#other/ ? 1:0,
        @wire ? [@{$wire[-1]}[0,1]] : []];
}

for my $channel ('#test','&local','!ABCDEsafe','+room') {
    my ($bot,$db) = fixture_1424($channel);
    stored_1424($db,$channel,'alice','TARGET_MESSAGE',1000);
    stored_1424($db,'#other','alice','FORBIDDEN_NEWER_MESSAGE',2000);
    for my $explicit (0,1) {
        my ($caller,@args) = $explicit ? ('#caller','Alice',$channel) : ($channel,'Alice');
        my $text = invoke_1424($bot,$caller,@args);
        is_deeply(outcome_1424($text,qr/TARGET_MESSAGE/),[1,0,['public',$caller]],
            "$channel: persisted lookup keeps its ".($explicit?'explicit':'current')." scope and reply destination");
    }
    $db->do(q{INSERT INTO CHANNEL_LOG VALUES
        (7,'alice',1000,'alice!id@host','one','public'),
        (7,'alice',1001,'alice!id@host','two','action'),
        (9,'alice',1002,'alice!id@host','other','public')});
    like(invoke_1424($bot,undef,'Alice',$channel),qr/\[2 msg in last 24h\]/,
        "$channel: the best-effort activity hint uses the same channel classification and identity");
    $db->do(q{DELETE FROM CHANNEL_LOG});
    stored_1424($db,$channel,'a_lice','target wildcard',1000);
    stored_1424($db,'#other','a_other','FORBIDDEN_WILDCARD',2000);
    stored_1424($db,$channel,'ablice','must not match literal underscore',3000);
    for my $explicit (0,1) {
        my ($caller,@args) = $explicit ? (undef,'a_*',$channel) : ($channel,'a_*');
        my $text = invoke_1424($bot,$caller,@args);
        is_deeply([$text =~ /1 nick\(s\).*a_lice/s ? 1:0,
            $text =~ /a_other|ablice|#other/ ? 1:0,[@{$wire[-1]}[0,1]]],
            [1,0,['notice','Operator']],
            "$channel: ".($explicit?'explicit':'current')." wildcard scope preserves literal underscore matching");
    }
    $db->do(q{DELETE FROM USER_SEEN});
    $bot->{online} = {'#other'=>['Alice']};
    $db->do(q{INSERT INTO history.CHANNEL_LOG_ARCHIVE VALUES
        (7,'alice',1000,'alice!id@host','TARGET_ARCHIVE','public')});
    $db->do(q{INSERT INTO CHANNEL_LOG VALUES
        (9,'alice',2000,'alice!elsewhere@host','FORBIDDEN_QUIT','quit')});
    for my $explicit (0,1) {
        my ($caller,@args) = $explicit ? (undef,'Alice',$channel) : ($channel,'Alice');
        my $text = invoke_1424($bot,$caller,@args);
        my $dest = $explicit ? ['notice','Operator'] : ['public',$channel];
        is_deeply(outcome_1424($text,qr/TARGET_ARCHIVE/),[1,0,$dest],
            "$channel: ".($explicit?'explicit':'current')." legacy archive scope rejects the unrelated online shortcut");
    }
    $bot->{online}{$channel} = ['ALIce'];
    my $text = invoke_1424($bot,undef,'Alice',$channel);
    is_deeply(outcome_1424($text,qr/ALIce is currently online on \Q$channel\E/),
        [1,0,['notice','Operator']],"$channel: the requested online channel preserves real nick casing");
    $db->disconnect;
}
{
    my ($bot,$db) = fixture_1424('&local');
    stored_1424($db,'#other','alice','GLOBAL_MESSAGE',2000);
    like(invoke_1424($bot,undef,'Alice'),qr/GLOBAL_MESSAGE/,
        'private exact lookup with no channel retains its historical global scope');
    like(invoke_1424($bot,undef,'Ali*'),qr/alice.*#other/,
        'private wildcard lookup with no channel retains its historical global scope');
    $db->do(q{DELETE FROM USER_SEEN});
    $db->do(q{INSERT INTO CHANNEL_LOG VALUES(9,'alice',2000,'alice!id@host','FORBIDDEN_QUIT','quit')});
    is(invoke_1424($bot,undef,'Alice','&unknown'),'Channel unavailable.',
        'an unknown explicit channel cannot turn into a global history lookup');
    is(invoke_1424($bot,undef,'Nobody*','+unknown'),"No nicks matching 'Nobody*' on +unknown.",
        'an empty explicit wildcard result retains its requested channel');
    $db->disconnect;
}
is_deeply(\@warnings,[],'scoped, empty and global native paths are warning-free');
1;
