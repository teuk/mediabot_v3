use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Encode qw(encode);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::External ();
use Mediabot::External::Horoscope ();
use MB840AsyncFixture qw(fixture pump record_output);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

{
    package MB874SignConf;
    sub get { $_[0]{$_[1]} }
    package MB874SignLog;
    sub log { push @{$_[0]{lines}}, $_[2]; 1 }
    package MB874SignHTTP;
    sub get {
        my ($self, $url) = @_;
        die 'unexpected offline horoscope destination' unless $url =~ m{\Ahttps://(?:primary|mirror)[.]example[.]test/};
        push @{$self->{calls}}, $url;
        return shift @{$self->{responses}} // {success => 0, status => 503};
    }
}
my $json = JSON::PP->new->utf8;
my $response = sub { {success => 1, status => 200, content => $json->encode($_[0])} };
my $bot = {conf => bless({}, 'MB874SignConf'), logger => bless({lines => []}, 'MB874SignLog')};
my $http = bless({calls => [], responses => []}, 'MB874SignHTTP');
my @options;
no warnings qw(redefine once);
local @Mediabot::External::Horoscope::PROVIDERS = (
    'https://primary.example.test/daily?sign=%s', 'https://mirror.example.test/daily?sign=%s');
local *Mediabot::External::_make_http = sub { push @options, {@_}; $http };
my $fetch = \&Mediabot::External::Horoscope::fetch_daily;

for my $nested (0, 1) {
    for my $bad ([], {}, JSON::PP::true, JSON::PP::false) {
        my $node = {sign => $bad, horoscope => 'Unverified provider forecast.'};
        my $doc = $nested ? {data => $node} : $node;
        $http->{calls} = [];
        $http->{responses} = [$response->($doc), $response->({data => {sign => 'Leo', horoscope_data => 'Verified Leo forecast.'}})];
        is($fetch->($bot, 'leo'), 'Verified Leo forecast.', 'non-scalar declared sign cannot supply the requested forecast');
        is(scalar @{$http->{calls}}, 2, 'malformed sign allows the existing mirror attempt');
        like($http->{calls}[1] // '', qr{mirror[.]example[.]test/daily\?sign=leo\z}, 'mirror receives the same requested sign');
        $http->{responses} = [$response->($doc), $response->($doc)];
        ok(!defined $fetch->($bot, 'leo'), 'two malformed identities return the local fallback signal');
    }
}
unlike(join("\n", @{$bot->{logger}{lines}}), qr/ARRAY\(|HASH\(|JSON::PP::Boolean=/, 'diagnostics do not stringify malformed sign containers');

for my $sign ('Leo', 'lion', 'LEO', '♌', undef) {
    $http->{calls} = [];
    $http->{responses} = [$response->({data => {sign => $sign, horoscope => 'Correct forecast.'}})];
    is($fetch->($bot, 'leo'), 'Correct forecast.', 'valid aliases and the existing optional/null sign remain supported');
    is(scalar @{$http->{calls}}, 1, 'usable primary response does not need a mirror');
}
$http->{responses} = [$response->({description => 'Flat forecast without a sign field.'})];
is($fetch->($bot, 'leo'), 'Flat forecast without a sign field.', 'supported flat response without a sign remains usable');
$http->{calls} = [];
$http->{responses} = [$response->({data => {sign => 'Virgo', horoscope => 'Wrong sign.'}}),
    $response->({data => {sign => 'Leo', horoscope => 'Correct mirror.'}})];
is($fetch->($bot, 'leo'), 'Correct mirror.', 'ordinary wrong scalar sign still allows mirror recovery');
is(scalar @{$http->{calls}}, 2, 'wrong scalar identity does not shorten the provider plan');

$bot->{conf}{'horoscope.API_URL'} = 'https://primary.example.test/custom?sign=%s';
$http->{calls} = [];
$http->{responses} = [$response->({sign => [], horoscope => 'Unverified custom forecast.'})];
ok(!defined $fetch->($bot, 'leo'), 'malformed identity on configured single provider returns fallback');
is(scalar @{$http->{calls}}, 1, 'explicit provider URL does not introduce another provider');
delete $bot->{conf}{'horoscope.API_URL'};
is($options[0]{timeout}, 6, 'default provider timeout remains six seconds');
is($options[0]{max_size}, 256 * 1024, 'provider body bound remains unchanged');
is($options[0]{verify_SSL}, 1, 'TLS verification remains enabled');
is($options[0]{max_redirect}, 0, 'provider redirects remain disabled');

# Both public aliases cross the real command worker. No API, IRC or database
# is contacted; the existing fixture supplies the isolated worker DB boundary.
local *Mediabot::Helpers::chanset_enabled = sub {1};
local *Mediabot::Helpers::channel_lang = sub {'en'};
local *Mediabot::Helpers::botPrivmsg = \&record_output;
local *Mediabot::Helpers::botNotice = \&record_output;
local *Mediabot::UserCommands::botPrivmsg = \&record_output;
local *Mediabot::UserCommands::botNotice = \&record_output;
my %handlers = Mediabot::_builtin_public_command_handlers();
for my $alias (qw(horoscope horo)) {
    for my $recover (0, 1) {
        my ($native, undef, $loop) = fixture();
        $native->{conf} = bless({'main.LANG' => 'en'}, 'MB874SignConf');
        $http->{calls} = [];
        $http->{responses} = [
            $response->({data => {sign => ['Virgo'], horoscope => 'Unverified provider forecast.'}}),
            $recover ? $response->({data => {sign => 'Leo', horoscope => 'Verified mirror forecast.'}})
                : $response->({data => {sign => {}, horoscope => 'Unverified mirror forecast.'}}),
        ];
        my $ctx = Mediabot::Context->new(bot => $native, nick => 'Reader', channel => '#test', command => $alias, args => ['lion']);
        ok($handlers{$alias}->($ctx), "$alias starts with the existing worker path");
        ok(pump($loop, sub {!keys %{$native->{_cmd_async_jobs}}}, 5), "$alias real worker completes");
        is($native->{_cmd_async_stats}{spawned} // 0, 1, "$alias uses a native fork worker");
        is(scalar @{$native->{out}}, 2, "$alias retains two compact reply lines");
        my $first = $native->{out}[0][1] // '';
        like($first, qr/♌ \x02Leo\x02/, "$alias reply still identifies the requested Leo sign");
        unlike($first, qr/Unverified/, "$alias never publishes a forecast with an unverifiable declared sign");
        if ($recover) {
            like($first, qr/Verified mirror forecast[.]/, "$alias displays the usable mirror forecast");
        }
        else {
            my $date = $first =~ /(\d{4}-\d{2}-\d{2})/ ? $1 : '';
            my $local = Mediabot::External::Horoscope::local_forecast('leo', $date, 'en') // '<missing>';
            like($first, qr/\Q$local\E/, "$alias uses the normal deterministic local fallback");
        }
        ok(!grep({$_->[0] ne '#test'} @{$native->{out}}), "$alias replies retain the requesting channel");
        ok(!grep({length(encode('UTF-8', $_->[1])) > 400} @{$native->{out}}), "$alias payloads retain the UTF-8 byte bound");
    }
}
done_testing;
