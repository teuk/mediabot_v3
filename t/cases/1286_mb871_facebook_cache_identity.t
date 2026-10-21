use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::External ();
use Mediabot::External::URL ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

{
    package MB871FacebookLog;
    sub log { 1 }
    package MB871FacebookConf;
    sub get { undef }
    package MB871FacebookHTTP;
    sub get {
        my ($self, $url) = @_;
        push @{$self->{calls}}, $url;
        die 'unexpected offline destination' unless $url =~ m{\Ahttps://www[.]facebook[.]com/}i;
        my $title = $self->{shell} ? 'Facebook' : "Émission $url";
        return {success => 1, status => 200, headers => {'content-type' => 'text/html; charset=utf-8'},
            content => Encode::encode('UTF-8', "<title>$title</title>")};
    }
}

sub facebook_bot_871 {
    return {logger => bless({}, 'MB871FacebookLog'), conf => bless({}, 'MB871FacebookConf'), out => []};
}

no warnings qw(redefine once);
my $http = bless({calls => []}, 'MB871FacebookHTTP');
my @rendered;
our $enabled = 1;
local *Mediabot::External::_make_http = sub { $http };
local *Mediabot::External::_chanset_ok = sub { $enabled };
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1], $_[2]]; 1 };
local *Mediabot::External::URL::_fetch_url_chromium_dumpdom = sub {
    push @rendered, $_[1];
    return "<title>Rendered $_[1]</title>";
};
local *Mediabot::External::URL::_handle_generic_title = sub { die 'Facebook must use its dedicated handler' };
my $display = \&Mediabot::External::URL::displayUrlTitle;
my $handle = \&Mediabot::External::URL::_handle_facebook;

# Exercise the real admission, normalization, HTTP parser, formatting and cache.
for my $pair (
    ['posts/pfbidAbC123', 'posts/pfbidabc123'],
    ['story.php?story_fbid=AbC123', 'story.php?story_fbid=abc123'],
    ['share/AbC123?token=QwE', 'share/AbC123?token=qwe'],
    ['posts/AbC123#Comment', 'posts/AbC123#comment'],
) {
    my $bot = facebook_bot_871();
    $http->{calls} = [];
    my @urls = map { "https://www.facebook.com/$_" } @$pair;
    for my $i (0 .. 1) {
        ok($display->($bot, undef, "Reader$i", '#test', $urls[$i]), "$pair->[$i] is displayed");
        like($bot->{out}[-1][1] // '', qr/Émission \Q$urls[$i]\E/, 'title belongs to the selected resource');
    }
    is_deeply($http->{calls}, \@urls, 'case-distinct resources both reach HTTP with their original spelling');
    is(scalar keys %{$bot->{_facebook_cache}}, 2, 'metadata entries remain independent');
    my $variant = $urls[0];
    $variant =~ s{\Ahttps://www[.]facebook[.]com}{HTTPS://WWW.FACEBOOK.COM};
    ok($display->($bot, undef, 'Replay', '#other', $variant), 'scheme/host case variation can replay on another channel');
    is(scalar @{$http->{calls}}, 2, 'equivalent scheme and host reuse the selected cached metadata');
    is($bot->{out}[-1][0], '#other', 'cache replay keeps the current destination');
    like($bot->{out}[-1][1], qr/^\(Replay\).*Émission \Q$urls[0]\E/, 'cache replay keeps the current caller and correct title');
    $display->($bot, undef, 'Repeat', '#TEST', $variant);
    is(scalar @{$bot->{out}}, 3, 'same-channel repeat remains suppressed');
    is(scalar @{$http->{calls}}, 2, 'same-channel repeat does not fetch');
}

{
    my $bot = facebook_bot_871();
    $http->{calls} = [];
    ok($handle->($bot, undef, 'First', '#one', 'http://facebook.com/posts/pfbidAbC123'), 'existing HTTP/bare-host normalization remains handled');
    ok($handle->($bot, undef, 'Second', '#two', 'https://www.facebook.com/posts/pfbidAbC123'), 'normalized equivalent replays');
    is_deeply($http->{calls}, ['https://www.facebook.com/posts/pfbidAbC123'], 'normalization does not rewrite resource case or refetch');
    like($bot->{out}[-1][1], qr/^\(Second\).*pfbidAbC123/, 'normalized replay retains caller and resource');
    $_->{ts} = time() - 601 for values %{$bot->{_facebook_cache}};
    $handle->($bot, undef, 'Refresh', '#three', 'https://www.facebook.com/posts/pfbidAbC123');
    is(scalar @{$http->{calls}}, 2, 'expired metadata is fetched again');
    is($bot->{out}[-1][0], '#three', 'expiry refresh uses the current channel');
}

{
    my $bot = facebook_bot_871();
    local $http->{shell} = 1;
    $http->{calls} = [];
    @rendered = ();
    for my $id (qw(pfbidAbC123 pfbidabc123)) {
        ok($handle->($bot, undef, 'Reader', '#test', "https://www.facebook.com/posts/$id"), 'non-Reel shell retains Chromium fallback');
        like($bot->{out}[-1][1], qr/Rendered https:\/\/www[.]facebook[.]com\/posts\/\Q$id\E/, 'rendered title belongs to the selected post');
    }
    is(scalar @rendered, 2, 'case-distinct shells each reach the browser fallback');
    $handle->($bot, undef, 'Replay', '#other', 'HTTPS://WWW.FACEBOOK.COM/posts/pfbidAbC123');
    is(scalar @rendered, 2, 'rendered metadata is reused for the matching post');
    $handle->($bot, undef, 'Reel', '#test', 'https://www.facebook.com/reel/123');
    is(scalar @rendered, 2, 'Reel login shell still skips the known-dead browser fallback');
    like($bot->{out}[-1][1], qr/\(Reel\).*Facebook reel/, 'Reel shell retains its deterministic label');
}

{
    my $bot = facebook_bot_871();
    $http->{calls} = [];
    local $enabled = 0;
    $display->($bot, undef, 'Reader', '#test', 'https://facebook.com/posts/pfbidAbC123');
    is(scalar @{$http->{calls}}, 0, 'disabled UrlTitle makes no Facebook request');
    is(scalar keys %{$bot->{_url_display_cache} // {}}, 0, 'disabled feature does not consume admission');
    $enabled = 1;
    ok($display->($bot, undef, 'Reader', '#test', 'https://facebook.com/posts/pfbidAbC123'), 'enabling admits the previously refused post');
    $display->($bot, undef, 'Reader', '#test', 'http://127.0.0.1/posts/pfbidAbC123');
    is(scalar @{$http->{calls}}, 1, 'private literal remains blocked before dispatch');
    ok(!defined $handle->($bot, undef, 'Reader', '#test', 'https://facebook.com.evil.test/posts/pfbidAbC123'), 'lookalike host is refused');
    is(scalar @{$http->{calls}}, 1, 'unsupported host does not reach HTTP');
}
done_testing;
