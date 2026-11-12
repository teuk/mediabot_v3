use strict;
use warnings;
use Test::More;
use IO::Async::Loop::Poll;
use IO::Async::Timer::Countdown;
use IO::Select;
our $WAIT_FAULT_PID;
BEGIN {
    *CORE::GLOBAL::waitpid = sub {
        if (defined($WAIT_FAULT_PID) && $_[0] == $WAIT_FAULT_PID) { $! = 5; return -1 }
        return CORE::waitpid($_[0], $_[1]);
    };
}
use Mediabot::AsyncWorker;
use Time::HiRes ();
use POSIX qw(WNOHANG);
use Scalar::Util qw(refaddr);
use File::Temp qw(tempfile);
use JSON::PP ();
my %owned;
END {
 local $?;
 for my $pid (keys %owned) {
  my $seen=waitpid($pid,WNOHANG);
  if($seen==0){kill 'KILL',$pid;CORE::waitpid($pid,0)}
 }
}
{
 package MB1254::Loop;
 our @ISA=('IO::Async::Loop::Poll');
 sub watch_process {
  my($self,$pid,$cb)=@_;push @{$self->{retained}},[$pid,$cb];
  $self->SUPER::watch_process($pid,$cb);
 }
 sub remove {
  my($self,$obj)=@_;
  if(my $cb=delete $self->{on_remove}){$cb->()}
  $self->SUPER::remove($obj);
  die "injected removal failure\n" if delete $self->{fail_remove};
 }
}
sub launch {
 my($loop,$done)=@_;
 pipe(my $r,my $w) or die $!;
 my $worker=Mediabot::AsyncWorker->start(loop=>$loop,timeout=>60,term_grace=>60,force_grace=>60,
  child=>sub {close $r;$SIG{TERM}='IGNORE';syswrite($w,'R');close $w;
   my $end=Time::HiRes::time()+5;while(Time::HiRes::time()<$end){Time::HiRes::sleep(.01)};return {normal=>1}},
  on_done=>$done,on_progress=>sub {die 'unexpected progress'});
 die 'worker launch failed' unless $worker;
 $owned{$worker->pid}=1;close $w;
 die 'child readiness timeout' unless IO::Select->new($r)->can_read(2);
 my $byte;sysread($r,$byte,1);close $r;
 return $worker;
}
sub collected {
 my($w)=@_;my $pid=$w->pid;my $seen=waitpid($pid,WNOHANG);
 my $ok=$seen==-1 && $!{ECHILD};delete $owned{$pid} if $ok;return $ok;
}
my $loop=MB1254::Loop->new;
my @calls=(0,0,0);
my @workers=map {my $i=$_;launch($loop,sub {$calls[$i]++})} 0..2;
$workers[1]->cancel('pending');
$workers[2]->cancel('forced');
$workers[2]{force_timer}->invoke_event('on_expire');
is($calls[2],1,'forced result completed before exit');
is(scalar(Mediabot::AsyncWorker->active_workers($loop)),2,'logical registry excludes forced completion');
ok(exists $Mediabot::AsyncWorker::CHILDREN{$workers[2]{task_id}},'physical registry retains unconfirmed finalized child');
my @timers=grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers;
my $other=MB1254::Loop->new;my $other_calls=0;my $other_worker=launch($other,sub {$other_calls++});
my($refused,$refusal_callback)=(0,0);
$loop->{on_remove}=sub {
 $refused=!Mediabot::AsyncWorker->start(loop=>$loop,child=>sub {die 'must not fork'},on_done=>sub {$refusal_callback++});
};
my $begin=Time::HiRes::time();my $result=Mediabot::AsyncWorker->shutdown_loop($loop);
ok($result->{ok},'shutdown collects active, cancelled and finalized children');
ok(Time::HiRes::time()-$begin<2,'batch collection has a shared bounded wait');
ok($refused && !$refusal_callback,'reentrant submission refused without consumer callback');
ok(collected($_),'child already collected without loop iteration') for @workers;
is_deeply(\@calls,[0,0,1],'shutdown delivers no arbitrary result callback');
is(scalar(Mediabot::AsyncWorker->active_workers($loop)),0,'logical registry empty');
ok(!grep({exists $Mediabot::AsyncWorker::CHILDREN{$_->{task_id}}} @workers),'physical records removed after confirmation');
is(scalar(grep {$_->isa('IO::Async::Timer::Countdown') || $_->isa('IO::Async::Stream')} $loop->notifiers),0,'owned stream and timers removed');
$_->invoke_event('on_expire') for @timers;
$_->[1]->($_->[0],0) for @{$loop->{retained}};
is_deeply(\@calls,[0,0,1],'retained timer/process callbacks cannot deliver or signal again');
ok(Mediabot::AsyncWorker->shutdown_loop($loop)->{ok},'repeat shutdown harmless');
is(scalar(Mediabot::AsyncWorker->active_workers($other)),1,'different loop retains work');
ok(!$other_worker->is_done && !$other_calls,'different loop callbacks unchanged');
ok(Mediabot::AsyncWorker->shutdown_loop($other)->{ok} && collected($other_worker),'different loop can be retired separately');

