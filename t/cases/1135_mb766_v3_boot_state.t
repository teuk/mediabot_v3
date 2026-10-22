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

    # MB912: real disk and cold restores must retain Unicode config/channel keys.
    for my $vector (
        ['ascii', '#test', 'ASCII prefix', 'on'],
        ['latin1', '#caf'.chr(0xe9), 'café', 'observe'],
        ['bmp', '#東京', '東京', 'on'],
        ['supplementary', '#test', '🦉 café 東京', 'off'],
        ['combining', '#test', "Cafe\x{301} 🪄", 'on'],
    ) {
        my ($label, $channel, $text, $mode) = @$vector;
        my $data_dir = tempdir(CLEANUP => 1);
        my $state_path = "$data_dir/.api-v3-runtime-state.json";
        my $writer = manager_1135($data_dir);
        my (@warnings, $reader, $raw, $decoded, $report, $error);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            eval {
                $writer->load_package_v3_persistent('short-content-v3', grants => [
                    qw(http.fetch irc.reply storage.kv)
                ]);
                $writer->set_v3_channel_policy_persistent('short-content-v3',
                    $channel, mode => $mode, config => { %config, prefix => $text });
                $writer->set_v3_enabled_persistent('short-content-v3', 1);
                open my $stored, '<:raw', $state_path or die "$state_path: $!";
                $raw = do { local $/; <$stored> };
                close $stored or die "$state_path: $!";
                $decoded = JSON::PP->new->utf8->decode($raw);
                $reader = manager_1135($data_dir);
                $report = $reader->restore_v3_runtime_state;
                1;
            } or $error = $@ || 'roundtrip failed';
        }
        my $restored = $reader && $reader->v3_channel_policy('short-content-v3', $channel);
        my $wire_policy = $decoded && $decoded->{packages}{'short-content-v3'}{policies}{$channel};
        my $same = !$error && !@warnings && $restored && $wire_policy
            && $restored->{channel} eq $channel && $restored->{mode} eq $mode
            && $restored->{config}{prefix} eq $text && $wire_policy->{config}{prefix} eq $text
            && $reader->is_enabled('short-content-v3') && @{$report->{loaded}} == 1
            && !@{$report->{errors}} && ((stat($state_path))[2] & 07777) == 0600;
        if ($label eq 'ascii' && defined $raw) {
            $same &&= $raw eq JSON::PP->new->canonical->encode($writer->v3_runtime_state_snapshot);
        }
        $assert->ok($same, "mb912: $label survives persistent policy, enable and a cold restore without warnings");
        $writer->unregister_plugin('short-content-v3');
        $reader->unregister_plugin('short-content-v3') if $reader;
    }

    {
        my $data_dir = tempdir(CLEANUP => 1);
        my $writer = manager_1135($data_dir);
        $writer->load_package_v3('short-content-v3', grants => []);
        $writer->set_v3_channel_policy('short-content-v3', '#test', mode => 'on',
            config => { %config, prefix => '🦉 東京' });
        my ($stored, $why) = $writer->store_v3_runtime_state;
        die $why unless $stored;
        my $state_path = "$data_dir/.api-v3-runtime-state.json";
        open my $fh, '<:raw', $state_path or die "$state_path: $!";
        my $before = do { local $/; <$fh> }; close $fh;
        {
            local $Mediabot::PluginManager::V3_RUNTIME_STATE_MAX_BYTES = length($before);
            ($stored, $why) = $writer->store_v3_runtime_state;
            $assert->ok($stored, 'mb912: serialized state is accepted at its exact byte limit');
        }
        $writer->set_v3_channel_policy('short-content-v3', '#test', mode => 'on',
            config => { %config, prefix => '🦊 東京' });
        {
            local $Mediabot::PluginManager::V3_RUNTIME_STATE_MAX_BYTES = length($before) - 1;
            ($stored, $why) = $writer->store_v3_runtime_state;
        }
        open $fh, '<:raw', $state_path or die "$state_path: $!";
        my $after = do { local $/; <$fh> }; close $fh;
        $assert->ok(!$stored && $why =~ /byte limit/ && $after eq $before
                && !-e "$state_path.tmp.$$",
            'mb912: one byte over the limit refuses before changing the saved state');
        $writer->unregister_plugin('short-content-v3');
    }

    {
        # The reader is unchanged: keep previously emitted Latin-1 state readable.
        my $data_dir = tempdir(CLEANUP => 1);
        my $writer = manager_1135($data_dir);
        $writer->load_package_v3('short-content-v3', grants => []);
        $writer->set_v3_channel_policy('short-content-v3', '#test', mode => 'on',
            config => { %config, prefix => 'café' });
        my $legacy = JSON::PP->new->canonical->encode($writer->v3_runtime_state_snapshot);
        utf8::downgrade($legacy, 1) or die 'Latin-1 witness must fit in bytes';
        open my $fh, '>:raw', "$data_dir/.api-v3-runtime-state.json" or die $!;
        print {$fh} $legacy; close $fh or die $!;
        my $reader = manager_1135($data_dir);
        my $report = $reader->restore_v3_runtime_state;
        my $policy = $reader->v3_channel_policy('short-content-v3', '#test');
        $assert->ok(!@{$report->{errors}} && @{$report->{loaded}} == 1
                && $policy && $policy->{config}{prefix} eq 'café',
            'mb912: historical Latin-1 state still restores through the existing reader');
        $writer->unregister_plugin('short-content-v3');
        $reader->unregister_plugin('short-content-v3');
    }
};
