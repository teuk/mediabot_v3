package Mediabot::Plugin::QuoteRecordV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(refaddr);

my %STATE;

sub _state { $STATE{ refaddr($_[0]) } }

sub _text {
    my ($value, $field, $max_bytes) = @_;
    die "QuoteRecordV3: $field must be a scalar\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    die "QuoteRecordV3: $field exceeds $max_bytes bytes\n"
        if length(encode('UTF-8', $text)) > $max_bytes;
    return $text;
}

sub _uint {
    my ($value, $field, $positive) = @_;
    die "QuoteRecordV3: $field must be an unsigned integer\n"
        unless defined($value) && !ref($value) && "$value" =~ /\A[0-9]+\z/;
    die "QuoteRecordV3: $field must be positive\n"
        if $positive && "$value" eq '0';
    return 0 + $value;
}

sub new {
    my ($class, %args) = @_;
    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        id         => _uint($args{id}, 'id', 1),
        text       => _text($args{text}, 'text', 2048),
        author     => _text($args{author} // 'Unknown', 'author', 256),
        author_id  => _uint($args{author_id} // 0, 'author_id', 0),
        created_at => _text($args{created_at} // '', 'created_at', 64),
        hits       => _uint($args{hits} // 0, 'hits', 0),
    };
    return $self;
}

sub id         { _state($_[0])->{id} }
sub text       { _state($_[0])->{text} }
sub author     { _state($_[0])->{author} }
sub author_id  { _state($_[0])->{author_id} }
sub created_at { _state($_[0])->{created_at} }
sub hits       { _state($_[0])->{hits} }

sub as_hash {
    my ($self) = @_;
    return { %{ _state($self) } };
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
