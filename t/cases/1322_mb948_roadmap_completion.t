use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP;
use Mediabot::Conversation::Profiles;
use Mediabot::Plugin::ScaffoldV3;
use Mediabot::ChannelCommands;
use Mediabot::Context;
{
    package MB948::DBI;our @ISA=('DBI');
    package MB948::DBI::db;our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        push @{$db->{private_mb948}{sql}},$sql;
        $sql =~ s/\s+FOR UPDATE\s*\z//;
        return $db->SUPER::prepare($sql,@rest);
    }
    sub commit {
        my ($db)=@_;
        return if $db->{private_mb948}{fail_commit};
        return $db->SUPER::commit;
    }
    package MB948::DBI::st;our @ISA=('DBI::st');
    sub execute {
        my ($st,@bind)=@_;
        my $s=$st->{Database}{private_mb948};
        if ($st->{Statement} =~ /\A\s*(?:INSERT|UPDATE|DELETE)\b/) {
            $s->{writes}++;
            return if $s->{fail_write} && $s->{writes}==$s->{fail_write};
        }
        return $st->SUPER::execute(@bind);
    }
    package MB948::User;
    sub is_authenticated {$_[0]{auth}}
    sub id {1}
    sub has_level {$_[1] eq 'Master' ? $_[0]{master} : 1}
    package MB948::Channel;sub get_id {37}
    package MB948::Wrapper;sub ensure_connected {$_[0]{db}}
    package MB948::Bot;sub get_user_from_message {$_[0]{test_user}}
}
my $make=sub {
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>1,PrintError=>0,AutoCommit=>1,RootClass=>'MB948::DBI'});
    $db->{private_mb948}={sql=>[],writes=>0};
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT)');
    $db->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $db->do('CREATE TABLE HAILO_CHANNEL(id_hailo_channel INTEGER PRIMARY KEY,id_channel INTEGER UNIQUE,ratio INTEGER)');
    $db->do("INSERT INTO CHANNEL VALUES (37,'#test'),(38,'#other')");
    $db->do("INSERT INTO CHANSET_LIST VALUES (1,'HailoChatter'),(2,'Spark'),(3,'SparkAction'),(4,'OtherFlag')");
    $db->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) VALUES (37,1),(37,4),(38,1)');
    $db->do('INSERT INTO HAILO_CHANNEL(id_channel,ratio) VALUES (37,17),(38,65)');
    $db->{private_mb948}={sql=>[],writes=>0};
    return bless {dbh=>$db,channels=>{'#test'=>bless({},'MB948::Channel')},
        _chanset_cache=>{"#Test\x001"=>1,"#other\x001"=>2},
        _hailo_ratio_cache=>{'#test'=>17,'#other'=>65}},'MB948::Bot';
};
my $state=sub {
    my ($db)=@_;
    return [$db->selectall_arrayref('SELECT id_channel,id_chanset_list FROM CHANNEL_SET ORDER BY id_channel,id_chanset_list'),
        $db->selectall_arrayref('SELECT id_channel,ratio FROM HAILO_CHANNEL ORDER BY id_channel')];
};
my $op=sub {Mediabot::Conversation::Profiles::operate($_[0],37,'#test',$_[1])};
my $bot=$make->();my $db=$bot->{dbh};my $original=$state->($db);
my $r=$op->($bot,'show');ok($r->{ok} && !$r->{changed},'profile show reads the current custom state');
is_deeply($state->($db),$original,'show changes no stored settings');
is($db->{private_mb948}{writes},0,'show issues no DML');
$r=$op->($bot,'quiet');ok($r->{ok} && $r->{changed},'quiet profile applies');
is_deeply([@{$r->{state}}{qw(HailoChatter Spark SparkAction ratio)}],[0,0,0,17],
    'quiet suppresses three spontaneous gates and preserves ratio');
ok(!exists($bot->{_chanset_cache}{"#Test\x001"}) && !exists($bot->{_hailo_ratio_cache}{'#test'}),
    'committed changes invalidate channel flag and ratio caches');
ok(exists($bot->{_chanset_cache}{"#other\x001"}) && exists($bot->{_hailo_ratio_cache}{'#other'}),
    'another channel cache remains intact');
