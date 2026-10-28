use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
our $NOW;
BEGIN { $NOW = 1_000_000; *CORE::GLOBAL::time = sub () { $NOW } }
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::External ();
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB998::HTTP;
    sub get {
        my ($self,$url) = @_;
        die "unexpected offline weather destination\n" unless $url =~ m{\Ahttps://wttr[.]in/([^?]+)\?};
        push @{$self->{calls}}, $url;
        return {success=>1,status=>200,content=>"$1 weather #" . scalar(@{$self->{calls}})};
    }
    package MB998::Conf;
    sub get { $_[1] eq 'main.MAIN_PROG_URL' ? 'https://project.example.invalid/' : undef }
    package MB998::Log;
    sub log {1}
}
my (@wire,@warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
my $http = bless {calls=>[]}, 'MB998::HTTP';
local *Mediabot::External::_make_http = sub { $http };
local *Mediabot::External::getIdChansetList = sub {7};
local *Mediabot::External::getIdChannelSet = sub {8};
local *Mediabot::Helpers::botPrivmsg = sub { push @wire, ['public',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botPrivmsg = \&Mediabot::Helpers::botPrivmsg;
local *Mediabot::Helpers::botNotice = sub { push @wire, ['notice',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botNotice = \&Mediabot::Helpers::botNotice;
local *Mediabot::Helpers::logBot = sub {1};
my $bot = Mediabot->new({});
$bot->{conf} = bless {}, 'MB998::Conf';
$bot->{logger} = bless {}, 'MB998::Log';
sub weather_1373 {
    my ($args,$channel) = @_;
    @wire = ();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
        command=>'weather',args=>$args);
    $bot->command_registry->handler_for('weather','public')->($ctx);
    return dclone(\@wire);
}
sub compare_1373 {
    my ($text,$calls,$label,$cities,$channel) = @_;
    $cities //= ['Paris','Lyon']; $channel //= '#test';
    my $before = dclone($bot->{_weather_cache});
    my $wire = weather_1373(['compare',@$cities],$channel);
    is_deeply([$wire,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['public',$channel,$text]],$calls,$before], $label);
}
weather_1373(['Paris'],'#seed');
weather_1373(['Lyon'],'#seed');
compare_1373('Paris weather #1  ||  Lyon weather #2',2,
    'real fetched cache is compared without HTTP or cache changes');
$NOW += 900;
compare_1373('Paris weather #1  ||  Lyon weather #2',2,
    'the existing fifteen-minute maximum remains inclusive');
$NOW++;
my $paris_missing = 'Paris: no cached data (use !weather Paris first)';
my $lyon_missing = 'Lyon: no cached data (use !weather Lyon first)';
compare_1373("$paris_missing  ||  $lyon_missing",2,
    'data older than fifteen minutes is refused instead of shown indefinitely');
weather_1373(['Lyon'],'#seed');
compare_1373("$paris_missing  ||  Lyon weather #3",3,
    'each city is checked separately when only one cached result has expired');
$bot->{_weather_cache}{paris} = {ts=>$NOW+1,text=>'Future data'};
compare_1373("$paris_missing  ||  Lyon weather #3",3,
    'a future timestamp cannot make an invalid entry appear fresh');
$bot->{_weather_cache}{paris} = {text=>'Undated data'};
compare_1373("$paris_missing  ||  Lyon weather #3",3,
    'an undated entry is not treated as confirmed recent data');
delete $bot->{_weather_cache}{paris};
compare_1373("$paris_missing  ||  Lyon weather #3",3,
    'an absent city retains the established no-cache response');
$bot->{_weather_cache}{paris} = {ts=>$NOW,text=>''};
compare_1373("$paris_missing  ||  Lyon weather #3",3,
    'empty cached text still follows the no-data branch');
{
    my $before = dclone($bot->{_weather_cache});
    my $wire = weather_1373(['compare','Paris'],'#test');
    is_deeply([$wire,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['notice','Reader','Syntax: weather compare <city1> <city2>']],3,$before],
        'insufficient comparison arguments retain private syntax feedback and do not fetch');
}
weather_1373(['Paris'],'#seed');
compare_1373('Paris weather #4  ||  Lyon weather #3',4,
    'normal weather refresh restores comparison and preserves case-insensitive keys and destination',
    ['pArIs','LYON'],'#other');
is_deeply(\@warnings, [], 'cache-age comparison emits no warnings');
done_testing;
