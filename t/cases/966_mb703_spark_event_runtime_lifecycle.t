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
        'mb703-966: eligible human interaction can finish an active Spark as engaged');
    $assert->like(
        $main,
        qr/if\s*\(\$kind\s+eq\s+'fork'\).*?event_remaining_seconds.*?parse_fork_choice\(\$line\).*?return 0 unless defined \$choice/s,
        'mb706: an active Fork requires a live-window A/B choice instead of treating arbitrary speech as engagement',
    );
    $assert->like(
        $main,
        qr/render_fork_choice_ack\(\$nick,\s*\$choice\).*?botPrivmsg\(\$bot,\s*\$channel,\s*\$ack\)/s,
        'mb706: a recognized Fork choice produces a visible IRC acknowledgement',
    );
    $assert->like(
        $main,
        qr/interaction=choice choice=.*?ack=/s,
        'mb706: Fork engagement diagnostics expose choice/ack metadata without conversation content',
    );
    $assert->like($main, qr/expire_due_event\(\$channel\)/,
        'mb703-966: timer expires unanswered events into the adaptive miss path');
    $assert->like($main, qr/\[SPARK_EVENT\].*outcome=engaged/s,
        'mb703-966: engagement lifecycle exposes metadata-only diagnostics');
    $assert->like($main, qr/\[SPARK_EVENT\].*outcome=miss/s,
        'mb703-966: missed-event lifecycle exposes metadata-only diagnostics');
};
