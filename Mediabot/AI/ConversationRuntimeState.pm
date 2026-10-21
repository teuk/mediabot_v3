package Mediabot::AI::ConversationRuntimeState;

use strict;
use warnings;
use Mediabot::IRC::CaseMapping qw(fold_irc);

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
        casemapping    => 'ascii', # Conservative until this connection advertises ISUPPORT.
    }, $class;
}

sub _channel_key {
    my ($self, $channel) = @_;
    croak 'channel must be a public IRC channel'
        unless defined($channel)
            && !ref($channel)
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return fold_irc("$channel", $self->{casemapping} // 'ascii');
}

sub _next_generation {
    my ($self) = @_;
    croak 'conversation runtime generation exhausted'
        if $self->{next_generation} >= $MAX_GENERATION;
    return ++$self->{next_generation};
}

sub _channel_state {
    my ($self, $key, $channel) = @_;
    return $self->{channels}{lc $key} ||= {
        name       => lc $channel,
        joined     => 0,
        generation => 0,
    };
}

# A changed identity rule invalidates old tickets while preserving actual
# membership. Never manufacture extra joined rooms when a mapping is narrowed.
sub _set_casemapping {
    my ($self, $mapping) = @_;
    return 0 if $self->{casemapping} eq $mapping;
    $self->{casemapping} = $mapping;
    my %channels;
    for my $state (sort { $a->{name} cmp $b->{name} } values %{ $self->{channels} }) {
        my $key = $self->_channel_key($state->{name});
        if (my $previous = $channels{$key}) {
            $previous->{name} = $state->{name}
                if $state->{joined} && !$previous->{joined};
            $previous->{joined} ||= $state->{joined};
            $previous->{generation} = $state->{generation}
                if $state->{generation} > $previous->{generation};
        } else {
            $channels{$key} = { %$state };
        }
    }
    for my $state (values %channels) {
        $state->{generation} = $self->_next_generation() if $state->{joined};
    }
    $self->{channels} = \%channels;
    return 1;
}

sub update_isupport {
    my ($self, @tokens) = @_;
    my $changed = 0;
    for my $token (@tokens) {
        next if !defined($token) || ref($token);
        if ($token =~ /\ACASEMAPPING=(ascii|rfc1459|strict-rfc1459)\z/i) {
            $changed = $self->_set_casemapping(lc $1) || $changed;
        } elsif ($token eq '-CASEMAPPING') {
            $changed = $self->_set_casemapping('ascii') || $changed;
        }
    }
    return $changed;
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

    $self->_set_casemapping('ascii');
    return $changed;
}

sub mark_joined {
    my ($self, $channel) = @_;
    croak 'runtime state object is required' unless ref($self);
    my $key = $self->_channel_key($channel);

    return undef unless $self->{runtime_active} && $self->{irc_connected};

    my $state = $self->_channel_state($key, $channel);
    return $state->{generation} if $state->{joined};

    $state->{name} = lc $channel;
    $state->{joined} = 1;
    $state->{generation} = $self->_next_generation();
    return $state->{generation};
}

sub mark_left {
    my ($self, $channel) = @_;
    croak 'runtime state object is required' unless ref($self);
    my $key = $self->_channel_key($channel);

    my $state = $self->_channel_state($key, $channel);
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
    my $key = $self->_channel_key($channel);

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
