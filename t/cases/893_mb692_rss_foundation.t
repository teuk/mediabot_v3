# t/cases/893_mb692_rss_foundation.t
use strict;
use warnings;
use utf8;

use Mediabot::RSS qw(
    normalize_feed_label validate_feed_url is_public_ip_literal
    parse_feed_document rss_item_key format_rss_announcement format_rss_feed_list
);

sub _slurp_893 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    $assert->is(
        normalize_feed_label("  Journal   du Geek  "),
        'Journal du Geek',
        'mb692-893: labels normalize whitespace',
    );
    $assert->is(
        normalize_feed_label("\00304Bad\002 Feed"),
        '04Bad Feed',
        'mb692-893: labels strip IRC controls',
    );
    $assert->ok(
        !defined normalize_feed_label("\r\n"),
        'mb692-893: control-only label rejected',
    );

    my $good = validate_feed_url('https://example.org/feed.xml');
    $assert->ok(
        $good->{ok} && $good->{host} eq 'example.org' && $good->{port} == 443,
        'mb692-893: public HTTPS feed accepted',
    );
    $assert->ok(
        validate_feed_url('http://93.184.216.34/rss')->{ok},
        'mb692-893: public IPv4 literal accepted',
    );

    for my $bad (
        'file:///etc/passwd',
        'ftp://example.org/feed',
        'https://user:pass@example.org/feed',
        'http://localhost/feed',
        'http://127.0.0.1/feed',
        'http://10.0.0.8/feed',
        'http://172.16.4.2/feed',
        'http://192.168.1.5/feed',
        'http://169.254.169.254/latest/meta-data/',
        'http://100.64.1.1/feed',
        'https://[::1]/feed',
        'https://[fc00::1]/feed',
        'https://[fe80::1]/feed',
        'https://[2001:db8::1]/feed',
        'http://example.org:22/feed',
    ) {
        $assert->ok(
            !validate_feed_url($bad)->{ok},
            "mb692-893: unsafe URL rejected: $bad",
        );
    }

    $assert->is(is_public_ip_literal('8.8.8.8'), 1,
        'mb692-893: public IPv4');
    $assert->is(is_public_ip_literal('192.168.0.1'), 0,
        'mb692-893: private IPv4');
    $assert->ok(
        !defined is_public_ip_literal('example.org'),
        'mb692-893: DNS resolution is deferred to connect time',
    );

    my $rss = <<'XML';
