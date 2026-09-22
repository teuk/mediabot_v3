# MB764 — machine and operator guides freeze the first controlled promotion.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1131 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1131('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB764',
        'machine contract records the consolidation milestone');
    $assert->is($contract->{operator_portfolio}{partyline_command},
        'overviewv3', 'machine contract names the bounded operator view');
    $assert->is($contract->{operator_portfolio}{maximum_entries}, 64,
        'machine contract freezes the portfolio bound');
    $assert->is($contract->{operator_portfolio}{mutation}, 'none',
        'portfolio cannot change lifecycle or policy');
    $assert->is($contract->{development_promotion}{package}, 'factoids-v3',
        'first promoted package is explicit');
    $assert->is($contract->{development_promotion}{channel}, '#test',
        'promotion is limited to one development channel');
    $assert->is($contract->{development_promotion}{mode}, 'on',
        'promotion uses authoritative on policy');
    $assert->is($contract->{development_promotion}{boot_autoload},
        JSON::PP::false, 'promotion does not create boot autoload');
    $assert->is($contract->{development_promotion}{restart_behavior},
        'implicit rollback to unloaded',
        'restart remains a fail-closed rollback');
    $assert->is($contract->{development_promotion}{production_channels}, 0,
        'no production channel is promoted');

    my $guide = slurp_1131('docs/PLUGIN_V3_PROMOTION.md');
    $assert->like($guide,
        qr/\.plugins overviewv3.*?\.plugins doctor factoids-v3.*?\.plugins why factoids-v3 #test/s,
        'promotion guide collects portfolio, readiness and decision evidence');
    $assert->like($guide,
        qr/\.plugins policy factoids-v3 #test off.*?\.plugins disable factoids-v3.*?\.plugins unload factoids-v3/s,
        'promotion guide keeps immediate explicit rollback');
    $assert->like($guide,
        qr/restart.*?unloaded/is,
        'promotion guide records restart as implicit rollback');
    $assert->like($guide,
        qr/disposable/i, 'promotion evidence uses disposable data');
};
