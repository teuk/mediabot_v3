package Mediabot::Plugin::HTTPResponseV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state { $STATE{ refaddr($_[0]) } }

sub _scalar {
    my ($value, $limit) = @_;
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    return substr($text, 0, $limit);
}

sub new {
    my ($class, %args) = @_;
    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        ok           => $args{ok} ? 1 : 0,
        status       => defined($args{status}) && !ref($args{status})
            && "$args{status}" =~ /\A[0-9]{3}\z/ ? int($args{status}) : 0,
        url          => _scalar($args{url}, 2048),
        content_type => _scalar($args{content_type}, 160),
        body         => defined($args{body}) && !ref($args{body})
            ? "$args{body}" : '',
        from_cache   => $args{from_cache} ? 1 : 0,
        error        => _scalar($args{error}, 80),
    };
    return $self;
}

sub ok           { _state($_[0])->{ok} ? 1 : 0 }
sub status       { _state($_[0])->{status} }
sub url          { _state($_[0])->{url} }
sub content_type { _state($_[0])->{content_type} }
sub body         { _state($_[0])->{body} }
sub from_cache   { _state($_[0])->{from_cache} ? 1 : 0 }
sub error        { _state($_[0])->{error} }

sub DESTROY { delete $STATE{ refaddr($_[0]) } }

1;
