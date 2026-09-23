# MB770 — inert activity package and reversible migration are source-locked.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1144 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp_1144('plugins/API_V3_CONTRACT.json'));
    my $manifest = JSON::PP->new->decode(
        _slurp_1144('plugins/channel-activity-v3/plugin.json'));

    $assert->is($contract->{milestone}, 'MB770',
        'machine contract records the activity adoption milestone');
    $assert->is($manifest->{name}, 'channel-activity-v3',
        'manifest names the inert activity package');
    $assert->is($manifest->{activation}{default}, 'off',
        'installation grants no activity authority');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.channel_activity.read,irc.reply,irc.notice',
        'manifest requests only reviewed activity and output capabilities');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'compare,heatmap', 'manifest adopts exactly two public commands');
    for my $name (qw(compare heatmap)) {
        $assert->is($manifest->{commands}{$name}{migration},
            'legacy-public-fallback',
            "$name uses the reversible saved-handler bridge");
    }

    my $migration = $contract->{channel_activity_migration};
    $assert->is($migration->{package}, 'channel-activity-v3',
        'contract binds migration to the reviewed package');
    $assert->is(join(',', @{ $migration->{commands} }),
        'compare,heatmap', 'contract lists the complete migration surface');
    $assert->is($migration->{writes}, 'none',
        'migration cannot change channel activity data');
    $assert->like($migration->{observe_behavior},
        qr/suppressed.*historical fallback/i,
        'observe leaves the historical handler solely visible');
    $assert->like($migration->{rollback}, qr/off.*disable.*unload/i,
        'contract names every immediate rollback step');

    my $catalogue = _slurp_1144('Mediabot/BuiltinCommandCatalog.pm');
    $assert->like($catalogue, qr/\bcompare\s+heatmap\b/,
        'both migration targets remain registry-native built-ins');
    my $plan = _slurp_1144('docs/CHANNEL_ACTIVITY_V3_PLAN.md');
    my $api = _slurp_1144('docs/PLUGIN_API_V3.md');
    my $architecture = _slurp_1144('docs/PLUGIN_ARCHITECTURE.md');
    my $operations = _slurp_1144('docs/PLUGIN_OPERATIONS_V3.md');
    my $changelog = _slurp_1144('CHANGELOG.md');
    $assert->like($plan,
        qr/MB770.*?channel-activity-v3.*?observe.*?rollback/is,
        'activity plan records adoption and rollback evidence');
    $assert->like($api,
        qr/channel-activity-v3.*?compare.*?heatmap.*?legacy-public-fallback/is,
        'API guide documents the exact adopted commands');
    $assert->like($architecture,
        qr/MB770.*?reversible.*?compare.*?heatmap/is,
        'architecture records the second-wave adoption');
    $assert->like($operations,
        qr/MB770.*?channel-activity-v3.*?observe.*?on/is,
        'operations guide records the supervised policy path');
    $assert->like($changelog, qr/MB770.*?channel activity/is,
        'changelog records the activity command migration');
};
