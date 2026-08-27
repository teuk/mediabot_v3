# t/cases/959_mb703_spark_runtime_ai_wiring.t
# =============================================================================
# MB703-G — Runtime AI completion may reach only the guarded Spark sender.
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

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };

    $assert->like($main, qr/use Mediabot::Spark::Generator \(\);/,
        'mb703-959: production runtime imports Spark Generator');
    $assert->like($main, qr/use Mediabot::Spark::DryRun \(\);/,
        'mb703-959: production runtime imports revocable Spark DryRun');
    $assert->like($main, qr/_spark_ai_dryrun\(/,
        'mb703-959: runtime owns a dedicated Spark AI dry-run factory');
    $assert->like($main, qr/submit_candidate\(/,
        'mb703-959: eligible candidate submits asynchronously through dry-run boundary');
    $assert->like($main, qr/Mediabot::Helpers::channel_lang\(/,
        'mb703-959: AI generation follows existing per-channel language');
    $assert->like($main, qr/Mediabot::Spark::DryRun::format_ai_dryrun_log/,
        'mb703-959: provider completion is logged through metadata-only formatter');
    $assert->like($main, qr/invalidate_channel\(\$channel\)/,
        'mb703-959: new human activity invalidates pending Spark AI generation');
    $assert->like($main, qr/SPARK_SEND_ARMED/,
        'mb703-959: delivery requires the explicit process-wide Spark arm switch');
    $assert->like($main, qr/\$bot->\{spark_state\}->begin_event/,
        'mb703-959: only the guarded candidate path may create visible Spark event state');
};
