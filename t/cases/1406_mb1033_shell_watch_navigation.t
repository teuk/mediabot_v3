use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Test::More;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Select;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Scalar::Util qw(weaken);
use Time::HiRes qw(time);
use Mediabot::Partyline;
use Mediabot::Scheduler;
use Mediabot::Channel;
use Mediabot::Helpers ();
use Mediabot::Partyline::ShellWatch;
{
    package MB1033::Out;
    sub write {die 'PRIVATE_STREAM_ERROR' if $_[0]{broken};$_[0]{text}.=$_[1];1}
    package MB1033::Log;
    sub log {push @{$_[0]{lines}},$_[2];my $hook=$_[0]{hook};$hook->($_[2]) if $hook;1}
    package MB1033::Party;
    our @ISA=('Mediabot::Partyline');
    sub _write_runtime_status {1}
    package MB1033::Bot;
    sub gethChannelsNicksOnChan {Mediabot::Helpers::gethChannelsNicksOnChan(@_)}
}
my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
my $loop=IO::Async::Loop->new;
my $log=bless {lines=>[]},'MB1033::Log';
my $scheduler=Mediabot::Scheduler->new(loop=>$loop,logger=>$log);
my $native=sub {};$scheduler->add(name=>'ordinary.job',interval=>600,cb=>$native);
my $bot=bless {loop=>$loop,scheduler=>$scheduler,logger=>$log,
    channels=>{'#test'=>Mediabot::Channel->new({id=>1,name=>'#Test',topic=>'Radio — été'}),
               '#other'=>Mediabot::Channel->new({id=>2,name=>'#Other'})},
    hChannelsNicks=>{'#Test'=>[map {sprintf('nick%02d',$_)} 1..45]}},'MB1033::Bot';
my $out=bless {text=>''},'MB1033::Out';
my $party=bless {bot=>$bot,loop=>$loop,users=>{},streams=>{}},'MB1033::Party';
sub reset_1406 {
    $party->{users}{10}={authenticated=>1,level=>0,login=>'teuk'};
    $party->{streams}{10}=$out;$out->{text}='';
}
sub line_1406 {
    my ($line)=@_;$out->{text}='';$party->{users}{10}{rate_window}=0;
    $party->_handle_line($out,10,$line);return $out->{text};
}
sub watch_1406 {
    line_1406('watch 5 status');return $party->{users}{10}{shell_watch};
}
sub task_count_1406 {my @names=$scheduler->task_names;return scalar @names}
reset_1406();line_1406('.command #test');
like(line_1406('next'),qr/No listing yet/,'navigation without a listing gives actionable guidance');
line_1406('who | sort -r');
like(line_1406('next'),qr/nick25.*nick06.*page 2\/3/s,'next preserves sort and chooses the second live page');
like(line_1406('next'),qr/nick05.*nick01.*page 3\/3/s,'next reaches the final partial page');
like(line_1406('prev'),qr/nick25.*nick06.*page 2\/3/s,'prev retains the original filtered command');
push @{$bot->{hChannelsNicks}{'#Test'}},'nick46';
like(line_1406('refresh'),qr/nick26.*nick07.*46 entry/s,'refresh reruns the current live page rather than caching stale rows');
line_1406('use #Other');like(line_1406('next'),qr/Listing context changed/,'pagination cannot move silently into another channel');
line_1406('use #Test');line_1406('who');line_1406('cd workers');
like(line_1406('next'),qr/Listing context changed/,'pagination also binds its working directory');
line_1406('cd /');line_1406('ls /schedulers');
like(line_1406('refresh'),qr/ordinary.job/,'resource-directory listing refresh uses its canonical ps query');
is($scheduler->registration_id('ordinary.job',$native),$scheduler->task_info('ordinary.job')->{task_id},
    'scheduler proves exact callback registration identity without exposing callbacks');
