#!/usr/bin/env perl
# Offline characterization of the installed IRC transport. No TCP, DNS or login.
use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);
use IO::Async::Loop;
use IO::Async::Stream;
use Net::Async::IRC;
use JSON::PP;
use Getopt::Long qw(GetOptions);
my $mediabot_transport = 0;
GetOptions('mediabot' => \$mediabot_transport) && !@ARGV
    or die "Usage: perl -I. tools/dev/irc-control-probe.pl [--mediabot]\n";
my $class = 'Net::Async::IRC';
if ($mediabot_transport) {
    require Mediabot::IRC::Transport;
    $class = 'Mediabot::IRC::Transport';
}

local $SIG{ALRM} = sub { die "Offline transport probe exceeded 10 seconds\n" };
alarm 10;
socketpair(my $client, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
setsockopt($client, SOL_SOCKET, SO_SNDBUF, pack('i', 4096))
    or die "SO_SNDBUF: $!";
my $loop = IO::Async::Loop->new;
my $irc = $class->new(handle => $client);
$loop->add($irc);
my $count = 256;
my @expected;
my $payload_flushed;
for my $i (1 .. $count) {
    my $text = sprintf('%04d ', $i) . ('x' x 380);
    push @expected, "PRIVMSG #probe :$text";
    if ($i == $count) {
        $payload_flushed = $irc->do_PRIVMSG(target => '#probe', text => $text);
    } else {
        $irc->do_PRIVMSG(target => '#probe', text => $text);
    }
}
# Nothing has consumed the peer socket. The real stream must have unsent work.
my $pending = !$payload_flushed->is_ready;
die "Probe did not establish a transport backlog\n" unless $pending;
my $ping = "PING :mb1268-offline\r\n";
$irc->on_read(\$ping, 0); # actual parser and inherited automatic PONG handler
$irc->send_message('MODE', undef, '#probe', '+m');
my $control_flushed = $irc->send_message('NOTICE', undef, 'Probe', 'mb1268-end');
die "Control flush completed before draining the backlog\n" if $control_flushed->is_ready;
my @lines;
my $done = $loop->new_future;
my $reader = IO::Async::Stream->new(
    handle => $peer,
    on_read => sub {
        my ($self, $buffer, $eof) = @_;
        while ($$buffer =~ s/^(.*?)\r\n//) {
            push @lines, $1;
            $done->done if $1 =~ /^NOTICE Probe :?mb1268-end$/ && !$done->is_ready;
        }
        die "Unexpected local EOF\n" if $eof && !$done->is_ready;
        return 0;
    },
);
$loop->add($reader);
$loop->await($done);
die "Write completion was not acknowledged\n"
    unless $payload_flushed->is_done && $control_flushed->is_done;
my @payload = grep { /^PRIVMSG / } @lines;
die "Payload lost, duplicated or reordered\n"
    unless join("\n", @payload) eq join("\n", @expected);
my @pong = grep { $lines[$_] =~ /^PONG :?mb1268-offline$/ } 0 .. $#lines;
my @mode = grep { $lines[$_] eq 'MODE #probe +m' } 0 .. $#lines;
die "Expected exactly one PONG and MODE\n" unless @pong == 1 && @mode == 1;
die "Unexpected output frames\n" unless @lines == $count + 3;
my $before_pong = grep { /^PRIVMSG / } @lines[0 .. $pong[0]];
my $before_mode = grep { /^PRIVMSG / } @lines[0 .. $mode[0]];
$irc->close_now;
$reader->close_now;
alarm 0;
print JSON::PP->new->canonical->pretty->encode({
    transport => $class,
    net_async_irc => "$Net::Async::IRC::VERSION",
    protocol_irc => "$Protocol::IRC::VERSION",
    io_async_stream => "$IO::Async::Stream::VERSION",
    preview_frames => $count, pending_before_control => $pending ? 1 : 0,
    preview_frames_before_pong => $before_pong,
    preview_frames_before_mode => $before_mode,
    automatic_pong => 1, payload_intact => 1, write_futures_completed => 1,
    scope => 'local AF_UNIX socket pair; no server or Mediabot runtime',
});
