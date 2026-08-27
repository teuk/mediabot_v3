package Mediabot::Spark::Observer;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '1.0';

my %DEFAULT = (
    max_channels   => 256,
    max_lines      => 12,
    max_line_chars => 240,
    max_age_seconds => 7_200,
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
}

sub observe_public_line {
    my ($self, %args) = @_;
    croak 'Spark observer object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $nick = _nick_key($args{nick});
    return { action => 'skip', reason => 'invalid_nick' } unless defined $nick;

    my $bot_nick = _nick_key($args{bot_nick});
    if (defined($bot_nick) && lc($nick) eq lc($bot_nick)) {
        return { action => 'skip', reason => 'self' };
    }

    my $line = _clean_line($args{message}, $self->{max_line_chars});
    return { action => 'skip', reason => 'blank_or_control' } unless defined $line;

    my $command_char = _plain_scalar($args{command_char})
        ? "$args{command_char}"
        : '!';
    if (length($command_char) && index($line, $command_char) == 0) {
        return { action => 'skip', reason => 'command' };
    }

    # Bare factoid quick recall is also a command surface, even though it uses
    # '?' instead of MAIN_PROG_CMD_CHAR.
    return { action => 'skip', reason => 'command' }
        if $line =~ /^\?[A-Za-z0-9_.\-]{1,64}\z/;

    if (defined($bot_nick) && length($bot_nick)) {
        my $quoted = quotemeta($bot_nick);
        return { action => 'skip', reason => 'bot_trigger' }
            if $line =~ /^$quoted(?:\s*[:,]\s*|\s+)/i;
    }

    my $now = $self->_now();
    $self->_make_room($channel);
    my $state = $self->{channels}{lc($channel)} ||= {
        lines => [],
        last_seen => $now,
    };

    croak 'Spark observer clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $self->_prune($state, $now);

    push @{ $state->{lines} }, {
        at   => $now,
        nick => $nick,
        text => $line,
    };

    shift @{ $state->{lines} }
        while @{ $state->{lines} } > $self->{max_lines};

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
