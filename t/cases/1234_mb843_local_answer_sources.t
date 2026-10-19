use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json);
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::AI::MetaChat;
use Mediabot::AI::MetaReply qw(shorten_sources);

{
    package MB843Conf;
    sub get {$_[0]{$_[1]}}
    package MB843Client;
    sub submit {my($s,$r,%a)=@_;push @{$s->{calls}},{request=>$r,done=>$a{on_done}};1}
    package MB843NoHTTP;
    sub request {die 'a source-free answer must not contact the shortener'}
}
sub begin_request {
    my ($prompt,%options)=@_;
    my $conf=bless {'openai.API_KEY'=>'openai-test-key','anthropic.API_KEY'=>'anthropic-test-key',
        'meta_ai.PROVIDERS'=>'openai anthropic','meta_ai.WEB_MODE'=>$options{mode}//'auto'},'MB843Conf';
    my $state={calls=>[],results=>[],searches=>0};
    my $engine=Mediabot::AI::MetaChat->new(conf=>$conf,settings=>settings($conf),
        client=>bless({calls=>$state->{calls}},'MB843Client'),clock=>sub {1792324800},
        evidence_mode=>'passage_ids',web_start=>sub {$state->{searches}++;
            $_[1]->({ok=>1,sources=>[{id=>1,url=>'https://official.example.org/reference',
                text=>'The documented stable version is 9.4 and the official project supports this release.'}]});1});
    my $messages=[{role=>'user',content=>'speaker1: Quel est le détail de CVE-2024-3094 ?'},
        {role=>'assistant',content=>'Earlier researched answer. Sources: https://previous.example.org/reference'},
        {role=>'user',content=>'speaker2: '.$prompt}];
    $engine->submit(prompt=>$prompt,messages=>$messages,language=>'fr',on_done=>sub {push @{$state->{results}},shift});
    return $state;
}
my $weight='si tu pese 104.6 kg et que tu perds 10kg et tu en reprends 5 etc , en combien de cycles arrives tu a 91?';
for my $prompt ($weight,"wie geht's",'et si je perds 10 puis reprends 5, combien après 3 cycles ?',
    'How would you phrase this more politely? Please leave me alone.',
    'ça me fait plaisir de te parler') {
    my $s=begin_request($prompt);
    is(scalar(@{$s->{calls}}),2,'two configured contributors start without an extra routing call');
    like($s->{calls}[0]{request}{system},qr/task_type/,'contributors classify in their existing response');
    for my $i (1,0) {
        my $semantic=$prompt =~ /politely|plaisir/;
        $s->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'A local draft.',
            task_type=>$semantic?($prompt =~ /plaisir/?'conversation':'transformation'):'factual',needs_web=>$semantic?0:1,
            query=>'CVE previous unrelated research'})});
    }
    is($s->{searches},0,'self-contained task does not run Tavily despite old sources and unrelated contributor queries');
    is(scalar(@{$s->{calls}}),3,'only the normal synthesis follows the contributors');
    is($s->{calls}[2]{request}{purpose},'meta_synthesis','native web fallback is not launched either');
    like($s->{calls}[2]{request}{system},qr/do not add sources, citations, source names/,'local synthesis has an explicit source-free contract');
    like($s->{calls}[2]{request}{system},qr/define a complete cycle/,'arithmetic distinguishes full cycles from intermediate values');
    like($s->{calls}[2]{request}{system},qr/greeting naturally/,'a greeting is answered as conversation');
    $s->{calls}[2]{done}->({ok=>1,answer=>encode_json({answer=>'Une réponse directe.',source_ids=>[1]})});
    my $out=$s->{results}[0];
    ok($out->{ok},'local answer completes');
    ok(!$out->{web_attempted} && !$out->{web_used},'no false research metadata');
    is_deeply($out->{sources},[],'a source ID from earlier context cannot become a local citation');
    my $short=shorten_sources(bot=>{conf=>bless({},'MB843Conf')},sources=>$out->{sources},http=>bless({},'MB843NoHTTP'));
    is_deeply($short->{mappings},[],'the source-free answer has no shortener mapping');
    $s->{calls}[0]{done}->({ok=>1,answer=>'late duplicate'});
    is(scalar(@{$s->{results}}),1,'duplicate contributor completion cannot revive research or delivery');
}

for my $case (
    ['auto','what is the latest release?',1,0],
    ['auto','Calcule 2+2 et cite tes sources',1,0],
    ['always',"wie geht's",1,0],
    ['off',$weight,0,0],
    ['off','what is the latest release?',0,1],
) {
    my($mode,$prompt,$searches,$error)=@$case;my $s=begin_request($prompt,mode=>$mode);
    for my $i (0,1) {$s->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',task_type=>'calculation',needs_web=>0})})}
    is($s->{searches},$searches,'mode and explicit/current research boundary retained');
    if ($error) {
        is($s->{results}[0]{error},'web_disabled_for_current_question','web off refuses required verification');
        is(scalar(@{$s->{calls}}),2,'disabled required web does not silently synthesize an unsourced factual answer');
    }
    elsif ($searches) {
        is($s->{calls}[2]{request}{purpose},'meta_synthesis_passages','required research keeps the validated passage route');
        $s->{calls}[2]{done}->({ok=>1,provider=>'openai',answer=>encode_json({answer=>'Unverified claim',source_ids=>[99]})});
        is($s->{results}[0]{error},'unsupported_web_answer','required research still rejects invented citations');
    }
    else {is($s->{calls}[2]{request}{purpose},'meta_synthesis','local task remains available with web off')}
}
done_testing;
