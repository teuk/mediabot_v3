package Mediabot::Spark::Mosaic;

use strict;
use warnings;
use utf8;

use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    mosaic_defaults
    mosaic_target_for_regime
    mosaic_opening_generation
    format_mosaic_log
);

my %DEFAULT = (
    max_channels            => 256,
    minimum_contributions   => 2,
    max_word_chars          => 24,
    closing_timeout_seconds => 30,
);

sub mosaic_defaults { return { %DEFAULT }; }

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

sub _safe_reason {
    my ($value) = @_;
    return undef unless _plain_scalar($value)
        && "$value" =~ /^[a-z_]{1,64}\z/;
    return "$value";
}

sub mosaic_target_for_regime {
    my ($regime) = @_;
    return undef unless _plain_scalar($regime);
    $regime = lc "$regime";
    return 2 if $regime eq 'small';
    return 3 if $regime eq 'social';
    return 4 if $regime eq 'crowded';
    return undef;
}

sub mosaic_opening_generation {
    my (%args) = @_;
    my $target = _bounded_int($args{target}, 3, 2, 4);
    my $language = _plain_scalar($args{language})
        ? lc "$args{language}"
        : 'en';

    my $line = $language eq 'fr'
        ? "Mosaïque éclair : +mot, un seul mot par personne — $target voix et j'assemble."
        : $language eq 'es'
            ? "Mosaico relámpago: +palabra, una por persona — $target voces y las uno."
            : "Flash mosaic: +word, one word per person — $target voices and I assemble them.";

    return {
        action => 'ready', reason => 'local_opening', kind => 'mosaic',
        content => { line => $line },
    };
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
        minimum_contributions => _bounded_int(
            $args{minimum_contributions},
            $DEFAULT{minimum_contributions},
            2,
            4,
        ),
        max_word_chars => _bounded_int(
            $args{max_word_chars}, $DEFAULT{max_word_chars}, 8, 40,
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
    croak 'Mosaic collector capacity exhausted by active events';
}

sub begin {
    my ($self, %args) = @_;
    croak 'Mosaic collector object is required' unless ref($self);

    my $channel = _channel_key($args{channel});
    my $generation = _generation($args{generation});
    return { action => 'skip', reason => 'invalid_generation' }
        unless defined $generation;
    my $target = _bounded_int($args{target}, 0, 2, 4);
    return { action => 'skip', reason => 'invalid_target' }
        unless $target;
    return { action => 'skip', reason => 'invalid_target' }
        if $target < $self->{minimum_contributions};

    my $now = $self->_now();
    $self->_make_room($channel);
    $self->{channels}{lc($channel)} = {
        generation        => $generation,
        target            => $target,
        phase             => 'collecting',
        contributions     => [],
        contributor_nicks => {},
        started_at        => $now,
        closing_started_at => 0,
        last_seen         => $now,
    };

    return {
        action => 'begin', reason => 'collector_ready',
        generation => $generation, count => 0, target => $target,
    };
}

sub _word_from_message {
    my ($self, $value) = @_;
    return (undef, 'not_contribution') unless _plain_scalar($value);

    my $line = "$value";
    $line =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return (undef, 'invalid_word') if $line =~ /[\x00-\x1f\x7f]/;
    $line =~ s/^\s+|\s+$//g;
    return (undef, 'not_contribution') unless index($line, '+') == 0;

    my $word = substr($line, 1);
    return (undef, 'invalid_word')
        unless length($word) >= 1
            && length($word) <= $self->{max_word_chars}
            && $word =~ /\A[\p{L}\p{N}_]+(?:['’\-][\p{L}\p{N}_]+)*\z/u;
    return ($word, undef);
}

sub collect {
    my ($self, %args) = @_;
    croak 'Mosaic collector object is required' unless ref($self);

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
    my $target = int($state->{target} // 0);
    return {
        action => 'skip', reason => 'closing', generation => $generation,
        count => $count, target => $target,
    } unless ($state->{phase} // '') eq 'collecting';

    my $nick = _nick_key($args{nick});
    return {
        action => 'skip', reason => 'invalid_nick', generation => $generation,
        count => $count, target => $target,
    } unless defined $nick;

    my $bot_nick = _nick_key($args{bot_nick});
    return {
        action => 'skip', reason => 'self', generation => $generation,
        count => $count, target => $target,
    } if defined($bot_nick) && $nick eq $bot_nick;

    my ($word, $word_error) = $self->_word_from_message($args{message});
    return {
        action => 'skip', reason => $word_error, generation => $generation,
        count => $count, target => $target,
    } unless defined $word;

    return {
        action => 'skip', reason => 'duplicate_nick', generation => $generation,
        count => $count, target => $target,
    } if $state->{contributor_nicks}{$nick};

    my $now = $self->_now();
    croak 'Mosaic collector clock moved backwards'
        if defined($state->{last_seen}) && $now < $state->{last_seen};
    $state->{last_seen} = $now;
    $state->{contributor_nicks}{$nick} = 1;
    push @{ $state->{contributions} }, $word;

    $count = scalar @{ $state->{contributions} };
    return {
        action => 'collect',
        reason => $count >= $target
            ? 'target_reached'
            : 'contribution_accepted',
        generation => $generation,
        count => $count,
        target => $target,
        ready => $count >= $target ? 1 : 0,
    };
}

sub mark_closing {
    my ($self, %args) = @_;
    croak 'Mosaic collector object is required' unless ref($self);

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
        target => int($state->{target} // 0),
    } if $count < $self->{minimum_contributions};
    return {
        action => 'skip', reason => 'already_closing',
        generation => $generation, count => $count,
        target => int($state->{target} // 0),
    } if ($state->{phase} // '') eq 'closing';

    my $now = $self->_now();
    $state->{phase} = 'closing';
    $state->{closing_started_at} = $now;
    $state->{last_seen} = $now;
    return {
        action => 'close', reason => 'ready_for_synthesis',
        generation => $generation, count => $count,
        target => int($state->{target}),
    };
}

sub contributions {
    my ($self, %args) = @_;
    croak 'Mosaic collector object is required' unless ref($self);
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
    croak 'Mosaic collector object is required' unless ref($self);
    my $key = _channel_key($channel);
    my $state = $self->{channels}{lc($key)};
    return {
        active => 0, phase => 'inactive', generation => 0,
        count => 0, target => 0,
        minimum => $self->{minimum_contributions}, ready => 0,
        closing_timed_out => 0,
    } unless ref($state) eq 'HASH';

    my $count = scalar @{ $state->{contributions} || [] };
    my $target = int($state->{target} // 0);
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
        target => $target,
        minimum => $self->{minimum_contributions},
        ready => $count >= $target ? 1 : 0,
        closing_timed_out => $timed_out,
    };
}

sub forget_channel {
    my ($self, $channel) = @_;
    croak 'Mosaic collector object is required' unless ref($self);
    my $key = _channel_key($channel);
    return delete($self->{channels}{lc($key)}) ? 1 : 0;
}

sub clear_all {
    my ($self) = @_;
    croak 'Mosaic collector object is required' unless ref($self);
    my $count = scalar keys %{ $self->{channels} };
    $self->{channels} = {};
    return $count;
}

sub format_mosaic_log {
    my ($channel, $summary) = @_;
    return undef unless _plain_scalar($channel)
        && "$channel" =~ /^#[^\s,:\x00-\x1f\x7f]{1,79}\z/
        && ref($summary) eq 'HASH';
    my $action = _safe_reason($summary->{action});
    my $reason = _safe_reason($summary->{reason});
    return undef unless defined($action) && defined($reason);

    my @parts = (
        '[SPARK_MOSAIC]', "channel=$channel",
        "action=$action", "reason=$reason",
    );
    for my $key (qw(generation count target)) {
        push @parts, "$key=" . int($summary->{$key})
            if _plain_scalar($summary->{$key})
                && "$summary->{$key}" =~ /^\d+\z/;
    }
    return join ' ', @parts;
}

1;
