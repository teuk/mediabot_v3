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
        0 => "\e[32m",  # INFO - vert
        1 => "\e[34m",  # DEBUG1 - bleu
        2 => "\e[36m",  # DEBUG2 - cyan
        3 => "\e[35m",  # DEBUG3 - magenta
        4 => "\e[33m",  # DEBUG4 - jaune
        5 => "\e[31m",  # DEBUG5 - rouge
    );

    my %label_map = (
        0 => "[INFO ]",
        1 => "[DEBUG1]",
        2 => "[DEBUG2]",
        3 => "[DEBUG3]",
        4 => "[DEBUG4]",
        5 => "[DEBUG5]",
    );

    my $color = $color_map{$level} // "\e[0m";
    my $label = $label_map{$level} // "[LVL$level]";

    my $logline = "$timestamp $label $msg\n";

    # Imprime dans le terminal avec couleurs si terminal interactif
    if (-t STDOUT) {
        print STDOUT "$color$logline\e[0m";
    } else {
        print STDOUT $logline;
    }

    # Écrit dans le fichier de log s’il existe
    if (my $fh = $self->{logfilehandle}) {
        print $fh $logline;
    }
}

1;