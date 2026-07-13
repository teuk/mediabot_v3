# t/cases/722_mb516_readme_social_preview.t
# =============================================================================
# MB516 — README social-preview contract.
#
# Keeps the public README visual tied to a real, repository-local, GitHub-sized
# PNG instead of a stale or external image.
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

    $assert->like(
        $readme,
        qr{<img\s+src="docs/mediabot-3\.3-github-social-preview\.png"[^>]*>},
        'README embeds the repository-local Mediabot 3.3 preview'
    );
    $assert->like(
        $readme,
        qr{<a\s+href="https://github\.com/teuk/mediabot_v3/releases/tag/3\.3">\s*<img\s+src="docs/mediabot-3\.3-github-social-preview\.png"}s,
        'preview links to the stable 3.3 release'
    );
    $assert->like(
        $readme,
        qr/alt="Mediabot 3\.3 [^"]*long-running communities"/,
        'preview has useful alternative text'
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
