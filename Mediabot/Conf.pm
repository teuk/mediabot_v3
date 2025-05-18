package Mediabot::Conf;

use strict;
use warnings;

sub new {
    my ($class, $conf_ref) = @_;
    my $self = {
        _conf => $conf_ref || {},
    };
    bless $self, $class;
    return $self;
}

sub get {
    my ($self, $key) = @_;
    return $self->{_conf}{$key};
}

sub set {
    my ($self, $key, $value) = @_;
    $self->{_conf}{$key} = $value;
}

sub all {
    my ($self) = @_;
    return %{ $self->{_conf} };
}

1;

__END__

=pod

=head1 NAME

Mediabot::Conf - Simple configuration wrapper for mediabot

=head1 SYNOPSIS

    use Mediabot::Conf;

    my $conf = Mediabot::Conf->new({ foo => 'bar' });
    my $val = $conf->get('foo');
    $conf->set('baz', 'qux');

=head1 METHODS

=head2 new($hashref)

Creates a new config object from a hash reference.

=head2 get($key)

Returns the value for the given key.

=head2 set($key, $value)

Sets the value for a given key.

=head2 all

Returns the entire configuration hash.

=cut
