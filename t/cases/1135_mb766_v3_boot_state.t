# MB766 — exact API v3 operator posture survives a clean manager restart.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Temp qw(tempdir);
use JSON::PP ();

{
    package T1135::Conf;
    sub new { bless { dir => $_[1] }, $_[0] }
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
}

{
    package T1135::Log;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; 1 }
}

{
    package T1135::Bot;
    sub new {
        my ($class, $dir) = @_;
        require Mediabot::CommandRegistry;
        return bless {
            conf => T1135::Conf->new($dir),
            logger => T1135::Log->new,
            registry => Mediabot::CommandRegistry->new,
        }, $class;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

sub manager_1135 {
    my ($dir) = @_;
    require Mediabot::PluginManager;
    return Mediabot::PluginManager->new(
        bot => T1135::Bot->new($dir), plugin_dir => 'plugins');
}

return sub {
    my ($assert) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/.api-v3-runtime-state.json";
    my %config = (
        endpoint => 'https://example.net/mb766.json',
        json_path => 'name', language => 'en',
        cache_ttl_seconds => 120, max_chars => 200, prefix => 'MB766: ',
    );

    my $first = manager_1135($dir);
    $first->load_package_v3_persistent('short-content-v3', grants => [
        qw(http.fetch irc.reply storage.kv)
    ]);
    $first->set_v3_channel_policy_persistent(
        'short-content-v3', '#test', mode => 'on', config => \%config);
    $first->set_v3_enabled_persistent('short-content-v3', 1);

    $assert->ok(-f $path && !-l $path,
        'core-owned runtime ledger is a regular file');
    $assert->is((stat($path))[2] & 07777, 0600,
        'runtime ledger is private');
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $document = JSON::PP->new->decode($raw);
    $assert->is($document->{schema}, 1,
        'runtime ledger carries an explicit schema');
    $assert->ok(!exists($document->{packages}{'short-content-v3'}{package_dir}),
        'runtime ledger contains no package path');
    $assert->is(
        join(',', @{ $document->{packages}{'short-content-v3'}{grants} }),
        'http.fetch,irc.reply,storage.kv',
        'exact capability grants are persisted');

    my $second = manager_1135($dir);
    my $report = $second->restore_v3_runtime_state;
    $assert->is(scalar @{ $report->{loaded} }, 1,
        'one persisted package restores');
    $assert->is(scalar @{ $report->{errors} }, 0,
        'valid restore reports no error');
    $assert->ok($second->is_enabled('short-content-v3'),
        'enabled lifecycle survives restart');
    my $policy = $second->v3_channel_policy('short-content-v3', '#test');
    $assert->is($policy->{mode}, 'on',
        'authoritative channel policy survives restart');
    $assert->is($policy->{config}{endpoint}, $config{endpoint},
        'typed policy configuration survives restart');

    $second->unregister_plugin_persistent('short-content-v3');
    my $third = manager_1135($dir);
    my $empty = $third->restore_v3_runtime_state;
    $assert->is(scalar @{ $empty->{loaded} }, 0,
        'persistent unload removes the next-boot package');
    $assert->is($third->count, 0,
        'persistent unload leaves a cold manager empty');
};
