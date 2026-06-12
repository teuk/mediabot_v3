package Mediabot::CommandRegistry;

use strict;
use warnings;
use utf8;

# ---------------------------------------------------------------------------
# Mediabot::CommandRegistry
# ---------------------------------------------------------------------------
# mb165-B1: small, standalone command registry foundation.
#
# This module deliberately does not change the existing Mediabot dispatch yet.
# It provides the stable API needed to move commands out of hard-coded dispatch
# hashes later, and eventually to let internal plugins/scripts register commands
# without editing Mediabot.pm.
# ---------------------------------------------------------------------------

sub new {
    my ($class) = @_;

    return bless {
        commands => {},  # source -> canonical command -> entry
        aliases  => {},  # source -> alias -> canonical command
    }, $class;
}

sub _source {
    my ($source) = @_;
    $source = 'public' unless defined $source && length $source;
    return lc $source;
}

sub _name {
    my ($name) = @_;
    return undef unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    return undef unless length $name;
    return lc $name;
}

sub register {
    my ($self, %args) = @_;
    return $self->register_command(%args);
}

sub register_command {
    my ($self, %args) = @_;

    my $name = _name($args{name});
    die "CommandRegistry: missing command name\n" unless defined $name;

    my $source = _source($args{source});

    my $handler = $args{handler};
    die "CommandRegistry: handler for '$name' must be a CODE reference\n"
        unless ref($handler) eq 'CODE';

    my @aliases;
    if (defined $args{aliases}) {
        die "CommandRegistry: aliases for '$name' must be an ARRAY reference\n"
            unless ref($args{aliases}) eq 'ARRAY';

        for my $alias (@{ $args{aliases} }) {
            my $a = _name($alias);
            next unless defined $a;
            next if $a eq $name;
            push @aliases, $a;
        }
    }

    $self->{commands}{$source} ||= {};
    $self->{aliases}{$source}  ||= {};

    if (exists $self->{commands}{$source}{$name} && !$args{replace}) {
        die "CommandRegistry: command '$name' already registered for source '$source'\n";
    }

    for my $alias (@aliases) {
        my $existing = $self->{aliases}{$source}{$alias};
        if (defined $existing && $existing ne $name && !$args{replace}) {
            die "CommandRegistry: alias '$alias' already points to '$existing' for source '$source'\n";
        }
    }

    my $entry = {
        name        => $name,
        source      => $source,
        aliases     => [ @aliases ],
        handler     => $handler,
        category    => $args{category},
        description => $args{description},
        level       => $args{level},
        chanset     => $args{chanset},
        plugin      => $args{plugin},
        metadata    => (ref($args{metadata}) eq 'HASH') ? { %{ $args{metadata} } } : {},
    };

    $self->{commands}{$source}{$name} = $entry;

    for my $alias (@aliases) {
        $self->{aliases}{$source}{$alias} = $name;
    }

    return $entry;
}

sub command_for {
    my ($self, $name, $source) = @_;

    my $cmd = _name($name);
    return undef unless defined $cmd;

    my $src = _source($source);

    my $canonical = $cmd;
    if (exists $self->{aliases}{$src} && exists $self->{aliases}{$src}{$cmd}) {
        $canonical = $self->{aliases}{$src}{$cmd};
    }

    return undef unless exists $self->{commands}{$src};
    return $self->{commands}{$src}{$canonical};
}

sub handler_for {
    my ($self, $name, $source) = @_;

    my $entry = $self->command_for($name, $source);
    return undef unless $entry;

    return $entry->{handler};
}

sub has_command {
    my ($self, $name, $source) = @_;
    return defined $self->command_for($name, $source) ? 1 : 0;
}

sub aliases_for {
    my ($self, $name, $source) = @_;

    my $entry = $self->command_for($name, $source);
    return () unless $entry && ref($entry->{aliases}) eq 'ARRAY';

    return @{ $entry->{aliases} };
}

sub list {
    my ($self, $source) = @_;

    my @sources = defined $source && length $source
        ? (_source($source))
        : sort keys %{ $self->{commands} };

    my @entries;
    for my $src (@sources) {
        next unless exists $self->{commands}{$src};
        push @entries, map { $self->{commands}{$src}{$_} }
            sort keys %{ $self->{commands}{$src} };
    }

    return @entries;
}

sub count {
    my ($self, $source) = @_;
    return scalar $self->list($source);
}

1;
