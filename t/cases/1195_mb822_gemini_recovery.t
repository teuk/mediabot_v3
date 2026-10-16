use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Provider::Gemini qw(failure_category build_payload);
my $conf=bless {'gemini.API_KEY'=>'YOUR_GEMINI_TEST_KEY'},'MB822GeminiConf';
my (@responses,@calls,@timeouts);
my $client=Mediabot::AI::Client->new(conf=>$conf,http_factory=>sub {
    push @timeouts,$_[1];bless {},'MB822GeminiHTTP'});
sub probe {
    my ($purpose,@items)=@_;@responses=@items;@calls=();@timeouts=();
    return $client->execute(build_request(provider=>'gemini',purpose=>$purpose,
        model=>'gemini-3.8-flash',messages=>[{role=>'user',content=>'Reply OK.'}],max_output_tokens=>1024,timeout_seconds=>5));
}
my $ok={success=>1,status=>200,content=>encode_json({candidates=>[{content=>{parts=>[{text=>'OK'}]}}]})};
my $busy={success=>0,status=>503,content=>encode_json({error=>{status=>'UNAVAILABLE',code=>503,message=>'hidden provider message'}})};
my $r=probe('meta_probe',$busy,$ok);
ok($r->{ok},'a transient Gemini overload can recover in the same explicit probe');
is($r->{provider},'gemini','retry never changes provider');
is($r->{transient_retries},1,'one transient retry is observable');
is(scalar(@calls),2,'at most two HTTP attempts');
cmp_ok($timeouts[0],'<',3,'first attempt leaves room in the existing five-second request budget');
cmp_ok($timeouts[1],'<',5,'retry receives remaining budget rather than a new deadline');
is($calls[0][2]{headers}{'x-goog-api-key'},'YOUR_GEMINI_TEST_KEY','header authentication retained on retry');
ok(!grep(/key=/,@{$calls[0]}[1]),'credential never enters request URL');
$r=probe('meta_draft',$busy,$busy);
ok(!$r->{ok},'persistent overload remains a failure');
is($r->{status},503,'actual HTTP status is preserved');
is($r->{failure_category},'service_unavailable','overload is distinguished from access and billing');
is(scalar(@calls),2,'persistent overload has no retry loop');
for my $case (
    [599,'SSL certificate verification failed','tls'],
    [599,'Could not resolve hostname','dns'],
    [599,'Unclassified internal exception','transport'],
    [403,'Permission denied','access'],
    [429,'Quota reached','quota'],
    [404,'Not found','model'],
    [400,'Bad settings','request']) {
    my ($status,$body,$category)=@$case;
    $r=probe('meta_probe',{success=>0,status=>$status,reason=>'Internal Exception',content=>$body},$ok);
    ok(!$r->{ok},"$category is not blindly retried");
    is($r->{failure_category},$category,"$status retains its meaningful failure category");
    is(scalar(@calls),1,'permanent or unidentified failure gets one attempt');
}
$r=probe('meta_probe',{success=>0,status=>599,reason=>'Internal Exception',content=>'Timed out while waiting for socket to become ready'},$ok);
ok($r->{ok} && $r->{transient_retries}==1,'a recognized 599 timeout can recover');
$r=probe('gemini',$busy,$ok);
ok(!$r->{ok} && @calls==1,'legacy explicit Gemini caller keeps its historical single-attempt contract');
for my $spec (['gemini-2.5-flash',0],['gemini-2.5-pro',128]) {
    my ($model,$budget)=@$spec;
    my $payload=decode_json(build_payload(build_request(provider=>'gemini',purpose=>'meta_probe',model=>$model,
        max_output_tokens=>1024,messages=>[{role=>'user',content=>'OK'}]),{thinking_level=>'LOW'}));
    is_deeply($payload->{generationConfig}{thinkingConfig},{thinkingBudget=>$budget},'known 2.5 model uses its supported thinking budget');
}
is(failure_category(599,'','','','unknown'), 'transport','599 alone is a transport result, not a model-access verdict');
done_testing;
package MB822GeminiConf;
sub get {$_[0]{$_[1]}}
package MB822GeminiHTTP;
sub request {push @calls,[@_[1..3]];return shift @responses}
