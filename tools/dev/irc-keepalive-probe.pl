#!/usr/bin/env perl
# Offline keepalive characterization. No TCP, DNS, configuration or login.
use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);
use IO::Handle;
use IO::Async::Loop;
use IO::Async::Stream;
use Net::Async::IRC;
use JSON::PP;
use Getopt::Long qw(GetOptions);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

my $mediabot = 0;
GetOptions('mediabot' => \$mediabot) && !@ARGV
    or die "Usage: perl -I. tools/dev/irc-keepalive-probe.pl [--mediabot]\n";
my $class = 'Net::Async::IRC';
if ($mediabot) {
    require Mediabot::IRC::Transport;
    $class = 'Mediabot::IRC::Transport';
}
{
    package MB1270ObservedTransport;
    use mro 'c3';
    our @ISA;
    # Observe the public write receipt without altering its data or scheduling.
    sub write {
        my ($self, $data, @args) = @_;
        my $receipt = $self->SUPER::write($data, @args);
        $self->{probe_ping_receipt} = $receipt
            if defined($data) && !ref($data) && $data =~ /\APING /;
        return $receipt;
    }
}
@MB1270ObservedTransport::ISA = ($class);
local $SIG{ALRM} = sub { die "Offline keepalive probe exceeded 10 seconds\n" };
alarm 10;

sub pair {
    my (%args) = @_;
    socketpair(my $client, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    setsockopt($client, SOL_SOCKET, SO_SNDBUF, pack('i',4096)) or die "SO_SNDBUF: $!";
    $peer->blocking(0);
    my $loop = IO::Async::Loop->really_new;
    my $irc = MB1270ObservedTransport->new(
        handle => $client, pingtime => 0.01, pongtime => 0.03, %args);
    $loop->add($irc);
    # Native on_read arms the real idle timer; no timer method is replaced.
    my $input = '';
    $irc->on_read(\$input, 0);
    return ($loop, $irc, $peer);
}

my %blocked;
{
    my $timeout;
    my ($loop,$irc,$peer) = pair(on_ping_timeout => sub { $timeout->done unless $timeout->is_ready });
    $timeout = $loop->new_future;
    my @expected;
    my $tail;
    for my $i (1..256) {
        my $text = sprintf('%04d ', $i) . ('x' x 380);
        push @expected, "PRIVMSG #probe :$text";
        $tail = $irc->do_PRIVMSG(target => '#probe', text => $text);
    }
    $loop->await($timeout); # Peer deliberately does not read during this phase.
    my $ping = $irc->{probe_ping_receipt} or die "Timeout without an observed PING write\n";
    $blocked{ping_flush_complete_at_timeout} = $ping->is_done ? 1 : 0;
    $blocked{payload_flush_complete_at_timeout} = $tail->is_done ? 1 : 0;
    # Inspect only bytes already accepted by the socket, before another loop turn.
    my $wire = '';
    while (1) {
        my $n = sysread($peer, my $chunk, 65536);
        if (!defined $n) {
            next if $! == EINTR;
            last if $! == EAGAIN || $! == EWOULDBLOCK;
            die "sysread: $!";
        }
        die "Unexpected EOF before recovery\n" unless $n;
        $wire .= $chunk;
    }
    $blocked{ping_visible_at_timeout} = $wire =~ /(?:\A|\r\n)PING [^\r\n]*\r\n/ ? 1 : 0;
    my $end = $irc->send_message('NOTICE', undef, 'Probe', 'keepalive-end');
    my $done = $loop->new_future;
    my $reader = IO::Async::Stream->new(handle => $peer, on_read => sub {
        my ($stream,$buffer,$eof) = @_;
        $wire .= $$buffer; $$buffer = '';
        $done->done if $wire =~ /NOTICE Probe :?keepalive-end\r\n\z/ && !$done->is_ready;
        die "Unexpected EOF before complete recovery\n" if $eof && !$done->is_ready;
        return 0;
    });
    $loop->add($reader);
    $loop->await($done);
    my @lines = split /\r\n/, $wire;
    my @payload = grep { /^PRIVMSG / } @lines;
    die "Recovery lost or reordered payload\n" unless join("\n",@payload) eq join("\n",@expected);
    die "Recovery did not flush every observed write\n" unless $ping->is_done && $tail->is_done && $end->is_done;
    die "Unexpected recovered frames\n" unless @lines == 258 && (grep { /^PING / } @lines) == 1;
    die "Keepalive no longer follows the ordinary backlog\n" unless $lines[-2] =~ /^PING /;
    $blocked{recovered_payload_frames} = scalar @payload;
    $blocked{recovered_write_receipts} = 1;
    $irc->close_now; $reader->close_now;
}

my %responsive;
{
    my ($done,$timeouts);
    my ($loop,$irc,$peer) = pair(
        pongtime => 2,
        on_ping_timeout => sub { $timeouts++; die "Responsive peer timed out\n" },
        on_pong_reply => sub { $done->done unless $done->is_ready },
    );
    $done = $loop->new_future;
    my $pings = 0;
    my $reader = IO::Async::Stream->new(handle => $peer, on_read => sub {
        my ($stream,$buffer,$eof) = @_;
        while ($$buffer =~ s/^(.*?)\r\n//) {
            my $line = $1;
            die "Unexpected responsive frame\n" unless $line =~ /^PING (.+)$/;
            $pings++;
            $stream->write(":probe PONG Probe $1\r\n");
        }
        die "Unexpected responsive EOF\n" if $eof;
        return 0;
    });
    $loop->add($reader);
    $loop->await($done);
    die "Expected one flushed keepalive\n" unless $pings == 1 && $irc->{probe_ping_receipt}->is_done;
    %responsive = (pings => $pings, pong_received => 1, timeout_count => $timeouts || 0);
    $irc->close_now; $reader->close_now;
}
alarm 0;
print JSON::PP->new->canonical->pretty->encode({
    transport => $class,
    net_async_irc => "$Net::Async::IRC::VERSION",
    protocol_irc => "$Protocol::IRC::VERSION",
    io_async_stream => "$IO::Async::Stream::VERSION",
    blocked_peer => \%blocked, responsive_peer => \%responsive,
    pingtime_s => 0.01, blocked_pongtime_s => 0.03, responsive_pongtime_s => 2,
    scope => 'local AF_UNIX socket pairs; accelerated native timers; no server or Mediabot runtime',
});
