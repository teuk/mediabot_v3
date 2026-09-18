package Mediabot::PluginContext;

use strict;
use warnings;
use utf8;

use Encode qw(encode);
use Scalar::Util qw(refaddr);

my %STATE;

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub new {
    my ($class, %args) = @_;

    die "PluginContext: plugin name is required\n"
        unless defined($args{plugin}) && !ref($args{plugin})
            && $args{plugin} =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;

    my $requested = ref($args{requested}) eq 'ARRAY' ? $args{requested} : [];
    my $granted   = ref($args{granted}) eq 'ARRAY'   ? $args{granted}   : [];
    my %requested = map { $_ => 1 } grep { defined($_) && !ref($_) } @$requested;
    my %granted   = map { $_ => 1 } grep { defined($_) && !ref($_) } @$granted;
    my %effective = map { $_ => 1 } grep { $granted{$_} } keys %requested;

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        plugin    => $args{plugin},
        requested => \%requested,
        granted   => \%granted,
        effective => \%effective,
    };
    return $self;
}

sub plugin { _state($_[0])->{plugin} }

sub requested_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{requested} };
}

sub granted_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{granted} };
}

sub effective_capabilities {
    my ($self) = @_;
    return sort keys %{ _state($self)->{effective} };
}

sub has_capability {
    my ($self, $capability) = @_;
    return 0 unless defined($capability) && !ref($capability);
    return _state($self)->{effective}{$capability} ? 1 : 0;
}

sub require_capability {
    my ($self, $capability) = @_;
    my $state = _state($self);
    die "PluginContext: capability '$capability' was not granted to '$state->{plugin}'\n"
        unless $self->has_capability($capability);
    return 1;
}

sub _text {
    my ($value) = @_;
    die "PluginContext: output must be a scalar\n"
        unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/^\s+|\s+$//g;
    die "PluginContext: output must not be empty\n" unless length $text;
    die "PluginContext: output exceeds 400 bytes\n"
        if length(encode('UTF-8', $text)) > 400;
    return $text;
}

sub reply {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.reply');
    die "PluginContext: invalid invocation\n"
        unless ref($invocation) && eval { $invocation->can('_emit_reply') };
    return $invocation->_emit_reply(_text($text));
}

sub notice {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.notice');
    die "PluginContext: invalid invocation\n"
        unless ref($invocation) && eval { $invocation->can('_emit_notice') };
    return $invocation->_emit_notice(_text($text));
}

sub channel_message {
    my ($self, $invocation, $text) = @_;
    $self->require_capability('irc.channel_message');
    die "PluginContext: invalid channel invocation\n"
        unless ref($invocation)
            && eval { $invocation->can('_emit_channel_message') };
    return $invocation->_emit_channel_message(_text($text));
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
