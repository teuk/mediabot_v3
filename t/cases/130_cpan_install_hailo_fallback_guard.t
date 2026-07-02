# t/cases/130_cpan_install_hailo_fallback_guard.t
# =============================================================================
# Regression checks for install/cpan_install.sh Hailo fallback behavior.
#
# Hailo is attempted through the normal module installation loop first.
# The manual Hailo-0.75 fallback should run only if Hailo is still unavailable
# afterwards. Otherwise fresh installs waste time and recompile unnecessarily.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_cpan_hailo_guard {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_cpan_hailo_guard(
        File::Spec->catfile('.', 'install', 'cpan_install.sh')
    );

    $assert->like(
        $src,
        qr/"Hailo"/,
        'cpan_install.sh still includes Hailo in the module list'
    );

    $assert->like(
        $src,
        qr/if ! perl -MHailo -e "exit 0;" &>\/dev\/null; then/,
        'manual Hailo fallback is guarded by a real availability check'
    );

    $assert->like(
        $src,
        qr/messageln "Installing Hailo manually as fallback after CPAN attempt"/,
        'manual Hailo fallback log remains present'
    );

    $assert->like(
        $src,
        qr/wget https:\/\/cpan\.metacpan\.org\/authors\/id\/A\/AV\/AVAR\/Hailo-0\.75\.tar\.gz/,
        'manual Hailo fallback still downloads the pinned Hailo archive'
    );

    # mb383: mb380 resolves CPAN_LOGFILE under $SCRIPT_DIR, so the fallback
    # no longer prepends "../" relative to the caller's working directory.
    $assert->like(
        $src,
        qr/make install >>"\$CPAN_LOGFILE" 2>&1/,
        'manual Hailo fallback still runs make install when needed'
    );

    $assert->like(
        $src,
        qr/messageln "Hailo already available, skipping manual fallback installation"/,
        'cpan_install.sh logs when manual Hailo fallback is skipped'
    );

    my $guard_pos = index($src, 'if ! perl -MHailo -e "exit 0;" &>/dev/null; then');
    my $fallback_pos = index($src, 'messageln "Installing Hailo manually as fallback after CPAN attempt"');

    $assert->ok(
        $guard_pos >= 0 && $fallback_pos > $guard_pos,
        'manual Hailo fallback is inside the guard block'
    );
};
