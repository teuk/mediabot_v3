package Mediabot::AI::ConversationDryRun;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

use Mediabot::AI::ConversationExecutor qw(execution_summary);
use Mediabot::AI::ConversationFloodGuard ();
use Mediabot::AI::ConversationObserver qw(observe_public_line);
use Mediabot::AI::ConversationRoom;

our $VERSION = '1.0';
our @EXPORT_OK = qw(format_ai_dryrun_log);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_short {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text) && length($text) <= $max;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    return $text;
}

sub new {
    my ($class, %args) = @_;

    my $executor = $args{executor};
    if (defined $executor) {
        croak 'executor must provide submit_dryrun()'
            unless ref($executor) && eval { $executor->can('submit_dryrun') };
    }
    else {
        my $conf = $args{conf};
        croak 'conf is required when executor is not injected'
            unless $conf && ref($conf) && eval { $conf->can('get') };

        $executor = Mediabot::AI::ConversationExecutor->new(
            conf       => $conf,
            loop_owner => $args{loop_owner},
        );
    }

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
        executor       => $executor,
        flood_guard    => $flood_guard,
        clock          => $clock || sub { time() },
        room           => Mediabot::AI::ConversationRoom->new(clock => $clock || sub { time() }),
        inflight       => {},
        last_submit_at => {},
    }, $class;
}

sub _runtime_language {
    my ($value) = @_;
    my $language = _plain_scalar($value) ? lc("$value") : 'en';
    return $language if $language eq 'en' || $language eq 'fr' || $language eq 'es';
    return 'en';
}

sub _runtime_no_reply {
    my ($reason, %extra) = @_;
    my %out = (
        ok     => 1,
        action => 'no_reply',
        reason => $reason,
    );
    $out{$_} = $extra{$_} for keys %extra;
    return \%out;
}

