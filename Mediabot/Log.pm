package Mediabot::Log;
use strict;
use warnings;
use POSIX qw(strftime);

sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{debug_level} = int($args{debug_level} // 0);  # valeur par défaut : 0

    if (defined $args{logfile}) {
        open my $fh, '>>:utf8', $args{logfile} or die "Cannot open logfile $args{logfile}: $!";
        $fh->autoflush(1);
        $self->{logfilehandle} = $fh;
    }

    return $self;
}

sub log {
    my ($self, $level, $msg) = @_;
    return unless defined $msg && $msg ne '';

    my $debug_level = $self->{debug_level} // 0;
    return if $level > $debug_level;

    my $timestamp = strftime("[%d/%m/%Y %H:%M:%S]", localtime);

    my %color_map = (
        0 => "\e[32m",  # INFO - green
        1 => "\e[34m",  # DEBUG1 - blue
        2 => "\e[36m",  # DEBUG2 - cyan
        3 => "\e[35m",  # DEBUG3 - magenta
        4 => "\e[33m",  # DEBUG4 - yellow
        5 => "\e[90m",  # DEBUG5 - light gray
    );

    my %label_map = (
        0 => "[INFO]",
        1 => "[DEBUG1]",
        2 => "[DEBUG2]",
        3 => "[DEBUG3]",
        4 => "[DEBUG4]",
        5 => "[DEBUG5]",
    );

    my $color = $color_map{$level} // "\e[0m";
    my $label = $label_map{$level} // "[LVL$level]";

    # Detect if message already starts with a [TAG]
    my $has_tag_prefix = ($msg =~ /^\[[A-Z]+\]/) ? 1 : 0;

    my $logline = $has_tag_prefix
        ? "$timestamp $msg\n"
        : "$timestamp $label $msg\n";

    # Print to terminal with color if interactive
    if (-t STDOUT) {
        print STDOUT "$color$logline\e[0m";
    } else {
        print STDOUT $logline;
    }

    # Write to logfile if enabled
    if (my $fh = $self->{logfilehandle}) {
        print $fh $logline;
    }

    # Dispatch to partyline console hooks
    # Each hook: { level => N, cb => sub { } }
    # The logline sent to partyline strips trailing \n and uses \r\n
    if ($self->{_console_hooks} && %{ $self->{_console_hooks} }) {
        my $pl_line = $logline;
        $pl_line =~ s/\n$//;
        for my $id (keys %{ $self->{_console_hooks} }) {
            my $hook = $self->{_console_hooks}{$id};
            next unless $hook && $hook->{cb};
            next if $level > ($hook->{level} // 0);
            eval { $hook->{cb}->($pl_line) };
        }
    }
}

# ---------------------------------------------------------------------------
# Console hook API — used by Partyline to redirect logs to connected sessions
# ---------------------------------------------------------------------------

# Register a partyline session to receive log lines up to $hook_level
sub add_console_hook {
    my ($self, $id, $hook_level, $cb) = @_;
    $self->{_console_hooks} //= {};
    $self->{_console_hooks}{$id} = { level => ($hook_level // 0), cb => $cb };
}

# Remove a hook (called when session disconnects or disables console)
sub remove_console_hook {
    my ($self, $id) = @_;
    delete $self->{_console_hooks}{$id} if $self->{_console_hooks};
}

# Return current hook level for a session (undef = not hooked)
sub get_console_hook_level {
    my ($self, $id) = @_;
    return undef unless $self->{_console_hooks} && $self->{_console_hooks}{$id};
    return $self->{_console_hooks}{$id}{level};
}

# ---------------------------------------------------------------------------
# Convenience helpers — declared at package level (not nested inside sub log)
# ---------------------------------------------------------------------------

sub info {
    my ($self, $msg) = @_;
    $self->log(0, $msg);
}

sub debug {
    my ($self, $msg) = @_;
    $self->log(2, $msg);
}

sub error {
    my ($self, $msg) = @_;
    $self->log(0, "[ERROR] $msg");
}

1;