# MB766 — boot wiring, Partyline persistence and machine contract agree.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1137 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $manager = slurp_1137('Mediabot/PluginManager.pm');
    my $partyline = slurp_1137('Mediabot/Partyline/Commands.pm');
    my $main = slurp_1137('mediabot.pl');
    my $sample = slurp_1137('mediabot.sample.conf');
    my $operations = slurp_1137('docs/PLUGIN_OPERATIONS_V3.md');
    my $contract = JSON::PP->new->decode(
        slurp_1137('plugins/API_V3_CONTRACT.json'));

    $assert->is($contract->{milestone}, 'MB767',
        'machine contract advances while retaining persistent startup');
    $assert->is($contract->{boot_persistence}{schema}, 1,
        'machine contract publishes boot-state schema');
    $assert->is($contract->{boot_persistence}{maximum_bytes}, 1048576,
        'machine contract and runtime share the byte bound');
    $assert->is($contract->{boot_persistence}{maximum_packages}, 64,
        'machine contract and runtime share the package bound');
    $assert->is($contract->{boot_persistence}{historical_autoload_dependency},
        JSON::PP::false, 'v3 restore is independent from legacy autoload');
    $assert->is($contract->{boot_persistence}{network_access}, 'none',
        'boot restore is local and deterministic');

    $assert->like($manager,
        qr/sub restore_v3_runtime_state \{/,
        'PluginManager owns validated boot restore');
    $assert->like($manager,
        qr/chmod 0600, \$temporary.*?rename \$temporary, \$path/s,
        'operator ledger uses private atomic publication');
    $assert->like($partyline,
        qr/load_package_v3_persistent.*?set_v3_channel_policy_persistent.*?reset_v3_channel_policy_persistent/s,
        'Partyline load and policy mutations are persistent');
    $assert->like($partyline,
        qr/unregister_plugin_persistent.*?set_v3_enabled_persistent/s,
        'Partyline unload and lifecycle mutations are persistent');
    $assert->like($main,
        qr/load_configured_plugins_if_enabled.*?restore_v3_plugins_from_state/s,
        'v3 restore runs after the historical plugin boot stage');
    $assert->like($main,
        qr/Mediabot::Scheduler->new.*?restore_v3_plugins_from_state/s,
        'v3 restore waits for scheduler-backed package dependencies');
    $assert->like($sample, qr/\.api-v3-runtime-state\.json/,
        'sample configuration documents the core-owned ledger');
    $assert->like($operations, qr/restart restores the exact grants/i,
        'operator guide records restart-persistent posture');
    $assert->like($operations, qr/unload removes it.*next boot/is,
        'operator guide records definitive persistent rollback');
};
