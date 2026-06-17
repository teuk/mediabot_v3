#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $sample = slurp('mediabot.sample.conf');
my $bridge = slurp('Mediabot/Plugin/ScriptDryRun.pm');
my $manager = slurp('Mediabot/PluginManager.pm');
my $bot = slurp('Mediabot/Mediabot.pm');
my $party = slurp('Mediabot/Partyline.pm');

for my $key (qw(SCRIPT COMMANDS ROUTES ACTION_MODE ALLOW_IRC APPLY_REQUIRE_SCOPE)) {
    like($sample, qr/\b\Q$key\E\b/, "sample documents canonical ScriptDryRun key $key");
}

for my $alias (qw(
    PLUGIN_AUTOLOAD PLUGINS_AUTOLOAD
    PLUGINS_ENABLED PLUGIN_ENABLED PLUGINS
    SCRIPT_DRYRUN_SCRIPT SCRIPT_DRYRUN_PATH
    SCRIPT_DRYRUN_COMMANDS SCRIPT_DRYRUN_ROUTES
    SCRIPT_DRYRUN_ACTION_MODE SCRIPT_DRYRUN_ALLOW_IRC
    SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE
)) {
    like($sample, qr/\b\Q$alias\E\b/, "sample documents compatibility alias $alias");
}

like($bridge, qr/'plugins\.ScriptDryRun\.SCRIPT'/,
    'runtime still accepts canonical ScriptDryRun SCRIPT key');
like($bridge, qr/'plugins\.ScriptDryRun\.ROUTES'/,
    'runtime still accepts canonical ScriptDryRun ROUTES key');
like($manager, qr/'PLUGIN_ENABLED'/,
    'PluginManager still accepts singular plugin-list compatibility key');
like($bot, qr/'PLUGIN_AUTOLOAD'/,
    'Mediabot boot gate still accepts singular autoload compatibility key');

like($sample, qr{unscoped fallback may observe a command but does not own/suppress}s,
    'sample explains dry-run fallback ownership');
like($sample, qr/APPLY_REQUIRE_SCOPE=yes rejects fallback.*?execution/s,
    'sample explains apply fallback scope rejection');
like($sample, qr{trusted extensions, not\s+\# a sandbox}s,
    'sample explains trusted-code boundary');

like($party, qr/autoload keys: plugins\.AUTOLOAD, plugins\.autoload, plugins\.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD/,
    'partyline config view lists complete autoload aliases');
like($party, qr/plugin list keys: plugins\.ENABLED, plugins\.enabled, plugins\.PLUGINS, plugins\.plugins, PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS/,
    'partyline config view lists complete plugin-list aliases');
like($party, qr/SCRIPT fallback: used only when no route matches; keep scoped in apply mode/,
    'partyline ScriptDryRun config explains fallback scope');

unlike($sample, qr/^\[plugins\]$/m,
    'sample does not activate plugins section');
unlike($sample, qr/^AUTOLOAD=1$/m,
    'sample does not activate plugin autoload');
unlike($sample, qr/^ACTION_MODE=apply$/m,
    'sample does not activate apply mode');
unlike($sample, qr/^ALLOW_IRC=yes$/m,
    'sample does not activate IRC output');

done_testing();
