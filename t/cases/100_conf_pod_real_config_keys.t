# t/cases/100_conf_pod_real_config_keys.t
# =============================================================================
# Regression checks for Mediabot::Conf documentation examples.
#
# Conf.pm is often the first place a developer looks to understand key naming.
# Its POD examples must use real sample/runtime keys, not stale placeholders.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_conf_pod_real_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $conf = _slurp_conf_pod_real_keys(
        File::Spec->catfile('.', 'Mediabot', 'Conf.pm')
    );

    my $sample = _slurp_conf_pod_real_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    $assert->like(
        $sample,
        qr/^MAIN_PROG_NAME=Mediabot$/m,
        'sample config documents MAIN_PROG_NAME'
    );

    $assert->like(
        $conf,
        qr/get\('main\.MAIN_PROG_NAME'\)/,
        'Conf.pm POD get() example uses main.MAIN_PROG_NAME'
    );

    $assert->like(
        $conf,
        qr/set\('main\.MAIN_PROG_NAME', 'NewBot'\)/,
        'Conf.pm POD set() example uses main.MAIN_PROG_NAME'
    );

    $assert->unlike(
        $conf,
        qr/main\.bot_name/,
        'Conf.pm no longer documents stale main.bot_name'
    );

    $assert->like(
        $conf,
        qr/package Mediabot::Conf;/,
        'Conf.pm is the expected module'
    );
};
