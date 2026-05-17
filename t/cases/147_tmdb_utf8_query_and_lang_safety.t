# t/cases/147_tmdb_utf8_query_and_lang_safety.t
# =============================================================================
# Regression checks for TMDB URL construction.
#
# Movie searches can contain accents and Unicode. get_tmdb_info() should use
# uri_escape_utf8(), not byte-oriented uri_escape(), and should not trust a raw
# language value from the database directly in the URL.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_tmdb_utf8 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_tmdb_utf8 {
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

    my $src = _slurp_tmdb_utf8(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_tmdb_utf8($src, 'get_tmdb_info');

    $assert->ok(
        defined $body,
        'get_tmdb_info body found'
    );

    $assert->like(
        $src,
        qr/use URI::Escape qw\(uri_escape_utf8 uri_escape\);/,
        'External.pm imports uri_escape_utf8'
    );

    $assert->like(
        $body // '',
        qr/\$lang = 'en-US'\s+unless defined\(\$lang\) && \$lang =~ \/\^\[A-Za-z\]\{2\}\(\?:-\[A-Za-z\]\{2\}\)\?\\z\//,
        'get_tmdb_info validates TMDB language format'
    );

    $assert->like(
        $body // '',
        qr/my \$encoded_query = uri_escape_utf8\(\$query\);/,
        'get_tmdb_info encodes search query as UTF-8'
    );

    $assert->like(
        $body // '',
        qr/my \$encoded_lang\s+= uri_escape_utf8\(\$lang\);/,
        'get_tmdb_info encodes language parameter'
    );

    $assert->like(
        $body // '',
        qr/language=\$encoded_lang.*query=\$encoded_query/s,
        'get_tmdb_info uses encoded language and encoded query in URL'
    );

    $assert->unlike(
        $body // '',
        qr/my \$encoded_query = uri_escape\(\$query\);/,
        'get_tmdb_info no longer uses uri_escape() for movie query text'
    );

    $assert->unlike(
        $body // '',
        qr/language=\$lang&query=\$encoded_query/,
        'get_tmdb_info no longer inserts raw language into URL'
    );
};
