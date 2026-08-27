# t/cases/955_mb703_spark_runtime_wiring_disarmed.t
# =============================================================================
# MB703-G — Production wiring keeps observation/generation/delivery separated.
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

    $assert->like($main, qr/use Mediabot::Spark::State \(\);/,
        'mb703-955: production runtime imports Spark State');
    $assert->like($main, qr/use Mediabot::Spark::Observer \(\);/,
        'mb703-955: production runtime imports bounded Spark Observer');
    $assert->like($main, qr/use Mediabot::Spark::Orchestrator \(\);/,
        'mb703-955: production runtime imports disarmed Spark Orchestrator');
    $assert->like($main, qr/_spark_observe_public_line\(/,
        'mb703-955: public channel path observes +Spark activity');
    $assert->like($main, qr/_spark_tick_all\(/,
        'mb703-955: existing five-second tick evaluates Spark dry-run state');
    $assert->like($main, qr/use Mediabot::Spark::Generator \(\);/,
        'mb703-955: MB703-E runtime imports the provider-neutral Spark Generator');
    $assert->like($main, qr/use Mediabot::Spark::DryRun \(\);/,
        'mb703-955: MB703-E wraps generation in a revocable dry-run boundary');
    $assert->like($main, qr/submit_candidate\(/,
        'mb703-955: eligible Spark candidates may exercise real AI asynchronously');
    $assert->like($main, qr/use Mediabot::Spark::Sender \(\);/,
        'mb703-955: production runtime imports the dedicated guarded Spark sender');
    $assert->like($main, qr/SPARK_SEND_ARMED/,
        'mb703-955: production delivery is controlled by the master Spark arm switch');

    my $orch = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Spark/Orchestrator.pm"
            or die "open Orchestrator.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->like($orch, qr/\[SPARK_DRYRUN\]/,
        'mb703-955: runtime orchestrator provides a dedicated application-log marker');
    $assert->unlike($orch, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb703-955: Spark Orchestrator owns no IRC emission primitive');
    $assert->unlike($orch, qr/Mediabot::Spark::Generator|AI::Client/,
        'mb703-955: Spark Orchestrator itself still cannot invoke the AI generator');
};
