# t/cases/151_youtube_search_same_colors_as_link.t
# =============================================================================
# Regression checks for youtubeSearch_ctx() output formatting.
#
# The yt search command must use the same shared YouTube rendering helpers as
# automatic YouTube URL title rendering:
#
#   - _yt_label() keeps the YouTube badge style;
#   - _yt_text(), _yt_sep(), _yt_meta() render foreground-only text after the
#     badge so the title/metadata keep transparent/default background.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_151 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_between_151 {
    my ($src, $start_marker, $next_marker) = @_;

    my $start = index($src, $start_marker);
    return undef if $start < 0;

    my $end = index($src, $next_marker, $start);
    return undef if $end < 0;

    return substr($src, $start, $end - $start);
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_151(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    my $label_body = _extract_between_151(
        $src,
        'sub _yt_label {',
        '# ---------------------------------------------------------------------------' . "\n" . '# _extract_url'
    );

    my $search_body = _extract_between_151(
        $src,
        'sub youtubeSearch_ctx {',
        'sub getFortniteId {'
    );

    $assert->ok(defined $label_body && $label_body ne '', '_yt_label body found');
    $assert->ok(defined $search_body && $search_body ne '', 'youtubeSearch_ctx body found');

    $assert->like(
        $label_body // '',
        qr/return\s+"\\x0301,00\[You\\x0300,04Tube\\x0301,00\]\\x0f";/,
        '_yt_label keeps the validated YouTube badge style'
    );

    $assert->like(
        $search_body // '',
        qr/fields=items\(id,snippet\/title,snippet\/channelTitle,contentDetails\/duration,statistics\/viewCount\)/,
        'youtubeSearch_ctx requests id, title, channelTitle, duration and viewCount'
    );

    $assert->like(
        $search_body // '',
        qr/my\s+\$msg\s+=\s+_yt_label\(\);/,
        'youtubeSearch_ctx starts each result with the shared YouTube label'
    );

    $assert->like(
        $search_body // '',
        qr/my\s+\$entry\s+=\s+_yt_text\(" \$title "\);/,
        'youtubeSearch_ctx renders title through _yt_text()'
    );

    $assert->like(
        $search_body // '',
        qr/\$entry\s+\.=\s+_yt_sep\("- "\);/,
        'youtubeSearch_ctx renders separators through _yt_sep()'
    );

    $assert->like(
        $search_body // '',
        qr/\$entry\s+\.=\s+_yt_meta\("\$dur_disp "\);/,
        'youtubeSearch_ctx renders duration through _yt_meta()'
    );

    $assert->like(
        $search_body // '',
        qr/\$entry\s+\.=\s+_yt_meta\("\$views_disp "\);/,
        'youtubeSearch_ctx renders views through _yt_meta()'
    );

    $assert->like(
        $search_body // '',
        qr/\$entry\s+\.=\s+_yt_meta\("by \$channel_title "\);/,
        'youtubeSearch_ctx renders channel name through _yt_meta()'
    );

    $assert->like(
        $search_body // '',
        qr/\$entry\s+\.=\s+_yt_meta\(\$url\);/,
        'youtubeSearch_ctx renders result URL through _yt_meta()'
    );

    $assert->unlike(
        $search_body // '',
        qr/_yt_badge\(\)/,
        'youtubeSearch_ctx does not call stale _yt_badge()'
    );

    $assert->unlike(
        $search_body // '',
        qr/String::IRC->new\(" \$title "\)->white\('black'\)/,
        'youtubeSearch_ctx no longer uses old title background rendering'
    );

    $assert->unlike(
        $search_body // '',
        qr/String::IRC->new\("- "\)->orange\('black'\)/,
        'youtubeSearch_ctx no longer uses old separator background rendering'
    );
};
