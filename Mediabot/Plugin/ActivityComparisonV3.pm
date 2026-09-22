package Mediabot::Plugin::ActivityComparisonV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state { $STATE{ refaddr($_[0]) } }

sub _nick {
    my ($value, $field) = @_;
    die "ActivityComparisonV3: $field must be a bounded nickname\n"
        unless defined($value) && !ref($value)
            && length($value) >= 1 && length($value) <= 64
            && $value =~ /\A[^\x00-\x20\x7f,:]+\z/;
    return lc "$value";
}

sub _uint {
    my ($value, $field) = @_;
    die "ActivityComparisonV3: $field must be an unsigned integer\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[0-9]+\z/;
    return 0 + $value;
}

sub _period {
    my ($value, $field) = @_;
    die "ActivityComparisonV3: $field must be a bounded scalar\n"
        unless defined($value) && !ref($value)
            && length($value) >= 1 && length($value) <= 32
            && $value !~ /[\r\n\0]/;
    return "$value";
}

sub new {
    my ($class, %args) = @_;
    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        left         => _nick($args{left}, 'left'),
        right        => _nick($args{right}, 'right'),
        left_count   => _uint($args{left_count}, 'left_count'),
        right_count  => _uint($args{right_count}, 'right_count'),
        period       => _period($args{period}, 'period'),
        period_label => _period($args{period_label}, 'period_label'),
    };
    return $self;
}

sub left         { _state($_[0])->{left} }
sub right        { _state($_[0])->{right} }
sub left_count   { _state($_[0])->{left_count} }
sub right_count  { _state($_[0])->{right_count} }
sub period       { _state($_[0])->{period} }
sub period_label { _state($_[0])->{period_label} }

sub as_hash { return { %{ _state($_[0]) } } }

sub DESTROY { delete $STATE{ refaddr($_[0]) } }

1;
