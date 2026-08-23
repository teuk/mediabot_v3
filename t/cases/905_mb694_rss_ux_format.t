# t/cases/905_mb694_rss_ux_format.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::RSS qw(format_rss_feed_list rss_feed_state format_rss_feed_overview format_rss_feed_info_lines);

return sub {
    my ($assert) = @_;
    $assert->is(rss_feed_state({ enabled=>0 }), 'off', 'mb694-905: disabled feed is paused');
    $assert->is(rss_feed_state({ enabled=>1, last_error=>'timeout' }), 'error', 'mb694-905: durable error is visible');
    $assert->is(rss_feed_state({ enabled=>1 }), 'waiting', 'mb694-905: new enabled feed is waiting');
    $assert->is(rss_feed_state({ enabled=>1, last_success_at=>'x', pending_count=>2 }), 'pending', 'mb694-905: pending work is visible');
    $assert->is(rss_feed_state({ enabled=>1, last_success_at=>'x', pending_count=>0 }), 'ok', 'mb694-905: healthy initialized feed is OK');

    my $legacy = format_rss_feed_list('Korben.info', 'Numerama');
    $assert->like($legacy, qr/\A\037Flux disponibles\037 : \00314Korben\.info\00313 \| \00314Numerama\003\z/, 'mb694-905: legacy list charter remains compatible');

    my $overview = format_rss_feed_overview('#boulets',
        {label=>'Korben',enabled=>1,last_success_at=>'x',poll_interval=>300,announce_limit=>3,item_count=>25,pending_count=>0},
        {label=>'Paused',enabled=>0,poll_interval=>1800,announce_limit=>5,item_count=>2,pending_count=>0},
    );
    $assert->is(ref($overview), 'ARRAY', 'mb694-905: overview is a bounded line array');
    $assert->is(scalar(@$overview), 1, 'mb694-905: compact feeds fit on one IRC line');
    $assert->like($overview->[0], qr/Flux RSS #boulets.*?\[Korben\].*?5 min\/max3.*?25 items.*?OK/s, 'mb694-905: overview carries operational status');
    $assert->like($overview->[0], qr/\[Paused\].*?30 min\/max5.*?PAUSED/s, 'mb694-905: overview makes paused state obvious');

    my $lines = format_rss_feed_info_lines({
        label=>'Korben',channel=>'#boulets',url=>'https://korben.info/feed',enabled=>1,
        poll_interval=>300,announce_limit=>3,item_count=>25,pending_count=>0,next_poll_in=>121,
        last_poll_at=>'2026-08-23 12:30:00',last_success_at=>'2026-08-23 12:30:00',
    });
    $assert->is(scalar(@$lines), 6, 'mb694-905: healthy info stays concise');
    $assert->is($lines->[0], 'RSS [Korben] on #boulets — ON · OK', 'mb694-905: info headline exposes ON + health');
    $assert->is($lines->[2], 'Polling: every 5 min | max 3 | next: in 3 min', 'mb694-905: info exposes cadence and next poll');
    $assert->is($lines->[3], 'Items: 25 stored | 0 pending', 'mb694-905: info exposes durable queue state');
    $assert->is($lines->[5], 'Last error: none', 'mb694-905: healthy info has explicit no-error state');

    my $err = format_rss_feed_info_lines({
        label=>'Broken',channel=>'#boulets',url=>'https://example.org/feed',enabled=>1,
        poll_interval=>1800,announce_limit=>5,item_count=>7,pending_count=>1,next_poll_in=>0,
        last_poll_at=>'2026-08-23 12:31:00',last_success_at=>'2026-08-23 11:00:00',
        last_error=>'http_status',last_error_at=>'2026-08-23 12:31:00',
    });
    $assert->is($err->[0], 'RSS [Broken] on #boulets — ON · ERROR', 'mb694-905: error outranks pending');
    $assert->like($err->[-1], qr/Last error: http_status \(2026-08-23 12:31:00\)/, 'mb694-905: error includes timestamp');
};
