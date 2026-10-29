use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::RSS qw(parse_feed_document latest_feed_item format_rss_announcement);
use Mediabot::RSS::Fetcher ();
use Mediabot::RSS::Poller;

sub atom_1389 {
    my ($prefix, $ids, $title) = @_;
    $title = 'Bulletin' unless defined $title;
    my $p = length($prefix) ? "$prefix:" : '';
    my $xml = qq{<${p}feed xmlns="http://www.w3.org/2005/Atom" xmlns:a="http://www.w3.org/2005/Atom" xmlns:b="http://www.w3.org/2005/Atom">};
    $xml .= "<${p}title>$title</${p}title>" if length $title;
    for my $id (@$ids) {
        $xml .= "<${p}entry><${p}title>Article $id — été</${p}title>"
            . "<${p}id>tag:example.org,2026:$id</${p}id>"
            . qq{<${p}link rel="alternate" href="https://example.org/articles/$id"/>}
            . sprintf('<%supdated>2026-10-%02dT12:00:00Z</%supdated>', $p, $id, $p)
            . "</${p}entry>";
    }
    return $xml . "</${p}feed>";
}
sub projection_1389 {
    my ($xml, %opts) = @_;
    my $r = parse_feed_document($xml, %opts);
    return {map { $_ => $r->{$_} } qw(ok format title items)};
}
{
    my (@actual, @expected);
    for my $title ('Bulletin', '') {
        for my $p ('a', 'b') {
            push @actual, projection_1389(atom_1389($p, [1, 2], $title));
            push @expected, projection_1389(atom_1389('', [1, 2], $title));
        }
    }
    is_deeply(\@actual, \@expected,
        'prefixed Atom entries keep articles, fields, keys and feed-title boundaries');
}
{
    my $plain = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">'
        . '<channel><title>RDF Bulletin</title></channel>'
        . '<item><title>Article RDF</title><link>https://example.org/rdf/1</link><guid>rdf:1</guid></item></rdf:RDF>';
    my $prefixed = $plain;
    $prefixed =~ s/xmlns=/xmlns:r=/;
    $prefixed =~ s{<(/?)(channel|title|item|link|guid)\b}{<$1r:$2}g;
    is_deeply(projection_1389($prefixed), projection_1389($plain),
        'prefixed RDF/RSS channel and items retain source title and article identity');
}
{
    my $xml = atom_1389('a', [1, 2, 3]);
    $xml =~ s{<a:entry>(.*?)</a:entry>}{<b:entry>$1</b:entry>}s;
    my $result = parse_feed_document($xml, max_items => 2);
    my $plain = parse_feed_document(atom_1389('', [1, 2]), max_items => 2);
    my $latest = latest_feed_item($result->{items});
    is_deeply([$result->{items}, $latest], [$plain->{items}, $plain->{items}[1]],
        'mixed namespace aliases preserve feed order, item limit and newest-article selection');
}

{
    package MB1014::Repo;
    sub new { bless {rows => {}, successes => 0, errors => []}, shift }
    sub insert_item {
        my ($s, $id, $item, %opts) = @_;
        return 0 if exists $s->{rows}{$id}{$item->{item_key}};
        $s->{rows}{$id}{$item->{item_key}} = {%$item, announced => $opts{announced}};
        return 1;
    }
    sub record_poll_success { $_[0]{successes}++; 1 }
    sub record_poll_error { push @{$_[0]{errors}}, [@_[1, 2]]; 1 }
    sub pending_items {
        my ($s, $id, $limit) = @_;
        my @rows = sort {$a->{title} cmp $b->{title}}
            grep {!$_->{announced}} values %{$s->{rows}{$id} || {}};
        splice @rows, $limit if @rows > $limit;
        return \@rows;
    }
}
my $repo = MB1014::Repo->new;
my $xml = atom_1389('a', [1, 2]);
my (@requests, @warnings);
my $poller = Mediabot::RSS::Poller->new(repo => $repo, fetcher => sub {
    my ($url, %opts) = @_;
    return Mediabot::RSS::Fetcher::fetch_feed_once($url, %opts,
        resolver => sub { ['93.184.216.34'] },
        requester => sub {
            my ($target, %request) = @_;
            push @requests, [$target, $request{validated_addresses}, $request{request_headers}];
            return {success => 1, status => 200, content => encode('UTF-8', $xml),
                headers => {'content-type' => 'application/atom+xml; charset=utf-8', etag => '"v1"'}};
        });
});
my $feed = {id_rss_feed => 17, channel => '#news', label => 'Bulletin',
    url => 'https://example.org/feed', announce_limit => 1, last_success_at => undef};
