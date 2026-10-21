package Mediabot::IRC::CaseMapping;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(fold_irc);

# Preserve the project's lc-based behavior. Unknown mappings retain the
# historical ASCII-mode path; this is folding, not nickname validation.
sub fold_irc {
    my ($value, $mapping) = @_;
    $value = lc($value // '');
    $mapping = 'rfc1459' unless defined $mapping;
    if ($mapping eq 'rfc1459') {
        $value =~ tr/[]\\^/{}|~/;
    }
    elsif ($mapping eq 'strict-rfc1459') {
        $value =~ tr/[]\\/{}|/;
    }
    return $value;
}

1;
