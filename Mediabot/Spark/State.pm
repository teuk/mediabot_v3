package Mediabot::Spark::State;

use strict;
use warnings;

use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '1.0';
our @EXPORT_OK = qw(spark_state_defaults spark_state_summary);

my %DEFAULT = (
    recent_window_seconds       => 7_200,
    event_duration_seconds      => 60,
    engaged_cooldown_seconds    => 3_600,
    delivered_cooldown_seconds  => 3_600,
    superseded_cooldown_seconds => 1_800,
    error_cooldown_seconds      => 900,
    max_channels                => 256,
    max_humans_per_channel      => 128,
);

my @MISS_COOLDOWN = (2_700, 5_400, 14_400, 28_800);
my $MAX_GENERATION = 999_999_999_999_999;

sub spark_state_defaults {
    return {
        %DEFAULT,
        miss_cooldown_seconds => [ @MISS_COOLDOWN ],
    };
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
            && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/;
    return lc "$channel";
}

sub _nick_key {
    my ($nick) = @_;
    croak 'nick must be a non-empty IRC nickname'
        unless _plain_scalar($nick)
            && length("$nick") >= 1
            && length("$nick") <= 100
            && "$nick" !~ /[\s,:\x00-\x1f\x7f]/;
    return lc "$nick";
}

sub _event_kind {
    my ($kind) = @_;
    croak 'event kind must be a short machine token'
        unless _plain_scalar($kind)
            && "$kind" =~ /^[a-z][a-z0-9_-]{0,31}\z/;
    return "$kind";
}

sub _positive_generation {
    my ($value) = @_;
    return undef unless _plain_scalar($value) && "$value" =~ /^[1-9]\d{0,14}\z/;
    return int($value);
}

sub new {
    my ($class, %args) = @_;

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    my $miss = $args{miss_cooldown_seconds};
    if (defined $miss) {
        croak 'miss_cooldown_seconds must be an array reference'
            unless ref($miss) eq 'ARRAY' && @$miss;
        my @clean;
        for my $value (@$miss) {
            croak 'miss cooldown must be between 60 and 86400 seconds'
                unless _plain_scalar($value)
                    && "$value" =~ /^\d+\z/
                    && $value >= 60
                    && $value <= 86_400;
            push @clean, int($value);
        }
        $miss = \@clean;
    }
    else {
        $miss = [ @MISS_COOLDOWN ];
    }

    return bless {
        clock => $clock || sub { clock_gettime(CLOCK_MONOTONIC) },
        recent_window_seconds => _bounded_int(
            $args{recent_window_seconds}, $DEFAULT{recent_window_seconds}, 300, 86_400,
        ),
        event_duration_seconds => _bounded_int(
            $args{event_duration_seconds}, $DEFAULT{event_duration_seconds}, 30, 90,
        ),
        engaged_cooldown_seconds => _bounded_int(
            $args{engaged_cooldown_seconds}, $DEFAULT{engaged_cooldown_seconds}, 300, 86_400,
        ),
        delivered_cooldown_seconds => _bounded_int(
            $args{delivered_cooldown_seconds}, $DEFAULT{delivered_cooldown_seconds}, 300, 86_400,
        ),
        superseded_cooldown_seconds => _bounded_int(
            $args{superseded_cooldown_seconds}, $DEFAULT{superseded_cooldown_seconds}, 60, 86_400,
        ),
        error_cooldown_seconds => _bounded_int(
            $args{error_cooldown_seconds}, $DEFAULT{error_cooldown_seconds}, 60, 86_400,
        ),
        miss_cooldown_seconds => $miss,
        max_channels => _bounded_int(
            $args{max_channels}, $DEFAULT{max_channels}, 1, 4096,
        ),
        max_humans_per_channel => _bounded_int(
            $args{max_humans_per_channel}, $DEFAULT{max_humans_per_channel}, 2, 4096,
        ),
        next_generation => 0,
        channel_state   => {},
    }, $class;
}

