package Mediabot::Liquidsoap;

use strict;
use warnings;
use IO::Socket::INET;

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

    my $payload = $command . "\nquit\n";
    unless (print {$sock} $payload) {
        my $err = "write failed to $host:$port: $!";
        close $sock;
        $self->_log(1, $err);
        return (0, $err);
    }

    my $response = '';
    eval {
        local $SIG{ALRM} = sub { die "read timeout\n" };
        alarm($timeout);

        while (1) {
            my $count = sysread($sock, my $chunk, 4096);
            die "read failed: $!\n" unless defined $count;
            last unless $count;
            $response .= $chunk;
            die "response too large\n" if length($response) > 65536;
            # MB734: END terminates this command's response. Waiting for EOF
            # can mistake a later quit response for the command's result.
            last if $response =~ /(?:\A|\n)END\r?\n/;
        }

        alarm(0);
        1;
    } or do {
        alarm(0);
        my $err = $@ || 'unknown read error';
        chomp $err;
        close $sock;
        $self->_log(1, "read failed from $host:$port: $err");
        return (0, "read failed from $host:$port: $err");
    };

    close $sock;

    return _decode_response($response);
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
