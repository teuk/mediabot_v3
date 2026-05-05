# t/cases/104_configure_generated_runtime_keys.t
# =============================================================================
# Regression checks for generated configuration files.
#
# mediabot.sample.conf is not enough: ./configure and install/db_install.sh
# must also generate the runtime keys that the bot expects.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_generated_runtime_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $configure = _slurp_generated_runtime_keys(
        File::Spec->catfile('.', 'configure')
    );

    my $db_install = _slurp_generated_runtime_keys(
        File::Spec->catfile('.', 'install', 'db_install.sh')
    );

    my $sample = _slurp_generated_runtime_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    for my $key (
        qw(
            CHANNEL_LOG_RETENTION_DAYS=90
            USER_SEEN_RETENTION_DAYS=180
            DCC_DEBUG_HINTS=0
            PARTYLINE_EVAL_ENABLED=0
            PARTYLINE_EVAL_TIMEOUT_SECONDS=5
        )
    ) {
        $assert->like(
            $configure,
            qr/\Q$key\E/,
            "./configure writes $key"
        );

        $assert->like(
            $sample,
            qr/^\Q$key\E$/m,
            "sample documents $key"
        );
    }

    $assert->like(
        $configure,
        qr/\[metrics\]\nMETRICS_ENABLED=0\nMETRICS_BIND=127\.0\.0\.1\nMETRICS_PORT=9108/s,
        './configure writes [metrics] defaults'
    );

    for my $key (
        qw(
            METRICS_ENABLED=0
            METRICS_BIND=127.0.0.1
            METRICS_PORT=9108
        )
    ) {
        $assert->like(
            $sample,
            qr/^\Q$key\E$/m,
            "sample documents $key"
        );
    }

    $assert->like(
        $db_install,
        qr/CHARSET_MODE=utf8mb4/,
        'install/db_install.sh writes CHARSET_MODE=utf8mb4 in [mysql]'
    );

    $assert->like(
        $sample,
        qr/^CHARSET_MODE=utf8mb4$/m,
        'sample documents CHARSET_MODE=utf8mb4'
    );
};
