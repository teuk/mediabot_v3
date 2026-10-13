use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Encode qw(encode);
use JSON::PP qw(encode_json decode_json);
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::AI::MetaReply qw(clean_answer shorten_sources display_urls shorturl_ready);
use Mediabot::AI::MetaRuntime;
use Mediabot::AI::MetaPolicy qw(settings);
use Mediabot::URLShortener qw(make_bot_shortener);
{
 package MB819Conf;sub get {$_[0]{$_[1]}}
 package MB819HTTP;
 sub request {my ($s,$method,$url,$options)=@_;push @{$s->{calls}},[$method,$url,$options];
  my $p=JSON::PP::decode_json($options->{content});my $id=@{$s->{calls}}==1?'Abcdef23':'Ghijkm45';
  return {success=>1,status=>201,content=>JSON::PP::encode_json({protocol=>1,id=>$id,url=>$s->{mismatch}?'https://other.example.org/wrong':$p->{url},short_url=>'https://teuk.org/shorturl/'.$id})};}
 package MB819Gen;sub capture_generation {$_[0]{generation}}
 package MB819Logger;sub log {push @{$_[0]{lines}},[$_[1],$_[2]]}
 package MB819Bot;sub getMessageNickIdentHost {my ($s,$m)=@_;return @$m}
 package MB819Client;sub submit {my ($s,$r,%args)=@_;push @{$s->{calls}},{request=>$r,done=>$args{on_done}};1}
}
my $given='Les positions : \\n- Alice propose une mesure précise.\\n- Bob conteste son financement.';
is(clean_answer($given),'Les positions : Alice propose une mesure précise. Bob conteste son financement.','serialized list newlines flatten into compact prose');
is(clean_answer("Deux faits :\n- Alice confirme.\n- Bob nuance."),'Deux faits : Alice confirme. Bob nuance.','real newlines and bullets flatten before delivery');
unlike(clean_answer('Un fait.\\\\n- Un autre fait.\\r\\n- Dernier fait.'),qr/\\[rn]/,'multiply escaped paragraph artifacts are removed');
is(clean_answer('Chemin C:\\new et motif "\\n".'),'Chemin C:\\new et motif "\\n".','ambiguous code/path escapes remain meaningful');
unlike(clean_answer("clair\x01ACTION\x00\x03".'12' ."\\n fin"),qr/[\x00-\x1f]/,'normalization strips externally supplied IRC controls');
my $dir=tempdir(CLEANUP=>1);my $long1='https://one.example.org/'.('first-article-'x30);my $long2='https://two.example.org/'.('second-article-'x30);
my $sources=[{id=>1,url=>$long1,text=>'A first verified statement with concrete detail.'},
 {id=>2,url=>$long2,text=>'A second verified statement with independent detail.'},
 {id=>3,url=>'https://third.example.org/article',text=>'A third verified statement with concrete detail.'}];
my $short_key='a' x 64;
my $conf=bless {'shorturl.API_URL'=>'https://teuk.org/shorturl/api/v1/links','shorturl.PUBLIC_BASE_URL'=>'https://teuk.org/shorturl/',
 'shorturl.API_KEY'=>$short_key,'shorturl.STATE_FILE'=>"$dir/short-cache.json"},'MB819Conf';
my $http=bless {calls=>[]},'MB819HTTP';my $bot={conf=>$conf,config_file=>"$dir/mediabot.conf"};
ok(shorturl_ready($bot),'private shortening readiness is offline and uses existing contract');
my $shortened=shorten_sources(bot=>$bot,sources=>$sources,http=>$http);
is(scalar(@{$http->{calls}}),2,'only two actually selected source destinations are shortened');
is($http->{calls}[0][1],'https://teuk.org/shorturl/api/v1/links','existing private HTTPS endpoint is reused');
is($http->{calls}[0][2]{headers}{Authorization},'Bearer '.$short_key,'private endpoint uses its configured credential');
unlike($http->{calls}[0][2]{content},qr/\Q$short_key\E/,'credential does not enter shortening body');
is_deeply([map {$_->{url}} @{$shortened->{mappings}}],[$long1,$long2],'shortening retains exact destination binding');
shorten_sources(bot=>$bot,sources=>$sources,http=>$http);
is(scalar(@{$http->{calls}}),2,'existing persistent cache avoids repeated HTTP calls');
is((stat("$dir/short-cache.json"))[2]&0777,0600,'shared cache remains private');
my $urls=display_urls($sources,$shortened,'https://teuk.org/shorturl/');
is($urls->{$long1},'https://teuk.org/shorturl/Abcdef23','first alias is attached to its exact source');
my $line=Mediabot::AI::MetaRuntime::_source_line($sources,'fr',$urls);
like($line,qr/\x0312\x1fhttps:\/\/teuk\.org\/shorturl\/Abcdef23\x0f/,'shorturl is light blue and underlined with a reset');
like($line,qr/\x0f \| \x0312\x1f/,'separator stays outside link style');
unlike($line,qr/first-article|second-article/,'long verified original links do not consume displayed space');
cmp_ok(length(encode('UTF-8',$line)),'<',160,'source line is compact including colour and underline bytes');
is(scalar(()=$line=~/\x0312\x1f/g),2,'both displayed aliases have the requested style');
my $untrusted=display_urls($sources,{mappings=>[
 {url=>$long1,display_url=>'https://evil.example.org/Abcdef23'},
 {url=>'https://not-requested.example.org/',display_url=>'https://teuk.org/shorturl/Abcdef23'},
 {url=>$long2,display_url=>"https://teuk.org/shorturl/Ghijkm45\r\ninjected"}]},'https://teuk.org/shorturl/');
