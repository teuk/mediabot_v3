package Mediabot::Spark::Selector;

use strict;
use warnings;

use Exporter 'import';

use Mediabot::Spark::Event qw(spark_event_kinds spark_event_profile);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    select_spark_event
    spark_selector_summary
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _nonneg_int {
    my ($value, $default) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    return int($value);
}

sub _bool {
    my ($value) = @_;
    return 0 if !defined($value) || ref($value);
    return $value ? 1 : 0;
}

sub _normal_kind {
    my ($kind) = @_;
    return undef unless _plain_scalar($kind);
    $kind = lc "$kind";
    my %known = map { $_ => 1 } @{ spark_event_kinds() };
    return $known{$kind} ? $kind : undef;
}

sub _normal_regime {
    my ($regime) = @_;
    return 'social' unless _plain_scalar($regime);
    $regime = lc "$regime";
    return $regime
        if $regime =~ /^(?:empty|solo|small|social|crowded)\z/;
    return 'social';
}

sub select_spark_event {
    my (%args) = @_;

    my $humans = _nonneg_int($args{recent_humans}, 0);
    my $context_lines = _nonneg_int($args{context_lines}, 0);
    my $ai_available = _bool($args{ai_available});
    my $vdm_enabled = _bool($args{vdm_enabled});
    my $cursor = _nonneg_int($args{cursor}, 0);
    my $last_kind = _normal_kind($args{last_kind});
    my $audience_regime = _normal_regime($args{audience_regime});

    my @eligible;
    for my $kind (@{ spark_event_kinds() }) {
        # Stage Cue belongs exclusively to the separately authorized momentum
        # lane. Catalog growth must never leak it into long-silence selection.
        next if $kind eq 'stage_cue';
        next if $audience_regime eq 'empty';
        next if $audience_regime eq 'solo'
            && $kind ne 'reaction'
            && $kind ne 'callback';
        next if $audience_regime eq 'small' && $kind eq 'portal';
        my $p = spark_event_profile($kind);
        my $required_humans = $p->{min_recent_humans};
        $required_humans = 1
            if $audience_regime eq 'solo'
                && ($kind eq 'reaction' || $kind eq 'callback');
        next if $humans < $required_humans;
        next if $p->{needs_context} && $context_lines < 3;
        next if ($kind eq 'callback' || $kind eq 'reaction') && !$ai_available;
        next if $kind eq 'mosaic' && !$ai_available;
        next if $kind eq 'vdm' && !$vdm_enabled;
        push @eligible, $kind;
    }

    return {
        action => 'skip',
        reason => 'no_eligible_event',
    } unless @eligible;

    my %eligible = map { $_ => 1 } @eligible;

    # Contextual weighted schedule, kept deterministic for reproducible tests and
    # operations. Reaction/Callback dominate rich context, Fork stays available,
    # Portal remains occasional until its contribution runtime is completed, and
    # VDM stays a rare source-backed variation when +VDM is enabled.
    my @schedule;
    if ($audience_regime eq 'solo') {
        @schedule = qw(reaction callback reaction);
    }
    elsif ($audience_regime eq 'crowded'
        && $ai_available && $context_lines >= 6) {
        @schedule = qw(reaction portal callback mosaic reaction portal fork vdm);
    }
    elsif ($ai_available && $context_lines >= 6) {
        @schedule = qw(reaction callback reaction mosaic fork callback portal reaction vdm);
    }
    elsif ($ai_available && $context_lines >= 3) {
        @schedule = qw(reaction fork callback mosaic reaction portal fork vdm);
    }
    else {
        @schedule = qw(fork portal fork mosaic vdm);
    }

    @schedule = grep { $eligible{$_} } @schedule;

    # Future catalog additions cannot disappear merely because the preference
    # schedule has not been taught about them yet.
    my %scheduled = map { $_ => 1 } @schedule;
    push @schedule, grep { !$scheduled{$_}++ } @eligible;

    if (@eligible > 1 && defined $last_kind) {
        my @without_repeat = grep { $_ ne $last_kind } @schedule;
        @schedule = @without_repeat if @without_repeat;
    }

    my $index = $cursor % @schedule;
    my $kind = $schedule[$index];
    my $profile = spark_event_profile($kind);

    return {
        action             => 'select',
        reason             => 'contextual_schedule',
        kind               => $kind,
        duration_seconds   => int($profile->{duration_seconds}),
        ai_use             => "$profile->{ai_use}",
        interaction        => "$profile->{interaction}",
        candidate_count    => scalar(@eligible),
        next_cursor        => $cursor + 1,
        audience_regime    => $audience_regime,
    };
}

sub spark_selector_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';
    return undef unless _plain_scalar($decision->{action}) && _plain_scalar($decision->{reason});
    return undef unless $decision->{action} eq 'select' || $decision->{action} eq 'skip';

    my %out = (
        action => "$decision->{action}",
        reason => "$decision->{reason}",
    );

    if ($decision->{action} eq 'select') {
        my $kind = _normal_kind($decision->{kind});
        return undef unless defined $kind;
        $out{kind} = $kind;
        for my $key (qw(duration_seconds candidate_count next_cursor)) {
            return undef unless _plain_scalar($decision->{$key}) && "$decision->{$key}" =~ /^\d+\z/;
            $out{$key} = int($decision->{$key});
        }
        for my $key (qw(ai_use interaction)) {
            return undef unless _plain_scalar($decision->{$key});
            $out{$key} = "$decision->{$key}";
        }
        $out{audience_regime} = _normal_regime(
            $decision->{audience_regime},
        );
    }

    return \%out;
}

1;
