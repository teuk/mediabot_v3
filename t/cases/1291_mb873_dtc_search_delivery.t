use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::DTC::Source qw(search_ids);
use Mediabot::DTC::Commands ();
use MB840AsyncFixture qw(fixture pump record_output);

my $bad = '<a href="https://foreign.test/quote/999.html">unrelated</a>'
    . join('', map {qq{<a href="/quote/${_}.html">invalid</a>}} ('0', '01', map {'123456789012'.$_} 1 .. 22));
my $mixed = '<a href="/?uddg=https%3A%2F%2Fdanstonchat.com%2Fquote%2F101.html">first result</a>'
    . join('', map {qq{<a href="/quote/${_}.html">later result</a>}} 202 .. 208);
my @calls;
my $trace;
my $mode = 'fallback';
my $fetcher = sub {
    my ($url, %options) = @_;
    push @calls, {url => $url, timeout => $options{timeout}, max_items => $options{max_items}};
    if (defined $trace) {
        open my $fh, '>>', $trace or die $!;
        print {$fh} encode_json({url => $url, timeout => $options{timeout}})."\n";
        close $fh or die $!;
    }
    my $html;
    if ($url =~ m{\Ahttps://(?:lite[.])?duckduckgo[.]com/}) {
        $html = $mode eq 'empty' ? '<p>no results</p>' : $bad;
    }
    elsif ($url =~ m{\Ahttps://danstonchat[.]com/\?s=}) {
        $html = $mode eq 'empty' ? '<p>no results</p>' : $mixed;
    }
    elsif ($url =~ m{\Ahttps://danstonchat[.]com/quote/([1-9][0-9]{0,11})[.]html\z}) {
        my $id = $1;
        my $canonical = $mode eq 'mismatch' ? 777 : $id;
        $html = qq{<link rel="canonical" href="https://danstonchat.com/quote/$canonical.html">}
            . qq{<article><a href="/quote/$id.html">permalink</a><div class="entry-content"><p>Speaker: selected quote $id</p></div></article>};
    }
    else { die "unexpected offline destination: $url" }
    my $parsed = $options{parser}->($html);
    return {ok => 1, status => 200, url => $url, feed => $parsed};
};

my $result = search_ids('linux', fetcher => $fetcher);
ok($result->{ok}, 'real source search completes');
is_deeply($result->{ids}, [qw(101 202 203 204 205)], 'first five usable distinct results retain mixed-link order');
is(scalar @calls, 3, 'invalid-only results allow both search-engine passes and the site fallback');
like($result->{source_url} // '', qr{\Ahttps://danstonchat[.]com/\?s=linux\z}, 'source identifies the fallback that supplied actual results');
like($calls[0]{url}, qr{\Ahttps://duckduckgo[.]com/html/}, 'narrow search remains first');
like($calls[1]{url} // '', qr{\Ahttps://lite[.]duckduckgo[.]com/lite/}, 'lite search remains second');
is($calls[0]{timeout}, 8, 'per-attempt HTML timeout remains eight seconds');
is($calls[0]{max_items}, 1, 'HTML parser fetch contract is unchanged');

@calls = ();
$mode = 'empty';
$result = search_ids('linux', fetcher => $fetcher);
is_deeply($result->{ids}, [], 'three empty sources still return a successful empty search');
is(scalar @calls, 3, 'empty search still uses the bounded three-source plan');
@calls = ();
for my $query ('', 'x' x 161, "bad\0query") {
    ok(!search_ids($query, fetcher => $fetcher)->{ok}, 'invalid query remains rejected');
}
is(scalar @calls, 0, 'invalid queries never reach source IO');

# Exercise both real public handlers, the source parser, identity-checked
# detail parser and actual CommandAsync fork/pipe/replay. Only IO is replaced.
no warnings qw(redefine once);
local *Mediabot::RSS::Fetcher::fetch_feed_once = $fetcher;
local *Mediabot::Helpers::chanset_enabled = sub {1};
local *Mediabot::Helpers::botPrivmsg = \&record_output;
local *Mediabot::Helpers::botNotice = \&record_output;
my %handlers = Mediabot::_builtin_public_command_handlers();
my $tmp = tempdir('mb873-search-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $alias (qw(dtc bashfr)) {
    $mode = 'fallback';
    $trace = "$tmp/$alias.jsonl";
    my ($bot, undef, $loop) = fixture();
    my $ctx = Mediabot::Context->new(bot => $bot, channel => '#test', nick => 'Reader', command => $alias, args => ['linux']);
    ok($handlers{$alias}->($ctx), "$alias search starts through its real public handler");
    ok(pump($loop, sub {!keys %{$bot->{_cmd_async_jobs}}}, 5), "$alias real command worker finishes");
    is($bot->{_cmd_async_stats}{spawned} // 0, 1, "$alias search crosses the native worker");
    my @lines = map {$_->[1]} @{$bot->{out}};
    like($lines[0] // '', qr/\[DansTonChat : 101\|202\|203\|204\|205\]/, "$alias heading contains usable results in order");
    like($lines[1] // '', qr/\[101\].*selected quote 101/, "$alias displays the first actual search result");
    is(scalar @lines, 2, "$alias emits one heading and one complete quote line");
    ok(!grep({$_->[0] ne '#test'} @{$bot->{out}}), "$alias reply keeps the requesting channel");
    open my $fh, '<', $trace or die $!;
    my @seen = map {decode_json($_)} <$fh>;
    close $fh;
    is(scalar @seen, 4, "$alias uses three bounded searches then one detail fetch");
    is($seen[-1]{url}, 'https://danstonchat.com/quote/101.html', "$alias fetches only the selected canonical detail URL");
    ok(!grep({$_->{url} =~ /foreign[.]test|\/quote\/(?:999|0|01)[.]html/} @seen), "$alias never fetches foreign or invalid candidate URLs");
}

$mode = 'mismatch';
$trace = undef;
my ($bot, undef, $loop) = fixture();
my $ctx = Mediabot::Context->new(bot => $bot, channel => '#test', nick => 'Reader', command => 'dtc', args => ['linux']);
ok($handlers{dtc}->($ctx), 'identity-mismatched detail request starts');
ok(pump($loop, sub {!keys %{$bot->{_cmd_async_jobs}}}, 5), 'identity-mismatched detail worker finishes');
my $text = join "\n", map {$_->[1]} @{$bot->{out}};
like($text, qr/impossible d'afficher la quote #101/, 'existing detail identity guard refuses the wrong canonical page');
unlike($text, qr/selected quote|\[777\]/, 'wrong detail text never replaces the requested search result');
done_testing;
