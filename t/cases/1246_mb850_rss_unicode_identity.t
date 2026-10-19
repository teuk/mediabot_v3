use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Mediabot::RSS qw(rss_item_key parse_feed_document);
use Mediabot::RSS::Poller;

# Keep every previously valid key, including Latin-1 and already encoded bytes.
# UTF-8 upgrading a Perl scalar must not silently change durable identity.
for my $field (qw(id guid url)) {
    for my $value ('ascii', "caf\x{e9}", encode('UTF-8', "caf\x{e9}")) {
        my $bytes = $value;
        utf8::downgrade($bytes, 1) or die 'invalid legacy fixture';
        my $expected = sha256_hex("$field\0$bytes");
        for my $flag (0, 1) {
            my $input = $value; utf8::upgrade($input) if $flag;
            my $item = {$field => $input, title => 'ignored title'};
            is(rss_item_key($item), $expected, "$field legacy/flag=$flag retains exact stored key");
            is($item->{$field}, $input, "$field legacy/flag=$flag does not alter caller text");
        }
    }
}
is(rss_item_key({title => "caf\x{e9}", published => 'date'}),
    sha256_hex("fallback\0caf\xe9\0date"), 'legacy Latin-1 fallback identity is unchanged');

for my $field (qw(id guid url)) {
    my $value = "entry:東京 — 🧭";
    my $item = {$field => $value, title => 'title'};
    my ($key, $warning) = (undef, '');
    my $ok;
    {local $SIG{__WARN__} = sub {$warning .= $_[0]}; $ok = eval {$key = rss_item_key($item); 1}}
    ok($ok, "$field wide identity is hashable");
    is($warning, '', "$field wide identity emits no warning");
    is($key, sha256_hex(encode('UTF-8', "$field\0$value")), "$field wide identity hashes explicit UTF-8 bytes");
    is($item->{$field}, $value, "$field wide input remains character text");
}
my $fallback;
ok(eval {$fallback = rss_item_key({title => 'L’été 🧭', published => '2026'}); 1},
    'wide fallback title is hashable without an ID or URL');
is($fallback, sha256_hex(encode('UTF-8', join("\0", 'fallback', 'L’été 🧭', '2026'))),
    'wide fallback retains field separators and UTF-8 text');

# Numeric XML entities produce real Unicode even in an all-ASCII HTTP body.
my $rss = '<rss><channel><title>Feed</title>'
    . '<item><title>Legacy</title><guid>caf&#233;</guid></item>'
    . '<item><title>New &#x1F9ED;</title><guid>news:&#x6771;&#x4EAC;</guid></item>'
    . '</channel></rss>';
my $atom = '<feed><title>Feed</title><entry><title>New</title>'
    . '<id>tag:&#x1F9ED;</id></entry></feed>';
for my $doc ($rss, $atom,
    '<rss><channel><item><title>Fallback &#x2019; &#x1F9ED;</title></item></channel></rss>') {
    my $parsed;
    ok(eval {$parsed = parse_feed_document($doc); 1}, 'valid entity-based Unicode feed parses without digest exception');
    ok($parsed && $parsed->{ok}, 'Unicode RSS/Atom parse remains successful');
    my $items = ref($parsed) eq 'HASH' && ref($parsed->{items}) eq 'ARRAY' ? $parsed->{items} : [];
    like(@$items ? $items->[-1]{item_key} : '', qr/\A[0-9a-f]{64}\z/, 'parsed Unicode item has bounded key');
}

{
    package MB850::RSSRepo;
    sub new {bless {rows => {}, errors => [], successes => 0}, shift}
    sub insert_item {
        my ($self, $id, $item, %opts) = @_;
        return 0 if exists $self->{rows}{$item->{item_key}};
        $self->{rows}{$item->{item_key}} = {%$item, announced => $opts{announced}};
        return 1;
    }
    sub record_poll_success {$_[0]{successes}++; 1}
    sub record_poll_error {push @{$_[0]{errors}}, $_[2]; 1}
    sub pending_items {[grep {!$_->{announced}} values %{$_[0]{rows}}]}
}
my $repo = MB850::RSSRepo->new;
my $old_key = sha256_hex("guid\0caf\xe9");
$repo->{rows}{$old_key} = {item_key => $old_key, title => 'Previously announced', announced => 1};
my $poller = Mediabot::RSS::Poller->new(repo => $repo,
    fetcher => sub {return {ok => 1, status => 200, feed => parse_feed_document($rss)}});
my $feed = {id_rss_feed => 1, url => 'https://example.invalid/feed',
    announce_limit => 1, last_success_at => 'existing'};
my $first = $poller->poll_feed($feed);
ok($first->{ok}, 'actual poller accepts a feed containing wide IDs');
is($first->{inserted}, 1, 'legacy announced item retains its key; only new Unicode item is inserted');
is(scalar @{$first->{pending} || []}, 1, 'only the new Unicode article is eligible for announcement');
ok($repo->{rows}{$old_key}{announced}, 'old announced history remains suppressed');
my $second = $poller->poll_feed($feed);
ok($second->{ok}, 'second Unicode poll succeeds');
is($second->{inserted}, 0, 'Unicode identity deduplicates on repeat polls');
is(scalar keys %{$repo->{rows}}, 2, 'repeat polling creates no duplicate old or new article');
is(scalar @{$repo->{errors}}, 0, 'valid Unicode feed records no fetch exception');
my $bootstrap = MB850::RSSRepo->new;
my $initial = Mediabot::RSS::Poller->new(repo => $bootstrap,
    fetcher => sub {return {ok => 1, status => 200, feed => parse_feed_document($rss)}})
    ->poll_feed({%$feed, last_success_at => undef});
ok($initial->{ok} && $initial->{baseline}, 'first Unicode poll retains baseline mode');
is(scalar @{$initial->{pending} || []}, 0, 'Unicode support does not announce historical bootstrap items');

is(rss_item_key({}), undef, 'missing identity still returns no key');
is(rss_item_key('bad'), undef, 'invalid item shape remains rejected');
is(rss_item_key({id => 'first', guid => 'second', url => 'https://example.invalid'}),
    sha256_hex("id\0first"), 'ID precedence over GUID and URL stays unchanged');
done_testing;
