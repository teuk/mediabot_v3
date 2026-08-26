package Mediabot::AI::ConversationSender;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';

use Mediabot::AI::ConversationEmission qw(evaluate_emission);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    sender_defaults
    format_sender_log
);

my %DEFAULT = (
    min_interval_seconds => 120,
);

my %ALLOWED_NEW = map { $_ => 1 } qw(
    send_cb
    clock
);

my %ALLOWED_ATTEMPT = map { $_ => 1 } qw(
    channel
    text
    request_generation
    state_cb
);

sub sender_defaults {
    return { %DEFAULT };
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_channel {
    my ($channel) = @_;
    return undef unless _plain_scalar($channel);
    my $text = "$channel";
    return undef unless $text =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return $text;
}

sub _safe_uint {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && "$value" =~ /^\d+\z/;
    return int($value);
}

sub _result {
    my ($action, $reason, %extra) = @_;
    my %out = (
        action => $action,
        reason => $reason,
    );

    for my $key (qw(reply_chars reply_bytes request_generation retry_after)) {
        my $value = _safe_uint($extra{$key});
        $out{$key} = $value if defined $value;
    }

    return \%out;
}

sub new {
    my ($class, %args) = @_;

    for my $key (keys %args) {
        croak "unknown Wit sender field: $key" unless $ALLOWED_NEW{$key};
    }

    my $send_cb = $args{send_cb};
    croak 'send_cb must be a code reference'
        unless ref($send_cb) eq 'CODE';

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    return bless {
        send_cb      => $send_cb,
        clock        => $clock || sub { time() },
        armed        => 0,
        last_sent_at => {},
    }, $class;
}

sub arm {
    my ($self) = @_;
    croak 'sender object is required' unless ref($self);
    $self->{armed} = 1;
    return 1;
}

sub disarm {
    my ($self) = @_;
    croak 'sender object is required' unless ref($self);
    $self->{armed} = 0;
    return 1;
}

sub is_armed {
    my ($self) = @_;
    croak 'sender object is required' unless ref($self);
    return $self->{armed} ? 1 : 0;
}

sub _clock_now {
    my ($self) = @_;
    my ($ok, $value);
    $ok = eval {
        $value = $self->{clock}->();
        1;
    };
    return undef unless $ok;
    return undef unless _plain_scalar($value) && "$value" =~ /^\d+(?:\.\d+)?\z/;
    return 0 + $value;
}

sub _rate_limit_result {
    my ($self, $channel_key, $now) = @_;

    return undef unless exists $self->{last_sent_at}{$channel_key};

    my $elapsed = $now - $self->{last_sent_at}{$channel_key};
    $elapsed = 0 if $elapsed < 0;
    return undef if $elapsed >= $DEFAULT{min_interval_seconds};

    my $retry_after = int($DEFAULT{min_interval_seconds} - $elapsed);
    $retry_after++ if $elapsed + $retry_after < $DEFAULT{min_interval_seconds};
    $retry_after = 1 if $retry_after < 1;

    return _result('no_send', 'rate_limited', retry_after => $retry_after);
}

sub attempt_send {
    my ($self, %args) = @_;
    croak 'sender object is required' unless ref($self);

    for my $key (keys %args) {
        croak "unknown Wit send attempt field: $key" unless $ALLOWED_ATTEMPT{$key};
    }

    # The sender starts disarmed and the kill switch wins before any state
    # lookup or callback. This is a separate safety boundary from +Wit.
    return _result('no_send', 'kill_switch') unless $self->{armed};

    my $channel = _safe_channel($args{channel});
    return _result('no_send', 'invalid_channel') unless defined $channel;

    my $state_cb = $args{state_cb};
    croak 'state_cb must be a code reference'
        unless ref($state_cb) eq 'CODE';

    my $now = $self->_clock_now();
    return _result('no_send', 'clock_error') unless defined $now;

    my $channel_key = lc $channel;
    my $rate_limited = $self->_rate_limit_result($channel_key, $now);
    return $rate_limited if $rate_limited;

    # Re-read every mutable authorization input synchronously here, directly
    # before the final emission contract and the send callback.
    my ($state_ok, $state);
    $state_ok = eval {
        $state = $state_cb->();
        1;
    };
    return _result('no_send', 'state_error')
        unless $state_ok && ref($state) eq 'HASH';

    my ($decision_ok, $decision);
    $decision_ok = eval {
        $decision = evaluate_emission(
            enabled            => $state->{enabled},
            runtime_active     => $state->{runtime_active},
            irc_connected      => $state->{irc_connected},
            channel_joined     => $state->{channel_joined},
            request_generation => $args{request_generation},
            current_generation => $state->{current_generation},
            channel            => $channel,
            text               => $args{text},
        );
        1;
    };
    return _result('no_send', 'authorization_error')
        unless $decision_ok && ref($decision) eq 'HASH';

    if (($decision->{action} // '') ne 'emit') {
        return _result(
            'no_send',
            $decision->{reason} // 'authorization_error',
            reply_chars        => $decision->{reply_chars},
            reply_bytes        => $decision->{reply_bytes},
            request_generation => $decision->{request_generation},
        );
    }

    # A state callback is allowed to trigger an administrative disarm. Check
    # the independent kill switch again after final authorization and before
    # delivery so that disarm always wins in this synchronous critical section.
    return _result('no_send', 'kill_switch') unless $self->{armed};

    my $now_before_send = $self->_clock_now();
    return _result('no_send', 'clock_error') unless defined $now_before_send;

    $rate_limited = $self->_rate_limit_result($channel_key, $now_before_send);
    return $rate_limited if $rate_limited;

    my ($send_ok, $accepted);
    $send_ok = eval {
        $accepted = $self->{send_cb}->($channel, $decision->{text});
        1;
    };
    return _result('no_send', 'send_error') unless $send_ok;
    return _result('no_send', 'send_failed') unless $accepted;

    my $sent_at = $self->_clock_now();
    $sent_at = $now_before_send unless defined $sent_at;
    $self->{last_sent_at}{$channel_key} = $sent_at;

    return _result(
        'sent',
        'delivered',
        reply_chars        => $decision->{reply_chars},
        reply_bytes        => $decision->{reply_bytes},
        request_generation => $decision->{request_generation},
    );
}

sub _safe_log_scalar {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);
    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return undef unless length($text) && length($text) <= $max;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    return $text;
}

sub format_sender_log {
    my ($channel, $summary) = @_;

    my $safe_channel = _safe_channel($channel);
    return undef unless defined $safe_channel;
    return undef unless ref($summary) eq 'HASH';

    my $action = _safe_log_scalar($summary->{action}, 32);
    my $reason = _safe_log_scalar($summary->{reason}, 64);
    return undef unless defined($action) && defined($reason);
    return undef unless $action eq 'sent' || $action eq 'no_send';

    my @parts = (
        '[WIT_SEND]',
        'channel=' . $safe_channel,
        'action=' . $action,
        'reason=' . $reason,
    );

    for my $key (qw(reply_chars reply_bytes request_generation retry_after)) {
        my $value = _safe_uint($summary->{$key});
        push @parts, "$key=$value" if defined $value;
    }

    return join ' ', @parts;
}

1;
