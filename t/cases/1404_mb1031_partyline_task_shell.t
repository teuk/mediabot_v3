use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Loop;
use IO::Async::Loop::Poll;
use Time::HiRes qw(time sleep);
use Scalar::Util qw(weaken);
use POSIX qw(WNOHANG);
use Mediabot::Partyline::Dispatcher ();
use Mediabot::Partyline::TaskConsole ();
use Mediabot::Scheduler;
use Mediabot::AsyncWorker;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
 package MB1031::Out;sub write {$_[0]{text}.=$_[1];1}
 package MB1031::Log;sub log {1}
 package MB1031::Party;
 sub _display_nick {'teuk'}
 sub _broadcast {push @{$_[0]{broadcast}},$_[1]}
 sub _broadcast_chat {push @{$_[0]{chat}},$_[2]}
}
my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
my $loop=IO::Async::Loop->new;my $other=IO::Async::Loop::Poll->new;
my $scheduler=Mediabot::Scheduler->new(loop=>$loop);
$scheduler->add(name=>'radio.refresh',interval=>3600,cb=>sub {sleep 0.003});
my $p=bless {bot=>{loop=>$loop,scheduler=>$scheduler,logger=>bless({},'MB1031::Log')},
 users=>{one=>{authenticated=>1,level=>0,login=>'teuk'},two=>{authenticated=>1,level=>1,login=>'other'}},
 chat=>[],broadcast=>[]},'MB1031::Party';
