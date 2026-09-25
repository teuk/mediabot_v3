package Mediabot::Hailo::OutputPolish;

use strict;
use warnings;
use utf8;

use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(polish_hailo_output);

# Small, deterministic successors to the harmless typo fixes in MegaHAL's
# moulinex_out. Only apply in French; the provider handles broader repairs.
# Requiring "je" prevents a nickname such as Susi being changed in isolation.
sub polish_hailo_output {
    my (%args) = @_;
    return undef unless defined($args{text}) && !ref($args{text});
    my $line = "$args{text}";
    return $line unless defined($args{language}) && !ref($args{language})
        && $args{language} eq 'fr';

    $line =~ s/(?<![\p{L}\p{N}_])([Ss])a va(?![\p{L}\p{N}_])/
        $1 eq 'S' ? 'Ça va' : 'ça va'/geu;
    $line =~ s/(?<![\p{L}\p{N}_])([Jj])e susi(?![\p{L}\p{N}_])/
        $1 eq 'J' ? 'Je suis' : 'je suis'/geu;
    $line =~ s/,\s*\././g;
    return $line;
}

1;
