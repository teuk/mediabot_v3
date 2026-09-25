# MB781 — short-content-v3 becomes the next persistent development promotion.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1149 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp_1149('plugins/API_V3_CONTRACT.json'));
    my $manifest = JSON::PP->new->decode(
        _slurp_1149('plugins/short-content-v3/plugin.json'));
    my $promotion = $contract->{development_promotion};
    my $history = $contract->{development_promotion_history};
    my $portfolio = $contract->{production_pilots}{enabled_on_portfolio};

    $assert->is($contract->{milestone}, 'MB786',
        'machine contract advances while retaining short-content promotion');
    $assert->is($promotion->{milestone}, 'MB781',
        'current development promotion is versioned');
    $assert->is($promotion->{package}, 'short-content-v3',
        'current promotion names the reviewed HTTP proof package');
    $assert->is($promotion->{channel}, '#test',
        'promotion remains limited to the development channel');
    $assert->is($promotion->{mode}, 'on',
        'accepted short-content policy is authoritative on');
    $assert->like($promotion->{evidence},
        qr/MB756.*HTTP.*repository.*observe.*silent.*write-free.*one revisioned.*zero failures.*restart/i,
        'promotion binds supervised proof, persistence and restart evidence');
    $assert->is($promotion->{persistent_operator_state}, JSON::PP::true,
        'short-content posture is held by the core boot ledger');
    $assert->is($promotion->{production_channels}, 0,
        'development promotion grants no production channel');

    $assert->is(join(',', map { $_->{milestone} } @$history),
        'MB764,MB767,MB771,MB778',
        'four earlier promotions remain ordered history');
    $assert->is(join(',', map { $_->{package} } @$history),
        'factoids-v3,quotes-v3,channel-activity-v3,playful-v3',
        'earlier promoted packages remain explicit');

    $assert->is($portfolio->{milestone}, 'MB783',
        'latest production portfolio evidence includes short-content');
    $assert->is(join(',', @{ $portfolio->{packages} || [] }),
        'quotes-v3,channel-activity-v3,factoids-v3,playful-v3,short-content-v3',
        'production portfolio records the five enabled-on packages');
    $assert->is($portfolio->{quiet_magic}, 'disabled',
        'production portfolio records the dormant autonomous job');
    $assert->is($portfolio->{failures}, 0,
        'production portfolio remains failure-free');

    $assert->is($manifest->{activation}{default}, 'off',
        'promoted package source remains default-off');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'http.fetch,irc.reply,storage.kv',
        'promotion grants exactly the three manifest capabilities');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }), 'short',
        'promotion contains exactly the reviewed short command');
    $assert->is($manifest->{config_schema}{endpoint}{required},
        JSON::PP::true, 'HTTPS endpoint remains explicit channel policy');
    $assert->is($manifest->{config_schema}{cache_ttl_seconds}{maximum}, 3600,
        'cache lifetime remains bounded by manifest policy');
    $assert->is($manifest->{config_schema}{max_chars}{maximum}, 320,
        'public content length remains bounded');

    my $guide = _slurp_1149('docs/PLUGIN_V3_PROMOTION.md');
    my $pilot = _slurp_1149('docs/SHORT_CONTENT_V3_PILOT.md');
    my $api = _slurp_1149('docs/PLUGIN_API_V3.md');
    my $operations = _slurp_1149('docs/PLUGIN_OPERATIONS_V3.md');
    my $architecture = _slurp_1149('docs/PLUGIN_ARCHITECTURE.md');
    my $readme = _slurp_1149('plugins/short-content-v3/README.md');
    my $changelog = _slurp_1149('CHANGELOG.md');

    $assert->like($guide,
        qr/MB781.*?policy short-content-v3 #test observe.*?policy short-content-v3 #test on/is,
        'promotion guide requires observe before on');
    $assert->like($guide,
        qr/one repository revision.*?zero failures.*?restart/is,
        'promotion guide freezes state and restart evidence');
    $assert->like($guide,
        qr/policy short-content-v3 #test off.*?disable short-content-v3.*?unload short-content-v3/s,
        'promotion guide freezes explicit rollback order');
    $assert->like($pilot,
        qr/MB781.*?persistent.*?development `#test`.*?production/is,
        'short-content pilot records the development-only posture');
    $assert->like($api,
        qr/MB781.*?short-content-v3.*?clean restart.*?production remains untouched/is,
        'API guide records restart persistence and production isolation');
    $assert->like($operations,
        qr/MB781.*?HTTPS.*?repository.*?rollback/is,
        'operations guide records the mediated boundaries');
    $assert->like($architecture,
        qr/MB781.*?persistent short-content promotion.*?development `#test`/is,
        'architecture records the next functional tranche');
    $assert->like($readme,
        qr/MB781.*?development `#test`.*?HTTP.*?repository.*?production/is,
        'package guide distinguishes operator intent from source defaults');
    $assert->like($changelog,
        qr/MB781.*?short-content.*?restart.*?production/is,
        'changelog records the controlled short-content promotion');
};
