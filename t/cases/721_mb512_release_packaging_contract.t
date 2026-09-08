# t/cases/721_mb512_release_packaging_contract.t
# =============================================================================
# mb512 / mb726 — explicit stable release identity and artifact contract.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_721 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $builder = File::Spec->catfile('.', 'tools', 'build_release_artifacts.sh');
    my $release_doc = File::Spec->catfile('.', 'docs', 'RELEASING.md');
    my $attrs = File::Spec->catfile('.', '.gitattributes');

    $assert->ok(-f $builder, 'release artifact builder exists');
    $assert->ok(-x $builder, 'release artifact builder is executable');
    $assert->ok(-f $release_doc, 'release workflow documentation exists');
    $assert->ok(-f $attrs, 'release export attributes exist');

    my $script = _slurp_721($builder);
    my $doc = _slurp_721($release_doc);
    my $gitattributes = _slurp_721($attrs);
    my $readme = _slurp_721(File::Spec->catfile('.', 'README.md'));
    my $changelog = _slurp_721(File::Spec->catfile('.', 'CHANGELOG.md'));

    $assert->like($script, qr/git archive --format=tar --prefix="\$PREFIX" "\$REF"/,
        'builder archives the selected committed Git ref');
    $assert->like($script, qr/^VERSION=""$/m,
        'builder has no stale implicit release version');
    $assert->like($script, qr/^REF=""$/m,
        'builder has no stale implicit release ref');
    $assert->like($script, qr/ERROR: --version X\.Y is required/,
        'builder requires an explicit release version');
    $assert->like($script, qr/ERROR: --ref REF is required/,
        'builder requires an explicit release ref');
    $assert->like($script, qr/gzip -n -9 -c/,
        'gzip artifact is deterministic');
    $assert->like($script, qr/xz -T1 -9e --check=crc64 -c/,
        'xz artifact is deterministic');
    $assert->like($script, qr/sha256sum .*\.tar\.gz.*\.tar\.xz/,
        'builder creates SHA-256 sums for both archives');
    $assert->like($script, qr/sha512sum .*\.tar\.gz.*\.tar\.xz/,
        'builder creates SHA-512 sums for both archives');
    $assert->like($script, qr/for path in Mediabot contrib docs install plugins t tools/,
        'builder requires contrib and plugins with the core trees');
    $assert->like($script, qr/commit\\\.sh.*mediabot\\\.conf.*mp3\/.*node_modules/s,
        'builder rejects local/runtime-only archive paths');
    $assert->like($script, qr/VERSION at \$REF is/,
        'builder rejects a ref whose VERSION is not the stable version');
    $assert->like($script, qr/does not point at HEAD/,
        'builder requires the release ref to point at HEAD');
    $assert->like($script, qr/BASE="mediabot_v3-\$\{VERSION\}"/,
        'builder preserves the historical mediabot_v3-X.Y artifact name');
    $assert->like($script, qr/SHA256="\$WORK\/\$\{BASE\}-SHA256SUMS"/,
        'builder uses a versioned SHA-256 manifest');
    $assert->like($script, qr/SHA512="\$WORK\/\$\{BASE\}-SHA512SUMS"/,
        'builder uses a versioned SHA-512 manifest');

    $assert->like($gitattributes, qr/^node_modules export-ignore$/m,
        'root node_modules is export-ignored');
    $assert->like($gitattributes, qr/^\*\*\/node_modules export-ignore$/m,
        'nested node_modules directories are export-ignored');
    $assert->like($gitattributes, qr/^commit\.sh export-ignore$/m,
        'local commit helper is export-ignored');
    $assert->like($gitattributes, qr/^mp3 export-ignore$/m,
        'runtime MP3 directory is export-ignored');

    $assert->like($doc, qr/release_dest='\/home\/wws\/downloads\/mediabot'/,
        'release documentation records the requested server destination');
    $assert->like($doc, qr/release_version='3\.5'/,
        'release documentation prepares the intended 3.5 identity explicitly');
    $assert->like($doc, qr/--version "\$release_version"/,
        'release documentation passes the explicit version to the builder');
    $assert->like($doc, qr/--ref "\$release_ref"/,
        'release documentation passes the exact ref to the builder');
    $assert->like($doc, qr/mediabot_v3-3\.5-SHA256SUMS/,
        'release documentation names the planned 3.5 SHA-256 manifest');
    $assert->like($doc, qr/mediabot_v3-3\.5-SHA512SUMS/,
        'release documentation names the planned 3.5 SHA-512 manifest');
    $assert->like($doc, qr/does not declare it stable/,
        'release preparation does not prematurely publish 3.5');

    $assert->like($readme, qr/3\.5\s+current stable release/i,
        'README marks 3.5 as current stable');
    $assert->like($readme, qr/3\.6dev\s+current development line/i,
        'README names the current development line');
    $assert->like($changelog, qr/^##\s*\[3\.5\]\s+\x{2014}\s+2026-09-06/m,
        'CHANGELOG dates the 3.5 release');
    $assert->unlike($changelog, qr/^##\s*\[3\.5\].*(?:unreleased|target)/mi,
        'CHANGELOG does not mark 3.5 as unreleased');
};
