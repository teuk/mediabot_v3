use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use JSON::PP qw(encode_json decode_json);
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request validate_request);
use Mediabot::AI::Transport ();
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaRuntime;
use Mediabot::External::Claude ();
use Mediabot::External::Gemini ();
{
    package MB1049::Conf;
    sub get {$_[0]{$_[1]}}
    package MB1049::HTTP;
    sub request {$_[0]{reply}->(@_[1..$#_])}
    package MB1049::Loop;
    sub add {1} sub remove {1} sub watch_process {1}
    package MB1049::Log;
    sub log {push @{$_[0]{rows}},$_[2];1}
    package MB1049::Bot;
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
sub conf_1422 {
    return bless {map {($_.'.API_KEY'=>'test-placeholder',$_.'.MODEL'=>'example-model')}
        qw(openai anthropic gemini)},'MB1049::Conf';
}
sub request_1422 {
    my ($provider)=@_;
    return build_request(provider=>$provider,messages=>[{role=>'user',content=>'probe'}],timeout_seconds=>5);
}
sub response_1422 {
    my ($provider,$answer)=@_;
    return {success=>1,status=>200,reason=>'OK',content=>encode_json(
        $provider eq 'anthropic' ? {content=>[{type=>'text',text=>$answer}]}:
        $provider eq 'openai' ? {choices=>[{message=>{content=>$answer}}]}:
        {candidates=>[{content=>{parts=>[{text=>$answer}]}}]})};
}
sub transport_1422 {
    my ($response,$options)=@_;
    return eval {Mediabot::AI::Transport::post_json(api_url=>'https://fixture.example/api',
        timeout=>5,headers=>{},payload=>'{}',http_factory=>sub {
            %$options=@_ if $options;
            bless {reply=>sub {$response}},'MB1049::HTTP';
        })};
}
{
    my $r={provider=>'openai',system=>'s'x249_999,messages=>[{role=>'user',content=>'u'}]};
    ok(!defined(validate_request($r)),'combined system and messages fit exactly at the existing text ceiling');
    $r->{system}.='s';
    like(validate_request($r)//'',qr/safety ceiling/,'system text is counted together with conversation text');
    $r->{system}='s'x250_001;
    ok(defined(validate_request($r)),'oversized system instructions are rejected before provider work');
    $r->{system}='€'x100_000;
    ok(!defined(validate_request($r)),'request text retains its character-based Unicode contract');
    for my $provider (qw(openai anthropic gemini)) {
        my $request={provider=>$provider,model=>'example-model',max_output_tokens=>10,
            system=>'s'x249_999,messages=>[{role=>'user',content=>'uu'}]};
        my $package='Mediabot::AI::Provider::'.{openai=>'OpenAI',anthropic=>'Anthropic',gemini=>'Gemini'}->{$provider};
        my $payload=eval {$package->can('build_payload')->($request)};
        ok(!defined($payload) && $@ =~ /safety ceiling/,"$provider adapter enforces the shared aggregate request limit");
    }
}
{
    my %options;my $r=transport_1422({success=>1,status=>200,content=>'{}'},\%options);
    is_deeply([@options{qw(timeout verify_SSL max_size)}],[5,1,512*1024],
        'every HTTP factory receives the existing production byte cap and verified TLS');
    my $at=transport_1422({success=>1,status=>200,content=>'x'x(512*1024)});
    ok($at->{success} && length(Mediabot::AI::Transport::decode_content($at))==512*1024,
        'the exact HTTP byte boundary is accepted without truncation');
    my $over=transport_1422({success=>1,status=>200,content=>'x'x(512*1024+1)});
    is_deeply([$over->{success},$over->{error},Mediabot::AI::Transport::decode_content($over)],
        [0,'response_too_large',''],'a custom client cannot bypass the HTTP response cap or retain oversized content');
    my $unicode=transport_1422({success=>1,status=>200,content=>'€'x174_763});
    is_deeply([$unicode ? $unicode->{error}:undef,$unicode ? $unicode->{content_b64}:undef],
        ['response_too_large',''],'upgraded Unicode content is bounded by actual UTF-8 bytes');
    my $native=transport_1422({success=>0,status=>599,
        content=>"Size of response body exceeds the maximum allowed of 524288\n"});
    is($native->{error},'response_too_large','HTTP::Tiny max_size failure keeps a specific bounded diagnosis');
    my $ordinary=transport_1422({success=>1,status=>200,
        content=>"Size of response body exceeds the maximum allowed of 524288\n"});
    ok($ordinary->{success} && !$ordinary->{error},'ordinary successful text cannot masquerade as a native size abort');
}
my $normal="Bonjour 🌟 — \\"x1000;
for my $provider (qw(openai anthropic gemini)) {
    my $calls=0;
    my $client=Mediabot::AI::Client->new(conf=>conf_1422(),http_factory=>sub {
        bless {reply=>sub {$calls++;response_1422($provider,$normal)}},'MB1049::HTTP'});
    my $r=$client->execute(request_1422($provider));
    ok($r->{ok} && $r->{answer} eq $normal,"$provider preserves complete ordinary Unicode and escaping");
    $client=Mediabot::AI::Client->new(conf=>conf_1422(),http_factory=>sub {
        bless {reply=>sub {response_1422($provider,'x'x(300*1024))}},'MB1049::HTTP'});
    $r=$client->execute(request_1422($provider));
    is_deeply([@$r{qw(ok provider error failure_category)},exists($r->{answer})?1:0],
        [0,$provider,'response_too_large','response_size',0],"$provider returns a complete failure rather than an oversized successful result");
}
{
    my $client=Mediabot::AI::Client->new(conf=>conf_1422(),http_factory=>sub {
        bless {reply=>sub {response_1422('openai','\\'x130_000)}},'MB1049::HTTP'});
    my $r=$client->execute(request_1422('openai'));
    is($r->{error},'response_too_large','the result ceiling counts JSON escaping instead of raw answer characters');
}
for my $case (['openai',400],['gemini',503]) {
    my ($provider,$status)=@$case;my $calls=0;my $conf=conf_1422();
    $conf->{'openai.FALLBACK_MODEL'}='example-backup';$conf->{'gemini.FALLBACK_MODEL'}='example-backup';
    my $client=Mediabot::AI::Client->new(conf=>$conf,http_factory=>sub {
        bless {reply=>sub {$calls++;{success=>0,status=>$status,content=>'x'x(512*1024+1)}}},'MB1049::HTTP'});
    my $r=$client->execute(request_1422($provider));
    is_deeply([$calls,$r->{error}],[1,'response_too_large'],"$provider size errors do not trigger pointless model/transient retries");
}
{
    my @calls;
    my $client=Mediabot::AI::Client->new(conf=>conf_1422(),provider_order=>[qw(anthropic openai gemini)],
        http_factory=>sub {bless {reply=>sub {
            my (undef,$url)=@_;my $provider=$url =~ /anthropic/?'anthropic':'openai';
            push @calls,$provider;response_1422($provider,$provider eq 'anthropic'?'x'x(300*1024):'recovered');
        }},'MB1049::HTTP'});
    my $r=$client->execute(request_1422('auto'));
    is_deeply([\@calls,@$r{qw(ok provider answer provider_fallback)}],
        [[qw(anthropic openai)],1,'openai','recovered',1],'auto alone may recover on the next permitted provider');
}
{
    my $loop=IO::Async::Loop->new;my @results;
    for my $provider (qw(openai anthropic gemini)) {
        for my $large (0,1) {
            my $text=$large?'漢'x100_000:$normal;
            my $client=Mediabot::AI::Client->new(conf=>conf_1422(),loop_owner=>{loop=>$loop},
                http_factory=>sub {bless {reply=>sub {response_1422($provider,$text)}},'MB1049::HTTP'});
            $client->submit(request_1422($provider),on_done=>sub {push @results,[$provider,$large,$_[0]]});
        }
    }
    my $deadline=time()+12;$loop->loop_once(0.05) while @results<6 && time()<$deadline;
    is(scalar(@results),6,'six real worker children complete through the actual JSON pipe');
    for my $provider (qw(openai anthropic gemini)) {
        my ($small)=map {$_->[2]} grep {$_->[0] eq $provider && !$_->[1]} @results;
        my ($large)=map {$_->[2]} grep {$_->[0] eq $provider && $_->[1]} @results;
        ok($small && $small->{ok} && $small->{answer} eq $normal,"$provider async output remains byte-for-byte complete");
        is_deeply([$large ? $large->{error}:undef,$large ? $large->{failure_category}:undef,
            $large ? $large->{provider}:undef],['response_too_large','response_size',$provider],
            "$provider oversized worker output retains its provider and size diagnosis");
    }
}
{
    my $client=Mediabot::AI::Client->new(conf=>conf_1422(),
        provider_order=>[qw(openai anthropic gemini)],loop_owner=>{loop=>bless({},'MB1049::Loop')},
        worker_start=>sub {my %a=@_;$a{on_done}->({ok=>1,value=>$a{child}->()});bless {},'MB1049::Worker'},
        http_factory=>sub {bless {reply=>sub {
            my (undef,$url,$options)=@_;my $provider=$url=~/anthropic/?'anthropic':$url=~/googleapis/?'gemini':'openai';
            my $text=$provider eq 'anthropic'?'x'x(300*1024)
                :index($options->{content},'UNTRUSTED DRAFTS:')>=0
                ? encode_json({answer=>'4',source_ids=>[]})
                : encode_json({answer=>'4',task_type=>'calculation',needs_web=>JSON::PP::false});
            response_1422($provider,$text);
        }},'MB1049::HTTP'});
    my @results;
    Mediabot::AI::MetaChat->new(client=>$client,conf=>conf_1422(),settings=>settings(conf_1422()),
        web_start=>sub {die 'calculation must remain local'})
        ->submit(prompt=>'calcule 2+2',messages=>[{role=>'user',content=>'calcule 2+2'}],
            on_done=>sub {push @results,$_[0]});
    is_deeply([scalar(@results),$results[0]{ok},$results[0]{answer},$results[0]{degraded},
        $results[0]{contributors},$results[0]{provider_failures}],
        [1,1,'4',1,[qw(openai gemini)],['anthropic']],
        'MetaAI uses the two intact contributors and marks the oversized one as failed');
}
{
    my $bot=bless {logger=>bless({rows=>[]},'MB1049::Log'),wire=>[]},'MB1049::Bot';
    no warnings qw(redefine once);
    local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},$_[2];1};
    local *Mediabot::External::Gemini::_can_deliver=sub {1};
    for my $provider (qw(openai anthropic gemini)) {
        $bot->{wire}=[];my $r={ok=>0,provider=>$provider,error=>'response_too_large',status=>200};
        if ($provider eq 'openai') {Mediabot::External::Claude::_chatgpt_accept_client_result($bot,{nick=>'Alice',chan=>'#test'},$r)}
        elsif ($provider eq 'anthropic') {Mediabot::External::Claude::_claude_accept_client_result($bot,{nick=>'Alice',chan=>'#test',model=>'example-model'},$r)}
        else {Mediabot::External::Gemini::_accept_result($bot,{nick=>'Alice',channel=>'#test'},$r)}
        like(join(' ',@{$bot->{wire}}),qr/exceeded its safe size limit/,"$provider IRC surface gives a useful size-specific explanation");
    }
    Mediabot::AI::MetaRuntime->new(bot=>$bot)->_log_event({kind=>'provider',provider=>'openai',
        outcome=>'api_failure',status=>200,error=>'response_too_large',failure_category=>'response_size'});
    like($bot->{logger}{rows}[-1],qr/error=response_too_large category=response_size/,
        'MetaAI preserves the common bounded size category in operational logs');
}
is_deeply(\@warnings,[],'shared request/transport/result boundaries remain warning-free');
done_testing;
