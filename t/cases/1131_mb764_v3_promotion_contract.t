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
    $assert->is($contract->{milestone}, 'MB786',
        'machine contract advances without losing promotion history');
    $assert->is($contract->{operator_portfolio}{partyline_command},
        'overviewv3', 'machine contract names the bounded operator view');
    $assert->is($contract->{operator_portfolio}{maximum_entries}, 64,
        'machine contract freezes the portfolio bound');
    $assert->is($contract->{operator_portfolio}{mutation}, 'none',
        'portfolio cannot change lifecycle or policy');
    my $promotion = $contract->{development_promotion_history}[0];
    $assert->is($promotion->{milestone}, 'MB764',
        'first controlled promotion remains versioned');
    $assert->is($promotion->{package}, 'factoids-v3',
        'first promoted package is explicit');
    $assert->is($promotion->{channel}, '#test',
        'promotion is limited to one development channel');
    $assert->is($promotion->{mode}, 'on',
        'promotion uses authoritative on policy');
    $assert->is($contract->{boot_persistence}{historical_autoload_dependency},
        JSON::PP::false, 'promotion stays outside historical boot autoload');
    $assert->is($contract->{development_promotion}{persistent_operator_state},
        JSON::PP::true, 'promotion posture is now restart-persistent');
    $assert->like($contract->{development_promotion}{restart_behavior},
        qr/restore exact grants.*enabled.*on policy/i,
        'restart restores only validated operator intent');
    $assert->is($promotion->{production_channels}, 0,
        'no production channel is promoted');

    my $guide = slurp_1131('docs/PLUGIN_V3_PROMOTION.md');
    $assert->like($guide,
        qr/\.plugins overviewv3.*?\.plugins doctor quotes-v3.*?\.plugins why quotes-v3 #test/s,
        'promotion guide collects portfolio, readiness and decision evidence');
    $assert->like($guide,
        qr/\.plugins policy quotes-v3 #test off.*?\.plugins disable quotes-v3.*?\.plugins unload quotes-v3/s,
        'promotion guide keeps immediate explicit rollback');
    $assert->like($guide,
        qr/restart.*?last committed\s+state/is,
        'promotion guide records persistent restart semantics');
    $assert->like($guide,
        qr/disposable/i, 'promotion evidence uses disposable data');
};
