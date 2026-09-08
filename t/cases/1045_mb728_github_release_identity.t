# MB728 — GitHub presentation must stay truthful to the stable 3.5 runtime.

use strict;
use warnings;
use utf8;

sub _slurp_1045 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $readme = _slurp_1045('README.md');
    my $preview = _slurp_1045('docs/mediabot-3.5-github-social-preview.svg');
    my $version = _slurp_1045('VERSION');
    $version =~ s/\s+\z//;

    $assert->like($version, qr/^3\.6dev-[0-9]{8}_[0-9]{6}$/,
        'mb731: moving source identity is the timestamped 3.6 development line');

    for my $workflow (qw(ci debian13)) {
        $assert->like(
            $readme,
            qr{actions/workflows/\Q$workflow\E\.yml/badge\.svg\?branch=master&event=push},
            "mb728: $workflow badge is backed by the real push workflow"
        );
    }

    $assert->like($readme, qr/alt="Tested with Perl 5\.40"/,
        'mb728: tested Perl baseline is visible');
    $assert->unlike($readme, qr{(?:codecov|coveralls)\.io}i,
        'mb728: README does not invent a coverage provider');
    $assert->unlike($readme, qr{badge/(?:tests|coverage)-passing}i,
        'mb728: README does not present a static passing badge as live evidence');

    $assert->like(
        $readme,
        qr{releases/tag/3\.5">\s*<img\s+src="docs/mediabot-3\.5-github-social-preview\.png"}s,
        'mb728: 3.5 hero points at the matching release'
    );
    $assert->unlike($readme, qr{<img[^>]+mediabot-3\.3-github-social-preview\.png},
        'mb728: historical 3.3 artwork is not presented as current');

    for my $truth (
        'Net::Async::IRC',
        'MariaDB',
        'Hailo',
        'Gemini',
        'mbweb',
        'Prometheus',
        'read-only by default',
    ) {
        $assert->like($readme, qr/\Q$truth\E/i,
            "mb728: README names the real $truth boundary");
        $assert->like($preview, qr/\Q$truth\E/i,
            "mb728: preview names the real $truth boundary")
            unless $truth eq 'read-only by default';
    }

    $assert->like($readme, qr/927 files · 18,760 assertions passed/,
        'mb728: final suite result is identified as release evidence');
    $assert->like($readme, qr/37\/37 fail-closed security invariants across 16 axes/,
        'mb728: cross-cutting audit evidence is exact');
    $assert->like($readme, qr/Tagged commit `a55d030`/,
        'mb728: published source evidence names the stable commit');
    $assert->like($readme, qr/These are release-gate results.*not rolling coverage claims/s,
        'mb728: historical evidence is not misrepresented as live coverage');

    $assert->like($readme, qr/```mermaid\s+flowchart TB/s,
        'mb728: README includes a maintainable runtime diagram');
    $assert->like($preview, qr/viewBox="0 0 1280 640"/,
        'mb728: editable preview preserves GitHub social dimensions');
    $assert->like($preview, qr/18,760 TESTS/,
        'mb728: preview carries the accepted suite result');
    $assert->like($preview, qr/37 SECURITY INVARIANTS/,
        'mb728: preview carries the accepted audit result');
};
