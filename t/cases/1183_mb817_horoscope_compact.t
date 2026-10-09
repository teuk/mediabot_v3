use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode decode);
use JSON::PP ();
use Mediabot::External::Horoscope;
use Mediabot::UserCommands;
use Mediabot::Helpers;
use Mediabot::AI::Client;
use Mediabot::CommandAsync;
{
    package MB817::Conf;
    sub new {bless {values=>$_[1] || {}}, $_[0]}
    sub get {$_[0]{values}{$_[1]}}
    package MB817::Log;
    sub log {push @{$_[0]{lines}}, $_[2]; 1}
    package MB817::DB;
    sub prepare {push @{$_[0]{queries}}, $_[1]; bless {db=>$_[0]}, 'MB817::Statement'}
    package MB817::Statement;
    sub execute {$_[0]{nick}=$_[1]; 1}
    sub fetchrow_hashref {my $s=shift; +{birthday=>$s->{db}{birthdays}{$s->{nick}}}}
    sub finish {1}
    package MB817::Ctx;
    sub bot {$_[0]{bot}} sub nick {$_[0]{nick}} sub channel {$_[0]{channel}} sub args {$_[0]{args}}
    package MB817::HTTP;
    sub get {push @{$_[0]{gets}}, $_[1]; shift @{$_[0]{responses}} || {success=>0,status=>503}}
    sub request {push @{$_[0]{requests}}, [@_[1..3]]; shift @{$_[0]{responses}} || {success=>0,status=>503}}
}
my $H='Mediabot::External::Horoscope';
my $original_daily = \&Mediabot::External::Horoscope::daily_line;
my @signs=Mediabot::External::Horoscope::all_slugs();
my $date='2026-10-08';
for my $lang (qw(fr en)) {
    my %unique;
    for my $slug (@signs) {
        my $line=$H->can('local_forecast')->($slug,$date,$lang);
        ok(defined($line) && length($line)>25, "$lang $slug has a substantive local forecast");
        $unique{$line}++;
        is($line,$H->can('local_forecast')->($slug,$date,$lang), 'same sign/date is stable');
    }
    is(scalar keys %unique,12,"$lang: twelve signs have different cards, not four repeated element slogans");
}
my %days=map {$H->can('local_forecast')->('leo',sprintf('2026-10-%02d',$_),'fr')=>1} 1..28;
ok(keys(%days)>1,'local forecast changes across days');
ok(!defined $H->can('local_forecast')->('not-a-sign',$date,'fr'),'unknown sign never gains an invented prediction');
my $family="👩‍👩‍👧‍👦";
is($H->can('clean_text')->($family),$family,'emoji joiners are preserved');
is($H->can('cap_text')->($family x 3,30),$family.'…','trimming keeps whole emoji grapheme clusters');
my $long=('Une idée éclaire votre journée. ' x 60);
my $lines=$H->can('compact_lines')->(lang=>'fr', target=>'Émilie',date=>$date,
    sign=>'Bélier',glyph=>'♈',forecast=>$long,number=>42,colour=>'émeraude',luck=>80,companion=>'Poissons');
is(@$lines,2,'long forecast remains exactly two IRC payloads');
for my $line (@$lines) {
    ok(length(encode('UTF-8',$line))<=400,'each payload fits a 400-byte UTF-8 budget');
    ok(defined eval {decode('UTF-8',encode('UTF-8',$line),Encode::FB_CROAK())},'trimming preserves valid UTF-8');
    unlike($line,qr/[\r\n\x00\x01]/,'payload cannot contain extra IRC lines or CTCP');
}
like($lines->[0],qr/…$/,'overlong forecast ends at a word boundary with ellipsis');
like($lines->[1],qr/Nombre 42 .*Couleur émeraude .*Chance 80% .*Complice Poissons/,'compact French lucky details');
is($H->can('clean_text')->("a\n\x02b\x02"),'a b','external whitespace and IRC bold normalized');
ok(!defined $H->can('clean_text')->("\x01ACTION inject"),'external CTCP rejected');
ok(!defined $H->can('clean_text')->("\xff"),'invalid UTF-8 rejected');

# Actual command: sign precedence, database birthday, language and gates.
my $db=bless {birthdays=>{pablo=>'07-24',max_=>'1990-03-21'},queries=>[]},'MB817::DB';
my $bot=bless {dbh=>$db,conf=>MB817::Conf->new({'main.LANG'=>'en'}),
    logger=>bless({lines=>[]},'MB817::Log')},'Mediabot';
