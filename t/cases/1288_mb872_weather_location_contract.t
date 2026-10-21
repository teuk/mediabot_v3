use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::Context;
use Mediabot::External ();
use Mediabot::External::YouTube ();
use Mediabot::UserCommands ();

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

{
    package MB872LocationLog;
    sub log { 1 }
    package MB872LocationConf;
    sub get { $_[1] eq 'main.MAIN_PROG_URL' ? 'https://project.example.test/' : undef }
    package MB872LocationHTTP;
    sub get {
        my ($self, $url, $options) = @_;
        push @{$self->{calls}}, [$url, $options];
        die 'unexpected offline weather destination' unless $url =~ m{\Ahttps://wttr[.]in/};
        return {success => 1, status => 200, content => "Weather for $url"};
    }
}

sub location_bot_872 {
    return {logger => bless({}, 'MB872LocationLog'), conf => bless({}, 'MB872LocationConf'), out => [], notices => [], audit => []};
}
sub location_ctx_872 {
    my ($bot, $args, $channel) = @_;
    return Mediabot::Context->new(bot => $bot, nick => 'Reader', channel => $channel,
        command => 'weather', args => $args, message => 'offline message');
}

no warnings qw(redefine once);
my $http = bless({calls => []}, 'MB872LocationHTTP');
my @clients;
our $enabled = 1;
local *Mediabot::External::_make_http = sub { push @clients, {@_}; $http };
local *Mediabot::External::getIdChansetList = sub { 7 };
local *Mediabot::External::getIdChannelSet = sub { $enabled ? 8 : undef };
local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1], $_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = \&Mediabot::Helpers::botPrivmsg;
local *Mediabot::Helpers::botNotice = sub { push @{$_[0]{notices}}, [$_[1], $_[2]]; 1 };
local *Mediabot::Helpers::logBot = sub { push @{$_[0]{audit}}, [@_[2 .. $#_]]; 1 };
my $weather = \&Mediabot::External::displayWeather_ctx;

for my $row (
    [[qw(New York)], 'New%20York', 'New York'],
    [[qw(Los Angeles)], 'Los%20Angeles', 'Los Angeles'],
    [[qw(Salt Lake City)], 'Salt%20Lake%20City', 'Salt Lake City'],
    [[qw(Rio de Janeiro)], 'Rio%20de%20Janeiro', 'Rio de Janeiro'],
    [[qw(Le Havre)], 'Le%20Havre', 'Le Havre'],
    [[qw(Paris FR)], 'Paris%2CFR', 'Paris,FR'],
    [[qw(New York US)], 'New%20York%2CUS', 'New York,US'],
    [['New York,US'], 'New%20York%2CUS', 'New York,US'],
    [['New,York'], 'New%2CYork', 'New,York'],
    [['-33.8688,151.2093'], '-33.8688%2C151.2093', '-33.8688,151.2093'],
    [['Genève'], 'Gen%C3%A8ve', 'Genève'],
    [[encode('UTF-8', 'Genève')], 'Gen%C3%A8ve', encode('UTF-8', 'Genève')],
    [[qw(São Paulo)], 'S%C3%A3o%20Paulo', 'São Paulo'],
    [[encode('UTF-8', 'São'), 'Paulo'], 'S%C3%A3o%20Paulo', encode('UTF-8', 'São Paulo')],
) {
    my ($args, $encoded, $location) = @$row;
    my $bot = location_bot_872();
    $http->{calls} = [];
    ok($weather->(location_ctx_872($bot, $args, '#test')), "weather handles $encoded");
    is(scalar @{$http->{calls}}, 1, 'one request for an uncached location');
    like($http->{calls}[0][0], qr{\Ahttps://wttr[.]in/\Q$encoded\E\?format=}, 'request preserves the city name before byte-safe URL encoding');
    like($bot->{out}[-1][1], qr{Weather for https://wttr[.]in/\Q$encoded\E\?}, 'displayed response belongs to that exact query');
    is($bot->{out}[-1][0], '#test', 'response uses the current channel');
    ok(exists $bot->{_weather_cache}{lc $location}, 'metadata cache uses the actual normalized location');
    is($bot->{audit}[-1][-1], $location, 'audit records the actual location');
}

is($clients[0]{timeout}, 4, 'individual weather HTTP timeout remains four seconds');
is($clients[0]{verify_SSL}, 1, 'TLS verification remains enabled');
like($clients[0]{agent}, qr{\Qhttps://project.example.test/\E}, 'User-Agent keeps the configured project URL');
like($http->{calls}[0][0], qr/%F0%9F%92%A7/, 'format emoji is encoded once');
like($http->{calls}[0][0], qr/&m\z/, 'metric units are retained');
is($http->{calls}[0][1]{headers}{Accept}, 'text/plain', 'request keeps the plain-text response preference');
like($http->{calls}[0][1]{headers}{'Accept-Language'}, qr/\Afr-FR,/, 'language preference remains French first');

{
    my $bot = location_bot_872();
    $http->{calls} = [];
    $weather->(location_ctx_872($bot, [qw(New York)], '#one'));
    $weather->(location_ctx_872($bot, [qw(new york)], '#two'));
    is(scalar @{$http->{calls}}, 1, 'same city with different letter case reuses fresh data');
    is($bot->{out}[-1][0], '#two', 'fresh replay uses the current destination');
    like($bot->{out}[-1][1], qr{/New%20York\?}, 'fresh replay retains the selected city response');
    $weather->(location_ctx_872($bot, ['New,York'], '#three'));
    is(scalar @{$http->{calls}}, 2, 'a literal comma-qualified query remains a distinct location');
    $weather->(location_ctx_872($bot, ['Paris'], '#one'));
    Mediabot::UserCommands::mbWeatherCompare_ctx(location_ctx_872($bot, ['New York', 'Paris'], '#compare'));
    like($bot->{out}[-1][1], qr{/New%20York\?.*\|\|.*?/Paris\?}, 'existing comparison can find the fetched multiword city');
    is($bot->{out}[-1][0], '#compare', 'comparison retains its destination');
    is(scalar @{$http->{calls}}, 3, 'comparison does not launch an extra request');
}
{
    my $bot = location_bot_872();
    $http->{calls} = [];
    $weather->(location_ctx_872($bot, [], '#test'));
    $weather->(location_ctx_872($bot, [qw(New York)], undef));
    is(scalar @{$http->{calls}}, 0, 'missing arguments and private usage do not fetch');
    is(scalar @{$bot->{notices}}, 2, 'syntax errors remain private notices');
    local $enabled = 0;
    $weather->(location_ctx_872($bot, [qw(New York)], '#test'));
    is(scalar @{$http->{calls}}, 0, 'disabled Weather chanset makes no request');
    is(scalar keys %{$bot->{_weather_cache} // {}}, 0, 'disabled Weather chanset does not fill the cache');
    $enabled = 1;
    ok($weather->(location_ctx_872($bot, [qw(New York)], '#test')), 'enabling permits the previously refused location');
}
done_testing;
