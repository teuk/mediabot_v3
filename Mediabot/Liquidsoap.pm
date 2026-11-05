package Mediabot::Liquidsoap;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

=head1 NAME

Mediabot::Liquidsoap - Small Liquidsoap telnet client for Mediabot.

=head1 DESCRIPTION

This module talks to the local Liquidsoap telnet server.

It intentionally stays small and boring:

  * connect to host/port
  * send one command
  * send quit
  * collect the response

Use the queue namespace actually exposed by the command server, configured
through LIQUIDSOAP_QUEUE_ID. A source ID written in the Liquidsoap script does
not by itself prove the effective control namespace. Supported queue commands
are push, queue, skip and flush_and_skip; no status command is assumed.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        host     => $args{host}     || '127.0.0.1',
        port     => $args{port}     || 1235,
        queue_id => $args{queue_id} || 'mediabot_queue',
        timeout  => $args{timeout}  || 5,
        logger   => $args{logger},
    };

    return bless $self, $class;
}

sub _log {
    my ($self, $level, $msg) = @_;
    return unless defined $msg && $msg ne '';
    return unless $self->{logger} && $self->{logger}->can('log');
    $self->{logger}->log($level, "Liquidsoap: $msg");
}

sub command {
    my ($self, $command) = @_;

    return (0, 'empty Liquidsoap command')
        unless defined($command) && $command ne '';

    # mb363-B1: the Liquidsoap telnet protocol is line-oriented. A CR/LF in a
    # queue id, URI or future caller-supplied command would terminate the
    # intended line and inject another command before the automatic `quit`.
    # Reject the whole request before opening a socket; do not silently strip
    # bytes and accidentally queue a path different from the one requested.
    return (0, 'unsafe Liquidsoap command: CR, LF and NUL are not allowed')
        if $command =~ /[\r\n\x00]/;

    my $host    = $self->{host};
    my $port    = $self->{port};
    my $timeout = $self->{timeout};

    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    );

    unless ($sock) {
        my $err = "connect failed to $host:$port: $!";
        $self->_log(1, $err);
        return (0, $err);
    }

    $sock->autoflush(1);

    # A peer can close between connect and write. Return the existing write
    # failure instead of letting SIGPIPE terminate the calling process.
    local $SIG{PIPE} = 'IGNORE';
    my $payload = $command . "\nquit\n";
    unless (print {$sock} $payload) {
        my $err = "write failed to $host:$port: $!";
        close $sock;
        $self->_log(1, $err);
        return (0, $err);
    }

    my ($response, $err) = _read_response($sock, $timeout);
    close $sock;
    if (defined $err) {
        $self->_log(1, "read failed from $host:$port: $err");
        return (0, "read failed from $host:$port: $err");
    }

    return _decode_response($response);
}

sub _read_response {
    my ($sock, $timeout) = @_;
    # One deadline for the whole frame. Do not use the process-wide alarm:
    # it can belong to a caller, and the read timeout can be fractional.
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + $timeout;
    my $readable = IO::Select->new($sock);
    my $response = '';
    while (1) {
        my $left = $deadline - clock_gettime(CLOCK_MONOTONIC);
        return (undef, 'read timeout') if $left <= 0;
        local $! = 0;
        unless ($readable->can_read($left)) {
            next if $!{EINTR};
            return (undef, $! ? "select failed: $!" : 'read timeout');
        }
        my $count = sysread($sock, my $chunk, 4096);
        unless (defined $count) {
            next if $!{EINTR};
            return (undef, "read failed: $!");
        }
        last unless $count;
        $response .= $chunk;
        return (undef, 'response too large') if length($response) > 65536;
        # MB734: END terminates this command's response. Do not wait for EOF
        # or consume the quit response as the result of the command.
        last if $response =~ /(?:\A|\n)END\r?\n/;
    }
    return ($response, undef);
}

sub _decode_response {
    my ($response) = @_;
    $response //= '';
    $response =~ s/\r//g;
    my ($body) = $response =~ /\A(.*?)^END[ \t]*$/ms;
    return (0, 'incomplete Liquidsoap response') unless defined $body;
    $body =~ s/\A\s+|\s+\z//g;
    return (0, $body) if $body =~ /^(?:ERROR\b|Unknown command\b|No such command\b|Invalid command\b)/mi;
    return (1, $body);
}

sub push {
    my ($self, $uri) = @_;

    return (0, 'empty URI')
        unless defined($uri) && $uri ne '';

    my $queue_id = $self->{queue_id} || 'mediabot_queue';
    my ($ok, $response) = $self->command("$queue_id.push $uri");
    return ($ok, $response) unless $ok;
    # A push acknowledgement is a non-negative request ID, not arbitrary text.
    return (0, 'Liquidsoap did not return a request ID')
        unless defined($response) && $response =~ /\A\d+\z/;
    return (1, $response);
}

sub queue {
    my ($self) = @_;

    my $queue_id = $self->{queue_id} || 'mediabot_queue';
    return $self->command("$queue_id.queue");
}

sub skip {
    my ($self) = @_;

    my $queue_id = $self->{queue_id} || 'mediabot_queue';
    return $self->command("$queue_id.skip");
}

sub flush_and_skip {
    my ($self) = @_;

    my $queue_id = $self->{queue_id} || 'mediabot_queue';
    return $self->command("$queue_id.flush_and_skip");
}

1;
