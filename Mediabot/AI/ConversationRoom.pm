package Mediabot::AI::ConversationRoom;

use strict;
use warnings;
use Carp qw(croak);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Mediabot::Spark::Observer;

# Reuse the bounded observer, with a short conversational window. Identity
# stays local; only per-request speaker labels cross the provider boundary.
sub new {
    my ($class, %args) = @_;
    my $clock = $args{clock} || sub { time() };
    return bless {
        clock => $clock,
        observer => Mediabot::Spark::Observer->new(
            clock => $clock, max_channels => 256, max_lines => 8,
            max_line_chars => 240, max_age_seconds => 300,
        ),
        generations => {},
        previous => {},
        serial => 0,
        versions => {},
    }, $class;
}

sub _fold {
    my ($raw) = @_;
    return '' unless defined($raw) && !ref($raw);
    my $value = lc "$raw";
    $value =~ tr/[]\\^/{}|~/;
    return $value;
}

sub forget_channel {
    my ($self, $channel) = @_;
    my $key = _fold($channel);
    $self->{observer}->forget_channel($key);
    delete $self->{previous}{$key};
    delete $self->{generations}{$key};
    delete $self->{versions}{$key};
    return 1;
}

sub observe_public_line {
    my ($self, %args) = @_;
    my $key = _fold($args{channel});
    my $generation = $args{room_generation};
    if (defined($generation) && !ref($generation) && "$generation" =~ /^\d+\z/) {
        if (exists($self->{generations}{$key})
            && $self->{generations}{$key} != $generation) {
            $self->forget_channel($key);
        }
        $self->{generations}{$key} = $generation;
    }
    my $observed = $self->{observer}->observe_public_line(
        %args, channel => $key, nick => _fold($args{nick}),
        bot_nick => _fold($args{bot_nick}),
    );
    $self->{versions}{$key} = ++$self->{serial}
        if ($observed->{reason} // '') eq 'human_context';
    my %live = map { $_ => 1 } @{ $self->{observer}->channels() };
    for my $store (qw(generations previous versions)) {
        delete $self->{$store}{$_} for grep { !$live{$_} } keys %{ $self->{$store} };
    }
    return $self->snapshot($key);
}

sub snapshot {
    my ($self, $channel) = @_;
    my $key = _fold($channel);
    my $lines = $self->{observer}->context_lines($key);
    my $activity = $self->{observer}->activity_summary($key, window_seconds => 300);
    my (%speakers, @context);
    for my $line (@$lines) {
        my ($nick, $text) = $line =~ /^([^:]+): (.*)\z/s;
        next unless defined $text;
        unless (exists $speakers{$nick}) {
            my $label = 'speaker' . (1 + scalar keys %speakers);
            $speakers{$nick} = $label;
        }
        push @context, { speaker => $speakers{$nick}, text => $text };
    }
    my $reason = @context < 3 || keys(%speakers) < 2 ? 'room_warming'
        : defined($activity->{last_bot_pressure_at})
            && $activity->{bot_pressure_quiet_seconds} < 30 ? 'room_busy'
        : 'room_ready';
    my $previous = $self->{previous}{$key};
    my $now = $self->{clock}->();
    my $previous_reply = ref($previous) eq 'HASH'
        && $now >= $previous->{at} && $now - $previous->{at} <= 300
        ? $previous->{text} : '';
    return {
        ready => $reason eq 'room_ready' ? 1 : 0,
        reason => $reason,
        context => \@context,
        fingerprint => sha256_hex(encode('UTF-8', join "\x00", $self->{versions}{$key} // 0, @$lines)),
        previous_reply => $previous_reply,
    };
}

sub note_delivery {
    my ($self, $channel, $text) = @_;
    return 0 unless defined($text) && !ref($text) && length($text) <= 280
        && $text !~ /[\x00-\x1f\x7f]/;
    my $key = _fold($channel);
    $self->note_bot_pressure($key);
    $self->{previous}{$key} = { at => $self->{clock}->(), text => "$text" };
    return 1;
}

sub note_bot_pressure {
    my ($self, $channel) = @_;
    $self->{observer}->observe_public_line(
        channel => _fold($channel), nick => 'conversation-bot', bot_nick => 'conversation-bot',
        message => 'delivery', from_bot => 1,
    );
    return 1;
}

1;
