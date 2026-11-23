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

sub job_pulse {
    my ($self, $context, $job) = @_;
    my $greeting = $job->config_value('greeting');
    return $context->channel_message($job, "$greeting, passage " . $job->sequence);
}

sub command_remember {
    my ($self, $context, $invocation) = @_;
    my ($scope, $value) = @{ $invocation->args };
    die "Expected a global or channel value\n"
        unless defined($value) && ($scope eq 'global' || $scope eq 'channel');
    my ($read, $write) = $scope eq 'global'
        ? qw(storage_snapshot storage_commit)
        : qw(channel_storage_snapshot channel_storage_commit);
    my $snapshot = $context->$read($invocation);
    my $result = $context->$write($invocation,
        expected_revision => $snapshot->{revision}, changes => {note => $value});
    return if $result->{ok} || ($invocation->activation_mode eq 'observe'
        && ($result->{error} // '') eq 'observe');
    die "Storage commit failed: " . ($result->{error} // 'unknown') . "\n";
}

1;
