package Mediabot::Plugin::RepositoryV3;

use strict;
use warnings;
use utf8;

use Encode qw(encode);

our $MAX_VALUES = 64;
our $MAX_VALUE_BYTES = 2048;

sub new {
    my ($class, %args) = @_;
    die "RepositoryV3: plugin name is required\n"
        unless defined($args{plugin}) && !ref($args{plugin})
            && $args{plugin} =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;
    die "RepositoryV3: reader must be CODE\n"
        unless ref($args{reader}) eq 'CODE';
    die "RepositoryV3: writer must be CODE\n"
        unless ref($args{writer}) eq 'CODE';
    return bless {
        plugin => $args{plugin},
        reader => $args{reader},
        writer => $args{writer},
    }, $class;
}

sub _copy_values {
    my ($values) = @_;
    return { map { $_ => $values->{$_} } keys %$values };
}

sub _valid_key {
    my ($key) = @_;
    return defined($key) && !ref($key)
        && $key =~ /\A[a-z][a-z0-9_.-]{0,47}\z/ ? 1 : 0;
}

sub _validate_value {
    my ($value) = @_;
    die "RepositoryV3: values must be plain scalars\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    die "RepositoryV3: value contains a control character\n"
        if $text =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    die "RepositoryV3: value exceeds $MAX_VALUE_BYTES bytes\n"
        if length(encode('UTF-8', $text)) > $MAX_VALUE_BYTES;
    return $text;
}

sub _document {
    my ($self) = @_;
    my $raw = $self->{reader}->($self->{plugin});
    return { revision => 0, values => {} } unless defined $raw;
    die "RepositoryV3: stored document must be an object\n"
        unless ref($raw) eq 'HASH';
    die "RepositoryV3: stored revision is invalid\n"
        unless defined($raw->{revision}) && !ref($raw->{revision})
            && "$raw->{revision}" =~ /\A(?:0|[1-9][0-9]*)\z/;
    die "RepositoryV3: stored values are invalid\n"
        unless ref($raw->{values}) eq 'HASH';
    die "RepositoryV3: stored document has too many values\n"
        if keys(%{ $raw->{values} }) > $MAX_VALUES;
    my %values;
    for my $key (sort keys %{ $raw->{values} }) {
        die "RepositoryV3: stored key is invalid\n" unless _valid_key($key);
        $values{$key} = _validate_value($raw->{values}{$key});
    }
    return { revision => int($raw->{revision}), values => \%values };
}

sub snapshot {
    my ($self) = @_;
    my $doc = $self->_document;
    return {
        revision => $doc->{revision},
        values   => _copy_values($doc->{values}),
    };
}

sub commit {
    my ($self, %args) = @_;
    die "RepositoryV3: expected_revision is required\n"
        unless defined($args{expected_revision})
            && !ref($args{expected_revision})
            && "$args{expected_revision}" =~ /\A(?:0|[1-9][0-9]*)\z/;
    my $changes = exists($args{changes}) ? $args{changes} : {};
    my $delete = exists($args{delete}) ? $args{delete} : [];
    die "RepositoryV3: changes must be an object\n"
        unless ref($changes) eq 'HASH';
    die "RepositoryV3: delete must be an array\n"
        unless ref($delete) eq 'ARRAY';

    my $doc = $self->_document;
    return {
        ok => 0, error => 'conflict', revision => $doc->{revision},
    } if $doc->{revision} != int($args{expected_revision});

    my %next = %{ $doc->{values} };
    for my $key (sort keys %$changes) {
        die "RepositoryV3: invalid key\n" unless _valid_key($key);
        $next{$key} = _validate_value($changes->{$key});
    }
    for my $key (@$delete) {
        die "RepositoryV3: invalid delete key\n" unless _valid_key($key);
        delete $next{$key};
    }
    die "RepositoryV3: document has too many values\n"
        if keys(%next) > $MAX_VALUES;

    my $next_revision = $doc->{revision} + 1;
    my ($ok, $error) = $self->{writer}->($self->{plugin}, {
        revision => $next_revision,
        values   => \%next,
    });
    return { ok => 0, error => 'write_failed', detail => ($error // '') }
        unless $ok;
    return {
        ok => 1,
        revision => $next_revision,
        values => _copy_values(\%next),
    };
}

1;
