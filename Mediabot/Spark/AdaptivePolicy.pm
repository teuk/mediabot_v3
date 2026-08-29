package Mediabot::Spark::AdaptivePolicy;

use strict;
use warnings;

use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    adaptive_spark_policy
    adaptive_spark_policy_summary
    spark_audience_regimes
);

my @REGIME = qw(empty solo small social crowded);
my %KNOWN_REGIME = map { $_ => 1 } @REGIME;

# Every audience-dependent pacing decision lives in this table. The values are
# percentages of the reviewed operator baselines, not replacement magic
# numbers scattered through runtime code.
my %PROFILE = (
    empty => {
        revival_silence_pct => 200,
        revival_probe_pct   => 150,
        action_pause_pct    => 150,
        action_window_pct   => 150,
        shared_cooldown_pct => 200,
    },
    solo => {
        revival_silence_pct => 200,
        revival_probe_pct   => 150,
        action_pause_pct    => 150,
        action_window_pct   => 150,
        shared_cooldown_pct => 200,
    },
    small => {
        revival_silence_pct => 150,
        revival_probe_pct   => 125,
        action_pause_pct    => 100,
        action_window_pct   => 133,
        shared_cooldown_pct => 150,
    },
    social => {
        revival_silence_pct => 100,
        revival_probe_pct   => 100,
        action_pause_pct    => 100,
        action_window_pct   => 100,
        shared_cooldown_pct => 100,
    },
    crowded => {
        revival_silence_pct => 60,
        revival_probe_pct   => 67,
        action_pause_pct    => 67,
        action_window_pct   => 67,
        shared_cooldown_pct => 67,
    },
);

sub spark_audience_regimes { return [ @REGIME ]; }

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _nonnegative_int {
    my ($value, $default) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    return int($value);
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    my $n = _nonnegative_int($value, $default);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub _scale {
    my ($value, $pct, $min, $max) = @_;
    my $scaled = int((($value * $pct) + 50) / 100);
    $scaled = $min if $scaled < $min;
    $scaled = $max if $scaled > $max;
    return $scaled;
}

sub _regime_rank {
    my ($effective, $distinct) = @_;
    return 0 if $distinct == 0 || $effective == 0;
    return 1 if $distinct <= 1 || $effective < 1_500;
    return 2 if $distinct <= 2 || $effective < 2_600;
    return 3 if $distinct <= 5 || $effective < 5_000;
    return 4;
}

sub adaptive_spark_policy {
    my (%args) = @_;

    my $effective = _nonnegative_int($args{effective_humans_milli}, 0);
    my $distinct = _nonnegative_int($args{distinct_humans}, 0);
    my $dominant = _bounded_int($args{dominant_share_pct}, 0, 0, 100);
    my $line_rate = _nonnegative_int($args{human_line_rate_milli}, 0);
    my $pressure_share = _bounded_int(
        $args{bot_pressure_share_pct}, 0, 0, 100,
    );

    my $rank = _regime_rank($effective, $distinct);

    # Five genuinely active, balanced voices can cross into the busiest regime
    # through sustained human cadence. Conversely, conversational dominance or
    # automation pressure can only make the bot more conservative.
    $rank = 4
        if $rank == 3
            && $distinct >= 5
            && $effective >= 4_500
            && $line_rate >= 6_000;
    $rank-- if $rank > 1 && $dominant >= 75;

    my $regime = $REGIME[$rank];
    my $profile = $PROFILE{$regime};

    my $base_silence = _bounded_int(
        $args{base_revival_silence_seconds}, 1_200, 60, 86_400,
    );
    my $base_probe = _bounded_int(
        $args{base_revival_probe_seconds}, 300, 30, 3_600,
    );
    my $base_action_humans = _bounded_int(
        $args{base_action_min_humans}, 3, 2, 100,
    );
    my $base_action_lines = _bounded_int(
        $args{base_action_min_lines}, 6, 2, 1_000,
    );
    my $base_action_pause = _bounded_int(
        $args{base_action_min_pause_seconds}, 45, 15, 600,
    );
    my $base_action_window = _bounded_int(
        $args{base_action_max_pause_seconds}, 180, 60, 1_800,
    );
    my $base_cooldown = _bounded_int(
        $args{base_shared_cooldown_seconds}, 1_200, 300, 86_400,
    );

    my $action_min_humans = $base_action_humans;
    my $action_min_lines = $base_action_lines;
    if ($regime eq 'solo' || $regime eq 'small') {
        $action_min_humans = 2;
        $action_min_lines = _scale($base_action_lines, 67, 2, 1_000);
    }
    elsif ($regime eq 'crowded') {
        $action_min_humans = 4 if $action_min_humans < 4;
        $action_min_lines = _scale($base_action_lines, 150, 2, 1_000);
    }

    my $action_min_pause = _scale(
        $base_action_pause,
        $profile->{action_pause_pct},
        15,
        600,
    );
    my $action_max_pause = _scale(
        $base_action_window,
        $profile->{action_window_pct},
        60,
        1_800,
    );
    $action_max_pause = $action_min_pause + 15
        if $action_max_pause <= $action_min_pause;

    return {
        audience_regime => $regime,
        audience_rank => $rank,
        audience_intensity_pct => int(25 * $rank),
        revival_min_humans => $regime eq 'solo' ? 1 : 2,
        revival_silence_seconds => _scale(
            $base_silence,
            $profile->{revival_silence_pct},
            60,
            86_400,
        ),
        revival_probe_seconds => _scale(
            $base_probe,
            $profile->{revival_probe_pct},
            30,
            3_600,
        ),
        action_min_humans => $action_min_humans,
        action_min_lines => $action_min_lines,
        action_min_pause_seconds => $action_min_pause,
        action_max_pause_seconds => $action_max_pause,
        shared_cooldown_seconds => _scale(
            $base_cooldown,
            $profile->{shared_cooldown_pct},
            300,
            86_400,
        ),
        dominance_limited => ($dominant >= 75) ? 1 : 0,
        pressure_limited => ($pressure_share >= 50) ? 1 : 0,
    };
}

sub adaptive_spark_policy_summary {
    my ($policy) = @_;
    return undef unless ref($policy) eq 'HASH';
    return undef unless _plain_scalar($policy->{audience_regime})
        && $KNOWN_REGIME{$policy->{audience_regime}};

    my %out = (audience_regime => "$policy->{audience_regime}");
    for my $key (qw(
        audience_rank audience_intensity_pct
        revival_min_humans revival_silence_seconds revival_probe_seconds
        action_min_humans action_min_lines action_min_pause_seconds
        action_max_pause_seconds shared_cooldown_seconds
        dominance_limited pressure_limited
    )) {
        return undef unless _plain_scalar($policy->{$key})
            && "$policy->{$key}" =~ /^\d+\z/;
        $out{$key} = int($policy->{$key});
    }
    return \%out;
}

1;
