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

my $accepted_command = 'g' x 24;
my $boundary = Mediabot::Plugin::ScaffoldV3::create(
    directory => $tmp, name => 'limit-v3', command => $accepted_command);
ok(-f "$boundary->{directory}/plugin.json", 'scaffold accepts the runtime command length limit');
for my $args (
    { name => 'over-limit-v3', command => 'g' x 25 },
    { name => 'a' x 25 },
) {
    my $created = eval { Mediabot::Plugin::ScaffoldV3::create(directory => $tmp, %$args); 1 };
    ok(!$created && $@ =~ /invalid command name/,
        'scaffold rejects an overlong explicit or derived command through ManifestV3');
    ok(!-e "$tmp/$args->{name}", 'the rejected scaffold leaves no package directory');
}

sub workshop_cli_1322 {
    my (@args) = @_;
    my $pid = open my $child, '-|';
    die "cannot fork workshop validator: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>&STDOUT' or die $!;
        exec $^X, 'tools/plugin_v3_workshop.pl', @args or die $!;
    }
    my $output = do { local $/; <$child> };
    my $ok = close $child;
    return ($ok, $output // '');
}

sub validate_workshop_1322 {
    return workshop_cli_1322('--validate', @_);
}

my ($valid, $validation) = validate_workshop_1322('first-v3',
    '--directory', $tmp, '--grant', 'irc.reply');
ok($valid, 'the author can validate their generated package in a custom directory');
like($validation, qr/first-v3 0\.1\.0 loaded disabled and unloaded.*commands: 1\/1 mounted/s,
    'the validator exercises the real command registration');

($valid, $validation) = validate_workshop_1322('hello-v3');
ok($valid, 'an existing package validates without any test grants');
like($validation, qr/events: 0\/1 mounted.*jobs: 0\/1 mounted.*grants: none/s,
    'declared resources without a test grant remain unmounted');

($valid, $validation) = validate_workshop_1322('hello-v3',
    '--grant', 'events.subscribe', '--grant', 'scheduler.jobs');
ok($valid, 'the validator mounts and unloads real listeners and jobs with requested grants');
like($validation, qr/events: 1\/1 mounted.*jobs: 1\/1 mounted/s,
    'the report shows mounted listener and job counts');

($valid, $validation) = validate_workshop_1322('first-v3',
    '--directory', $tmp, '--grant', 'http.fetch');
ok(!$valid, 'the offline runtime rejects an unrequested test grant');
like($validation, qr/capability 'http\.fetch' was not requested/,
    'the validator returns the runtime grant error');

Mediabot::Plugin::ScaffoldV3::create(directory => $tmp, name => 'collision-v3', command => 'choose');
($valid, $validation) = validate_workshop_1322('collision-v3', '--directory', $tmp);
ok(!$valid, 'a conflicting command is checked against the actual built-in registry');
like($validation, qr/mounting API v3 command 'choose'/, 'the report identifies the conflicting command');

sub write_fixture_1322 {
    my ($path, $steps) = @_;
    open my $fixture, '>:raw', $path or die $!;
    print {$fixture} encode_json({steps => $steps}) or die $!;
    close $fixture or die $!;
}

my ($tested, $test_report) = workshop_cli_1322('--test', 'first-v3',
    '--directory', $tmp, '--grant', 'irc.reply');
ok($tested, 'generated Perl package passes its editable default fixture');
like($test_report, qr/passed 4 offline API v3 command step/, 'fixture exercises on, observe and off');

my $python = Mediabot::Plugin::ScaffoldV3::create(
    directory => $tmp, name => 'test-python', language => 'python');
($tested, $test_report) = workshop_cli_1322('--test', 'test-python',
    '--directory', $tmp, '--grant', 'irc.reply');
ok($tested && $test_report =~ /passed 4 offline API v3 command step/,
    'Python package runs its generated Unicode fixture through the subprocess runtime');

