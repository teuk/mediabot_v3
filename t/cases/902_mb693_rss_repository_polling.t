# t/cases/902_mb693_rss_repository_polling.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS::Fetcher;

{
    package FakeTiny902;
    sub get {
        my ($self, $url, $args) = @_;
        $self->{url} = $url;
        $self->{args} = $args;
        return { success=>1, status=>200, headers=>{}, content=>'<rss><channel><title>x</title></channel></rss>' };
    }
}

sub _slurp902 {
    my ($p)=@_; open my $fh,'<',$p or die $!; local $/; return <$fh>;
}

return sub {
    my ($assert) = @_;

    my %seen;
    my $rss = '<rss><channel><title>x</title><item><title>A</title><link>https://example.org/a</link><guid>a</guid></item></channel></rss>';
    my $res = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { ['93.184.216.34'] },
        requester => sub {
            my ($url,%opts)=@_; %seen=%opts;
            return { success=>1,status=>200,headers=>{ etag=>'"abc"','last-modified'=>'Sat, 23 Aug 2026 09:00:00 GMT' },content=>$rss };
        },
        etag => '"old"', last_modified => 'Fri, 22 Aug 2026 09:00:00 GMT',
    );
    $assert->ok($res->{ok}, 'mb693-902: conditional fetch parses a 200 response');
    $assert->is($seen{request_headers}{'If-None-Match'}, '"old"',
        'mb693-902: ETag becomes If-None-Match');
    $assert->is($seen{request_headers}{'If-Modified-Since'}, 'Fri, 22 Aug 2026 09:00:00 GMT',
        'mb693-902: Last-Modified becomes If-Modified-Since');
    $assert->is($res->{etag}, '"abc"', 'mb693-902: response ETag returned to poller');
    $assert->is($res->{last_modified}, 'Sat, 23 Aug 2026 09:00:00 GMT',
        'mb693-902: response Last-Modified returned to poller');

    my $nm = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { ['93.184.216.34'] },
        requester => sub { return { success=>0,status=>304,headers=>{etag=>'"abc"'},content=>'' } },
        etag => '"abc"',
    );
    $assert->ok($nm->{ok} && $nm->{not_modified},
        'mb693-902: HTTP 304 succeeds without trying to parse an empty body');

    my $tiny = bless {}, 'FakeTiny902';
    {
        no warnings qw(redefine once);
        local *HTTP::Tiny::new = sub { return $tiny };
        Mediabot::RSS::Fetcher::_default_requester(
            'https://feed.example/rss',
            validated_addresses => ['93.184.216.34'],
            request_headers => {
                'If-None-Match' => '"wire"',
                'If-Modified-Since' => 'Sat, 23 Aug 2026 09:00:00 GMT',
                'Host' => 'forbidden.example',
            },
        );
    }
    $assert->is($tiny->{args}{headers}{'If-None-Match'}, '"wire"',
        'mb693-902: default HTTP requester emits If-None-Match');
    $assert->is($tiny->{args}{headers}{'If-Modified-Since'}, 'Sat, 23 Aug 2026 09:00:00 GMT',
        'mb693-902: default HTTP requester emits If-Modified-Since');
    $assert->ok(!exists $tiny->{args}{headers}{Host},
        'mb693-902: conditional-header path cannot inject Host');

    my $repo = _slurp902('Mediabot/RSS/Repository.pm');
    $assert->like($repo, qr/sub list_due_feeds .*?TIMESTAMPADD\(SECOND, rf\.poll_interval, rf\.last_poll_at\)/s,
        'mb693-902: due-feed discovery honors each persisted interval');
    $assert->like($repo, qr/sub insert_item .*?INSERT IGNORE INTO RSS_ITEM/s,
        'mb693-902: durable item dedup uses the unique RSS_ITEM insert path');
    $assert->like($repo, qr/announced_at\)\s*VALUES \(\?, \?, \?, \?, \?, IF\(\? = 1, NOW\(\), NULL\)\)/s,
        'mb693-902: baseline/overflow suppression is persisted in announced_at');
    $assert->like($repo, qr/sub pending_items .*?announced_at IS NULL.*?ORDER BY id_rss_item ASC/s,
        'mb693-902: pending announcements are durable and oldest-first');
    $assert->like($repo, qr/sub mark_announced .*?SET announced_at = NOW\(\)/s,
        'mb693-902: post-send acknowledgement is explicit');
    $assert->like($repo, qr/sub record_poll_success .*?last_success_at = NOW\(\).*?etag = COALESCE/s,
        'mb693-902: successful poll records health plus HTTP validators');
    $assert->like($repo, qr/sub record_poll_error .*?last_error_at = NOW\(\).*?last_error = \?/s,
        'mb693-902: one broken feed gets isolated durable error state');

    my $fetch = _slurp902('Mediabot/RSS/Fetcher.pm');
    $assert->like($fetch, qr/If-None-Match.*?If-Modified-Since/s,
        'mb693-902: default HTTP requester allowlists conditional headers');
    $assert->like($fetch, qr/status == 304.*?not_modified/s,
        'mb693-902: fetcher has a first-class 304 path');
};