sub handle_public_line {
    my ($self, %args) = @_;
    croak 'dry-run object is required' unless ref($self);

    my $on_observation = delete $args{on_observation};
    my $on_candidate   = delete $args{on_candidate};
    my $on_result      = delete $args{on_result};
    croak 'on_observation must be a code reference'
        if defined($on_observation) && ref($on_observation) ne 'CODE';
    croak 'on_candidate must be a code reference'
        if defined($on_candidate) && ref($on_candidate) ne 'CODE';
    croak 'on_result must be a code reference'
        unless ref($on_result) eq 'CODE';

    my $channel = $args{channel};
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel) && "$channel" =~ /^#/;

    my $channel_key = lc "$channel";
    my $language = _runtime_language($args{language});
    my $style = delete($args{style}) // 'wit';
    croak 'invalid conversation style' unless !ref($style) && $style =~ /^(?:wit|quip|mixed)\z/;
    my $quip = $style ne 'wit';
    my $context_blocked = delete $args{context_blocked};
    my $room = eval { $self->{room}->observe_public_line(%args) };
    if ($quip) {
        my $observation_cb = $on_observation;
        $on_observation = sub {
            my ($summary) = @_;
            $observation_cb->({ %$summary, style => $style }) if $observation_cb;
        };
        my $result_cb = $on_result;
        $on_result = sub { my ($summary) = @_; $result_cb->({ %$summary, style => $style }) };
    }

    # MB702-A2: count every public line before inflight/policy/provider work.
    # A tripped/broken guard fails closed and cannot submit to an AI provider.
    my $flood = eval {
        $self->{flood_guard}->observe_public_line(channel => $channel);
    };
    unless (ref($flood) eq 'HASH'
        && (($flood->{action} // '') eq 'allow'
            || ($flood->{action} // '') eq 'suppress')) {
        my $summary = _runtime_no_reply(
            'flood_guard_error',
            language => $language,
            provider => 'auto',
        );
        $on_observation->($summary) if $on_observation;
        return 0;
    }

    if (($flood->{action} // '') eq 'suppress') {
        my %extra = (
            language => $language,
            provider => 'auto',
        );
        $extra{retry_after_seconds} = int($flood->{retry_after_seconds})
            if _plain_scalar($flood->{retry_after_seconds})
                && "$flood->{retry_after_seconds}" =~ /^\d+\z/;

        my $summary = _runtime_no_reply('flood_suppression', %extra);
        $on_observation->($summary) if $on_observation;
        return 0;
    }

    my $now = $self->{clock}->();

    if ($quip && (ref($room) ne 'HASH' || !$room->{ready} || $context_blocked)) {
        my $reason = $context_blocked ? 'conversation_busy'
            : ref($room) eq 'HASH' ? $room->{reason} : 'room_error';
        $on_observation->(_runtime_no_reply($reason, language => $language, provider => 'auto'));
        return 0;
    }

    if ($self->{inflight}{$channel_key}) {
        my $summary = _runtime_no_reply(
            'inflight',
            language => $language,
            provider => 'auto',
        );
        $on_observation->($summary) if $on_observation;
        return 0;
    }

    my $observation = observe_public_line(
        %args,
        now           => $now,
        last_reply_at => $self->{last_submit_at}{$channel_key},
    );

    $on_observation->($observation) if $on_observation;
    return 0 unless ref($observation) eq 'HASH'
        && ($observation->{action} // '') eq 'consider';

    $self->{inflight}{$channel_key} = 1;

    my $completed = 0;
    my $finish = sub {
        my ($result) = @_;
        return if $completed++;

        delete $self->{inflight}{$channel_key};

        if ($quip && ref($result) eq 'HASH' && ($result->{action} // '') eq 'reply'
            && !$self->room_current($channel, $room->{fingerprint}, $now)) {
            $on_result->({ ok => 1, action => 'no_reply', reason => 'room_changed' });
            return;
        }

        # MB702-A3: a provider reply that was started before flood suppression
        # may no longer cross the private candidate boundary. Re-check the
        # current per-channel flood state immediately before on_candidate.
        if (ref($result) eq 'HASH'
            && ($result->{action} // '') eq 'reply') {
            my $late_flood = eval {
                $self->{flood_guard}->current_decision(channel => $channel);
            };

            my $late_action = ref($late_flood) eq 'HASH'
                ? ($late_flood->{action} // '')
                : q{};

            if ($late_action ne 'allow' && $late_action ne 'suppress') {
                my %blocked = (
                    ok     => 0,
                    action => 'no_reply',
                    reason => 'flood_guard_error',
                    error  => 'late_flood_guard_invalid',
                );
                for my $key (qw(provider model provider_fallback model_fallback)) {
                    $blocked{$key} = $result->{$key} if exists $result->{$key};
                }
                $on_result->(execution_summary(\%blocked));
                return;
            }

            if ($late_action eq 'suppress') {
                my %blocked = (
                    ok     => 1,
                    action => 'no_reply',
                    reason => 'flood_suppression',
                );
                for my $key (qw(provider model provider_fallback model_fallback)) {
                    $blocked{$key} = $result->{$key} if exists $result->{$key};
                }
                $on_result->(execution_summary(\%blocked));
                return;
            }
        }

        # MB701-C: the normalized reply text may cross exactly one private
        # in-memory boundary into the late emission gate. Public/result logging
        # still receives execution_summary(), which never contains that text.
        if ($on_candidate
            && ref($result) eq 'HASH'
            && ($result->{action} // '') eq 'reply'
            && _plain_scalar($result->{text})) {
            $result = {
                %$result, style => $style,
                context_fingerprint => $room->{fingerprint}, context_started_at => $now,
            } if $quip;
            my $candidate_ok = eval {
                $on_candidate->($result);
                1;
            };
            unless ($candidate_ok) {
                my %failed = (
                    ok     => 0,
                    action => 'no_reply',
                    reason => 'runtime_guard_error',
                    error  => 'candidate_callback_exception',
                );
                for my $key (qw(provider model provider_fallback model_fallback)) {
                    $failed{$key} = $result->{$key} if exists $result->{$key};
                }
                $on_result->(execution_summary(\%failed));
                return;
            }
        }

        my $summary = execution_summary($result);
        $summary ||= {
            ok     => 0,
            action => 'no_reply',
            reason => 'provider_error',
            error  => 'invalid_executor_result',
        };
        $on_result->($summary);
    };

    my $started;
    # An unsuccessful Quip provider attempt also spends the shared request
    # interval. Switching modes must not retry the same failing provider per line.
    $self->{last_submit_at}{$channel_key} = $now if $quip;
    my $ok = eval {
        $started = $self->{executor}->submit_dryrun(
            provider => $observation->{provider},
            language => $observation->{language},
            message  => $args{message},
            ($quip ? (style => $style, context => $room->{context},
                previous_reply => $room->{previous_reply}) : ()),
            on_done  => $finish,
        );
        1;
    };

    unless ($ok) {
        delete $self->{inflight}{$channel_key};
        $finish->({
            ok     => 0,
            action => 'no_reply',
            reason => 'provider_error',
            error  => 'executor_exception',
        });
        return 0;
    }

    if ($started) {
        $self->{last_submit_at}{$channel_key} = $now;
        return 1;
    }

    # ConversationExecutor/AI::Client may complete synchronously with an async
    # availability error before returning false. If it did not, fail closed.
    $finish->({
        ok     => 0,
        action => 'no_reply',
        reason => 'provider_error',
        error  => 'async_unavailable',
    }) unless $completed;

    return 0;
}

sub channel_inflight {
    my ($self, $channel) = @_;
    croak 'dry-run object is required' unless ref($self);
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return $self->{inflight}{lc "$channel"} ? 1 : 0;
}

sub room_current {
    my ($self, $channel, $fingerprint, $started_at) = @_;
    return 0 unless defined($fingerprint) && !ref($fingerprint) && $fingerprint =~ /^[a-f0-9]{64}\z/
        && defined($started_at) && !ref($started_at) && "$started_at" =~ /^\d+(?:\.\d+)?\z/;
    my $room = eval { $self->{room}->snapshot($channel) };
    return 0 unless ref($room) eq 'HASH' && $room->{ready};
    my $now = $self->{clock}->();
    return $now >= $started_at && $now - $started_at <= 30
        && $room->{fingerprint} eq $fingerprint ? 1 : 0;
}

sub note_delivery {
    my ($self, $channel, $text) = @_;
    return $self->{room}->note_delivery($channel, $text);
}

sub note_bot_pressure {
    my ($self, $channel) = @_;
    return $self->{room}->note_bot_pressure($channel);
}

sub forget_room {
    my ($self, $channel) = @_;
    return $self->{room}->forget_channel($channel);
}

sub format_ai_dryrun_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel) && "$channel" =~ /^#/;
    return undef unless ref($summary) eq 'HASH';

    my $action = _safe_short($summary->{action}, 32);
    my $reason = _safe_short($summary->{reason}, 64);
    return undef unless defined($action) && defined($reason);
    return undef unless $action eq 'reply' || $action eq 'no_reply';

    my @parts = (
        (($summary->{style} // '') =~ /^(?:quip|mixed)\z/ ? '[QUIP_AI]' : '[WIT_AI_DRYRUN]'),
        'channel=' . $channel,
        'action=' . $action,
        'reason=' . $reason,
    );
    push @parts, 'style=' . $summary->{style}
        if ($summary->{style} // '') =~ /^(?:quip|mixed)\z/;

    for my $key (qw(provider model error)) {
        my $value = _safe_short($summary->{$key}, 160);
        push @parts, "$key=$value" if defined $value;
    }

    push @parts, 'provider_fallback=' . ($summary->{provider_fallback} ? 1 : 0)
        if exists $summary->{provider_fallback};
    push @parts, 'model_fallback=' . ($summary->{model_fallback} ? 1 : 0)
        if exists $summary->{model_fallback};

    if (defined($summary->{reply_chars}) && !ref($summary->{reply_chars})
        && "$summary->{reply_chars}" =~ /^\d+\z/) {
        push @parts, 'reply_chars=' . int($summary->{reply_chars});
    }

    return join ' ', @parts;
}

1;
