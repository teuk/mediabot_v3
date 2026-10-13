use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use Time::HiRes qw(time usleep);
use JSON::PP qw(encode_json decode_json);
use Mediabot::AI::Client;
use Mediabot::AI::Request qw(build_request);
{
    package MB818ParallelConf;
    sub get {$_[0]{$_[1]}}
    package MB818ParallelHTTP;
    sub request {
        my ($self,$method,$url,$opts)=@_;
        Time::HiRes::usleep(100_000);
        my $text='worker '.$$;
        my $body=$url =~ /anthropic/ ? {content=>[{type=>'text',text=>$text}]}
            : $url =~ /googleapis/ ? {candidates=>[{content=>{parts=>[{text=>$text}]}}]}
            : {output=>[{type=>'message',content=>[{type=>'output_text',text=>$text}]}]};
        return {success=>1,status=>200,content=>JSON::PP::encode_json($body)};
    }
}
my $loop=IO::Async::Loop->new;
my $conf=bless {'openai.API_KEY'=>'fake-openai','anthropic.API_KEY'=>'fake-anthropic','gemini.API_KEY'=>'fake-gemini'},'MB818ParallelConf';
my $client=Mediabot::AI::Client->new(conf=>$conf,loop_owner=>{loop=>$loop},
    config_overrides=>{'openai.API_URL'=>'https://api.openai.com/v1/responses','openai.MODEL'=>'gpt-6.1-sol'},
    http_factory=>sub {bless {},'MB818ParallelHTTP'});
my @results;
for my $provider (qw(openai anthropic gemini)) {
    ok($client->submit(build_request(provider=>$provider,purpose=>'meta_draft',
        messages=>[{role=>'user',content=>'A stable test'}],max_output_tokens=>2048,timeout_seconds=>5),
        on_done=>sub {push @results,shift}),"$provider worker starts asynchronously");
}
is(scalar(@results),0,'all three workers are launched before the event loop consumes any response');
my $deadline=time+8;
$loop->loop_once(0.05) while @results<3 && time<$deadline;
is(scalar(@results),3,'all actual AsyncWorker processes finish');
ok(!grep(!$_->{ok},@results),'all three provider envelopes parse successfully');
my %pids=map {($_->{answer}//'')=>1} @results;
is(scalar(keys %pids),3,'HTTP work ran in three separate child processes');
ok(!exists($pids{'worker '.$$}),'no HTTP call blocks the IRC parent process');
done_testing;
