use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::External;
use Mediabot::External::URL ();

{
    package MB1054::Log; sub log {1}
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
my $wiki='https://fr.wikipedia.org/wiki/Talos_(mythologie)';
my $plain='https://example.org/path?x=1&y=2#part';
my $encoded='https://example.org/%3Cname%3E?quote=%22&literal=%02';
my $unicode='https://example.org/café?ville=Genève';
my @cases=(
    ["<$plain>",$plain,'angle-bracket wrapper'],
    ["voir <$plain>suite",$plain,'adjacent text after closing angle'],
    ['<a href="'.$plain.'">listen</a>',$plain,'copied double-quoted href'],
    [$plain.'"suite',$plain,'adjacent text after a double quote'],
    ["\x02$plain\x02",$plain,'terminal bold'],
    ["$plain.\x0f",$plain,'reset after sentence punctuation'],
    ["(\x02$plain\x0f).",$plain,'reset before wrapper punctuation'],
    ["$plain\x0304,01",$plain,'terminal numeric colour'],
    ["$plain\x04A1B2C3,123ABC",$plain,'terminal hexadecimal colour'],
    ["<$wiki>,",$wiki,'balanced Wikipedia parentheses inside an angle wrapper'],
    ["'$plain)'",$plain,'quoted unbalanced closing parenthesis'],
    ["<$encoded>",$encoded,'percent-encoded delimiters and controls remain byte-identical'],
    ['https://[2001:db8::1]/a?x=[1]','https://[2001:db8::1]/a?x=[1]','balanced IPv6/query brackets'],
    ['<https://first.example/a><https://second.example/b>','https://first.example/a','first adjacent bracketed URL wins'],
    [$unicode,$unicode,'ordinary Unicode URL'],
    [encode('UTF-8',$unicode),encode('UTF-8',$unicode),'ordinary raw UTF-8 URL'],
    ["https://exam\x02ple.org/path","https://exam\x02ple.org/path",'internal controls are not rewritten into another destination'],
    ['see HTTPS://example.org/path,','HTTPS://example.org/path','scheme spelling and ordinary punctuation stay intact'],
    ['there is no URL',undef,'no URL'],
    [undef,undef,'undefined input'],
);
for my $case (@cases) {
    is(Mediabot::External::URL::_extract_url($case->[0]),$case->[1],$case->[2]);
}
is(Mediabot::External::_extract_url("<$plain>"),$plain,'the historical External facade uses the same extractor');

my (@calls,@gates);
no warnings qw(redefine once);
local *Mediabot::External::URL::_url_display_cache_gate=sub {1};
local *Mediabot::External::_chanset_ok=sub {push @gates,$_[2];$_[0]{enabled}};
local *Mediabot::External::MixCloud::enabled=sub {push @gates,'MixCloud';$_[0]{enabled}};
local *Mediabot::External::URL::_handle_generic_title=sub {push @calls,['generic',$_[4]];1};
local *Mediabot::External::MixCloud::handle=sub {
    my $info=Mediabot::External::MixCloud::link_info($_[4]);
    push @calls,['mixcloud',$info ? $info->{url}:undef,$_[4]];1;
};
local *Mediabot::External::displayYoutubeDetails=sub {push @calls,['youtube',$_[4]];1};
my $bot=bless {enabled=>1,logger=>bless({},'MB1054::Log')},'MB1054::Bot';
for my $case (
    ['generic',$plain,['generic',$plain]],
    ['mixcloud','https://www.mixcloud.com/leekid/shut-up-and-dance/',
        ['mixcloud','https://www.mixcloud.com/leekid/shut-up-and-dance/','https://www.mixcloud.com/leekid/shut-up-and-dance/']],
    ['mixcloud','https://www.mixcloud.com/leekid/',
        ['mixcloud','https://www.mixcloud.com/leekid/','https://www.mixcloud.com/leekid/']],
    ['youtube','https://www.youtube.com/watch?v=AbCdEfGh123',
        ['youtube','https://www.youtube.com/watch?v=AbCdEfGh123']]) {
    @calls=();@gates=();
    Mediabot::External::displayUrlTitle($bot,undef,'Operator','#test',"\x02<$case->[1]>\x0f");
    is_deeply(\@calls,[$case->[2]],"native $case->[0] routing receives only the extracted destination");
}
$bot->{enabled}=0;
for my $case (
    [$plain,'UrlTitle'],['https://www.mixcloud.com/leekid/','MixCloud'],
    ['https://www.youtube.com/watch?v=AbCdEfGh123','Youtube']) {
    @calls=();@gates=();
    Mediabot::External::displayUrlTitle($bot,undef,'Operator','#test',"<$case->[0]>");
    is_deeply([\@calls,\@gates],[[],[$case->[1]]],"disabled $case->[1] remains authoritative for a wrapped URL");
}
$bot->{enabled}=1;@calls=();@gates=();
Mediabot::External::displayUrlTitle($bot,undef,'Operator','#test','<http://127.0.0.1/private>');
is_deeply([\@calls,\@gates],[[],[]],'the existing private-literal guard still runs before any provider gate');
is_deeply(\@warnings,[],'native extraction and routing remain warning-free');
done_testing;
