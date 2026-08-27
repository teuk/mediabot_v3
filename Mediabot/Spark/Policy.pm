package Mediabot::Spark::Policy;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(looks_like_number);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    spark_policy_defaults
    evaluate_spark_start
    spark_policy_summary
);

my %DEFAULT = (
    min_silence_seconds => 1_200,
    min_recent_humans   => 2,
);

sub spark_policy_defaults {
    return { %DEFAULT };
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if ref($value);
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

    $out{retry_after_seconds} = int($args{retry_after_seconds})
        if defined $args{retry_after_seconds};

    return \%out;
}

sub evaluate_spark_start {
    my (%args) = @_;

    return _decision(action => 'skip', reason => 'disabled')
        unless _bool($args{enabled});

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

    my $recent_humans = _bounded_int($args{recent_humans}, 0, 0, 10_000);
    my $min_humans = _bounded_int(
        $args{min_recent_humans},
        $DEFAULT{min_recent_humans},
        1,
        100,
    );

    return _decision(action => 'skip', reason => 'insufficient_humans')
        if $recent_humans < $min_humans;

    my $now = _time_value($args{now});
    return _decision(action => 'skip', reason => 'invalid_time')
        unless defined $now;

    my $cooldown_until = _time_value($args{cooldown_until});
    if (defined($cooldown_until) && $cooldown_until > $now) {
        my $retry = int($cooldown_until - $now);
        $retry = 1 if $retry < 1;
        return _decision(
            action              => 'skip',
            reason              => 'cooldown',
            retry_after_seconds => $retry,
        );
    }

    my $last_human_at = _time_value($args{last_human_at});
    return _decision(action => 'skip', reason => 'no_human_activity')
        unless defined $last_human_at && $now >= $last_human_at;

    my $min_silence = _bounded_int(
        $args{min_silence_seconds},
        $DEFAULT{min_silence_seconds},
        60,
        86_400,
    );

    my $quiet_for = $now - $last_human_at;
    if ($quiet_for < $min_silence) {
        my $retry = int($min_silence - $quiet_for);
        $retry = 1 if $retry < 1;
        return _decision(
            action              => 'skip',
            reason              => 'not_quiet',
            retry_after_seconds => $retry,
        );
    }

    return _decision(action => 'consider', reason => 'eligible');
}

sub spark_policy_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';

    my $action = $decision->{action};
    my $reason = $decision->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'consider' || $action eq 'skip';

    my %summary = (
        action => "$action",
        reason => "$reason",
    );

    $summary{retry_after_seconds} = int($decision->{retry_after_seconds})
        if _plain_scalar($decision->{retry_after_seconds})
            && "$decision->{retry_after_seconds}" =~ /^\d+\z/;

    return \%summary;
}

1;
