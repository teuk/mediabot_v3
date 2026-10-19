use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Temp qw(tempdir);
use File::Spec;
use File::Copy qw(copy);
use File::Path qw(make_path);
use Mediabot::Hailo::BrainRegistry;

{
    package MB851::Brain;
    sub new {
        my ($class, $path) = @_;
        my $bytes = 'new brain fixture';
        if (-f $path) {open my $fh, '<:raw', $path or die $!; local $/; $bytes = <$fh>; close $fh}
        my $self = bless {path => $path, bytes => $bytes, saves => 0}, $class;
        $self->save unless -f $path;
        return $self;
    }
    sub save {
        my ($self) = @_;
        open my $fh, '>:raw', $self->{path} or die $!;
        print {$fh} $self->{bytes} or die $!; close $fh or die $!;
        $self->{saves}++; return 1;
    }
}
sub mb851_registry {
    return Mediabot::Hailo::BrainRegistry->new(factory => sub {MB851::Brain->new($_[0])}, @_);
}
my $tmp = tempdir(CLEANUP => 1);
my @legacy = (
    ['ExampleNET', '#R[oo]m', "examplenet\0#r{oo}m"],
    ['Réseau', '#Café', "réseau\0#café"],
    ['net', encode('UTF-8', '#Café'), 'net' . "\0" . encode('UTF-8', '#café')],
);
for my $index (0..$#legacy) {
    for my $flag (0,1) {
        my ($network, $channel, $old_bytes) = @{$legacy[$index]};
        utf8::downgrade($old_bytes, 1) or die 'bad legacy key fixture';
        if ($flag) {utf8::upgrade($network); utf8::upgrade($channel)}
        else {utf8::downgrade($network, 1); utf8::downgrade($channel, 1)}
        my $registry = mb851_registry(root => File::Spec->catdir($tmp, "old-$index-$flag"), network => $network);
        my $old_id = sha256_hex($old_bytes);
        is($registry->brain_id_for($channel), $old_id, "legacy $index/$flag retains exact durable brain ID");
        is($registry->brain_path_for($channel), File::Spec->catfile($registry->{root}, "$old_id.brn"),
            "legacy $index/$flag retains exact opaque filename");
    }
}

my @wide = (['Epiknet', '#東京'], ['Réseau 🧭', '#i/o'], ['net', '#café-🧭']);
for my $index (0..$#wide) {
    my ($network, $channel) = @{$wide[$index]};
    my $registry = mb851_registry(root => File::Spec->catdir($tmp, "wide-$index"), network => $network);
    my ($id, $warning) = (undef, ''); my $ok;
    {local $SIG{__WARN__} = sub {$warning .= $_[0]}; $ok = eval {$id = $registry->brain_id_for($channel); 1}}
    ok($ok, 'wide network/channel can select a brain ID');
    is($warning, '', 'wide brain identity emits no warning');
    my $canonical = $registry->canonical_channel($channel);
    my $expected = sha256_hex(encode('UTF-8', lc($network) . "\0" . $canonical));
    is($id, $expected, 'wide identity hashes explicit UTF-8 under existing fold rules');
    my $brain; $ok = eval {$brain = $registry->brain_for($channel); 1};
    ok($ok && $brain, 'wide channel opens through the actual brain registry factory');
    my $path = File::Spec->catfile($registry->{root}, "$expected.brn");
    ok(-f $path && !-l $path, 'wide identity produces an ordinary private brain file');
    is(-f $path ? ((stat $path)[2] & 0777) : 0, 0600, 'wide brain file retains private mode');
    is($registry->stats->{open_brains}, 1, 'wide brain occupies one normal cache entry');
}

