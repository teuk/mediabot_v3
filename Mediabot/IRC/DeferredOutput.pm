package Mediabot::IRC::DeferredOutput;

use strict;
use warnings;
use utf8;
use Scalar::Util qw(refaddr weaken);
use Mediabot::IRC::Timer ();

# Existing bounded AntiFlood queue. Keep state keys, head reinsertion, timing
# and dynamic Helpers callbacks; this is separate from explicit paced batches.
sub botPrivmsg { return Mediabot::Helpers::botPrivmsg(@_); }
sub botAction { return Mediabot::Helpers::botAction(@_); }

sub _defer_flooded_send {
    my ($self, $kind, $to, $msg, $send_options) = @_;

    my $q = $self->{_flood_outq}{$to} //= { items => [], armed => 0 };
    # Queue physical IRC lines so an oversized response can make progress
    # even when its total cost exceeds the channel or connection allowance.
    my @chunks = Mediabot::Helpers::_split_text_for_irc($msg, $kind eq 'action' ? 391 : 400);
    @chunks = ($msg) unless @chunks;
    my @items;
    for my $chunk (@chunks) {
        my $item = [$kind, $chunk];
        push @$item, {ping_started_at => $send_options->{ping_started_at}}
            if ref($send_options) eq 'HASH' && defined($send_options->{ping_started_at})
                && !ref($send_options->{ping_started_at});
        # Keep the whole response for badword checks across chunk boundaries.
        my $source = ref($send_options) eq 'HASH' ? $send_options->{flood_source_text} : undef;
        $source = $msg if @chunks > 1 && !defined($source);
        if (defined($source) && !ref($source)) {
            $item->[2] ||= {};
            $item->[2]{flood_source_text} = $source;
        }
        push @items, $item;
    }
    if (@{$q->{items}} + @items > 30) {
        $self->{logger}->log(3,
            "flood queue full on $to — dropping one $kind message");
        return undef;
    }
    if ((refaddr($self->{_flood_draining}) // 0) == refaddr($q)) {
        # Preserve line order ahead of later replies, including a legacy
        # unsplit item already queued before this code was loaded.
        unshift @{$q->{items}}, @items;
        return undef;
    }
    push @{$q->{items}}, @items;
    $self->{logger}->log(4, "botPrivmsg/botAction deferred by AntiFlood on $to ("
        . scalar(@{ $q->{items} }) . " queued)");
    Mediabot::Helpers::_arm_flood_drain($self, $to);
    return 1;
}

sub _flood_queue_current {
    my ($self, $to, $expected) = @_;
    return 0 unless $expected;
    my $queues = $self->{_flood_outq} or return 0;
    my $current = $queues->{$to} or return 0;
    return refaddr($current) == refaddr($expected);
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
    my $expected = $q;
    weaken($expected);
    my $started = eval {
        Mediabot::IRC::Timer::countdown(
            loop => $loop,
            delay => 2,
            on_expire => sub {
                return unless _flood_queue_current($self, $to, $expected);
                Mediabot::Helpers::_drain_flood_queue($self, $to);
            },
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
            my ($kind, $msg, $send_options) = @$item;
            local $self->{_flood_draining} = $q;
            if ($kind eq 'action') { botAction($self, $to, $msg, $send_options) }
            else                   { botPrivmsg($self, $to, $msg, $send_options) }
        }
        1;
    };
    my $send_error = $@;
    # A send exception must not strand the rest of the queue. Do not retry the
    # attempted item: the transport may have sent it before raising the error.
    my $rearmed = eval {
        Mediabot::Helpers::_arm_flood_drain($self, $to)
            if @{ $q->{items} } && _flood_queue_current($self, $to, $q);
        1;
    };
    my $arm_error = $@;
    die $send_error unless $sent;
    die $arm_error unless $rearmed;
    return 1;
}

1;
