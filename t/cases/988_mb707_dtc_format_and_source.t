use strict;
use warnings;
use utf8;

BEGIN {
    package Mediabot::Helpers;
    sub botPrivmsg { 1 }
    sub botNotice { 1 }
    sub chanset_enabled { 1 }
    $INC{'Mediabot/Helpers.pm'} = __FILE__;

    package Mediabot::CommandAsync;
    sub run_ctx_async { 1 }
    $INC{'Mediabot/CommandAsync.pm'} = __FILE__;
}
use Mediabot::DTC::Commands;
use Mediabot::DTC::Source qw(fetch_by_id fetch_random search_ids);

return sub {
    my ($assert) = @_;

    my $lines = Mediabot::DTC::Commands::format_quote_lines('123', join("\n", map { "line $_" } 1..12));
    $assert->is(scalar(@$lines), 10, 'mb707-988: output is capped at ten IRC lines');
    $assert->like($lines->[0], qr/\[123\].*line 1/, 'mb707-988: first line carries the ID and quote text');
    $assert->is($lines->[-2], "\x0300,14...\x0f", 'mb707-988: long quote gets an ellipsis');
    $assert->like($lines->[-1], qr{danstonchat\.com/quote/123\.html}, 'mb707-988: long quote ends with canonical source URL');

    my $header = Mediabot::DTC::Commands::format_search_header([1,2,3,4,5,6]);
    $assert->like($header, qr/\[DansTonChat : 1\|2\|3\|4\|5\]/, 'mb707-988: search header shows at most five IDs');

    my @calls;
    my $fetcher = sub {
        my ($url, %opts) = @_;
        push @calls, $url;
        my $html = $url =~ m{/quote/77\.html}
            ? '<div class="entry-content"><p>hello<br>world</p></div></div>'
            : '<a href="/quote/77.html">hit</a>';
        my $parsed = $opts{parser}->($html, max_items => 1);
        return { ok => 1, status => 200, url => $url, feed => $parsed };
    };

    my $idres = fetch_by_id(77, fetcher => $fetcher);
    $assert->ok($idres->{ok} && $idres->{text} eq "hello\nworld", 'mb707-988: numeric source fetch parses quote body');

    my $rand = fetch_random(fetcher => sub {
        my ($url,%opts)=@_;
        my $p=$opts{parser}->('<a href="/quote/55.html">q</a><div class="entry-content">random line</div></div>');
        return {ok=>1,status=>200,url=>$url,feed=>$p};
    }, rand_cb => sub { 0 });
    $assert->ok($rand->{ok} && $rand->{id} eq '55', 'mb707-988: random mode selects a parsed quote without a second request');

    my $searched = search_ids('linux', fetcher => $fetcher);
    $assert->ok($searched->{ok} && join('|', @{$searched->{ids}}) eq '77', 'mb707-988: text search returns DTC quote IDs');
    $assert->like($calls[-1], qr/duckduckgo\.com/, 'mb707-988: search starts with DuckDuckGo narrow path');
};
