# t/cases/390_mb131_ignore_cache.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;
    my $root = File::Spec->catdir($Bin, '..', '..');

    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    open my $hfh, '<', $helpers_file or do { $assert->(0, "cannot open Helpers.pm: $!"); return; };
    my $helpers = do { local $/; <$hfh> };
    close $hfh;

    $assert->($helpers =~ /\$self->\{_ignore_cache\}/, 'isIgnored uses _ignore_cache');
    $assert->($helpers =~ /my \$ttl = 30/, 'isIgnored cache TTL is 30 seconds');
    $assert->($helpers =~ /SELECT hostmask FROM IGNORES WHERE id_channel = 0/, 'global ignores query still present');
    $assert->($helpers =~ /JOIN CHANNEL ON CHANNEL\.id_channel = IGNORES\.id_channel WHERE CHANNEL\.name = \?/, 'channel ignores query still present');
    $assert->($helpers =~ /hostmask_matches/, 'matching still uses Mediabot::Auth hostmask matcher');
    $assert->($helpers =~ /chan\\x00\$channel_key/, 'channel cache key is lower-cased and namespaced');

    my $db_file = File::Spec->catfile($root, 'Mediabot', 'DBCommands.pm');
    open my $dfh, '<', $db_file or do { $assert->(0, "cannot open DBCommands.pm: $!"); return; };
    my $db = do { local $/; <$dfh> };
    close $dfh;

    my $invalidations = () = ($db =~ /delete \$self->\{_ignore_cache\}; # mb131-B4/g);
    $assert->($invalidations >= 2, 'ignore/unignore invalidate _ignore_cache');

    my $ch_file = File::Spec->catfile($root, 'Mediabot', 'ChannelCommands.pm');
    open my $cfh, '<', $ch_file or do { $assert->(0, "cannot open ChannelCommands.pm: $!"); return; };
    my $ch = do { local $/; <$cfh> };
    close $cfh;

    $assert->($ch =~ /delete \$self->\{_ignore_cache\}; # mb131-B4: purge may remove channel-scoped IGNORES rows/,
        'purgeChannel_ctx invalidates _ignore_cache');
};

if (caller) { return $case; }

my $tests = 0;
my $fail = 0;
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
