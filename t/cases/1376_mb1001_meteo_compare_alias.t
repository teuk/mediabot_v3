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
    package MB1001::HTTP;
    sub get {
        my ($self,$url) = @_;
        die "unexpected offline weather destination\n" unless $url =~ m{\Ahttps://wttr[.]in/([^?]+)\?};
        push @{$self->{calls}},$url;
        return {success=>1,status=>200,content=>"$1 weather #".scalar(@{$self->{calls}})};
    }
    package MB1001::Conf;
    sub get { $_[1] eq 'main.MAIN_PROG_URL' ? 'https://project.example.invalid/' : undef }
    package MB1001::Log; sub log {1}
}
my ($http,$weather_enabled,@wire,@audit,@warnings);
local $SIG{__WARN__} = sub { push @warnings,@_ };
no warnings qw(redefine once);
local *Mediabot::External::_make_http = sub {$http};
local *Mediabot::External::getIdChansetList = sub {7};
local *Mediabot::External::getIdChannelSet = sub {$weather_enabled ? 8 : undef};
local *Mediabot::Helpers::botPrivmsg = sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg = \&Mediabot::Helpers::botPrivmsg;
local *Mediabot::Helpers::botNotice = sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice = \&Mediabot::Helpers::botNotice;
local *Mediabot::Helpers::logBot = sub {push @audit,[@_[2..$#_]];1};
sub invoke_1376 {
    my ($bot,$command,$args,$channel) = @_;
    @wire=(); @audit=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
        command=>$command,args=>$args);
    $bot->command_registry->handler_for($command,'public')->($ctx);
    return dclone(\@wire);
}
sub setup_1376 {
    $NOW=1_000_000; $weather_enabled=1;
    $http=bless {calls=>[]},'MB1001::HTTP';
    my $bot=Mediabot->new({});
    $bot->{conf}=bless {},'MB1001::Conf'; $bot->{logger}=bless {},'MB1001::Log';
    invoke_1376($bot,'weather',['Paris'],'#seed');
    invoke_1376($bot,'meteo',['Lyon'],'#seed');
    return $bot;
}
{
    my $bot=setup_1376();
    is_deeply([\@wire,\@audit,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['public','#seed','Lyon weather #2']],[['#seed','weather','Lyon']],2,
         {paris=>{ts=>$NOW,text=>'Paris weather #1'},lyon=>{ts=>$NOW,text=>'Lyon weather #2'}}],
        'ordinary weather and meteo still populate the same real weather cache');
}
{
    my $bot=setup_1376(); my $before=dclone($bot->{_weather_cache});
    my $wire=invoke_1376($bot,'meteo',[qw(compare Paris Lyon)],'#test');
    is_deeply([$wire,\@audit,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['public','#test','Paris weather #1  ||  Lyon weather #2']],[],2,$before],
        'meteo comparison reads both cached cities without HTTP, cache changes or fetch audit');
}
{
    my $bot=setup_1376(); my $before=dclone($bot->{_weather_cache}); $NOW+=900;
    my $wire=invoke_1376($bot,'meteo',[qw(CoMpArE pArIs LYON)],'#other');
    is_deeply([$wire,\@audit,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['public','#other','Paris weather #1  ||  Lyon weather #2']],[],2,$before],
        'alias preserves case-insensitive dispatch, destination and inclusive fifteen-minute comparison limit');
}
{
    my $bot=setup_1376(); my $before=dclone($bot->{_weather_cache}); my @actual;
    for my $args (['compare'],['compare','Paris']) {
        push @actual,[invoke_1376($bot,'meteo',$args,'#test'),dclone(\@audit),
            scalar(@{$http->{calls}}),dclone($bot->{_weather_cache})];
    }
    is_deeply(\@actual,[map { [[['notice','Reader','Syntax: weather compare <city1> <city2>']],[],2,$before] } 1..2],
        'missing comparison cities use the existing private syntax notice without fetching a fictitious location');
}
{
    my (@actual,@expected);
    for my $entry ({ts=>999_099,text=>'Expired'},{ts=>1_000_001,text=>'Future'},
                   {text=>'Undated'},{ts=>1_000_000,text=>''}) {
        my $bot=setup_1376(); $bot->{_weather_cache}{paris}=$entry;
        my $before=dclone($bot->{_weather_cache});
        push @actual,[invoke_1376($bot,'meteo',[qw(compare Paris Lyon)],'#test'),
            dclone(\@audit),scalar(@{$http->{calls}}),dclone($bot->{_weather_cache})];
        push @expected,[[['public','#test','Paris: no cached data (use !weather Paris first)  ||  Lyon weather #2']],[],2,$before];
    }
    is_deeply(\@actual,\@expected,'alias retains invalid/expired cache rejection and never turns comparison into a refresh');
}
{
    my $bot=setup_1376(); my $before=dclone($bot->{_weather_cache});
    my $wire=invoke_1376($bot,'meteo',['Paris'],'#test');
    is_deeply([$wire,\@audit,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[['public','#test','Paris weather #1']],[],2,$before],
        'ordinary alias requests still reuse fresh cached weather');
}
{
    my $bot=setup_1376(); my $args=['New','York'];
    my $wire=invoke_1376($bot,'meteo',$args,'#test');
    is_deeply([$wire,\@audit,$args,scalar(@{$http->{calls}}),$http->{calls}[-1]=~m{\Ahttps://wttr[.]in/New%20York\?} ? 1 : 0],
        [[['public','#test','New%20York weather #3']],[['#test','weather','New York']],['New','York'],3,1],
        'ordinary multiword city input keeps its HTTP encoding, original arguments, routing and fetch audit');
}
{
    my $bot=setup_1376(); my $before=dclone($bot->{_weather_cache}); my @actual;
    $weather_enabled=0;
    push @actual,invoke_1376($bot,'meteo',['Paris'],'#test');
    $weather_enabled=1;
    push @actual,invoke_1376($bot,'meteo',['Paris'],undef);
    push @actual,invoke_1376($bot,'meteo',[],'#test');
    is_deeply([\@actual,scalar(@{$http->{calls}}),$bot->{_weather_cache}],
        [[[],[['notice','Reader','Syntax (in channel): weather <City|City,CC|lat,lon>']],
              [['notice','Reader','Syntax (no accents): weather <City|City,CC|lat,lon>']]],2,$before],
        'ordinary alias keeps the Weather gate, private-channel refusal and empty-city syntax');
}
is_deeply(\@warnings,[],'meteo alias emits no warnings');
done_testing;
