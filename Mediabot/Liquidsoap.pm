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

The first radio integration step only uses the commands already confirmed
on the dev Liquidsoap instance:

  * mediabot_queue.push <uri>
  * mediabot_queue.queue
  * mediabot_queue.skip
  * mediabot_queue.flush_and_skip

There is no mediabot_queue.status command in the tested Liquidsoap setup.

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

        while (defined(my $line = <$sock>)) {
            $response .= $line;
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

    $response =~ s/\r//g;
    $response =~ s/\A\s+|\s+\z//g;

    return (1, $response);
}

sub push {
    my ($self, $uri) = @_;

    return (0, 'empty URI')
        unless defined($uri) && $uri ne '';

    my $queue_id = $self->{queue_id} || 'mediabot_queue';
    return $self->command("$queue_id.push $uri");
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
