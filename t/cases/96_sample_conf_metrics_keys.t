# t/cases/96_sample_conf_metrics_keys.t
# =============================================================================
# Regression checks for Prometheus metrics configuration.
#
# mediabot.pl reads:
#   metrics.METRICS_ENABLED
#   metrics.METRICS_BIND
#   metrics.METRICS_PORT
#
# The root sample config must document those keys explicitly.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_metrics_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_metrics_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $main = _slurp_metrics_keys(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    my $metrics = _slurp_metrics_keys(
        File::Spec->catfile('.', 'Mediabot', 'Metrics.pm')
    );

    $assert->like(
        $sample,
        qr/^\[metrics\]$/m,
        'sample config has a [metrics] section'
    );

    $assert->like(
        $sample,
        qr/^METRICS_ENABLED=0$/m,
        'sample config disables metrics by default'
    );

    $assert->like(
        $sample,
        qr/^METRICS_BIND=127\.0\.0\.1$/m,
        'sample config binds metrics to localhost by default'
    );

    $assert->like(
        $sample,
        qr/^METRICS_PORT=9108$/m,
        'sample config documents default metrics port'
    );

    for my $key (
        qw(
            METRICS_ENABLED
            METRICS_BIND
            METRICS_PORT
        )
    ) {
        $assert->like(
            $main,
            qr/get\('metrics\.\Q$key\E'\)/,
            "mediabot.pl reads metrics.$key"
        );

        $assert->like(
            $sample,
            qr/^\Q$key\E=/m,
            "sample config documents $key"
        );
    }

    $assert->like(
        $metrics,
        qr/package Mediabot::Metrics;/,
        'Mediabot::Metrics module exists'
    );

    $assert->like(
        $metrics,
        qr/sub start_http_server\s*\{/,
        'Mediabot::Metrics has HTTP exporter startup code'
    );

    $assert->like(
        $metrics,
        qr/render_prometheus/,
        'Mediabot::Metrics renders Prometheus output'
    );
};
