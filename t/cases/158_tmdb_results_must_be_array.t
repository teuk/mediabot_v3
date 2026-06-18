# t/cases/158_tmdb_results_must_be_array.t
# =============================================================================
# Regression checks for get_tmdb_info() JSON result guards.
#
# TMDB JSON can be valid but malformed from our point of view.  The code must
# verify that results is an ARRAY before dereferencing it with @{ ... }.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_tmdb_results_array_guard {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_tmdb_results_array_guard {
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

    my $src = _slurp_tmdb_results_array_guard(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $body = _extract_sub_body_tmdb_results_array_guard($src, 'get_tmdb_info');

    $assert->ok(
        defined $body,
        'get_tmdb_info body found'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data\) ne 'HASH'/,
        'get_tmdb_info verifies decoded JSON is a HASH'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$data->\{results\}\) eq 'ARRAY'/,
        'get_tmdb_info verifies results is an ARRAY before dereferencing'
    );

    $assert->like(
        $body // '',
        qr/\@\{ \$data->\{results\} \}/,
        'get_tmdb_info still rejects empty results arrays'
    );

    $assert->like(
        $body // '',
        qr/foreach my \$item \(\@\{ \$data->\{results\} \}\)/,
        'get_tmdb_info iterates results only after the ARRAY guard'
    );

    $assert->like(
        $body // '',
        qr/next unless ref\(\$item\) eq 'HASH';/,
        'get_tmdb_info remains defensive for individual result entries'
    );

    $assert->unlike(
        $body // '',
        qr/return undef if \$\@ \|\| !ref\(\$data\) \|\| !\$data->\{results\} \|\| !\@\{\$data->\{results\}\};/,
        'get_tmdb_info no longer dereferences results before checking it is an ARRAY'
    );
};