is($scheduler->registration_id('ordinary.job',sub {}),undef,'same-name lookup with a foreign callback grants no identity');
like(line_1406('watch 5 kill s1'),qr/Usage: watch/,'watch refuses mutations before creating a schedule');
like(line_1406('watch 5 diagnose'),qr/Usage: watch/,'watch refuses recurring SQL/provider diagnostics');
like(line_1406('watch 1 status'),qr/Usage: watch/,'watch has a hard lower refresh interval');
is(task_count_1406(),1,'invalid watches leave unrelated tasks unchanged');
my $watch=watch_1406();
ok($watch && $scheduler->task_info($watch->{name})->{started},'valid cached observation registers with the native scheduler');
like($out->{text},qr/Watch every 5s.*Runtime observation/s,'watch displays a validated initial observation immediately');
line_1406('');ok(!$party->{users}{10}{shell_watch} && !defined($scheduler->task_info($watch->{name})),
    'Enter revokes output and removes only its owned registration');
$out->{text}='';$watch->_tick;is($out->{text},'','retained late watch cannot emit after interruption');
$watch=watch_1406();line_1406('watch off');
is(scalar(()=$out->{text}=~/Watch output stopped/g),1,'watch off acknowledges cancellation once');
$watch=watch_1406();$party->{users}{10}{rate_window}=CORE::time();$party->{users}{10}{rate_count}=10;
$out->{text}='';$party->_handle_line($out,10,'pwd');
ok(!$party->{users}{10}{shell_watch} && $out->{text}=~/Rate limit exceeded/,
    'even rate-limited input cancels a watch before command dispatch');
$watch=watch_1406();$party->{users}{10}{level}=2;$out->{text}='';$watch->_tick;
ok(!$party->{users}{10}{shell_watch} && $out->{text} eq '', 'role downgrade stops observation without further output');
$party->{users}{10}{level}=0;
$watch=watch_1406();$party->{users}{10}{command_shell}{channel_id}=9;$out->{text}='';$watch->_tick;
ok(!$party->{users}{10}{shell_watch} && $out->{text} eq '', 'changed context identity revokes asynchronous output');
line_1406('use #Test');
$watch=watch_1406();$watch->{expires_at}=time-1;$out->{text}='';$watch->_tick;
like($out->{text},qr/Watch expired/,'deadline expires and removes the observation');
ok(!defined($scheduler->task_info($watch->{name})),'deadline leaves no owned native schedule');
$watch=watch_1406();$watch->{remaining}=0;$watch->_tick;
ok(!$party->{users}{10}{shell_watch},'refresh-count budget independently bounds a backward wall-clock jump');
$watch=watch_1406();my $old=$party->{users}{10};reset_1406();$out->{text}='';$watch->_tick;
ok(!exists($party->{users}{10}{shell_watch}) && $out->{text} eq '' && !defined($old->{shell_watch}),
    'a reused fd never receives a previous session observation');
line_1406('.command #Test');
my $payload=bless {},'MB1033::Payload';my $weak_payload=$payload;weaken($weak_payload);
$watch=Mediabot::Partyline::ShellWatch->start($party,10,$out,interval=>5,
    render=>sub {my ($captured)=@_;return sub {$captured?'frame':'missing'}}->($payload));
undef $payload;
$party->_close_session(10);$watch->_tick;
ok(!exists($party->{users}{10}) && !defined($scheduler->task_info($watch->{name})) && !defined($weak_payload),
    'native session close revokes the timer and releases the captured renderer payload');
reset_1406();line_1406('.command');
$watch=Mediabot::Partyline::ShellWatch->start($party,10,$out,interval=>5,render=>sub {die 'PRIVATE_OBSERVATION_ERROR'});
$out->{text}='';$watch->_tick;
ok($out->{text}=~/observation unavailable/ && $out->{text}!~/PRIVATE/ && !$party->{users}{10}{shell_watch},
    'failed refresh is redacted and tears down its scheduler resource');
$watch=Mediabot::Partyline::ShellWatch->start($party,10,$out,interval=>5,render=>sub {'x'x16385});
$watch->_tick;ok(!$party->{users}{10}{shell_watch},'output frame size is bounded even for a foreign internal renderer');
$watch=Mediabot::Partyline::ShellWatch->start($party,10,$out,interval=>5,render=>sub {
    $party->{users}{10}{command_shell}={%{$party->{users}{10}{command_shell}}};return 'PRIVATE_LATE_FRAME';
});
$out->{text}='';$watch->_tick;
ok($out->{text} eq '' && !$party->{users}{10}{shell_watch},
    'a renderer reentering and replacing shell state cannot publish its late frame');
