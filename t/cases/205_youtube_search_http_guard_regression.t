# t/cases/205_youtube_search_http_guard_regression.t
# =============================================================================
# Regression checks for youtubeSearch_ctx() HTTP guards.
#
# Both YouTube API calls must be protected with eval just like the rest of
# Mediabot::External network code. Empty responses must be handled before JSON
# decoding.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_205 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_205 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
                $pos++;
                next;
            }

            if ($ch eq "\\") {
                $escape = 1;
                $pos++;
                next;
            }

            if ($ch eq $quote) {
                undef $quote;
                $pos++;
                next;
            }

            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
            $pos++;
            next;
        }

        if ($ch eq '"' || $ch eq "'") {
            $quote = $ch;
            $pos++;
            next;
        }

        if ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos + 1 - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_205(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_205($src, 'youtubeSearch_ctx');

    $assert->ok(
        defined $body && $body ne '',
        'youtubeSearch_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$res_s\s+=\s+eval\s+\{\s*\$http_s->get\(\$search_url\);\s*\}/,
        'search endpoint HTTP call is protected by eval'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$res_v\s+=\s+eval\s+\{\s*\$http_v->get\(\$videos_url\);\s*\}/,
        'videos endpoint HTTP call is protected by eval'
    );

    $assert->like(
        $body // '',
        qr/reason\s*=>\s*\$\@/,
        'youtubeSearch_ctx has fallback HTTP error structure with literal $@'
    );

    $assert->like(
        $body // '',
        qr/youtubeSearch_ctx\(\): empty search response/,
        'youtubeSearch_ctx rejects empty search response before JSON decode'
    );

    $assert->like(
        $body // '',
        qr/youtubeSearch_ctx\(\): empty videos response/,
        'youtubeSearch_ctx rejects empty videos response before JSON decode'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\$res_s\s+=\s+\$http_s->get\(\$search_url\);/,
        'search endpoint no longer calls HTTP without eval'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\$res_v\s+=\s+\$http_v->get\(\$videos_url\);/,
        'videos endpoint no longer calls HTTP without eval'
    );
};
