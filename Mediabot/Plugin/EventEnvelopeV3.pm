package Mediabot::Plugin::EventEnvelopeV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _copy_value {
    my ($value) = @_;
    return $value unless ref($value);
    return [ map { _copy_value($_) } @$value ] if ref($value) eq 'ARRAY';
    return { map { $_ => _copy_value($value->{$_}) } keys %$value }
        if ref($value) eq 'HASH';
    return undef;
}

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub new {
    my ($class, %args) = @_;

    die "EventEnvelopeV3: invalid event name\n"
        unless defined($args{name}) && !ref($args{name})
            && $args{name} =~ /\A[a-z][a-z0-9_.-]{0,63}\z/;
    die "EventEnvelopeV3: invalid event version\n"
        unless defined($args{version}) && !ref($args{version})
            && "$args{version}" =~ /\A[1-9][0-9]*\z/;
    die "EventEnvelopeV3: event data must be an object\n"
        unless ref($args{data}) eq 'HASH';

    my $occurred_at = $args{occurred_at};
    $occurred_at = time()
        unless defined($occurred_at) && !ref($occurred_at)
            && "$occurred_at" =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    my $activation = defined($args{activation}) ? $args{activation} : 'off';
    die "EventEnvelopeV3: invalid activation mode\n"
        unless !ref($activation) && $activation =~ /\A(?:off|observe|on)\z/;

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        name        => "$args{name}",
        version     => int($args{version}),
        occurred_at => 0 + $occurred_at,
        data        => _copy_value($args{data}),
        policy_channel => defined($args{policy_channel}) && !ref($args{policy_channel})
            ? "$args{policy_channel}" : '',
        activation => "$activation",
        config     => ref($args{config}) eq 'HASH'
            ? _copy_value($args{config}) : {},
    };
    return $self;
}

sub name        { _state($_[0])->{name} }
sub version     { _state($_[0])->{version} }
sub occurred_at { _state($_[0])->{occurred_at} }
sub policy_channel { _state($_[0])->{policy_channel} }
sub activation_mode { _state($_[0])->{activation} }

sub data {
    my ($self) = @_;
    return _copy_value(_state($self)->{data});
}

sub get {
    my ($self, $key) = @_;
    return undef unless defined($key) && !ref($key);
    return _copy_value(_state($self)->{data}{$key});
}

sub config {
    my ($self) = @_;
    return _copy_value(_state($self)->{config});
}

sub config_value {
    my ($self, $key) = @_;
    return undef unless defined($key) && !ref($key);
    return _copy_value(_state($self)->{config}{$key});
}

sub with_policy {
    my ($self, %args) = @_;
    my $state = _state($self);
    return ref($self)->new(
        name           => $state->{name},
        version        => $state->{version},
        occurred_at    => $state->{occurred_at},
        data           => $state->{data},
        policy_channel => $args{channel},
        activation     => $args{mode},
        config         => $args{config},
    );
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
