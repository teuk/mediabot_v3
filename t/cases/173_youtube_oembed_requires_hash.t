# t/cases/173_youtube_oembed_requires_hash.t
# =============================================================================
# Regression checks for _youtube_html_fallback().
#
# decode_json() can return valid JSON that is not a HASH.  The oEmbed fallback
# must verify the decoded response is a HASH before dereferencing title and
# author_name.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_youtube_oembed_guard {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_youtube_oembed_guard {
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

    my $src = _slurp_youtube_oembed_guard(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_youtube_oembed_guard($src, '_youtube_html_fallback');

    $assert->ok(
        defined $body,
        '_youtube_html_fallback body found'
    );

    $assert->like(
        $body // '',
        qr/my \$data = eval \{ decode_json\(\$res->\{content\}\) \};/,
        '_youtube_html_fallback still decodes oEmbed JSON under eval'
    );

    $assert->like(
        $body // '',
        qr/if \(\$\@ \|\| ref\(\$data\) ne 'HASH'\)/,
        '_youtube_html_fallback requires decoded oEmbed JSON to be a HASH'
    );

    $assert->like(
        $body // '',
        qr/oEmbed JSON parse\/structure error/,
        '_youtube_html_fallback logs parse or structure errors'
    );

    $assert->like(
        $body // '',
        qr/my \$title\s+= \$data->\{title\}\s+\/\/ '';/,
        '_youtube_html_fallback still reads title after HASH guard'
    );

    $assert->like(
        $body // '',
        qr/my \$author_name = \$data->\{author_name\} \/\/ '';/,
        '_youtube_html_fallback still reads author_name after HASH guard'
    );

    $assert->unlike(
        $body // '',
        qr/if \(\$\@ \|\| !ref \$data\)/,
        '_youtube_html_fallback no longer accepts any reference type'
    );
};
