# MB771 — channel-activity-v3 becomes the second ledger-backed promotion.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1146 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp_1146('plugins/API_V3_CONTRACT.json'));
    my $manifest = JSON::PP->new->decode(
        _slurp_1146('plugins/channel-activity-v3/plugin.json'));
    my $promotion = $contract->{development_promotion};
    my $history = $contract->{development_promotion_history};

    $assert->is($contract->{milestone}, 'MB771',
        'machine contract records the activity promotion milestone');
    $assert->is($promotion->{milestone}, 'MB771',
        'current development promotion is versioned');
    $assert->is($promotion->{package}, 'channel-activity-v3',
        'current promotion names the reviewed activity package');
    $assert->is($promotion->{channel}, '#test',
        'promotion is limited to the development channel');
    $assert->is($promotion->{mode}, 'on',
        'accepted activity policy is authoritative on');
    $assert->is($promotion->{scope}, 'single development channel',
        'activity promotion scope remains deliberately narrow');
    $assert->like($promotion->{evidence},
        qr/MB770.*observe.*on.*compare.*heatmap.*CommandAsync.*zero failures.*restart/i,
        'promotion binds parity, completion, health and restart evidence');
    $assert->is($promotion->{boot_autoload}, JSON::PP::false,
        'promotion does not revive historical autoload');
    $assert->is($promotion->{persistent_operator_state}, JSON::PP::true,
        'activity posture is held by the core boot ledger');
    $assert->like($promotion->{restart_behavior},
        qr/exact grants.*enabled.*on policy/i,
        'restart restores exact activity authority and lifecycle');
    $assert->like($promotion->{explicit_rollback},
        qr/policy off.*disable.*unload/i,
        'activity rollback remains explicit and bounded');
    $assert->is($promotion->{production_channels}, 0,
        'development promotion grants no production channel');

    $assert->is(ref($history), 'ARRAY',
        'prior promotions remain a machine-readable history');
    $assert->is(join(',', map { $_->{milestone} } @$history),
        'MB764,MB767',
        'factoid and quote promotions remain ordered history');
    $assert->is(join(',', map { $_->{package} } @$history),
        'factoids-v3,quotes-v3',
        'historical promoted packages remain explicit');

    $assert->is($manifest->{activation}{default}, 'off',
        'promoted package source remains default-off');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.channel_activity.read,irc.reply,irc.notice',
        'promotion grants exactly the three manifest capabilities');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'compare,heatmap',
        'promotion contains only compare and heatmap');

    my $plan = _slurp_1146('docs/CHANNEL_ACTIVITY_V3_PLAN.md');
    my $guide = _slurp_1146('docs/PLUGIN_V3_PROMOTION.md');
    my $api = _slurp_1146('docs/PLUGIN_API_V3.md');
    my $operations = _slurp_1146('docs/PLUGIN_OPERATIONS_V3.md');
    my $architecture = _slurp_1146('docs/PLUGIN_ARCHITECTURE.md');
    my $readme = _slurp_1146('plugins/channel-activity-v3/README.md');
    my $changelog = _slurp_1146('CHANGELOG.md');

    $assert->like($guide,
        qr/policy channel-activity-v3 #test observe.*?policy channel-activity-v3 #test on/s,
        'promotion guide requires observe before on');
    $assert->like($guide,
        qr/quotes-v3.*?channel-activity-v3.*?ready/is,
        'promotion guide protects the existing quote posture');
    $assert->like($guide,
        qr/policy channel-activity-v3 #test off.*?disable channel-activity-v3.*?unload channel-activity-v3/s,
        'promotion guide freezes explicit rollback order');
    $assert->like($plan,
        qr/MB771.*?exact grants.*?clean restart.*?quotes-v3/is,
        'activity plan records persistence and quote non-regression');
    $assert->like($api,
        qr/MB771.*?channel-activity-v3.*?boot\s+ledger.*?production remains untouched/is,
        'API guide records the development-only ledger posture');
    $assert->like($operations,
        qr/MB771.*?enabled.*?on.*?quotes-v3/is,
        'operations guide records the retained activity posture');
    $assert->like($architecture,
        qr/MB771.*?persistent activity promotion.*?development `#test`/is,
        'architecture records the second controlled promotion');
    $assert->like($readme,
        qr/MB771.*?development `#test`.*?default-off.*?production/is,
        'package guide distinguishes operator intent from source defaults');
    $assert->like($changelog,
        qr/mb771.*?channel observatory.*?restart.*?production/is,
        'changelog records the controlled activity promotion');
};
