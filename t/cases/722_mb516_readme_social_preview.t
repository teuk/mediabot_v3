# t/cases/722_mb516_readme_social_preview.t
# =============================================================================
# MB516 — README social-preview contract.
#
# Keeps the historical 3.3 visual available without presenting it as the
# current 3.5 release identity.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_text_722 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _png_dimensions_722 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    read($fh, my $header, 24) == 24 or die "$path: short PNG header";
    close $fh;

    return unless substr($header, 0, 8) eq "\x89PNG\r\n\x1a\n";
    return unless substr($header, 12, 4) eq 'IHDR';

    return unpack('NN', substr($header, 16, 8));
}

return sub {
    my ($assert) = @_;

    my $readme_path = File::Spec->catfile('.', 'README.md');
    my $image_path = File::Spec->catfile(
        '.', 'docs', 'mediabot-3.3-github-social-preview.png'
    );

    $assert->ok(-f $readme_path, 'README exists');
    $assert->ok(-f $image_path, 'local Mediabot 3.3 preview image exists');

    my $readme = -f $readme_path ? _slurp_text_722($readme_path) : '';

    $assert->unlike(
        $readme,
        qr{<img\s+src="docs/mediabot-3\.3-github-social-preview\.png"[^>]*>},
        'README no longer embeds the historical Mediabot 3.3 preview'
    );
    $assert->unlike(
        $readme,
        qr{<a\s+href="https://github\.com/teuk/mediabot_v3/releases/tag/3\.3">\s*<img\s+src="docs/mediabot-3\.3-github-social-preview\.png"}s,
        'historical preview is not linked as the current stable release'
    );
    $assert->like(
        $readme,
        qr/releases\/tag\/3\.5.*?alt="Stable release 3\.5"/s,
        'README visual identity points to stable 3.5'
    );

    if (-f $image_path) {
        my ($width, $height) = _png_dimensions_722($image_path);
        $assert->is($width, 1280, 'preview width is 1280 pixels');
        $assert->is($height, 640, 'preview height is 640 pixels');
        $assert->ok(
            -s $image_path < 1_000_000,
            'preview stays below 1,000,000 bytes'
        );
    }
    else {
        $assert->ok(0, 'preview width is 1280 pixels');
        $assert->ok(0, 'preview height is 640 pixels');
        $assert->ok(0, 'preview stays below 1,000,000 bytes');
    }
};