my (@out,@api);
my ($fr,$disabled)=(0,0);
no warnings 'redefine';
local *Mediabot::UserCommands::botPrivmsg=sub {push @out,{to=>$_[1],text=>$_[2]}; 1};
local *Mediabot::UserCommands::botNotice=sub {push @out,{to=>$_[1],text=>$_[2],notice=>1}; 1};
local *Mediabot::Helpers::chanset_enabled=sub {
    my ($self,$channel,$flag)=@_;
    return !$disabled if $flag eq 'Games';
    return $fr if $flag eq 'LangFR';
    return 0;
};
local *Mediabot::External::Horoscope::daily_line=sub {push @api,[@_]; undef};
my $run=sub {
    my ($nick,$channel,@args)=@_; @out=();
    my $ctx=bless {bot=>$bot,nick=>$nick,channel=>$channel,args=>\@args},'MB817::Ctx';
    Mediabot::UserCommands::mbHoroscope_ctx($ctx);
    return [map {{%$_}} @out];
};
my ($english,$french);
for my $lang (qw(en fr)) {
    $fr=$lang eq 'fr';
    my $result=$run->('Pablo','#room');
    is(@$result,2,"$lang actual birthday command emits two lines");
    my $want=$fr ? 'Lion' : 'Leo';
    like($result->[0]{text},qr/♌ \x02\Q$want\E\x02/,'stored birthday selects the right localized sign');
    like($result->[1]{text},$fr ? qr/Nombre .*Couleur .*Chance .*Complice/ : qr/Lucky number .*Colour .*Luck .*Kindred sign/,'all details use channel language');
    is($result->[0]{to},'#room','output stays on invocation channel');
    is($api[-1][2],$lang,'external forecast gets the same display language');
    unlike(join('\n',map {$_->{text}} @$result),qr/(?:Climat :|Vibe:|Conseil :|Advice:|humeur |mood:)/,'no old repeated slogan or extra verbose sections');
    ($fr ? $french : $english)=$result;
}
my ($en_n,$en_l)=$english->[1]{text}=~/number (\d+).*Luck (\d+)%/;
my ($fr_n,$fr_l)=$french->[1]{text}=~/Nombre (\d+).*Chance (\d+)%/;
is("$en_n/$en_l","$fr_n/$fr_l",'changing language preserves daily lucky number and luck');
$fr=1;
for my $slug (@signs) {
    my $result=$run->('Pablo','#room',$slug);
    my ($label,$glyph)=$H->can('sign_label')->($slug,'fr');
    like($result->[0]{text},qr/\Q$glyph\E \x02\Q$label\E\x02/,'explicit sign overrides stored birthday');
    ok(!grep({length(encode('UTF-8',$_->{text}))>400} @$result),'actual sign output respects byte limits');
}
my $r1=$run->('Pablo','#room','lion');
my $r2=$run->('Max_','#room','lion');
my ($f1)=$r1->[0]{text}=~/ — (.*)$/;
my ($f2)=$r2->[0]{text}=~/ — (.*)$/;
is($f1,$f2,'same sign/day has one forecast for different users, without personalized repeated padding');
my $count=@api;
my $unknown=$run->('Nobody','#room');
is(@$unknown,2,'missing birthday still gets a compact useful response');
like($unknown->[0]{text},qr/signe inconnu : essaie !horoscope lion/,'unknown sign offers a working sign command');
unlike($unknown->[1]{text},qr/Complice/,'unknown sign has no invented companion');
is(scalar @api,$count,'missing sign performs no external fetch');
$disabled=1;
my $denied=$run->('Pablo','#room','lion');
is(@$denied,1,'-Games still blocks public use');
ok($denied->[0]{notice},'disabled public games reply remains a notice');
is(scalar @api,$count,'disabled games performs no external fetch');
$disabled=0; $fr=0;
my $private=$run->('Pablo',undef,'bélier');
is($private->[0]{to},'Pablo','internal private call replies only to requester');
like($private->[0]{text},qr/\x02Aries\x02/,'private call uses global English language');
is($bot->{_horoscope_count}{Pablo}>0,1,'consultation counters still advance');
is($db->{queries}[0],'SELECT birthday FROM USER WHERE nickname = ?','birthday lookup remains parameterized');
srand(81); my @reference=map {rand()} 1..4;
srand(81); my @head=map {rand()} 1..2; $run->('Pablo','#room','lion'); my @tail=map {rand()} 1..2;
is("@head @tail","@reference",'actual horoscope does not reseed or consume global RNG');

# Real provider-neutral executor, HTTP mocked at its normal boundary.
my $http=bless {responses=>[],gets=>[],requests=>[]},'MB817::HTTP';
my @http_opts;
local *Mediabot::External::_make_http=sub {push @http_opts,{@_}; $http};
local *Mediabot::External::Claude::claudeAI=sub {die 'must never enter chat translation'};
my $b=bless {conf=>MB817::Conf->new({'anthropic.API_KEY'=>'test-key'}),logger=>$bot->{logger},
    _claude_history=>{secret=>'unchanged'},_claude_persona=>{secret=>'unchanged'},_claude_pinned=>{secret=>'unchanged'}},'Mediabot';