is_deeply($untrusted,{},'foreign aliases, substituted originals and injected controls are rejected');
my $badconf=bless {%$conf,'shorturl.STATE_FILE'=>"$dir/mismatch.json"},'MB819Conf';
my $badhttp=bless {calls=>[],mismatch=>1},'MB819HTTP';
my $bad=shorten_sources(bot=>{conf=>$badconf},sources=>[$sources->[0]],http=>$badhttp);
is($bad->{mappings}[0]{display_url},$long1,'service destination mismatch preserves exact original URL');
my $legacy=bless {'tinyurl.API_KEY'=>'YOUR_TINYURL_TEST_KEY'},'MB819Conf';
my $nohttp=bless {calls=>[]},'MB819HTTP';
my $fallback=shorten_sources(bot=>{conf=>$legacy},sources=>[$sources->[0]],http=>$nohttp);
is(scalar(@{$nohttp->{calls}}),0,'Meta AI never contacts legacy third-party shortener');
is($fallback->{mappings}[0]{display_url},$long1,'unconfigured private service retains original-source fallback');
ok(!shorturl_ready({conf=>$legacy}),'legacy key is not mistaken for private-service readiness');

my (@sent,@notices,@timers,@shortening);my $accept=1;
no warnings 'redefine';
local *Mediabot::Helpers::channel_lang=sub {'fr'};
local *Mediabot::Helpers::chanset_enabled=sub {1};
local *Mediabot::Helpers::botPrivmsg=sub {return 0 unless $accept;push @sent,[$_[1],$_[2],$_[3]];1};
local *Mediabot::Helpers::botNotice=sub {push @notices,$_[2];1};
sub fixture {
 @sent=();@notices=();@timers=();@shortening=();$accept=1;
 my $tmp=tempdir(CLEANUP=>1);
 my $c=bless {%$conf,'meta_ai.ENABLED'=>1,'meta_ai.CHANNELS'=>'#test','meta_ai.PROVIDERS'=>'openai anthropic',
  'meta_ai.STATE_FILE'=>"$tmp/memory.json",'openai.API_KEY'=>'YOUR_OPENAI_TEST_KEY','anthropic.API_KEY'=>'YOUR_CLAUDE_TEST_KEY'},'MB819Conf';
 my $client=bless {calls=>[]},'MB819Client';
 my $b=bless {conf=>$c,config_file=>"$tmp/mediabot.conf",wit_runtime_state=>bless({generation=>1},'MB819Gen'),
  logger=>bless({lines=>[]},'MB819Logger')},'MB819Bot';
 my $runtime=Mediabot::AI::MetaRuntime->new(bot=>$b,client_factory=>sub {$client},
  web_start=>sub {$_[1]->({ok=>1,sources=>$sources});1},schedule_cb=>sub {push @timers,[@_]},
  shorten_start=>sub {push @shortening,[@_];1});
 $b->{_meta_ai_runtime}=$runtime;
 return ($b,$client,$runtime,$tmp);
}
sub ask {Mediabot::AI::MetaRuntime::handle($_[0],['Alice','ident','public.example.org'],'Alice','#test','latest positions?')}
sub synthesize {
 my ($c,$text)=@_;
 for my $i (0..1) {$c->{calls}[$i]{done}->({ok=>1,answer=>encode_json({answer=>'Draft',needs_web=>1,query=>'official positions'})})}
 $c->{calls}[2]{done}->({ok=>1,provider=>'openai',answer=>encode_json({answer=>$text,source_ids=>[1,2],basis=>'supported',support=>[
  {source_id=>1,quote=>'A first verified statement with concrete detail.'},
  {source_id=>2,quote=>'A second verified statement with independent detail.'}]})});
}
sub history_count {my ($tmp)=@_;open my $f,'<:raw',"$tmp/memory.json" or die $!;local $/;my $s=decode_json(<$f>);return scalar map {@{$_->{turns}}} values %{$s->{rooms}};}
my ($b,$client,$runtime,$tmp)=fixture();ask($b);synthesize($client,'Un fait concret et sa réserve. 'x23);
is(scalar(@sent),0,'HTTP shortening is a separate asynchronous presentation stage');
is(scalar(@shortening),1,'one presentation stage per researched answer');
is_deeply([map {$_->{url}} @{$shortening[0][0]}],[$long1,$long2],'only cited evidence enters source presentation');
$shortening[0][1]->($shortened);
is(scalar(@sent),1,'first answer line starts after presentation completes');
is($timers[0][0],1.5,'second answer line is paced at 1.5 seconds');
is(history_count($tmp),0,'partly delivered researched answer is not saved');
$timers[0][1]->();
is(scalar(@sent),2,'second answer line is available for substance');
is($timers[1][0],1.5,'sources line also waits 1.5 seconds');
$timers[1][1]->();
is(scalar(@sent),3,'at most two answer lines plus one compact sources line are sent');
like($sent[2][1],qr/^Sources : /,'third line contains only source presentation');
ok(!grep(length(encode('UTF-8',$_->[1]))>400,@sent),'all three payloads including style remain within 400 UTF-8 bytes');
ok(!grep(!$_->[2]{no_defer},@sent),'none of the three lines bypasses immediate-only flood policy');
is(history_count($tmp),1,'only fully delivered exchange is retained');
like($b->{logger}{lines}[-1][1],qr/shorturls=2$/,'completion metadata reports shortening without URLs or keys');
$shortening[0][1]->($shortened);
is(scalar(@sent),3,'duplicate source completion cannot send another reply');

