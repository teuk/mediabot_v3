package Mediabot::Plugin::EventQueueV3;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;

    die "EventQueueV3: defer callback is required\n"
        unless ref($args{defer}) eq 'CODE';
    die "EventQueueV3: dispatch callback is required\n"
        unless ref($args{dispatch}) eq 'CODE';

    my $max_pending = $args{max_pending} // 32;
    my $batch_size  = $args{batch_size}  // 8;
    die "EventQueueV3: max_pending must be between 1 and 256\n"
        unless !ref($max_pending) && "$max_pending" =~ /\A[0-9]+\z/
            && $max_pending >= 1 && $max_pending <= 256;
    die "EventQueueV3: batch_size must be between 1 and max_pending\n"
        unless !ref($batch_size) && "$batch_size" =~ /\A[0-9]+\z/
            && $batch_size >= 1 && $batch_size <= $max_pending;

    return bless {
        defer        => $args{defer},
        dispatch     => $args{dispatch},
        on_drop      => ref($args{on_drop}) eq 'CODE' ? $args{on_drop} : undef,
        on_error     => ref($args{on_error}) eq 'CODE' ? $args{on_error} : undef,
        max_pending  => int($max_pending),
        batch_size   => int($batch_size),
        queue        => [],
        scheduled    => 0,
        draining     => 0,
        generation   => 0,
        dropped      => 0,
        processed    => 0,
    }, $class;
}

sub pending_count   { scalar @{ $_[0]{queue} } }
sub dropped_count   { $_[0]{dropped} }
sub processed_count { $_[0]{processed} }
sub max_pending     { $_[0]{max_pending} }
sub batch_size      { $_[0]{batch_size} }

sub enqueue {
    my ($self, $event) = @_;
    die "EventQueueV3: event object is required\n" unless ref($event);

    if (@{ $self->{queue} } >= $self->{max_pending}) {
        $self->{dropped}++;
        eval { $self->{on_drop}->($event, $self->{dropped}) }
            if $self->{on_drop};
        return 0;
    }

    push @{ $self->{queue} }, $event;
    $self->_schedule unless $self->{scheduled} || $self->{draining};
    return 1;
}

sub _schedule {
    my ($self) = @_;
    return 1 if $self->{scheduled};

    my $token = ++$self->{generation};
    $self->{scheduled} = 1;
    my $ok = eval {
        $self->{defer}->(sub {
            return unless $token == $self->{generation};
            $self->{scheduled} = 0;
            $self->_drain;
        });
        1;
    };
    unless ($ok) {
        $self->{scheduled} = 0;
        die($@ || "EventQueueV3: defer failed\n");
    }
    return 1;
}

sub _drain {
    my ($self) = @_;
    return 1 if $self->{draining};

    $self->{draining} = 1;
    my $count = 0;
    while ($count < $self->{batch_size} && @{ $self->{queue} }) {
        my $event = shift @{ $self->{queue} };
        my $ok = eval { $self->{dispatch}->($event); 1 };
        if (!$ok && $self->{on_error}) {
            my $error = $@ || 'event dispatch failed';
            eval { $self->{on_error}->($event, $error) };
        }
        $self->{processed}++;
        $count++;
    }
    $self->{draining} = 0;
    $self->_schedule if @{ $self->{queue} };
    return 1;
}

sub clear {
    my ($self) = @_;
    my $removed = scalar @{ $self->{queue} };
    $self->{queue} = [];
    $self->{scheduled} = 0;
    $self->{generation}++;
    return $removed;
}

1;
