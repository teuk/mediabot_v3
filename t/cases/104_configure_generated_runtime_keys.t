use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb378_generated {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $configure = _slurp_mb378_generated(File::Spec->catfile('.', 'configure'));
    my $helper    = _slurp_mb378_generated(File::Spec->catfile('.', 'install', 'configure_config.pl'));
    my $db_install = _slurp_mb378_generated(File::Spec->catfile('.', 'install', 'db_install.sh'));
    my $sample = _slurp_mb378_generated(File::Spec->catfile('.', 'mediabot.sample.conf'));

    $assert->like($configure, qr/SAMPLE_CONF="\$APP_DIR\/mediabot\.sample\.conf"/,
        './configure uses mediabot.sample.conf as the source of truth');
    $assert->like($configure, qr/--mode fresh/,
        './configure has a complete fresh-generation path');
    $assert->like($configure, qr/--mode merge/,
        './configure has an existing-config merge path');
    $assert->unlike($configure, qr/echo "\[main\].*?>\$CONFIG_FILE/s,
        './configure no longer writes a hand-maintained minimal config');

    for my $key (qw(
        CHANNEL_LOG_RETENTION_DAYS=90
        USER_SEEN_RETENTION_DAYS=180
        DCC_DEBUG_HINTS=0
        PARTYLINE_EVAL_ENABLED=0
        PARTYLINE_EVAL_TIMEOUT_SECONDS=5
        METRICS_ENABLED=0
        METRICS_BIND=127.0.0.1
        METRICS_PORT=9108
        HAILO_CHATTER_RATE_WINDOW=60
        HAILO_CHATTER_REFERENCE_MSGS=10
        HAILO_CHATTER_MIN_FACTOR_PCT=10
    )) {
        $assert->like($sample, qr/^\Q$key\E$/m, "sample provides active safe default $key");
    }

    $assert->like($helper, qr/writes via\s+an atomic rename/s,
        'config helper documents atomic writes');
    $assert->like($helper, qr/chmod 0600, \$config/,
        'config helper protects the resulting config file');
    $assert->like($db_install, qr/configure_config\.pl/,
        'db installer updates config through the atomic helper');
    $assert->like($db_install, qr/mysql\.CHARSET_MODE=utf8mb4/,
        'db installer writes CHARSET_MODE=utf8mb4 through the overlay');
};
