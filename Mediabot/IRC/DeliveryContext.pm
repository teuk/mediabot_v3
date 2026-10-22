package Mediabot::IRC::DeliveryContext;

use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(refaddr);

our @EXPORT_OK = qw(capture_delivery_context delivery_context_current);

# Bind delayed output to its transport and, when available, the existing
# joined-channel generation. Callers retain their own capability checks.
sub capture_delivery_context {
    my ($self, $channel) = @_;
    my $binding = { irc => $self->{irc} };
    if (defined($channel) && $channel =~ /^#/ && $self->{wit_runtime_state}) {
        $binding->{runtime} = $self->{wit_runtime_state};
        $binding->{channel} = $channel;
        $binding->{generation} = eval {
            $binding->{runtime}->capture_generation($channel);
        };
    }
    return $binding;
}

sub delivery_context_current {
    my ($self, $binding) = @_;
    return 0 if eval { $self->getQuit };
    my $current = $self->{irc};
    if (defined($binding->{irc})) {
        return 0 unless ref($current) && ref($binding->{irc})
            && refaddr($current) == refaddr($binding->{irc})
            && eval { $current->is_connected };
    }
    else {
        # Preserve offline fixture callers, but never attach their old work
        # to a connection that appeared after submission.
        return 0 if defined $current;
    }
    if ($binding->{runtime}) {
        my $state = $self->{wit_runtime_state};
        return 0 unless ref($state) && refaddr($state) == refaddr($binding->{runtime});
        my $expected = $binding->{generation};
        my $generation = eval { $state->capture_generation($binding->{channel}) };
        return 0 unless defined($expected) && !ref($expected) && "$expected" =~ /\A[1-9][0-9]*\z/
            && defined($generation) && !ref($generation) && "$generation" eq "$expected";
    }
    return 1;
}

1;
