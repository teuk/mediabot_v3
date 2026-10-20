package Mediabot::DTC::Format;

use strict;
use warnings;
use utf8;
use Encode qw(encode decode FB_QUIET);
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
    my ($line, $truncated) = @_;
    return '' unless defined($line) && !ref($line);
    my $bytes = encode('UTF-8', $line);
    return $line if length($bytes) <= MAX_WIRE_BYTES;
    $$truncated = 1 if ref($truncated) eq 'SCALAR';
    my $suffix = "\x{2026}\x0f";
    # Encode once, then discard only an incomplete final UTF-8 character.
    my $prefix = substr($bytes, 0, MAX_WIRE_BYTES - length(encode('UTF-8', $suffix)));
    return decode('UTF-8', $prefix, FB_QUIET) . $suffix;
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
    my $url = $id =~ /\A[0-9]+\z/
        ? "Consultez la quote ici : https://danstonchat.com/quote/$id.html"
        : undef;
    my $abridged = @lines > $max_lines;
    if ($abridged) {
        my $keep = $max_lines - ($url ? 2 : 1);
        $keep = 1 if $keep < 1;
        @lines = (@lines[0 .. $keep - 1], '...');
        push @lines, $url if $url;
    }

    my @out;
    my $clipped = 0;
    my $first = shift @lines;
    push @out, _fit_wire("\x03" . '01,15' . "\x02[$id]\x02\x03" . '00,14' . " $first\x0f", \$clipped);
    push @out, map { _fit_wire("\x03" . '00,14' . "$_\x0f", \$clipped) } @lines;
    if ($clipped && !$abridged && $url) {
        # Byte truncation also hides quote text, even with few dialogue lines.
        # Reserve the existing ellipsis/link pair if the batch is already full.
        if (@out == $max_lines) {
            splice @out, $max_lines - 2;
            push @out, "\x03" . '00,14' . "...\x0f";
        }
        push @out, _fit_wire("\x03" . '00,14' . "$url\x0f");
    }
    return \@out;
}

1;
