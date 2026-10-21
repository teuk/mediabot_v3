use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use Mediabot::External ();
use Mediabot::External::URL ();

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
