# MB726 — release identity is explicit and rehearsals cannot masquerade as releases.

use strict;
use warnings;
use utf8;

sub _slurp_1041 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $builder = _slurp_1041('tools/build_release_artifacts.sh');
    my $rehearse = _slurp_1041('tools/rehearse_release_artifacts.sh');
    my $doc = _slurp_1041('docs/RELEASING.md');

    $assert->like($builder, qr/^VERSION=""$/m,
        'mb726: release builder has no implicit version');
    $assert->like($builder, qr/^REF=""$/m,
        'mb726: release builder has no implicit ref');
    $assert->like($builder, qr/--rehearsal\)/,
        'mb726: builder exposes a bounded rehearsal mode');
    $assert->like($builder, qr/rehearsal target must be an odd stable X\.Y version/,
        'mb726: rehearsal requires a stable target identity');
    $assert->like($builder, qr/DEV_MINOR=\$\(\(VERSION_MINOR - 1\)\)/,
        'mb726: rehearsal derives the preceding development line');
    $assert->like($builder,
        qr/BASE="mediabot_v3-\$\{VERSION\}-rehearsal-\$\{SHORT_COMMIT\}"/,
        'mb726: rehearsal artifact names cannot look publishable');
    $assert->like($builder, qr/yes \(not publishable\)/,
        'mb726: rehearsal metadata rejects publication');

    $assert->like($rehearse,
        qr/"\$BUILDER" --version "\$VERSION" --ref "\$REF" --dest "\$FIRST" --rehearsal/,
        'mb726: first build uses explicit candidate identity');
    $assert->like($rehearse,
        qr/"\$BUILDER" --version "\$VERSION" --ref "\$REF" --dest "\$SECOND" --rehearsal/,
        'mb726: second build repeats the exact invocation');
    $assert->like($rehearse, qr/cmp --silent "\$FIRST\/\$artifact" "\$SECOND\/\$artifact"/,
        'mb726: every artifact is compared byte for byte');
    $assert->like($rehearse, qr/sha256sum --quiet -c/,
        'mb726: rehearsal verifies SHA-256 manifests');
    $assert->like($rehearse, qr/sha512sum --quiet -c/,
        'mb726: rehearsal verifies SHA-512 manifests');
    $assert->like($rehearse, qr/RELEASE_REHEARSAL=OK/,
        'mb726: rehearsal has one explicit success marker');
    $assert->unlike($rehearse, qr/\bgit\s+(?:add|commit|tag|push|reset|checkout)\b/,
        'mb726: rehearsal never mutates Git');

    $assert->like($doc, qr/^## 0\. Rehearse the artifacts from the committed candidate$/m,
        'mb726: release guide starts with the candidate rehearsal');
    $assert->like($doc, qr/RELEASE_REHEARSAL=OK/,
        'mb726: release guide requires the success marker');
    $assert->like($doc, qr/neither changes the repository nor produces a stable\s+release artifact/s,
        'mb726: release guide states the rehearsal boundary');
};
