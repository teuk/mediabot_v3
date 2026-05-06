# t/cases/152_external_x_handler_chromium.t
# =============================================================================
# Regression checks for dedicated X/Twitter URL title handling.
#
# X/Twitter links should not be ignored silently. They should go through a
# dedicated Chromium path, then fall back to honest URL-based labels.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_external_x_handler {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_external_x_handler {
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

    my $src = _slurp_external_x_handler(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $display_body = _extract_sub_body_external_x_handler($src, 'displayUrlTitle');
    my $url_body     = _extract_sub_body_external_x_handler($src, '_x_url');
    my $title_body   = _extract_sub_body_external_x_handler($src, '_x_title_from_html');
    my $fallback     = _extract_sub_body_external_x_handler($src, '_x_fallback_title_from_url');
    my $handler_body = _extract_sub_body_external_x_handler($src, '_handle_x_twitter');

    $assert->ok(defined $display_body, 'displayUrlTitle body found');
    $assert->ok(defined $url_body,     '_x_url body found');
    $assert->ok(defined $title_body,   '_x_title_from_html body found');
    $assert->ok(defined $fallback,     '_x_fallback_title_from_url body found');
    $assert->ok(defined $handler_body, '_handle_x_twitter body found');

    $assert->like(
        $src,
        qr/^\s+_handle_x_twitter$/m,
        '_handle_x_twitter is exported'
    );

    $assert->like(
        $url_body // '',
        qr/twitter\\\.com/,
        '_x_url accepts twitter.com'
    );

    $assert->like(
        $url_body // '',
        qr/https:\/\/x\.com\//,
        '_x_url normalizes to x.com'
    );

    $assert->like(
        $title_body // '',
        qr/og:title|twitter:title/,
        '_x_title_from_html looks for OpenGraph/Twitter title metadata'
    );

    $assert->like(
        $handler_body // '',
        qr/_fetch_url_chromium_dumpdom/,
        '_handle_x_twitter uses Chromium rendered DOM'
    );

    $assert->like(
        $handler_body // '',
        qr/virtual_time_budget => 6500/,
        '_handle_x_twitter uses a dedicated Chromium virtual time budget'
    );

    $assert->like(
        $handler_body // '',
        qr/alarm_timeout\s+=> 16/,
        '_handle_x_twitter uses a bounded Chromium alarm timeout'
    );

    $assert->like(
        $fallback // '',
        qr/X post by \\\@\$owner/,
        '_x_fallback_title_from_url handles status URLs'
    );

    $assert->like(
        $fallback // '',
        qr/X profile: \\\@\$owner/,
        '_x_fallback_title_from_url handles profile URLs'
    );

    $assert->like(
        $display_body // '',
        qr/_handle_x_twitter\(\$self, \$message, \$sNick, \$sChannel, \$url\)/,
        'displayUrlTitle dispatches X/Twitter to the dedicated handler'
    );

    $assert->unlike(
        $display_body // '',
        qr/Twitter \/ X .+ ignored silently/,
        'displayUrlTitle no longer documents X/Twitter as ignored silently'
    );

    $assert->unlike(
        $display_body // '',
        qr/return undef if \$url =~ m\{https\?:\/\/\(\?:www\\\.\)\?\(\?:twitter\|x\)\\\.com\/\}i;/,
        'displayUrlTitle no longer silently returns undef for X/Twitter URLs'
    );

    my $x_pos       = index($display_body // '', '_handle_x_twitter($self, $message, $sNick, $sChannel, $url)');
    my $generic_pos = index($display_body // '', '_handle_generic_title($self, $message, $sNick, $sChannel, $url)');

    $assert->ok(
        $x_pos >= 0 && $generic_pos >= 0 && $x_pos < $generic_pos,
        'X/Twitter dispatch happens before the generic handler'
    );
};