sub _now {
    my ($self) = @_;
    my $now = $self->{clock}->();
    croak 'clock must return a non-negative numeric value'
        unless _plain_scalar($now) && looks_like_number($now) && $now >= 0;
    return 0 + $now;
}

sub _next_generation {
    my ($self) = @_;
    croak 'Spark event generation exhausted'
        if $self->{next_generation} >= $MAX_GENERATION;
    return ++$self->{next_generation};
}

sub _make_room {
    my ($self, $wanted_key) = @_;
    return if exists $self->{channel_state}{$wanted_key};

    my $count = scalar keys %{ $self->{channel_state} };
    return if $count < $self->{max_channels};

    my @evictable = grep {
        !$self->{channel_state}{$_}{event_active}
    } keys %{ $self->{channel_state} };

    croak 'Spark channel-state capacity exhausted by active events'
        unless @evictable;

    my ($oldest_key) = sort {
        ($self->{channel_state}{$a}{last_seen} // 0)
            <=> ($self->{channel_state}{$b}{last_seen} // 0)
            || $a cmp $b
    } @evictable;

    delete $self->{channel_state}{$oldest_key};
}

sub _channel_state {
    my ($self, $key, $now) = @_;

    $self->_make_room($key);
    return $self->{channel_state}{$key} ||= {
        humans          => {},
        last_human_at   => undef,
        event_active    => 0,
        event_kind      => undef,
        event_started_at => 0,
        event_deadline_at => 0,
        generation      => 0,
        miss_streak     => 0,
        cooldown_until  => 0,
        last_seen       => $now,
    };
}

sub _touch {
    my ($self, $state, $now) = @_;
    croak 'Spark clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
}

sub _recent_human_count {
    my ($self, $state, $now) = @_;
    my $window = $self->{recent_window_seconds};
    my $count = 0;

    for my $seen (values %{ $state->{humans} || {} }) {
        next unless defined($seen) && looks_like_number($seen);
        $count++ if $now >= $seen && ($now - $seen) <= $window;
    }

    return $count;
}

sub _prune_humans {
    my ($self, $state, $now) = @_;
    my $window = $self->{recent_window_seconds};

    for my $nick (keys %{ $state->{humans} || {} }) {
        my $seen = $state->{humans}{$nick};
        delete $state->{humans}{$nick}
            unless defined($seen)
                && looks_like_number($seen)
                && $now >= $seen
                && ($now - $seen) <= $window;
    }
}

sub observe_human {
    my ($self, %args) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $nick = _nick_key($args{nick});
    my $now = $self->_now();
    my $state = $self->_channel_state($channel, $now);
    $self->_touch($state, $now);
    $self->_prune_humans($state, $now);

    $state->{humans}{$nick} = $now;
    $state->{last_human_at} = $now;

    my $max = $self->{max_humans_per_channel};
    while (scalar(keys %{ $state->{humans} }) > $max) {
        my ($oldest) = sort {
            $state->{humans}{$a} <=> $state->{humans}{$b}
                || $a cmp $b
        } keys %{ $state->{humans} };
        delete $state->{humans}{$oldest};
    }

    return {
        recent_humans => _recent_human_count($self, $state, $now),
        last_human_at => 0 + $state->{last_human_at},
    };
}

sub snapshot {
    my ($self, $channel) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $now = $self->_now();
    my $state = $self->{channel_state}{$key};

    return {
        event_active              => 0,
        event_kind                => undef,
        current_generation        => 0,
        event_started_at          => 0,
        event_deadline_at         => 0,
        event_remaining_seconds   => 0,
        last_human_at             => undef,
        recent_humans             => 0,
        miss_streak               => 0,
        cooldown_until            => 0,
        cooldown_remaining_seconds => 0,
    } unless ref($state) eq 'HASH';

    $self->_touch($state, $now);

    my $remaining = 0;
    if ($state->{event_active} && ($state->{event_deadline_at} // 0) > $now) {
        $remaining = int($state->{event_deadline_at} - $now);
        $remaining = 1 if $remaining < 1;
    }

    my $cooldown_remaining = 0;
    if (($state->{cooldown_until} // 0) > $now) {
        $cooldown_remaining = int($state->{cooldown_until} - $now);
        $cooldown_remaining = 1 if $cooldown_remaining < 1;
    }

    return {
        event_active              => $state->{event_active} ? 1 : 0,
        event_kind                => $state->{event_active} ? $state->{event_kind} : undef,
        current_generation        => int($state->{generation} // 0),
        event_started_at          => $state->{event_active} ? 0 + ($state->{event_started_at} // 0) : 0,
        event_deadline_at         => $state->{event_active} ? 0 + ($state->{event_deadline_at} // 0) : 0,
        event_remaining_seconds   => $remaining,
        last_human_at             => defined($state->{last_human_at}) ? 0 + $state->{last_human_at} : undef,
        recent_humans             => _recent_human_count($self, $state, $now),
        miss_streak               => int($state->{miss_streak} // 0),
        cooldown_until            => 0 + ($state->{cooldown_until} // 0),
        cooldown_remaining_seconds => $cooldown_remaining,
    };
}

sub begin_event {
    my ($self, %args) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $kind = _event_kind($args{kind});
    my $now = $self->_now();
    my $state = $self->_channel_state($channel, $now);
    $self->_touch($state, $now);

    return undef if $state->{event_active};
    return undef if ($state->{cooldown_until} // 0) > $now;

    my $duration = _bounded_int(
        $args{duration_seconds},
        $self->{event_duration_seconds},
        30,
        90,
    );

    my $generation = $self->_next_generation();
    $state->{event_active} = 1;
    $state->{event_kind} = $kind;
    $state->{event_started_at} = $now;
    $state->{event_deadline_at} = $now + $duration;
    $state->{generation} = $generation;

    return $generation;
}

sub capture_event_generation {
    my ($self, $channel) = @_;
    my $snap = $self->snapshot($channel);
    return undef unless $snap->{event_active} && $snap->{current_generation} > 0;
    return $snap->{current_generation};
}

sub generation_is_current {
    my ($self, $channel, $generation) = @_;
    my $wanted = _positive_generation($generation);
    return 0 unless defined $wanted;

    my $snap = $self->snapshot($channel);
    return 0 unless $snap->{event_active};
    return $snap->{current_generation} == $wanted ? 1 : 0;
}

sub _cooldown_for_miss_streak {
    my ($self, $streak) = @_;
    my $list = $self->{miss_cooldown_seconds};
    my $index = $streak - 1;
    $index = 0 if $index < 0;
    $index = $#$list if $index > $#$list;
    return $list->[$index];
}

sub _finish_at {
    my ($self, $state, $outcome, $now, $cooldown_override) = @_;
    return undef unless $state->{event_active};

    my $old_generation = int($state->{generation} // 0);
    my $new_generation = $self->_next_generation();

    $state->{event_active} = 0;
    $state->{event_kind} = undef;
    $state->{event_started_at} = 0;
    $state->{event_deadline_at} = 0;
    $state->{generation} = $new_generation;

    my $cooldown;
    if ($outcome eq 'engaged') {
        $state->{miss_streak} = 0;
        $cooldown = $self->{engaged_cooldown_seconds};
    }
    elsif ($outcome eq 'delivered') {
        # Ambient content has no qualifying response contract. Delivery is
        # neither participation nor a miss, so it must not rewrite the
        # interactive miss streak in either direction.
        $cooldown = $self->{delivered_cooldown_seconds};
    }
    elsif ($outcome eq 'miss') {
        $state->{miss_streak} = int($state->{miss_streak} // 0) + 1;
        $cooldown = $self->_cooldown_for_miss_streak($state->{miss_streak});
    }
    elsif ($outcome eq 'superseded') {
        $state->{miss_streak} = 0;
        $cooldown = $self->{superseded_cooldown_seconds};
    }
    elsif ($outcome eq 'error') {
        $cooldown = $self->{error_cooldown_seconds};
    }
    else {
        croak 'unknown Spark event outcome';
    }

    # Ambient action families may own a reviewed pacing interval distinct from
    # conversational events. Only finish_event() can supply this bounded
    # override, and only for the non-participatory delivered outcome.
    $cooldown = $cooldown_override if defined $cooldown_override;

    $state->{cooldown_until} = $now + $cooldown;

    return {
        outcome          => $outcome,
        old_generation   => $old_generation,
        new_generation   => $new_generation,
        miss_streak      => int($state->{miss_streak} // 0),
        cooldown_seconds => int($cooldown),
        cooldown_until   => 0 + $state->{cooldown_until},
    };
}

sub finish_event {
    my ($self, %args) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $outcome = $args{outcome};
    croak 'unknown Spark event outcome'
        unless _plain_scalar($outcome)
            && ($outcome eq 'engaged'
                || $outcome eq 'delivered'
                || $outcome eq 'miss'
                || $outcome eq 'superseded'
                || $outcome eq 'error');

    my $cooldown_override;
    if (exists $args{cooldown_seconds}) {
        croak 'cooldown override is allowed only for delivered events'
            unless $outcome eq 'delivered';
        croak 'delivered cooldown must be between 300 and 86400 seconds'
            unless _plain_scalar($args{cooldown_seconds})
                && "$args{cooldown_seconds}" =~ /^\d+\z/
                && $args{cooldown_seconds} >= 300
                && $args{cooldown_seconds} <= 86_400;
        $cooldown_override = int($args{cooldown_seconds});
    }

    my $now = $self->_now();
    my $state = $self->{channel_state}{$channel};
    return undef unless ref($state) eq 'HASH';
    $self->_touch($state, $now);

    return $self->_finish_at(
        $state, "$outcome", $now, $cooldown_override,
    );
}

sub expire_due_event {
    my ($self, $channel) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $now = $self->_now();
    my $state = $self->{channel_state}{$key};
    return undef unless ref($state) eq 'HASH';
    $self->_touch($state, $now);

    return undef unless $state->{event_active};
    return undef if ($state->{event_deadline_at} // 0) > $now;

    return $self->_finish_at($state, 'miss', $now);
}

sub invalidate_event {
    my ($self, $channel) = @_;
    croak 'Spark state object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $now = $self->_now();
    my $state = $self->{channel_state}{$key};
    return undef unless ref($state) eq 'HASH';
    $self->_touch($state, $now);
    return $state->{generation} unless $state->{event_active};

    $state->{event_active} = 0;
    $state->{event_kind} = undef;
    $state->{event_started_at} = 0;
    $state->{event_deadline_at} = 0;
    $state->{generation} = $self->_next_generation();

    return $state->{generation};
}

sub forget_channel {
    my ($self, $channel) = @_;
    croak 'Spark state object is required' unless ref($self);
    my $key = _channel_key($channel);
    return delete($self->{channel_state}{$key}) ? 1 : 0;
}

sub clear_all {
    my ($self) = @_;
    croak 'Spark state object is required' unless ref($self);
    my $count = scalar keys %{ $self->{channel_state} };
    $self->{channel_state} = {};
    return $count;
}

sub spark_state_summary {
    my ($snapshot) = @_;
    return undef unless ref($snapshot) eq 'HASH';

    my %out;
    for my $key (qw(
        event_active
        current_generation
        event_started_at
        event_deadline_at
        event_remaining_seconds
        recent_humans
        miss_streak
        cooldown_until
        cooldown_remaining_seconds
    )) {
        next unless _plain_scalar($snapshot->{$key});
        next unless "$snapshot->{$key}" =~ /^\d+(?:\.\d+)?\z/;
        $out{$key} = 0 + $snapshot->{$key};
    }

    if (_plain_scalar($snapshot->{event_kind})
            && "$snapshot->{event_kind}" =~ /^[a-z][a-z0-9_-]{0,31}\z/) {
        $out{event_kind} = "$snapshot->{event_kind}";
    }

    $out{last_human_at} = 0 + $snapshot->{last_human_at}
        if _plain_scalar($snapshot->{last_human_at})
            && looks_like_number($snapshot->{last_human_at})
            && $snapshot->{last_human_at} >= 0;

    return \%out;
}

1;
