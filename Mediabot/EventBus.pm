package Mediabot::EventBus;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

# ---------------------------------------------------------------------------
# Mediabot::EventBus
# ---------------------------------------------------------------------------
# Active internal event bus used by core hooks and trusted plugins.
#
# Listeners can subscribe with metadata and priority; emit_report() isolates
# listener failures and reports them without stopping the remaining listeners.
# The current public_command_observed event powers plugin observation and the
# external-script bridge, while the same API remains available for more events.
# ---------------------------------------------------------------------------

sub new {
    my ($class) = @_;

    return bless {
        listeners => {}, # event_name -> [ { cb => CODE, name => ..., plugin => ..., priority => ... } ]
    }, $class;
}

sub _event_name {
    my ($event) = @_;

    # mb275-B1: EventBus event names are plugin-facing identifiers and must
    # remain plain scalars.  Do not let ARRAY/HASH/blessed refs stringify into
    # pseudo-events such as ARRAY(0x...) at the plugin boundary.
    return undef unless defined $event;
    return undef if ref($event);

    $event =~ s/^\s+|\s+$//g;
    return undef unless length $event;
    $event =~ s/\s+/_/g;
    return lc $event;
}

sub _listener_meta_text {
    my ($value) = @_;

    # mb275-B2: listener metadata is rendered in emit_report() diagnostics.
    # Keep useful scalar text, but never expose HASH(...)/ARRAY(...) by
    # stringifying plugin-supplied references.
    return undef unless defined $value;
    return undef if ref($value);
    $value =~ s/[\r\n\0]+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? $value : undef;
}

sub _listener_priority {
    my ($value) = @_;

    # mb275-B3: priority is numeric ordering data; a bad ref should not trigger
    # Perl's implicit ref stringification warnings.
    return 0 unless defined $value;
    return 0 if ref($value);
    return int($value);
}

sub _listener_error_text {
    my ($value) = @_;

    # mb277-B1: listener exceptions are rendered in emit_report() diagnostics.
    # Perl allows dying with refs/objects; returning those directly would leak
    # structured values into the EventBus report. Keep diagnostics scalar,
    # bounded and single-line, just like the script bridge diagnostics.
    return 'unknown listener error' unless defined $value;
    return 'unknown listener error' if ref($value);

    $value =~ s/[\r\n\0]+/ /g;
    $value =~ s/\s+/ /g;
    $value =~ s/^\s+|\s+$//g;
    return 'unknown listener error' unless length $value;
    return substr($value, 0, 240);
}

sub _same_listener_entry {
    my ($left, $right) = @_;

    # mb275-B4: listener cleanup must use reference identity.  Stringifying
    # refs is fragile and inconsistent with PluginManager's refaddr()-based
    # lifecycle checks.
    return 0 unless ref($left) && ref($right);
    my $left_id  = eval { refaddr($left) };
    my $right_id = eval { refaddr($right) };
    return 0 unless defined $left_id && defined $right_id;
    return $left_id == $right_id ? 1 : 0;
}

sub on {
    my ($self, $event, $callback, %opts) = @_;

    my $name = _event_name($event);
    die "EventBus: missing event name\n" unless defined $name;
    die "EventBus: listener for '$name' must be a CODE reference\n"
        unless ref($callback) eq 'CODE';

    my $entry = {
        cb       => $callback,
        name     => _listener_meta_text($opts{name}),
        plugin   => _listener_meta_text($opts{plugin}),
        priority => _listener_priority($opts{priority}),
        once     => $opts{once} ? 1 : 0,
    };

    $self->{listeners}{$name} ||= [];
    push @{ $self->{listeners}{$name} }, $entry;

    @{ $self->{listeners}{$name} } = sort {
        ($b->{priority} <=> $a->{priority})
    } @{ $self->{listeners}{$name} };

    return $entry;
}

sub once {
    my ($self, $event, $callback, %opts) = @_;
    $opts{once} = 1;
    return $self->on($event, $callback, %opts);
}

sub off {
    my ($self, $event, $entry) = @_;

    my $name = _event_name($event);
    return 0 unless defined $name;
    return 0 unless ref($entry);
    return 0 unless exists $self->{listeners}{$name};

    # mb242-B1: listener entries returned by on()/once() can now be removed by
    # exact entry reference. Plugin replacement needs this so an old plugin
    # instance can unregister only its own EventBus listener without touching
    # the replacement listener registered during reload.
    my $removed = 0;
    my @keep;
    for my $current (@{ $self->{listeners}{$name} || [] }) {
        if (_same_listener_entry($current, $entry)) {
            $removed++;
            next;
        }
        push @keep, $current;
    }

    if (@keep) {
        $self->{listeners}{$name} = \@keep;
    }
    else {
        delete $self->{listeners}{$name};
    }

    return $removed;
}

