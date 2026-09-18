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
    };
    return $self;
}

sub nick       { _state($_[0])->{nick} }
sub channel    { _state($_[0])->{channel} }
sub command    { _state($_[0])->{command} }
sub source     { _state($_[0])->{source} }
sub is_private { _state($_[0])->{is_private} ? 1 : 0 }
sub args       { [ @{ _state($_[0])->{args} } ] }

sub _emit_reply {
    my ($self, $text) = @_;
    my $state = _state($self);
    $state->{authority}->require_capability('irc.reply');
    return $state->{reply_sink}->($text);
}

sub _emit_notice {
    my ($self, $text) = @_;
    my $state = _state($self);
    $state->{authority}->require_capability('irc.notice');
    return $state->{notice_sink}->($text);
}

sub DESTROY {
    my ($self) = @_;
    delete $STATE{ refaddr($self) };
}

1;
