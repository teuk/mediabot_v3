use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json);
use Mediabot::External ();
use Mediabot::External::URL ();
use Mediabot::External::XTwitter ();
use IPC::Open3;
use Symbol qw(gensym);

for my $order (
    [qw(External::XTwitter)],
    [qw(External::URL External::XTwitter External)],
    [qw(External External::XTwitter External::URL)],
) {
    my $code = "use Scalar::Util qw(refaddr);\n"
        . join('', map { "require Mediabot::$_;\n" } @$order);
    if (@$order == 1) {
        $code .= q{die 'eager URL load' if $INC{'Mediabot/External/URL.pm'};
            die 'eager AI load' if $INC{'Mediabot/External/Claude.pm'};
            die 'normalizer failed' unless
                Mediabot::External::XTwitter::_x_url('http://twitter.com/Studio/status/123')
                    eq 'https://x.com/Studio/status/123';
            die 'count formatting failed' unless
                Mediabot::External::XTwitter::_x_compact_count(999999) eq '1M';
            die 'lazy fallback failed' unless
                Mediabot::External::XTwitter::_x_fallback_title_from_url('https://twitter.com/Studio')
                    eq 'X profile: @Studio';};
    }
    $code .= q{require Mediabot::External;
        for my $name (@Mediabot::External::XTwitter::EXPORT_OK) {
            die 'legacy URL alias differs' unless
                refaddr(Mediabot::External::URL->can($name)) ==
                refaddr(Mediabot::External::XTwitter->can($name));
        }
        for my $name (qw(_x_url _x_title_from_html _x_fallback_title_from_url _handle_x_twitter)) {
            die 'facade alias differs' unless
                refaddr(Mediabot::External->can($name)) ==
                refaddr(Mediabot::External::XTwitter->can($name));
        }
        print 'loaded';};
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid($pid, 0);
    ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
        'X/Twitter loads and retains aliases in order: ' . join('/', @$order));
}

{
    package MB871XLog;
    sub log { 1 }
    package MB871XHTTP;
    sub get {
        my ($self, $url) = @_;
        push @{$self->{calls}}, $url;
        die 'unexpected offline API destination' unless $url =~ m{\Ahttps://api[.]fxtwitter[.]com/[^/]+/status/\d+\z};
        return {success => 1, status => 200, content => JSON::PP::encode_json({code => 200, tweet => {
            author => {name => 'Studio', screen_name => 'studio'}, text => "Post $url", likes => 12, retweets => 3,
        }})};
    }
}
sub x_bot_871 { return {logger => bless({}, 'MB871XLog'), out => []}; }

no warnings qw(redefine once);

{
    local *Mediabot::External::URL::_decode_html = sub { 'legacy decoded text' };
    my $bot = x_bot_871();
    is_deeply([
        Mediabot::External::XTwitter::_x_title_from_html($bot, '<title>input</title>', 'override'),
        Mediabot::External::XTwitter::_x_desc_from_html($bot, '<meta property="og:description" content="input">', 'override'),
    ], ['legacy decoded text', 'legacy decoded text'],
        'X/Twitter title and description still resolve the URL decoder at call time');
}
{
    my (@hooks, @out);
    local *Mediabot::External::URL::_x_url = sub {
        push @hooks, 'normalize'; return 'https://x.com/Hook/status/123';
    };
    local *Mediabot::External::URL::_url_cache_identity = sub {
        push @hooks, 'cache'; return 'legacy cache key';
    };
    local *Mediabot::External::URL::decode_json = sub {
        push @hooks, 'json';
        return {code=>200, tweet=>{author=>{name=>'Émission 🦉', screen_name=>'Hook'},
            text=>'Legacy text', likes=>12, retweets=>0}};
    };
    local *Mediabot::External::URL::_x_compact_count = sub {
        push @hooks, 'count'; return '12*';
    };
    local *Mediabot::External::_make_http = sub {
        push @hooks, 'http'; return bless {calls=>[]}, 'MB871XHTTP';
    };
    local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub { die 'unexpected browser' };
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, [$_[1], $_[2]]; 1 };
    my $bot = x_bot_871();
    my $ret = Mediabot::External::_handle_x_twitter($bot, undef, 'First', '#test', 'legacy input');
    my $replay = Mediabot::External::URL::_handle_x_twitter($bot, undef, 'Second', '#i/o', 'legacy replay');
    my @plain = map {my $s=$_->[1]; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; $s} @out;
    ok($ret && $replay && @out == 2
        && join('|', @hooks) eq 'normalize|cache|http|json|count|normalize|cache'
        && $out[0][0] eq '#test' && $out[1][0] eq '#i/o'
        && $plain[0] eq '(First) [X] Émission 🦉 (@Hook) on X: "Legacy text" (12* likes)'
        && $plain[1] eq '(Second) [X] Émission 🦉 (@Hook) on X: "Legacy text" (12* likes)'
        && utf8::is_utf8($out[0][1]) && utf8::is_utf8($out[1][1])
        && exists $bot->{_x_twitter_cache}{'legacy cache key'},
        'legacy normalization, JSON, counters and cache hooks survive facade delivery and replay');
}

my $http = bless({calls => []}, 'MB871XHTTP');
my @rendered;
our $shell = 0;
our $enabled = 1;
local *Mediabot::External::_make_http = sub { $http };
local *Mediabot::External::_chanset_ok = sub { $enabled };
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1], $_[2]]; 1 };
local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
    push @rendered, $_[1];
    return $shell ? '<title>X</title>' : "<title>Rendered $_[1]</title>";
};
local *Mediabot::External::URL::_handle_generic_title = sub { die 'X must use its dedicated handler' };
my $display = \&Mediabot::External::URL::displayUrlTitle;
my $handle = \&Mediabot::External::URL::_handle_x_twitter;

