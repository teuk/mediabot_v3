package Mediabot::Plugin::QuarantineV3;

use strict;
use warnings;
use utf8;

my %RUNTIME_KIND = map { $_ => 1 } qw(
    command
    event
    http_callback
    job
);

sub new {
    my ($class, %args) = @_;

    my $max_entries = exists($args{max_entries}) ? $args{max_entries} : 64;
    die "QuarantineV3: max_entries must be between 1 and 128\n"
        unless defined($max_entries) && !ref($max_entries)
            && "$max_entries" =~ /\A[0-9]+\z/
            && $max_entries >= 1 && $max_entries <= 128;
    die "QuarantineV3: clock must be CODE\n"
        if exists($args{clock}) && ref($args{clock}) ne 'CODE';

    return bless {
        max_entries => int($max_entries),
        clock       => $args{clock} || sub { time() },
        entries     => {},
    }, $class;
}

sub _runtime_kind {
    my ($kind) = @_;
    die "QuarantineV3: unsupported runtime kind\n"
        unless defined($kind) && !ref($kind) && $RUNTIME_KIND{$kind};
    return "$kind";
}

sub _resource {
    my ($resource) = @_;
    die "QuarantineV3: invalid resource name\n"
        unless defined($resource) && !ref($resource)
            && length($resource) >= 1 && length($resource) <= 128
            && $resource =~ /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/;
    return "$resource";
}

sub _channel {
    my ($channel) = @_;
    die "QuarantineV3: invalid channel\n"
        unless defined($channel) && !ref($channel)
            && length($channel) >= 2 && length($channel) <= 128
            && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    return "$channel";
}

sub _channel_key {
    my ($channel) = @_;
    my $key = lc $channel;
    $key =~ tr/\x5b\x5d\x5c\x5e/\x7b\x7d\x7c\x7e/;
    return $key;
}

sub _timestamp {
    my ($self) = @_;
    my $value = $self->{clock}->();
    die "QuarantineV3: invalid timestamp\n"
        unless defined($value) && !ref($value)
            && "$value" =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    return int($value);
}

sub _identity {
    my (%args) = @_;
    my $kind = _runtime_kind($args{kind});
    my $resource = _resource($args{resource});
    my $channel = _channel($args{channel});
    my $key = join("\x00", $kind, $resource, _channel_key($channel));
    return ($key, $kind, $resource, $channel);
}

sub quarantine {
    my ($self, %args) = @_;
    my ($key, $kind, $resource, $channel) = _identity(%args);
    if (my $existing = $self->{entries}{$key}) {
        return { %$existing, created => 0 };
    }
    die "QuarantineV3: quarantine limit reached\n"
        if keys(%{ $self->{entries} }) >= $self->{max_entries};

    my $entry = {
        kind           => $kind,
        resource       => $resource,
        channel        => $channel,
        quarantined_at => $self->_timestamp,
    };
    $self->{entries}{$key} = $entry;
    return { %$entry, created => 1 };
}

sub release {
    my ($self, %args) = @_;
    my ($key) = _identity(%args);
    return delete($self->{entries}{$key}) ? 1 : 0;
}

sub is_quarantined {
    my ($self, %args) = @_;
    my ($key) = _identity(%args);
    return exists($self->{entries}{$key}) ? 1 : 0;
}

sub report {
    my ($self) = @_;
    my @entries = map { { %$_ } } sort {
           $a->{quarantined_at} <=> $b->{quarantined_at}
        || $a->{kind} cmp $b->{kind}
        || $a->{resource} cmp $b->{resource}
        || _channel_key($a->{channel}) cmp _channel_key($b->{channel})
    } values %{ $self->{entries} };

    return {
        total       => scalar(@entries),
        max_entries => $self->{max_entries},
        entries     => \@entries,
    };
}

1;
