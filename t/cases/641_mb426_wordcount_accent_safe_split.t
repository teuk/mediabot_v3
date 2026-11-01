use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package WordFixture::Conf; sub get {undef}
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
is_deeply([\@warnings,[map {$_->[1]} @snapshots]],
    [[],[map {$_->[0]} @snapshots]],'counting leaves all stored source rows intact and emits no warning');
done_testing;
