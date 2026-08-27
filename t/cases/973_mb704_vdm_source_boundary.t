use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::VDM qw(vdm_feed_url);
use Mediabot::VDM::Source qw(fetch_vdm_once);

sub _slurp_973 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my @seen;
    my $res = fetch_vdm_once(
        max_items => 3,
        timeout => 9,
        feed_fetcher => sub {
            my ($url, %opts) = @_;
            push @seen, [ $url, { %opts } ];
            my $parsed = $opts{parser}->(<<'XML', max_items => $opts{max_items});
<rss><channel><item>
<link>https://www.viedemerde.fr/article/test_777.html</link>
<description>Aujourd'hui, même les tests ont besoin de café. VDM</description>
</item></channel></rss>
XML
            return { ok => 1, status => 200, url => $url, feed => $parsed };
        },
    );

    $assert->ok($res->{ok}, 'mb704-973: VDM source composes over shared RSS transport boundary');
    $assert->is($seen[0][0], vdm_feed_url(),
        'mb704-973: VDM source requests only the canonical official feed URL');
    $assert->is($seen[0][1]{max_items}, 3,
        'mb704-973: source preserves bounded fetch size');
    $assert->is($seen[0][1]{timeout}, 9,
        'mb704-973: source preserves transport timeout option');
    $assert->ok(ref($seen[0][1]{parser}) eq 'CODE',
        'mb704-973: VDM parser is injected below the shared RSS transport');
    $assert->is($res->{items}[0]{id}, '777',
        'mb704-973: normalized VDM item crosses source boundary');

    my $boom = fetch_vdm_once(feed_fetcher => sub { die "offline failure\n" });
    $assert->is($boom->{error}, 'fetch_exception',
        'mb704-973: source fetch exceptions are normalized');
    $assert->unlike($boom->{detail}, qr/[\r\n]/,
        'mb704-973: source error detail is safe for later logs');

    my $main = _slurp_973('mediabot.pl');
    $assert->unlike($main, qr/Mediabot::VDM::(?:Source|AsyncFetcher)/,
        'mb704-973: top-level executable never bypasses the VDM source/worker boundary');

    my $async_src = _slurp_973('Mediabot/VDM/AsyncFetcher.pm');
    $assert->like($async_src, qr/worker_class.*Mediabot::AsyncWorker/s,
        'mb704-973: async source uses the shared worker contract');
    $assert->unlike($async_src, qr/HTTP::Tiny|LWP::|curl\b|wget\b/i,
        'mb704-973: parent async layer contains no direct network client');
};
