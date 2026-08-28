package Mediabot::Spark::ActionPolicy;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(looks_like_number);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    spark_action_policy_defaults
    evaluate_spark_action_start
    spark_action_policy_summary
);

my %DEFAULT = (
    activity_window_seconds => 600,
    min_recent_humans       => 3,
    min_recent_lines        => 6,
    min_pause_seconds       => 45,
    max_pause_seconds       => 180,
);

sub spark_action_policy_defaults { return { %DEFAULT }; }

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bool {
    my ($value) = @_;
    return 0 unless _plain_scalar($value);
    return $value ? 1 : 0;
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    my $n = int($value);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub _time_value {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && looks_like_number($value);
    return undef if $value < 0;
    return 0 + $value;
}

sub _decision {
    my (%args) = @_;
    my %out = (
        action => $args{action},
        reason => $args{reason},
    );
    for my $key (qw(
        retry_after_seconds
        activity_window_seconds
        recent_humans
        recent_lines
        quiet_for_seconds
    )) {
        $out{$key} = int($args{$key}) if defined $args{$key};
    }
    return \%out;
}

sub evaluate_spark_action_start {
    my (%args) = @_;

    return _decision(action => 'skip', reason => 'spark_disabled')
        unless _bool($args{spark_enabled});
    return _decision(action => 'skip', reason => 'action_disabled')
        unless _bool($args{action_enabled});

    my $channel = $args{channel};
    return _decision(action => 'skip', reason => 'private')
        unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return _decision(action => 'skip', reason => 'runtime_inactive')
        unless _bool($args{runtime_active});
    return _decision(action => 'skip', reason => 'irc_disconnected')
        unless _bool($args{irc_connected});
    return _decision(action => 'skip', reason => 'not_joined')
        unless _bool($args{channel_joined});
    return _decision(action => 'skip', reason => 'flood_suppression')
        if _bool($args{flood_suppressed});
    return _decision(action => 'skip', reason => 'event_active')
        if _bool($args{event_active});
    return _decision(action => 'skip', reason => 'game_active')
        if _bool($args{game_active});
    return _decision(action => 'skip', reason => 'wit_pending')
        if _bool($args{wit_pending});

    my $now = _time_value($args{now});
    return _decision(action => 'skip', reason => 'invalid_time')
        unless defined $now;

    my $cooldown_until = _time_value($args{cooldown_until});
    if (defined($cooldown_until) && $cooldown_until > $now) {
        my $retry = int($cooldown_until - $now);
        $retry = 1 if $retry < 1;
        return _decision(
            action => 'skip', reason => 'cooldown',
            retry_after_seconds => $retry,
        );
    }

    my $window = _bounded_int(
        $args{activity_window_seconds},
        $DEFAULT{activity_window_seconds},
        60,
        3_600,
    );
    my $humans = _bounded_int($args{recent_humans}, 0, 0, 10_000);
    my $lines = _bounded_int($args{recent_lines}, 0, 0, 10_000);
    my $min_humans = _bounded_int(
        $args{min_recent_humans}, $DEFAULT{min_recent_humans}, 2, 100,
    );
    my $min_lines = _bounded_int(
        $args{min_recent_lines}, $DEFAULT{min_recent_lines}, 2, 1_000,
    );

    return _decision(
        action => 'skip', reason => 'insufficient_humans',
        activity_window_seconds => $window,
        recent_humans => $humans,
        recent_lines => $lines,
    ) if $humans < $min_humans;
    return _decision(
        action => 'skip', reason => 'insufficient_lines',
        activity_window_seconds => $window,
        recent_humans => $humans,
        recent_lines => $lines,
    ) if $lines < $min_lines;

    my $last_human_at = _time_value($args{last_human_at});
    return _decision(action => 'skip', reason => 'no_human_activity')
        unless defined($last_human_at) && $last_human_at <= $now;

    my $min_pause = _bounded_int(
        $args{min_pause_seconds}, $DEFAULT{min_pause_seconds}, 15, 600,
    );
    my $max_pause = _bounded_int(
        $args{max_pause_seconds}, $DEFAULT{max_pause_seconds}, 60, 1_800,
    );
    $max_pause = $DEFAULT{max_pause_seconds} if $max_pause <= $min_pause;

    my $quiet_for = int($now - $last_human_at);
    if ($quiet_for < $min_pause) {
        my $retry = $min_pause - $quiet_for;
        $retry = 1 if $retry < 1;
        return _decision(
            action => 'skip', reason => 'momentum_busy',
            retry_after_seconds => $retry,
            activity_window_seconds => $window,
            recent_humans => $humans,
            recent_lines => $lines,
            quiet_for_seconds => $quiet_for,
        );
    }
    return _decision(
        action => 'skip', reason => 'momentum_expired',
        activity_window_seconds => $window,
        recent_humans => $humans,
        recent_lines => $lines,
        quiet_for_seconds => $quiet_for,
    ) if $quiet_for > $max_pause;

    return _decision(
        action => 'consider', reason => 'momentum_ready',
        activity_window_seconds => $window,
        recent_humans => $humans,
        recent_lines => $lines,
        quiet_for_seconds => $quiet_for,
    );
}

sub spark_action_policy_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';
    return undef unless _plain_scalar($decision->{action})
        && "$decision->{action}" =~ /^(?:consider|skip)\z/;
    return undef unless _plain_scalar($decision->{reason})
        && "$decision->{reason}" =~ /^[a-z_]{1,64}\z/;

    my %out = (
        action => "$decision->{action}",
        reason => "$decision->{reason}",
    );
    for my $key (qw(
        retry_after_seconds
        activity_window_seconds
        recent_humans
        recent_lines
        quiet_for_seconds
    )) {
        next unless _plain_scalar($decision->{$key})
            && "$decision->{$key}" =~ /^\d+\z/;
        $out{$key} = int($decision->{$key});
    }
    return \%out;
}

1;
