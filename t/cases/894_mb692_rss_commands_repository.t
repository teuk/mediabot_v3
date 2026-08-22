# t/cases/894_mb692_rss_commands_repository.t
# =============================================================================
# MB692-R3 — native RSS repository + command surface, without periodic polling.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS qw(canonical_feed_url validate_feed_url);
use Mediabot::RSS::Fetcher;
use Mediabot::RSS::Repository;

sub _slurp_894 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    $assert->is(
        canonical_feed_url('HTTPS://Example.COM:443/feed.xml#frag'),
        'https://example.com/feed.xml',
        'mb692-894: URL canonicalization lowers authority, drops default port and fragment',
    );
    $assert->is(
        canonical_feed_url('http://Example.COM'),
        'http://example.com/',
        'mb692-894: canonical feed root has an explicit path',
    );

    my $requests = 0;
    my $rss = '<rss><channel><title>Safe Feed</title>'
            . '<item><title>Hello</title><link>https://example.org/a</link><guid>1</guid></item>'
            . '</channel></rss>';
    my $ok = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            $requests++;
            return { success => 1, status => 200, headers => {}, content => $rss };
        },
        max_items => 3,
    );
    $assert->ok($ok->{ok}, 'mb692-894: safe one-shot fetch succeeds with injected transport');
    $assert->is($requests, 1, 'mb692-894: safe one-shot fetch makes one request');
    $assert->is($ok->{feed}{title}, 'Safe Feed', 'mb692-894: fetched feed is parsed');
    $assert->is(scalar(@{ $ok->{feed}{items} }), 1, 'mb692-894: fetched item is retained');

    my $blocked_calls = 0;
    my $blocked = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub { return ['127.0.0.1'] },
        requester => sub { $blocked_calls++; return { success => 1, status => 200, content => $rss } },
    );
    $assert->is($blocked->{error}, 'blocked_destination',
        'mb692-894: DNS resolving to loopback is rejected');
    $assert->is($blocked_calls, 0,
        'mb692-894: blocked DNS destination is rejected before HTTP request');

    my $redirect_calls = 0;
    my $redirect = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feed.example/rss',
        resolver => sub {
            my ($host) = @_;
            return ['93.184.216.34'] if $host eq 'feed.example';
            return ['10.0.0.8'];
        },
        requester => sub {
            $redirect_calls++;
            return {
                success => 0,
                status  => 302,
                headers => { location => 'http://internal.example/private' },
                content => '',
            };
        },
    );
    $assert->is($redirect->{error}, 'blocked_destination',
        'mb692-894: redirect target is DNS-validated independently');
    $assert->is($redirect_calls, 1,
        'mb692-894: private redirect is stopped before following it');

    my $fetch_src = _slurp_894('Mediabot/RSS/Fetcher.pm');
    $assert->like($fetch_src, qr/max_redirect\s*=>\s*0/,
        'mb692-894: HTTP client automatic redirects are disabled');
    $assert->like($fetch_src, qr/verify_SSL\s*=>\s*1/,
        'mb692-894: RSS HTTPS verification is enabled');
    $assert->like($fetch_src, qr/http_proxy.*https_proxy.*HTTP_PROXY.*HTTPS_PROXY/s,
        'mb692-894: ambient HTTP proxy variables are disabled for RSS fetching');
    $assert->like($fetch_src, qr/_validated_addresses.*?requester->/s,
        'mb692-894: destination addresses are validated immediately before each request');
    $assert->like($fetch_src, qr/301\|302\|303\|307\|308/,
        'mb692-894: redirect handling is explicit and bounded');

    my $repo_src = _slurp_894('Mediabot/RSS/Repository.pm');
    $assert->like($repo_src, qr/INSERT INTO RSS_FEED.*?VALUES \(\?, \?, \?, \?, \?, \?, \?, \?\)/s,
        'mb692-894: feed insertion is parameterized');
    $assert->like($repo_src, qr/sha256_hex\(\$url\)/,
        'mb692-894: canonical URL has a stable SHA-256 uniqueness key');
    $assert->like($repo_src, qr/my %allowed = map .*poll_interval announce_limit enabled/s,
        'mb692-894: dynamic setting column is allowlisted');
    $assert->unlike($repo_src, qr/DELETE FROM RSS_FEED WHERE .*label\s*=\s*['"]?\$label/,
        'mb692-894: delete path does not interpolate a feed label into SQL');

    my $cmd_src = _slurp_894('Mediabot/RSS/Commands.pm');
    for my $sub (qw(list info add del set probe show)) {
        $assert->like($cmd_src, qr/\b\Q$sub\E\b/,
            "mb692-894: command surface contains '$sub'");
    }
    $assert->like($cmd_src, qr/checkUserChannelLevel\([^\n]+400\)/,
        'mb692-894: feed mutation reuses channel level 400 ACL');
    $assert->like($cmd_src, qr/has_level\('Administrator'\)/,
        'mb692-894: global Administrator can manage channel feeds');
    $assert->like($cmd_src, qr/run_ctx_async.*?rss probe/s,
        'mb692-894: network probe runs outside the IRC event loop');
    $assert->like($cmd_src, qr/run_ctx_async.*?rss show/s,
        'mb692-894: on-demand feed display runs outside the IRC event loop');
    $assert->like($cmd_src, qr/interval=30.*max=5/,
        'mb692-894: add syntax keeps the TCL-inspired 30-minute / 5-item defaults');

    my $mb = _slurp_894('Mediabot/Mediabot.pm');
    $assert->like($mb, qr/^use Mediabot::RSS::Commands;$/m,
        'mb692-894: RSS command module is loaded by Mediabot');
    $assert->like($mb, qr/^\s*rss\s*=>\s*sub \{ Mediabot::RSS::Commands::mbRss_ctx\(\$ctx\) \},$/m,
        'mb692-894: m rss has one explicit route');
    $assert->like($mb, qr/^rss\|rss <list\|info\|add\|del\|set\|probe\|show>/m,
        'mb692-894: internal help documents the RSS family');
    $assert->like($mb, qr/^\s*news\s*=>\s*sub \{ Mediabot::CommandAsync::run_ctx_async/m,
        'mb692-894: existing news route remains unchanged');

    my $all = $fetch_src . $repo_src . $cmd_src;
    $assert->unlike($all, qr/Mediabot::Scheduler|Timer::Periodic|schedule\s*\(/,
        'mb692-894: R3 does not activate periodic RSS polling');
};
