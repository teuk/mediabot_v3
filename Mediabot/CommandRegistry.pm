package Mediabot::CommandRegistry;

use strict;
use warnings;
use utf8;

# ---------------------------------------------------------------------------
# Mediabot::CommandRegistry
# ---------------------------------------------------------------------------
# Active command registry used alongside Mediabot's legacy dispatch tables.
#
# It stores canonical public/private commands, aliases, metadata and handlers.
# Mediabot consults it first for migrated commands, then keeps the legacy tables
# as a compatibility fallback for commands not registered here yet. Trusted
# in-process plugins can use the same validated registration API.
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

    # mb274-B1: command registry source names are plugin-facing protocol
    # identifiers and must be plain scalars.  A plugin must not be able to
    # register or look up commands under ARRAY(...)/HASH(...) pseudo-sources by
    # passing Perl references that get stringified accidentally.
    return undef if ref($source);

    $source = 'public' unless defined $source;
    $source =~ s/^\s+|\s+$//g;
    $source = 'public' unless length $source;

    return lc $source;
}

sub _name {
    my ($name) = @_;

    # mb274-B2: command and alias names must be plain scalars too.  Invalid
    # plugin input should be rejected for canonical command names and ignored
    # for optional aliases, never stringified into ARRAY(...)/HASH(...).
    return undef unless defined $name;
    return undef if ref($name);

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

    die "CommandRegistry: command name must be scalar\n" if ref($args{name});

    my $name = _name($args{name});
    die "CommandRegistry: missing command name\n" unless defined $name;

    my $source = _source($args{source});
    die "CommandRegistry: command source must be scalar\n" unless defined $source;

    my $handler = $args{handler};
    die "CommandRegistry: handler for '$name' must be a CODE reference\n"
        unless ref($handler) eq 'CODE';

    my @aliases;
    my %seen_alias;
    if (defined $args{aliases}) {
        die "CommandRegistry: aliases for '$name' must be an ARRAY reference\n"
            unless ref($args{aliases}) eq 'ARRAY';

        for my $alias (@{ $args{aliases} }) {
            my $a = _name($alias);
            next unless defined $a;
            next if $a eq $name;
            next if $seen_alias{$a}++;
            push @aliases, $a;
        }
    }

    $self->{commands}{$source} ||= {};
    $self->{aliases}{$source}  ||= {};

    my $replacing_existing = exists $self->{commands}{$source}{$name} ? 1 : 0;
    if ($replacing_existing && !$args{replace}) {
        die "CommandRegistry: command '$name' already registered for source '$source'\n";
    }

    # mb230-B1: replacing a command must not leave stale aliases behind, and
    # replace must not steal aliases/canonical names owned by another command.
    # This matters for plugins because a reload can legitimately replace a
    # command definition with a new alias set; old aliases must disappear instead
    # of continuing to dispatch to the replaced command.
    #
    # mb231-B1: failed replacements must be atomic. Validate the new alias set
    # before deleting aliases from the currently registered command. Otherwise a
    # plugin reload that tries to replace a command with a conflicting alias could
    # die halfway through and leave the old command alive but stripped of its old
    # aliases. That would be a silent command-dispatch regression.
    for my $alias (@aliases) {
        if (exists $self->{commands}{$source}{$alias} && $alias ne $name) {
            die "CommandRegistry: alias '$alias' conflicts with command '$alias' for source '$source'
";
        }

        my $existing = $self->{aliases}{$source}{$alias};
        if (defined $existing && $existing ne $name) {
            die "CommandRegistry: alias '$alias' already points to '$existing' for source '$source'
";
        }
    }

    if ($replacing_existing && $args{replace}) {
        for my $alias (keys %{ $self->{aliases}{$source} }) {
            delete $self->{aliases}{$source}{$alias}
                if defined $self->{aliases}{$source}{$alias}
                && $self->{aliases}{$source}{$alias} eq $name;
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
    return undef unless defined $src;

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

    my @sources;
    if (defined $source) {
        my $src = _source($source);
        return () unless defined $src;
        @sources = ($src);
    }
    else {
        @sources = sort keys %{ $self->{commands} };
    }

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

    # mb274-B3: force list context before scalar count. If list() returns an
    # empty list in scalar context (for example an invalid non-scalar source),
    # Perl can produce undef instead of 0. Keep count() numeric and quiet.
    my @entries = $self->list($source);
    return scalar @entries;
}

1;