# Reaped process with an undelivered pipe still needs callback retirement.
{
 my $l=MB1254::Loop->new;my $done=0;
 my $w=Mediabot::AsyncWorker->start(loop=>$l,timeout=>60,child=>sub {{ok=>1}},on_done=>sub {$done++});
 $owned{$w->pid}=1;$w->_remove_stream;
 my $until=Time::HiRes::time()+2;$l->loop_once(.01) while !$w->{child_done} && Time::HiRes::time()<$until;
 ok($w->{child_done} && !$w->is_done,'native watcher precedes withheld pipe EOF');
 ok(Mediabot::AsyncWorker->shutdown_loop($l)->{ok},'shutdown also revokes reaped but logically pending work');
 my $bytes='';$w->_consume_output(\$bytes,1,undef);
 is($done,0,'late EOF cannot publish after shutdown');ok(collected($w),'already reaped PID remains untouched');
}
# Wait errors retain ownership and must not be interpreted as ECHILD.
{
 my $l=MB1254::Loop->new;my $done=0;my $w=launch($l,sub {$done++});
 my $report;
 {local $WAIT_FAULT_PID=$w->pid;
  $report=Mediabot::AsyncWorker->shutdown_loop($l);}
 ok(!$report->{ok} && $report->{remaining}==1,'uncertain wait retains explicit incomplete result');
 ok(exists $Mediabot::AsyncWorker::CHILDREN{$w->{task_id}},'uncertain child remains owned for retry');
 ok(kill(0,$w->pid),'uncertain ownership does not signal child');
 ok(Mediabot::AsyncWorker->shutdown_loop($l)->{ok} && collected($w),'later confirmed collection recovers');
 is($done,0,'retry does not restore revoked callback');
}
{
 my $l=MB1254::Loop->new;my $done=0;my $w=launch($l,sub {$done++});
 $l->{fail_remove}=1;
 my $report=Mediabot::AsyncWorker->shutdown_loop($l);
 ok(!$report->{ok} && $report->{cleanup_errors}==1,'physical removal failure reported');
 ok(!$report->{remaining} && collected($w),'removal failure cannot skip process collection');
 is($done,0,'failed cleanup leaves consumer inert');
}
# Forked consumers cannot collect the original process owner's children.
{
 my $l=MB1254::Loop->new;my $w=launch($l,sub {});my @done;
 my $probe=Mediabot::AsyncWorker->start(loop=>$l,timeout=>2,child=>sub {Mediabot::AsyncWorker->shutdown_loop($l)},on_done=>sub {push @done,shift});
 $owned{$probe->pid}=1;my $until=Time::HiRes::time()+3;$l->loop_once(.01) while !@done && Time::HiRes::time()<$until;
 ok(@done && $done[0]{ok} && $done[0]{value}{remaining}==0,'inherited loop shutdown owns no parent children');
 ok(!$w->is_done,'parent worker stays live after child-side shutdown');collected($probe);
 ok(Mediabot::AsyncWorker->shutdown_loop($l)->{ok} && collected($w),'original owner still collects');
}
# Native success still delivers once and releases physical ownership.
{
 my $l=MB1254::Loop->new;my @done;
 my $w=Mediabot::AsyncWorker->start(loop=>$l,timeout=>2,child=>sub {{packet=>'normal'}},on_done=>sub {push @done,shift});
 $owned{$w->pid}=1;my $until=Time::HiRes::time()+3;$l->loop_once(.01) while !@done && Time::HiRes::time()<$until;
 is_deeply($done[0]{value},{packet=>'normal'},'normal fork/pipe contract preserved');
 is(scalar @done,1,'normal completion once');ok(collected($w),'normal watcher collected child');
 ok(!exists $Mediabot::AsyncWorker::CHILDREN{$w->{task_id}},'normal physical ownership released');
}