my $custom_fixture = "$tmp/alternate.test.json";
write_fixture_1322($custom_fixture, [{command => 'test_python',
    data => {nick => 'Karo', channel => '#chosen'},
    replies => [['PRIVMSG', '#chosen', 'Bonjour, Karo!']]}]);
my @custom = ('--test', 'test-python', '--directory', $tmp, '--fixture', $custom_fixture);
($tested, $test_report) = workshop_cli_1322(@custom, '--grant', 'irc.reply');
ok($tested && $test_report =~ /passed 1 offline API v3 command step/,
    'an existing Python plugin can use an explicit fixture with channel and nick');
($tested, $test_report) = workshop_cli_1322(@custom);
ok(!$tested && $test_report =~ /Step 1 failed:.*actions were refused/,
    'an ungranted subprocess reply fails the fixture with the runtime error');

write_fixture_1322($custom_fixture, [{command => 'test_python',
    replies => [['PRIVMSG', '#workshop', 'wrong greeting']]}]);
($tested, $test_report) = workshop_cli_1322(@custom, '--grant', 'irc.reply');
ok(!$tested && $test_report =~ /Step 1 reply mismatch.*wrong greeting.*Bonjour, Pablo!/s,
    'mismatches contain the expected and captured replies');

open my $crashing_script, '>:raw', "$python->{directory}/lib/greeting.py" or die $!;
print {$crashing_script} "raise SystemExit(1)\n" or die $!;
close $crashing_script or die $!;
write_fixture_1322($custom_fixture, [{command => 'test_python', mode => 'observe', replies => []}]);
($tested, $test_report) = workshop_cli_1322(@custom, '--grant', 'irc.reply');
ok(!$tested && $test_report =~ /Step 1 failed:.*script process failed/,
    'a failed interpreter cannot pass a silent observe test');

write_fixture_1322($custom_fixture, [{command => 'test_python', mode => 'observe',
    failure => {contains => 'script process failed'}, replies => []}]);
($tested, $test_report) = workshop_cli_1322(@custom, '--grant', 'irc.reply');
ok($tested, 'an expected asynchronous interpreter failure is recorded before the step completes')
    or diag($test_report);

my $guard_dir = Mediabot::Plugin::ScaffoldV3::create(
    directory => $tmp, name => 'guard-python', language => 'python')->{directory};
my $guard_path = "$guard_dir/plugin.json";
open my $guard_read, '<:raw', $guard_path or die $!;
my $guard_manifest = decode_json(do { local $/; <$guard_read> });
close $guard_read or die $!;
$guard_manifest->{commands}{guard_python}{level} = 'Master';
$guard_manifest->{commands}{guard_python}{aliases} = ['guard_alias'];
open my $guard_write, '>:raw', $guard_path or die $!;
print {$guard_write} encode_json($guard_manifest) or die $!;
close $guard_write or die $!;

my $master = {role => 'Master', authenticated => JSON::PP::true};
my $owner = {role => 'Owner', authenticated => JSON::PP::true};
my @access = ('--test', 'guard-python', '--directory', $tmp,
    '--fixture', $custom_fixture, '--grant', 'irc.reply');
