package Mediabot::Spark::Observer;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Mediabot::Spark::Audience qw(summarize_audience);

our $VERSION = '1.0';

my %DEFAULT = (
    max_channels   => 256,
    max_lines      => 12,
    max_line_chars => 240,
    max_age_seconds => 7_200,
    max_activity_events => 512,
);

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
    return "$nick";
}

sub _clean_line {
    my ($text, $max_chars) = @_;
    return undef unless _plain_scalar($text);

    my $line = "$text";

    # Remove presentation-only IRC controls before the line ever reaches the
    # bounded in-memory context window or a future provider request.
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $line =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;

    # Reject CTCP/control payloads instead of trying to reinterpret them.
    return undef if $line =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;

    $line =~ s/[\r\n\t]+/ /g;
    $line =~ s/\s+/ /g;
    $line =~ s/^\s+|\s+$//g;
    return undef unless length $line;

    $line = substr($line, 0, $max_chars) if length($line) > $max_chars;
    $line =~ s/\s+$//g;
    return length($line) ? $line : undef;
}

sub new {
    my ($class, %args) = @_;

    my $clock = $args{clock};
    croak 'clock must be a code reference'
        if defined($clock) && ref($clock) ne 'CODE';

    return bless {
        clock => $clock || sub { clock_gettime(CLOCK_MONOTONIC) },
        max_channels => _bounded_int(
            $args{max_channels}, $DEFAULT{max_channels}, 1, 4096,
        ),
        max_lines => _bounded_int(
            $args{max_lines}, $DEFAULT{max_lines}, 3, 64,
        ),
        max_line_chars => _bounded_int(
            $args{max_line_chars}, $DEFAULT{max_line_chars}, 40, 500,
        ),
        max_age_seconds => _bounded_int(
            $args{max_age_seconds}, $DEFAULT{max_age_seconds}, 300, 86_400,
        ),
        max_activity_events => _bounded_int(
            $args{max_activity_events}, $DEFAULT{max_activity_events}, 32, 4096,
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

    my ($oldest) = sort {
        ($self->{channels}{lc($a)}{last_seen} // 0)
            <=> ($self->{channels}{lc($b)}{last_seen} // 0)
            || $a cmp $b
    } keys %{ $self->{channels} };

    delete $self->{channels}{lc($oldest)} if defined $oldest;
}

sub _prune {
    my ($self, $state, $now) = @_;
    my $min = $now - $self->{max_age_seconds};
    my @keep = grep {
        ref($_) eq 'HASH'
            && defined($_->{at})
            && looks_like_number($_->{at})
            && $_->{at} >= $min
            && $_->{at} <= $now
    } @{ $state->{lines} || [] };
    $state->{lines} = \@keep;

    my @activity = grep {
        ref($_) eq 'HASH'
            && defined($_->{at})
            && looks_like_number($_->{at})
            && $_->{at} >= $min
            && $_->{at} <= $now
            && defined($_->{kind})
            && ($_->{kind} eq 'human' || $_->{kind} eq 'bot_pressure')
    } @{ $state->{activity} || [] };
    $state->{activity} = \@activity;
}

sub _state {
    my ($self, $channel, $now) = @_;
    $self->_make_room($channel);
    my $state = $self->{channels}{lc($channel)} ||= {
        lines    => [],
        activity => [],
        last_seen => $now,
    };

    croak 'Spark observer clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $self->_prune($state, $now);
    return $state;
}

sub _record_activity {
    my ($self, $state, %args) = @_;
    my %event = (
        at   => $args{at},
        kind => $args{kind},
    );
    $event{nick} = $args{nick} if defined $args{nick};
    push @{ $state->{activity} }, \%event;
    shift @{ $state->{activity} }
        while @{ $state->{activity} } > $self->{max_activity_events};
}

sub _command_reason {
    my (%args) = @_;
    my $line = $args{line};
    my $command_char = $args{command_char};
    return 'command'
        if length($command_char) && index($line, $command_char) == 0;
    return 'command' if $line =~ /^\?[A-Za-z0-9_.\-]{1,64}\z/;

    my $bot_nick = $args{bot_nick};
    return undef unless defined($bot_nick) && length($bot_nick);
    my $quoted_nick = quotemeta($bot_nick);
    return 'bot_trigger'
        if $line =~ /^$quoted_nick(?:\s*[:,]\s*|\s+)/i;

    my ($first) = split /\s+/, $line;
    return undef unless defined($first) && length($first);

    my $fold = lc $first;
    my $nick_fold = lc $bot_nick;
    if ($args{initial_trigger_enabled}) {
        my $initial = substr($nick_fold, 0, 1);
        return 'initial_trigger' if length($initial) && $fold eq $initial;
    }
    return undef;
}

sub observe_public_line {
    my ($self, %args) = @_;
    croak 'Spark observer object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $nick = _nick_key($args{nick});
    return { action => 'skip', reason => 'invalid_nick' } unless defined $nick;

    my $bot_nick = _nick_key($args{bot_nick});

    my $line = _clean_line($args{message}, $self->{max_line_chars});
    return { action => 'skip', reason => 'blank_or_control' } unless defined $line;

    my $command_char = _plain_scalar($args{command_char})
        ? "$args{command_char}"
        : '!';
    my $now = $self->_now();
    my $record = !exists($args{record}) || $args{record} ? 1 : 0;
    my $state = $record
        ? $self->_state($channel, $now)
        : $self->{channels}{lc($channel)};

    my $from_self = defined($bot_nick) && lc($nick) eq lc($bot_nick);
    my $from_bot = $from_self || ($args{from_bot} ? 1 : 0);
    if ($from_bot) {
        _record_activity(
            $self, $state,
            at => $now, kind => 'bot_pressure',
        ) if $record;
        return {
            action => 'observe',
            reason => $from_self ? 'self' : 'bot_activity',
            line_count => ref($state) eq 'HASH'
                ? scalar(@{ $state->{lines} || [] }) : 0,
            bot_pressure => 1,
        };
    }

    my $command_reason = _command_reason(
        line => $line,
        command_char => $command_char,
        bot_nick => $bot_nick,
        initial_trigger_enabled => $args{initial_trigger_enabled},
    );
    if (defined $command_reason) {
        _record_activity(
            $self, $state,
            at => $now, kind => 'bot_pressure',
        ) if $record;
        return {
            action => 'observe',
            reason => $command_reason,
            line_count => ref($state) eq 'HASH'
                ? scalar(@{ $state->{lines} || [] }) : 0,
            bot_pressure => 1,
        };
    }

    unless ($record) {
        return {
            action => 'observe',
            reason => 'human_context',
            line_count => ref($state) eq 'HASH'
                ? scalar(@{ $state->{lines} || [] }) : 0,
        };
    }

    push @{ $state->{lines} }, {
        at   => $now,
        nick => $nick,
        text => $line,
    };

    shift @{ $state->{lines} }
        while @{ $state->{lines} } > $self->{max_lines};

    _record_activity(
        $self, $state,
        at => $now, kind => 'human', nick => $nick,
    );

    return {
        action     => 'observe',
        reason     => 'human_context',
        line_count => scalar(@{ $state->{lines} }),
    };
}

sub context_lines {
    my ($self, $channel) = @_;
    croak 'Spark observer object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $state = $self->{channels}{lc($key)};
    return [] unless ref($state) eq 'HASH';

    my $now = $self->_now();
    croak 'Spark observer clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $self->_prune($state, $now);

    return [
        map { "$_->{nick}: $_->{text}" }
            @{ $state->{lines} || [] }
    ];
}

sub context_summary {
    my ($self, $channel) = @_;
    my $lines = $self->context_lines($channel);
    my $chars = 0;
    $chars += length($_) for @$lines;
    return {
        line_count => scalar(@$lines),
        chars      => $chars,
    };
}

sub activity_summary {
    my ($self, $channel, %args) = @_;
    croak 'Spark observer object is required' unless ref($self);

    my $key = _channel_key($channel);
    my $window = _bounded_int(
        $args{window_seconds}, 600, 60, 86_400,
    );
    my $state = $self->{channels}{lc($key)};
    return summarize_audience(
        human_weights => {},
        human_lines => 0,
        bot_pressure_lines => 0,
        window_seconds => $window,
        now => $self->_now(),
    ) unless ref($state) eq 'HASH';

    my $now = $self->_now();
    croak 'Spark observer clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $self->_prune($state, $now);

    my $cutoff = $now - $window;
    my @recent = grep {
        ref($_) eq 'HASH'
            && defined($_->{at})
            && looks_like_number($_->{at})
            && $_->{at} >= $cutoff
            && $_->{at} <= $now
    } @{ $state->{activity} || [] };

    my %human_weights;
    my $human_lines = 0;
    my $bot_pressure_lines = 0;
    my $last_human_at;
    my $last_bot_pressure_at;
    for my $entry (@recent) {
        if (($entry->{kind} // '') eq 'human') {
            my $nick = _nick_key($entry->{nick});
            next unless defined $nick;
            my $age = $now - $entry->{at};
            my $weight = 1 + int(999 * (($window - $age) / $window));
            $weight = 1 if $weight < 1;
            $weight = 1_000 if $weight > 1_000;
            $human_weights{lc($nick)} += $weight;
            $human_lines++;
            $last_human_at = $entry->{at}
                if !defined($last_human_at) || $entry->{at} > $last_human_at;
        }
        elsif (($entry->{kind} // '') eq 'bot_pressure') {
            $bot_pressure_lines++;
            $last_bot_pressure_at = $entry->{at}
                if !defined($last_bot_pressure_at)
                    || $entry->{at} > $last_bot_pressure_at;
        }
    }

    return summarize_audience(
        human_weights => \%human_weights,
        human_lines => $human_lines,
        bot_pressure_lines => $bot_pressure_lines,
        window_seconds => $window,
        now => $now,
        last_human_at => $last_human_at,
        last_bot_pressure_at => $last_bot_pressure_at,
    );
}

sub channels {
    my ($self) = @_;
    croak 'Spark observer object is required' unless ref($self);
    return [ sort keys %{ $self->{channels} } ];
}

sub forget_channel {
    my ($self, $channel) = @_;
    croak 'Spark observer object is required' unless ref($self);
    my $key = _channel_key($channel);
    return delete($self->{channels}{lc($key)}) ? 1 : 0;
}

sub clear_all {
    my ($self) = @_;
    croak 'Spark observer object is required' unless ref($self);
    my $count = scalar keys %{ $self->{channels} };
    $self->{channels} = {};
    return $count;
}

1;
