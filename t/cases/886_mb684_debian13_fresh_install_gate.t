# t/cases/886_mb684_debian13_fresh_install_gate.t
# =============================================================================
# MB684 — Debian 13 must have a real CI fresh-install/configuration gate.
# The gate backs the public badge without changing runtime behavior.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_886 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $workflow = _slurp_886(File::Spec->catfile('.', '.github', 'workflows', 'debian13.yml'));
    my $readme   = _slurp_886(File::Spec->catfile('.', 'README.md'));
    my $cfgdoc   = _slurp_886(File::Spec->catfile('.', 'docs', 'CONFIGURE.md'));
    my $configure= _slurp_886(File::Spec->catfile('.', 'configure'));

    $assert->like(
        $workflow,
        qr/^name:\s*Debian 13 fresh-install gate\s*$/m,
        'dedicated Debian 13 workflow has a stable public name',
    );
    $assert->like(
        $workflow,
        qr/container:\s*\n\s*image:\s*debian:13-slim\s*$/m,
        'fresh-install job runs in the official Debian 13 slim container',
    );
    $assert->like(
        $workflow,
        qr/test "\$ID" = debian.*?test "\$VERSION_ID" = 13/s,
        'workflow fails closed unless the container identifies as Debian 13',
    );
    $assert->like(
        $workflow,
        qr/expected Debian 13 system Perl 5\.40\.x.*?\$\] >= 5\.040 && \$\] < 5\.041/s,
        'workflow verifies the Debian system Perl 5.40 baseline',
    );

    for my $pkg (qw(
        sudo git curl wget jq unzip zip perl build-essential make gcc pkg-config
        mariadb-server mariadb-client libmariadb-dev
    )) {
        $assert->like(
            $workflow,
            qr/^\s*\Q$pkg\E\s*(?:\\)?\s*$/m,
            "Debian 13 workflow installs bootstrap package $pkg",
        );
    }

    $assert->unlike(
        $workflow,
        qr/^\s*libdbi-perl\s*(?:\\)?\s*$/m,
        'Debian 13 workflow does not replace CPAN DBI with a Debian Perl package',
    );
    $assert->unlike(
        $workflow,
        qr/^\s*libdbd-(?:mariadb|mysql)-perl\s*(?:\\)?\s*$/m,
        'Debian 13 workflow does not replace CPAN DBD drivers with Debian Perl packages',
    );

    $assert->like(
        $workflow,
        qr/cpanm --notest --local-lib "\$GITHUB_WORKSPACE\/local" --installdeps \./,
        'CI builds cpanfile dependencies against the Debian system Perl in an isolated local library',
    );
    $assert->like(
        $workflow,
        qr/bash install\/cpan_install\.sh --verify-only/,
        'supported runtime module verifier validates the resulting dependency set',
    );
    $assert->like(
        $workflow,
        qr/Hailo-0\.75\.tar\.gz/,
        'Debian 13 gate retains the supported pinned Hailo fallback',
    );

    $assert->like(
        $workflow,
        qr/adduser --disabled-password --gecos '' mediabot/,
        'fresh configuration is exercised with a dedicated Mediabot account',
    );
    $assert->like(
        $workflow,
        qr/sudo -u mediabot env.*?\.\/configure.*?--sync-only.*?--skip-db.*?--skip-cpan.*?--yes/s,
        'workflow executes the real configure entry point as non-root in safe fresh mode',
    );
    $assert->like(
        $workflow,
        qr/test "\$\(stat -c %a mediabot\.conf\)" = 600/,
        'fresh-install gate verifies private generated config permissions',
    );
    $assert->like(
        $workflow,
        qr/PARTYLINE_EVAL_ENABLED.*?0/,
        'fresh-install gate verifies Partyline eval stays disabled',
    );
    $assert->like(
        $workflow,
        qr/configure_config\.pl.*?--mode audit.*?--strict.*?--quiet/s,
        'fresh-install gate finishes with the strict sample-driven config audit',
    );
    $assert->like(
        $workflow,
        qr/-f '\^\(.*?886_.*?\)'/,
        'workflow still runs the MB684 contract in the expanded fresh-install contract set',
    );

    $assert->like(
        $readme,
        qr/actions\/workflows\/debian13\.yml.*?Debian 13 fresh-install gate.*?debian13\.yml\/badge\.svg/s,
        'README Debian badge is backed by the dedicated live workflow',
    );
    $assert->like(
        $readme,
        qr/official `debian:13-slim` container.*?system Perl 5\.40.*?cpan_install\.sh --verify-only/s,
        'README explains what the Debian 13 gate actually proves',
    );
    $assert->like(
        $readme,
        qr/Live systemd deployment and IRC\s+connectivity remain end-to-end runtime checks rather than container-CI claims/s,
        'README states the remaining deployment/runtime boundary of the Debian 13 CI claim',
    );

    $assert->like(
        $cfgdoc,
        qr/^## Debian 13 fresh-install CI gate$/m,
        'configure guide has a dedicated Debian 13 gate section',
    );
    $assert->like(
        $cfgdoc,
        qr/`debian:13-slim`.*?Debian system Perl 5\.40.*?dedicated non-root `mediabot` account/s,
        'configure guide documents distro, Perl and non-root invariants',
    );
    $assert->like(
        $cfgdoc,
        qr/container gate deliberately does \*\*not\*\* claim to replace live systemd or\s+IRC end-to-end validation/s,
        'configure guide preserves the remaining deployment/runtime boundary',
    );

    $assert->like(
        $configure,
        qr/\[\[ "\$\(id -u\)" -ne 0 \]\] \|\| fail "Run this wizard as the dedicated non-root Mediabot user, not root"/,
        'the CI gate exercises the existing non-root configure safety contract rather than bypassing it',
    );
};
