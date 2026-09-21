package Mediabot::Plugin::FactoidRecordV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(refaddr);

my %STATE;

sub _state { $STATE{ refaddr($_[0]) } }

sub _text {
    my ($value, $field, $max_bytes) = @_;
    die "FactoidRecordV3: $field must be a scalar\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    die "FactoidRecordV3: $field exceeds $max_bytes bytes\n"
        if length(encode('UTF-8', $text)) > $max_bytes;
    return $text;
}

sub _uint {
    my ($value, $field, $positive) = @_;
    die "FactoidRecordV3: $field must be an unsigned integer\n"
        unless defined($value) && !ref($value) && "$value" =~ /\A[0-9]+\z/;
    die "FactoidRecordV3: $field must be positive\n"
        if $positive && "$value" eq '0';
    return 0 + $value;
}

sub _keyword {
    my ($value) = @_;
    my $keyword = lc _text($value, 'keyword', 64);
    die "FactoidRecordV3: keyword is invalid\n"
        unless $keyword =~ /\A[a-z0-9_.-]{1,64}\z/;
    return $keyword;
}

sub new {
    my ($class, %args) = @_;
    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        id         => _uint($args{id}, 'id', 1),
        keyword    => _keyword($args{keyword}),
        value      => _text($args{value}, 'value', 2048),
        author     => _text($args{author} // 'Unknown', 'author', 256),
        author_id  => _uint($args{author_id} // 0, 'author_id', 0),
        created_at => _text($args{created_at} // '', 'created_at', 64),
        updated_at => _text($args{updated_at} // '', 'updated_at', 64),
        hits       => _uint($args{hits} // 0, 'hits', 0),
    };
    return $self;
}

sub id         { _state($_[0])->{id} }
sub keyword    { _state($_[0])->{keyword} }
sub value      { _state($_[0])->{value} }
sub author     { _state($_[0])->{author} }
sub author_id  { _state($_[0])->{author_id} }
sub created_at { _state($_[0])->{created_at} }
sub updated_at { _state($_[0])->{updated_at} }
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