write_fixture_1322($custom_fixture, [
    {command => 'guard_python', expect => 'denied', replies => []},
    {command => 'guard_alias', caller => {%$owner, authenticated => JSON::PP::false},
        expect => 'denied', replies => []},
    {command => 'guard_python', caller => {%$master, role => 'Administrator'},
        expect => 'denied', replies => []},
    {command => 'guard_alias', caller => $master,
        replies => [['PRIVMSG', '#workshop', 'Bonjour, Pablo!']]},
    {command => 'guard_python', caller => $owner, mode => 'observe', replies => []},
    {command => 'guard_python', caller => $owner, mode => 'off', replies => []},
    {command => 'guard_python', expect => 'denied', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@access);
ok($tested && $test_report =~ /passed 7 offline API v3 command step/,
    'the registry enforces identification, role order and activation on commands and aliases');

write_fixture_1322($custom_fixture, [
    {command => 'guard_alias', mode => 'observe', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@access);
ok(!$tested && $test_report =~ /expected 'ran' in 'observe'.*1 access denial/,
    'an unexpected access denial cannot pass as a silent observe result');

write_fixture_1322($custom_fixture, [
    {command => 'guard_python', caller => $master, mode => 'observe', expect => 'denied', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@access);
ok(!$tested && $test_report =~ /expected 'denied' but a script started/,
    'a false denial expectation fails even if the command produces no reply');

write_fixture_1322($custom_fixture, [
    {command => 'guard_python', caller => {%$master, authenticated => 'false'}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@access);
ok(!$tested && $test_report =~ /caller must have a stock role and a JSON authenticated boolean/,
    'a string cannot stand in for a boolean authentication state');

my @observer = ('--test', 'channel-observer-v3', '--directory', 'plugins/examples-v3');
($tested, $test_report) = workshop_cli_1322(@observer, '--grant', 'events.subscribe', '--grant', 'irc.reply');
ok($tested && $test_report =~ /passed 13 offline API v3 command\/event step/,
    'one package observes joins, reports its state per channel and replies only to active word events');

my @event_fixture = (@observer, '--fixture', $custom_fixture);
write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.join', mode => 'off', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /requires --grant events\.subscribe/,
    'no subscription cannot be mistaken for an off event that was ignored');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.join', version => 2, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe');
ok(!$tested && $test_report =~ /version 2 is not declared/,
    'an unsupported version cannot enter the event bus');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.join', data => {is_self => 'false'}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe');
ok(!$tested && $test_report =~ /invalid event data field 'is_self'/,
    'ambiguous join booleans fail before emission');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.word', data => {word => 'two words'}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe');
ok(!$tested && $test_report =~ /did not reach its bus listener/,
    'the actual word producer rejects non-word input');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.word', mode => 'observe', data => {word => 'salut'}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe');
ok(!$tested && $test_report =~ /Step 1 failed:.*API v3 event.*capability 'irc\.reply' was not granted/,
    'a deferred handler failure is reported even for an observe step expecting silence');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.word', mode => 'observe', data => {word => 'salut'},
        failure => {contains => "capability 'irc.reply' was not granted"}, replies => []},
    {event => 'irc.channel.join', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe');
ok($tested, 'a matched deferred handler failure allows the next event to run')
    or diag($test_report);

my @job_grants = ('--grant', 'scheduler.jobs', '--grant', 'irc.channel_message');
($tested, $test_report) = workshop_cli_1322(@observer,
    '--fixture', 'plugins/examples-v3/channel-observer-v3/jobs.test.json',
    '--grant', 'events.subscribe', '--grant', 'irc.reply', @job_grants);
ok($tested && $test_report =~ /passed 8 offline API v3 command\/event\/job step/,
    'one fixture exercises native job ticks, cross-channel policies and suppression of real timers');

write_fixture_1322($custom_fixture, [{job => 'pulse', channels => {}, replies => []}]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /job fixture requires --grant scheduler\.jobs/,
    'a missing registration cannot pass as a scheduled job with no eligible channels');

write_fixture_1322($custom_fixture, [{job => 'undeclared', channels => {}, replies => []}]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, @job_grants);
ok(!$tested && $test_report =~ /job must be declared by 'channel-observer-v3'/,
    'workshop cannot tick an undeclared scheduler task');

write_fixture_1322($custom_fixture, [
    {job => 'pulse', channels => {'#a[1]' => {}, '#a{1}' => {}}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, @job_grants);
ok(!$tested && $test_report =~ /duplicate IRC channel in job policies/,
    'RFC1459 equivalent channels may not specify two policies for one tick');

write_fixture_1322($custom_fixture, [
    {job => 'pulse', channels => {'#workshop' => {mode => 'observe'}}, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'scheduler.jobs');
ok(!$tested && $test_report =~ /Step 1 failed:.*API v3 job.*capability 'irc\.channel_message' was not granted/,
    'a job failure remains visible in observe even when replies are empty');

my $job_failure = {channel => '#Atelier{1}', contains => "capability 'irc.channel_message' was not granted"};
write_fixture_1322($custom_fixture, [
    {job => 'pulse', channels => {'#atelier[1]' => {}}, failure => $job_failure, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'scheduler.jobs');
ok($tested, 'job failures can target a single channel using RFC1459 identity')
    or diag($test_report);

write_fixture_1322($custom_fixture, [
    {job => 'pulse', channels => {'#atelier[1]' => {}, '#other' => {}},
        failure => $job_failure, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'scheduler.jobs');
ok(!$tested && $test_report =~ /Step 1: expected one job failure, saw 2/,
    'an expected job failure does not mask an additional channel failure');

my @storage_grant = ('--grant', 'storage.kv');
{
    my $storage_tmp = "$tmp/storage-run";
    mkdir $storage_tmp or die $!;
    local $ENV{TMPDIR} = $storage_tmp;
    my @storage_fixture = (@observer,
        '--fixture', 'plugins/examples-v3/channel-observer-v3/storage.test.json', @storage_grant);
    for (1 .. 2) {
        ($tested, $test_report) = workshop_cli_1322(@storage_fixture);
        ok($tested && $test_report =~ /passed 8 offline API v3 command step/,
            'each storage run starts empty and checks writes, RFC1459 channel scopes and suppression');
    }
    opendir my $temp_entries, $storage_tmp or die $!;
    my @leftovers = grep { $_ ne '.' && $_ ne '..' } readdir $temp_entries;
    closedir $temp_entries or die $!;
    is_deeply(\@leftovers, [], 'workshop removes both run directories and their storage files');
}

my $empty_storage = {global => {revision => 0, values => {}}};
write_fixture_1322($custom_fixture, [
    {command => 'workshop_remember', mode => 'off', replies => [], storage => $empty_storage},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /storage assertions require --grant storage\.kv/,
    'a silent command does not allow assertions without the explicit storage grant');

write_fixture_1322($custom_fixture, [
    {command => 'workshop_remember', data => {args => ['channel', 'reel']}, replies => [],
        storage => {channels => {'#workshop' => {revision => 1, values => {note => 'autre'}}}}},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, @storage_grant);
ok(!$tested && $test_report =~ /Step 1 channel storage '#workshop' mismatch.*autre.*reel/s,
    'a storage mismatch identifies the channel and shows expected and captured documents');

($tested, $test_report) = workshop_cli_1322(@observer,
    '--fixture', 'plugins/examples-v3/channel-observer-v3/failures.test.json', @storage_grant);
ok($tested && $test_report =~ /passed 3 offline API v3 command step/,
    'an expected command failure preserves storage and the next write succeeds')
    or diag($test_report);

my $failing_command = {command => 'workshop_remember', data => {args => ['unknown', 'value']},
    failure => {contains => 'Expected a global or channel value'}, replies => []};
write_fixture_1322($custom_fixture, [
    $failing_command,
    {%$failing_command, data => {args => ['global', 'value']}},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, @storage_grant);
ok(!$tested && $test_report =~ /Step 2: expected one command failure, saw 0/,
    'failure history from a previous step cannot satisfy a missing new failure');

write_fixture_1322($custom_fixture, [
    {%$failing_command, failure => {contains => 'Expected .* channel value'}},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, @storage_grant);
ok(!$tested && $test_report =~ /Step 1: expected failure containing .*got: .*Expected a global or channel value/,
    'a different diagnostic fails and the expected fragment is literal');

write_fixture_1322($custom_fixture, [{%$failing_command, mode => 'off'}]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /Step 1: failure requires an active command/,
    'a suppressed invocation cannot be declared as a failure');

write_fixture_1322($custom_fixture, [
    {event => 'irc.channel.join', replies => [], storage => $empty_storage},
    {job => 'pulse', channels => {}, replies => [], storage => $empty_storage},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture, '--grant', 'events.subscribe',
    '--grant', 'scheduler.jobs', @storage_grant);
ok($tested && $test_report =~ /passed 2 offline API v3 command\/event\/job step/,
    'the same read-only storage assertions work on event and job steps');

($tested, $test_report) = workshop_cli_1322(@observer,
    '--fixture', 'plugins/examples-v3/channel-observer-v3/restart.test.json',
    '--grant', 'events.subscribe', '--grant', 'irc.reply', @job_grants, @storage_grant);
ok($tested && $test_report =~ /passed 10 offline API v3 command\/event\/job\/restart step/,
    'restart restores persisted policy and storage, renews jobs and resumes event and command dispatch');

write_fixture_1322($custom_fixture, [
    {restart => JSON::PP::false, replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /restart must be JSON true/,
    'restart requires an explicit JSON true');

write_fixture_1322($custom_fixture, [
    {restart => JSON::PP::true, command => 'last_workshop_join', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /declare one command, event, job, restart or lifecycle/,
    'restart is a distinct fixture step');

($tested, $test_report) = workshop_cli_1322(@observer,
    '--fixture', 'plugins/examples-v3/channel-observer-v3/lifecycle.test.json',
    '--grant', 'events.subscribe', '--grant', 'irc.reply', @job_grants, @storage_grant);
ok($tested && $test_report =~ /passed 11 offline API v3 command\/event\/job\/lifecycle step/,
    'disable blocks dispatch and ticks; enable retains observer state, the job sequence and storage')
    or diag($test_report);

write_fixture_1322($custom_fixture, [
    {lifecycle => 'pause', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /Step 1: lifecycle must be enable or disable/,
    'lifecycle accepts only the two activation actions');

write_fixture_1322($custom_fixture, [
    {command => 'last_workshop_join', expect => 'disabled', replies => []},
]);
($tested, $test_report) = workshop_cli_1322(@event_fixture);
ok(!$tested && $test_report =~ /Step 1: expect must be ran or denied/,
    'an enabled package cannot satisfy an explicit disabled expectation');

Mediabot::Plugin::ScaffoldV3::create(
    directory => $tmp, name => 'restart-python', language => 'python');
write_fixture_1322($custom_fixture, [
    {command => 'restart_python', replies => [['PRIVMSG', '#workshop', 'Bonjour, Pablo!']]},
    {lifecycle => 'disable', replies => []},
    {command => 'restart_python', expect => 'disabled', replies => []},
    {restart => JSON::PP::true, replies => []},
    {command => 'restart_python', mode => 'observe', expect => 'disabled', replies => []},
    {lifecycle => 'enable', replies => []},
    {command => 'restart_python', data => {args => ['Élodie']},
        replies => [['PRIVMSG', '#workshop', 'Bonjour, Élodie!']]},
]);
($tested, $test_report) = workshop_cli_1322('--test', 'restart-python', '--directory', $tmp,
    '--fixture', $custom_fixture, '--grant', 'irc.reply');
ok($tested && $test_report =~ /passed 7 offline API v3 command\/restart\/lifecycle step/,
    'a disabled external command stays blocked after restart and runs once re-enabled')
    or diag($test_report);

$manifest->{commands}{first_greeting}{handler} = 'command_missing';
open my $edited_manifest, '>:raw', "$out->{directory}/plugin.json" or die $!;
print {$edited_manifest} encode_json($manifest) or die $!;
close $edited_manifest or die $!;
($valid, $validation) = validate_workshop_1322('first-v3', '--directory', $tmp);
ok(!$valid, 'the validator reads the author-edited package instead of the witness');
like($validation, qr/command 'first_greeting' has no handler 'command_missing'/,
    'the report identifies the missing method');
done_testing;
