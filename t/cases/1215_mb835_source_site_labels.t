use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::AI::MetaReply qw(source_label display_urls);
use Mediabot::AI::MetaRuntime;

for my $case (
    ['https://www.franceinfo.fr/elections/article','FranceInfo'],
    ['https://FRANCEINFO.FR/article','FranceInfo'],
    ['https://mobile.franceinfo.fr/article','FranceInfo'],
    ['https://www.francetvinfo.fr/article','FranceInfo'],
    ['https://www.lemonde.fr/article','Le Monde'],
    ['https://cert.ssi.gouv.fr/alerte','CERT-FR'],
    ['https://www.ssi.gouv.fr/guide','ANSSI'],
    ['https://www.musee-orsay.fr/visit',"Musée d'Orsay"],
    ['https://fr.wikipedia.org/wiki/Science','Wikipedia'],
    ['https://www.imaginaire.example.org/article','imaginaire.example.org'],
    ['https://docs.project.example.org/guide','docs.project.example.org'],
    ['https://franceinfo.fr.example.org/article','franceinfo.fr.example.org'],
    ['https://notfranceinfo.fr/article','notfranceinfo.fr'],
    ['https://example.org/franceinfo.fr/article','example.org'],
) {
    is(source_label($case->[0]),$case->[1],"original host label: $case->[0]");
}
my $long_host=('subdomain.'x10).'example.org';
is(source_label('https://'.$long_host.'/article'),'...'.substr($long_host,-45),
    'long unknown host retains its domain ending within 48 characters');
for my $bad (undef,{},[],q{},'javascript:alert(1)','https://www.franceinfo.fr@evil.example.org/',
    "https://franceinfo.fr/\r\nPRIVMSG #test :injected") {
    is(source_label($bad),'','unsafe or non-scalar URL cannot provide a label');
}

my $sources=[
    {id=>1,url=>'https://www.franceinfo.fr/article',title=>"Wrong title\x03".'04',site_name=>'Fake Brand'},
    {id=>2,url=>'https://imaginaire.example.org/article',title=>'FranceInfo'},
];
my $urls=display_urls($sources,{mappings=>[
    {url=>$sources->[1]{url},display_url=>'https://teuk.org/shorturl/Ghijkm45'},
    {url=>$sources->[0]{url},display_url=>'https://teuk.org/shorturl/Abcdef23'},
]},'https://teuk.org/shorturl/');
my $line=Mediabot::AI::MetaRuntime::_source_line($sources,'en',$urls);
is($line,"Sources: \x0314FranceInfo\x0f \x0312\x1fhttps://teuk.org/shorturl/Abcdef23\x0f"
    ." | \x0314imaginaire.example.org\x0f \x0312\x1fhttps://teuk.org/shorturl/Ghijkm45\x0f",
    'two labels are dark grey; each alias is blue/underlined and each style resets');
unlike($line,qr/Wrong title|Fake Brand/,'article and model site labels cannot enter output');
unlike($line,qr/\x0314teuk/,'labels identify destinations rather than the private shortener');
my $plain=$line;$plain=~s/\x03\d{2}|[\x0f\x1f]//g;
is($plain,'Sources: FranceInfo https://teuk.org/shorturl/Abcdef23 | imaginaire.example.org https://teuk.org/shorturl/Ghijkm45',
    'clients without formatting still display readable labels and clickable aliases');
my $fr=Mediabot::AI::MetaRuntime::_source_line($sources,'fr',$urls);
like($fr,qr/\ASources : \x0314FranceInfo/,'French prefix retains its spacing and source labels');
my $translated=$fr;$translated=~s/\ASources : /Sources: /;
is($translated,$line,'language does not change source attribution or URLs');
my $fallback=Mediabot::AI::MetaRuntime::_source_line([$sources->[0]],'en',{});
is($fallback,"Sources: \x0314FranceInfo\x0f https://www.franceinfo.fr/article",
    'failed shortening retains labelled exact original URL without alias styling');
my $untrusted=display_urls($sources,{mappings=>[
    {url=>$sources->[0]{url},display_url=>'https://evil.example.org/Abcdef23'},
]},'https://teuk.org/shorturl/');
is(Mediabot::AI::MetaRuntime::_source_line([$sources->[0]],'en',$untrusted),$fallback,
    'untrusted alias cannot change either label or displayed original URL');

my $unicode=Mediabot::AI::MetaRuntime::_source_line([
    {url=>'https://www.musee-orsay.fr/visit'},
],'en',{'https://www.musee-orsay.fr/visit'=>'https://teuk.org/shorturl/Abcdef23'});
like($unicode,qr/\x0314Musée d'Orsay\x0f /,'UTF-8 site label retains its accent and reset');
my $unicode_prefix="Sources: \x0314Musée d'Orsay\x0f ";
my $unicode_url='https://musee-orsay.fr/'.('x'x(400-length(encode('UTF-8',$unicode_prefix))-length('https://musee-orsay.fr/')));
is(length(encode('UTF-8',Mediabot::AI::MetaRuntime::_source_line([{url=>$unicode_url}],'en',{}))),400,
    'non-ASCII label bytes count towards the exact 400-byte boundary');
is(Mediabot::AI::MetaRuntime::_source_line([{url=>$unicode_url.'x'}],'en',{}),undef,
    'UTF-8 byte budget cannot be bypassed by an accented label');
my @many=(@$sources,{url=>'https://third.example.org/article'});
my $limited=Mediabot::AI::MetaRuntime::_source_line(\@many,'en',$urls);
is($limited,$line,'existing maximum of two source entries is unchanged');
cmp_ok(length(encode('UTF-8',$line)),'<=',400,'labels and all controls fit the IRC byte envelope');
my $prefix="Sources: \x0314example.org\x0f ";
my $exact='https://example.org/'.('x'x(400-length(encode('UTF-8',$prefix))-length('https://example.org/')));
my $boundary=Mediabot::AI::MetaRuntime::_source_line([{url=>$exact}],'en',{});
is(length(encode('UTF-8',$boundary)),400,'exactly 400 bytes including label and controls remains valid');
like($boundary,qr/\Q$exact\E\z/,'a fitting original URL is never truncated');
is(Mediabot::AI::MetaRuntime::_source_line([{url=>$exact.'x'}],'en',{}),undef,
    'one extra byte cannot publish an overlong or truncated sources line');
is(Mediabot::AI::MetaRuntime::_source_line([],'en',{}),undef,'no sources creates no stray label line');
is(Mediabot::AI::MetaRuntime::_source_line([{},undef],'en',{}),undef,
    'absent sources create neither labels nor a fabricated citation');

done_testing;
