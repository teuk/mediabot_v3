use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Fcntl qw(:flock);
use JSON::PP;
use POSIX qw(mkfifo);
use Mediabot::Plugin::ChannelRepositoryV3;

my $tmp = tempdir(CLEANUP => 1);
my $new = sub { Mediabot::Plugin::ChannelRepositoryV3->new(directory => "$tmp/data", plugin => $_[0] // 'longest-word-v3', channel => $_[1] // '#test') };
my $a = $new->();
is_deeply($a->snapshot, {revision => 0, values => {}}, 'absent collection reads empty');
ok(!-e "$tmp/data", 'snapshot does not create directories');
ok($a->commit(expected_revision => 0, changes => {p => 'été'})->{ok}, 'atomic collection commit accepts Unicode');
my $b = $new->();
is($b->snapshot->{values}{p}, 'été', 'a fresh repository reads the persisted Unicode value');
my $snap = $b->snapshot; $snap->{values}{p} = 'edited';
is($a->snapshot->{values}{p}, 'été', 'snapshot is detached');
is($b->commit(expected_revision => 0, changes => {p => 'lost'})->{error}, 'conflict', 'stale writer cannot overwrite a newer revision');
ok(!keys %{$new->('other-plugin')->snapshot->{values}}, 'plugin isolation');
ok(!keys %{$new->(undef, '#elsewhere')->snapshot->{values}}, 'channel isolation');
is($new->(undef, '#TEST')->snapshot->{values}{p}, 'été', 'RFC1459 channel case aliases share a collection');
my $path = $a->_path(0);
is((stat($path))[2] & 0777, 0600, 'score file is private');
open my $lock, '+<', "$path.lock" or die $!;
flock($lock, LOCK_EX | LOCK_NB) or die $!;
is($a->commit(expected_revision => 1, changes => {q => 'x'})->{error}, 'busy', 'another process lock does not block the IRC loop');
close $lock;
for my $changes ({'../foreign' => 'x'}, {oversize => 'x' x 2049}, {p => []}) {
    my $ok = eval { $a->commit(expected_revision => 1, changes => $changes); 1 };
    ok(!$ok, 'invalid collection change is refused');
    is($a->snapshot->{revision}, 1, 'rejected transaction preserves the stored revision');
}
{
    local $Mediabot::Plugin::ChannelRepositoryV3::MAX_VALUES = 1;
    ok(!eval { $a->commit(expected_revision => 1, changes => {second => 'x'}); 1 }, 'capacity failure never evicts an existing player');
    is_deeply($a->snapshot->{values}, {p => 'été'}, 'capacity refusal preserves all existing values');
}
ok($a->commit(expected_revision => 1, changes => {q => 'ok'}, delete => ['p'])->{ok}, 'atomic update and deletion');
is_deeply($a->snapshot->{values}, {q => 'ok'}, 'deletion applies to the same revision');
open my $fh, '<:raw', $path or die $!; my $bytes = do { local $/; <$fh> }; close $fh;
chmod 0644, $path;
ok(!eval { $a->snapshot; 1 }, 'publicly readable score file fails closed');
chmod 0600, $path;
unlink $path; symlink "$tmp/foreign", $path or die $!;
ok(!eval { $a->snapshot; 1 }, 'a symlink score file never becomes an empty collection');
ok(!eval { $a->commit(expected_revision => 0, changes => {x => 'y'}); 1 }, 'symlink destination cannot redirect a write');
ok(!-e "$tmp/foreign", 'foreign symlink target is untouched');
unlink $path; open $fh, '>:raw', $path or die $!; print {$fh} '{broken'; close $fh; chmod 0600, $path;
ok(!eval { $a->snapshot; 1 }, 'corrupt score document fails closed instead of resetting totals');
ok(!eval { $a->commit(expected_revision => 0, changes => {x => 'y'}); 1 }, 'corrupt totals are never overwritten');
open $fh, '<:raw', $path or die $!; is(do { local $/; <$fh> }, '{broken', 'corrupt bytes remain available for recovery'); close $fh;
unlink $path; open $fh, '>:raw', $path or die $!; print {$fh} $bytes; close $fh; chmod 0600, $path;
is($a->snapshot->{revision}, 2, 'restored complete state reads normally');

# MB1187: a substituted FIFO must fail before waiting for a writer.
unlink $path or die $!;
mkfifo($path, 0600) or die $!;
for my $operation ('snapshot', 'commit') {
    my $ok = eval {
        local $SIG{ALRM} = sub { die "fixture_timeout\n" };
        alarm 2;
        if ($operation eq 'snapshot') { $a->snapshot }
        else { $a->commit(expected_revision => 2, changes => {q => 'lost'}) }
        alarm 0;
        1;
    };
    my $error = $@; alarm 0;
    ok(!$ok, "$operation refuses a FIFO state file");
    like($error, qr/\Achannel_storage_permissions\n\z/,
        "$operation rejects the opened object without waiting for a FIFO writer");
    ok(-p $path, "$operation preserves the unexpected object for diagnosis");
}
unlink $path or die $!;
open $fh, '>:raw', $path or die $!; print {$fh} $bytes; close $fh or die $!;
chmod 0600, $path;
{
    local $Mediabot::Plugin::ChannelRepositoryV3::MAX_BYTES = length($bytes);
    is($a->snapshot->{revision}, 2, 'state exactly at the byte limit remains readable');
}
{
    local $Mediabot::Plugin::ChannelRepositoryV3::MAX_BYTES = length($bytes)-1;
    ok(!eval {$a->snapshot;1}, 'state exceeding the byte limit is refused');
}
is_deeply($a->snapshot->{values}, {q=>'ok'}, 'restoring regular state recovers the original scores');

my $old = "$tmp/data/v3-collections"; rename $old, "$old.saved" or die $!; symlink "$old.saved", $old or die $!;
ok(!eval { $a->snapshot; 1 }, 'symlink ancestor is refused');
unlink $old; rename "$old.saved", $old or die $!;
ok($new->('other-plugin')->commit(expected_revision => 0, changes => {keep => 'foreign'})->{ok}, 'another plugin has independent data');
my $cleared = Mediabot::Plugin::ChannelRepositoryV3->clear_plugin(directory => "$tmp/data", plugin => 'longest-word-v3');
is($cleared, 1, 'core cleanup removes only the selected plugin collection');
is_deeply($a->snapshot->{values}, {}, 'selected collection is empty after owner cleanup');
is($new->('other-plugin')->snapshot->{values}{keep}, 'foreign', 'owner cleanup preserves another plugin');

# MB1188: cleanup must enforce the same lock permissions as ordinary writes.
for my $fault ('permissions', 'busy') {
    my $plugin="cleanup-$fault";
    my @repos=map {$new->($plugin,$_)} ('#one','#two');
    $_->commit(expected_revision=>0, changes=>{keep=>'score'}) for @repos;
    my @paths=sort map {$_->_path(0)} @repos;
    my $lock_path=$paths[-1].'.lock';
    my $inode=(stat($lock_path))[1];
    my $held;
    if ($fault eq 'permissions') {chmod 0644,$lock_path or die $!}
    else {
        open $held,'+<',$lock_path or die $!;
        flock($held,LOCK_EX|LOCK_NB) or die $!;
    }
    my $ok=eval {
        Mediabot::Plugin::ChannelRepositoryV3->clear_plugin(directory=>"$tmp/data",plugin=>$plugin);
        1;
    };
    my $error=$@;
    ok(!$ok,"cleanup refuses $fault on a later channel lock");
    like($error,$fault eq 'permissions' ? qr/\Achannel_storage_lock\n\z/ : qr/\Achannel_storage_busy\n\z/,
        'cleanup reports its bounded lock error');
    for my $repo (@repos) {
        is_deeply($repo->snapshot,{revision=>1,values=>{keep=>'score'}},
            'refused cleanup preserves every channel collection');
    }
    close $held if $held;
    chmod 0600,$lock_path or die $!;
    is(Mediabot::Plugin::ChannelRepositoryV3->clear_plugin(directory=>"$tmp/data",plugin=>$plugin),
        2,'cleanup succeeds after the lock problem is resolved');
    is((stat($lock_path))[1],$inode,'cleanup preserves the original lock inode');
}
done_testing;
