# t/cases/94_sample_conf_runtime_keys.t
# =============================================================================
# Regression checks for runtime configuration keys documented in the root sample.
#
# These keys are read by runtime code and should be present in mediabot.sample.conf
# to avoid confusing MEDIABOT_DEBUG_CONF warnings and hidden defaults.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_sample_runtime_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = File::Spec->catfile('.', 'mediabot.sample.conf');
    my $src    = _slurp_sample_runtime_keys($sample);

    $assert->like(
        $src,
        qr/^\[mysql\]$/m,
        'sample config has a [mysql] section'
    );

    $assert->like(
        $src,
        qr/^CHARSET_MODE=utf8mb4$/m,
        'sample config documents mysql.CHARSET_MODE with utf8mb4 default'
    );

    $assert->like(
        $src,
        qr/Database session charset mode: utf8mb4, latin1, or off/,
        'sample config explains CHARSET_MODE choices'
    );

    $assert->like(
        $src,
        qr/^\[connection\]$/m,
        'sample config has a [connection] section'
    );

    $assert->like(
        $src,
        qr/^CONN_PASS=$/m,
        'sample config explicitly defines empty optional connection.CONN_PASS'
    );

    $assert->unlike(
        $src,
        qr/^#CONN_PASS=/m,
        'sample config does not leave CONN_PASS only as a commented key'
    );

    my $db = _slurp_sample_runtime_keys(
        File::Spec->catfile('.', 'Mediabot', 'DB.pm')
    );

    $assert->like(
        $db,
        qr/get\('mysql\.CHARSET_MODE'\)/,
        'DB.pm reads mysql.CHARSET_MODE'
    );

    my $core = _slurp_sample_runtime_keys(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    $assert->like(
        $core,
        qr/get\('connection\.CONN_PASS'\)/,
        'Mediabot.pm reads connection.CONN_PASS'
    );
};
