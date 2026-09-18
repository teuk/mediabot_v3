package Mediabot::Plugin::ChannelPolicyV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed);

our $MAX_CHANNELS = 128;

sub _clone {
    my ($value) = @_;
    return $value unless ref($value);
    return [ map { _clone($_) } @$value ] if ref($value) eq 'ARRAY';
    return { map { $_ => _clone($value->{$_}) } keys %$value }
        if ref($value) eq 'HASH';
    return undef;
}

sub _channel_key {
    my ($channel, $fatal) = @_;
    my $ok = defined($channel) && !ref($channel)
        && length($channel) >= 2 && length($channel) <= 128
        && $channel =~ /\A[#&+!][^\x00\x07\r\n ,:]+\z/;
    die "Plugin API v3: invalid policy channel\n" if !$ok && $fatal;
    return undef unless $ok;
    my $key = lc "$channel";
    $key =~ tr/\x5b\x5d\x5c\x5e/\x7b\x7d\x7c\x7e/;
    return $key;
}

sub _mode {
    my ($mode) = @_;
    die "Plugin API v3: channel policy mode must be off, observe or on\n"
        unless defined($mode) && !ref($mode)
            && $mode =~ /\A(?:off|observe|on)\z/;
    return "$mode";
}

sub new {
    my ($class, %args) = @_;
    my $schema = $args{schema};
    die "Plugin API v3: typed config schema is required for channel policy\n"
        unless blessed($schema)
            && $schema->isa('Mediabot::Plugin::ConfigSchemaV3');
    my $self = bless { schema => $schema, policies => {} }, $class;

    if (exists $args{policies}) {
        die "Plugin API v3: channel_policies must be an object\n"
            unless ref($args{policies}) eq 'HASH';
        die "Plugin API v3: channel_policies exceeds $MAX_CHANNELS channels\n"
            if keys(%{ $args{policies} }) > $MAX_CHANNELS;
        for my $channel (sort keys %{ $args{policies} }) {
            my $policy = $args{policies}{$channel};
            die "Plugin API v3: policy for '$channel' must be an object\n"
                unless ref($policy) eq 'HASH';
            for my $field (sort keys %$policy) {
                die "Plugin API v3: unknown policy field '$field' for '$channel'\n"
                    unless $field eq 'mode' || $field eq 'config';
            }
            $self->set($channel,
                mode   => ($policy->{mode} // 'off'),
                config => ($policy->{config} // {}));
        }
    }
    return $self;
}

sub set {
    my ($self, $channel, %args) = @_;
    my $key = _channel_key($channel, 1);
    my $mode = _mode($args{mode} // 'off');
    my $existing = $self->{policies}{$key};
    my $effective;
    if (exists $args{config}) {
        $effective = $self->{schema}->normalize($args{config});
    }
    elsif ($existing) {
        $effective = $mode eq 'off'
            ? _clone($existing->{config})
            : $self->{schema}->normalize($existing->{config});
    }
    elsif ($mode eq 'off') {
        $effective = $self->{schema}->defaults;
    }
    else {
        $effective = $self->{schema}->normalize({});
    }
    die "Plugin API v3: channel_policies exceeds $MAX_CHANNELS channels\n"
        if !$existing && keys(%{ $self->{policies} }) >= $MAX_CHANNELS;
    $self->{policies}{$key} = {
        channel => "$channel",
        mode    => $mode,
        config  => $effective,
    };
    return _clone($self->{policies}{$key});
}

sub reset {
    my ($self, $channel) = @_;
    my $key = _channel_key($channel, 1);
    return delete($self->{policies}{$key}) ? 1 : 0;
}

sub policy_for {
    my ($self, $channel) = @_;
    my $key = _channel_key($channel, 0);
    return { channel => (defined($channel) && !ref($channel) ? "$channel" : ''),
             mode => 'off', config => $self->{schema}->defaults }
        unless defined($key) && exists($self->{policies}{$key});
    return _clone($self->{policies}{$key});
}

sub active_policies {
    my ($self) = @_;
    return map { _clone($_) }
        sort { lc($a->{channel}) cmp lc($b->{channel}) }
        grep { $_->{mode} ne 'off' } values %{ $self->{policies} };
}

sub policies {
    my ($self) = @_;
    return map { _clone($_) }
        sort { lc($a->{channel}) cmp lc($b->{channel}) }
        values %{ $self->{policies} };
}

sub count { scalar keys %{ $_[0]->{policies} } }

1;
