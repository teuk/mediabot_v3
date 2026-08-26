package Mediabot::AI::ConversationRuntimeState;

use strict;
use warnings;

use Carp qw(croak);

our $VERSION = '1.0';

my $MAX_GENERATION = 999_999_999_999_999;

sub new {
    my ($class) = @_;

    return bless {
        runtime_active => 1,
        irc_connected  => 0,
        next_generation => 0,
        channels       => {},
    }, $class;
}

sub _channel_key {
    my ($channel) = @_;
    croak 'channel must be a public IRC channel'
        unless defined($channel)
            && !ref($channel)
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return lc "$channel";
}

sub _next_generation {
    my ($self) = @_;
    croak 'conversation runtime generation exhausted'
        if $self->{next_generation} >= $MAX_GENERATION;
    return ++$self->{next_generation};
}

sub _channel_state {
    my ($self, $key) = @_;
    return $self->{channels}{lc $key} ||= {
        joined     => 0,
        generation => 0,
    };
}

sub mark_connected {
    my ($self) = @_;
    croak 'runtime state object is required' unless ref($self);

    return 0 unless $self->{runtime_active};
    return 0 if $self->{irc_connected};

    $self->{irc_connected} = 1;
    return 1;
}

sub mark_disconnected {
    my ($self) = @_;
    croak 'runtime state object is required' unless ref($self);

    my $changed = $self->{irc_connected} ? 1 : 0;
    $self->{irc_connected} = 0;

    for my $state (values %{ $self->{channels} }) {
        next unless $state->{joined};
        $state->{joined} = 0;
        $state->{generation} = $self->_next_generation();
        $changed = 1;
    }

    return $changed;
}

sub mark_joined {
    my ($self, $channel) = @_;
    croak 'runtime state object is required' unless ref($self);
    my $key = _channel_key($channel);

    return undef unless $self->{runtime_active} && $self->{irc_connected};

    my $state = $self->_channel_state($key);
    return $state->{generation} if $state->{joined};

    $state->{joined} = 1;
    $state->{generation} = $self->_next_generation();
    return $state->{generation};
}

sub mark_left {
    my ($self, $channel) = @_;
    croak 'runtime state object is required' unless ref($self);
    my $key = _channel_key($channel);

    my $state = $self->_channel_state($key);
    return $state->{generation} unless $state->{joined};

    $state->{joined} = 0;
    $state->{generation} = $self->_next_generation();
    return $state->{generation};
}

sub mark_shutdown {
    my ($self) = @_;
    croak 'runtime state object is required' unless ref($self);

    return 0 unless $self->{runtime_active};

    $self->{runtime_active} = 0;
    $self->mark_disconnected();
    return 1;
}

sub snapshot {
    my ($self, $channel) = @_;
    croak 'runtime state object is required' unless ref($self);
    my $key = _channel_key($channel);

    my $state = $self->{channels}{lc $key};
    return {
        runtime_active     => $self->{runtime_active} ? 1 : 0,
        irc_connected      => $self->{irc_connected} ? 1 : 0,
        channel_joined     => ($state && $state->{joined}) ? 1 : 0,
        current_generation => $state ? int($state->{generation} // 0) : 0,
    };
}

sub capture_generation {
    my ($self, $channel) = @_;
    my $state = $self->snapshot($channel);

    return undef unless $state->{runtime_active}
        && $state->{irc_connected}
        && $state->{channel_joined}
        && $state->{current_generation} > 0;

    return $state->{current_generation};
}

1;
