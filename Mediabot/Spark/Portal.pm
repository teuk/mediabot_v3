package Mediabot::Spark::Portal;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '1.0';

my %DEFAULT = (
    max_channels            => 256,
    target_contributions    => 3,
    minimum_contributions   => 2,
    max_contribution_chars  => 120,
    closing_timeout_seconds => 30,
);

sub portal_defaults { return { %DEFAULT }; }

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
    return undef unless _plain_scalar($nick)
        && length("$nick") >= 1
        && length("$nick") <= 100
        && "$nick" !~ /[\s,:\x00-\x1f\x7f]/;
    return lc "$nick";
}

sub _generation {
    my ($value) = @_;
    return undef unless _plain_scalar($value)
        && "$value" =~ /^[1-9]\d{0,14}\z/;
    return int($value);
}

sub _clean_line {
    my ($value, $max_chars) = @_;
    return undef unless _plain_scalar($value);

    my $line = "$value";
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $line =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    return undef if $line =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;

    $line =~ s/[\r\n\t]+/ /g;
    $line =~ s/\s+/ /g;
    $line =~ s/^\s+|\s+$//g;
    return undef unless length $line;

    $line = substr($line, 0, $max_chars) if length($line) > $max_chars;
    $line =~ s/\s+$//g;
    return length($line) ? $line : undef;
}

sub _safe_reason {
    my ($value) = @_;
    return undef unless _plain_scalar($value)
        && "$value" =~ /^[a-z_]{1,64}\z/;
    return "$value";
}

