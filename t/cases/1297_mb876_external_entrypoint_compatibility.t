use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Mediabot::Context;
use Mediabot::Mediabot;
use Mediabot::External ();
use MB875FortniteFixture qw(run_fortnite healthy_fortnite);

my @game = (
    ['owner', \&Mediabot::External::Fortnite::fortniteStats_ctx],
    ['facade', \&Mediabot::External::fortniteStats_ctx],
    ['legacy', \&Mediabot::External::YouTube::fortniteStats_ctx],
    ['builtin', undef],
);
for my $kind (qw(healthy bad_status bad_leaves api_error)) {
    my $doc = healthy_fortnite();
    $doc->{status} = '200oops' if $kind eq 'bad_status';
    if ($kind eq 'bad_leaves') {
        $doc->{data}{account}{name} = [];
        $doc->{data}{stats}{all}{overall}{kd} = {};
        $doc->{data}{battlePass}{progress} = JSON::PP::true;
    }
    $doc = {status => 403, error => []} if $kind eq 'api_error';
    my $expected;
    for my $entry (@game) {
        my ($label, $handler) = @$entry;
        my $r = run_fortnite($doc, handler => $handler, channel => '#test');
        ok($r->{ok}, "$kind/$label: real handler and account queries execute") or diag($r->{error});
        is_deeply($r->{warnings}, [], "$kind/$label: no import or coercion warnings");
        my $actual = [$r->{result}, $r->{bot}{out}, $r->{bot}{notices}, $r->{bot}{audit}, $r->{calls}, $r->{options}];
        if (defined $expected) {
            is_deeply($actual, $expected, "$kind/$label: output, routing, audit, return and HTTP equal the owner");
        } else {
            $expected = $actual;
            is(scalar @{$r->{calls}}, 1, "$kind/$label: one existing API request");
        }
    }
}

{ package MB876WeatherConf; sub get {undef} }
{ package MB876WeatherLog; sub log {1} }
{ package MB876WeatherHTTP;
  sub get {
      my ($self, $url) = @_;
      push @{$self->{calls}}, $url;
      die 'unexpected fixture URL' unless $url =~ m{\Ahttps://wttr[.]in/Gen%C3%A8ve\?};
      return $self->{response};
  } }
my $http = bless({calls => [], response => {success => 1, status => 200, content => 'Genève: 18°C'}}, 'MB876WeatherHTTP');
my $bot = {conf => bless({}, 'MB876WeatherConf'), logger => bless({}, 'MB876WeatherLog'), out => [], notices => []};
my %builtin = Mediabot::_builtin_public_command_handlers();
my @weather = (
    ['owner', \&Mediabot::External::Weather::displayWeather_ctx],
    ['facade', \&Mediabot::External::displayWeather_ctx],
    ['legacy', \&Mediabot::External::YouTube::displayWeather_ctx],
    ['weather', $builtin{weather}], ['meteo', $builtin{meteo}],
);
no warnings qw(redefine once);
local *Mediabot::External::_make_http = sub {$http};
local *Mediabot::External::getIdChansetList = sub {7};
local *Mediabot::External::getIdChannelSet = sub {8};
local *Mediabot::Helpers::botPrivmsg = sub {push @{$_[0]{out}}, [$_[1], $_[2]]; 1};
local *Mediabot::Helpers::botNotice = sub {push @{$_[0]{notices}}, [$_[1], $_[2]]; 1};
local *Mediabot::Helpers::logBot = sub {1};
for my $entry (@weather) {
    my ($label, $handler) = @$entry;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Reader', channel => "#test-$label", args => ['Genève']);
    ok($handler->($ctx), "$label: weather works through every supported entry");
    is_deeply($bot->{out}[-1], ["#test-$label", 'Genève: 18°C'], "$label: cached data retains UTF-8 text and current target");
    is(scalar @{$http->{calls}}, 1, "$label: every entry shares the original bot cache");
}
my $stamp = time() - 300;
$bot->{_weather_cache}{lc 'Genève'}{ts} = $stamp;
$http->{response} = {success => 0, status => 503};
for my $entry (@weather) {
    my ($label, $handler) = @$entry;
    my $ctx = Mediabot::Context->new(bot => $bot, nick => 'Reader', channel => '#outage', args => ['Genève']);
    $handler->($ctx);
    is_deeply($bot->{out}[-1], ['#outage', 'Genève: 18°C  (cached)'], "$label: outage reuses the same stale response");
    is($bot->{_weather_cache}{lc 'Genève'}{ts}, $stamp, "$label: failed refresh never renews stale data");
}
is(scalar @{$http->{calls}}, 6, 'each stale entry performs its one existing refresh attempt');
done_testing;
