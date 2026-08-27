# t/cases/961_mb703_spark_runtime_pacing_config.t
# =============================================================================
# MB703-F — bounded Spark runtime pacing is configurable without delivery arm.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    my $sample = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.sample.conf"
            or die "open sample config: $!";
        local $/;
        <$fh>;
    };

    $assert->is(
        scalar(() = $sample =~ /^SPARK_MIN_SILENCE_SECONDS=1200$/mg),
        1,
        'mb703-961: sample defines the conservative Spark silence default once',
    );
    $assert->is(
        scalar(() = $sample =~ /^SPARK_CANDIDATE_PROBE_SECONDS=300$/mg),
        1,
        'mb703-961: sample defines the conservative Spark probe default once',
    );
    $assert->like(
        $sample,
        qr/Pilot deployments may temporarily use 60 \/ 30/,
        'mb703-961: sample documents the bounded pilot pacing values',
    );

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };

    $assert->like(
        $main,
        qr/\$bot->\{conf\}->get\('main\.SPARK_MIN_SILENCE_SECONDS'\)/,
        'mb703-961: runtime reads the configured Spark silence threshold',
    );
    $assert->like(
        $main,
        qr/\$bot->\{conf\}->get\('main\.SPARK_CANDIDATE_PROBE_SECONDS'\)/,
        'mb703-961: runtime reads the configured Spark candidate probe interval',
    );
    $assert->like(
        $main,
        qr/min_silence_seconds\s*=>\s*\$min_silence_seconds/,
        'mb703-961: runtime delegates silence validation to the Orchestrator',
    );
    $assert->like(
        $main,
        qr/candidate_probe_seconds\s*=>\s*\$candidate_probe_seconds/,
        'mb703-961: runtime delegates probe validation to the Orchestrator',
    );
    $assert->like(
        $main,
        qr/get_int\(\s*'main\.SPARK_SEND_ARMED'/s,
        'mb703-961: delivery arm is read independently from pacing configuration',
    );
};
