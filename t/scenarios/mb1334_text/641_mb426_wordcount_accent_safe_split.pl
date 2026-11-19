package MB1334::Case641;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package WordFixture::Conf; sub get {$_[0]{$_[1]}}
    package WordFixture::Log; sub log {1}
    package WordFixture::Achievements;
    sub check_wordcount {push @{$_[0]{calls}},[@_[1..3]];1}
}
my (@wire,@warnings,@snapshots);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {1};
local $SIG{__WARN__}=sub {push @warnings,@_};
my @text=("ÉCOLE école E\x{301}COLE — CAFÉ café cafe\x{301} … 😀",
    'ΓΕΙΑ γεια 中文词 中文词 naïf NAÏF','alpha ALPHA foo_bar 123','— … 😀');
sub fixture_words {
    my ($unicode,$texts,$legacy_bytes)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
    $db->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    $db->do('CREATE TABLE CHANNEL_LOG(id_channel_log INTEGER PRIMARY KEY,id_channel INTEGER,nick TEXT,publictext TEXT,event_type TEXT)');
    $db->{sqlite_unicode}=0 if $legacy_bytes;
    my $id=0;
    for my $text(@$texts) {
        $db->do("INSERT INTO CHANNEL_LOG VALUES(?,1,'alice',?,'public')",undef,++$id,$text);
    }
    $db->do("INSERT INTO CHANNEL_LOG VALUES(100,2,'alice','foreign-channel-word','public'),(101,1,'bob','foreign-user-word','public'),(102,1,'alice','presence-not-word','join')");
    $db->{sqlite_unicode}=$unicode;
    my $before=$db->selectall_arrayref('SELECT * FROM CHANNEL_LOG ORDER BY id_channel_log');
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{conf}=bless {},'WordFixture::Conf';$bot->{logger}=bless {},'WordFixture::Log';
    $bot->{achievements}=bless {calls=>[]},'WordFixture::Achievements';
    return ($bot,$db,$before);
}
sub invoke_words {
    my ($bot,$all)=@_;@wire=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Observer',channel=>'#test',
        command=>'wordcount',args=>['Alice',($all?'all':())]);
    $ctx->{_user_fetched}=1;
    $bot->command_registry->handler_for('wordcount','public')->($ctx);
    return [map {[@$_]} @wire];
}
sub finish_words {
    my ($db,$before)=@_;
    push @snapshots,[$before,$db->selectall_arrayref('SELECT * FROM CHANNEL_LOG ORDER BY id_channel_log')];
    $db->disconnect;
}

my ($raw_bot,$raw_db,$raw_before)=fixture_words(0,\@text);
my $raw_sample=$raw_db->selectrow_array('SELECT publictext FROM CHANNEL_LOG WHERE id_channel_log=1');
my $raw=invoke_words($raw_bot,1);
like($raw->[0][2],qr/\Aalice: 8 distinct word\(s\) on #test/,
    'native registry counts canonical words from raw UTF-8 without foreign users, channels or presence events');
my ($char_bot,$char_db,$char_before)=fixture_words(1,\@text);
my $char_sample=$char_db->selectrow_array('SELECT publictext FROM CHANNEL_LOG WHERE id_channel_log=1');
my $characters=invoke_words($char_bot,1);
is_deeply([utf8::is_utf8($raw_sample)?1:0,utf8::is_utf8($char_sample)?1:0,$characters],
    [0,1,$raw],'actual DBI byte and character results produce the same command output');
like($raw->[0][2],qr/top words: café \(3\), école \(3\), alpha \(2\), naïf \(2\), γεια \(2\)\z/,
    'case and composed/decomposed accents share frequencies, with correct Unicode labels and stable ties');
