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

    # ---------------------------------------------------------------------------
    # Convenience helpers for logging
    # ---------------------------------------------------------------------------

    sub info {
        my ($self, $msg) = @_;
        # Level 0 = INFO in existing log()
        $self->log(0, $msg);
    }

    sub debug {
        my ($self, $msg) = @_;
        # Level 2 chosen as "normal debug" (respects debug_level)
        $self->log(2, $msg);
    }

    sub error {
        my ($self, $msg) = @_;
        # Still level 0 but with an explicit [ERROR] prefix in the message
        $self->log(0, "[ERROR] $msg");
    }
}

1;