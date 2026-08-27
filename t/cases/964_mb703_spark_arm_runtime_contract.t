# t/cases/964_mb703_spark_arm_runtime_contract.t
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

    my $sample = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.sample.conf" or die $!;
        local $/; <$fh>;
    };
    $assert->is(scalar(() = $sample =~ /^SPARK_SEND_ARMED=0$/mg), 1,
        'mb703-964: Spark delivery remains off by default');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };
    $assert->like($main, qr/use Mediabot::Spark::Sender \(\);/,
        'mb703-964: runtime imports the dedicated Spark sender');
    $assert->like($main, qr/get_int\(\s*'main\.SPARK_SEND_ARMED'/s,
        'mb703-964: runtime re-reads the process-wide Spark arm switch');
    $assert->like($main, qr/chanset_enabled\(\$bot, \$channel, 'Spark', default => 0\)/,
        'mb703-964: +Spark remains a separate per-channel gate');
    $assert->like($main, qr/_spark_delivery_state\(/,
        'mb703-964: final mutable runtime state is re-read before delivery');
    $assert->like($main, qr/attempt_send\(/,
        'mb703-964: generated candidates reach only the guarded sender boundary');
};
