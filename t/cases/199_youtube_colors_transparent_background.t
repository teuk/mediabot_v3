# t/cases/199_youtube_colors_transparent_background.t
# =============================================================================
# Regression checks for YouTube IRC colors.
#
# YouTube output must not force background colors. Forced backgrounds render
# badly on some IRC themes. Use foreground colors only, so the client background
# remains transparent/default.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_199 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_199 {
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

    my $src = _slurp_199(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my @youtube_subs = qw(
        getYoutubeDetails
        displayYoutubeDetails
        _youtube_html_fallback
        _yt_label
        youtubeSearch_ctx
    );

    for my $sub (@youtube_subs) {
        my $body = _extract_sub_body_199($src, $sub);

        $assert->ok(defined $body, "$sub body found");

        $assert->unlike(
            $body // '',
            qr/->(?:white|orange|grey|black)\('(?:black|white|red)'\)/,
            "$sub does not force IRC background colors"
        );
    }

    $assert->like(
        $src,
        qr/String::IRC->new\('You'\)->white\(\)/,
        'YouTube label uses foreground-only white for You'
    );

    $assert->like(
        $src,
        qr/String::IRC->new\('Tube'\)->red\(\)/,
        'YouTube label uses foreground-only red for Tube'
    );

    $assert->like(
        $src,
        qr/String::IRC->new\("- "\)->orange\(\)/,
        'YouTube separators use foreground-only orange'
    );

    $assert->like(
        $src,
        qr/String::IRC->new\("\$views_disp "\)->grey\(\)/,
        'YouTube search metadata uses foreground-only grey'
    );

    $assert->like(
        $src,
        qr/String::IRC->new\("\$sViewCount "\)->grey\(\)/,
        'YouTube direct-link metadata uses foreground-only grey'
    );
};
