# t/cases/151_youtube_search_same_colors_as_link.t
# =============================================================================
# Regression checks for YouTube search output formatting after MB320 split the
# blocking API worker from the IRC command callback.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_151 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _sub_151 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;
    my $src = _slurp_151(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $label   = _sub_151($src, '_yt_label');
    my $format  = _sub_151($src, '_youtube_search_format_entry');
    my $command = _sub_151($src, 'youtubeSearch_ctx');

    $assert->ok(defined $label, '_yt_label found');
    $assert->ok(defined $format, '_youtube_search_format_entry found');
    $assert->ok(defined $command, 'youtubeSearch_ctx found');
    $assert->like($label // '', qr/\[You.*Tube/s,
        '_yt_label keeps the YouTube badge');
    $assert->like($format // '', qr/_yt_text\(" \$title "\)/,
        'title uses _yt_text');
    $assert->like($format // '', qr/_yt_sep\('- '\)/,
        'separators use _yt_sep');
    $assert->like($format // '', qr/_yt_meta\("\$dur_disp "\)/,
        'duration uses _yt_meta');
    $assert->like($format // '', qr/_yt_meta\("\$views_disp "\)/,
        'views use _yt_meta');
    $assert->like($format // '', qr/_yt_meta\("by \$channel_title "\)/,
        'channel title uses _yt_meta');
    $assert->like($format // '', qr/_yt_link\("https:\/\/www\.youtube\.com\/watch\?v=\$video_id"\)/,
        'result URL is rendered by the shared blue-underlined link helper');
    $assert->like($command // '', qr/my\s+\$msg\s*=\s*_yt_label\(\)/,
        'each result starts with the shared label');
    $assert->unlike($format // '', qr/_yt_badge\(\)/,
        'stale _yt_badge is absent');
    $assert->unlike($format // '', qr/String::IRC->new/,
        'old background-specific rendering is absent');
};
