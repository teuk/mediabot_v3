# t/cases/901_mb693_rss_poller_core.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS::Poller;

{
    package FakeRepo901;
    sub new { bless { calls => [], inserted => [], pending => [] }, shift }
    sub insert_item {
        my ($self, $id, $item, %opts) = @_;
        push @{ $self->{calls} }, [insert_item => $id, $item->{item_key}, $opts{announced} ? 1 : 0];
        push @{ $self->{inserted} }, $item->{item_key};
        return 1;
    }
    sub record_poll_success { my ($s,@a)=@_; push @{$s->{calls}}, [success=>@a]; 1 }
    sub record_not_modified { my ($s,@a)=@_; push @{$s->{calls}}, [notmod=>@a]; 1 }
    sub record_poll_error { my ($s,@a)=@_; push @{$s->{calls}}, [error=>@a]; 1 }
    sub pending_items { my ($s,$id,$lim)=@_; push @{$s->{calls}}, [pending=>$id,$lim]; return $s->{pending} }
}

sub _item901 {
    my ($n) = @_;
    return {
        item_key => sprintf('%064x', $n),
        title => "Item $n",
        url => "https://example.org/$n",
        published => "date$n",
    };
}

return sub {
    my ($assert) = @_;

    my $repo = FakeRepo901->new;
    my %seen;
    my $poller = Mediabot::RSS::Poller->new(
        repo => $repo,
        fetcher => sub {
            my ($url, %opts) = @_;
            %seen = (url => $url, %opts);
            return {
                ok => 1, status => 200, etag => '"v2"',
                last_modified => 'Sat, 23 Aug 2026 09:00:00 GMT',
                feed => { items => [ _item901(1), _item901(2) ] },
            };
        },
    );

    my $base = $poller->poll_feed({
        id_rss_feed => 7, url => 'https://feed.example/rss',
        announce_limit => 1, etag => '"v1"',
        last_modified => 'Fri, 22 Aug 2026 09:00:00 GMT',
        last_success_at => undef,
    });
    $assert->ok($base->{ok}, 'mb693-901: baseline poll succeeds');
    $assert->ok($base->{baseline}, 'mb693-901: first successful poll is a baseline');
    $assert->is(scalar(@{ $base->{pending} }), 0,
        'mb693-901: first successful poll announces no historical items');
    $assert->is($seen{max_items}, 100, 'mb693-901: poll fetches bounded dedup horizon');
    $assert->is($seen{etag}, '"v1"', 'mb693-901: ETag validator forwarded');
    $assert->is($seen{last_modified}, 'Fri, 22 Aug 2026 09:00:00 GMT',
        'mb693-901: Last-Modified validator forwarded');
    $assert->is(join(',', map { $_->[3] // '' } grep { $_->[0] eq 'insert_item' } @{ $repo->{calls} }),
        '1,1', 'mb693-901: baseline items are persisted already-announced');

    my $repo2 = FakeRepo901->new;
    $repo2->{pending} = [ { item_key => sprintf('%064x', 3), title => 'Item 3', url => 'https://example.org/3' } ];
    my $poller2 = Mediabot::RSS::Poller->new(
        repo => $repo2,
        fetcher => sub { return { ok=>1, status=>200, feed=>{ items=>[ _item901(3), _item901(4) ] } } },
    );
    my $normal = $poller2->poll_feed({
        id_rss_feed => 8, url => 'https://feed.example/rss',
        announce_limit => 1, last_success_at => '2026-08-23 10:00:00',
    });
    $assert->ok($normal->{ok} && !$normal->{baseline},
        'mb693-901: later poll is not a baseline');
    my @ins = grep { $_->[0] eq 'insert_item' } @{ $repo2->{calls} };
    $assert->is($ins[0][3], 0, 'mb693-901: first new item stays pending');
    $assert->is($ins[1][3], 1, 'mb693-901: overflow new item is durably suppressed');
    $assert->is(scalar(@{ $normal->{pending} }), 1,
        'mb693-901: later poll returns bounded pending announcements');

    my $repo3 = FakeRepo901->new;
    $repo3->{pending} = [ { item_key => sprintf('%064x', 9), title => 'retry' } ];
    my $poller3 = Mediabot::RSS::Poller->new(
        repo => $repo3,
        fetcher => sub { return { ok=>1, not_modified=>1, status=>304, etag=>'"same"' } },
    );
    my $notmod = $poller3->poll_feed({
        id_rss_feed=>9, url=>'https://feed.example/rss', announce_limit=>5,
        last_success_at=>'2026-08-23 10:00:00', etag=>'"same"',
    });
    $assert->ok($notmod->{ok} && $notmod->{not_modified},
        'mb693-901: HTTP 304 is a successful poll');
    $assert->is(scalar(@{ $notmod->{pending} }), 1,
        'mb693-901: 304 still exposes durable pending items for retry');

    my $repo4 = FakeRepo901->new;
    my $poller4 = Mediabot::RSS::Poller->new(
        repo => $repo4,
        fetcher => sub { return { ok=>0, error=>'http_status', status=>503 } },
    );
    my $fail = $poller4->poll_feed({
        id_rss_feed=>10, url=>'https://feed.example/rss', last_success_at=>'x'
    });
    $assert->is($fail->{error}, 'http_status', 'mb693-901: fetch error returned');
    $assert->like(join(' ', map { join(':', @$_) } @{ $repo4->{calls} }), qr/error:10:http_status/,
        'mb693-901: fetch failure is persisted per feed');

    my $src = do { open my $fh, '<', 'Mediabot/RSS/Poller.pm' or die $!; local $/; <$fh> };
    $assert->unlike($src, qr/Mediabot::Scheduler|Timer::Periodic|botPrivmsg|make_shortener/,
        'mb693-901: polling core has no Scheduler, IRC or presentation coupling');
};
