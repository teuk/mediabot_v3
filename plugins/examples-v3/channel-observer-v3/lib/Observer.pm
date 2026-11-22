package Mediabot::Plugin::V3::WorkshopObserver;

use strict;
use warnings;
use utf8;

sub new {
    my ($class) = @_;
    return bless { last_join => {} }, $class;
}

sub event_join {
    my ($self, $context, $event) = @_;
    return if $event->get('is_self');
    my $nick = $event->get('nick');
    my $greeting = $event->config_value('greeting');
    my $mode = $event->activation_mode;
    $self->{last_join}{ $event->policy_channel } = "$greeting, $nick [$mode]";
    return;
}

sub command_last_join {
    my ($self, $context, $invocation) = @_;
    my $last = $self->{last_join}{ $invocation->channel } // "Aucune arrivée observée.";
    return $context->reply($invocation, $last);
}

sub event_word {
    my ($self, $context, $event, $invocation) = @_;
    return $context->reply($invocation, 'Mot observé : ' . $event->get('word'));
}

1;
