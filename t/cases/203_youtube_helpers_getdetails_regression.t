# t/cases/203_youtube_helpers_getdetails_regression.t
# =============================================================================
# Regression checks for YouTube helpers and getYoutubeDetails().
#
# youtubeSearch_ctx() uses _yt_format_duration(), so the helper must exist.
# getYoutubeDetails() is used by radio/play helpers and must not blindly
# dereference malformed YouTube API responses.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_203 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_between_203 {
    my ($src, $start_marker, $next_marker) = @_;

    my $start = index($src, $start_marker);
    return undef if $start < 0;

    my $end = index($src, $next_marker, $start);
    return undef if $end < 0;

    return substr($src, $start, $end - $start);
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_203(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    $assert->like(
        $src,
        qr/sub\s+_yt_format_duration\s*\{/,
        '_yt_format_duration helper exists'
    );

    $assert->like(
        $src,
        qr/sub\s+_yt_duration_seconds\s*\{/,
        '_yt_duration_seconds helper exists'
    );

    $assert->like(
        $src,
        qr/my\s+\$dur_disp\s+=\s+_yt_format_duration\(\$dur_iso\);/,
        'youtubeSearch_ctx uses the shared YouTube duration formatter'
    );

    my $body = _extract_between_203(
        $src,
        'sub getYoutubeDetails {',
        '# Display Youtube details'
    );

    $assert->ok(
        defined $body && $body ne '',
        'getYoutubeDetails body found'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$sYoutubeInfo->\{items\}\)\s+eq\s+'ARRAY'/,
        'getYoutubeDetails verifies items is an ARRAY'
    );

    $assert->like(
        $body // '',
        qr/unless\s+\(\@items\s+&&\s+ref\(\$items\[0\]\)\s+eq\s+'HASH'\)/,
        'getYoutubeDetails verifies first item is a HASH'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$statistics\s+=\s+ref\(\$item->\{statistics\}\)\s+eq\s+'HASH'/,
        'getYoutubeDetails guards statistics hash'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$snippet\s+=\s+ref\(\$item->\{snippet\}\)\s+eq\s+'HASH'/,
        'getYoutubeDetails guards snippet hash'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$localized\s+=\s+ref\(\$snippet->\{localized\}\)\s+eq\s+'HASH'/,
        'getYoutubeDetails guards localized hash'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$contentDetails\s+=\s+ref\(\$item->\{contentDetails\}\)\s+eq\s+'HASH'/,
        'getYoutubeDetails guards contentDetails hash'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$sTitle\s+=\s+\$localized->\{title\}\s+\/\/\s+\$snippet->\{title\}\s+\/\/\s+'';/,
        'getYoutubeDetails falls back from localized title to snippet title'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$sDisplayDuration\s+=\s+_yt_format_duration\(\$sDuration\);/,
        'getYoutubeDetails uses shared duration formatter'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$duration_seconds\s+=\s+_yt_duration_seconds\(\$sDuration\);/,
        'getYoutubeDetails uses shared duration seconds helper'
    );

    $assert->like(
        $body // '',
        qr/return\s+\(\$duration_seconds,\s+\$sMsgSong\);/,
        'getYoutubeDetails returns duration seconds and message'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\@fTyoutubeItems\s+=\s+\@\{\$tYoutubeItems\[0\]\};/,
        'getYoutubeDetails no longer blindly dereferences items'
    );

    $assert->unlike(
        $body // '',
        qr/\$hYoutubeItems\{snippet\}\{localized\}\{title\}/,
        'getYoutubeDetails no longer directly dereferences snippet.localized.title'
    );
};
