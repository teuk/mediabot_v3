# t/cases/896_mb692_rss_public_ipv6.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS qw(is_public_ip_literal validate_feed_url);

return sub {
    my ($assert) = @_;

    for my $ip (
        '2606:4700:20::ac43:4873',
        '2606:4700:20::681a:35e',
        '2001:4860:4860::8888',
    ) {
        $assert->is(is_public_ip_literal($ip), 1,
            "mb692-896: global IPv6 accepted: $ip");
    }

    for my $ip (
        '::',
        '::1',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '::ffff:127.0.0.1',
        '::ffff:10.0.0.8',
        '::ffff:192.168.1.2',
    ) {
        $assert->is(is_public_ip_literal($ip), 0,
            "mb692-896: special/private IPv6 rejected: $ip");
    }

    $assert->is(is_public_ip_literal('::ffff:8.8.8.8'), 1,
        'mb692-896: IPv4-mapped public IPv4 keeps IPv4 policy');

    $assert->ok(validate_feed_url('https://[2606:4700:20::ac43:4873]/feed')->{ok},
        'mb692-896: public IPv6 URL literal accepted');
    $assert->ok(!validate_feed_url('https://[::ffff:127.0.0.1]/feed')->{ok},
        'mb692-896: mapped loopback URL rejected');

    {
        package FakeTiny896;
        our @SEEN;
        sub get {
            my ($self, $url, $args) = @_;
            push @SEEN, $args->{peer};
            return { success => 0, status => 599, headers => {}, content => 'no route' }
                if $args->{peer} eq '104.26.2.1';
            return { success => 1, status => 200, headers => {}, content => '<rss></rss>' };
        }
    }
    require Mediabot::RSS::Fetcher;
    no warnings qw(redefine once);
    local *HTTP::Tiny::new = sub { bless {}, 'FakeTiny896' };
    @FakeTiny896::SEEN = ();
    my $fallback = Mediabot::RSS::Fetcher::_default_requester(
        'https://feed.example/rss',
        validated_addresses => ['2606:4700:20::1', '104.26.2.1', '104.26.2.94'],
    );
    $assert->ok($fallback->{success} && $fallback->{status} == 200,
        'mb692-896: transport 599 falls back to next validated peer');
    $assert->is(join(',', @FakeTiny896::SEEN), '104.26.2.1,104.26.2.94',
        'mb692-896: validated IPv4 peers are preferred and retried without DNS');

    my $src;
    {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/RSS.pm' or die $!;
        local $/; $src = <$fh>;
    }
    $assert->like($src, qr/\(grep \{ \$_ != 0 \} \@b\[0\.\.14\]\) == 0/,
        'mb692-896: loopback grep scalarized before boolean AND');
    $assert->like($src, qr/\(grep \{ \$_ != 0 \} \@b\[0\.\.9\]\) == 0/,
        'mb692-896: mapped-address grep scalarized before boolean AND');
};
