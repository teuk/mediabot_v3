use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::AdaptivePolicy qw(
    adaptive_spark_policy adaptive_spark_policy_summary
    spark_audience_regimes
);

return sub {
    my ($assert) = @_;

    my $policy = sub {
        return adaptive_spark_policy(
            base_revival_silence_seconds => 1_200,
            base_revival_probe_seconds => 300,
            base_action_min_humans => 3,
            base_action_min_lines => 6,
            base_action_min_pause_seconds => 45,
            base_action_max_pause_seconds => 180,
            base_shared_cooldown_seconds => 1_200,
            @_,
        );
    };

    $assert->is(join(',', @{ spark_audience_regimes() }),
        'empty,solo,small,social,crowded',
        'mb710-1007: audience regimes form one explicit ordered scale');

    my $empty = $policy->();
    $assert->is($empty->{audience_regime}, 'empty',
        'mb710-1007: no observed human activity remains empty');

    my $solo = $policy->(
        distinct_humans => 1, effective_humans_milli => 1_000,
        dominant_share_pct => 100, human_line_rate_milli => 500,
    );
    $assert->is($solo->{audience_regime}, 'solo',
        'mb710-1007: one effective voice is a solo audience');
    $assert->is($solo->{revival_min_humans}, 1,
        'mb710-1007: a solo channel may receive a rare contextual revival');
    $assert->is($solo->{revival_silence_seconds}, 2_400,
        'mb710-1007: solo revival waits twice the reviewed baseline');
    $assert->is($solo->{shared_cooldown_seconds}, 2_400,
        'mb710-1007: solo delivery consumes a long shared budget');

    my $small = $policy->(
        distinct_humans => 2, effective_humans_milli => 2_000,
        dominant_share_pct => 50, human_line_rate_milli => 1_000,
    );
    $assert->is($small->{audience_regime}, 'small',
        'mb710-1007: two balanced voices form the small regime');
    $assert->is($small->{revival_silence_seconds}, 1_800,
        'mb710-1007: small channels remain deliberately patient');
    $assert->is($small->{action_min_humans}, 2,
        'mb710-1007: momentum can exist in a genuine two-person exchange');
    $assert->is($small->{action_min_lines}, 4,
        'mb710-1007: small momentum uses a proportional line threshold');
    $assert->is($small->{shared_cooldown_seconds}, 1_800,
        'mb710-1007: small channels receive a longer shared cooldown');

    my $social = $policy->(
        distinct_humans => 3, effective_humans_milli => 3_000,
        dominant_share_pct => 34, human_line_rate_milli => 2_000,
    );
    $assert->is($social->{audience_regime}, 'social',
        'mb710-1007: three balanced voices preserve the reviewed baseline');
    $assert->is($social->{revival_silence_seconds}, 1_200,
        'mb710-1007: social pacing equals the operator baseline');
    $assert->is($social->{shared_cooldown_seconds}, 1_200,
        'mb710-1007: social cooldown equals the operator baseline');

    my $crowded = $policy->(
        distinct_humans => 8, effective_humans_milli => 7_600,
        dominant_share_pct => 16, human_line_rate_milli => 8_000,
    );
    $assert->is($crowded->{audience_regime}, 'crowded',
        'mb710-1007: a balanced large audience reaches the crowded regime');
    $assert->is($crowded->{revival_silence_seconds}, 720,
        'mb710-1007: crowded revival needs less dead air');
    $assert->is($crowded->{action_min_pause_seconds}, 30,
        'mb710-1007: crowded momentum recognizes a shorter breathing pause');
    $assert->is($crowded->{action_max_pause_seconds}, 121,
        'mb710-1007: crowded momentum also expires sooner');
    $assert->is($crowded->{shared_cooldown_seconds}, 804,
        'mb710-1007: crowded delivery returns budget sooner');
    $assert->is($crowded->{action_min_lines}, 9,
        'mb710-1007: crowded momentum still requires substantial activity');

    my $fast_five = $policy->(
        distinct_humans => 5, effective_humans_milli => 4_700,
        dominant_share_pct => 24, human_line_rate_milli => 6_500,
    );
    $assert->is($fast_five->{audience_regime}, 'crowded',
        'mb710-1007: sustained balanced cadence can promote a five-person room');

    my $dominated = $policy->(
        distinct_humans => 7, effective_humans_milli => 5_500,
        dominant_share_pct => 80, human_line_rate_milli => 8_000,
    );
    $assert->is($dominated->{audience_regime}, 'social',
        'mb710-1007: one dominant speaker makes the policy more conservative');
    $assert->ok($dominated->{dominance_limited},
        'mb710-1007: dominance limitation remains explicit metadata');

    my $pressured = $policy->(
        distinct_humans => 3, effective_humans_milli => 3_000,
        dominant_share_pct => 34, human_line_rate_milli => 2_000,
        bot_pressure_share_pct => 60,
    );
    $assert->ok($pressured->{pressure_limited},
        'mb710-1007: automation pressure remains explicit for hard runtime gates');

    my $summary = adaptive_spark_policy_summary($crowded);
    $assert->is($summary->{audience_regime}, 'crowded',
        'mb710-1007: pure policy summary preserves the bounded regime');
    $assert->unlike(join(',', sort keys %$summary), qr/(?:nick|message|text)/i,
        'mb710-1007: adaptive policy exposes no identity or conversation text');
};
