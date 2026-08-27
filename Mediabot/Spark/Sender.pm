package Mediabot::Spark::Sender;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode_utf8);
use Mediabot::Spark::Event qw(spark_event_profile);

our $VERSION = '1.0';

my %DEFAULT = (
    min_interval_seconds => 120,
    max_chars            => 300,
    max_bytes            => 350,
);

sub sender_defaults { return { %DEFAULT }; }

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _safe_channel {
    my ($channel) = @_;
    return undef unless _plain_scalar($channel);
    return "$channel" if "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return undef;
}

sub _safe_generation {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && "$value" =~ /^[1-9]\d{0,14}\z/;
    return int($value);
}

sub _safe_piece {
    my ($value, $max) = @_;
    return undef unless _plain_scalar($value);
    my $text = "$value";
    return undef if $text =~ /[\r\n\x00]/;
    $text =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/[ \t]+/ /g;
    return undef unless length($text) && length($text) <= $max;
    return $text;
}

sub _result {
    my ($action, $reason, %extra) = @_;
    my %out = ( action => $action, reason => $reason );
    for my $key (qw(generation reply_chars reply_bytes retry_after)) {
        next unless _plain_scalar($extra{$key}) && "$extra{$key}" =~ /^\d+\z/;
        $out{$key} = int($extra{$key});
    }
    $out{kind} = $extra{kind}
        if _plain_scalar($extra{kind}) && "$extra{kind}" =~ /^(?:fork|portal|callback)\z/;
    return \%out;
}