my $bounded=invoke_words($char_bot,0);
is_deeply([$bounded->[0][2]=~/\Aalice: 8 distinct word\(s\)/?1:0,
    $bounded->[0][2]=~/activity rank: #1/?1:0,$char_bot->{achievements}{calls}],
    [1,1,[['alice','#test',8],['alice','#test',8]]],
    'bounded mode and streaming all agree, retain the activity rank and publish the corrected achievement count');
finish_words($raw_db,$raw_before);finish_words($char_db,$char_before);
{
    my ($bot,$db,$before)=fixture_words(1,['ΓΕΙΑ γεια 中文词 中文词']);
    my $out=invoke_words($bot,1);
    like($out->[0][2],qr/2 distinct word\(s\).*top words: γεια \(2\), 中文词 \(2\)\z/,
        'decoded Greek and Chinese words remain whole and count repeated words once');
    finish_words($db,$before);
}
{
    my ($bot,$db,$before)=fixture_words(0,['alpha—beta…gamma😀delta']);
    my $out=invoke_words($bot,1);
    like($out->[0][2],qr/4 distinct word\(s\).*top words: alpha \(1\), beta \(1\), delta \(1\), gamma \(1\)\z/,
        'Unicode punctuation and emoji separate adjacent words instead of becoming a byte token');
    finish_words($db,$before);
}
{
    my ($bot,$db,$before)=fixture_words(0,["CAF\xC9","caf\xE9",undef],1);
    my $out=invoke_words($bot,1);
    my $legacy=$db->selectrow_array('SELECT publictext FROM CHANNEL_LOG WHERE id_channel_log=1');
    is_deeply([$legacy,utf8::is_utf8($legacy)?1:0,
        $out->[0][2]=~/1 distinct word\(s\).*top words: café \(2\)\z/?1:0],
        ["CAF\xC9",0,1],'the shared decoder retains its legacy byte fallback and NULL messages invent no word');
    finish_words($db,$before);
}
{
    my ($bot,$db,$before)=fixture_words(1,[undef,''," \t","—😀… ❤️ \x{301}"]);
    my $out=invoke_words($bot,1);
    is_deeply([$out->[0][2]=~/\Aalice: 0 distinct word\(s\)/?1:0,
        scalar(grep {$_->[0] eq 'notice' || $_->[2]=~/top words:/} @$out),$bot->{achievements}{calls}],
        [1,0,[['alice','#test',0]]],'empty and symbol-only messages yield a genuine zero and no invented top word');
    finish_words($db,$before);
}
{
    # MB1363: the 50k tokenization cap must not become the target's activity
    # count. Execute the real grouping and cap against live/archive tables.
    my ($bot,$db)=fixture_words(1,[]);
    $db->do('DELETE FROM CHANNEL_LOG');
    $db->do("ATTACH DATABASE ':memory:' AS archive");
    $db->do('CREATE TABLE archive.CHANNEL_LOG_ARCHIVE AS SELECT * FROM CHANNEL_LOG WHERE 0');
    $db->do('CREATE TEMP TABLE numbers(x INTEGER)');
    $db->do(q{INSERT INTO numbers
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<50003)
        SELECT x FROM n});
    $db->do(q{INSERT INTO CHANNEL_LOG
        SELECT x+25001,1,'alice','currentword','public' FROM numbers WHERE x<=25001});
    $db->do(q{INSERT INTO archive.CHANNEL_LOG_ARCHIVE
        SELECT x,1,'alice','archiveword','action' FROM numbers WHERE x<=25001});
    for my $entry (['bob',50001],['charlie',50002],['dana',50003]) {
        my ($nick,$count)=@$entry;
        $db->do(q{INSERT INTO CHANNEL_LOG(id_channel,id_channel_log,nick,publictext,event_type)
            SELECT 1,NULL,?,'otherword','public' FROM numbers WHERE x<=?},undef,$nick,$count);
    }
    # Two unrelated messages or one presence event must not alter ties or
    # make the target overtake Dana; the competition is channel speech only.
    $db->do(q{INSERT INTO CHANNEL_LOG(id_channel,nick,publictext,event_type) VALUES
        (2,'alice','elsewhere','public'),(2,'alice','elsewhere','action'),
        (2,'bob','elsewhere','public'),(2,'bob','elsewhere','action'),
        (1,'alice','joined','join')});
    $bot->{conf}=bless {'mysql.CHANNEL_LOG_ARCHIVE_DBNAME'=>'archive',
        'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'=>30},'WordFixture::Conf';
    my $fingerprint=sub { [map {$db->selectall_arrayref(
        "SELECT COUNT(*),SUM(id_channel_log),SUM(LENGTH(publictext)) FROM $_")}
        ('CHANNEL_LOG','archive.CHANNEL_LOG_ARCHIVE')] };
    my $before=$fingerprint->();
    my $out=invoke_words($bot,0);
    is_deeply($out,[['public','#test','alice: 2 distinct word(s) on #test [last 50k msgs]'
        .'  | activity rank: #2  | top words: currentword (25001), archiveword (24999)']],
        '50,002 messages outrank 50,001 and tie 50,002 after archive merging; only 50,003 ranks ahead, while words remain capped');
    is_deeply([$fingerprint->(),$bot->{achievements}{calls}],
        [$before,[['alice','#test',2]]],
        'ranking preserves both history tables and the capped distinct-word achievement count');
    $db->disconnect;
}
is_deeply([\@warnings,[map {$_->[1]} @snapshots]],
    [[],[map {$_->[0]} @snapshots]],'counting leaves all stored source rows intact and emits no warning');
1;
