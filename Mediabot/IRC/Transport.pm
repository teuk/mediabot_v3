package Mediabot::IRC::Transport;

use strict;
use warnings;
use parent 'Net::Async::IRC';
use mro 'c3';
use Scalar::Util qw(weaken);
use Carp qw(croak);

# Keep protocol serialization and Stream's public write/Future contract. Only
# whole PONG frames may overtake work not yet submitted to the native stream.
sub write {
    my ($self, $data, %args) = @_;
    croak 'Cannot write to a retired IRC transport' if $self->{_control_retired};
    croak 'Cannot write to a closing IRC transport' if $self->{_control_closing};
    return $self->SUPER::write($data, %args) unless $self->loop;
    for my $key (keys %args) {
        croak "Unrecognised write option: $key"
            unless $key =~ /\A(?:on_write|on_flush|on_error|write_len)\z/;
    }
    my $future = $self->loop->new_future;
    # A raw partial frame or producer is a compatibility barrier. Disable
    # overtaking for this transport rather than insert PONG inside opaque data.
    $self->{_control_barrier} = 1
        unless defined($data) && !ref($data) && $data =~ /\A[^\r\n]*\r\n\z/;
    my $pong = defined($data) && !ref($data)
        && $data =~ /\APONG [^\r\n]*\r\n\z/;
    $self->{_control_pongs}++ if $pong;
    push @{$self->{_control_pending}}, {
        data => $data, args => \%args, future => $future, pong => $pong,
    };
    $self->_control_pump;
    return defined(wantarray) ? $future : undef;
}

sub _control_pump {
    my ($self) = @_;
    return if $self->{_control_retired} || $self->{_control_active};
    my $queue = $self->{_control_pending} ||= [];
    unless (@$queue) {
        $self->SUPER::close_when_empty if $self->{_control_closing};
        return;
    }
    my $index = 0;
    if (!$self->{_control_barrier} && $self->{_control_pongs}) {
        for my $i (0 .. $#$queue) {
            if ($queue->[$i]{pong}) { $index = $i; last; }
        }
    }
    my ($entry) = splice @$queue, $index, 1;
    $self->{_control_pongs}-- if $entry->{pong};
    $self->{_control_active} = $entry;
    my $data = delete $entry->{data};
    my $args = delete $entry->{args};
    my $weak = $self; weaken($weak);
    if (my $callback = $args->{on_error}) {
        my $called = 0;
        $args->{on_error} = sub {
            return if $called++;
            my $ok = eval { $callback->(@_); 1 };
            return if $ok;
            my $error = $@;
            if ($weak && $weak->{_control_retired}) {
                $weak->{_control_close_error} = $error
                    unless defined $weak->{_control_close_error};
            } else { die $error; }
        };
    }
    my $native;
    my $ok = eval { $native = $self->SUPER::write($data, %$args); 1 };
    unless ($ok) {
        my $error = $@;
        $entry->{future}->fail('IRC write setup failed', 'irc_write')
            unless $entry->{future}->is_ready;
        $self->close_now;
        die $error;
    }
    $native->on_ready(sub {
        my ($completed) = @_;
        if ($weak && !$weak->{_control_retired} && $weak->loop) {
            # Stream invokes on_flush before removing its Writer. Pump only on
            # a later turn. Schedule before consumer callbacks, which may throw.
            $weak->loop->later(sub {
                return unless $weak && !$weak->{_control_retired};
                delete $weak->{_control_active};
                $weak->_control_pump;
            });
        }
        my $out = $entry->{future};
        unless ($out->is_ready) {
            my $ok = eval {
                $completed->is_done ? $out->done($completed->get)
                    : $out->fail($completed->failure);
                1;
            };
            unless ($ok) {
                my $error = $@;
                if ($weak && $weak->{_control_retired}) {
                    $weak->{_control_close_error} = $error
                        unless defined $weak->{_control_close_error};
                } else { die $error; }
            }
        }
    });
}

sub close_when_empty {
    my ($self) = @_;
    $self->{_control_closing} = 1;
    $self->_control_pump;
}

sub close_now {
    my ($self) = @_;
    return if $self->{_control_retired};
    $self->{_control_retired} = 1;
    my $queue = delete $self->{_control_pending} || [];
    delete $self->{_control_pongs};
    my $active = delete $self->{_control_active};
    # Detach all work before user callbacks, which may install a successor.
    my $error;
    for my $entry (@$queue) {
        eval {
            $entry->{future}->fail('write failed: stream closing', 'syswrite', 'stream closing')
                unless $entry->{future}->is_ready;
            1;
        } or do { $error = $@ unless defined $error; };
        eval {
            if (my $cb = $entry->{args}{on_error}) { $cb->($self, 'stream closing'); }
            1;
        } or do { $error = $@ unless defined $error; };
    }
    eval { $self->SUPER::close_now; 1 } or do { $error = $@ unless defined $error; };
    # Also cover a native setup exception before Stream took ownership.
    if ($active && !$active->{future}->is_ready) {
        $active->{future}->fail('write failed: stream closing', 'syswrite', 'stream closing');
    }
    my $callback_error = delete $self->{_control_close_error};
    $error = $callback_error unless defined $error;
    die $error if defined $error;
    return;
}

sub retire_output { shift->close_now(@_) }

1;
