package Mediabot::Spark::Orchestrator;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::AdaptivePolicy qw(
    adaptive_spark_policy adaptive_spark_policy_summary
);
use Mediabot::Spark::Observer;
use Mediabot::Spark::ActionPolicy qw(
    evaluate_spark_action_start spark_action_policy_summary
);
use Mediabot::Spark::Event qw(spark_event_profile);
use Mediabot::Spark::Policy qw(evaluate_spark_start spark_policy_summary);
use Mediabot::Spark::Selector qw(select_spark_event spark_selector_summary);
use Mediabot::Spark::State;

our $VERSION = '1.0';

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bool {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    return $value ? 1 : 0;
}

sub _channel_key {
    my ($channel) = @_;
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel)
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return lc "$channel";
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    my $n = int($value);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub new {
    my ($class, %args) = @_;

    my $state = $args{state};
    croak 'state must provide observe_human() and snapshot()'
        unless ref($state)
            && eval { $state->can('observe_human') }
            && eval { $state->can('snapshot') };

    my $observer = $args{observer};
    croak 'observer must provide observe_public_line() and context_lines()'
        unless ref($observer)
            && eval { $observer->can('observe_public_line') }
            && eval { $observer->can('context_lines') };

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    my $flood_guard = $args{flood_guard};
    if (defined $flood_guard) {
        croak 'flood_guard must provide observe_public_line() and current_decision()'
            unless ref($flood_guard)
                && eval { $flood_guard->can('observe_public_line') }
                && eval { $flood_guard->can('current_decision') };
    }
    else {
        $flood_guard = Mediabot::AI::ConversationFloodGuard->new();
    }

    return bless {
        state      => $state,
        observer   => $observer,
        flood_guard => $flood_guard,
        clock      => $clock || sub { clock_gettime(CLOCK_MONOTONIC) },
        min_silence_seconds => _bounded_int(
            $args{min_silence_seconds}, 1_200, 60, 86_400,
        ),
        candidate_probe_seconds => _bounded_int(
            $args{candidate_probe_seconds}, 300, 30, 3_600,
        ),
        action_probe_seconds => _bounded_int(
            $args{action_probe_seconds}, 30, 15, 300,
        ),
        action_cooldown_seconds => _bounded_int(
            $args{action_cooldown_seconds}, 1_200, 300, 86_400,
        ),
        action_activity_window_seconds => _bounded_int(
            $args{action_activity_window_seconds}, 600, 60, 3_600,
        ),
        action_min_humans => _bounded_int(
            $args{action_min_humans}, 3, 2, 100,
        ),
        action_min_lines => _bounded_int(
            $args{action_min_lines}, 6, 2, 64,
        ),
        action_min_pause_seconds => _bounded_int(
            $args{action_min_pause_seconds}, 45, 15, 600,
        ),
        action_max_pause_seconds => _bounded_int(
            $args{action_max_pause_seconds}, 180, 60, 1_800,
        ),
        runtime => {},
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = $self->{clock}->();
    croak 'clock must return a non-negative numeric value'
        unless _plain_scalar($now) && looks_like_number($now) && $now >= 0;
    return 0 + $now;
}

sub _rt {
    my ($self, $key) = @_;
    return $self->{runtime}{$key} ||= {
        cursor        => 0,
        last_kind     => undef,
        next_probe_at => 0,
        next_action_probe_at => 0,
        action_cooldown_until => 0,
        shared_cooldown_until => 0,
        last_adaptive_policy => undef,
    };
}

sub _adaptive_policy {
    my ($self, $activity) = @_;
    $activity = {} unless ref($activity) eq 'HASH';

    my $policy = adaptive_spark_policy(
        effective_humans_milli => $activity->{effective_humans_milli},
        distinct_humans => $activity->{distinct_humans},
        dominant_share_pct => $activity->{dominant_share_pct},
        human_line_rate_milli => $activity->{human_line_rate_milli},
        bot_pressure_share_pct => $activity->{bot_pressure_share_pct},
        base_revival_silence_seconds => $self->{min_silence_seconds},
        base_revival_probe_seconds => $self->{candidate_probe_seconds},
        base_action_min_humans => $self->{action_min_humans},
        base_action_min_lines => $self->{action_min_lines},
        base_action_min_pause_seconds => $self->{action_min_pause_seconds},
        base_action_max_pause_seconds => $self->{action_max_pause_seconds},
        base_shared_cooldown_seconds => $self->{action_cooldown_seconds},
    );
    return adaptive_spark_policy_summary($policy) || {
        audience_regime => 'empty',
        audience_rank => 0,
        audience_intensity_pct => 0,
        revival_min_humans => 2,
        revival_silence_seconds => $self->{min_silence_seconds},
        revival_probe_seconds => $self->{candidate_probe_seconds},
        action_min_humans => $self->{action_min_humans},
        action_min_lines => $self->{action_min_lines},
        action_min_pause_seconds => $self->{action_min_pause_seconds},
        action_max_pause_seconds => $self->{action_max_pause_seconds},
        shared_cooldown_seconds => $self->{action_cooldown_seconds},
        dominance_limited => 0,
        pressure_limited => 0,
    };
}

sub _shared_budget_wait {
    my ($rt, $now) = @_;
    return undef unless ($rt->{shared_cooldown_until} // 0) > $now;
    my $retry = int($rt->{shared_cooldown_until} - $now);
    $retry = 1 if $retry < 1;
    return {
        action => 'skip',
        reason => 'shared_budget',
        retry_after_seconds => $retry,
    };
}

sub evaluate_action_channel {
    my ($self, %args) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    return { action => 'skip', reason => 'spark_disabled' }
        unless _bool($args{spark_enabled});
    return { action => 'skip', reason => 'action_disabled' }
        unless _bool($args{action_enabled});
    return { action => 'skip', reason => 'ai_unavailable' }
        unless _bool($args{ai_available});

    my $now = $self->_now();
    my $rt = $self->_rt($channel);
    if (($rt->{next_action_probe_at} // 0) > $now) {
        my $retry = int($rt->{next_action_probe_at} - $now);
        $retry = 1 if $retry < 1;
        return {
            action => 'skip', reason => 'action_probe_wait',
            retry_after_seconds => $retry,
        };
    }

    my $state = eval { $self->{state}->snapshot($channel) };
    return { action => 'skip', reason => 'state_error' }
        unless ref($state) eq 'HASH';
    return { action => 'skip', reason => 'activity_unavailable' }
        unless eval { $self->{observer}->can('activity_summary') };
    my $activity = eval {
        $self->{observer}->activity_summary(
            $channel,
            window_seconds => $self->{action_activity_window_seconds},
        )
    };
    return { action => 'skip', reason => 'activity_error' }
        unless ref($activity) eq 'HASH';

    my $adaptive = $self->_adaptive_policy($activity);

    # Momentum requires an effective conversation, not merely two raw nicks.
    # A new public line resets the probe, so this bounded wait never delays a
    # room that genuinely grows beyond the empty/solo regimes.
    if ($adaptive->{audience_regime} eq 'empty'
        || $adaptive->{audience_regime} eq 'solo') {
        my $retry = $self->{action_probe_seconds};
        $rt->{next_action_probe_at} = $now + $retry;
        return {
            action => 'skip',
            reason => 'audience_too_small',
            retry_after_seconds => $retry,
            recent_humans => int($activity->{distinct_humans} // 0),
            effective_humans_milli => int(
                $activity->{effective_humans_milli} // 0
            ),
            dominant_share_pct => int(
                $activity->{dominant_share_pct} // 0
            ),
            audience_regime => $adaptive->{audience_regime},
            audience_intensity_pct => int(
                $adaptive->{audience_intensity_pct}
            ),
        };
    }

    if (int($activity->{bot_pressure_lines} // 0) > 0
        && int($activity->{bot_pressure_quiet_seconds} // 0)
            < $adaptive->{action_min_pause_seconds}) {
        my $retry = $adaptive->{action_min_pause_seconds}
            - int($activity->{bot_pressure_quiet_seconds} // 0);
        $retry = 1 if $retry < 1;
        $rt->{next_action_probe_at} = $now + $retry;
        return {
            action => 'skip',
            reason => 'bot_pressure',
            retry_after_seconds => $retry,
            bot_pressure_lines => int($activity->{bot_pressure_lines} // 0),
            bot_pressure_quiet_seconds => int(
                $activity->{bot_pressure_quiet_seconds} // 0
            ),
        };
    }

    my $flood = eval {
        $self->{flood_guard}->current_decision(channel => $channel)
    };
    my $flood_suppressed = 1;
    if (ref($flood) eq 'HASH'
        && (($flood->{action} // '') eq 'allow'
            || ($flood->{action} // '') eq 'suppress')) {
        $flood_suppressed = (($flood->{action} // '') eq 'suppress') ? 1 : 0;
    }

    my $decision = evaluate_spark_action_start(
        spark_enabled         => 1,
        action_enabled        => 1,
        channel               => $channel,
        runtime_active        => _bool($args{runtime_active}),
        irc_connected         => _bool($args{irc_connected}),
        channel_joined        => _bool($args{channel_joined}),
        flood_suppressed      => $flood_suppressed,
        event_active          => $state->{event_active},
        game_active           => _bool($args{game_active}),
        wit_pending           => _bool($args{wit_pending}),
        cooldown_until        => ($state->{cooldown_until} // 0)
            > ($rt->{shared_cooldown_until} // 0)
                ? ($state->{cooldown_until} // 0)
                : ($rt->{shared_cooldown_until} // 0),
        now                   => $now,
        last_human_at         => $activity->{last_human_at},
        recent_humans         => $activity->{distinct_humans},
        recent_lines          => $activity->{line_count},
        activity_window_seconds => $self->{action_activity_window_seconds},
        min_recent_humans     => $adaptive->{action_min_humans},
        min_recent_lines      => $adaptive->{action_min_lines},
        min_pause_seconds     => $adaptive->{action_min_pause_seconds},
        max_pause_seconds     => $adaptive->{action_max_pause_seconds},
    );
    my $safe = spark_action_policy_summary($decision) || {
        action => 'skip', reason => 'action_policy_error',
    };

    if (($safe->{action} // '') ne 'consider') {
        my $retry = int($safe->{retry_after_seconds} // 0);
        $retry = $self->{action_probe_seconds} if $retry < 1;
        $retry = $self->{action_probe_seconds}
            if $retry > $self->{action_probe_seconds};
        $rt->{next_action_probe_at} = $now + $retry;
        return {
            %$safe,
            audience_regime => $adaptive->{audience_regime},
            audience_intensity_pct => $adaptive->{audience_intensity_pct},
        };
    }

    my $profile = spark_event_profile('stage_cue');
    my $context = eval { $self->{observer}->context_lines($channel) };
    $context = [] unless ref($context) eq 'ARRAY';
    # A candidate consumes the current momentum window. New public activity
    # resets this probe below; without it, a declined provider result cannot
    # trigger repeated requests against the same paused conversation.
    $rt->{next_action_probe_at} =
        $now + $adaptive->{action_max_pause_seconds};
    $rt->{last_adaptive_policy} = { %$adaptive };
    return {
        %$safe,
        action => 'action_candidate',
        reason => 'momentum_ready',
        lane   => 'momentum',
        kind   => $profile->{kind},
        duration_seconds => int($profile->{duration_seconds}),
        ai_use => $profile->{ai_use},
        interaction => $profile->{interaction},
        context_lines => scalar(@$context),
        effective_humans_milli => int(
            $activity->{effective_humans_milli} // 0
        ),
        dominant_share_pct => int($activity->{dominant_share_pct} // 0),
        human_line_rate_milli => int(
            $activity->{human_line_rate_milli} // 0
        ),
        bot_pressure_lines => int($activity->{bot_pressure_lines} // 0),
        audience_regime => $adaptive->{audience_regime},
        audience_intensity_pct => int(
            $adaptive->{audience_intensity_pct}
        ),
        policy_min_pause_seconds => int(
            $adaptive->{action_min_pause_seconds}
        ),
        policy_max_pause_seconds => int(
            $adaptive->{action_max_pause_seconds}
        ),
        policy_cooldown_seconds => int(
            $adaptive->{shared_cooldown_seconds}
        ),
    };
}

sub mark_action_delivered {
    my ($self, $channel) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    my $key = _channel_key($channel);
    my $now = $self->_now();
    my $rt = $self->_rt($key);
    my $adaptive = ref($rt->{last_adaptive_policy}) eq 'HASH'
        ? $rt->{last_adaptive_policy}
        : {};
    my $cooldown = $self->action_cooldown_seconds($key);
    $rt->{action_cooldown_until} = $now + $cooldown;
    $rt->{shared_cooldown_until} = $rt->{action_cooldown_until};
    $rt->{next_action_probe_at} = $rt->{action_cooldown_until};
    return {
        action => 'paced',
        reason => 'action_delivered',
        cooldown_seconds => $cooldown,
        cooldown_until => 0 + $rt->{action_cooldown_until},
        audience_regime => $adaptive->{audience_regime} // 'social',
    };
}

sub action_cooldown_seconds {
    my ($self, $channel) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    if (defined $channel) {
        my $key = _channel_key($channel);
        my $rt = $self->_rt($key);
        if (ref($rt->{last_adaptive_policy}) eq 'HASH') {
            return int(
                $rt->{last_adaptive_policy}{shared_cooldown_seconds}
                    // $self->{action_cooldown_seconds}
            );
        }
    }
    return int($self->{action_cooldown_seconds});
}

sub observe_public_line {
    my ($self, %args) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    return { action => 'skip', reason => 'disabled' }
        unless _bool($args{enabled});

    my $flood = eval {
        $self->{flood_guard}->observe_public_line(channel => $channel)
    };
    return { action => 'skip', reason => 'flood_guard_error' }
        unless ref($flood) eq 'HASH'
            && (($flood->{action} // '') eq 'allow'
                || ($flood->{action} // '') eq 'suppress');

    my $observation = eval {
        $self->{observer}->observe_public_line(
            channel      => $channel,
            nick         => $args{nick},
            bot_nick     => $args{bot_nick},
            message      => $args{message},
            command_char => $args{command_char},
            initial_trigger_enabled => $args{initial_trigger_enabled},
            from_bot     => $args{from_bot},
            record       => ($flood->{action} // '') eq 'allow' ? 1 : 0,
        )
    };
    return { action => 'skip', reason => 'observer_error' }
        unless ref($observation) eq 'HASH';

    my $human;
    if (($observation->{reason} // '') eq 'human_context') {
        $human = eval {
            $self->{state}->observe_human(
                channel => $channel,
                nick    => $args{nick},
            )
        };
    }
    else {
        $human = eval { $self->{state}->snapshot($channel) };
    }
    return { action => 'skip', reason => 'state_error' }
        unless ref($human) eq 'HASH';

    if (($flood->{action} // '') eq 'suppress') {
        return {
            action              => 'observe',
            reason              => 'flood_suppression',
            recent_humans       => int($human->{recent_humans} // 0),
            retry_after_seconds => int($flood->{retry_after_seconds} // 0),
        };
    }

    # New conversation creates a new momentum window. The action cooldown
    # remains authoritative in policy. Bot/command pressure receives its own
    # short pause instead of masquerading as another human participant.
    if ($observation->{bot_pressure}) {
        $self->_rt($channel)->{next_action_probe_at} =
            $self->_now() + $self->{action_min_pause_seconds};
    }
    else {
        $self->_rt($channel)->{next_action_probe_at} = 0;
    }

    return {
        action        => 'observe',
        reason        => $observation->{reason} // 'human_activity',
        recent_humans => int($human->{recent_humans} // 0),
        context_lines => int($observation->{line_count} // 0),
    };
}

sub evaluate_channel {
    my ($self, %args) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    unless (_bool($args{enabled})) {
        $self->forget_channel($channel);
        return { action => 'skip', reason => 'disabled' };
    }

    my $now = $self->_now();
    my $rt = $self->_rt($channel);
    if (($rt->{next_probe_at} // 0) > $now) {
        my $retry = int($rt->{next_probe_at} - $now);
        $retry = 1 if $retry < 1;
        return {
            action              => 'skip',
            reason              => 'probe_wait',
            retry_after_seconds => $retry,
        };
    }

    my $state = eval { $self->{state}->snapshot($channel) };
    return { action => 'skip', reason => 'state_error' }
        unless ref($state) eq 'HASH';

    # If IRC truth says we are no longer in the channel, discard ephemeral
    # context so a later rejoin cannot resurrect stale conversation material.
    unless (_bool($args{runtime_active})
            && _bool($args{irc_connected})
            && _bool($args{channel_joined})) {
        $self->forget_channel($channel);
        return {
            action => 'skip',
            reason => !_bool($args{runtime_active}) ? 'runtime_inactive'
                    : !_bool($args{irc_connected}) ? 'irc_disconnected'
                    : 'not_joined',
        };
    }

    my $shared_wait = _shared_budget_wait($rt, $now);
    return $shared_wait if ref($shared_wait) eq 'HASH';

    my $flood = eval {
        $self->{flood_guard}->current_decision(channel => $channel)
    };
    my $flood_suppressed = 1;
    if (ref($flood) eq 'HASH'
        && (($flood->{action} // '') eq 'allow'
            || ($flood->{action} // '') eq 'suppress')) {
        $flood_suppressed = (($flood->{action} // '') eq 'suppress') ? 1 : 0;
    }

    my $activity_window = $self->{min_silence_seconds};
    $activity_window = 3_600 if $activity_window < 3_600;
    $activity_window = 7_200 if $activity_window > 7_200;
    my $activity = eval {
        $self->{observer}->activity_summary(
            $channel,
            window_seconds => $activity_window,
        )
    };
    $activity = {} unless ref($activity) eq 'HASH';
    my $adaptive = $self->_adaptive_policy($activity);
    if (int($activity->{bot_pressure_lines} // 0) > 0
        && int($activity->{bot_pressure_quiet_seconds} // 0)
            < $adaptive->{revival_silence_seconds}) {
        my $retry = $adaptive->{revival_silence_seconds}
            - int($activity->{bot_pressure_quiet_seconds} // 0);
        $retry = 1 if $retry < 1;
        $rt->{next_probe_at} = $now + $retry;
        return {
            action => 'skip',
            reason => 'bot_pressure',
            retry_after_seconds => $retry,
            recent_humans => int($state->{recent_humans} // 0),
            bot_pressure_lines => int($activity->{bot_pressure_lines} // 0),
        };
    }

    my $policy = evaluate_spark_start(
        enabled             => 1,
        channel             => $channel,
        runtime_active      => 1,
        irc_connected       => 1,
        channel_joined      => 1,
        flood_suppressed    => $flood_suppressed,
        event_active        => $state->{event_active},
        game_active         => _bool($args{game_active}),
        wit_pending         => _bool($args{wit_pending}),
        recent_humans       => $state->{recent_humans},
        cooldown_until      => ($state->{cooldown_until} // 0)
            > ($rt->{shared_cooldown_until} // 0)
                ? ($state->{cooldown_until} // 0)
                : ($rt->{shared_cooldown_until} // 0),
        last_human_at       => $state->{last_human_at},
        now                 => $now,
        min_recent_humans   => $adaptive->{revival_min_humans},
        min_silence_seconds => $adaptive->{revival_silence_seconds},
    );

    my $safe_policy = spark_policy_summary($policy) || {
        action => 'skip', reason => 'policy_error',
    };

    if (($safe_policy->{action} // '') ne 'consider') {
        my $retry = int($safe_policy->{retry_after_seconds} // 0);
        $retry = 30 if $retry < 30;
        $rt->{next_probe_at} = $now + $retry;
        return {
            %$safe_policy,
            recent_humans => int($state->{recent_humans} // 0),
        };
    }

    my $context = eval { $self->{observer}->context_lines($channel) };
    $context = [] unless ref($context) eq 'ARRAY';

    my $selection = select_spark_event(
        recent_humans => $state->{recent_humans},
        context_lines => scalar(@$context),
        ai_available  => _bool($args{ai_available}),
        vdm_enabled   => _bool($args{vdm_enabled}),
        cursor        => $rt->{cursor},
        last_kind     => $rt->{last_kind},
        audience_regime => $adaptive->{audience_regime},
    );

    my $safe_selection = spark_selector_summary($selection) || {
        action => 'skip', reason => 'selector_error',
    };

    if (($safe_selection->{action} // '') ne 'select') {
        $rt->{next_probe_at} = $now + $adaptive->{revival_probe_seconds};
        return {
            action        => 'skip',
            reason        => $safe_selection->{reason},
            recent_humans => int($state->{recent_humans} // 0),
            context_lines => scalar(@$context),
            audience_regime => $adaptive->{audience_regime},
        };
    }

    $rt->{cursor} = int($safe_selection->{next_cursor});
    $rt->{last_kind} = $safe_selection->{kind};
    $rt->{next_probe_at} = $now + $adaptive->{revival_probe_seconds};
    $rt->{last_adaptive_policy} = { %$adaptive };

    my $quiet_for = defined($state->{last_human_at})
        ? int($now - $state->{last_human_at})
        : 0;
    $quiet_for = 0 if $quiet_for < 0;

    # Deliberately do NOT call State::begin_event() here. No visible event has
    # been emitted in MB703-D, so creating an active event would be a lie.
    return {
        action           => 'dryrun_candidate',
        reason           => 'eligible_disarmed',
        kind             => $safe_selection->{kind},
        duration_seconds => int($safe_selection->{duration_seconds}),
        ai_use           => $safe_selection->{ai_use},
        interaction      => $safe_selection->{interaction},
        recent_humans    => int($state->{recent_humans} // 0),
        context_lines    => scalar(@$context),
        quiet_for_seconds => $quiet_for,
        effective_humans_milli => int(
            $activity->{effective_humans_milli} // 0
        ),
        dominant_share_pct => int($activity->{dominant_share_pct} // 0),
        human_line_rate_milli => int(
            $activity->{human_line_rate_milli} // 0
        ),
        bot_pressure_lines => int($activity->{bot_pressure_lines} // 0),
        audience_regime => $adaptive->{audience_regime},
        audience_intensity_pct => int(
            $adaptive->{audience_intensity_pct}
        ),
        policy_silence_seconds => int(
            $adaptive->{revival_silence_seconds}
        ),
        policy_probe_seconds => int(
            $adaptive->{revival_probe_seconds}
        ),
    };
}

sub channels {
    my ($self) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    return $self->{observer}->channels();
}

sub context_lines {
    my ($self, $channel) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    return $self->{observer}->context_lines($channel);
}

sub flood_suppressed {
    my ($self, $channel) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    my $key = _channel_key($channel);

    my $decision = eval {
        $self->{flood_guard}->current_decision(channel => $key)
    };
    return 1 unless ref($decision) eq 'HASH'
        && (($decision->{action} // '') eq 'allow'
            || ($decision->{action} // '') eq 'suppress');
    return ($decision->{action} // '') eq 'suppress' ? 1 : 0;
}

sub forget_channel {
    my ($self, $channel) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    my $key = _channel_key($channel);
    eval { $self->{state}->forget_channel($key); };
    eval { $self->{observer}->forget_channel($key); };
    delete $self->{runtime}{$key};
    return 1;
}

sub clear_all {
    my ($self) = @_;
    croak 'Spark orchestrator object is required' unless ref($self);
    my $channels = $self->channels();
    $self->forget_channel($_) for @$channels;
    return scalar(@$channels);
}

sub format_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return undef unless ref($summary) eq 'HASH';
    return undef unless ($summary->{action} // '') eq 'dryrun_candidate';
    return undef unless _plain_scalar($summary->{kind})
        && "$summary->{kind}" =~ /^(?:fork|portal|callback|reaction|mosaic|vdm)\z/;

    my @parts = (
        '[SPARK_DRYRUN]',
        'channel=' . $channel,
        'action=dryrun_candidate',
        'kind=' . $summary->{kind},
    );

    push @parts, 'audience_regime=' . $summary->{audience_regime}
        if _plain_scalar($summary->{audience_regime})
            && "$summary->{audience_regime}"
                =~ /^(?:empty|solo|small|social|crowded)\z/;

    for my $key (qw(
        recent_humans effective_humans_milli dominant_share_pct
        human_line_rate_milli bot_pressure_lines context_lines
        quiet_for_seconds duration_seconds audience_intensity_pct
        policy_silence_seconds policy_probe_seconds
    )) {
        next unless _plain_scalar($summary->{$key}) && "$summary->{$key}" =~ /^\d+\z/;
        push @parts, "$key=" . int($summary->{$key});
    }

    push @parts, 'ai_use=' . $summary->{ai_use}
        if _plain_scalar($summary->{ai_use})
            && "$summary->{ai_use}" =~ /^(?:never|optional|preferred|required)\z/;

    return join(' ', @parts);
}

sub format_action_candidate_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return undef unless ref($summary) eq 'HASH';
    return undef unless ($summary->{action} // '') eq 'action_candidate';
    return undef unless ($summary->{lane} // '') eq 'momentum';
    return undef unless ($summary->{kind} // '') eq 'stage_cue';

    my @parts = (
        '[SPARK_ACTION_CANDIDATE]',
        'channel=' . $channel,
        'action=action_candidate',
        'lane=momentum',
        'kind=stage_cue',
    );
    push @parts, 'audience_regime=' . $summary->{audience_regime}
        if _plain_scalar($summary->{audience_regime})
            && "$summary->{audience_regime}"
                =~ /^(?:empty|solo|small|social|crowded)\z/;
    for my $key (qw(
        activity_window_seconds recent_humans recent_lines quiet_for_seconds
        effective_humans_milli dominant_share_pct human_line_rate_milli
        bot_pressure_lines context_lines duration_seconds
        audience_intensity_pct
        policy_min_pause_seconds policy_max_pause_seconds
        policy_cooldown_seconds
    )) {
        next unless _plain_scalar($summary->{$key})
            && "$summary->{$key}" =~ /^\d+\z/;
        push @parts, "$key=" . int($summary->{$key});
    }
    return join(' ', @parts);
}

1;
