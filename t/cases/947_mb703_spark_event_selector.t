# t/cases/947_mb703_spark_event_selector.t
# =============================================================================
# MB703-C — Event catalog and deterministic selector.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Event qw(spark_event_kinds spark_event_profile spark_event_catalog_summary);
use Mediabot::Spark::Selector qw(select_spark_event spark_selector_summary);

return sub {
    my ($assert) = @_;

    my $kinds = spark_event_kinds();
    $assert->is(join(',', @$kinds), 'fork,portal,callback',
        'mb703-947: initial Spark catalog is Fork, Portal and Callback');

    my $fork = spark_event_profile('FORK');
    $assert->is($fork->{duration_seconds}, 60,
        'mb703-947: Fork uses a short 60-second event window');
    $assert->is($fork->{min_recent_humans}, 2,
        'mb703-947: Fork needs at least two recent humans');

    my $portal = spark_event_profile('portal');
    $assert->is($portal->{min_recent_humans}, 3,
        'mb703-947: Portal requires a collaborative audience');

    my $callback = spark_event_profile('callback');
    $assert->ok($callback->{needs_context},
        'mb703-947: Callback explicitly requires recent context');
    $assert->is($callback->{ai_use}, 'preferred',
        'mb703-947: Callback explicitly prefers provider-neutral AI');

    my $catalog = spark_event_catalog_summary();
    $assert->is(scalar(@$catalog), 3,
        'mb703-947: catalog summary exposes three bounded event profiles');

    my $sel = select_spark_event(
        recent_humans => 2,
        context_lines => 0,
        ai_available  => 0,
        cursor        => 0,
    );
    $assert->is($sel->{kind}, 'fork',
        'mb703-947: Fork is the deterministic low-context baseline');

    $sel = select_spark_event(
        recent_humans => 3,
        context_lines => 0,
        ai_available  => 0,
        cursor        => 1,
    );
    $assert->is($sel->{kind}, 'portal',
        'mb703-947: Portal becomes eligible with three recent humans');

    $sel = select_spark_event(
        recent_humans => 3,
        context_lines => 5,
        ai_available  => 1,
        cursor        => 2,
    );
    $assert->is($sel->{kind}, 'callback',
        'mb703-947: Callback becomes eligible only with context and AI availability');

    my $no_repeat = select_spark_event(
        recent_humans => 3,
        context_lines => 5,
        ai_available  => 1,
        cursor        => 0,
        last_kind     => 'fork',
    );
    $assert->ok($no_repeat->{kind} ne 'fork',
        'mb703-947: selector avoids immediate repetition when alternatives exist');

    my $none = select_spark_event(
        recent_humans => 1,
        context_lines => 8,
        ai_available  => 1,
    );
    $assert->is($none->{action}, 'skip',
        'mb703-947: insufficient audience fails closed');
    $assert->is($none->{reason}, 'no_eligible_event',
        'mb703-947: selector skip reason is explicit');

    my $summary = spark_selector_summary($no_repeat);
    $assert->is($summary->{action}, 'select',
        'mb703-947: selector summary preserves safe decision metadata');
};
