# MB784 — consolidate the accepted five-package production portfolio.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1150 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        _slurp_1150('plugins/API_V3_CONTRACT.json'));
    my $manifest = JSON::PP->new->decode(
        _slurp_1150('plugins/short-content-v3/plugin.json'));
    my $short = $contract->{production_pilots}{short_content_v3};
    my $portfolio = $contract->{production_pilots}{enabled_on_portfolio};
    my $consolidation = $contract->{production_pilots}{source_consolidation};

    $assert->is($contract->{milestone}, 'MB786',
        'machine contract retains the portfolio beyond its consolidation');
    $assert->is($short->{observe_milestone}, 'MB782',
        'short-content production observation remains explicit');
    $assert->is($short->{promotion_milestone}, 'MB783',
        'short-content production promotion remains explicit');
    $assert->is($short->{instance}, 'nbot',
        'production instance is named');
    $assert->is($short->{channel}, '#i/o',
        'production channel is bounded');
    $assert->is($short->{package}, 'short-content-v3',
        'production record names the promoted package');
    $assert->is($short->{final_mode}, 'on',
        'short-content finishes authoritative');
    $assert->like($short->{observe_behavior},
        qr/silent.*repository write-free/i,
        'observe evidence remains silent and write-free');
    $assert->is($short->{reply}, 'MB783-mediabot_v3',
        'authoritative HTTPS evidence is exact');
    $assert->like($short->{repository_change}, qr/one bounded revision/i,
        'repository mutation is explicitly bounded');
    $assert->is($short->{business_data_changed}, 0,
        'business data remains unchanged');
    $assert->like($short->{restart_behavior}, qr/exact enabled\/on posture/i,
        'short-content restart posture is exact');
    $assert->is($short->{failures}, 0,
        'short-content production evidence is failure-free');

    $assert->is($portfolio->{milestone}, 'MB783',
        'portfolio is anchored to the accepted production promotion');
    $assert->is(join(',', @{ $portfolio->{packages} || [] }),
        'quotes-v3,channel-activity-v3,factoids-v3,playful-v3,short-content-v3',
        'portfolio records exactly five enabled-on packages');
    $assert->is($portfolio->{mode}, 'on',
        'all accepted portfolio packages are authoritative');
    $assert->is($portfolio->{quiet_magic}, 'disabled',
        'autonomous playful output remains disabled');
    $assert->like($portfolio->{restart_behavior},
        qr/all five exact postures restored/i,
        'restart restored the complete portfolio');
    $assert->is($portfolio->{failures}, 0,
        'portfolio remains failure-free');
    $assert->is($portfolio->{source_mutation}, 'none',
        'production acceptance changed no source file');
    $assert->is($portfolio->{business_data_mutation}, 'none',
        'production acceptance changed no quote or factoid row');
    $assert->like($portfolio->{short_content_repository},
        qr/one verified bounded revision retained/i,
        'the one retained repository revision is explicit');

    $assert->is($consolidation->{milestone}, 'MB784',
        'source-only consolidation is versioned');
    $assert->is(join(',', @{ $consolidation->{accepted_evidence} || [] }),
        'MB782,MB783',
        'consolidation names both accepted production gates');
    $assert->is($consolidation->{runtime_authority_change}, 'none',
        'consolidation grants no new runtime authority');
    $assert->is($consolidation->{production_contact}, 'none',
        'consolidation does not contact production');
    $assert->is($consolidation->{development_ledger_change}, 'none',
        'consolidation does not mutate development posture');

    $assert->is($contract->{development_promotion}{milestone}, 'MB781',
        'development promotion remains the accepted short-content milestone');
    $assert->is($contract->{development_promotion}{production_channels}, 0,
        'development promotion itself still grants no production channel');
    $assert->is($contract->{updater_state_preservation}{milestone}, 'MB772',
        'updater preservation remains part of the accepted boundary');
    $assert->is($manifest->{activation}{default}, 'off',
        'installed package source remains default-off');
    $assert->is(join(',', @{ $manifest->{capabilities} || [] }),
        'http.fetch,irc.reply,storage.kv',
        'production record does not widen manifest authority');

    my $record = _slurp_1150('docs/PLUGIN_V3_PRODUCTION_PORTFOLIO.md');
    my $pilot = _slurp_1150('docs/SHORT_CONTENT_V3_PILOT.md');
    my $guide = _slurp_1150('docs/PLUGIN_V3_PROMOTION.md');
    my $api = _slurp_1150('docs/PLUGIN_API_V3.md');
    my $operations = _slurp_1150('docs/PLUGIN_OPERATIONS_V3.md');
    my $architecture = _slurp_1150('docs/PLUGIN_ARCHITECTURE.md');
    my $readme = _slurp_1150('plugins/short-content-v3/README.md');
    my $adr = _slurp_1150('docs/adr/0001-plugin-platform-evolution.md');
    my $changelog = _slurp_1150('CHANGELOG.md');

    $assert->like($record,
        qr/MB773.*MB774.*MB775.*MB776.*MB777.*MB779.*MB780.*MB782.*MB783/is,
        'production record preserves the ordered acceptance chain');
    $assert->like($record,
        qr/quotes-v3.*channel-activity-v3.*factoids-v3.*playful-v3.*short-content-v3/is,
        'production record names the five-package portfolio');
    $assert->like($record,
        qr/all five.*enabled.*on.*#i\/o.*zero failures/is,
        'production record freezes the final posture and health');
    $assert->like($record,
        qr/policy .* #i\/o off.*disable.*unload/is,
        'production record retains immediate rollback order');
    $assert->like($pilot,
        qr/MB782.*silent.*write-free.*MB783.*persistent.*enabled\/on/is,
        'short-content pilot records both production gates');
    $assert->like($guide,
        qr/MB782.*observe.*MB783.*short-content-v3.*#i\/o.*on/is,
        'promotion guide records observe before production authority');
    $assert->like($api,
        qr/MB784.*five-package production portfolio.*no new runtime authority/is,
        'API guide records source-only consolidation');
    $assert->like($operations,
        qr/MB784.*five\s+packages.*enabled\/on.*development ledger.*unchanged/is,
        'operations guide records the preserved runtime boundaries');
    $assert->like($architecture,
        qr/MB784.*production portfolio consolidation.*five.*#i\/o/is,
        'architecture records the completed production tranche');
    $assert->like($readme,
        qr/MB783.*production `#i\/o`.*enabled\/on.*one bounded repository revision/is,
        'package guide records production authority and bounded state');
    $assert->like($adr,
        qr/MB784.*MB782.*MB783.*no new runtime authority/is,
        'ADR records the evidence-only source decision');
    $assert->like($changelog,
        qr/MB784.*five production wards.*MB782.*MB783.*production.*not contacted/is,
        'changelog records the consolidation and isolation');
};
