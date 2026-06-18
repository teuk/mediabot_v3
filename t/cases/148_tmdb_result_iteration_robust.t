# t/cases/148_tmdb_result_iteration_robust.t
# =============================================================================
# Regression checks for get_tmdb_info() result iteration.
#
# TMDB results should be handled defensively. The bot should not assume every
# result entry is a HASH with a defined media_type.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_tmdb_result_iteration {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_tmdb_result_iteration {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_tmdb_result_iteration(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $body = _extract_sub_body_tmdb_result_iteration($src, 'get_tmdb_info');

    $assert->ok(
        defined $body,
        'get_tmdb_info body found'
    );

    $assert->like(
        $src,
        qr/# Get TMDB info using HTTP::Tiny/,
        'TMDB comment mentions HTTP::Tiny instead of curl'
    );

    $assert->unlike(
        $src,
        qr/# Get TMDB info using curl/,
        'stale TMDB curl comment is gone'
    );

    $assert->like(
        $body // '',
        qr/foreach my \$item \(\@\{ \$data->\{results\} \}\)/,
        'get_tmdb_info iterates TMDB results'
    );

    $assert->like(
        $body // '',
        qr/next unless ref\(\$item\) eq 'HASH';/,
        'get_tmdb_info skips malformed non-HASH result entries'
    );

    $assert->like(
        $body // '',
        qr/my \$media_type = \$item->\{media_type\} \/\/ '';/,
        'get_tmdb_info handles missing media_type without warnings'
    );

    $assert->like(
        $body // '',
        qr/next unless \$media_type eq 'movie' \|\| \$media_type eq 'tv';/,
        'get_tmdb_info still selects only movie or tv results'
    );

    $assert->unlike(
        $body // '',
        qr/\$item->\{media_type\} eq 'movie'/,
        'get_tmdb_info no longer compares raw possibly-undef media_type'
    );
};