# A cleanup callback may re-enter shutdown on the same loop.
{
 my $l=MB1254::Loop->new;my $done=0;my $w=launch($l,sub {$done++});my $nested;
 $l->{on_remove}=sub {$nested=Mediabot::AsyncWorker->shutdown_loop($l)};
 my $outer=Mediabot::AsyncWorker->shutdown_loop($l);
 ok($outer->{ok} && $nested->{ok} && collected($w),'reentrant shutdown preserves confirmed collection');
 is($done,0,'reentrant cleanup cannot restore delivery');
}

# Native setup faults retain physical ownership even when start returns undef.
for my $stage (qw(stream_new timer_start watch)) {
 my $l=MB1254::Loop->new;my @done;my $w;my $pid;
 my $stream_new=IO::Async::Stream->can('new');my $timer_start=IO::Async::Timer::Countdown->can('start');
 my $watch=$l->can('watch_process');
 {
  no warnings qw(redefine once);
  local *IO::Async::Stream::new=sub {die "setup stream fault\n" if $stage eq 'stream_new';$stream_new->(@_)};
  local *IO::Async::Timer::Countdown::start=sub {die "setup timer fault\n" if $stage eq 'timer_start';$timer_start->(@_)};
  local *MB1254::Loop::watch_process=sub {
   $pid=$_[1];$owned{$pid}=1;
   die "watch rejected\n" if $stage eq 'watch';$watch->(@_);
  };
  $w=Mediabot::AsyncWorker->start(loop=>$l,child=>sub {sleep 3;{}},on_done=>sub {push @done,shift});
 }
 ok(!$w && @done==1 && $done[0]{error} eq 'worker_setup',"$stage: setup failure preserves consumer contract");
 my $report=Mediabot::AsyncWorker->shutdown_loop($l);
 ok($report->{ok},"$stage: final collection handles failed startup");
 my $seen=waitpid($pid,WNOHANG);ok($seen==-1 && $!{ECHILD},"$stage: child already collected");delete $owned{$pid};
 is(scalar @done,1,"$stage: shutdown does not repeat failed result");
}
# Retirement during notifier setup must not publish or restart a successor arm.
{
 my $l=MB1254::Loop->new;my $add=$l->can('add');my($pid,$done)=(undef,0);my $w;
 my $watch=$l->can('watch_process');
 {
  no warnings qw(redefine once);
  local *MB1254::Loop::watch_process=sub {$pid=$_[1];$owned{$pid}=1;$watch->(@_)};
  local *MB1254::Loop::add=sub {
   my($self,$obj)=@_;my $ret=$add->(@_);
   Mediabot::AsyncWorker->shutdown_loop($self) if $obj->isa('IO::Async::Timer::Countdown');
   return $ret;
  };
  $w=Mediabot::AsyncWorker->start(loop=>$l,child=>sub {sleep 3;{}},on_done=>sub {$done++});
 }
 ok(!$w && !$done,'shutdown during timer add cannot return a live worker or call consumer');
 my $seen=waitpid($pid,WNOHANG);ok($seen==-1 && $!{ECHILD},'setup-time shutdown collects its child');delete $owned{$pid};
 is(scalar(grep {$_->isa('IO::Async::Timer::Countdown') || $_->isa('IO::Async::Stream')} $l->notifiers),0,'setup-time shutdown leaves no worker notifier');
}

