# t/cases/966_mb703_spark_event_runtime_lifecycle.t
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
    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };

    $assert->like($main, qr/begin_event\(\s*channel\s*=>\s*\$channel/s,
        'mb703-966: visible event state begins only in the guarded delivery path');
    $assert->like($main, qr/finish_event\(channel\s*=>\s*\$channel,\s*outcome\s*=>\s*'engaged'\)/s,
        'mb703-966: real human context can finish an active Spark as engaged');
    $assert->like($main, qr/expire_due_event\(\$channel\)/,
        'mb703-966: timer expires unanswered events into the adaptive miss path');
    $assert->like($main, qr/\[SPARK_EVENT\].*outcome=engaged/s,
        'mb703-966: engagement lifecycle exposes metadata-only diagnostics');
    $assert->like($main, qr/\[SPARK_EVENT\].*outcome=miss/s,
        'mb703-966: missed-event lifecycle exposes metadata-only diagnostics');
};
