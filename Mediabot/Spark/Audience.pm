package Mediabot::Spark::Audience;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(looks_like_number);

our $VERSION = '1.0';
our @EXPORT_OK = qw(summarize_audience);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _nonnegative_number {
    my ($value, $default) = @_;
    return $default unless _plain_scalar($value)
        && looks_like_number($value)
        && $value >= 0;
    return 0 + $value;
}

sub _time_value {
    my ($value) = @_;
    return undef unless _plain_scalar($value)
        && looks_like_number($value)
        && $value >= 0;
    return 0 + $value;
}

sub _quiet_for {
    my ($now, $at) = @_;
    return 0 unless defined($at) && $at <= $now;
    my $quiet = int($now - $at);
    return $quiet > 0 ? $quiet : 0;
}

sub summarize_audience {
    my (%args) = @_;

    my $weights = ref($args{human_weights}) eq 'HASH'
        ? $args{human_weights}
        : {};

    my @positive_weights = grep { $_ > 0 } map {
        _nonnegative_number($_, 0)
    } values %$weights;

    my ($weight_sum, $weight_square_sum, $dominant_weight) = (0, 0, 0);
    for my $weight (@positive_weights) {
        $weight_sum += $weight;
        $weight_square_sum += $weight * $weight;
        $dominant_weight = $weight if $weight > $dominant_weight;
    }

    # Kish's effective sample size turns a raw nick count into a conversational
    # audience size. One dominant speaker therefore stays close to one even if
    # several occasional voices are present, while balanced participation tends
    # toward the distinct-human count.
    my $effective_milli = $weight_square_sum > 0
        ? int((1_000 * $weight_sum * $weight_sum / $weight_square_sum) + 0.5)
        : 0;
    my $dominant_share_pct = $weight_sum > 0
        ? int((100 * $dominant_weight / $weight_sum) + 0.5)
        : 0;

    my $human_lines = int(_nonnegative_number($args{human_lines}, 0));
    my $pressure_lines = int(
        _nonnegative_number($args{bot_pressure_lines}, 0)
    );
    my $window = int(_nonnegative_number($args{window_seconds}, 0));
    my $now = _time_value($args{now});
    $now = 0 unless defined $now;
    my $last_human_at = _time_value($args{last_human_at});
    my $last_pressure_at = _time_value($args{last_bot_pressure_at});

    my $line_rate_milli = $window > 0
        ? int((60_000 * $human_lines / $window) + 0.5)
        : 0;
    my $total_lines = $human_lines + $pressure_lines;
    my $pressure_share_pct = $total_lines > 0
        ? int((100 * $pressure_lines / $total_lines) + 0.5)
        : 0;

    return {
        window_seconds             => $window,
        line_count                 => $human_lines,
        distinct_humans            => scalar(@positive_weights),
        effective_humans_milli     => $effective_milli,
        dominant_share_pct         => $dominant_share_pct,
        human_line_rate_milli      => $line_rate_milli,
        last_human_at              => $last_human_at,
        quiet_for_seconds          => _quiet_for($now, $last_human_at),
        bot_pressure_lines         => $pressure_lines,
        bot_pressure_share_pct     => $pressure_share_pct,
        last_bot_pressure_at       => $last_pressure_at,
        bot_pressure_quiet_seconds => _quiet_for($now, $last_pressure_at),
    };
}

1;