# Open the pre-existing legacy filename, then evict it for a Unicode channel
# and reopen it in a fresh registry. No history rename, migration or reset.
my $root = File::Spec->catdir($tmp, 'continuity');
my $registry = mb851_registry(root => $root, network => 'Epiknet', max_open => 1);
my $old_id = sha256_hex("epiknet\0#café");
my $old_path = File::Spec->catfile($root, "$old_id.brn");
my $old_bytes = "pre-existing learned bytes\0\xff\n";
{open my $fh, '>:raw', $old_path or die $!; print {$fh} $old_bytes; close $fh; chmod 0600, $old_path}
my $old = $registry->brain_for('#Café');
is($old->{bytes}, $old_bytes, 'existing Latin-1 channel reopens its original learned bytes');
my $wide; my $opened = eval {$wide = $registry->brain_for('#東京'); 1};
ok($opened && $wide, 'Unicode channel can replace the least-recently-used open brain');
ok($old->{saves} >= 1, 'existing brain is saved before eviction');
ok($registry->stats->{open_brains} <= 1, 'Unicode support preserves the open-brain ceiling');
ok($registry->save_all, 'ordinary save-all works after Unicode selection');
undef $registry;
my $fresh = mb851_registry(root => $root, network => 'Epiknet');
is($fresh->brain_path_for('#Café'), $old_path, 'fresh registry resolves the same legacy path');
is($fresh->brain_for('#Café')->{bytes}, $old_bytes, 'learned bytes survive save, eviction and reopening unchanged');
my $second = eval {$fresh->brain_for('#東京')};
ok($second && $second != $fresh->brain_for('#Café'), 'Unicode and legacy channels keep isolated brain objects');
is($fresh->stats->{seeded_brains}, 0, 'opening Unicode brain does not reset or reseed existing history');

for my $bad (undef, 'private', "#bad\nchannel", {}) {
    ok(!eval {$fresh->brain_id_for($bad); 1}, 'invalid channel remains rejected before hashing');
}
# The security audit must follow the new octet boundary without weakening
# network/channel scoping or private-file checks. Only public Hailo source is
# copied; all other audit sections intentionally lack their fixture files.
my $audit_root = File::Spec->catdir($tmp, 'audit');
make_path(File::Spec->catdir($audit_root, 'Mediabot', 'Hailo'));
for my $name (qw(BrainRegistry.pm PostEditor.pm PostEditRuntime.pm)) {
    copy("Mediabot/Hailo/$name", File::Spec->catfile($audit_root, 'Mediabot', 'Hailo', $name)) or die $!;
}
my $fixture_path = File::Spec->catfile($audit_root, 'Mediabot', 'Hailo', 'BrainRegistry.pm');
my $registry_source;
{open my $fh, '<:raw', $fixture_path or die $!; local $/; $registry_source = <$fh>; close $fh}
sub mb851_audit_output {
    open my $fh, '-|', $^X, 'tools/security_audit.pl', '--root', $audit_root or die $!;
    local $/; my $report = <$fh>; close $fh;
    return $report;
}
like(mb851_audit_output(), qr/\[ok\]\s+Hailo brain identity is network.channel.scoped/,
    'real security audit recognizes the scoped digest');
for my $change (
    ['network', sub {$_[0] =~ s/(join\s+"\\x00",\s*)\$self->\{network\}/$1'fixed-network'/}],
    ['channel', sub {$_[0] =~ s/(join\s+"\\x00",\s*\$self->\{network\},\s*)\$key/$1'fixed-channel'/}],
    ['symlink', sub {$_[0] =~ s/Hailo brain path must not be a symbolic link/removed private path guard/g}],
    ['permissions', sub {$_[0] =~ s/umask 0077/umask 0000/g}],
    ['digest input', sub {$_[0] =~ s/return sha256_hex\(\$identity\)/return sha256_hex('unscoped')/ ||
        $_[0] =~ s/return sha256_hex\(join [^;]+/return sha256_hex('unscoped')/}],
) {
    my $mutant = $registry_source;
    ok($change->[1]->($mutant), "security $change->[0] mutation changes its fixture");
    {open my $fh, '>:raw', $fixture_path or die $!; print {$fh} $mutant; close $fh}
    like(mb851_audit_output(), qr/\[FAIL\] Hailo per-channel brain isolation contract is incomplete/,
        "real security audit rejects missing $change->[0] boundary");
}
done_testing;
