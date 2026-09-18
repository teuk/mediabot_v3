package Mediabot::Plugin::InvocationV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

my %STATE;

sub _state {
    my ($self) = @_;
    return $STATE{ refaddr($self) };
}

sub _safe_scalar {
    my ($value, $limit) = @_;
    return '' unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    return substr($text, 0, $limit);
}

sub _copy_config {
    my ($config) = @_;
    return {} unless ref($config) eq 'HASH';
    my %copy;
    for my $key (keys %$config) {
        my $value = $config->{$key};
        next if ref($value);
        $copy{$key} = $value;
    }
    return \%copy;
}

sub new {
    my ($class, %args) = @_;

    my @clean_args;
    if (ref($args{args}) eq 'ARRAY') {
        for my $value (@{ $args{args} }) {
            next unless defined($value) && !ref($value);
            push @clean_args, _safe_scalar($value, 256);
            last if @clean_args >= 32;
        }
    }

    die "InvocationV3: reply sink must be CODE\n"
        unless ref($args{reply_sink}) eq 'CODE';
    die "InvocationV3: notice sink must be CODE\n"
        unless ref($args{notice_sink}) eq 'CODE';
    die "InvocationV3: PluginContext authority is required\n"
        unless ref($args{authority})
            && eval { $args{authority}->isa('Mediabot::PluginContext') };
    my $activation = defined($args{activation}) ? $args{activation} : 'off';
    die "InvocationV3: invalid activation mode\n"
        unless !ref($activation) && $activation =~ /\A(?:off|observe|on)\z/;
    die "InvocationV3: output guard must be CODE\n"
        if exists($args{output_guard}) && ref($args{output_guard}) ne 'CODE';

    my $opaque = 0;
    my $self = bless \$opaque, $class;
    $STATE{ refaddr($self) } = {
        nick        => _safe_scalar($args{nick}, 64),
        channel     => _safe_scalar($args{channel}, 128),
        command     => _safe_scalar($args{command}, 32),
        args        => \@clean_args,
        source      => _safe_scalar($args{source}, 16),
        is_private  => $args{is_private} ? 1 : 0,
        reply_sink  => $args{reply_sink},
        notice_sink => $args{notice_sink},
        authority   => $args{authority},
        activation  => "$activation",
        config      => _copy_config($args{config}),
        output_guard => $args{output_guard},
    };
    return $self;
}

sub nick       { _state($_[0])->{nick} }
sub channel    { _state($_[0])->{channel} }
sub command    { _state($_[0])->{command} }
sub source     { _state($_[0])->{source} }
sub is_private { _state($_[0])->{is_private} ? 1 : 0 }
sub args       { [ @{ _state($_[0])->{args} } ] }
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

sub _emit_reply {
    my ($self, $text) = @_;
    my $state = _state($self);
    $state->{authority}->require_capability('irc.reply');
    return 0 unless $self->output_allowed;
    return $state->{reply_sink}->($text);
}

sub _emit_notice {
    my ($self, $text) = @_;
    my $state = _state($self);
    $state->{authority}->require_capability('irc.notice');
    return 0 unless $self->output_allowed;
    return $state->{notice_sink}->($text);
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
