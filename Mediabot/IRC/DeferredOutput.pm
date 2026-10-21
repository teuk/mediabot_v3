package Mediabot::IRC::DeferredOutput;

use strict;
use warnings;
use utf8;
use Mediabot::IRC::Timer ();

# Existing bounded AntiFlood queue. Keep state keys, head reinsertion, timing
# and dynamic Helpers callbacks; this is separate from explicit paced batches.
sub botPrivmsg { return Mediabot::Helpers::botPrivmsg(@_); }
sub botAction { return Mediabot::Helpers::botAction(@_); }

sub _defer_flooded_send {
    my ($self, $kind, $to, $msg) = @_;

    my $q = $self->{_flood_outq}{$to} //= { items => [], armed => 0 };

    if ($self->{_flood_draining}) {
        # Re-blocage pendant un drain : on reprend la tete, le drain rearme.
        unshift @{ $q->{items} }, [ $kind, $msg ];
        return undef;
    }

    if (scalar(@{ $q->{items} }) >= 30) {
        $self->{logger}->log(3,
            "flood queue full on $to — dropping one $kind message");
        return undef;
    }

    push @{ $q->{items} }, [ $kind, $msg ];
    $self->{logger}->log(4, "botPrivmsg/botAction deferred by AntiFlood on $to ("
        . scalar(@{ $q->{items} }) . " queued)");
    Mediabot::Helpers::_arm_flood_drain($self, $to);
    return 1;
}

sub _arm_flood_drain {
    my ($self, $to) = @_;
    my $q = $self->{_flood_outq}{$to} or return;
    return if $q->{armed};

    my $loop = eval { $self->getLoop } // $self->{loop};
    unless ($loop) {
        # Pas de boucle (tests unitaires, arret) : la file reste, un prochain
        # envoi reel la rearmera.
        return;
    }
    $q->{armed} = 1;
    my $started = eval {
        Mediabot::IRC::Timer::countdown(
            loop => $loop,
            delay => 2,
            on_expire => sub { Mediabot::Helpers::_drain_flood_queue($self, $to) },
        );
        1;
    };
    unless ($started) {
        my $error = $@;
        $q->{armed} = 0;
        die $error;
    }
    return 1;
}

sub _drain_flood_queue {
    my ($self, $to) = @_;
    my $q = $self->{_flood_outq}{$to} or return;
    $q->{armed} = 0;

    my $item = shift @{ $q->{items} };
    my $sent = eval {
        if ($item) {
            my ($kind, $msg) = @$item;
            local $self->{_flood_draining} = 1;
            if ($kind eq 'action') { botAction($self, $to, $msg) }
            else                   { botPrivmsg($self, $to, $msg) }
        }
        1;
    };
    my $send_error = $@;
    # A send exception must not strand the rest of the queue. Do not retry the
    # attempted item: the transport may have sent it before raising the error.
    my $rearmed = eval {
        Mediabot::Helpers::_arm_flood_drain($self, $to) if @{ $q->{items} };
        1;
    };
    my $arm_error = $@;
    die $send_error unless $sent;
    die $arm_error unless $rearmed;
    return 1;
}

1;
