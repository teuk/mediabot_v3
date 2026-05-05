# t/cases/106_live_test_conf_template_runtime_keys.t
# =============================================================================
# Regression checks for t/live/test.conf.tpl.
#
# The live test configuration template should stay aligned with the modern
# runtime/sample configuration keys. Otherwise live tests can behave differently
# from real installs or trigger avoidable missing-key warnings.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_live_template_runtime_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $tpl = _slurp_live_template_runtime_keys(
        File::Spec->catfile('.', 't', 'live', 'test.conf.tpl')
    );

    my $sample = _slurp_live_template_runtime_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    for my $section (qw(mysql radio main metrics libera)) {
        $assert->like(
            $tpl,
            qr/^\[\Q$section\E\]$/m,
            "live template has [$section] section"
        );
    }

    for my $key (
        qw(
            CHARSET_MODE=utf8mb4
            RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000
            RADIO_ICECAST_PUBLIC_BASE_URL=http://127.0.0.1:8000
            RADIO_ICECAST_TIMEOUT=5
            RADIO_ICECAST_PRIMARY_MOUNT=/radio160.mp3
            EXEC_TIMEOUT_SECONDS=8
            MAIN_CHANNEL_NICKLIST_REFRESH_INTERVAL=300
            CHANNEL_LOG_RETENTION_DAYS=90
            USER_SEEN_RETENTION_DAYS=180
            DCC_DEBUG_HINTS=0
            PARTYLINE_EVAL_ENABLED=0
            PARTYLINE_EVAL_TIMEOUT_SECONDS=5
            METRICS_ENABLED=0
            METRICS_BIND=127.0.0.1
            METRICS_PORT=9108
            LIBERA_NICKSERV_PASSWORD=
        )
    ) {
        $assert->like(
            $tpl,
            qr/^\Q$key\E$/m,
            "live template contains $key"
        );
    }

    for my $key (
        qw(
            CHARSET_MODE=utf8mb4
            CHANNEL_LOG_RETENTION_DAYS=90
            USER_SEEN_RETENTION_DAYS=180
            DCC_DEBUG_HINTS=0
            PARTYLINE_EVAL_ENABLED=0
            PARTYLINE_EVAL_TIMEOUT_SECONDS=5
            METRICS_ENABLED=0
            METRICS_BIND=127.0.0.1
            METRICS_PORT=9108
            LIBERA_NICKSERV_PASSWORD=
        )
    ) {
        $assert->like(
            $sample,
            qr/^\Q$key\E$/m,
            "sample also contains $key"
        );
    }

    my $obsolete_network_name = join('', qw(free node));

    $assert->unlike(
        $tpl,
        qr/\Q$obsolete_network_name\E/i,
        'live template does not mention obsolete network naming'
    );
};