sub render_generation {
    my ($generated) = @_;
    return undef unless ref($generated) eq 'HASH';
    return undef unless ($generated->{action} // '') eq 'ready';

    my $profile = eval { spark_event_profile($generated->{kind}) };
    return undef unless $profile;
    my $kind = $profile->{kind};
    my $content = $generated->{content};
    return undef unless ref($content) eq 'HASH';

    my $text;
    if ($kind eq 'fork') {
        my $q = _safe_piece($content->{question}, 220);
        my $a = _safe_piece($content->{a}, 140);
        my $b = _safe_piece($content->{b}, 140);
        return undef unless defined($q) && defined($a) && defined($b);
        $text = "⚡ $q — A) $a · B) $b";
    }
    else {
        my $line = _safe_piece($content->{line}, 360);
        return undef unless defined $line;
        $text = "⚡ $line";
    }

    return undef if length($text) > $DEFAULT{max_chars};
    return undef if length(encode_utf8($text)) > $DEFAULT{max_bytes};
    return $text;
}

sub new {
    my ($class, %args) = @_;
    my $send_cb = $args{send_cb};
    croak 'send_cb must be a code reference' unless ref($send_cb) eq 'CODE';
    my $clock = $args{clock};
    croak 'clock must be a code reference' if defined($clock) && ref($clock) ne 'CODE';

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

sub _now {
    my ($self) = @_;
    my ($ok, $now);
    $ok = eval { $now = $self->{clock}->(); 1 };
    return undef unless $ok && _plain_scalar($now) && "$now" =~ /^\d+(?:\.\d+)?\z/;
    return 0 + $now;
}

sub _rate_limit {
    my ($self, $key, $now) = @_;
    return undef unless exists $self->{last_sent_at}{$key};
    my $elapsed = $now - $self->{last_sent_at}{$key};
    $elapsed = 0 if $elapsed < 0;
    return undef if $elapsed >= $DEFAULT{min_interval_seconds};
    my $retry = int($DEFAULT{min_interval_seconds} - $elapsed);
    $retry++ if $elapsed + $retry < $DEFAULT{min_interval_seconds};
    $retry = 1 if $retry < 1;
    return $retry;
}

sub attempt_send {
    my ($self, %args) = @_;
    croak 'sender object is required' unless ref($self);

    return _result('no_send', 'kill_switch') unless $self->{armed};

    my $channel = _safe_channel($args{channel});
    return _result('no_send', 'invalid_channel') unless defined $channel;

    my $generation = _safe_generation($args{generation});
    return _result('no_send', 'invalid_generation') unless defined $generation;

    my $kind = eval { spark_event_profile($args{kind})->{kind} };
    return _result('no_send', 'invalid_kind') unless defined $kind;

    my $text = render_generation($args{generated});
    return _result('no_send', 'invalid_content', generation => $generation, kind => $kind)
        unless defined $text;

    my $state_cb = $args{state_cb};
    croak 'state_cb must be a code reference' unless ref($state_cb) eq 'CODE';

    my $now = $self->_now();
    return _result('no_send', 'clock_error', generation => $generation, kind => $kind)
        unless defined $now;

    my $key = lc $channel;
    my $retry = $self->_rate_limit($key, $now);
    return _result('no_send', 'rate_limited', generation => $generation, kind => $kind, retry_after => $retry)
        if defined $retry;

    my ($ok, $state);
    $ok = eval { $state = $state_cb->(); 1 };
    return _result('no_send', 'state_error', generation => $generation, kind => $kind)
        unless $ok && ref($state) eq 'HASH';

    for my $gate (
        [enabled        => 'disabled'],
        [runtime_active => 'runtime_inactive'],
        [irc_connected  => 'irc_disconnected'],
        [channel_joined => 'not_joined'],
    ) {
        return _result('no_send', $gate->[1], generation => $generation, kind => $kind)
            unless $state->{ $gate->[0] };
    }
    return _result('no_send', 'game_active', generation => $generation, kind => $kind)
        if $state->{game_active};
    return _result('no_send', 'wit_pending', generation => $generation, kind => $kind)
        if $state->{wit_pending};

    my $current = _safe_generation($state->{current_generation});
    return _result('no_send', 'stale_generation', generation => $generation, kind => $kind)
        unless defined($current) && $current == $generation;

    # Administrative disarm always wins even if it happens during state_cb.
    return _result('no_send', 'kill_switch', generation => $generation, kind => $kind)
        unless $self->{armed};

    my $before_send = $self->_now();
    return _result('no_send', 'clock_error', generation => $generation, kind => $kind)
        unless defined $before_send;
    $retry = $self->_rate_limit($key, $before_send);
    return _result('no_send', 'rate_limited', generation => $generation, kind => $kind, retry_after => $retry)
        if defined $retry;

    my ($send_ok, $accepted);
    $send_ok = eval { $accepted = $self->{send_cb}->($channel, $text); 1 };
    return _result('no_send', 'send_error', generation => $generation, kind => $kind)
        unless $send_ok;
    return _result('no_send', 'send_failed', generation => $generation, kind => $kind)
        unless $accepted;

    my $sent_at = $self->_now();
    $sent_at = $before_send unless defined $sent_at;
    $self->{last_sent_at}{$key} = $sent_at;

    return _result(
        'sent', 'delivered',
        generation  => $generation,
        kind        => $kind,
        reply_chars => length($text),
        reply_bytes => length(encode_utf8($text)),
    );
}

sub format_sender_log {
    my ($channel, $summary) = @_;
    my $safe_channel = _safe_channel($channel);
    return undef unless defined($safe_channel) && ref($summary) eq 'HASH';
    return undef unless _plain_scalar($summary->{action})
        && "$summary->{action}" =~ /^(?:sent|no_send)\z/;
    return undef unless _plain_scalar($summary->{reason})
        && "$summary->{reason}" =~ /^[a-z_]{1,64}\z/;

    my @parts = (
        '[SPARK_SEND]',
        "channel=$safe_channel",
        'action=' . $summary->{action},
        'reason=' . $summary->{reason},
    );
    push @parts, 'kind=' . $summary->{kind}
        if _plain_scalar($summary->{kind}) && "$summary->{kind}" =~ /^(?:fork|portal|callback)\z/;
    for my $key (qw(generation reply_chars reply_bytes retry_after)) {
        push @parts, "$key=" . int($summary->{$key})
            if _plain_scalar($summary->{$key}) && "$summary->{$key}" =~ /^\d+\z/;
    }
    return join ' ', @parts;
}

1;
