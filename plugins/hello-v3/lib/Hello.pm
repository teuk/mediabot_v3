package Mediabot::Plugin::V3::Hello;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    die "hello-v3: PluginContext is required\n"
        unless ref($args{context})
            && eval { $args{context}->isa('Mediabot::PluginContext') };
    return bless {
        context => $args{context},
        started => 0,
        minutes_observed => 0,
        heartbeats       => 0,
        commands_observed => 0,
        observed_channels => [],
        observed_modes    => [],
    }, $class;
}

sub start {
    my ($self, %args) = @_;
    $self->{started} = 1;
    return 1;
}

sub stop {
    my ($self, %args) = @_;
    $self->{started} = 0;
    return 1;
}

sub command_hello {
    my ($self, $context, $invocation) = @_;
    return unless $self->{started};
    $self->{commands_observed}++;
    push @{ $self->{observed_modes} }, $invocation->activation_mode;
    my $greeting = $invocation->config_value('greeting');
    my $mention = $invocation->config_value('mention_nick')
        ? $invocation->nick . ': ' : '';
    my $enthusiasm = $invocation->config_value('enthusiasm') // 0;
    return $context->reply($invocation,
        $mention . $greeting . ('!' x $enthusiasm));
}

sub event_minute {
    my ($self, $context, $event) = @_;
    return unless $self->{started};
    $self->{minutes_observed}++;
    push @{ $self->{observed_channels} }, $event->policy_channel;
    push @{ $self->{observed_modes} }, $event->activation_mode;
    return 1;
}

sub job_heartbeat {
    my ($self, $context, $job) = @_;
    return unless $self->{started};
    $self->{heartbeats}++;
    push @{ $self->{observed_channels} }, $job->channel;
    push @{ $self->{observed_modes} }, $job->activation_mode;
    return 1;
}

1;