sub _drop_once_entries_from_current_list {
    my ($self, $name, $snapshot) = @_;

    return unless defined $name && ref($snapshot) eq 'ARRAY';

    my %drop;
    for my $entry (@$snapshot) {
        next unless ref($entry) && $entry->{once};
        my $id = eval { refaddr($entry) };
        $drop{$id} = 1 if defined $id;
    }
    return unless %drop;

    my @current = @{ $self->{listeners}{$name} || [] };
    my @kept = grep {
        my $id = eval { refaddr($_) };
        !(defined $id && $drop{$id});
    } @current;

    # mb281-B1: when dropping one-shot listeners empties an event, remove the
    # event key entirely (like off() does). Leaving an empty ARRAY ref behind
    # makes events() report a phantom event that has zero listeners, which is
    # inconsistent with off()/clear() and surprising to callers enumerating
    # active events.
    if (@kept) {
        $self->{listeners}{$name} = \@kept;
    }
    else {
        delete $self->{listeners}{$name};
    }
}

sub emit {
    my ($self, $event, @args) = @_;

    my $name = _event_name($event);
    return 0 unless defined $name;
    return 0 unless exists $self->{listeners}{$name};

    my @listeners = @{ $self->{listeners}{$name} };
    my $ran = 0;

    for my $entry (@listeners) {
        eval {
            $entry->{cb}->(@args);
            1;
        };

        $ran++;
    }

    # mb230-B2: do not rebuild the listener list from the initial snapshot.
    # A plugin may register a listener while an event is being emitted. The new
    # listener must not run in the current emit, but it must remain registered for
    # the next one. Only one-shot listeners from the snapshot are removed.
    $self->_drop_once_entries_from_current_list($name, \@listeners);
    return $ran;
}

sub emit_report {
    my ($self, $event, @args) = @_;

    my $name = _event_name($event);
    return {
        event  => $name,
        ran    => 0,
        errors => [],
    } unless defined $name && exists $self->{listeners}{$name};

    my @listeners = @{ $self->{listeners}{$name} };
    my @errors;
    my $ran = 0;

    for my $entry (@listeners) {
        my $ok = eval {
            $entry->{cb}->(@args);
            1;
        };

        $ran++;

        if (!$ok) {
            my $err = _listener_error_text($@);
            push @errors, {
                event  => $name,
                name   => $entry->{name},
                plugin => $entry->{plugin},
                error  => $err,
            };
        }
    }

    # mb230-B2: preserve listeners registered during emit_report as well.
    # Only once-listeners that were part of the snapshot are removed.
    $self->_drop_once_entries_from_current_list($name, \@listeners);

    return {
        event  => $name,
        ran    => $ran,
        errors => \@errors,
    };
}

sub listeners {
    my ($self, $event) = @_;

    my $name = _event_name($event);
    return () unless defined $name;
    return () unless exists $self->{listeners}{$name};

    return @{ $self->{listeners}{$name} };
}

sub listener_count {
    my ($self, $event) = @_;

    # mb167-P1: force list context before scalar count. A direct
    # 'scalar $self->listeners($event)' can become undef when listeners()
    # returns an empty list, which is noisy in numeric comparisons.
    my @listeners = $self->listeners($event);
    return scalar @listeners;
}

sub clear {
    my ($self, $event) = @_;

    if (defined $event) {
        my $name = _event_name($event);
        return 0 unless defined $name;
        my $count = $self->listener_count($name);
        delete $self->{listeners}{$name};
        return $count;
    }

    my $count = 0;
    for my $name (keys %{ $self->{listeners} }) {
        $count += scalar @{ $self->{listeners}{$name} };
    }

    $self->{listeners} = {};
    return $count;
}

sub events {
    my ($self) = @_;

    # mb167-P2: force list context before returning. Direct
    # 'return sort keys ...' may yield undef in scalar context when the list is
    # empty, which makes scalar($bus->events) noisy in tests/callers.
    my @events = sort keys %{ $self->{listeners} };
    return @events;
}

1;