# Import the native main module with unrelated subsystem dependencies stubbed.
# No source-body extraction: clean_and_exit itself is executed in a child.
BEGIN {
 my @mods=qw(Auth User Channel Channel::NicklistTimers Conf NetworkStats XAuth Log Context Command CommandRegistry BuiltinCommandCatalog CommandAsync EventBus AI::ConversationRuntimeState PluginManager ScriptRunner ScriptActionRunner Hailo Quotes RSS::Commands RandomQuote::Commands VDM::Runtime DTC::Commands LoginCommands Helpers ProcessLock ChannelCommands UserCommands External External::Wikipedia External::DuckDuckGo DCC DBCommands AdminCommands);
 my @names=((map {'Mediabot::'.$_} @mods),qw(Config::Simple DBI String::IRC DateTime DateTime::TimeZone URL::Encode Hailo JSON::MaybeXS IO::Socket::SSL HTML::Tree HTML::Entities URI::Escape));
 for my $name (@names){
  (my $path=$name)=~s!::!/!g; $INC{$path.'.pm'}=__FILE__;
  no strict 'refs'; *{$name.'::import'}=sub {my $caller=caller; for my $symbol (@_[1..$#_]){ next unless $symbol=~/^\w+$/; *{$caller.'::'.$symbol}=sub {die 'unused stub called'}; }};
 }
}
require Mediabot::Mediabot;

{
 package MB1254::Bot;
 our @ISA=('Mediabot');
 sub save_hailo_brains {push @{$_[0]{events}},'save';1}
 sub releasePidFile {push @{$_[0]{events}},'pid';1}
 package MB1254::Logger;
 sub log {push @{$_[0]{events}},$_[2] if $_[2] =~ /incomplete/}
 sub flush {push @{$_[0]{events}},'flush';open my $fh,'>',$_[0]{path} or die $!;
  print $fh JSON::PP->new->encode($_[0]{events});close $fh}
 package MB1254::DB;
 sub disconnect {
  my($self)=@_;my $pid=$self->{pid};my $seen=CORE::waitpid($pid,POSIX::WNOHANG());
  push @{$self->{events}},($seen==-1 && $!{ECHILD} ? 'collected-before-db' : 'uncollected-before-db');
  if($seen==0){kill 'KILL',$pid;CORE::waitpid($pid,0)}
  push @{$self->{events}},'db';$self->{Active}=0;
 }
}
for my $fault (0,1) {
 my($fh,$path)=tempfile();close $fh;
 my $parent=fork();die $! unless defined $parent;
 if(!$parent){
  Test::More->builder->no_ending(1);
  %owned=();my $l=MB1254::Loop->new;my @events;
  my $w=launch($l,sub {push @events,'FORBIDDEN-CALLBACK'});
  my $log=bless {events=>\@events,path=>$path},'MB1254::Logger';
  my $bot=bless {loop=>$l,events=>\@events,logger=>$log,
   dbh=>bless({events=>\@events,pid=>$w->pid,Active=>1},'MB1254::DB')},'MB1254::Bot';
  if($fault){local $WAIT_FAULT_PID=$w->pid;$bot->clean_and_exit(17)}
  else{$bot->clean_and_exit(17)}
  POSIX::_exit(99);
 }
 waitpid($parent,0);is($? >> 8,17,'native clean_and_exit retains requested process exit code');
 open my $read,'<',$path or die $!;my $text=do{local $/;<$read>};close $read;unlink $path;
 my $events=eval {JSON::PP->new->decode($text)};
 is_deeply($events,$fault ? ['AsyncWorker final cleanup incomplete','save','uncollected-before-db','db','pid','flush']
  : ['save','collected-before-db','db','pid','flush'],
  $fault ? 'uncertain collection is diagnosed; final saves and DB cleanup still run' : 'native exit collects child before DB teardown without consumer callbacks');
}
done_testing;
