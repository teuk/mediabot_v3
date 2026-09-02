package Mediabot::Hailo::PostEditRuntime;

use strict;
use warnings;
use utf8;

use Carp qw(croak);
use Encode qw(encode_utf8);

use Mediabot::Hailo::ReplyQueue;

our $VERSION = '1.0';

sub _plain {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain($value) && "$value" =~ /^\d+\z/;
    my $number = int($value);
    return $min if $number < $min;
    return $max if $number > $max;
    return $number;
}

sub _channel_key {
    my ($value) = @_;
    return undef unless _plain($value)
        && "$value" =~ /^[#&+!][^\s,\x00-\x1f\x7f]{1,79}\z/;
    my $key = lc "$value";
    $key =~ tr/[]\\^/{}|~/;
    return $key;
}

sub _clean_context_line {
    my ($value, $max) = @_;
    return undef unless _plain($value);
    my $line = "$value";
    return undef if $line =~ /[\r\n\x00]/;
    $line =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $line =~ s/[\x01-\x08\x0b\x0c\x0e\x11-\x15\x17-\x1c\x1e\x7f]//g;
    $line =~ s/^\s+|\s+$//g;
    $line =~ s/\s{2,}/ /g;
    return undef unless length($line) && length($line) <= $max;
    return $line;
}

sub _safe_emission_line {
    my ($value, $max, $prefixes) = @_;
    my $line = _clean_context_line($value, $max);
    return (undef, 'invalid_output') unless defined $line;
    return (undef, 'oversized_output') if length(encode_utf8($line)) > 400;

    if (ref($prefixes) eq 'ARRAY') {
        for my $prefix (@$prefixes) {
            next unless _plain($prefix) && length("$prefix") == 1;
            return (undef, 'command_output') if index($line, "$prefix") == 0;
        }
    }
    return ($line, undef);
}

sub new {
    my ($class, %args) = @_;
    my $post_editor = $args{post_editor};
    croak 'post_editor must provide submit()'
        unless $post_editor && ref($post_editor)
            && eval { $post_editor->can('submit') };

    my $queue = $args{queue};
    if (defined $queue) {
        croak 'queue must provide enqueue(), take_next() and typing_delay_seconds()'
            unless ref($queue)
                && eval { $queue->can('enqueue') }
                && eval { $queue->can('take_next') }
                && eval { $queue->can('typing_delay_seconds') };
    }
    else {
        $queue = Mediabot::Hailo::ReplyQueue->new();
    }

    for my $name (qw(clock schedule_cb metric_cb log_cb)) {
        croak "$name must be a code reference"
            if defined($args{$name}) && ref($args{$name}) ne 'CODE';
    }

    return bless {
        post_editor         => $post_editor,
        queue               => $queue,
        clock               => $args{clock} || sub { time() },
        schedule_cb         => $args{schedule_cb},
        metric_cb           => $args{metric_cb},
        log_cb              => $args{log_cb},
        max_context_lines   => _bounded_int($args{max_context_lines}, 4, 1, 8),
        max_context_chars   => _bounded_int($args{max_context_chars}, 500, 80, 800),
        max_context_channels => _bounded_int($args{max_context_channels}, 256, 1, 4096),
        max_inflight        => _bounded_int($args{max_inflight}, 4, 1, 32),
        typing_enabled      => exists($args{typing_enabled})
            ? ($args{typing_enabled} ? 1 : 0) : 1,
        contexts            => {},
        inflight            => {},
        inflight_total      => 0,
        pumping             => 0,
        stats               => {
            observed => 0,
            submitted => 0,
            sent => 0,
            dropped => 0,
        },
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = eval { $self->{clock}->() };
    return time() unless _plain($now)
        && "$now" =~ /^-?(?:\d+(?:[.]\d*)?|[.]\d+)\z/;
    return 0 + $now;
}

sub _touch_context {
    my ($self, $key) = @_;
    if (!exists($self->{contexts}{$key})
        && keys(%{ $self->{contexts} }) >= $self->{max_context_channels}) {
        my ($oldest) = sort {
            ($self->{contexts}{$a}{touched} // 0)
                <=> ($self->{contexts}{$b}{touched} // 0)
        } keys %{ $self->{contexts} };
        delete $self->{contexts}{$oldest} if defined $oldest;
    }
    return $self->{contexts}{$key} ||= { touched => 0, lines => [] };
}

sub observe_public_line {
    my ($self, %args) = @_;
    croak 'runtime object is required' unless ref($self);
    return 0 if $args{from_bot} || $args{is_command};

    my $key = _channel_key($args{channel});
    return 0 unless defined $key;
    my $line = _clean_context_line(
        $args{text}, $self->{max_context_chars}
    );
    return 0 unless defined $line;

    my $context = $self->_touch_context($key);
    $context->{touched} = $self->_now;
    push @{ $context->{lines} }, $line;
    splice @{ $context->{lines} }, 0,
        @{ $context->{lines} } - $self->{max_context_lines}
        if @{ $context->{lines} } > $self->{max_context_lines};
    $self->{stats}{observed}++;
    return 1;
}

sub recent_context {
    my ($self, %args) = @_;
    croak 'runtime object is required' unless ref($self);
    my $key = _channel_key($args{channel});
    return [] unless defined($key) && exists($self->{contexts}{$key});

    my @lines = @{ $self->{contexts}{$key}{lines} || [] };
    my $trigger = _clean_context_line(
        $args{trigger}, $self->{max_context_chars}
    );
    pop @lines if defined($trigger) && @lines && $lines[-1] eq $trigger;
    splice @lines, 0, @lines - $self->{max_context_lines}
        if @lines > $self->{max_context_lines};
    return \@lines;
}

sub _report {
    my ($self, $summary, $on_done) = @_;
    my $action = ref($summary) eq 'HASH' ? ($summary->{action} // 'dropped') : 'dropped';
    $action = $action eq 'sent' ? 'sent' : 'dropped';
    $self->{stats}{$action}++;

    eval { $self->{metric_cb}->($summary) } if $self->{metric_cb};
    eval { $self->{log_cb}->($summary) } if $self->{log_cb};
    eval { $on_done->($summary) } if ref($on_done) eq 'CODE';
    return 1;
}

sub _expire_queued {
    my ($self, $job) = @_;
    return unless ref($job) eq 'HASH';
    $self->_report({
        action  => 'dropped',
        reason  => 'queue_expired',
        channel => $job->{channel},
        mode    => $job->{mode},
    }, $job->{on_done});
}

sub submit {
    my ($self, %args) = @_;
    croak 'runtime object is required' unless ref($self);

    my $channel_key = _channel_key($args{channel});
    return { accepted => 0, reason => 'invalid_channel' }
        unless defined $channel_key;
    return { accepted => 0, reason => 'invalid_callbacks' }
        unless ref($args{send_cb}) eq 'CODE'
            && ref($args{state_cb}) eq 'CODE';

    my $candidate = _clean_context_line($args{candidate}, 360);
    my $trigger = _clean_context_line($args{trigger}, 600);
    return { accepted => 0, reason => 'invalid_candidate' }
        unless defined($candidate) && defined($trigger);
    return { accepted => 0, reason => 'invalid_generation' }
        unless _plain($args{request_generation})
            && "$args{request_generation}" =~ /^[1-9]\d{0,14}\z/;

    my $job = {
        channel           => "$args{channel}",
        channel_key       => $channel_key,
        trigger           => $trigger,
        candidate         => $candidate,
        channel_language  => $args{channel_language},
        provider          => _plain($args{provider}) ? "$args{provider}" : 'auto',
        mode              => _plain($args{mode}) ? "$args{mode}" : 'mention',
        request_generation => int($args{request_generation}),
        post_edit_enabled => exists($args{post_edit_enabled})
            ? ($args{post_edit_enabled} ? 1 : 0) : 1,
        command_prefixes  => ref($args{command_prefixes}) eq 'ARRAY'
            ? [ @{ $args{command_prefixes} } ] : ['!'],
        context           => $self->recent_context(
            channel => $args{channel}, trigger => $trigger,
        ),
        send_cb           => $args{send_cb},
        state_cb          => $args{state_cb},
        on_done           => $args{on_done},
        queued_at         => $self->_now,
        completed         => 0,
    };

    my $queued = $self->{queue}->enqueue(
        channel   => $job->{channel},
        payload   => $job,
        on_ready  => sub { $self->_start_job($_[0], $_[1]) },
        on_expire => sub { $self->_expire_queued($_[0]{payload}) },
    );
    unless (ref($queued) eq 'HASH' && $queued->{accepted}) {
        my $reason = ref($queued) eq 'HASH'
            ? ($queued->{reason} // 'queue_rejected') : 'queue_rejected';
        $self->_report({
            action  => 'dropped',
            reason  => $reason,
            channel => $job->{channel},
            mode    => $job->{mode},
        }, $job->{on_done});
        return { accepted => 0, reason => $reason };
    }

    $job->{queue_id} = $queued->{id};
    $self->{stats}{submitted}++;
    $self->_pump;
    return { accepted => 1, reason => 'queued', id => $queued->{id} };
}

sub _pump {
    my ($self) = @_;
    return 0 if $self->{pumping};
    local $self->{pumping} = 1;

    my $started = 0;
    while ($self->{inflight_total} < $self->{max_inflight}) {
        my $entry = $self->{queue}->take_next(sub {
            my ($candidate) = @_;
            return !$self->{inflight}{ $candidate->{channel_key} };
        });
        last unless $entry;
        my $ok = eval { $entry->{on_ready}->($entry->{payload}, $entry); 1 };
        unless ($ok) {
            my $job = $entry->{payload};
            $self->_report({
                action  => 'dropped',
                reason  => 'runtime_exception',
                channel => ref($job) eq 'HASH' ? $job->{channel} : undef,
            }, ref($job) eq 'HASH' ? $job->{on_done} : undef);
        }
        $started++;
    }
    return $started;
}

sub _start_job {
    my ($self, $job, $entry) = @_;
    return 0 unless ref($job) eq 'HASH' && ref($entry) eq 'HASH';
    my $key = $job->{channel_key};
    return 0 if $self->{inflight}{$key};

    $job->{queued_at} = $entry->{queued_at}
        if _plain($entry->{queued_at});
    $self->{inflight}{$key} = $job;
    $self->{inflight_total}++;

    unless ($job->{post_edit_enabled}) {
        $self->_provider_done($job, {
            ok       => 1,
            line     => $job->{candidate},
            edited   => 0,
            reason   => 'disabled_fallback',
            language => { language => $job->{channel_language} || 'en' },
        });
        return 1;
    }

    my $callback_seen = 0;
    my $started;
    my $ok = eval {
        $started = $self->{post_editor}->submit(
            provider         => $job->{provider},
            channel_language => $job->{channel_language},
            context          => $job->{context},
            trigger          => $job->{trigger},
            candidate        => $job->{candidate},
            on_done          => sub {
                return if $callback_seen++;
                $self->_provider_done($job, $_[0]);
            },
        );
        1;
    };

    if (!$ok || (!$started && !$callback_seen)) {
        $callback_seen = 1;
        $self->_provider_done($job, {
            ok       => 1,
            line     => $job->{candidate},
            edited   => 0,
            reason   => 'provider_error',
            language => { language => $job->{channel_language} || 'en' },
        });
    }
    return 1;
}

sub _provider_done {
    my ($self, $job, $result) = @_;
    return 0 unless ref($job) eq 'HASH';
    return 0 if $job->{completed};

    $result = {} unless ref($result) eq 'HASH';
    $job->{provider_result} = {
        line     => _plain($result->{line}) ? "$result->{line}" : $job->{candidate},
        edited   => $result->{edited} ? 1 : 0,
        reason   => _plain($result->{reason}) ? "$result->{reason}" : 'provider_error',
        language => ref($result->{language}) eq 'HASH'
            ? { %{ $result->{language} } } : {},
        (_plain($result->{provider}) ? (provider => "$result->{provider}") : ()),
    };

    my $delay = $self->{typing_enabled}
        ? $self->{queue}->typing_delay_seconds($job->{provider_result}{line})
        : 0;
    $delay = 0 unless _plain($delay) && "$delay" =~ /^\d+\z/;

    if ($delay > 0 && $self->{schedule_cb}) {
        my $scheduled = eval {
            $self->{schedule_cb}->($delay, sub { $self->_emit_job($job) });
        };
        return 1 if $scheduled;
    }
    return $self->_emit_job($job);
}

sub _state_reason {
    my ($state, $job) = @_;
    return 'state_error' unless ref($state) eq 'HASH';
    return 'disabled' unless $state->{enabled};
    return 'runtime_inactive' unless $state->{runtime_active};
    return 'irc_disconnected' unless $state->{irc_connected};
    return 'not_joined' unless $state->{channel_joined};
    return 'stale_generation'
        unless _plain($state->{current_generation})
            && "$state->{current_generation}" =~ /^\d+\z/
            && int($state->{current_generation}) == $job->{request_generation};
    return undef;
}

sub _emit_job {
    my ($self, $job) = @_;
    return 0 unless ref($job) eq 'HASH';
    return 0 if $job->{completed};

    my $ttl = eval { $self->{queue}->ttl_seconds } || 15;
    if (($self->_now - $job->{queued_at}) >= $ttl) {
        return $self->_finish_job($job, 'dropped', 'expired');
    }

    my $state = eval { $job->{state_cb}->() };
    my $blocked = _state_reason($state, $job);
    return $self->_finish_job($job, 'dropped', $blocked) if defined $blocked;

    my ($line, $line_error) = _safe_emission_line(
        $job->{provider_result}{line}, 360, $job->{command_prefixes},
    );
    return $self->_finish_job($job, 'dropped', $line_error)
        unless defined $line;

    my $sent = eval { $job->{send_cb}->($job->{channel}, $line) };
    return $self->_finish_job($job, 'dropped', 'send_failed') unless $sent;

    $self->observe_public_line(
        channel => $job->{channel},
        text    => $line,
    );
    return $self->_finish_job($job, 'sent', 'delivered');
}

sub _finish_job {
    my ($self, $job, $action, $reason) = @_;
    return 0 if $job->{completed}++;
    my $provider = $job->{provider_result} || {};
    my $summary = {
        action   => $action,
        reason   => $reason,
        channel  => $job->{channel},
        mode     => $job->{mode},
        edited   => $provider->{edited} ? 1 : 0,
        edit_reason => $provider->{reason} || 'provider_error',
        language => ref($provider->{language}) eq 'HASH'
            ? ($provider->{language}{language} || 'en') : 'en',
        (_plain($provider->{provider}) ? (provider => $provider->{provider}) : ()),
    };

    delete $self->{inflight}{ $job->{channel_key} };
    $self->{inflight_total}-- if $self->{inflight_total} > 0;
    $self->_report($summary, $job->{on_done});
    $self->_pump;
    return $action eq 'sent' ? 1 : 0;
}

sub stats {
    my ($self) = @_;
    croak 'runtime object is required' unless ref($self);
    return {
        %{ $self->{stats} },
        inflight => $self->{inflight_total},
        contexts => scalar(keys %{ $self->{contexts} }),
        queue    => $self->{queue}->stats,
    };
}

1;
