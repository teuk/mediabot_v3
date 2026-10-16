use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Provider::Gemini qw(build_payload);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaRuntime;
my $conf=bless {'gemini.API_KEY'=>'YOUR_GEMINI_TEST_KEY','meta_ai.GEMINI_FALLBACK_MODEL'=>'gemini-test-spare'},'MB825RecoveryConf';
my (@calls,@responses,@timeouts);
my $ok={success=>1,status=>200,content=>encode_json({candidates=>[{content=>{parts=>[{text=>'OK'}]}}]})};
my $busy={success=>0,status=>503,content=>encode_json({error=>{status=>'UNAVAILABLE',code=>503,message=>'PRIVATE_ERROR_BODY'}})};
sub run_probe {
    my ($purpose,$fallback,@response)=@_;@responses=@response;@calls=();@timeouts=();
    my $client=Mediabot::AI::Client->new(conf=>$conf,
        config_overrides=>{'gemini.FALLBACK_MODEL'=>$fallback},
        http_factory=>sub {push @timeouts,$_[1];bless {},'MB825RecoveryHTTP'});
    return $client->execute(build_request(provider=>'gemini',model=>'gemini-3.8-flash',purpose=>$purpose,
        messages=>[{role=>'user',content=>'OK'}],max_output_tokens=>1024,timeout_seconds=>5));
}
my $r=run_probe('meta_draft','gemini-test-spare',$busy,$ok);
ok($r->{ok},'configured spare can recover a real common-client request');
is($r->{model},'gemini-test-spare','common result reports the model that actually answered');
is($r->{model_fallback},1,'model fallback is explicit');
is($r->{transient_retries},1,'the existing second call is used');
is($r->{first_failure_category},'service_unavailable','original overload category survives a successful recovery');
is_deeply($r->{attempted},['gemini:gemini-3.8-flash','gemini:gemini-test-spare'],'both model identities remain observable');
is(scalar(@calls),2,'fallback does not add a third HTTP attempt');
like($calls[0][1],qr{/gemini-3\.8-flash:generateContent$},'first attempt retains the selected model');
like($calls[1][1],qr{/gemini-test-spare:generateContent$},'second attempt stays on Gemini with the explicit spare');
is_deeply(decode_json($calls[0][2]{content})->{contents},decode_json($calls[1][2]{content})->{contents},'recovery retains the exact same messages');
cmp_ok($timeouts[1],'<',5,'second attempt only receives the remaining original deadline');
is($calls[1][2]{headers}{'x-goog-api-key'},'YOUR_GEMINI_TEST_KEY','fallback retains header-only authentication');
is(decode_json($calls[0][2]{content})->{generationConfig}{responseMimeType},'application/json','meta contributor requests JSON from Gemini');
$r=run_probe('meta_probe','',$busy,$ok);
ok($r->{ok} && !$r->{model_fallback},'empty fallback retains bounded same-model recovery');
is($r->{model},'gemini-3.8-flash','empty fallback cannot silently select a model');
$r=run_probe('meta_probe','gemini-test-spare',$busy,$busy,$ok);
ok(!$r->{ok} && @calls==2,'persistent service failure has no third try');
is($r->{status},503,'final actual service status remains visible');
is($r->{model},'gemini-test-spare','failed fallback identifies the failing model too');
for my $status (400,401,403,404,429,599) {
    $r=run_probe('meta_probe','gemini-test-spare',{success=>0,status=>$status,content=>'PRIVATE_ERROR_BODY'},$ok);
    ok(!$r->{ok} && @calls==1,"$status cannot trigger model changes or blindly retry");
}
$r=run_probe('gemini','gemini-test-spare',$busy,$ok);
ok(!$r->{ok} && @calls==1,'legacy standalone purpose cannot activate meta fallback');
$r=run_probe('meta_probe','../secret',$ok);
ok(!$r->{ok} && @calls==0,'invalid fallback is rejected before any request');
for my $model ('gemini-3.8-flash','gemini-3.6-pro','gemini-4-flash','gemini-10-pro') {
    my $p=decode_json(build_payload(build_request(provider=>'gemini',purpose=>'meta_probe',model=>$model,
        messages=>[{role=>'user',content=>'OK'}],max_output_tokens=>100,temperature=>0.7)));
    ok(!exists($p->{generationConfig}{temperature}),"deprecated sampling omitted for $model");
}
my $p=decode_json(build_payload(build_request(provider=>'gemini',purpose=>'gemini',model=>'gemini-2.5-flash',
    messages=>[{role=>'user',content=>'OK'}],max_output_tokens=>100,temperature=>0.7)));
is($p->{generationConfig}{temperature},0.7,'older model temperature contract is preserved');
ok(!exists($p->{generationConfig}{responseMimeType}),'legacy text purpose is not forced to JSON');
is(settings($conf)->{gemini_fallback},'gemini-test-spare','fallback is explicitly read from private meta settings');
my $bot={logger=>bless({lines=>[]},'MB825Logger')};
my $runtime=Mediabot::AI::MetaRuntime->new(bot=>$bot);
$runtime->_log_event({kind=>'provider',provider=>'gemini',outcome=>'usable',status=>200,model=>'gemini-test-spare',model_fallback=>1});
like($bot->{logger}{lines}[0],qr/model=gemini-test-spare model_fallback=1/,'safe runtime metadata reports effective model');
$runtime->_log_event({kind=>'provider',provider=>'gemini',outcome=>'api_failure',status=>503,
    model=>"injected\nPRIVATE_CREDENTIAL",model_fallback=>"1\nPRIVATE_ERROR_BODY"});
unlike(join('\n',@{$bot->{logger}{lines}}),qr/PRIVATE|injected/,'malformed metadata cannot inject secrets or lines');
# The actual asynchronous worker must carry effective-model metadata back to
# the parent; a recovery sleep must not run in the IRC event loop.
require IO::Async::Loop;
require Time::HiRes;
my $loop=IO::Async::Loop->new;
my $ai=Mediabot::AI::Client->new(conf=>$conf,loop_owner=>{loop=>$loop},
    config_overrides=>{'gemini.FALLBACK_MODEL'=>'gemini-test-spare'},
    http_factory=>sub {bless {},'MB825RecoveryAsyncHTTP'});
my @async;
$ai->submit(build_request(provider=>'gemini',model=>'gemini-3.8-flash',purpose=>'meta_draft',
    messages=>[{role=>'user',content=>'OK'}],max_output_tokens=>1024,timeout_seconds=>5),on_done=>sub {push @async,shift});
is(scalar(@async),0,'real provider recovery is asynchronous to the parent');
my $deadline=Time::HiRes::time()+8;
$loop->loop_once(0.05) while !@async && Time::HiRes::time()<$deadline;
is(scalar(@async),1,'real worker recovery produces one final callback');
ok($async[0]{ok} && $async[0]{model_fallback} && $async[0]{model} eq 'gemini-test-spare','actual fallback model metadata survives worker IPC');
is($async[0]{first_failure_category},'service_unavailable','original category survives worker IPC');
done_testing;
package MB825RecoveryConf;
sub get {$_[0]{$_[1]}}
package MB825RecoveryHTTP;
sub request {push @calls,[@_[1..3]];shift @responses}
package MB825Logger;
sub log {push @{$_[0]{lines}},$_[2]}
package MB825RecoveryAsyncHTTP;
sub request {
    my ($s,$method,$url,$opts)=@_;
    return $url=~/gemini-test-spare:generateContent$/?$ok:$busy;
}