for my $host (qw(x.com twitter.com)) {
    for my $pair (
        ['i/spaces/1AbC123', 'i/spaces/1abc123'],
        ['search?q=AbC123', 'search?q=abc123'],
        ['i/spaces/1AbC123?cursor=QwE', 'i/spaces/1AbC123?cursor=qwe'],
        ['i/spaces/1AbC123#Segment', 'i/spaces/1AbC123#segment'],
    ) {
        my $bot = x_bot_871();
        @rendered = ();
        my @urls = map { "https://$host/$_" } @$pair;
        my @normalized = map { my $u = $_; $u =~ s{https://twitter[.]com}{https://x.com}; $u } @urls;
        for my $i (0 .. 1) {
            ok($display->($bot, undef, "Reader$i", '#test', $urls[$i]), "$host/$pair->[$i] is displayed");
            like($bot->{out}[-1][1] // '', qr/Rendered \Q$normalized[$i]\E/, 'title belongs to the selected resource');
        }
        is_deeply(\@rendered, \@normalized, 'case-distinct resources both reach Chromium with original path/query spelling');
        is(scalar keys %{$bot->{_x_twitter_cache}}, 2, 'metadata entries remain independent');
        my $variant = $urls[0];
        $variant =~ s{\Ahttps://([^/]+)}{'HTTPS://' . uc($1)}e;
        ok($display->($bot, undef, 'Replay', '#other', $variant), 'scheme/host case variation can replay on another channel');
        is(scalar @rendered, 2, 'equivalent scheme and host reuse the selected cache entry');
        is($bot->{out}[-1][0], '#other', 'cache replay keeps the current destination');
        like($bot->{out}[-1][1], qr/^\(Replay\).*Rendered \Q$normalized[0]\E/, 'cache replay keeps the current caller and correct title');
        $display->($bot, undef, 'Repeat', '#TEST', $variant);
        is(scalar @{$bot->{out}}, 3, 'same-channel repeat remains suppressed');
    }
}

{
    my $bot = x_bot_871();
    @rendered = ();
    $handle->($bot, undef, 'First', '#one', 'https://x.com/i/spaces/1AbC123');
    $_->{ts} = time() - 601 for values %{$bot->{_x_twitter_cache}};
    $handle->($bot, undef, 'Refresh', '#two', 'https://x.com/i/spaces/1AbC123');
    is(scalar @rendered, 2, 'expired X metadata is fetched again');
    like($bot->{out}[-1][1], qr/^\(Refresh\).*1AbC123/, 'expiry refresh retains caller and resource');
    is($bot->{out}[-1][0], '#two', 'expiry refresh keeps the current channel');
    $_->{msg} = '' for values %{$bot->{_x_twitter_cache}};
    $handle->($bot, undef, 'Repair', '#three', 'https://x.com/i/spaces/1AbC123');
    is(scalar @rendered, 3, 'legacy cache entry without a message is still refreshed');
    like($bot->{out}[-1][1], qr/^\(Repair\).*1AbC123/, 'legacy refresh is visible');
}
{
    my $bot = x_bot_871();
    @rendered = ();
    $http->{calls} = [];
    ok($display->($bot, undef, 'First', '#one', 'https://x.com/studio/status/123'), 'normal post uses the actual API reader');
    ok($display->($bot, undef, 'Second', '#two', 'HTTPS://X.COM/studio/status/123'), 'matching post replays on another channel');
    is_deeply($http->{calls}, ['https://api.fxtwitter.com/studio/status/123'], 'cached API post avoids redundant HTTP');
    is(scalar @rendered, 0, 'successful API path still avoids Chromium');
    like($bot->{out}[-1][1], qr/^\(Second\).*Studio.*Post .*status\/123.*12 likes.*3 RTs/, 'API cache keeps caller, text and counters');
}
{
    my $bot = x_bot_871();
    local $shell = 1;
    @rendered = ();
    ok($handle->($bot, undef, 'Reader', '#one', 'https://x.com/i/spaces/1AbC123'), 'login shell keeps deterministic fallback');
    like($bot->{out}[-1][1], qr/X link/, 'login shell fallback label remains visible');
    $handle->($bot, undef, 'Replay', '#two', 'HTTPS://X.COM/i/spaces/1AbC123');
    is(scalar @rendered, 1, 'fallback message is reusable from cache');
    like($bot->{out}[-1][1], qr/^\(Replay\).*X link/, 'fallback replay keeps the current caller');
}
{
    my $bot = x_bot_871();
    @rendered = ();
    local $enabled = 0;
    $display->($bot, undef, 'Reader', '#one', 'https://x.com/i/spaces/1AbC123');
    is(scalar @rendered, 0, 'disabled UrlTitle makes no browser request');
    is(scalar keys %{$bot->{_url_display_cache} // {}}, 0, 'disabled feature does not consume admission');
    $enabled = 1;
    ok($display->($bot, undef, 'Reader', '#one', 'https://x.com/i/spaces/1AbC123'), 'enabling admits the previously refused link');
    ok(!defined $handle->($bot, undef, 'Reader', '#one', 'https://x.com.evil.test/i/spaces/1AbC123'), 'lookalike X host remains unsupported');
    is(scalar @rendered, 1, 'unsupported host does not reach the browser');
}
done_testing;
