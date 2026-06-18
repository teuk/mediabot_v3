# t/cases/199_youtube_colors_transparent_background.t
# =============================================================================
# Regression checks for YouTube IRC colors.
#
# Current rule:
#   - the [YouTube] badge may keep its intended background;
#   - everything displayed after the badge must use foreground-only helpers so
#     the title, duration, views, channel and URL keep transparent background.
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

sub _extract_sub_199 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    my $quote;
    my $escape = 0;
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

    my $src = _slurp_199(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    my $irc_color = _extract_sub_199($src, '_irc_color');
    my $label_body = _extract_sub_199($src, '_yt_label');

    $assert->ok(defined $irc_color && $irc_color ne '', '_irc_color body found');
    $assert->ok(defined $label_body && $label_body ne '', '_yt_label body found');

    $assert->like(
        $label_body // '',
        qr/return\s+"\\x0301,00\[You\\x0300,04Tube\\x0301,00\]\\x0f";/,
        'YouTube badge keeps the validated background badge and final reset'
    );

    $assert->like(
        $irc_color // '',
        qr/sprintf\("\\x03%02d",\s*\$fg\)\s*\.\s*\$text\s*\.\s*"\\x0f"/,
        '_irc_color renders foreground-only color and then resets'
    );

    $assert->unlike(
        $irc_color // '',
        qr/sprintf\(",%02d"/,
        '_irc_color cannot set a background color'
    );

    for my $helper (
        [ '_yt_text', 14 ],
        [ '_yt_sep',  7 ],
        [ '_yt_meta', 14 ],
    ) {
        my ($name, $fg) = @$helper;
        my $body = _extract_sub_199($src, $name);

        $assert->ok(defined $body && $body ne '', "$name body found");

        $assert->like(
            $body // '',
            qr/_irc_color\(\$_\[0\],\s*$fg\)/,
            "$name uses foreground-only _irc_color()"
        );
    }

    for my $sub (
        qw(
            getYoutubeDetails
            displayYoutubeDetails
            _youtube_html_fallback
            youtubeSearch_ctx
        )
    ) {
        my $body = _extract_sub_199($src, $sub);

        $assert->ok(defined $body && $body ne '', "$sub body found");

        $assert->unlike(
            $body // '',
            qr/String::IRC->new\([^)]*\)->(?:white|orange|grey|black)\('(?:black|white|red)'\)/,
            "$sub does not render post-badge text with forced background"
        );

        $assert->unlike(
            $body // '',
            qr/_yt_badge\(\)/,
            "$sub does not use stale _yt_badge()"
        );
    }
};
