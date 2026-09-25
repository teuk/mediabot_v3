# MB778 — playful-v3 becomes the next ledger-backed development promotion.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1148 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp_1148('plugins/API_V3_CONTRACT.json'));
    my $manifest = JSON::PP->new->decode(
        _slurp_1148('plugins/playful-v3/plugin.json'));
    my $history = $contract->{development_promotion_history};
    my ($promotion) = grep {
        ($_->{milestone} // '') eq 'MB778'
    } @{ $history || [] };

    $assert->is($contract->{milestone}, 'MB786',
        'machine contract advances while retaining playful promotion evidence');
    $assert->ok(ref($promotion) eq 'HASH',
        'playful promotion remains in ordered history');
    $assert->is($promotion->{milestone}, 'MB778',
        'current development promotion is versioned');
    $assert->is($promotion->{package}, 'playful-v3',
        'current promotion names the reviewed playful package');
    $assert->is($promotion->{channel}, '#test',
        'promotion is limited to the development channel');
    $assert->is($promotion->{mode}, 'on',
        'accepted playful policy is authoritative on');
    $assert->like($promotion->{evidence},
        qr/MB745.*six-command.*observe before on.*ritual disabled.*zero failures.*ledger preserved.*restart/i,
        'promotion binds parity, silent ritual, health and restart evidence');
    $assert->is($promotion->{persistent_operator_state}, JSON::PP::true,
        'playful posture is held by the core boot ledger');
    $assert->is($promotion->{production_channels}, 0,
        'development promotion grants no production channel');

    $assert->is(join(',', map { $_->{milestone} } @$history),
        'MB764,MB767,MB771,MB778',
        'four development promotions remain ordered history');
    $assert->is(join(',', map { $_->{package} } @$history),
        'factoids-v3,quotes-v3,channel-activity-v3,playful-v3',
        'promoted packages remain explicit');

    $assert->is($manifest->{activation}{default}, 'off',
        'promoted package source remains default-off');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'irc.reply,irc.notice,irc.channel_message,scheduler.jobs',
        'promotion grants exactly the four manifest capabilities');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        '8ball,abbrev,choose,flip,morse,roll',
        'promotion contains exactly the six reviewed commands');
    $assert->is($manifest->{config_schema}{ritual_enabled}{default},
        JSON::PP::false,
        'autonomous ritual stays disabled by typed default');
    $assert->is(join(',', sort keys %{ $manifest->{jobs} }), 'quiet_magic',
        'the single bounded job remains explicit');

    my $guide = _slurp_1148('docs/PLUGIN_V3_PROMOTION.md');
    my $pilot = _slurp_1148('docs/PLAYFUL_V3_PILOT.md');
    my $api = _slurp_1148('docs/PLUGIN_API_V3.md');
    my $operations = _slurp_1148('docs/PLUGIN_OPERATIONS_V3.md');
    my $architecture = _slurp_1148('docs/PLUGIN_ARCHITECTURE.md');
    my $readme = _slurp_1148('plugins/playful-v3/README.md');
    my $changelog = _slurp_1148('CHANGELOG.md');

    $assert->like($guide,
        qr/policy playful-v3 #test observe.*?policy playful-v3 #test on/s,
        'promotion guide requires observe before on');
    $assert->like($guide,
        qr/ritual_enabled=false.*?six commands.*?one job.*?zero failures/is,
        'promotion guide keeps autonomous output disabled');
    $assert->like($guide,
        qr/policy playful-v3 #test off.*?disable playful-v3.*?unload playful-v3/s,
        'promotion guide freezes explicit rollback order');
    $assert->like($pilot,
        qr/MB778.*?development `#test`.*?six mounted commands.*?production/is,
        'playful pilot records the persistent development-only posture');
    $assert->like($api,
        qr/MB778.*?playful-v3.*?clean\s+restart.*?production remains untouched/is,
        'API guide records restart persistence and production isolation');
    $assert->like($operations,
        qr/MB778.*?ritual_enabled=false.*?pre-existing ledger.*?rollback/is,
        'operations guide records the retained safe posture');
    $assert->like($architecture,
        qr/MB778.*?persistent playful promotion.*?development `#test`/is,
        'architecture records the next functional tranche');
    $assert->like($readme,
        qr/MB778.*?development `#test`.*?quiet_magic.*?production/is,
        'package guide distinguishes operator intent from source defaults');
    $assert->like($changelog,
        qr/mb778.*?playful spellbook.*?restart.*?production/is,
        'changelog records the controlled playful promotion');
};
