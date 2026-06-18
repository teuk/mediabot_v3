# t/cases/150_youtube_search_uses_imported_uri_escape_utf8.t
# =============================================================================
# Regression checks for youtubeSearch_ctx().
#
# External/YouTube.pm imports uri_escape_utf8 from URI::Escape, not url_encode_utf8
# from URL::Encode.  youtubeSearch_ctx must not call an undefined helper.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_youtube_search_encoding {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_youtube_search_encoding {
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

    my $src = _slurp_youtube_search_encoding(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    my $body = _extract_sub_body_youtube_search_encoding($src, 'youtubeSearch_ctx');

    $assert->ok(
        defined $body,
        'youtubeSearch_ctx body found'
    );

    $assert->like(
        $src,
        qr/^use URI::Escape qw\(uri_escape_utf8\);$/m,
        'External/YouTube.pm imports uri_escape_utf8'
    );

    $assert->like(
        $body // '',
        qr/my \$q_enc\s+= uri_escape_utf8\(\$query_txt\);/,
        'youtubeSearch_ctx encodes the YouTube search query with uri_escape_utf8'
    );

    $assert->like(
        $body // '',
        qr/&q=\$q_enc/,
        'youtubeSearch_ctx uses the encoded query in the YouTube search URL'
    );

    $assert->unlike(
        $body // '',
        qr/url_encode_utf8\(\$query_txt\)/,
        'youtubeSearch_ctx no longer calls undefined url_encode_utf8'
    );

    $assert->unlike(
        $src,
        qr/use URL::Encode/,
        'External.pm does not depend on URL::Encode for youtubeSearch_ctx'
    );
};
