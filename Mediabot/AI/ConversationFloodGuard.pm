package Mediabot::AI::ConversationFloodGuard;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '1.0';
our @EXPORT_OK = qw(flood_defaults flood_summary);

my %DEFAULT = (
    window_seconds      => 10,
    threshold_lines     => 20,
    suppression_seconds => 180,
    max_channels        => 256,
);

sub flood_defaults {
    return { %DEFAULT };
}

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _bounded_int {
    my ($value, $default, $min, $max) = @_;
    return $default unless _plain_scalar($value) && "$value" =~ /^\d+\z/;

    my $n = int($value);
    return $default if $n < $min || $n > $max;
    return $n;
}

sub _channel_key {
    my ($channel) = @_;
    croak 'channel must be a public IRC channel'
        unless _plain_scalar($channel)
            && "$channel" =~ /^#/;

    my $key = lc "$channel";
    croak 'channel contains unsafe control data'
        if $key =~ /[\x00-\x1f\x7f]/;
    croak 'channel is too long'
        if length($key) > 200;

    return $key;
}

sub _retry_after {
    my ($remaining) = @_;
    return 1 unless defined($remaining) && looks_like_number($remaining) && $remaining > 0;

    my $whole = int($remaining);
    $whole++ if $whole < $remaining;
    return $whole > 0 ? $whole : 1;
}

sub new {
    my ($class, %args) = @_;

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    return bless {
        clock => $clock || sub { clock_gettime(CLOCK_MONOTONIC) },
        window_seconds => _bounded_int(
            $args{window_seconds}, $DEFAULT{window_seconds}, 1, 300,
        ),
        threshold_lines => _bounded_int(
            $args{threshold_lines}, $DEFAULT{threshold_lines}, 3, 10_000,
        ),
        suppression_seconds => _bounded_int(
            $args{suppression_seconds}, $DEFAULT{suppression_seconds}, 10, 3600,
        ),
        max_channels => _bounded_int(
            $args{max_channels}, $DEFAULT{max_channels}, 1, 4096,
        ),
        channel_state => {},
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = $self->{clock}->();
    croak 'clock must return a non-negative numeric value'
        unless _plain_scalar($now) && looks_like_number($now) && $now >= 0;
    return 0 + $now;
}

sub _make_room {
    my ($self, $wanted_key) = @_;
    return if exists $self->{channel_state}{$wanted_key};

    my $max = $self->{max_channels};
    my $count = scalar keys %{ $self->{channel_state} };
    return if $count < $max;

    my ($oldest_key) = sort {
        ($self->{channel_state}{$a}{last_seen} // 0)
            <=> ($self->{channel_state}{$b}{last_seen} // 0)
            || $a cmp $b
    } keys %{ $self->{channel_state} };

    delete $self->{channel_state}{$oldest_key} if defined $oldest_key;
}

sub observe_public_line {
    my ($self, %args) = @_;
    croak 'flood guard object is required' unless ref($self);

    my $channel_key = _channel_key($args{channel});
    my $now = $self->_now();

    $self->_make_room($channel_key);
    my $state = $self->{channel_state}{$channel_key} ||= {
        events           => [],
        suppressed_until => 0,
        last_seen        => $now,
    };

    # The default clock is monotonic. An injected/broken clock moving backwards
    # is treated fail-closed for this observation instead of silently clearing
    # an active suppression window.
    if (defined($state->{last_seen}) && $now < $state->{last_seen}) {
        $state->{suppressed_until} = $state->{last_seen} + $self->{suppression_seconds};
        $state->{events} = [];
        return {
            action              => 'suppress',
            reason              => 'flood_suppression',
            retry_after_seconds => $self->{suppression_seconds},
        };
    }

    $state->{last_seen} = $now;

    if (($state->{suppressed_until} // 0) > $now) {
        return {
            action              => 'suppress',
            reason              => 'flood_suppression',
            retry_after_seconds => _retry_after($state->{suppressed_until} - $now),
        };
    }

    # A completed suppression window starts with a clean burst history. Traffic
    # observed while suppressed never extends the suppression period.
    if (($state->{suppressed_until} // 0) > 0) {
        $state->{suppressed_until} = 0;
        $state->{events} = [];
    }

    my $window = $self->{window_seconds};
    my @recent = grep { ($now - $_) < $window } @{ $state->{events} || [] };
    push @recent, $now;
    $state->{events} = \@recent;

    if (@recent >= $self->{threshold_lines}) {
        $state->{events} = [];
        $state->{suppressed_until} = $now + $self->{suppression_seconds};

        return {
            action              => 'suppress',
            reason              => 'flood_suppression',
            retry_after_seconds => $self->{suppression_seconds},
        };
    }

    return {
        action => 'allow',
        reason => 'below_threshold',
    };
}

sub current_decision {
    my ($self, %args) = @_;
    croak 'flood guard object is required' unless ref($self);

    my $channel_key = _channel_key($args{channel});
    my $now = $self->_now();
    my $state = $self->{channel_state}{$channel_key};

    return {
        action => 'allow',
        reason => 'below_threshold',
    } unless ref($state) eq 'HASH';

    # A clock rollback during a late safety check also fails closed, but this
    # query never mutates/extents the stored suppression state.
    if (defined($state->{last_seen}) && $now < $state->{last_seen}) {
        return {
            action              => 'suppress',
            reason              => 'flood_suppression',
            retry_after_seconds => $self->{suppression_seconds},
        };
    }

    if (($state->{suppressed_until} // 0) > $now) {
        return {
            action              => 'suppress',
            reason              => 'flood_suppression',
            retry_after_seconds => _retry_after($state->{suppressed_until} - $now),
        };
    }

    return {
        action => 'allow',
        reason => 'below_threshold',
    };
}

sub flood_summary {
    my ($decision) = @_;
    return undef unless ref($decision) eq 'HASH';

    my $action = $decision->{action};
    my $reason = $decision->{reason};
    return undef unless _plain_scalar($action) && _plain_scalar($reason);
    return undef unless $action eq 'allow' || $action eq 'suppress';
    return undef unless $reason eq 'below_threshold' || $reason eq 'flood_suppression';

    my %summary = (
        action => "$action",
        reason => "$reason",
    );

    $summary{retry_after_seconds} = int($decision->{retry_after_seconds})
        if _plain_scalar($decision->{retry_after_seconds})
            && "$decision->{retry_after_seconds}" =~ /^\d+\z/;

    return \%summary;
}

1;
