package Mediabot::Hailo::ReplyQueue;

use strict;
use warnings;
use utf8;

use Carp qw(croak);

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

sub new {
    my ($class, %args) = @_;
    return bless {
        max_total       => _bounded_int($args{max_total}, 32, 1, 1024),
        max_per_channel => _bounded_int($args{max_per_channel}, 3, 1, 64),
        ttl_seconds     => _bounded_int($args{ttl_seconds}, 15, 1, 300),
        typing_coeff    => defined($args{typing_coeff}) ? 0 + $args{typing_coeff} : 1,
        typing_offset   => defined($args{typing_offset}) ? 0 + $args{typing_offset} : 0,
        now_cb          => ref($args{now_cb}) eq 'CODE' ? $args{now_cb} : sub { time() },
        queue           => [],
        next_id         => 0,
        dropped_full    => 0,
        dropped_expired => 0,
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = eval { $self->{now_cb}->() };
    return time() unless _plain($now) && "$now" =~ /^-?(?:\d+(?:[.]\d*)?|[.]\d+)\z/;
    return 0 + $now;
}

sub _channel_key {
    my ($value) = @_;
    return undef unless _plain($value)
        && "$value" =~ /^[#&+!][^\s,\x00-\x1f\x7f]{1,79}\z/;
    my $key = lc "$value";
    $key =~ tr/[]\\^/{}|~/;
    return $key;
}

sub _prune {
    my ($self) = @_;
    my $cutoff = $self->_now - $self->{ttl_seconds};
    my (@keep, @expired);
    for my $entry (@{ $self->{queue} }) {
        if (!ref($entry) || !defined($entry->{queued_at}) || $entry->{queued_at} <= $cutoff) {
            push @expired, $entry;
            next;
        }
        push @keep, $entry;
    }

    # Publish the pruned queue before invoking callbacks. A callback may read
    # queue stats (metrics do this), which calls _prune() again; keeping an
    # expired entry visible until after the callback would recurse forever.
    $self->{queue} = \@keep;
    $self->{dropped_expired} += scalar @expired;
    for my $entry (@expired) {
        eval { $entry->{on_expire}->($entry) }
            if ref($entry) eq 'HASH' && ref($entry->{on_expire}) eq 'CODE';
    }
    return scalar @expired;
}

sub enqueue {
    my ($self, %args) = @_;
    croak 'queue object is required' unless ref($self);
    $self->_prune;

    my $key = _channel_key($args{channel});
    return { accepted => 0, reason => 'invalid_channel' } unless defined $key;
    return { accepted => 0, reason => 'invalid_callback' }
        unless ref($args{on_ready}) eq 'CODE';
    return { accepted => 0, reason => 'invalid_expiry_callback' }
        if defined($args{on_expire}) && ref($args{on_expire}) ne 'CODE';

    if (@{ $self->{queue} } >= $self->{max_total}) {
        $self->{dropped_full}++;
        return { accepted => 0, reason => 'queue_full' };
    }
    my $per_channel = scalar grep { $_->{channel_key} eq $key } @{ $self->{queue} };
    if ($per_channel >= $self->{max_per_channel}) {
        $self->{dropped_full}++;
        return { accepted => 0, reason => 'channel_queue_full' };
    }

    my $id = ++$self->{next_id};
    push @{ $self->{queue} }, {
        id          => $id,
        channel     => "$args{channel}",
        channel_key => $key,
        queued_at   => $self->_now,
        on_ready    => $args{on_ready},
        on_expire   => $args{on_expire},
        payload     => $args{payload},
    };
    return { accepted => 1, reason => 'queued', id => $id };
}

sub take_next {
    my ($self, $predicate) = @_;
    croak 'queue object is required' unless ref($self);
    croak 'predicate must be a code reference'
        if defined($predicate) && ref($predicate) ne 'CODE';
    $self->_prune;
    return shift @{ $self->{queue} } unless $predicate;

    for my $index (0 .. $#{ $self->{queue} }) {
        my $entry = $self->{queue}[$index];
        next unless eval { $predicate->($entry) };
        return splice(@{ $self->{queue} }, $index, 1);
    }
    return undef;
}

sub ttl_seconds {
    my ($self) = @_;
    croak 'queue object is required' unless ref($self);
    return $self->{ttl_seconds};
}

sub dispatch_next {
    my ($self) = @_;
    my $entry = $self->take_next or return 0;
    my $ok = eval { $entry->{on_ready}->($entry->{payload}, $entry); 1 };
    return $ok ? 1 : 0;
}

sub typing_delay_seconds {
    my ($self, $line) = @_;
    return 0 unless _plain($line) && length("$line");
    my $delay = $self->{typing_coeff} * sqrt(length("$line")) + $self->{typing_offset};
    $delay = 0 if $delay < 0;
    $delay = 15 if $delay > 15;
    return int($delay + 0.5);
}

sub stats {
    my ($self) = @_;
    croak 'queue object is required' unless ref($self);
    $self->_prune;
    my %channels;
    $channels{$_->{channel_key}}++ for @{ $self->{queue} };
    return {
        queued          => scalar(@{ $self->{queue} }),
        channels        => scalar(keys %channels),
        max_total       => $self->{max_total},
        max_per_channel => $self->{max_per_channel},
        dropped_full    => $self->{dropped_full},
        dropped_expired => $self->{dropped_expired},
    };
}

1;
