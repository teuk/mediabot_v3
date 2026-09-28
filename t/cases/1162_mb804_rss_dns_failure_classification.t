# MB804: a DNS outage is not a blocked RSS destination. Neither condition
# permits a request without a fully validated public address set.
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::RSS::Fetcher;

return sub {
    my ($assert) = @_;
    my $url = 'https://feed.example/rss';
    my $calls = 0;
    my $requester = sub { $calls++; die 'request must not run' };

    my $unavailable = Mediabot::RSS::Fetcher::fetch_feed_once(
        $url, resolver => sub { die "temporary resolver failure for $url\n" },
        requester => $requester,
    );
    $assert->is($unavailable->{error}, 'dns_unavailable',
        'mb804-1162: resolver exception is diagnosed as DNS unavailable');
    $assert->unlike($unavailable->{detail}, qr/feed\.example|https?:\/\//,
        'mb804-1162: resolver details do not expose a destination');
    $assert->is($calls, 0, 'mb804-1162: resolver failure cannot reach HTTP');

    my $empty = Mediabot::RSS::Fetcher::fetch_feed_once(
        $url, resolver => sub { [] }, requester => $requester,
    );
    $assert->is($empty->{error}, 'dns_unavailable',
        'mb804-1162: empty DNS answer is diagnosed as unavailable');
    $assert->is($calls, 0, 'mb804-1162: empty DNS answer cannot reach HTTP');

    my $private = Mediabot::RSS::Fetcher::fetch_feed_once(
        $url, resolver => sub { ['127.0.0.1'] }, requester => $requester,
    );
    $assert->is($private->{error}, 'blocked_destination',
        'mb804-1162: private DNS address remains blocked');
    $assert->is($calls, 0, 'mb804-1162: private address cannot reach HTTP');

    my $mixed = Mediabot::RSS::Fetcher::fetch_feed_once(
        $url, resolver => sub { ['8.8.8.8', '10.1.2.3'] },
        requester => $requester,
    );
    $assert->is($mixed->{error}, 'blocked_destination',
        'mb804-1162: one private address poisons the whole DNS answer');
    $assert->is($calls, 0, 'mb804-1162: mixed address set cannot reach HTTP');

    my $literal = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://127.0.0.1/feed', resolver => sub { die 'must not resolve' },
        requester => $requester,
    );
    $assert->is($literal->{error}, 'blocked_ip',
        'mb804-1162: loopback literal remains blocked before DNS');
    $assert->is($calls, 0, 'mb804-1162: loopback literal cannot reach HTTP');

    my $redirect_calls = 0;
    my $redirect = Mediabot::RSS::Fetcher::fetch_feed_once(
        $url,
        resolver => sub {
            my ($host) = @_;
            return ['8.8.8.8'] if $host eq 'feed.example';
            die 'second DNS lookup failed';
        },
        requester => sub {
            $redirect_calls++;
            return { success => 0, status => 302,
                headers => { location => 'https://next.example/rss' } };
        },
    );
    $assert->is($redirect->{error}, 'dns_unavailable',
        'mb804-1162: redirect DNS failure is reported distinctly');
    $assert->is($redirect_calls, 1,
        'mb804-1162: redirect destination is never requested after DNS failure');
};
