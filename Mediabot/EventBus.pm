package Mediabot::EventBus;

use strict;
use warnings;
use utf8;

# ---------------------------------------------------------------------------
# Mediabot::EventBus
# ---------------------------------------------------------------------------
# mb167-B1: minimal internal event bus foundation.
#
# This module deliberately does not change current Mediabot behavior yet.
# It is the second architectural brick after CommandRegistry. It will allow
# future core code, internal plugins and controlled script runners to subscribe
# to events such as public_message, join, part, timer, url_detected, shutdown...
# ---------------------------------------------------------------------------

sub new {
    my ($class) = @_;

    return bless {
        listeners => {}, # event_name -> [ { cb => CODE, name => ..., plugin => ..., priority => ... } ]
    }, $class;
}

sub _event_name {
    my ($event) = @_;
    return undef unless defined $event;
    $event =~ s/^\s+|\s+$//g;
    return undef unless length $event;
    $event =~ s/\s+/_/g;
    return lc $event;
}

sub on {
    my ($self, $event, $callback, %opts) = @_;

    my $name = _event_name($event);
    die "EventBus: missing event name\n" unless defined $name;
    die "EventBus: listener for '$name' must be a CODE reference\n"
        unless ref($callback) eq 'CODE';

    my $entry = {
        cb       => $callback,
        name     => $opts{name},
        plugin   => $opts{plugin},
        priority => defined $opts{priority} ? int($opts{priority}) : 0,
        once     => $opts{once} ? 1 : 0,
    };

    $self->{listeners}{$name} ||= [];
    push @{ $self->{listeners}{$name} }, $entry;

    @{ $self->{listeners}{$name} } = sort {
        ($b->{priority} <=> $a->{priority})
    } @{ $self->{listeners}{$name} };

    return $entry;
}

sub once {
    my ($self, $event, $callback, %opts) = @_;
    $opts{once} = 1;
    return $self->on($event, $callback, %opts);
}

sub emit {
    my ($self, $event, @args) = @_;

    my $name = _event_name($event);
    return 0 unless defined $name;
    return 0 unless exists $self->{listeners}{$name};

    my @listeners = @{ $self->{listeners}{$name} };
    my $ran = 0;
    my @keep;

    for my $entry (@listeners) {
        eval {
            $entry->{cb}->(@args);
            1;
        };

        $ran++;
        push @keep, $entry unless $entry->{once};
    }

    $self->{listeners}{$name} = \@keep;
    return $ran;
}

sub emit_report {
    my ($self, $event, @args) = @_;

    my $name = _event_name($event);
    return {
        event  => $name,
        ran    => 0,
        errors => [],
    } unless defined $name && exists $self->{listeners}{$name};

    my @listeners = @{ $self->{listeners}{$name} };
    my @errors;
    my @keep;
    my $ran = 0;

    for my $entry (@listeners) {
        my $ok = eval {
            $entry->{cb}->(@args);
            1;
        };

        $ran++;

        if (!$ok) {
            my $err = $@ || 'unknown listener error';
            $err =~ s/\s+/ /g;
            push @errors, {
                event  => $name,
                name   => $entry->{name},
                plugin => $entry->{plugin},
                error  => $err,
            };
        }

        push @keep, $entry unless $entry->{once};
    }

    $self->{listeners}{$name} = \@keep;

    return {
        event  => $name,
        ran    => $ran,
        errors => \@errors,
    };
}

sub listeners {
    my ($self, $event) = @_;

    my $name = _event_name($event);
    return () unless defined $name;
    return () unless exists $self->{listeners}{$name};

    return @{ $self->{listeners}{$name} };
}

sub listener_count {
    my ($self, $event) = @_;

    # mb167-P1: force list context before scalar count. A direct
    # 'scalar $self->listeners($event)' can become undef when listeners()
    # returns an empty list, which is noisy in numeric comparisons.
    my @listeners = $self->listeners($event);
    return scalar @listeners;
}

sub clear {
    my ($self, $event) = @_;

    if (defined $event) {
        my $name = _event_name($event);
        return 0 unless defined $name;
        my $count = $self->listener_count($name);
        delete $self->{listeners}{$name};
        return $count;
    }

    my $count = 0;
    for my $name (keys %{ $self->{listeners} }) {
        $count += scalar @{ $self->{listeners}{$name} };
    }

    $self->{listeners} = {};
    return $count;
}

sub events {
    my ($self) = @_;

    # mb167-P2: force list context before returning. Direct
    # 'return sort keys ...' may yield undef in scalar context when the list is
    # empty, which makes scalar($bus->events) noisy in tests/callers.
    my @events = sort keys %{ $self->{listeners} };
    return @events;
}

1;
