use strict;
use warnings;
use Test::More;
use Mediabot::Context;
use Mediabot::External ();
use Mediabot::External::YouTube ();

{
    package MB872CacheLog;
    sub log { 1 }
    package MB872CacheConf;
    sub get { undef }
    package MB872CacheHTTP;
    sub get {
        my ($self, $url) = @_;
        push @{$self->{calls}}, $url;
        die 'unexpected offline weather destination' unless $url =~ m{\Ahttps://wttr[.]in/};
        die "offline transport failure\n" if $self->{throws};
        return $self->{response} // {success => 1, status => 200, content => "Weather for $url"};
    }
}
sub cache_bot_872 {
    return {logger => bless({}, 'MB872CacheLog'), conf => bless({}, 'MB872CacheConf'), out => []};
}
sub cache_ctx_872 {
    my ($bot, $city, $channel) = @_;
    return Mediabot::Context->new(bot => $bot, nick => 'Reader', channel => $channel // '#test', args => [$city]);
}
no warnings qw(redefine once);
my $http = bless({calls => []}, 'MB872CacheHTTP');
local *Mediabot::External::_make_http = sub { $http };
local *Mediabot::External::getIdChansetList = sub { 7 };
local *Mediabot::External::getIdChannelSet = sub { 8 };
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1], $_[2]]; 1 };
local *Mediabot::Helpers::logBot = sub { 1 };
my $weather = \&Mediabot::External::displayWeather_ctx;

# All entries are younger than fifteen minutes. Age-only cleanup cannot bound
# this map; successful requests must also evict the oldest excess entries.
{
    my $bot = cache_bot_872();
    my $now = time();
    $bot->{_weather_cache}{sprintf('city%03d', $_)} = {ts => $now - (250 - $_), text => "City $_"} for 1 .. 250;
    ok($weather->(cache_ctx_872($bot, 'Newest')), 'a new successful request is handled');
    is(scalar keys %{$bot->{_weather_cache}}, 200, 'cache is capped even when all previous entries are recent');
    ok(exists $bot->{_weather_cache}{newest}, 'the just-fetched response remains cached');
    ok(!exists $bot->{_weather_cache}{city051}, 'oldest excess entries are removed');
    ok(exists $bot->{_weather_cache}{city052}, 'newest retained boundary survives');
    ok(exists $bot->{_weather_cache}{city250}, 'more recent entries survive');
    is($bot->{_weather_cache}{city250}{text}, 'City 250', 'retained data is not rewritten');
    $weather->(cache_ctx_872($bot, 'Newest', '#other'));
    is(scalar @{$http->{calls}}, 1, 'fresh current location replays without another HTTP request');
    is($bot->{out}[-1][0], '#other', 'bounded cache replay uses the current channel');
}
{
    my $bot = cache_bot_872();
    my $now = time();
    $bot->{_weather_cache}{"expired$_"} = {ts => $now - 901, text => 'Expired'} for 1 .. 20;
    $bot->{_weather_cache}{"recent$_"} = {ts => $now - 300, text => 'Recent'} for 1 .. 190;
    $weather->(cache_ctx_872($bot, 'New'));
    is(scalar keys %{$bot->{_weather_cache}}, 191, 'expired entries are purged before evicting usable entries');
    is(scalar(grep { /^expired/ } keys %{$bot->{_weather_cache}}), 0, 'expired entries are removed');
    is(scalar(grep { /^recent/ } keys %{$bot->{_weather_cache}}), 190, 'usable stale-fallback entries survive when there is room');
}
{
    my $bot = cache_bot_872();
    my $now = time();
    $bot->{_weather_cache}{sprintf('tie%03d', $_)} = {ts => $now, text => 'Same timestamp'} for 1 .. 200;
    $weather->(cache_ctx_872($bot, 'Anew'));
    is(scalar keys %{$bot->{_weather_cache}}, 200, 'equal timestamps still enforce the cap');
    ok(exists $bot->{_weather_cache}{anew}, 'timestamp ties do not evict the just-fetched entry');
    ok(!exists $bot->{_weather_cache}{tie001}, 'timestamp ties use deterministic key order');
    ok(exists $bot->{_weather_cache}{tie002}, 'remaining tied entries survive');
}
{
    my $bot = cache_bot_872();
    $http->{calls} = [];
    my $handled = 0;
    $handled += $weather->(cache_ctx_872($bot, "Location$_")) ? 1 : 0 for 1 .. 205;
    is($handled, 205, 'all distinct requests complete despite eviction');
    is(scalar @{$http->{calls}}, 205, 'each initially absent location receives its own request');
    is(scalar @{$bot->{out}}, 205, 'each request is delivered exactly once');
    is(scalar keys %{$bot->{_weather_cache}}, 200, 'cache remains capped over repeated real writes');
    ok(exists $bot->{_weather_cache}{location205}, 'the final requested location is retained');
}

# Preserve three-minute freshness, fifteen-minute outage fallback and failed
# refresh behavior. Timestamps are seeded; tests never sleep or use live HTTP.
for my $failure (
    {success => 0, status => 503, reason => 'Offline'},
    {success => 1, status => 200, content => 'Unknown location'},
    {success => 1, status => 200, content => 'Service unavailable'},
    {success => 1, status => 200, content => ''},
    'throw',
) {
    my $bot = cache_bot_872();
    my $stamp = time() - 300;
    $bot->{_weather_cache}{paris} = {ts => $stamp, text => 'Paris stale weather'};
    local $http->{response} = ref($failure) ? $failure : undef;
    local $http->{throws} = !ref($failure);
    $http->{calls} = [];
    $weather->(cache_ctx_872($bot, 'Paris', '#fallback'));
    is(scalar @{$http->{calls}}, 1, 'stale entry attempts a provider refresh');
    is($bot->{out}[-1][1], 'Paris stale weather  (cached)', 'failed refresh reuses usable stale data');
    is($bot->{out}[-1][0], '#fallback', 'outage fallback keeps the current destination');
    is_deeply($bot->{_weather_cache}{paris}, {ts => $stamp, text => 'Paris stale weather'}, 'failed refresh does not renew or overwrite old data');
    $bot->{_weather_cache}{paris}{ts} = time() - 901;
    $weather->(cache_ctx_872($bot, 'Paris'));
    unlike($bot->{out}[-1][1], qr/Paris stale weather/, 'expired fallback is never replayed during outage');
}
{
    my $bot = cache_bot_872();
    $bot->{_weather_cache}{paris} = {ts => time() - 120, text => 'Paris fresh weather'};
    $http->{calls} = [];
    $weather->(cache_ctx_872($bot, 'Paris'));
    is(scalar @{$http->{calls}}, 0, 'entry younger than three minutes avoids HTTP');
    is($bot->{out}[-1][1], 'Paris fresh weather', 'fresh reply does not gain a stale marker');
    $bot->{_weather_cache}{paris}{ts} = time() - 300;
    ok($weather->(cache_ctx_872($bot, 'Paris')), 'successful stale refresh remains handled');
    is(scalar @{$http->{calls}}, 1, 'successful stale refresh makes one HTTP request');
    like($bot->{out}[-1][1], qr/Weather for https:\/\/wttr[.]in\/Paris\?/, 'new provider reply replaces stale display');
    like($bot->{_weather_cache}{paris}{text}, qr/Weather for /, 'successful refresh updates cached text');
    cmp_ok($bot->{_weather_cache}{paris}{ts}, '>=', time() - 5, 'successful refresh renews the timestamp');
}
done_testing;
