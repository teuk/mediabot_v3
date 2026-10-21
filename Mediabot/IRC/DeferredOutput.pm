package Mediabot::IRC::DeferredOutput;

use strict;
use warnings;
use utf8;
use IO::Async::Timer::Countdown;

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
    my $timer = IO::Async::Timer::Countdown->new(
        delay     => 2,
        on_expire => sub { Mediabot::Helpers::_drain_flood_queue($self, $to) },
    );
    $q->{armed} = 1;
    $loop->add($timer);
    $timer->start;
    return 1;
}

sub _drain_flood_queue {
    my ($self, $to) = @_;
    my $q = $self->{_flood_outq}{$to} or return;
    $q->{armed} = 0;

    my $item = shift @{ $q->{items} };
    if ($item) {
        my ($kind, $msg) = @$item;
        local $self->{_flood_draining} = 1;
        if ($kind eq 'action') { botAction($self, $to, $msg) }
        else                   { botPrivmsg($self, $to, $msg) }
    }
    Mediabot::Helpers::_arm_flood_drain($self, $to) if @{ $q->{items} };
    return 1;
}

1;
