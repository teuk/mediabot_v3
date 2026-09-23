# MB757 — API v3 repository cleanup derives the exact private namespace.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

{
    package Conf1109;
    sub new { bless { dir => $_[1] }, $_[0] }
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
}
{
    package Log1109;
    sub log { 1 }
}
{
    package Metrics1109;
    sub inc { 1 }
    sub set { 1 }
}
{
    package Bot1109;
    sub new {
        my ($class, $dir) = @_;
        return bless {
            conf => Conf1109->new($dir),
            logger => bless({}, 'Log1109'),
            metrics => bless({}, 'Metrics1109'),
        }, $class;
    }
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginManager;

    my $root = tempdir(CLEANUP => 1);
    my $data_dir = "$root/plugin-data";
    my $pm = Mediabot::PluginManager->new(
        bot => Bot1109->new($data_dir),
    );

    my ($ok, $err) = $pm->_store_plugin_data('short-content-v3', {
        legacy => 'keep',
    });
    $assert->ok($ok, 'legacy same-slug fixture is stored');
    ($ok, $err) = $pm->_store_plugin_data('v3-short-content-v3', {
        revision => 3,
        values => { served => '3' },
    });
    $assert->ok($ok, 'API v3 namespaced fixture is stored');

    my ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data('short-content-v3');
    $assert->ok($clear_ok && $removed && !defined($clear_err),
        'API v3 cleanup removes the namespaced repository');
    $assert->ok(!-e "$data_dir/v3-short-content-v3.json",
        'API v3 repository file is gone');
    $assert->ok(-f "$data_dir/short-content-v3.json",
        'legacy same-slug storage remains untouched');

    ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data('short-content-v3');
    $assert->ok($clear_ok && !$removed && !defined($clear_err),
        'clearing an absent API v3 repository is idempotent');

    my $long_name = 'a-very-long-api-v3-package-name-for-cleanup';
    my $repository = $pm->_v3_repository_for($long_name);
    my $commit = $repository->commit(
        expected_revision => 0,
        changes => { proof => 'stored' },
    );
    $assert->ok($commit->{ok}, 'long package fixture commits through repository');
    my @v3_files = glob "$data_dir/v3-*.json";
    $assert->is(scalar(@v3_files), 1,
        'long package storage uses one bounded hashed filename');
    ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data($long_name);
    $assert->ok($clear_ok && $removed && !defined($clear_err),
        'cleanup derives and removes a long package hashed key');
    $assert->ok(!-e $v3_files[0], 'hashed repository file is gone');

    my $sentinel = "$root/sentinel.json";
    open my $sentinel_fh, '>:raw', $sentinel or die $!;
    print {$sentinel_fh} '{"keep":true}';
    close $sentinel_fh;
    make_path($data_dir) unless -d $data_dir;
    my $link = "$data_dir/v3-link-probe.json";
    my $linked = symlink($sentinel, $link);
    $assert->ok($linked && -l $link, 'symlink fixture is present');
    ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data('link-probe');
    $assert->ok($clear_ok && !$removed && !defined($clear_err),
        'API v3 cleanup never follows a symlink');
    $assert->ok(-f $sentinel && -l $link,
        'symlink and outside target remain untouched');

    ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data('../escape');
    $assert->ok(!$clear_ok && !$removed
            && ($clear_err // '') =~ /invalid API v3 package name/,
        'API v3 cleanup rejects path traversal before key derivation');
    ($clear_ok, $removed, $clear_err) =
        $pm->clear_v3_plugin_data('UPPERCASE');
    $assert->ok(!$clear_ok && !$removed,
        'API v3 cleanup applies the runtime lowercase slug contract');

    open my $contract_fh, '<:raw', 'plugins/API_V3_CONTRACT.json' or die $!;
    local $/;
    my $contract = JSON::PP->new->decode(<$contract_fh>);
    close $contract_fh;
    $assert->is($contract->{milestone}, 'MB770',
        'machine contract records the current platform milestone');
    $assert->like($contract->{storage_limits}{operator_cleanup},
        qr/Owner-only clearv3data/,
        'machine contract makes the cleanup gate explicit');
    $assert->ok($contract->{storage_limits}{cleanup_loaded_or_unloaded},
        'machine contract permits lifecycle-independent cleanup');
};
