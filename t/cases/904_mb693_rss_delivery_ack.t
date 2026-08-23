# t/cases/904_mb693_rss_delivery_ack.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    my $helpers = do { open my $fh,'<','Mediabot/Helpers.pm' or die $!; local $/; <$fh> };
    $assert->like(
        $helpers,
        qr/sub botPrivmsg .*?_defer_flooded_send.*?return 1;\s*\n}/s,
        'mb693-904: botPrivmsg reports accepted immediate/deferred delivery',
    );

    my $repo = do { open my $fh,'<','Mediabot/RSS/Repository.pm' or die $!; local $/; <$fh> };
    $assert->like($repo, qr/sub is_feed_enabled .*?SELECT enabled FROM RSS_FEED/s,
        'mb693-904: queued output can re-check feed state before delivery');
    $assert->like($repo, qr/sub mark_announced .*?announced_at = NOW\(\)/s,
        'mb693-904: durable acknowledgement remains explicit');

    my $runtime = do { open my $fh,'<','Mediabot/RSS/Runtime.pm' or die $!; local $/; <$fh> };
    $assert->like(
        $runtime,
        qr/my \$accepted = eval \{.*?botPrivmsg.*?\};\s*if \(\$accepted\) \{\s*my \$marked = eval \{.*?mark_announced/s,
        'mb693-904: DB acknowledgement happens only after parent output acceptance',
    );
    $assert->like($runtime, qr/output rejected; item remains pending/,
        'mb693-904: rejected output remains durable pending work');
    $assert->like($runtime, qr/dropped queued item for deleted\/disabled feed/,
        'mb693-904: deleted/disabled feed cannot leak stale queued output');
};
