use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::Provider::OpenAI ();
use Mediabot::AI::Provider::Anthropic ();
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
{
    package MB818ProviderConf;
    sub new {bless $_[1],$_[0]} sub get {$_[0]{$_[1]}}
    package MB818ProviderHTTP;
    sub request {my ($s,$method,$url,$args)=@_;push @{$s->{calls}},[$method,$url,$args];
        return $s->{response}}
}
my $request=build_request(provider=>'openai',purpose=>'meta_draft',model=>'gpt-6.1-sol',
    system=>'Be concise',messages=>[{role=>'user',content=>'Question'}],max_output_tokens=>2048,temperature=>0.7);
my $payload=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($request,{api_style=>'responses'}));
is($payload->{model},'gpt-6.1-sol','requested modern model is retained');
is($payload->{reasoning}{effort},'low','latency-conscious reasoning is explicit');
is($payload->{max_output_tokens},2048,'Responses uses max_output_tokens');
ok(!exists($payload->{temperature}) && !exists($payload->{max_tokens}),'unsupported legacy sampling and token fields absent');
ok(!$payload->{store},'remote conversation storage is disabled');
is($payload->{instructions},'Be concise','system instructions use Responses field');
is($payload->{input}[0]{content},'Question','message input is preserved');
my $web=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($request,
    {api_style=>'responses',web_search=>1,web_domains=>['nist.gov']}));
is($web->{tools}[0]{type},'web_search','native web tool is available');
is($web->{tool_choice},'required','web fallback must actually use a tool');
is_deeply($web->{tools}[0]{filters}{allowed_domains},['nist.gov'],'validated domain filter is preserved');
my $raw=encode_json({output=>[
    {type=>'reasoning',summary=>[{text=>'private reasoning'}]},
    {type=>'web_search_call',status=>'completed'},
    {type=>'message',content=>[{type=>'output_text',text=>'Visible reply',annotations=>[
        {type=>'url_citation',url=>'https://nist.gov/physics',title=>'NIST'},
        {type=>'url_citation',url=>'https://nist.gov/physics',title=>'Duplicate'},
        {type=>'url_citation',url=>"https://nist.gov/x\r\ninjected",title=>'bad'},
    ]}]}]});
is(Mediabot::AI::Provider::OpenAI::extract_answer($raw),'Visible reply','reasoning is not output text');
is_deeply(Mediabot::AI::Provider::OpenAI::extract_sources($raw),
    [{url=>'https://nist.gov/physics',title=>'NIST'}],'verified API citation metadata is deduplicated');
is_deeply(Mediabot::AI::Provider::OpenAI::extract_sources(encode_json({output=>[
    {type=>'message',content=>[{type=>'output_text',text=>'fake',annotations=>[
        {type=>'url_citation',url=>'https://nist.gov/physics'}]}]}]})),[],
    'citation-shaped data without a completed web call is not browsing evidence');
is(Mediabot::AI::Provider::OpenAI::extract_answer(encode_json({choices=>[
    {message=>{content=>'Old answer'}}]})),'Old answer','legacy Chat Completions responses still parse');
my $legacy=decode_json(Mediabot::AI::Provider::OpenAI::build_payload($request));
is($legacy->{max_tokens},2048,'old callers retain their payload contract');
is($legacy->{temperature},0.7,'old sampling contract is unchanged');
for my $model ('claude-sonnet-5-5','claude-haiku-4-5-20251001') {
    my $claude={%$request,provider=>'anthropic',model=>$model};
    my $p=decode_json(Mediabot::AI::Provider::Anthropic::build_payload($claude));
    is(exists($p->{temperature})?1:0,$model =~ /-5-5/ ?0:1,'temperature compatibility follows the selected Claude family');
}
my $modern_claude=decode_json(Mediabot::AI::Provider::Anthropic::build_payload({%$request,provider=>'anthropic',model=>'claude-sonnet-5-5'}));
is($modern_claude->{thinking}{type},'between_tools','Sonnet 5.5 avoids unsupported disabled thinking');
is($modern_claude->{output_config}{effort},'low','Claude effort is bounded for IRC');
my @calls;my $conf=MB818ProviderConf->new({'openai.API_KEY'=>'test-openai-credential'});
my $client=Mediabot::AI::Client->new(conf=>$conf,config_overrides=>{
    'openai.API_URL'=>'https://api.openai.com/v1/responses','openai.MODEL'=>'gpt-6.1-sol',
    'openai.WEB_SEARCH'=>1},http_factory=>sub {
        my %opts=@_;ok($opts{verify_SSL},'authenticated request verifies TLS');
        bless {calls=>\@calls,response=>{success=>1,status=>200,content=>$raw}},'MB818ProviderHTTP'});
my $result=$client->execute({%$request,purpose=>'meta_web'});
ok($result->{ok},'shared client executes the modern provider plan');
is($calls[0][1],'https://api.openai.com/v1/responses','shared transport uses Responses endpoint');
is(decode_json($calls[0][2]{content})->{tools}[0]{type},'web_search','only native web purpose enables web tool');
is($calls[0][2]{headers}{Authorization},'Bearer test-openai-credential','existing private key location remains authoritative');
unlike($calls[0][2]{content},qr/test-openai-credential/,'credential never enters the JSON payload');
is_deeply($result->{sources},[{url=>'https://nist.gov/physics',title=>'NIST'}],'citation metadata survives the shared client');
done_testing;
