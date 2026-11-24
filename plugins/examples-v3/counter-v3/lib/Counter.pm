package Mediabot::Plugin::V3::TutorialCounter;

use strict;
use warnings;
use utf8;

my $max_count = 999999;

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

sub command_count {
    my ($self, $context, $invocation) = @_;
    my $args = $invocation->args;
    if (@$args > 1 || (@$args && $args->[0] ne '+1')) {
        return $context->reply($invocation, 'Usage : v3compteur [+1]');
    }

    my $snapshot = $context->channel_storage_snapshot($invocation);
    my $count = $snapshot->{values}{count} // 0;
    die "Invalid stored counter\n" unless "$count" =~ /\A(?:0|[1-9][0-9]{0,5})\z/;

    if (@$args) {
        return $context->reply($invocation, 'Compteur au maximum.') if $count == $max_count;
        my $next_count = $count + 1;
        my $result = $context->channel_storage_commit($invocation,
            expected_revision => $snapshot->{revision},
            changes => {count => $next_count},
        );
        unless ($result->{ok}) {
            my $error = $result->{error} // 'unknown';
            return if $error eq 'observe' && $invocation->activation_mode eq 'observe';
            return $context->reply($invocation, 'Le compteur a changé. Réessaie.')
                if $error eq 'conflict';
            die "Counter commit failed: $error\n";
        }
        $count = $next_count;
    }

    return $context->reply($invocation, "Compteur du canal : $count.");
}

1;