<rss version="2.0"><channel><title>Korben.info</title>
<item><title><![CDATA[Premier &amp; article]]></title><link>https://example.org/a?x=1&amp;y=2</link><guid>guid-a</guid><pubDate>Sat, 22 Aug 2026 12:00:00 GMT</pubDate></item>
<item><title>Second article</title><link>https://example.org/b</link><guid>guid-b</guid></item>
</channel></rss>
XML

    my $parsed_rss = parse_feed_document($rss, max_items => 5);
    $assert->ok(
        $parsed_rss->{ok} && $parsed_rss->{format} eq 'rss',
        'mb692-893: RSS recognized',
    );
    $assert->is($parsed_rss->{title}, 'Korben.info',
        'mb692-893: RSS title');
    $assert->is(scalar(@{$parsed_rss->{items}}), 2,
        'mb692-893: RSS items');
    $assert->is($parsed_rss->{items}[0]{title}, 'Premier & article',
        'mb692-893: CDATA/entities normalized');
    $assert->is(
        $parsed_rss->{items}[0]{url},
        'https://example.org/a?x=1&y=2',
        'mb692-893: RSS URL entities decoded',
    );
    $assert->like(
        $parsed_rss->{items}[0]{item_key},
        qr/\A[0-9a-f]{64}\z/,
        'mb692-893: RSS item key',
    );

    my $atom = <<'XML';
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Source</title><entry>
<title>Atom headline</title><id>tag:example.org,2026:1</id>
<link rel="alternate" href="https://example.org/atom/1"/><updated>2026-08-22T12:30:00Z</updated>
</entry></feed>
XML

    my $parsed_atom = parse_feed_document($atom);
    $assert->ok(
        $parsed_atom->{ok} && $parsed_atom->{format} eq 'atom',
        'mb692-893: Atom recognized',
    );
    $assert->is($parsed_atom->{title}, 'Atom Source',
        'mb692-893: Atom title');
    $assert->is(
        $parsed_atom->{items}[0]{url},
        'https://example.org/atom/1',
        'mb692-893: Atom alternate link',
    );
    $assert->like(
        $parsed_atom->{items}[0]{item_key},
        qr/\A[0-9a-f]{64}\z/,
        'mb692-893: Atom item key',
    );

    $assert->is(
        parse_feed_document(
            '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss/>'
        )->{error},
        'forbidden_doctype',
        'mb692-893: DTD/XXE rejected',
    );
    $assert->is(
        parse_feed_document('<html>no feed</html>')->{error},
        'unsupported_feed',
        'mb692-893: non-feed rejected',
    );

    my $k1 = rss_item_key({ guid => 'same-guid', title => 'A' });
    my $k2 = rss_item_key({ guid => 'same-guid', title => 'B' });
    $assert->is($k1, $k2,
        'mb692-893: GUID dominates mutable title');
    $assert->ok(
        rss_item_key({ title => 'No ID', published => '2026-08-22' }),
        'mb692-893: deterministic fallback key',
    );

    $assert->is(
        format_rss_announcement(
            label => 'Journal du Geek',
            title => 'Une actualité',
            url   => 'https://example.org/story',
        ),
        "\001ACTION - news \002:\002 \00313[Journal du Geek]\0036 Une actualité \00313\002-\002\00314 https://example.org/story\001",
        'mb692-893: TCL announcement charter',
    );

    $assert->like(
        format_rss_feed_list('Korben.info', 'Numerama', 'NoFrag'),
        qr/\A\037Flux disponibles\037 : \00314Korben\.info\00313 \| \00314Numerama\00313 \| \00314NoFrag\003\z/,
        'mb692-893: TCL list charter',
    );

    my $schema = _slurp_893('install/mediabot.sql');
    my $mig    = _slurp_893('install/migrations/20260822_rss_feeds.sql');
    my $mread  = _slurp_893('install/migrations/README.md');
    my $main   = _slurp_893('Mediabot/Mediabot.pm');

    for my $table (qw(RSS_FEED RSS_ITEM)) {
        $assert->like(
            $schema,
            qr/CREATE TABLE `\Q$table\E`/,
            "mb692-893: fresh schema contains $table",
        );
        $assert->like(
            $mig,
            qr/CREATE TABLE IF NOT EXISTS `\Q$table\E`/,
            "mb692-893: migration creates $table idempotently",
        );
    }

    $assert->like($schema, qr/uq_rss_feed_channel_label/,
        'mb692-893: channel feed label uniqueness');
    $assert->like($schema, qr/uq_rss_feed_channel_url_hash/,
        'mb692-893: channel feed URL uniqueness');
    $assert->like($schema, qr/uq_rss_item_feed_key/,
        'mb692-893: durable item dedup uniqueness');
    $assert->like($schema, qr/fk_rss_item_feed/,
        'mb692-893: RSS item FK');
    $assert->like($mread, qr/^20260822_rss_feeds\.sql$/m,
        'mb692-893: migration is in authoritative order');
    $assert->like($mread, qr/^RSS_FEED \/ RSS_ITEM$/m,
        'mb692-893: RSS tables are documented on their own migration-summary line');

    $assert->like(
        $main,
        qr/\bnews\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async/s,
        'mb692-893: existing news path remains untouched',
    );
    my $rss_routes = () = $main =~ /^\s*rss\s*=>\s*sub /mg;
    $assert->is(
        $rss_routes,
        1,
        'mb692-893: R3 registers exactly one native m rss route',
    );
};