$watch=watch_1406();$out->{broken}=1;$watch->_tick;$out->{broken}=0;
ok(!$party->{users}{10}{shell_watch},'failed stream write stops future refreshes');
$log->{hook}=sub {
    return unless $_[0]=~/registered 'partyline\.shell\.watch\./;
    delete $log->{hook};$party->_close_session(10);
};
line_1406('watch 5 status');
ok(!exists($party->{users}{10}) && task_count_1406()==1,
    'session close reentered during registration cannot leave an active watch behind');
reset_1406();line_1406('.command');
my ($replacement,$foreign);$foreign=sub {};
$log->{hook}=sub {
    return unless $_[0]=~/registered '(partyline\.shell\.watch\.[0-9]+)'/;
    $replacement=$1;delete $log->{hook};$scheduler->remove($replacement);
    $scheduler->add(name=>$replacement,interval=>600,cb=>$foreign,autostart=>1);
};
line_1406('watch 5 status');
ok(defined($scheduler->registration_id($replacement,$foreign)) && !$party->{users}{10}{shell_watch},
    'setup refuses a replaced registration without removing the foreign successor');
$scheduler->remove($replacement);
{
    my $original=Mediabot::Scheduler->can('start');
    no warnings 'redefine';local *Mediabot::Scheduler::start=sub {
        return 0 if $_[1]=~/\Apartyline\.shell\.watch\./;return $original->(@_);
    };
    line_1406('watch 5 status');
    ok(!$party->{users}{10}{shell_watch} && task_count_1406()==1,
        'failed native start rolls back the exact new registration');
}
$watch=watch_1406();
{
    no warnings 'redefine';local *Mediabot::Scheduler::remove=sub {0};
    line_1406('');$out->{text}='';$watch->_tick;
    ok($out->{text} eq '' && !$party->{users}{10}{shell_watch}
        && grep(/cleanup incomplete/,@{$log->{lines}}),
        'native removal failure still revokes output and reports incomplete cleanup privately');
}
$scheduler->remove($watch->{name});
line_1406('use #Test');my $saved=$bot->{hChannelsNicks}{'#Test'};
$bot->{hChannelsNicks}{'#Test'}=[map {$_ . ('x'x1000)} 1..20];
like(line_1406('watch 5 who'),qr/Watch frame exceeds/,'oversized initial observation fails before registering a refresh');
ok(!$party->{users}{10}{shell_watch} && task_count_1406()==1,'oversized initial frame leaves no watch behind');
$bot->{hChannelsNicks}{'#Test'}=$saved;

# A real native timer tick over the real UTF-8 stream, with a live heartbeat.
socketpair(my $handle,my $peer,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
my $stream=IO::Async::Stream->new(handle=>$handle,encoding=>'Mediabot-Partyline-Wire',on_read=>sub {0});
$loop->add($stream);$party->{streams}{10}=$stream;
$party->{users}{10}{rate_window}=0;$party->_handle_line($stream,10,'watch 5 topic');
my $ticks=0;$scheduler->add(name=>'test.heartbeat',interval=>1,cb=>sub {$ticks++},autostart=>1);
my $wire='';my $end=time+6.5;my $select=IO::Select->new($peer);
while (time<$end && $wire!~/\[Watch; any input/) {
    $loop->loop_once(.02);
    while ($select->can_read(0)) {my $n=sysread($peer,my $chunk,65536);last unless $n;$wire.=$chunk}
}
ok($wire=~/\[Watch; any input stops refresh\]/ && $ticks>=4 && index($wire,encode('UTF-8','Radio — été'))>=0,
    'real native periodic refresh reaches the wire while the event-loop heartbeat continues');
$party->_close_session(10);$scheduler->remove('test.heartbeat');$stream->close_now;close $peer;
is(task_count_1406(),1,'disconnect cleans up the live timer and preserves the ordinary schedule');
is_deeply(\@warnings,[],'navigation, watch setup and teardown are warning-free');
done_testing;
