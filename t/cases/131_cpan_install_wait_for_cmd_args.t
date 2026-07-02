# t/cases/131_cpan_install_wait_for_cmd_args.t
# =============================================================================
# Regression checks for install/cpan_install.sh wait_for_cmd().
#
# wait_for_cmd should execute commands through argv, not through a manually
# quoted shell string. Since mb380 made cpan_install.sh independent from the
# caller's working directory, the helper must be invoked through INSTALL_HELPER,
# which is anchored to SCRIPT_DIR.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_cpan_wait_for_cmd {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_cpan_wait_for_cmd(
        File::Spec->catfile('.', 'install', 'cpan_install.sh')
    );

    $assert->like(
        $src,
        qr/function wait_for_cmd \{/,
        'cpan_install.sh defines wait_for_cmd'
    );

    $assert->like(
        $src,
        qr/"\$\@" >>"\$\{CPAN_LOGFILE\}" 2>&1 &/,
        'wait_for_cmd executes argv directly'
    );

    $assert->like(
        $src,
        qr/while kill -0 "\$WAIT_PID" 2>\/dev\/null; do/,
        'wait_for_cmd waits using kill -0 instead of polling /proc directly'
    );

    $assert->like(
        $src,
        qr/wait "\$WAIT_PID"/,
        'wait_for_cmd returns the child process status through wait'
    );

    # mb383: mb380 switched the call from the caller-relative
    # ./install_perl_module.sh path to INSTALL_HELPER, which is resolved under
    # SCRIPT_DIR and therefore remains stable from every working directory.
    $assert->like(
        $src,
        qr/wait_for_cmd "\$INSTALL_HELPER" "\$perl_module"/,
        'ensure_module invokes the helper through the SCRIPT_DIR-anchored INSTALL_HELPER path'
    );

    $assert->unlike(
        $src,
        qr/wait_for_cmd \.\/install\/install_perl_module\.sh "\$perl_module"/,
        'ensure_module does not use the wrong root-relative install/install_perl_module.sh path'
    );

    $assert->unlike(
        $src,
        qr/bash -c "\$cmd"/,
        'wait_for_cmd no longer runs a constructed command string through bash -c'
    );

    $assert->unlike(
        $src,
        qr/local cmd="\$1"/,
        'wait_for_cmd no longer stores a shell command string'
    );

    $assert->unlike(
        $src,
        qr/\/proc\/\$WAIT_PID/,
        'wait_for_cmd no longer polls /proc directly'
    );

    $assert->unlike(
        $src,
        qr/wait_for_cmd "\.\/install_perl_module\.sh '\$perl_module'"/,
        'ensure_module no longer passes a manually quoted shell string'
    );
};
