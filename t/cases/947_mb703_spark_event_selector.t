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
    $assert->ok(grep($_ eq 'aside', @$kinds) && grep($_ eq 'micro_scene', @$kinds),
        'mb739-947: catalog includes both autonomous revival families');

    my $fork = spark_event_profile('FORK');
    $assert->is($fork->{duration_seconds}, 60,
        'mb703-947: Fork uses a short 60-second event window');
    $assert->is($fork->{min_recent_humans}, 2,
        'mb703-947: Fork needs at least two recent humans');
    $assert->ok(!$fork->{selectable} && $fork->{lane} eq 'retired',
        'mb739-947: legacy Fork remains decodable but cannot be selected');

    my $portal = spark_event_profile('portal');
    $assert->is($portal->{min_recent_humans}, 3,
        'mb703-947: Portal requires a collaborative audience');

    my $callback = spark_event_profile('callback');
    $assert->ok($callback->{needs_context},
        'mb703-947: Callback explicitly requires recent context');
    $assert->is($callback->{ai_use}, 'preferred',
        'mb703-947: Callback explicitly prefers provider-neutral AI');

    my $reaction = spark_event_profile('reaction');
    $assert->ok($reaction->{needs_context},
        'mb708: Reaction requires recent channel context');
    $assert->is($reaction->{ai_use}, 'preferred',
        'mb708: Reaction uses provider-neutral AI only when context can support it');

    my $catalog = spark_event_catalog_summary();
    $assert->ok(scalar(@$catalog) >= 5,
        'mb708: catalog contains the original families plus Reaction and VDM');

    my $sel = select_spark_event(
        recent_humans => 1,
        context_lines => 0,
        ai_available  => 1,
        audience_regime => 'solo',
        cursor        => 0,
    );
    $assert->is($sel->{kind}, 'aside',
        'mb739-947: Aside is the autonomous low-context baseline');

    $sel = select_spark_event(
        recent_humans => 3,
        context_lines => 0,
        ai_available  => 1,
        audience_regime => 'social',
        cursor        => 5,
    );
    $assert->is($sel->{kind}, 'portal',
        'mb739-947: Portal remains an occasional social option');

    my $reaction_pick = select_spark_event(
        recent_humans => 3,
        context_lines => 6,
        ai_available  => 1,
        cursor        => 0,
    );
    $assert->is($reaction_pick->{kind}, 'reaction',
        'mb739-947: rich recent context still starts with a natural Reaction');

    $sel = select_spark_event(
        recent_humans => 3,
        context_lines => 6,
        ai_available  => 1,
        cursor        => 2,
    );
    $assert->is($sel->{kind}, 'callback',
        'mb739-947: contextual schedule still gives Callback a regular slot');

    my $no_repeat = select_spark_event(
        recent_humans => 3,
        context_lines => 5,
        ai_available  => 1,
        cursor        => 0,
        last_kind     => 'reaction',
    );
    $assert->ok($no_repeat->{kind} ne 'reaction',
        'mb708: selector avoids immediate Reaction repetition when alternatives exist');
    $assert->is($reaction_pick->{reason}, 'contextual_schedule',
        'mb708: selector exposes the contextual schedule decision rather than catalog-order rotation');

    my $none = select_spark_event(
        recent_humans => 0,
        context_lines => 8,
        ai_available  => 1,
        audience_regime => 'empty',
    );
    $assert->is($none->{action}, 'skip',
        'mb739-947: empty audience fails closed');
    $assert->is($none->{reason}, 'no_eligible_event',
        'mb703-947: selector skip reason is explicit');

    my $summary = spark_selector_summary($no_repeat);
    $assert->is($summary->{action}, 'select',
        'mb703-947: selector summary preserves safe decision metadata');
};
