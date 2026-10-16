use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaRuntime;
{
    package MB823Conf;sub get {$_[0]{$_[1]}}
    package MB823Client;
    sub submit {my ($s,$r,%args)=@_;push @{$s->{calls}},{request=>$r,done=>$args{on_done}};1}
    package MB823Logger;sub log {push @{$_[0]{lines}},$_[2]}
}
my $conf=bless {'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY',
    'gemini.API_KEY'=>'YOUR_GEMINI_TEST_KEY','meta_ai.PROVIDERS'=>'openai anthropic gemini'},'MB823Conf';
my $quote='CVE-2024-3094 affected the XZ Utils 5.6.0 and 5.6.1 release archives.';
my $sources=[{id=>1,url=>'https://tukaani.org/xz-backdoor/',text=>$quote,kind=>'page_excerpt'}];
sub fixture {
    my (%opts)=@_;
    my $client=bless {calls=>[]},'MB823Client';my (@out,@events);my $searches=0;
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),client=>$client,
        on_event=>sub {push @events,shift;die 'PRIVATE_LOGGER_EXCEPTION' if $opts{observer_dies}},
        web_start=>sub {$searches++;$_[1]->({ok=>1,sources=>$sources});1});
    my $messages=[{role=>'user',content=>'speaker1 (Alice): détail CVE-2024-3094'}];
    $engine->submit(prompt=>'détail CVE-2024-3094',messages=>$messages,language=>'fr',on_done=>sub {push @out,shift});
    $client->{calls}[1]{done}->({ok=>1,status=>200,answer=>encode_json({answer=>'Independent draft',needs_web=>0})});
    $client->{calls}[2]{done}->($opts{all_ok}
        ? {ok=>1,status=>200,answer=>encode_json({answer=>'Gemini draft',needs_web=>0})}
        : {ok=>0,status=>503,error=>'http_error',failure_category=>'service_unavailable',transient_retries=>1,
            reason=>'PRIVATE_HTTP_REASON',error_message=>'PRIVATE_API_ERROR'});
    $client->{calls}[0]{done}->({ok=>1,status=>200,answer=>encode_json({answer=>'Another draft',needs_web=>0})});
    return ($client,\@out,\@events,\$searches);
}
sub answer {
    my (%extra)=@_;
    return {answer=>'XZ Utils 5.6.0 and 5.6.1 were affected.',source_ids=>[1],basis=>'supported',
        support=>[{source_id=>1,quote=>$quote}],%extra};
}
sub complete {my ($client,$idx,$value,$provider)=@_;
    $client->{calls}[$idx]{done}->({ok=>1,status=>200,provider=>$provider//'openai',answer=>encode_json($value)});}
my ($client,$out,$events,$searches)=fixture();
is(scalar(@{$client->{calls}}),4,'three independent contributors then one ordinary synthesis');
is(scalar(@$events),3,'one observer event per contributor even when one API fails');
is_deeply([map {$_->{provider}} @$events],[qw(anthropic gemini openai)],'events preserve actual callback identity rather than guessing the failed provider');
my ($gemini)=grep {$_->{provider} eq 'gemini'} @$events;
is($gemini->{outcome},'api_failure','Gemini unavailable is distinct from empty draft');
is($gemini->{status},503,'actual status retained');
is($gemini->{failure_category},'service_unavailable','known Gemini category retained');
is($gemini->{transient_retries},1,'existing retry count retained');
ok(!exists($gemini->{reason}) && !exists($gemini->{error_message}) && !exists($gemini->{answer}),
    'observer does not receive raw HTTP reason, error text or answer');
complete($client,3,answer());
ok($out->[0]{ok},'two usable providers still produce a validated answer');
is_deeply($out->[0]{contributors},[qw(openai anthropic)],'configured contributor order is stable despite callback race');
is_deeply($out->[0]{provider_failures},['gemini'],'failed provider is explicitly recorded');
ok($out->[0]{degraded},'successful two-of-three reply is degraded');
is($out->[0]{citation_repair},0,'normal valid synthesis has no correction');
is(scalar(@{$client->{calls}}),4,'normal valid answer adds no provider request');

my $invented='PRIVATE_REJECTED_CLAIM';
for my $bad (
    {support=>[{source_id=>1,quote=>'An invented claim absent from the actual source.'}]},
    {support=>[{source_id=>2,quote=>$quote}]},
    {basis=>'certain'},
    {support=>[{source_id=>1,quote=>('x'x241)}]},
    {support=>[{source_id=>1,quote=>{text=>$quote}}]}
) {
    ($client,$out,$events,$searches)=fixture();
    complete($client,3,answer(answer=>$invented,%$bad),'anthropic');
    is(scalar(@$out),0,'bad initial evidence is not delivered as a final answer');
    is(scalar(@{$client->{calls}}),5,'one complete synthesis regeneration, without contributor retry');
    is($$searches,1,'same evidence is reused without another search');
    is($client->{calls}[4]{request}{provider},'anthropic','regeneration stays on actual successful synthesis provider');
    is($client->{calls}[4]{request}{purpose},'meta_citation_repair','existing bounded repair purpose is reused');
    is_deeply($client->{calls}[4]{request}{messages},$client->{calls}[3]{request}{messages},'conversation is preserved');
    like($client->{calls}[4]{request}{system},qr/Copy each support quote as one contiguous, verbatim/,'repair requires exact passages rather than paraphrases');
    unlike($client->{calls}[4]{request}{system},qr/\Q$invented\E/,'rejected factual claim is not recycled into repair evidence');
    complete($client,4,answer(),'anthropic');
    ok($out->[0]{ok} && $out->[0]{citation_repair},'only a newly validated result is accepted');
    is($out->[0]{answer},answer()->{answer},'only replacement answer leaves the engine');
    is(scalar(@{$client->{calls}}),5,'successful correction has no further call');
}

($client,$out,$events,$searches)=fixture();
my $bad=answer(support=>[{source_id=>1,quote=>'A fabricated passage not present in supplied evidence.'}]);
complete($client,3,$bad);complete($client,4,$bad);
is($out->[0]{error},'web_evidence_mismatch','second unmatched quote remains a hard failure');
is($out->[0]{evidence_error},'mismatch','failure distinguishes unmatched quote from malformed structure');
is_deeply($out->[0]{contributors},[qw(openai anthropic)],'final rejection still records actual usable contributors');
ok($out->[0]{degraded} && $out->[0]{web_attempted} && $out->[0]{citation_repair},'failure retains degradation, search and repair attempts');
ok(!exists($out->[0]{answer}) && !exists($out->[0]{sources}),'rejected reply does not expose answer or sources');
is(scalar(@{$client->{calls}}),5,'no second correction or provider loop');
is_deeply([map {$_->{action}} grep {$_->{kind} eq 'evidence'} @$events],[qw(retry rejected)],'recovery and final rejection have separate events');
my $n=@$events;
$client->{calls}[4]{done}->({ok=>1,answer=>encode_json(answer())});
is(scalar(@$out),1,'late duplicate callback cannot revive rejected question');
is(scalar(@$events),$n,'duplicate callback cannot log a false recovery');

($client,$out,$events,$searches)=fixture();
complete($client,3,answer(source_ids=>[99]));
is($out->[0]{error},'unsupported_web_answer','invented top-level source ID still rejected immediately');
is(scalar(@{$client->{calls}}),4,'invented ID does not get a correction');
is($events->[-1]{reason},'invalid_ids','invalid IDs are distinguishable in metadata');

($client,$out,$events,$searches)=fixture();complete($client,3,$bad);
$client->{calls}[4]{done}->({ok=>0,status=>503,error=>'http_error',reason=>'PRIVATE_REPAIR_ERROR'});
is($out->[0]{error},'web_synthesis_failed','API failure of correction is explicit');
ok($out->[0]{citation_repair},'attempted correction is not falsely marked unused when API fails');
is(scalar(@{$client->{calls}}),5,'failed correction cannot launch a new provider loop');

($client,$out,$events,$searches)=fixture(observer_dies=>1,all_ok=>1);
complete($client,3,answer());
ok($out->[0]{ok} && !$out->[0]{degraded},'metadata observer failure cannot change acceptance or provider accounting');

my $logger=bless {lines=>[]},'MB823Logger';
my $runtime=Mediabot::AI::MetaRuntime->new(bot=>{logger=>$logger});
my $private='PRIVATE_METADATA_MUST_NOT_LEAK';
$runtime->_log_event({kind=>'provider',provider=>$private,outcome=>$private,status=>"503\n$private",
    error=>$private,failure_category=>$private,transient_retries=>99,answer=>$private});
is($logger->{lines}[-1],'META_AI provider=unknown outcome=unknown status=0 error=unknown category=unknown retries=0 model=unknown model_fallback=0 recovery_from=none',
    'untrusted result metadata is allowlisted before logging');
$runtime->_log_event({kind=>'evidence',reason=>$private,action=>$private,quote=>$private});
is($logger->{lines}[-1],'META_AI evidence=unknown action=unknown','evidence event cannot smuggle private data');
$runtime->_log_event({kind=>$private,answer=>$private});
is(scalar(@{$logger->{lines}}),2,'unknown event kind is ignored');
unlike(join(' ',@{$logger->{lines}}),qr/\Q$private\E/,'no untrusted metadata value is printed');
done_testing;