my $json=JSON::PP->new->utf8;
my $answer_response=sub {
    my ($answer)=@_;
    +{success=>1,status=>200,content=>$json->encode({content=>[{type=>'text',text=>$answer}]})};
};
my $translated='Votre assurance entraîne les autres. Partagez la lumière.';
@{$http->{responses}}=($answer_response->(JSON::PP->new->encode({language=>'fr',forecast=>$translated})));
is($H->can('localize')->($b,'Your confidence inspires others.','fr','Pablo'),$translated,'French translation completes synchronously before worker returns');
is(@{$http->{requests}},1,'one configured provider request, no nested async task');
my $request=$json->decode($http->{requests}[0][2]{content});
is(@{$request->{messages}},1,'translation has no chat history');
is($request->{temperature},0,'translation avoids creative personalization');
like($request->{system},qr/French.*only JSON/s,'translation asks for explicit French response schema');
ok($http_opts[-1]{verify_SSL} && $http_opts[-1]{max_redirect}==0,'authenticated translation verifies TLS and refuses redirects');
is($http_opts[-1]{timeout},8,'translation HTTP timeout is bounded');
is_deeply($b->{_claude_history},{secret=>'unchanged'},'translation does not touch chat history');
is_deeply($b->{_claude_persona},{secret=>'unchanged'},'translation ignores and preserves personas');
is_deeply($b->{_claude_pinned},{secret=>'unchanged'},'translation ignores and preserves pinned context');
for my $bad ('not JSON',JSON::PP->new->encode({language=>'en',forecast=>'A useful day.'}),
    JSON::PP->new->encode({language=>'fr',forecast=>'Take a chance and trust yourself.'}),
    JSON::PP->new->encode({language=>'fr',forecast=>'Votre journée https://evil.example'}),
    JSON::PP->new->encode({language=>'fr',forecast=>"Votre journée \x01ACTION"}),
    JSON::PP->new->encode({language=>'fr',forecast=>$translated,extra=>'not allowed'})) {
    @{$http->{responses}}=($answer_response->($bad));
    ok(!defined $H->can('localize')->($b,'source','fr','Pablo'),'bad translation returns local fallback signal');
}
@{$http->{responses}}=({success=>0,status=>503});
ok(!defined $H->can('localize')->($b,'source','fr','Pablo'),'provider outage silently chooses local forecast');
my $no_key=bless {conf=>MB817::Conf->new},'Mediabot';
my $calls=@{$http->{requests}};
ok(!defined $H->can('localize')->($no_key,'source','fr','Pablo'),'no key chooses a French local forecast');
is(@{$http->{requests}},$calls,'no key starts no translation request');
is($H->can('localize')->($no_key,'An English forecast.','en','Pablo'),'An English forecast.','English needs no AI translation');

# Provider label guard and ordinary English path remain valid.
@{$http->{responses}}=({success=>1,status=>200,content=>$json->encode({data=>{sign=>'Virgo',horoscope=>'wrong'}})},
    {success=>1,status=>200,content=>$json->encode({data=>{sign=>'Virgo',horoscope=>'wrong'}})});
ok(!defined $H->can('fetch_daily')->($no_key,'leo'),'wrong-sign API responses still rejected');
@{$http->{responses}}=({success=>1,status=>200,content=>$json->encode({data=>{sign=>'Leo',horoscope=>'Focus on one useful idea.'}})});
# daily_line itself was mocked above; exercise its independently saved original.
my $fetch=$H->can('fetch_daily')->($no_key,'leo');
is($fetch,'Focus on one useful idea.','correct sign API prediction remains available');
ok($http_opts[-1]{verify_SSL},'ordinary horoscope fetch verifies TLS');

{
    local *Mediabot::External::Horoscope::daily_line=$original_daily;
    $fr=1;
    @{$http->{responses}}=(
        {success=>1,status=>200,content=>$json->encode({data=>{sign=>'Leo',horoscope=>'Your confidence inspires others.'}})},
        $answer_response->(JSON::PP->new->encode({language=>'fr',forecast=>$translated})));
    my $ctx=bless {bot=>$b,nick=>'Pablo',channel=>'#room',args=>['lion']},'MB817::Ctx';
    my ($intents,$truncated,$ok,$error)=Mediabot::CommandAsync::_collect_intents_run(sub {
        Mediabot::UserCommands::mbHoroscope_ctx($ctx);
    });
    ok($ok,'real worker collector completes forecast and translation synchronously');
    is(@$intents,2,'worker returns both compact payloads before exiting');
    like($intents->[0][2],qr/\Q$translated\E/,'worker intent contains actual translated forecast');
    is($intents->[0][0],'privmsg','worker preserves ordinary PRIVMSG output');
}
done_testing();
