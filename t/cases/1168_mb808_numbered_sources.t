use strict;
use warnings;
use utf8;
use Mediabot::VDM::Source qw(vdm_article_url parse_vdm_article_document fetch_vdm_by_id);
use Mediabot::DTC::Source qw(dtc_quote_url parse_quote_by_id fetch_by_id);

sub mb808_vdm_page {
    my ($id, $story) = @_;
    return qq{<html><head><link rel="canonical" href="https://www.viedemerde.fr/article/test_$id.html"></head><body>
<article><span>Aujourd'hui, une suggestion étrangère. VDM</span><div data-route="/api/v2/article/999/vote"></div></article>
<article><span class="block text-blue-500 my-4">$story</span><div data-route="/api/v2/article/$id/vote"></div></article>
</body></html>};
}

return sub {
    my ($a) = @_;
    my $story = "Aujourd'hui, le numéro de mon billet mène au bon train. VDM";
    my $html = mb808_vdm_page(304759, $story);
    $a->is(vdm_article_url(304759), 'https://www.viedemerde.fr/article/304759', 'mb808: VDM ID uses official direct route');
    for my $bad (undef, 0, -1, '1/2', 'https://example.invalid', '1' x 13, {}) {
        $a->ok(!defined(vdm_article_url($bad)), 'mb808: invalid VDM ID cannot form a URL');
        $a->ok(!defined(dtc_quote_url($bad)), 'mb808: invalid DTC ID cannot form a URL');
    }
    my $parsed = parse_vdm_article_document($html, id => 304759);
    $a->ok($parsed->{ok}, 'mb808: actual VDM article shape parses');
    $a->is($parsed->{items}[0]{story}, $story, 'mb808: suggestions cannot replace requested VDM');
    $a->is(parse_vdm_article_document($html, id => 999)->{error}, 'article_id_mismatch', 'mb808: wrong VDM canonical ID is rejected');
    my $without = '<article><span>' . $story . '</span></article>';
    $a->is(parse_vdm_article_document($without, id => 304759)->{error}, 'article_not_found', 'mb808: arbitrary story without identity is rejected');
    my $meta = qq{<link rel="canonical" href="https://www.viedemerde.fr/article/t_304759.html"><meta name="description" content="$story">};
    $a->ok(parse_vdm_article_document($meta, id => 304759)->{ok}, 'mb808: full official description fallback requires matching canonical');
    $a->is(parse_vdm_article_document("<html>\0</html>", id => 304759)->{error}, 'nul_byte', 'mb808: VDM NUL input fails closed');
    my @calls;
    my $fetcher = sub {
        my ($url, %opts) = @_;
        push @calls, $url;
        return { ok => 1, status => 200, url => 'https://www.viedemerde.fr/article/t_304759.html', feed => $opts{parser}->($html) };
    };
    my $res = fetch_vdm_by_id(304759, feed_fetcher => $fetcher);
    $a->ok($res->{ok} && $res->{items}[0]{id} eq '304759', 'mb808: VDM numbered transport returns the requested ID');
    $a->is($calls[0], vdm_article_url(304759), 'mb808: VDM numbered request never fetches the recent feed');
    my $bad_redirect = fetch_vdm_by_id(304759, feed_fetcher => sub {
        return { ok => 1, url => 'https://www.viedemerde.fr/article/t_999.html', feed => $parsed };
    });
    $a->is($bad_redirect->{error}, 'article_id_mismatch', 'mb808: VDM redirect to a different ID is rejected');
    $a->is(fetch_vdm_by_id(304759, feed_fetcher => sub { return {ok => 0, status => 404, error => 'http_status'} })->{status}, 404, 'mb808: missing VDM preserves failure without fallback');

    my $dtc = <<'HTML';
<link rel="canonical" href="https://danstonchat.com/quote/77.html">
<article><h2><a href="/quote/88.html">88</a></h2><div class="entry-content">wrong quote</div></article>
<article><h2><a href="/quote/77.html">77</a></h2><div class="entry-content"><p>&lt;Pablo&gt; hello</p><div>&lt;Max_&gt; nested</div><p>last line</p></div></article>
HTML
    my $quote = parse_quote_by_id($dtc, 77);
    $a->ok($quote->{ok}, 'mb808: DTC numbered parser selects requested card');
    $a->like($quote->{text}, qr/Max_.*nested.*last line/s, 'mb808: nested div no longer truncates numbered quote');
    $a->unlike($quote->{text}, qr/wrong quote/, 'mb808: earlier card cannot steal requested quote');
    $a->is(parse_quote_by_id($dtc, 88)->{error}, 'quote_id_mismatch', 'mb808: DTC wrong canonical ID is rejected');
    $a->is(parse_quote_by_id('<div class="entry-content">a</div><div class="entry-content">b</div>', 77)->{error}, 'quote_not_found', 'mb808: ambiguous unlabelled cards fail closed');
    my $qfetch = sub {
        my ($url, %opts) = @_;
        push @calls, $url;
        return { ok => 1, status => 200, url => $url, feed => $opts{parser}->($dtc) };
    };
    $a->ok(fetch_by_id(77, fetcher => $qfetch)->{ok}, 'mb808: DTC direct fetch composes over bounded transport');
    $a->is($calls[-1], dtc_quote_url(77), 'mb808: DTC ID never becomes a random request');
    $a->is(fetch_by_id(77, fetcher => sub {return {ok=>1,url=>dtc_quote_url(88),feed=>{html=>$dtc}}})->{error}, 'quote_id_mismatch', 'mb808: DTC redirect to another ID is rejected');
    $a->is(fetch_by_id(77, fetcher => sub {return {ok=>0,status=>404,error=>'http_status'}})->{status}, 404, 'mb808: missing DTC does not select another quote');
};
