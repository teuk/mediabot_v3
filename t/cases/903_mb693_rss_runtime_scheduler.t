# t/cases/903_mb693_rss_runtime_scheduler.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    my $src = do { open my $fh,'<','Mediabot/RSS/Runtime.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/use Mediabot::AsyncWorker;/,
        'mb693-903: runtime uses shared bounded AsyncWorker');
    $assert->like($src, qr/return 0 unless \$bot->\{_start_time\}/,
        'mb693-903: scheduler tick is inert before IRC login completes');
    $assert->like($src, qr/max_workers.*?4/s,
        'mb693-903: runtime has a bounded worker pool');
    $assert->like($src, qr/next if \$self->\{inflight\}\{\$id\}/,
        'mb693-903: same feed cannot spawn a concurrent worker');
    $assert->like($src, qr/connect_isolated_handle/,
        'mb693-903: worker opens an isolated DB handle');
    $assert->like($src, qr/make_shortener\(\).*?format_rss_announcement/s,
        'mb693-903: TinyURL + formatter run in the isolated worker path');
    $assert->like($src, qr/output_delay.*?2/s,
        'mb693-903: automatic RSS output is spaced by two seconds per channel');
    $assert->like($src, qr/is_feed_enabled.*?botPrivmsg.*?mark_announced/s,
        'mb693-903: runtime rechecks feed and acknowledges only after output acceptance');

    my $main = do { open my $fh,'<','mediabot.pl' or die $!; local $/; <$fh> };
    $assert->like($main, qr/use Mediabot::RSS::Runtime;/,
        'mb693-903: main runtime loads RSS scheduler bridge');
    $assert->like($main, qr/name\s*=>\s*'rss_poll_dispatch'.*?interval\s*=>\s*15.*?first_interval\s*=>\s*20.*?->tick/s,
        'mb693-903: native Scheduler registers lightweight RSS dispatch task');
    $assert->unlike($main, qr/name\s*=>\s*'rss_poll_dispatch'.*?fetch_feed_once/s,
        'mb693-903: Scheduler callback itself does not perform feed HTTP');
};