$r=$op->($bot,'quiet');ok($r->{ok} && !$r->{changed} && $r->{undo_available},'repeat application preserves the previous undo point');
$r=$op->($bot,'restore');ok($r->{ok},'restore succeeds against the exact expected current settings');
is_deeply($state->($db),$original,'restore returns all prior flag presence and ratio values, preserving unrelated settings');
is($op->($bot,'restore')->{code},'no_previous_profile','restore consumes its one previous state');
for my $mode (qw(balanced animated)) {
    $bot=$make->();$db=$bot->{dbh};$original=$state->($db);$r=$op->($bot,$mode);
    is_deeply([@{$r->{state}}{qw(HailoChatter Spark SparkAction ratio)}],
        $mode eq 'balanced' ? [0,1,1,17] : [1,1,1,3],"$mode applies its explicit gates and chatter chance");
    ok($op->($bot,'restore')->{ok},"$mode can restore");
    is_deeply($state->($db),$original,"$mode restore retains unrelated channel state");
}
$bot=$make->();$db=$bot->{dbh};$db->do('DELETE FROM HAILO_CHANNEL WHERE id_channel=37');
$original=$state->($db);ok($op->($bot,'animated')->{ok},'animated can create a missing ratio');
ok($op->($bot,'restore')->{ok},'the previously absent ratio can be restored');
is_deeply($state->($db),$original,'restore recovers initial ratio absence');
$bot=$make->();$db=$bot->{dbh};$op->($bot,'balanced');$db->do('UPDATE HAILO_CHANNEL SET ratio=18 WHERE id_channel=37');
$original=$state->($db);is($op->($bot,'restore')->{code},'settings_changed','concurrent edit refuses whole restore');
is_deeply($state->($db),$original,'a refused restore leaves the foreign edit and flags intact');
for my $failure (1,2,3) {
    $bot=$make->();$db=$bot->{dbh};$original=$state->($db);
    $db->{private_mb948}{fail_write}=$failure;$r=$op->($bot,'animated');
    ok(!$r->{ok},"write failure $failure refuses the transaction");
    is_deeply($state->($db),$original,"write failure $failure rolls back earlier writes");
    ok(!exists($bot->{_conversation_profile_undo}),"failed write $failure publishes no undo state");
}
$bot=$make->();$db=$bot->{dbh};$original=$state->($db);$db->{private_mb948}{fail_commit}=1;
ok(!$op->($bot,'balanced')->{ok},'false-returning commit is a failure');
is_deeply($state->($db),$original,'failed commit restores the previous settings');
$bot=$make->();$db=$bot->{dbh};$db->begin_work;$db->do('UPDATE HAILO_CHANNEL SET ratio=19 WHERE id_channel=38');
ok(!$op->($bot,'balanced')->{ok},'caller-owned transaction is refused');
is($db->selectrow_array('SELECT ratio FROM HAILO_CHANNEL WHERE id_channel=38'),19,'refusal does not roll back the caller transaction');
$db->rollback;
$bot=$make->();$db=$bot->{dbh};$db->do('DELETE FROM CHANSET_LIST WHERE chanset=\'Spark\'');$original=$state->($db);
ok(!$op->($bot,'balanced')->{ok},'missing catalogue is refused instead of silently creating a new flag');
is_deeply($state->($db),$original,'invalid catalogue changes nothing');
$bot=$make->();$op->($bot,'quiet');my $newdb=$make->()->{dbh};$bot->{db}=bless({db=>$newdb},'MB948::Wrapper');
is($op->($bot,'restore')->{code},'connection_changed','undo cannot cross to another DB handle');

my @notices;my $run=sub {
    my ($bot,$user,@args)=@_;
    $bot->{test_user}=$user;
    return Mediabot::ChannelCommands::channelSet_ctx(Mediabot::Context->new(bot=>$bot,nick=>'Pablo',
        channel=>'#test',command=>'chanset',args=>['#test','profile',@args],user=>$user));
};
{
 no warnings 'redefine';
 local *Mediabot::ChannelCommands::checkUserChannelLevel=sub {1};
 local *Mediabot::ChannelCommands::botNotice=sub {push @notices,$_[2];1};
 local *Mediabot::ChannelCommands::logBot=sub {1};
 $bot=$make->();$original=$state->($bot->{dbh});
 $run->($bot,bless({auth=>1,master=>0},'MB948::User'),'animated');
 like($notices[-1] // '',qr/require Master/,'Administrator/channel access cannot bypass stricter Hailo profile authority');
 is_deeply($state->($bot->{dbh}),$original,'denied user changes no profile setting');
 $run->($bot,bless({auth=>1,master=>1},'MB948::User'),'balanced');
 like(join(' ',@notices),qr/Spark=on SparkAction=on/,'existing chanset handler exposes the native profile result');
 @notices=();$run->($bot,bless({auth=>1,master=>1},'MB948::User'),'animated','extra');
 like(join(' ',@notices),qr/Syntax: chanset/,'ambiguous extra arguments are refused');
}
my $tmp=tempdir(CLEANUP=>1);my $out=Mediabot::Plugin::ScaffoldV3::create(directory=>$tmp,name=>'first-v3',command=>'first_greeting');
ok(-f "$out->{directory}/plugin.json" && -f "$out->{directory}/lib/Greeting.pm",'scaffold creates a complete minimal package');
my $manifest=do {open my $fh,'<',"$out->{directory}/plugin.json" or die $!;local $/;decode_json(<$fh>)};
is_deeply($manifest->{capabilities},['irc.reply'],'generated example requests only its required capability');
is($manifest->{activation}{default},'off','generated example stays default off');
ok(!eval {Mediabot::Plugin::ScaffoldV3::create(directory=>$tmp,name=>'first-v3');1},'existing package is never overwritten');
for my $name ('../escape','a/b','Bad Name','x;touch') {
 ok(!eval {Mediabot::Plugin::ScaffoldV3::create(directory=>$tmp,name=>$name);1},'unsafe package names are refused before writing');
}
my $link="$tmp/linked";symlink($out->{directory},$link) or die $!;
ok(!eval {Mediabot::Plugin::ScaffoldV3::create(directory=>$link,name=>'other');1},'symlink parent is refused');
open my $workshop,'-|',$^X,'tools/plugin_v3_workshop.pl','--check' or die $!;
my $report=do {local $/;<$workshop>};my $closed=close $workshop;
ok($closed,'generated package completes its real native runtime lifecycle');
like($report,qr/observe\/on\/off.*unload and stale-handler refusal/,'workshop verifies activation, isolation, unload and stale callbacks');
done_testing;
