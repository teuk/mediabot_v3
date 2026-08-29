use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Selector qw(select_spark_event spark_selector_summary);

return sub {
    my ($assert) = @_;

    my $solo = select_spark_event(
        recent_humans => 1, context_lines => 4, ai_available => 1,
        audience_regime => 'solo', cursor => 0,
    );
    $assert->is($solo->{kind}, 'reaction',
        'mb710-1009: solo schedule starts with a contextual reaction');
    $assert->is($solo->{audience_regime}, 'solo',
        'mb710-1009: selector preserves the policy regime');

    my $solo_without_ai = select_spark_event(
        recent_humans => 1, context_lines => 4, ai_available => 0,
        audience_regime => 'solo', cursor => 0,
    );
    $assert->is($solo_without_ai->{action}, 'skip',
        'mb710-1009: solo fallback fails closed without contextual AI');

    my $small = select_spark_event(
        recent_humans => 3, context_lines => 0, ai_available => 0,
        audience_regime => 'small', cursor => 1,
    );
    $assert->is($small->{kind}, 'fork',
        'mb710-1009: a dominance-limited small room avoids Portal');

    my $crowded = select_spark_event(
        recent_humans => 7, context_lines => 8, ai_available => 1,
        audience_regime => 'crowded', cursor => 1,
    );
    $assert->is($crowded->{kind}, 'portal',
        'mb710-1009: crowded schedule makes contribution play more available');

    my $summary = spark_selector_summary($crowded);
    $assert->is($summary->{audience_regime}, 'crowded',
        'mb710-1009: safe selector summary retains the bounded regime');
};
