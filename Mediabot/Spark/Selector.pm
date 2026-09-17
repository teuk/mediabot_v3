package Mediabot::Spark::Selector;

use strict;
use warnings;

use Exporter 'import';

use Mediabot::Spark::Event qw(
    spark_event_kinds spark_event_profile spark_event_is_selectable
);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    select_spark_event
    select_spark_action
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
        my $p = spark_event_profile($kind);
        next unless spark_event_is_selectable($kind);
        next unless ($p->{lane} // '') eq 'revival';
        next if $audience_regime eq 'empty';
        next if $audience_regime eq 'solo'
            && $kind ne 'reaction'
            && $kind ne 'callback'
            && $kind ne 'aside'
            && $kind ne 'micro_scene';
        next if $audience_regime eq 'small' && $kind eq 'portal';
        my $required_humans = $p->{min_recent_humans};
        $required_humans = 1
            if $audience_regime eq 'solo'
                && ($kind eq 'reaction' || $kind eq 'callback');
        next if $humans < $required_humans;
        next if $p->{needs_context} && $context_lines < 3;
        next if $p->{ai_use} ne 'never' && !$ai_available;
        next if $kind eq 'vdm' && !$vdm_enabled;
        push @eligible, $kind;
    }

    return {
        action => 'skip',
        reason => 'no_eligible_event',
    } unless @eligible;

    my %eligible = map { $_ => 1 } @eligible;

    # Deterministic variety: autonomous lines dominate quiet rooms, contextual
    # callbacks return when the room offers a real hook, and Portal stays rare.
    my @schedule;
    if ($audience_regime eq 'solo') {
        @schedule = qw(aside micro_scene reaction aside callback micro_scene);
    }
    elsif ($audience_regime eq 'crowded'
        && $ai_available && $context_lines >= 6) {
        @schedule = qw(reaction micro_scene callback aside portal reaction micro_scene vdm);
    }
    elsif ($ai_available && $context_lines >= 6) {
        @schedule = qw(reaction aside callback micro_scene reaction aside portal vdm);
    }
    elsif ($ai_available && $context_lines >= 3) {
        @schedule = qw(aside reaction micro_scene callback aside portal vdm);
    }
    else {
        @schedule = qw(aside micro_scene portal vdm);
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

sub select_spark_action {
    my (%args) = @_;
    my $context_lines = _nonneg_int($args{context_lines}, 0);
    return { action => 'skip', reason => 'ai_unavailable' }
        unless _bool($args{ai_available});
    return { action => 'skip', reason => 'context_too_small' }
        if $context_lines < 3;

    my $cursor = _nonneg_int($args{cursor}, 0);
    my $last_kind = _normal_kind($args{last_kind});
    my @schedule = qw(stage_cue afterglow afterglow stage_cue);
    if (defined $last_kind) {
        my @without_repeat = grep { $_ ne $last_kind } @schedule;
        @schedule = @without_repeat if @without_repeat;
    }
    my $kind = $schedule[$cursor % @schedule];
    my $profile = spark_event_profile($kind);
    return {
        action => 'select', reason => 'momentum_schedule', kind => $kind,
        duration_seconds => int($profile->{duration_seconds}),
        ai_use => "$profile->{ai_use}", interaction => "$profile->{interaction}",
        candidate_count => 2, next_cursor => $cursor + 1,
        audience_regime => _normal_regime($args{audience_regime}),
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
