# t/cases/131_cpan_install_wait_for_cmd_args.t
# =============================================================================
# Regression checks for install/cpan_install.sh wait_for_cmd().
#
# wait_for_cmd should execute commands through argv, not through a manually
# quoted shell string. Since cpan_install.sh is launched from inside install/,
# install_perl_module.sh must be called as ./install_perl_module.sh.
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

    $assert->like(
        $src,
        qr/wait_for_cmd \.\/install_perl_module\.sh "\$perl_module"/,
        'ensure_module calls install_perl_module.sh relative to install/'
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
