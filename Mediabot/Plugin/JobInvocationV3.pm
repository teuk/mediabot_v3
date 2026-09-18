package Mediabot::Plugin::JobInvocationV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub _copy_config {
    my ($config) = @_;
    return {} unless ref($config) eq 'HASH';
    return { map { $_ => $config->{$_} } grep { !ref($config->{$_}) } keys %$config };
}

sub new {
    my ($class, %args) = @_;

    die "JobInvocationV3: invalid job name\n"
        unless defined($args{name}) && !ref($args{name})
            && $args{name} =~ /\A[a-z][a-z0-9_.-]{0,47}\z/;
    die "JobInvocationV3: invalid sequence\n"
        unless defined($args{sequence}) && !ref($args{sequence})
            && "$args{sequence}" =~ /\A[1-9][0-9]*\z/;
    die "JobInvocationV3: channel message sink must be CODE\n"
        if exists($args{channel_message_sink})
            && ref($args{channel_message_sink}) ne 'CODE';
    die "JobInvocationV3: output guard must be CODE\n"
        if exists($args{output_guard}) && ref($args{output_guard}) ne 'CODE';
    die "JobInvocationV3: invalid PluginContext authority\n"
        if exists($args{authority})
            && !(ref($args{authority})
                && eval { $args{authority}->isa('Mediabot::PluginContext') });

    die "JobInvocationV3: invalid fired_at timestamp\n"
        if defined($args{fired_at})
            && (ref($args{fired_at})
                || "$args{fired_at}" !~ /\A[0-9]+(?:\.[0-9]+)?\z/);
    die "JobInvocationV3: invalid scheduled_at timestamp\n"
        if defined($args{scheduled_at})
            && (ref($args{scheduled_at})
                || "$args{scheduled_at}" !~ /\A[0-9]+(?:\.[0-9]+)?\z/);

    my $fired_at = defined($args{fired_at})
        ? 0 + $args{fired_at} : time();
    my $scheduled_at = defined($args{scheduled_at})
        ? 0 + $args{scheduled_at} : $fired_at;
    my $activation = defined($args{activation}) ? $args{activation} : 'off';
    die "JobInvocationV3: invalid activation mode\n"
        unless !ref($activation) && $activation =~ /\A(?:off|observe|on)\z/;

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        name         => "$args{name}",
        sequence     => int($args{sequence}),
        scheduled_at => $scheduled_at,
        fired_at     => $fired_at,
        channel      => defined($args{channel}) && !ref($args{channel})
            ? "$args{channel}" : '',
        activation   => "$activation",
        config       => _copy_config($args{config}),
        authority    => $args{authority},
        output_guard => $args{output_guard},
        channel_message_sink => $args{channel_message_sink} || sub { 0 },
    };
    return $self;
}

sub name         { _state($_[0])->{name} }
sub sequence     { _state($_[0])->{sequence} }
sub scheduled_at { _state($_[0])->{scheduled_at} }
sub fired_at     { _state($_[0])->{fired_at} }
sub channel      { _state($_[0])->{channel} }
sub activation_mode { _state($_[0])->{activation} }
sub config { _copy_config(_state($_[0])->{config}) }

sub config_value {
    my ($self, $key) = @_;
    return undef unless defined($key) && !ref($key);
    return _state($self)->{config}{$key};
}

sub output_allowed {
    my ($self) = @_;
    my $state = _state($self);
    return 0 unless $state->{activation} eq 'on';
    return 1 unless ref($state->{output_guard}) eq 'CODE';
    return $state->{output_guard}->() ? 1 : 0;
}

sub _emit_channel_message {
    my ($self, $text) = @_;
    my $state = _state($self);
    die "JobInvocationV3: PluginContext authority is required for output\n"
        unless ref($state->{authority});
    $state->{authority}->require_capability('irc.channel_message');
    return 0 unless $self->output_allowed;
    return $state->{channel_message_sink}->($text);
}

sub lateness_seconds {
    my ($self) = @_;
    my $state = _state($self);
    my $late = $state->{fired_at} - $state->{scheduled_at};
    return $late > 0 ? $late : 0;
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