sub new {
    my ($class, %args) = @_;

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    my $target = _bounded_int(
        $args{target_contributions}, $DEFAULT{target_contributions}, 2, 6,
    );
    my $minimum = _bounded_int(
        $args{minimum_contributions}, $DEFAULT{minimum_contributions}, 1, 6,
    );
    croak 'minimum_contributions cannot exceed target_contributions'
        if $minimum > $target;

    return bless {
        clock => $clock || sub { clock_gettime(CLOCK_MONOTONIC) },
        max_channels => _bounded_int(
            $args{max_channels}, $DEFAULT{max_channels}, 1, 4096,
        ),
        target_contributions => $target,
        minimum_contributions => $minimum,
        max_contribution_chars => _bounded_int(
            $args{max_contribution_chars},
            $DEFAULT{max_contribution_chars},
            40,
            300,
        ),
        closing_timeout_seconds => _bounded_int(
            $args{closing_timeout_seconds},
            $DEFAULT{closing_timeout_seconds},
            5,
            120,
        ),
        channels => {},
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
    my ($self, $wanted) = @_;
    return if exists $self->{channels}{lc($wanted)};
    return if scalar(keys %{ $self->{channels} }) < $self->{max_channels};
    croak 'Portal collector capacity exhausted by active events';
}

sub begin {
    my ($self, %args) = @_;
    croak 'Portal collector object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $generation = _generation($args{generation});
    return { action => 'skip', reason => 'invalid_generation' }
        unless defined $generation;

    my $now = $self->_now();
    $self->_make_room($channel);
    $self->{channels}{lc($channel)} = {
        generation       => $generation,
        phase            => 'collecting',
        contributions    => [],
        contributor_nicks => {},
        started_at       => $now,
        closing_started_at => 0,
        last_seen        => $now,
    };

    return {
        action     => 'begin',
        reason     => 'collector_ready',
        generation => $generation,
        count      => 0,
        target     => $self->{target_contributions},
    };
}

sub collect {
    my ($self, %args) = @_;
    croak 'Portal collector object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $generation = _generation($args{generation});
    return { action => 'skip', reason => 'invalid_generation' }
        unless defined $generation;

    my $state = $self->{channels}{lc($channel)};
    return { action => 'skip', reason => 'inactive' }
        unless ref($state) eq 'HASH';
    return { action => 'skip', reason => 'stale_generation' }
        unless int($state->{generation} // 0) == $generation;

    my $count = scalar @{ $state->{contributions} || [] };
    return {
        action => 'skip', reason => 'closing', generation => $generation,
        count => $count, target => $self->{target_contributions},
    } unless ($state->{phase} // '') eq 'collecting';

    my $nick = _nick_key($args{nick});
    return {
        action => 'skip', reason => 'invalid_nick', generation => $generation,
        count => $count, target => $self->{target_contributions},
    } unless defined $nick;

    my $bot_nick = _nick_key($args{bot_nick});
    if (defined($bot_nick) && $nick eq $bot_nick) {
        return {
            action => 'skip', reason => 'self', generation => $generation,
            count => $count, target => $self->{target_contributions},
        };
    }

    my $line = _clean_line($args{message}, $self->{max_contribution_chars});
    return {
        action => 'skip', reason => 'blank_or_control', generation => $generation,
        count => $count, target => $self->{target_contributions},
    } unless defined $line;

    my $command_char = _plain_scalar($args{command_char})
        ? "$args{command_char}"
        : '!';
    if ((length($command_char) && index($line, $command_char) == 0)
        || $line =~ /^\?[A-Za-z0-9_.\-]{1,64}\z/) {
        return {
            action => 'skip', reason => 'command', generation => $generation,
            count => $count, target => $self->{target_contributions},
        };
    }

    if (defined($bot_nick) && length($bot_nick)) {
        my $quoted = quotemeta($bot_nick);
        if ($line =~ /^$quoted(?:\s*[:,]\s*|\s+)/i) {
            return {
                action => 'skip', reason => 'bot_trigger', generation => $generation,
                count => $count, target => $self->{target_contributions},
            };
        }
    }

    if ($state->{contributor_nicks}{$nick}) {
        return {
            action => 'skip', reason => 'duplicate_nick', generation => $generation,
            count => $count, target => $self->{target_contributions},
        };
    }

    my $now = $self->_now();
    croak 'Portal collector clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $state->{contributor_nicks}{$nick} = 1;
    push @{ $state->{contributions} }, $line;

    $count = scalar @{ $state->{contributions} };
    return {
        action     => 'collect',
        reason     => $count >= $self->{target_contributions}
            ? 'target_reached'
            : 'contribution_accepted',
        generation => $generation,
        count      => $count,
        target     => $self->{target_contributions},
        ready      => $count >= $self->{target_contributions} ? 1 : 0,
    };
}

sub mark_closing {
    my ($self, %args) = @_;
    croak 'Portal collector object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $generation = _generation($args{generation});
    return { action => 'skip', reason => 'invalid_generation' }
        unless defined $generation;

    my $state = $self->{channels}{lc($channel)};
    return { action => 'skip', reason => 'inactive' }
        unless ref($state) eq 'HASH';
    return { action => 'skip', reason => 'stale_generation' }
        unless int($state->{generation} // 0) == $generation;

    my $count = scalar @{ $state->{contributions} || [] };
    return {
        action => 'skip', reason => 'insufficient_contributions',
        generation => $generation, count => $count,
    } if $count < $self->{minimum_contributions};

    if (($state->{phase} // '') eq 'closing') {
        return {
            action => 'skip', reason => 'already_closing',
            generation => $generation, count => $count,
        };
    }

    my $now = $self->_now();
    $state->{phase} = 'closing';
    $state->{closing_started_at} = $now;
    $state->{last_seen} = $now;

    return {
        action => 'close', reason => 'ready_for_synthesis',
        generation => $generation, count => $count,
    };
}

sub contributions {
    my ($self, %args) = @_;
    croak 'Portal collector object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $generation = _generation($args{generation});
    return [] unless defined $generation;

    my $state = $self->{channels}{lc($channel)};
    return [] unless ref($state) eq 'HASH'
        && int($state->{generation} // 0) == $generation;
    return [ @{ $state->{contributions} || [] } ];
}

sub snapshot {
    my ($self, $channel) = @_;
    croak 'Portal collector object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $state = $self->{channels}{lc($key)};
    return {
        active => 0, phase => 'inactive', generation => 0,
        count => 0, target => $self->{target_contributions},
        minimum => $self->{minimum_contributions}, ready => 0,
        closing_timed_out => 0,
    } unless ref($state) eq 'HASH';

    my $count = scalar @{ $state->{contributions} || [] };
    my $phase = ($state->{phase} // '') eq 'closing'
        ? 'closing'
        : 'collecting';
    my $timed_out = 0;
    if ($phase eq 'closing') {
        my $now = $self->_now();
        my $started = $state->{closing_started_at} // 0;
        $timed_out = 1
            if $started > 0
                && $now >= $started
                && ($now - $started) >= $self->{closing_timeout_seconds};
    }

    return {
        active => 1,
        phase => $phase,
        generation => int($state->{generation}),
        count => $count,
        target => $self->{target_contributions},
        minimum => $self->{minimum_contributions},
        ready => $count >= $self->{target_contributions} ? 1 : 0,
        closing_timed_out => $timed_out,
    };
}

sub forget_channel {
    my ($self, $channel) = @_;
    croak 'Portal collector object is required' unless ref($self);
    my $key = _channel_key($channel);
    return delete($self->{channels}{lc($key)}) ? 1 : 0;
}

sub clear_all {
    my ($self) = @_;
    croak 'Portal collector object is required' unless ref($self);
    my $count = scalar keys %{ $self->{channels} };
    $self->{channels} = {};
    return $count;
}

sub format_portal_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel)
        && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/
        && ref($summary) eq 'HASH';

    my $action = _safe_reason($summary->{action});
    my $reason = _safe_reason($summary->{reason});
    return undef unless defined($action) && defined($reason);

    my @parts = (
        '[SPARK_PORTAL]',
        "channel=$channel",
        "action=$action",
        "reason=$reason",
    );
    for my $key (qw(generation count target)) {
        push @parts, "$key=" . int($summary->{$key})
            if _plain_scalar($summary->{$key}) && "$summary->{$key}" =~ /^\d+\z/;
    }
    return join ' ', @parts;
}

1;
