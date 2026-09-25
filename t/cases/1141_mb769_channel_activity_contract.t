# MB769 — public contract, roadmap and MB768 evidence are source-locked.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB786',
        'API contract advances beyond the channel-activity authority milestone');
    $assert->ok(grep($_ eq 'data.channel_activity.read',
        @{ $contract->{implemented_capabilities} }),
        'implemented capabilities include channel activity reads');
    $assert->is(join(',', @{ $contract->{channel_activity_read_limits}{operations} }),
        'compare,heatmap', 'only two activity operations are exposed');
    $assert->is($contract->{channel_activity_read_limits}{channel_source},
        'invocation policy', 'plugins cannot choose an activity channel');
    $assert->is($contract->{channel_activity_read_limits}{observe_reads},
        'allowed', 'observe remains safe for activity comparisons');
    $assert->is($contract->{channel_activity_read_limits}{writes},
        'none', 'activity authority cannot mutate domain data');
    $assert->is($contract->{production_pilots}{quotes_v3}{milestone},
        'MB768', 'MB768 production pilot is recorded');
    $assert->is($contract->{production_pilots}{quotes_v3}{final_mode},
        'observe', 'production quotes posture remains observe');
    $assert->is($contract->{production_pilots}{quotes_v3}{quote_rows_changed},
        0, 'production pilot changed no quote row');

    for my $class (qw(
        Mediabot::Plugin::ActivityComparisonV3
        Mediabot::Plugin::ActivityHeatmapV3
    )) {
        $assert->ok(grep($_ eq $class, @{ $contract->{plugin_receives} }),
            "$class is an explicit detached plugin value");
    }

    for my $manifest (grep { $_ !~ m{/channel-activity-v3/} }
            glob('plugins/*/plugin.json')) {
        my $doc = JSON::PP->new->decode(_slurp($manifest));
        $assert->ok(!grep($_ eq 'data.channel_activity.read',
            @{ $doc->{capabilities} || [] }),
            "$manifest cannot exercise the new authority yet");
    }

    my $api = _slurp('docs/PLUGIN_API_V3.md');
    my $architecture = _slurp('docs/PLUGIN_ARCHITECTURE.md');
    my $plan = _slurp('docs/CHANNEL_ACTIVITY_V3_PLAN.md');
    my $production = _slurp('docs/QUOTE_PRODUCTION_V3_PILOT.md');
    my $adr = _slurp('docs/adr/0001-plugin-platform-evolution.md');
    my $changelog = _slurp('CHANGELOG.md');
    $assert->like($api,
        qr/data\.channel_activity\.read.*?compare.*?heatmap.*?observe/is,
        'API guide documents the bounded activity facade');
    $assert->like($architecture,
        qr/MB769.*?second extraction wave.*?read-only/is,
        'architecture opens the new extraction wave explicitly');
    $assert->like($plan,
        qr/compare.*?heatmap.*?no package requests/is,
        'migration plan separates authority from command adoption');
    $assert->like($production,
        qr/MB768.*?#i\/o.*?observe.*?no quote row/is,
        'production quote evidence is documented');
    $assert->like($adr,
        qr/MB769.*?data\.channel_activity\.read/is,
        'ADR records the new authority decision');
    $assert->like($changelog, qr/MB768.*?production/is,
        'changelog records the production pilot');
    $assert->like($changelog, qr/MB769.*?channel activity/is,
        'changelog records the next authority');
};
