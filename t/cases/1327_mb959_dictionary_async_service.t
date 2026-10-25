use strict;
use warnings;
use Test::More;
use Mediabot::Plugin::DictionaryServiceV3;
use Mediabot::Plugin::DictionaryV3;
{
    package MB959::Worker;
    sub cancel {$_[0]{cancelled}++;1}
    package MB959::Conf;
    sub get {$_[0]{$_[1]}}
}
my @pending;
my $service = Mediabot::Plugin::DictionaryServiceV3->new(settings_provider=>sub {die 'must stay in child'},
    worker_factory=>sub {my %args=@_;my $w=bless {},'MB959::Worker';push @pending,{%args,worker=>$w};$w});
my @results;
ok($service->solve('longest-word-v3','#test','AEEINORSTT',sub {push @results,$_[0]})->{accepted}, 'dictionary work is accepted asynchronously');
is(scalar @results, 0, 'caller is not blocked waiting for database');
is($pending[0]{timeout}, 10, 'wall timeout is core-owned');
my $result={ok=>1,letters=>'AEEINORSTT',words=>[qw(NOTAIRES ORIENTATES)]};
$pending[0]{on_done}->({ok=>1,value=>$result});
is($results[0]{longest},10,'worker result is independently validated');
$results[0]{words}[0]='TAMPERED';
$service->solve('longest-word-v3','#test','AEEINORSTT',sub {push @results,$_[0]});
is($results[1]{words}[0],'ORIENTATES','cached result cannot be mutated through a callback');
$pending[0]{on_done}->({ok=>1,value=>$result});
is(scalar @results,2,'terminal result callback is delivered once');
for my $channel ('#one','#two') {$service->solve('longest-word-v3',$channel,'AABCDE',sub {push @results,$_[0]})}
$service->solve('longest-word-v3','#three','AABCDE',sub {push @results,$_[0]});
is($results[-1]{error},'busy','per-plugin concurrency limit returns a bounded error');
$service->cancel_scope('longest-word-v3','#ONE');
is($pending[1]{worker}{cancelled},1,'channel revocation cancels its worker');
my $n=@results;
$pending[1]{on_done}->({ok=>1,value=>{ok=>1,letters=>'AABCDE',words=>['AB']} });
is(scalar @results,$n,'late revoked callback cannot resurrect a round');
$pending[2]{on_done}->({ok=>0,error=>'secret SQL error'});
is($results[-1]{error},'unavailable','native errors are reduced to public error codes');
$service->solve('longest-word-v3','#test','AABCDE',sub {push @results,$_[0]});
$service->cancel_plugin('longest-word-v3');
ok($pending[-1]{worker}{cancelled},'disable cancels pending dictionary work');
$n=@results;$pending[-1]{on_done}->({ok=>1,value=>{ok=>1,letters=>'AABCDE',words=>['AB']}});
is(scalar @results,$n,'disable invalidates callbacks');
my $inline=Mediabot::Plugin::DictionaryServiceV3->new(settings_provider=>sub {{}},worker_factory=>sub {
    my %a=@_;$a{on_done}->({ok=>0});die 'launch failure after callback';
});
my $calls=0;$inline->solve('longest-word-v3','#test','ABC',sub {$calls++});
is($calls,1,'inline callback followed by launch error is still callback-once');
my $base=bless {'mysql.MAIN_PROG_DBUSER'=>'test','mysql.MAIN_PROG_DBPASS'=>'private','mysql.MAIN_PROG_DBHOST'=>'localhost'},'MB959::Conf';
my $cfg=Mediabot::Plugin::DictionaryV3->settings($base);
is($cfg->{database},'DICT','dictionary database name is explicit and case-sensitive');
is($cfg->{host},'127.0.0.1','localhost uses the existing TCP convention');
is($cfg->{pass},'private','credentials stay in the core-owned private settings');
for my $patch ({'dictionary.DATABASE'=>'mediabot'}, {'dictionary.HOST'=>'localhost;database=other'}, {'dictionary.PORT'=>0}, {'dictionary.SOCKET'=>"/tmp/a;host=other"}) {
    my $bad=bless {%$base,%$patch},'MB959::Conf';
    ok(!eval {Mediabot::Plugin::DictionaryV3->settings($bad);1},'unsafe connection configuration rejected');
}

# Exercise the real fork/pipe/IO::Async path and an independent timer.
require IO::Async::Loop;
require IO::Async::Timer::Countdown;
require Time::HiRes;
my $loop=IO::Async::Loop->new;
my ($heartbeat,$done,$seen_before_finish)=(0,0,0);
my $timer=IO::Async::Timer::Countdown->new(delay=>0.02,on_expire=>sub {$heartbeat=1});
$loop->add($timer);$timer->start;
my $real=Mediabot::Plugin::DictionaryServiceV3->new(loop=>$loop,settings_provider=>sub {
    Time::HiRes::sleep(0.15);die 'private database failure';
});
my $completion;
$real->solve('longest-word-v3','#test','ABC',sub {$completion=$_[0];$seen_before_finish=$heartbeat;$done++});
my $deadline=Time::HiRes::time()+3;
$loop->loop_once(0.01) while !$done && Time::HiRes::time()<$deadline;
is($done,1,'real AsyncWorker completion reaches the native event loop once');
ok($seen_before_finish,'independent timer fires while database child is waiting');
is($completion->{error},'unavailable','real child failure exposes no exception or credential');
$loop->remove($timer);
done_testing;