my $out=bless {text=>''},'MB1031::Out';
sub line_1404 {
 my ($line,$who)=@_;$who//='one';$out->{text}='';$p->{users}{$who}{rate_window}=0;
 Mediabot::Partyline::Dispatcher::_handle_line($p,$out,$who,$line);return $out->{text};
}
like(line_1404('.command'),qr/internal shell.*mediabot:\/> /s,'authenticated session enters a private interactive shell with help and prompt');
line_1404('cd workers');my $pwd=line_1404('pwd');
is_deeply([$pwd,$p->{users}{two}{command_mode}//0,scalar @{$p->{chat}},scalar @{$p->{broadcast}}],
 ["/workers\r\nmediabot:/workers> ",0,0,0],'working directory, mode and command output are session-local and never enter chat');
like(line_1404('cd ../schedulers'),qr{mediabot:/schedulers> },'relative resource paths normalize dot and parent segments');
like(line_1404('ls'),qr/s1.*radio\.refresh/s,'scheduler listing uses its owned logical handle');
line_1404('ps|grep -i "RADIO"|head 1');my $listed=$out->{text};
like($listed,qr/s1.*radio\.refresh.*1 task\(s\)/s,'bounded read pipelines accept quotes and attached pipes with literal grep/head');
my $before=$scheduler->task_info('radio.refresh')->{started};
like(line_1404('start s1 | grep radio'),qr/Filters apply only/,'invalid action pipeline is rejected before any mutation');
is($scheduler->task_info('radio.refresh')->{started},$before,'pipeline validation cannot accidentally start a schedule');
line_1404('start s1');line_1404('kill s1');
ok(!$scheduler->task_info('radio.refresh')->{started},'kill on a scheduler disables future ticks using the existing owner');
$scheduler->_run_task_callback('radio.refresh',sub {sleep 0.003});
my $info=$scheduler->task_info('radio.refresh');
ok($info->{last_duration_s}>0 && $info->{max_duration_s}>0 && $info->{total_duration_s}>0,
 'scheduler snapshots expose real callback durations');
$scheduler->remove('radio.refresh');$scheduler->add(name=>'radio.refresh',interval=>3600,cb=>sub {});
like(line_1404('kill s1'),qr/no longer exists/,'a stale scheduler ID cannot stop a same-name replacement');
like(line_1404('show s2'),qr/Callback last:/,'new registration has a new inspectable ID and timing fields');
like(line_1404('kill /workers/s2'),qr/task-id/,'resource paths cannot silently target another resource kind');
like(line_1404('complete ki'),qr/kill/,'textual completion discovers built-in commands');
line_1404('pwd');like(line_1404('!!'),qr{/schedulers},'history replay retains the original shell command');
my $history=line_1404('history');like($history,qr/\d+\s+pwd/,'history is numbered and session-local');
$p->{users}{one}{rate_window}=CORE::time();$p->{users}{one}{rate_count}=10;$out->{text}='';
Mediabot::Partyline::Dispatcher::_handle_line($p,$out,'one','pwd');
like($out->{text},qr/Rate limit exceeded/,'shell mode retains the partyline rate limit before command execution');
my $jobs_before=scalar Mediabot::AsyncWorker->active_workers($loop);
like(line_1404('kill 12345'),qr/task-id/,'raw OS PIDs are not executable task handles');
is(scalar(Mediabot::AsyncWorker->active_workers($loop)),$jobs_before,'invalid kill leaves the worker registry unchanged');
line_1404('exit');line_1404('hello');
is_deeply([$p->{users}{one}{command_mode}//0,$p->{chat}], [0,['hello']], 'exit returns to ordinary chat without disconnecting');
line_1404('.command');$p->{users}{one}{level}=2;
like(line_1404('kill s2'),qr/Access denied/,'authorization is rechecked after entry and revoked on downgrade');
ok(!$p->{users}{one}{command_mode},'downgrade exits privileged command mode');
$p->{users}{one}{level}=0;line_1404('.command');
{
 no warnings 'redefine';local *Mediabot::Scheduler::stop=sub {die "private backend detail\n"};
 my $s=line_1404('stop s2');unlike($s,qr/private backend/,'backend exceptions cannot be presented as trusted usage errors');
}
{
 my $saved=$p->{users}{one};
 no warnings 'redefine';local *Mediabot::Scheduler::stop=sub {delete $p->{users}{one};1};
 line_1404('stop s2');ok(!exists($p->{users}{one}),
  'an action closing its caller session cannot recreate that session while auditing');
 $p->{users}{one}=$saved;
}
my @done;
my $w=Mediabot::AsyncWorker->start(loop=>$loop,label=>'slow radio lookup',timeout=>3,term_grace=>0.05,
 child=>sub {$SIG{TERM}='IGNORE';sleep 5;return 'late'},on_done=>sub {push @done,shift});
my ($row)=Mediabot::AsyncWorker->active_workers($loop);my $id=$row->{id};
is_deeply([scalar(Mediabot::AsyncWorker->active_workers($other)),Mediabot::AsyncWorker->cancel_worker($other,$id)],
 [0,0],'workers are visible and cancellable only through their owning event loop');
$row->{label}='mutated';my ($actual)=Mediabot::AsyncWorker->active_workers($loop);
is($actual->{label},'slow radio lookup','operator snapshots cannot mutate live worker state');
like(line_1404("show $id"),qr/PID:.*timeout:/,'live async worker exposes elapsed time, deadline and PID as information');
my @probe;
my $inspector=Mediabot::AsyncWorker->start(loop=>$loop,timeout=>2,child=>sub {
 return [scalar(Mediabot::AsyncWorker->active_workers($loop)),
  Mediabot::AsyncWorker->cancel_worker($loop,$id)];
},on_done=>sub {push @probe,shift});
my $probe_end=time+2;$loop->loop_once(0.01) while !@probe && time<$probe_end;
is_deeply($probe[0]{value},[0,0],'forked child cannot observe or cancel inherited parent registrations');
my $end=time+0.1;$loop->loop_once(0.01) while time<$end;
like(line_1404("kill $id"),qr/Cancellation requested/,'worker kill requests cancellation through its owned lifecycle');
$end=time+3;$loop->loop_once(0.02) while !@done && time<$end;
$loop->loop_once(0.01) for 1..3;
is_deeply([scalar(@done),$done[0]{cancelled},$done[0]{kill_sent},waitpid($w->pid,WNOHANG),
 scalar(Mediabot::AsyncWorker->active_workers($loop)),Mediabot::AsyncWorker->cancel_worker($loop,$id)],
 [1,1,1,-1,0,0],'resistant child is terminated/reaped once, disappears from ps and cannot be killed through its stale ID');
is_deeply(\@warnings,[],'shell, snapshots and cancellation are free from warnings');
done_testing;