my $run = sub {
    local $SIG{__WARN__} = sub {push @warnings, @_};
    return $poller->poll_feed($feed);
};
my $baseline = $run->();
my $rows = sub { return [sort {$a->{id} cmp $b->{id}} values %{$repo->{rows}{17} || {}}] };
is_deeply([$baseline->{ok}, $baseline->{baseline}, $baseline->{inserted}, $baseline->{pending},
           [map {$_->{announced}} @{$rows->()}]],
    [1, 1, 2, [], [1, 1]],
    'real fetch/decode/parser/poller stores prefixed initial articles as already announced');
my $saved = [map {{%$_}} @{$rows->()}];
$feed->{last_success_at} = '2026-10-29 12:00:00';
$feed->{etag} = '"v1"';
my @repeats;
for my $prefix ('b', '') {
    $xml = atom_1389($prefix, [1, 2]);
    my $result = $run->();
    push @repeats, [$result->{ok}, $result->{inserted}, $result->{pending}, $rows->()];
}
is_deeply(\@repeats, [[1, 0, [], $saved], [1, 0, [], $saved]],
    'renaming or removing XML prefixes does not duplicate or reannounce initial articles');
$xml = atom_1389('b', [3, 4, 1, 2]);
my $new = $run->();
my $pending = $new->{pending} || [];
my $line = @$pending ? format_rss_announcement(label => 'Bulletin', %{$pending->[0]}) : undef;
my $expected_line = format_rss_announcement(label => 'Bulletin', title => 'Article 3 — été',
    url => 'https://example.org/articles/3');
is_deeply([$new->{ok}, $new->{baseline}, $new->{inserted},
           [map {$_->{id}} @$pending], [map {$_->{announced}} @{$rows->()}],
           $line, $repo->{successes}, $repo->{errors}, \@warnings, \@requests],
    [1, 0, 2, ['tag:example.org,2026:3'], [1, 1, 0, 1], $expected_line, 4, [], [],
     [map {['https://example.org/feed', ['93.184.216.34'], $_ ? {'If-None-Match' => '"v1"'} : {}]} 0..3]],
    'later poll announces the new article only, respects overflow suppression and preserves HTTP validators');
{
    my $rss = '<rss><channel><title>Plain RSS</title><item><title>Plain article</title>'
        . '<link>https://example.org/plain</link><guid>plain:1</guid></item></channel></rss>';
    my $parsed = parse_feed_document($rss);
    my @errors = map {parse_feed_document($_)->{error}} (
        '<!DOCTYPE feed><a:feed/>', '<!ENTITY x "bad"><a:feed/>', "<a:feed>\0</a:feed>", '<html/>');
    is_deeply([$parsed->{ok}, $parsed->{format}, $parsed->{title}, $parsed->{items}[0]{guid},
               scalar(@{$parsed->{items}}), \@errors],
        [1, 'rss', 'Plain RSS', 'plain:1', 1,
         ['forbidden_doctype', 'forbidden_doctype', 'nul_byte', 'unsupported_feed']],
        'ordinary RSS and existing declaration/NUL/unsupported-document guards stay unchanged');
}
done_testing;
