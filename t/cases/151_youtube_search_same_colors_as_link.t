# t/cases/151_youtube_search_same_colors_as_link.t
# =============================================================================
# Regression checks for youtubeSearch_ctx() output formatting.
#
# The yt search command should use the same YouTube color style as automatic
# YouTube URL title rendering.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_youtube_search_colors {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_youtube_search_colors {
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

    my $src = _slurp_youtube_search_colors(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $label_body  = _extract_sub_body_youtube_search_colors($src, '_yt_label');
    my $search_body = _extract_sub_body_youtube_search_colors($src, 'youtubeSearch_ctx');

    $assert->ok(defined $label_body,  '_yt_label body found');
    $assert->ok(defined $search_body, 'youtubeSearch_ctx body found');

    $assert->like(
        $label_body // '',
        qr/String::IRC->new\('\['\)->white\('black'\)/,
        '_yt_label builds the same bracket color style'
    );

    $assert->like(
        $search_body // '',
        qr/fields=items\(snippet\/title,snippet\/channelTitle,contentDetails\/duration,statistics\/viewCount\)/,
        'youtubeSearch_ctx requests channelTitle for matching link output'
    );

    $assert->like(
        $search_body // '',
        qr/my \$msg = _yt_label\(\);/,
        'youtubeSearch_ctx starts output with shared YouTube label'
    );

    $assert->like(
        $search_body // '',
        qr/String::IRC->new\(" \$title "\)->white\('black'\)/,
        'youtubeSearch_ctx colors title like YouTube URL output'
    );

    $assert->like(
        $search_body // '',
        qr/String::IRC->new\("- "\)->orange\('black'\)/,
        'youtubeSearch_ctx uses orange separators like YouTube URL output'
    );

    $assert->like(
        $search_body // '',
        qr/String::IRC->new\("\$views_disp "\)->grey\('black'\)/,
        'youtubeSearch_ctx colors views like YouTube URL output'
    );

    $assert->like(
        $search_body // '',
        qr/String::IRC->new\("by \$channel_title "\)->grey\('black'\)/,
        'youtubeSearch_ctx colors channel name like YouTube URL output'
    );

    $assert->like(
        $search_body // '',
        qr/String::IRC->new\(\$url\)->grey\('black'\)/,
        'youtubeSearch_ctx keeps the result URL with the same metadata color'
    );

    $assert->unlike(
        $search_body // '',
        qr/_yt_badge\(\)/,
        'youtubeSearch_ctx no longer calls undefined/non-shared _yt_badge'
    );

    $assert->unlike(
        $search_body // '',
        qr/my \$msg = "\$badge \$url"/,
        'youtubeSearch_ctx no longer builds a plain uncolored message'
    );
};
