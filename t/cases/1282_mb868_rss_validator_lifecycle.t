use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::RSS::Repository;
use Mediabot::RSS::Poller;
use Mediabot::RSS::Fetcher;

# Execute the real repository UPDATEs against a disposable in-memory database.
# NOW is the only SQL dialect adapter; no production schema is altered.
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->sqlite_create_function('NOW', 0, sub {'2026-10-21 05:00:00'});
$dbh->do(q{CREATE TABLE RSS_FEED (id_rss_feed INTEGER PRIMARY KEY,
    etag TEXT, last_modified TEXT, last_poll_at TEXT, last_success_at TEXT,
    last_error_at TEXT, last_error TEXT)});
$dbh->do(q{CREATE TABLE RSS_ITEM (id_rss_item INTEGER, id_rss_feed INTEGER,
    item_key TEXT, title TEXT, url TEXT, published_raw TEXT, seen_at TEXT, announced_at TEXT)});
$dbh->do(q{INSERT INTO RSS_FEED (id_rss_feed, last_success_at) VALUES (7, '2026-10-20 00:00:00')});
my $repo = Mediabot::RSS::Repository->new(dbh => $dbh);
my $row = sub {$dbh->selectrow_hashref('SELECT * FROM RSS_FEED WHERE id_rss_feed = 7')};
my $seed = sub {
    $dbh->do(q{UPDATE RSS_FEED SET etag = ?, last_modified = ?, last_error = 'old failure',
        last_error_at = '2026-10-20 00:00:00' WHERE id_rss_feed = 7}, undef, @_[0,1]);
};
my $old_date = 'Tue, 20 Oct 2026 00:00:00 GMT';
my $new_date = 'Wed, 21 Oct 2026 00:00:00 GMT';
for my $case (
    ['full body without validators', 'record_poll_success', {}, undef, undef],
    ['full body with ETag only', 'record_poll_success', {etag => '"new"'}, '"new"', undef],
    ['full body with date only', 'record_poll_success', {last_modified => $new_date}, undef, $new_date],
    ['full body with both validators', 'record_poll_success', {etag => '"new"', last_modified => $new_date}, '"new"', $new_date],
    ['304 without validators', 'record_not_modified', {}, '"old"', $old_date],
    ['304 with ETag only', 'record_not_modified', {etag => '"new"'}, '"new"', $old_date],
    ['304 with date only', 'record_not_modified', {last_modified => $new_date}, '"old"', $new_date],
    ['304 with both validators', 'record_not_modified', {etag => '"new"', last_modified => $new_date}, '"new"', $new_date],
) {
    my ($label, $method, $meta, $etag, $date) = @$case;
    $seed->('"old"', $old_date);
    ok($repo->$method(7, %$meta), "$label: repository succeeds");
    my $state = $row->();
    is($state->{etag}, $etag, "$label: stored ETag follows the current representation");
    is($state->{last_modified}, $date, "$label: stored date follows the current representation");
    is($state->{last_poll_at}, '2026-10-21 05:00:00', "$label: poll health updated");
    is($state->{last_success_at}, '2026-10-21 05:00:00', "$label: success recorded");
    is($state->{last_error}, undef, "$label: old error cleared");
    is($state->{last_error_at}, undef, "$label: old error timestamp cleared");
}

# A failed poll cannot discard the validators of the last accepted body.
$seed->('"old"', $old_date);
$repo->record_poll_error(7, 'http_status');
is($row->()->{etag}, '"old"', 'failed poll preserves ETag');
is($row->()->{last_modified}, $old_date, 'failed poll preserves Last-Modified');

# Follow complete wire cycles through the real fetcher, poller and repository.
for my $not_modified (0, 1) {
    $seed->('"old"', $old_date);
    my @headers;
    my $poller = Mediabot::RSS::Poller->new(repo => $repo, fetcher => sub {
        my ($url, %args) = @_;
        return Mediabot::RSS::Fetcher::fetch_feed_once($url, %args,
            resolver => sub {['8.8.8.8']}, requester => sub {
                my ($target, %options) = @_;
                push @headers, {%{$options{request_headers}}};
                return {status => 304, headers => {}, content => ''} if $not_modified;
                return {success => 1, status => 200, headers => {},
                    content => '<rss version="2.0"><channel><title>Local</title></channel></rss>'};
            });
    });
    for (1 .. 2) {
        my $stored = $row->();
        my $result = $poller->poll_feed({%$stored, channel => '#i/o',
            url => 'https://feed.example.test/rss', announce_limit => 1});
        ok($result->{ok}, 'wire cycle is accepted');
    }
    is($headers[0]{'If-None-Match'}, '"old"', 'first request validates the previous body');
    is($headers[0]{'If-Modified-Since'}, $old_date, 'first request includes the previous date');
    is($headers[1]{'If-None-Match'}, $not_modified ? '"old"' : undef,
        'next request keeps validators after 304, clears them after a new body');
    is($headers[1]{'If-Modified-Since'}, $not_modified ? $old_date : undef,
        'next request applies the same lifecycle to Last-Modified');
}
$dbh->disconnect;
done_testing();
