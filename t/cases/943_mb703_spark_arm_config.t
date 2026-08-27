# t/cases/943_mb703_spark_arm_config.t
# =============================================================================
# MB703-A3 — reserve a default-off process-wide Spark delivery kill switch.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.sample.conf"
        or die "open sample config: $!";
    local $/;
    my $sample = <$fh>;

    my $count = () = ($sample =~ /^SPARK_SEND_ARMED=0$/mg);
    $assert->is($count, 1,
        'mb703-943: sample config defines SPARK_SEND_ARMED=0 exactly once');

    $assert->like(
        $sample,
        qr/# Spark proactive event delivery master kill switch\. Keep 0 by default\.\n# \+Spark remains a separate per-channel opt-in;/,
        'mb703-943: sample explains independent channel opt-in and master gate');

    open my $mf, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
        or die "open mediabot.pl: $!";
    local $/;
    my $main = <$mf>;

    $assert->like($main, qr/get_int\(\s*'main\.SPARK_SEND_ARMED'/s,
        'mb703-943: runtime consumes Spark arm switch through bounded integer config');
    $assert->like($main, qr/Mediabot::Spark::Sender/,
        'mb703-943: Spark delivery uses a dedicated fail-closed sender boundary');
};
