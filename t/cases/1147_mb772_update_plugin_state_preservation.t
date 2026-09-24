# MB772 — the generic updater preserves API v3 and plugin KV instance state.

use strict;
use warnings;
use utf8;

sub _slurp_1147 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $deploy = _slurp_1147('install/deploy_update.sh');
    my $contract = _slurp_1147('plugins/API_V3_CONTRACT.json');
    my $operations = _slurp_1147('docs/PLUGIN_OPERATIONS_V3.md');
    my $architecture = _slurp_1147('docs/PLUGIN_ARCHITECTURE.md');
    my $api = _slurp_1147('docs/PLUGIN_API_V3.md');
    my $changelog = _slurp_1147('CHANGELOG.md');

    $assert->like($deploy,
        qr/Mediabot::Conf.*?plugins\.DATA_DIR.*?plugin-data/s,
        'updater resolves the configured plugin data directory with core semantics');
    $assert->like($deploy,
        qr/validate_internal_plugin_data_path.*?refusing symbolic-link plugin data path/s,
        'internal plugin data path is validated and symlinks are refused');
    $assert->like($deploy,
        qr/External plugin data remains in place/,
        'absolute external plugin data is not copied into a release');
    $assert->like($deploy,
        qr/cp -a -- "\$\{PLUGIN_DATA_SOURCE\}" "\$\{PLUGIN_DATA_TARGET\}"/,
        'internal plugin state is copied recursively with metadata');
    $assert->like($deploy,
        qr/candidate unexpectedly contains plugin data/,
        'updater refuses to merge instance data with candidate source');
    $assert->like($deploy,
        qr/validate_staged_plugin_data_parent.*?refusing symbolic-link plugin data parent in candidate/s,
        'candidate parent directories cannot redirect the preserved state');

    my $stop = index($deploy, 'Bot stopped.');
    my $copy = index($deploy, 'cp -a -- "${PLUGIN_DATA_SOURCE}"');
    my $rotate = index($deploy, 'Archiving current release:');
    $assert->ok($stop >= 0 && $copy > $stop,
        'plugin state snapshot happens only after the bot stops');
    $assert->ok($rotate > $copy,
        'plugin state reaches the staged tree before release rotation');

    $assert->like($contract,
        qr/"milestone"\s*:\s*"MB772"/,
        'machine contract advances to the updater preservation milestone');
    $assert->like($contract,
        qr/"updater_state_preservation".*?"configuration_source"\s*:\s*"plugins\.DATA_DIR through Mediabot::Conf".*?"symlink_policy"/s,
        'machine contract publishes the updater state boundary');
    $assert->like($operations,
        qr/MB772.*?IRC updater.*?plugins\.DATA_DIR.*?ledger/is,
        'operations guide records updater persistence');
    $assert->like($architecture,
        qr/MB772.*?release rotation.*?plugin.*?state/is,
        'architecture records ownership across release rotation');
    $assert->like($api,
        qr/MB772.*?\.api-v3-runtime-state\.json.*?update/is,
        'API guide records ledger survival across update');
    $assert->like($changelog,
        qr/MB772.*?updater.*?plugin.*?ledger/is,
        'changelog records the discovered persistence gap and repair');
};
