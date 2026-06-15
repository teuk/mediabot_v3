#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib '.';
use Mediabot::PluginManager;

{
    package MB266::ObjConf;
    sub new { my $class = shift; return bless { @_ }, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $pm = Mediabot::PluginManager->new;

my $empty_array_fallback = $pm->configured_modules_from_conf({
    'plugins.ENABLED' => [],
    'PLUGINS'         => 'Mediabot::Plugin::ScriptDryRun',
});

is_deeply(
    $empty_array_fallback->{modules},
    [ 'Mediabot::Plugin::ScriptDryRun' ],
    'empty ARRAY in first plugin key does not mask fallback PLUGINS key',
);
is_deeply($empty_array_fallback->{invalid}, [], 'empty ARRAY fallback produces no invalid module noise');

my $hash_fallback = $pm->configured_modules_from_conf({
    'plugins.ENABLED' => { bad => 1 },
    'PLUGINS'         => 'Mediabot::Plugin::ScriptDryRun',
});

is_deeply(
    $hash_fallback->{modules},
    [ 'Mediabot::Plugin::ScriptDryRun' ],
    'HASH ref in first plugin key does not mask fallback PLUGINS key',
);
is_deeply($hash_fallback->{invalid}, [], 'HASH ref is skipped instead of reported as HASH(...) invalid module');

my $hash_only = $pm->configured_modules_from_conf({
    'plugins.ENABLED' => { bad => 1 },
});

is_deeply($hash_only->{modules}, [], 'HASH-only plugin config enables no module');
is_deeply($hash_only->{invalid}, [], 'HASH-only plugin config never stringifies HASH(...) as invalid');
ok(!defined $hash_only->{raw}, 'HASH-only plugin config is not considered meaningful raw config');

my $nested_list = $pm->configured_modules_from_conf({
    'plugins.ENABLED' => [
        'Mediabot::Plugin::ScriptDryRun',
        [ 'Mediabot::Plugin::Demo' ],
        { bad => 1 },
    ],
});

is_deeply(
    $nested_list->{modules},
    [ 'Mediabot::Plugin::ScriptDryRun', 'Mediabot::Plugin::Demo' ],
    'nested ARRAY plugin config keeps valid module names',
);
is_deeply($nested_list->{invalid}, [], 'nested HASH refs inside plugin list are skipped without invalid noise');

my $object_conf = MB266::ObjConf->new(
    'plugins.ENABLED' => [],
    'PLUGINS'         => 'Mediabot::Plugin::ScriptDryRun Mediabot::Plugin::Demo',
);

my $object_result = $pm->configured_modules_from_conf($object_conf);
is_deeply(
    $object_result->{modules},
    [ 'Mediabot::Plugin::ScriptDryRun', 'Mediabot::Plugin::Demo' ],
    'object conf get() path also skips empty ARRAY and uses fallback plugin key',
);

my $custom_key_fallback = $pm->configured_modules_from_conf({
    'custom.plugins' => [],
    'PLUGINS'        => 'Mediabot::Plugin::ScriptDryRun',
}, key => 'custom.plugins');

is_deeply(
    $custom_key_fallback->{modules},
    [ 'Mediabot::Plugin::ScriptDryRun' ],
    'custom configured key with empty ARRAY does not mask default fallback keys',
);

my $source = do {
    open my $fh, '<', 'Mediabot/PluginManager.pm' or die $!;
    local $/;
    <$fh>;
};

like($source, qr/mb266-B1/, 'PluginManager source contains mb266 list-ref guard marker');
like($source, qr/mb266-B2/, 'PluginManager source contains mb266 fallback guard marker');
unlike($source, qr/system\s*\(/, 'mb266 PluginManager config guard does not introduce system()');

done_testing();
