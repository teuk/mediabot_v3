package Mediabot::IRC::Glob;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(glob_pattern);

# Return a quoted regex fragment for IRC's * and ? wildcards. Callers retain
# their own anchors and flags: Auth uses a strict string end, whereas the
# historical ChannelBan matcher accepts its existing line-end behavior.
# No I/O, cache, caller policy or authentication decision belongs here.
sub glob_pattern {
    my ($glob) = @_;
    $glob //= '';
    my @pieces = map {
        my $fixed = quotemeta($_);
        $fixed =~ s/\\\?/./g;
        $fixed;
    } split /\*+/, $glob, -1;
    my $pattern = shift(@pieces) // '';
    if (@pieces) {
        my $last = pop @pieces;
        # Commit each interior fixed piece at its earliest occurrence. A
        # later failure cannot redistribute all previous star matches.
        $pattern .= '(?>.*?' . $_ . ')' for @pieces;
        $pattern .= '.*' . $last;
    }
    return $pattern;
}

1;
