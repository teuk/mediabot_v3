# MB740 — freeze the plugin v2 baseline and keep architecture inventory honest.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Spec;
use JSON::PP ();

sub _slurp_1064 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $contract_path = File::Spec->catfile('.', 'plugins', 'API_V2_CONTRACT.json');
    my $contract = JSON::PP->new->decode(_slurp_1064($contract_path));

    $assert->is($contract->{api}, 2, 'MB740 freezes plugin API 2');
    $assert->is($contract->{status}, 'frozen', 'MB740 marks API v2 frozen');
    $assert->is($contract->{replacement}, 'api 3', 'MB740 names API v3 successor');
    $assert->is($contract->{script_protocol}, 'mediabot-script-v1',
        'MB740 preserves the script wire protocol');

    require Mediabot::PluginManager;
    my @runtime_events = sort keys %Mediabot::PluginManager::ROUTABLE_SCRIPT_EVENTS;
    my @contract_events = sort @{ $contract->{routable_script_events} || [] };
    $assert->is(join(',', @contract_events), join(',', @runtime_events),
        'frozen routed-event list matches PluginManager');

    require Mediabot::ScriptActionRunner;
    my $runner = Mediabot::ScriptActionRunner->new(bot => undef);
    my @runtime_actions = $runner->allowed_action_types;
    my @contract_actions = sort @{ $contract->{action_types} || [] };
    $assert->is(join(',', @contract_actions), join(',', @runtime_actions),
        'frozen action list matches ScriptActionRunner');

    $assert->is($contract->{limits}{manifest_bytes},
        $Mediabot::PluginManager::MAX_SIDECAR_BYTES,
        'manifest size limit matches runtime');
    $assert->is($contract->{limits}{storage_bytes},
        $Mediabot::ScriptActionRunner::MAX_STORE_BYTES,
        'storage byte limit matches runtime');
    $assert->is($contract->{limits}{storage_keys},
        $Mediabot::ScriptActionRunner::MAX_STORE_KEYS,
        'storage key limit matches runtime');
    $assert->is($contract->{limits}{storage_depth},
        $Mediabot::ScriptActionRunner::MAX_STORE_DEPTH,
        'storage depth limit matches runtime');

    my $architecture = _slurp_1064(
        File::Spec->catfile('.', 'docs', 'PLUGIN_ARCHITECTURE.md'));
    $assert->like($architecture, qr/No API v3 plugin receives the full Mediabot object/,
        'architecture denies full bot object to API v3');
    $assert->like($architecture, qr/Plugins are inactive by default/,
        'architecture keeps plugins opt-in');
    $assert->like($architecture, qr/No plugin migration is applied automatically/,
        'architecture rejects automatic plugin DDL');
    $assert->like($architecture, qr/MB740.*No runtime behavior changes/s,
        'MB740 is explicitly documentation-only at runtime');

    my $adr = _slurp_1064(
        File::Spec->catfile('.', 'docs', 'adr', '0001-plugin-platform-evolution.md'));
    $assert->like($adr, qr/Status: accepted for implementation/,
        'plugin direction has an accepted ADR');
    $assert->like($adr, qr/capability-scoped `PluginContext`/,
        'ADR records least-privilege context');
    $assert->like($adr, qr/changes no IRC behavior/,
        'ADR preserves the MB740 runtime boundary');

    my $tool = File::Spec->catfile('.', 'tools', 'mb_architecture_inventory.pl');
    my $inventory = File::Spec->catfile('docs', 'generated', 'COMMAND_INVENTORY.md');
    my $rc = system($^X, $tool, '--check', $inventory);
    $assert->is($rc, 0, 'generated command inventory matches source truth');

    my $generated = _slurp_1064(File::Spec->catfile('.', $inventory));
    $assert->like($generated, qr/\| Internal help entries \| 245 \|/,
        'MB740 records all 245 current built-in help entries');
    $assert->like($generated, qr/\| Help parser anomalies \| 0 \|/,
        'MB741 resolves the two frozen help parser anomalies');
    $assert->like($generated, qr/`roll`.*registry-public.*legacy-public-adapter/s,
        'inventory includes first-wave fun command');
};
