package Mediabot::Plugin::JobInvocationV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub new {
    my ($class, %args) = @_;

    die "JobInvocationV3: invalid job name\n"
        unless defined($args{name}) && !ref($args{name})
            && $args{name} =~ /\A[a-z][a-z0-9_.-]{0,47}\z/;
    die "JobInvocationV3: invalid sequence\n"
        unless defined($args{sequence}) && !ref($args{sequence})
            && "$args{sequence}" =~ /\A[1-9][0-9]*\z/;

    die "JobInvocationV3: invalid fired_at timestamp\n"
        if defined($args{fired_at})
            && (ref($args{fired_at})
                || "$args{fired_at}" !~ /\A[0-9]+(?:\.[0-9]+)?\z/);
    die "JobInvocationV3: invalid scheduled_at timestamp\n"
        if defined($args{scheduled_at})
            && (ref($args{scheduled_at})
                || "$args{scheduled_at}" !~ /\A[0-9]+(?:\.[0-9]+)?\z/);

    my $fired_at = defined($args{fired_at})
        ? 0 + $args{fired_at} : time();
    my $scheduled_at = defined($args{scheduled_at})
        ? 0 + $args{scheduled_at} : $fired_at;

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        name         => "$args{name}",
        sequence     => int($args{sequence}),
        scheduled_at => $scheduled_at,
        fired_at     => $fired_at,
    };
    return $self;
}

sub name         { _state($_[0])->{name} }
sub sequence     { _state($_[0])->{sequence} }
sub scheduled_at { _state($_[0])->{scheduled_at} }
sub fired_at     { _state($_[0])->{fired_at} }

sub lateness_seconds {
    my ($self) = @_;
    my $state = _state($self);
    my $late = $state->{fired_at} - $state->{scheduled_at};
    return $late > 0 ? $late : 0;
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
