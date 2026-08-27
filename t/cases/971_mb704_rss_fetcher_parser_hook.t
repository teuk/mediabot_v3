use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::RSS::Fetcher ();

return sub {
    my ($assert) = @_;

    my @parser_calls;
    my $custom = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feeds.example.test/vdm.xml',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1,
                status  => 200,
                headers => { 'content-type' => 'application/rss+xml; charset=UTF-8' },
                content => '<rss><channel><item><title>x</title></item></channel></rss>',
            };
        },
        parser => sub {
            my ($xml, %opts) = @_;
            push @parser_calls, [ $xml, { %opts } ];
            return { ok => 1, format => 'vdm-test', items => [ { id => 7 } ] };
        },
        max_items => 7,
    );

    $assert->ok($custom->{ok}, 'mb704-971: RSS transport accepts an injected parser');
    $assert->is(scalar(@parser_calls), 1,
        'mb704-971: injected parser runs exactly once after transport/decoding');
    $assert->is($parser_calls[0][1]{max_items}, 7,
        'mb704-971: parser receives the bounded item limit');
    $assert->is($custom->{feed}{format}, 'vdm-test',
        'mb704-971: custom parser result flows through normal fetch result');

    my $boom = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feeds.example.test/vdm.xml',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return { success => 1, status => 200, headers => {}, content => '<rss></rss>' };
        },
        parser => sub { die "parser exploded\nsecond line" },
    );
    $assert->is($boom->{error}, 'parse_exception',
        'mb704-971: injected parser exceptions fail closed');
    $assert->unlike($boom->{detail}, qr/[\r\n]/,
        'mb704-971: parser exception detail is log-safe');

    my $default = Mediabot::RSS::Fetcher::fetch_feed_once(
        'https://feeds.example.test/default.xml',
        resolver => sub { return ['93.184.216.34'] },
        requester => sub {
            return {
                success => 1, status => 200, headers => {},
                content => '<rss><channel><title>T</title><item><title>Hello</title><link>https://example.com/x</link></item></channel></rss>',
            };
        },
    );
    $assert->ok($default->{ok},
        'mb704-971: existing RSS callers keep the default parser');
    $assert->is($default->{feed}{items}[0]{title}, 'Hello',
        'mb704-971: default RSS parser behavior is preserved');
};
