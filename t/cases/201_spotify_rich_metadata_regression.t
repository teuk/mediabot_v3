# t/cases/201_spotify_rich_metadata_regression.t
# =============================================================================
# Regression checks for Spotify UrlTitle handling.
#
# Spotify must not output the useless shell title "Spotify – Web Player".
# It should try richer metadata sources and keep only the badge background,
# then hard-reset before the displayed text.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_201 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_spotify_body_201 {
    my ($src) = @_;

    return undef unless $src =~ /^sub\s+_handle_spotify\s*\{/mg;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

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

    my $src = _slurp_201(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Spotify.pm')
    );

    my $body = _extract_spotify_body_201($src);

    $assert->ok(defined $body && $body ne '', '_handle_spotify body found');

    $assert->like(
        $body // '',
        qr/open\.spotify\.com\/oembed\?url=/,
        'Spotify tries oEmbed first'
    );

    $assert->like(
        $body // '',
        qr/open\.spotify\.com\/embed\/\$spotify_type\/\$spotify_id/,
        'Spotify tries the embed page'
    );

    $assert->like(
        $body // '',
        qr/_fetch_url_chromium_dumpdom/,
        'Spotify keeps Chromium fallback'
    );

    $assert->like(
        $src,
        qr/Web Player/i,
        'Spotify explicitly rejects Spotify Web Player shell title'
    );

    $assert->like(
        $src,
        qr/duration_ms|duration_from_ms|format_iso_duration|duration_from_iso/,
        'Spotify tries to extract duration'
    );

    $assert->like(
        $body // '',
        qr/release_date|datePublished|year/,
        'Spotify tries to extract release year/date'
    );

    $assert->like(
        $body // '',
        qr/album\s+\$info\{album\}/,
        'Spotify output can include album'
    );

    $assert->like(
        $body // '',
        qr/by\s+\$info\{artist\}/,
        'Spotify output can include artist'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$badge\s*=\s*String::IRC->new\("\["\)->white\('black'\);/,
        'Spotify builds a badge object first'
    );

    $assert->like(
        $body // '',
        qr/String::IRC->new\("Spotify"\)->black\('green'\)/,
        'Spotify keeps its historical badge style'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+\$display";/,
        'Spotify hard-resets after badge before displayed text'
    );

    $assert->unlike(
        $body // '',
        qr/\$msg\s+\.=\s+String::IRC->new\("Spotify"\)->black\('green'\)/,
        'Spotify no longer appends displayed text through String::IRC msg object'
    );
};
