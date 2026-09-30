package Mediabot::DTC::Format;

use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Exporter 'import';

our @EXPORT_OK = qw(format_quote_lines);

use constant MAX_LINES => 10;
use constant MAX_WIRE_BYTES => 430;

sub _clean_line {
    my ($line) = @_;
    return '' unless defined($line) && !ref($line);
    $line =~ s/[\r\n\0]+/ /g;
    $line =~ s/^\s+|\s+$//g;
    return $line;
}

sub _fit_wire {
    my ($line) = @_;
    return '' unless defined($line) && !ref($line);
    return $line if length(encode('UTF-8', $line)) <= MAX_WIRE_BYTES;
    my $suffix = "\x{2026}\x0f";
    while (length($line) && length(encode('UTF-8', $line . $suffix)) > MAX_WIRE_BYTES) {
        chop $line;
    }
    return $line . $suffix;
}

sub format_quote_lines {
    my ($id, $text, %opts) = @_;
    my $max_lines = $opts{max_lines} // MAX_LINES;
    $max_lines = MAX_LINES unless !ref($max_lines)
        && "$max_lines" =~ /\A\d+\z/ && $max_lines >= 3
        && $max_lines <= MAX_LINES;
    $id = '??' unless defined($id) && !ref($id) && $id =~ /\A(?:[0-9]+|\?\?)\z/;
    return [] unless defined($text) && !ref($text);

    my @lines = grep { length($_) } map { _clean_line($_) } split /\n/, $text;
    return [] unless @lines;
    if (@lines > $max_lines) {
        my $url = $id =~ /\A[0-9]+\z/
            ? "Consultez la quote ici : https://danstonchat.com/quote/$id.html"
            : undef;
        my $keep = $max_lines - ($url ? 2 : 1);
        $keep = 1 if $keep < 1;
        @lines = (@lines[0 .. $keep - 1], '...');
        push @lines, $url if $url;
    }

    my @out;
    my $first = shift @lines;
    push @out, _fit_wire("\x03" . '01,15' . "\x02[$id]\x02\x03" . '00,14' . " $first\x0f");
    push @out, map { _fit_wire("\x03" . '00,14' . "$_\x0f") } @lines;
    return \@out;
}

1;
