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
    return $context->reply(
        $invocation,
        'Hello from a tiny, capability-scoped API v3 plugin.'
    );
}

1;
