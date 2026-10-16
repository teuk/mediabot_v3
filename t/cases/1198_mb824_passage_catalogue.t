use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::MetaEvidence qw(validate_support);
use Mediabot::AI::MetaPassages qw(build_catalogue resolve_support);

my $source={id=>1,url=>'https://tukaani.org/xz-backdoor/',title=>'XZ Utils advisory',
    text=>'The affected release archives were XZ Utils 5.6.0 and 5.6.1. Do not use those releases.',kind=>'page_excerpt'};
my $other={id=>2,url=>'https://example.org/advisory',text=>'Official distribution guidance identifies supported package updates.'};
my $catalogue=build_catalogue([$source,$other]);
ok($catalogue && @{$catalogue->{sources}}==2,'retrieved source content yields a bounded catalogue');
my $pid=$catalogue->{sources}[0]{passages}[0]{passage_id};
like($pid,qr/\As1p1-[a-f0-9]{12}\z/,'program assigns a source/content-bound passage ID');
is($catalogue->{sources}[0]{passages}[0]{text},$source->{text},'model reads the retrieved passage verbatim');
ok(!exists($catalogue->{sources}[0]{text}),'unindexed duplicate source text is absent from model payload');
my $parsed={answer=>'Les archives 5.6.0 et 5.6.1 sont concernées.',source_ids=>[1],basis=>'supported',
    support=>[{source_id=>1,passage_id=>$pid}]};
my ($resolved,$error)=resolve_support($parsed,[$source],$catalogue);
ok($resolved && !defined($error),'valid selection resolves without model-generated quote text');
is($resolved->{support}[0]{quote},$source->{text},'the local program supplies the exact proof text');
ok(!defined(validate_support($resolved,[$source])),'unchanged literal validator accepts resolved evidence');
ok(!exists($parsed->{support}[0]{quote}),'resolution does not mutate the model reply');
my $changed=build_catalogue([{%$source,text=>$source->{text}.' Later correction.'}]);
isnt($changed->{sources}[0]{passages}[0]{passage_id},$pid,'changed source content gets different IDs');
($resolved,$error)=resolve_support($parsed,[{%$source,text=>$source->{text}.' Later correction.'}],$catalogue);
is($error,'source_changed','mutable source content cannot silently reuse the original catalogue');
($resolved,$error)=resolve_support($parsed,[{%$source,url=>'https://other.example.org/advisory'}],$catalogue);
is($error,'source_changed','changed source destination cannot inherit an old proof');
($resolved,$error)=resolve_support($parsed,[$source],$changed);
is($error,'unknown_passage','IDs from another source snapshot are rejected');
for my $id ('s1p99-000000000000','invented',undef,[],"$pid\n") {
    ($resolved,$error)=resolve_support({%$parsed,support=>[{source_id=>1,passage_id=>$id}]},[$source],$catalogue);
    ok(!$resolved && defined($error),'malformed or unknown passage IDs never become valid proof');
}
my $other_pid=$catalogue->{sources}[1]{passages}[0]{passage_id};
($resolved,$error)=resolve_support({%$parsed,support=>[{source_id=>1,passage_id=>$other_pid}]},[$source],$catalogue);
is($error,'unknown_passage','real passage from another source cannot be attached to this citation');
for my $bad (
    {basis=>'certain'},
    {support=>[]},
    {support=>[{source_id=>1,quote=>$source->{text}}]},
    {support=>[{source_id=>1,passage_id=>$pid,quote=>'Forged replacement'}]},
    {support=>[{source_id=>1,passage_id=>$pid},{source_id=>1,passage_id=>$pid}]},
    {support=>[{source_id=>3,passage_id=>$pid}]},
    {support=>{}},
) {
    ($resolved,$error)=resolve_support({%$parsed,%$bad},[$source],$catalogue);
    ok(!$resolved && defined($error),'invalid support shape, duplicate ID or extra free-text proof is rejected');
}
($resolved,$error)=resolve_support($parsed,[$source,$other],$catalogue);
is($error,'missing','every displayed source still needs a selected passage');
($resolved,$error)=resolve_support({%$parsed,source_ids=>[1,2],support=>[
    {source_id=>1,passage_id=>$pid},{source_id=>2,passage_id=>$other_pid}]},[$source,$other],$catalogue);
ok($resolved && @{$resolved->{support}}==2,'two sources resolve to two actual passages');
my $typographic={%$source,text=>'L’ANSSI décrit l’hameçonnage : « ne communiquez pas vos codes ». 🌍'};
my $unicode=build_catalogue([$typographic]);
($resolved,$error)=resolve_support({%$parsed,support=>[{source_id=>1,
    passage_id=>$unicode->{sources}[0]{passages}[0]{passage_id}}]},[$typographic],$unicode);
ok($resolved && !defined(validate_support($resolved,[$typographic])),'Unicode/apostrophe normalization uses the existing source validator');
my $many={%$source,text=>join(' ',map {'word'.$_} 1..800)};
my $large=build_catalogue([$many]);
cmp_ok(scalar(@{$large->{sources}[0]{passages}}),'<=',40,'per-source catalogue has a hard row bound');
my $full=Mediabot::AI::MetaEvidence::_literal($many->{text});
for my $passage (@{$large->{sources}[0]{passages}}) {
    ok(length($passage->{text})>=12 && length($passage->{text})<=240,'every proof respects unchanged quote bounds');
    cmp_ok(index($full,$passage->{text}),'>=',0,'every generated proof is a contiguous actual source substring');
}
my $joined=build_catalogue([{%$source,text=>('First independent fragment with facts. 'x5).' … '.('Second independent fragment with other facts. 'x5)}]);
ok(!grep($_->{text}=~/First.*Second/s,@{$joined->{sources}[0]{passages}}),'proofs never cross the extractor non-contiguous fragment separator');
ok(!build_catalogue([]),'empty research cannot fabricate a catalogue');
ok(!build_catalogue([{%$source,url=>'http://127.0.0.1/private'}]),'unsafe source destination remains rejected');
ok(!build_catalogue([$source,$source]),'duplicate source identities are refused');
ok(!build_catalogue([{%$source,text=>'tiny'}]),'empty/too-short source has no usable proof');
for my $cited (undef,[],[undef],[{id=>1,url=>[]}],[$source,$source]) {
    my $ok=eval {($resolved,$error)=resolve_support($parsed,$cited,$catalogue);1};
    ok($ok && !$resolved && defined($error),'malformed cited-source input fails without throwing');
}
done_testing;
