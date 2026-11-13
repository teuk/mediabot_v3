package Mediabot::IRC::Recovery;
use strict;
use warnings;
use Scalar::Util qw(refaddr);

# Native pongtime starts at enqueue, not at flush. This is an exchange/stall
# deadline, never proof that the peer ignored a transmitted PING.
sub ping_timeout {
    my ($bot, $transport) = @_;
    return 0 unless $bot && ref($transport) && ref($bot->{irc})
        && refaddr($transport) == refaddr($bot->{irc});
    return 0 if $bot->getQuit;
    return 0 if $transport->{_keepalive_recovery_started};
    $transport->{_keepalive_recovery_started} = 1;

    # Publish recovery before closing: close/receipt callbacks may reenter or
    # install a successor. Never write lifecycle state after those callbacks.
    $bot->{irc_reconnect_requested} = 1;
    my $closed = eval { $transport->close_now; 1 };
    eval {
        $bot->{logger}->log(1, $closed
            ? 'IRC keepalive exchange deadline exceeded (includes local output wait); transport retired, reconnect requested'
            : 'IRC keepalive exchange deadline exceeded (includes local output wait); transport close failed, reconnect requested');
    } if $bot->{logger};
    return 1;
}
1;