($b,$client,$runtime,$tmp)=fixture();ask($b);synthesize($client,'Late reply');
$b->{wit_runtime_state}{generation}=2;$shortening[0][1]->($shortened);
is(scalar(@sent),0,'changed generation discards source presentation and answer');
is(history_count($tmp),0,'stale presentation creates no completed history');
is(scalar(keys %{$runtime->{jobs}}),0,'stale presentation releases channel job');
($b,$client,$runtime,$tmp)=fixture();ask($b);synthesize($client,'Forgotten reply');
Mediabot::AI::MetaRuntime::handle($b,['Alice','ident','public.example.org'],'Alice','#test','/forget');
$shortening[0][1]->($shortened);
is(scalar(@sent),0,'forget during shortening cancels future output');
is(history_count($tmp),0,'forgotten in-flight answer is not reinserted');
($b,$client,$runtime,$tmp)=fixture();ask($b);synthesize($client,'First facts. 'x45);$shortening[0][1]->($shortened);
$timers[0][1]->();$accept=0;$timers[1][1]->();
is(scalar(@sent),2,'source-line flood rejection sends no third line');
is(history_count($tmp),0,'missing source delivery leaves no completed memory');
like($b->{logger}{lines}[-1][1],qr/delivery_aborted/,'incomplete delivery is not logged as completed');

($b,$client,$runtime,$tmp)=fixture();ask($b);synthesize($client,$given);$shortening[0][1]->($shortened);$timers[0][1]->();
unlike(join(' ',map {$_->[1]} @sent),qr/\\[rn]|[\r\n\x00\x01]/,'live presentation has no escaped line breaks or IRC line injection');
my $system=$client->{calls}[2]{request}{system};
like($system,qr/declared candidacy from speculation/,'synthesis is instructed to preserve precise candidate status');
like($system,qr/actual stated proposals/,'positions question requests concrete statements from evidence');
like($system,qr/under 650 characters/,'researched answer is no longer reduced to 280 characters');

# Actual isolated shortening worker preserves the event loop contract.
($b,$client,$runtime,$tmp)=fixture();my $loop=IO::Async::Loop->new;$b->{loop}=$loop;$runtime->{shorten_start}=undef;
my $completed;
local *Mediabot::AI::MetaRuntime::shorten_sources=sub {return $shortened};
$runtime->_present_sources([$sources->[0]],sub {$completed=shift});
ok(!defined($completed),'real shortening worker does not complete synchronously in IRC parent');
my $deadline=time+3;$loop->loop_once(0.02) while !defined($completed) && time<$deadline;
is_deeply($completed,$shortened,'isolated presentation result returns to its parent');
done_testing;
