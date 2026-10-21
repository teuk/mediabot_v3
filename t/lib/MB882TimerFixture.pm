package MB882TimerFixture;
use strict;
use warnings;
use Scalar::Util ();
our $new_error;

package MB882::Timer;
sub new {
    my ($class, %args) = @_;
    die $MB882TimerFixture::new_error if defined $MB882TimerFixture::new_error;
    bless \%args, $class;
}
sub start {
    my ($self) = @_;
    die $self->{loop}{error} if ($self->{loop}{stage} // '') eq 'start';
    push @{$self->{loop}{pending}}, $self;
    1;
}
sub stop {$_[0]{stopped}++; 1}

package MB882::Loop;
sub new {bless {pending => [], attached => {}, callbacks => [], probes => [], delays => []}, shift}
sub add {
    my ($self, $timer) = @_;
    push @{$self->{callbacks}}, $timer->{on_expire};
    push @{$self->{probes}}, $timer;
    Scalar::Util::weaken($self->{probes}[-1]);
    die $self->{error} if ($self->{stage} // '') eq 'add-before';
    $timer->{loop} = $self;
    $self->{attached}{Scalar::Util::refaddr($timer)} = $timer;
    push @{$self->{delays}}, $timer->{delay};
    die $self->{error} if ($self->{stage} // '') eq 'add-after';
    1;
}
sub remove {
    my ($self, $timer) = @_;
    my $id = Scalar::Util::refaddr($timer);
    delete $self->{attached}{$id};
    @{$self->{pending}} = grep {Scalar::Util::refaddr($_) != $id} @{$self->{pending}};
    delete $timer->{loop};
    1;
}
sub tick {my $timer = shift @{$_[0]{pending}}; $timer->{on_expire}->($timer) if $timer; 1}
sub drain {my ($self) = @_; my $n = 0; while (@{$self->{pending}}) {die 'fixture loop did not finish' if ++$n > 100; $self->tick} 1}

package MB882::Bot;
sub getLoop {$_[0]{loop}}
package MB882::Logger;
sub log {push @{$_[0]{rows}}, [$_[1], $_[2]]; 1}
1;
