package Mediabot::Plugin::ActivityHeatmapV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state { $STATE{ refaddr($_[0]) } }

sub _nick {
    my ($value) = @_;
    die "ActivityHeatmapV3: nick must be a bounded nickname\n"
        unless defined($value) && !ref($value)
            && length($value) >= 1 && length($value) <= 64
            && $value =~ /\A[^\x00-\x20\x7f,:]+\z/;
    return lc "$value";
}

sub _hours {
    my ($value) = @_;
    die "ActivityHeatmapV3: hours must contain exactly 24 counters\n"
        unless ref($value) eq 'ARRAY' && @$value == 24;
    my @copy;
    for my $count (@$value) {
        die "ActivityHeatmapV3: hour counters must be unsigned integers\n"
            unless defined($count) && !ref($count)
                && "$count" =~ /\A[0-9]+\z/;
        push @copy, 0 + $count;
    }
    return \@copy;
}

sub new {
    my ($class, %args) = @_;
    my $hours = _hours($args{hours});
    my $total = 0;
    $total += $_ for @$hours;
    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        nick  => _nick($args{nick}),
        hours => $hours,
        total => $total,
    };
    return $self;
}

sub nick  { _state($_[0])->{nick} }
sub total { _state($_[0])->{total} }
sub hours { return [ @{ _state($_[0])->{hours} } ] }

sub as_hash {
    my ($self) = @_;
    return {
        nick  => $self->nick,
        hours => $self->hours,
        total => $self->total,
    };
}

sub DESTROY { delete $STATE{ refaddr($_[0]) } }

1;
