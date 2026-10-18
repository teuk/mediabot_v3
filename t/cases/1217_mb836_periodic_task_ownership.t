use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);
use Time::HiRes qw(time);
use IO::Async::Loop;
use Mediabot::Scheduler;

my $loop=IO::Async::Loop->new;
my $scheduler=Mediabot::Scheduler->new(loop=>$loop);
my $runs=0;
$scheduler->add(name=>'periodic',interval=>3600,first_interval=>0,
    cb=>sub{$runs++},autostart=>1);
my $timer=$scheduler->{_tasks}{periodic}{timer};
my $deadline=time()+1;
$loop->loop_once(0.01) while !$runs && time()<$deadline;
is($runs,1,'actual periodic timer executes the running task');
is($scheduler->task_info('periodic')->{ticks},1,'real tick updates task statistics');
ok($scheduler->stop('periodic'),'periodic task stops');
$timer->invoke_event('on_tick');
is($runs,1,'a retained tick callback cannot execute a stopped task');
is($scheduler->task_info('periodic')->{ticks},1,'ignored callback cannot inflate statistics');
ok($scheduler->start('periodic'),'same registered task can start again');
$timer->invoke_event('on_tick');
is($runs,2,'explicit start restores normal callback delivery');

my $weak_task=$scheduler->{_tasks}{periodic};weaken($weak_task);
ok($scheduler->remove('periodic'),'running task is removed');
ok(!defined($weak_task),'a retained timer does not keep its removed task alive');
my $replacement_runs=0;
$scheduler->add(name=>'periodic',interval=>3600,cb=>sub{$replacement_runs++},autostart=>1);
$timer->invoke_event('on_tick');
is($runs,2,'removed timer cannot replay its original callback');
is($replacement_runs,0,'old timer cannot execute a same-name replacement task');
my $replacement=$scheduler->{_tasks}{periodic}{timer};
$replacement->invoke_event('on_tick');
is($replacement_runs,1,'replacement timer executes its own callback');
$scheduler->remove('periodic');
my $weak_scheduler=$scheduler;weaken($weak_scheduler);undef $scheduler;
ok(!defined($weak_scheduler),'retained timer callbacks do not keep an empty scheduler alive');
ok(eval{$timer->invoke_event('on_tick');$replacement->invoke_event('on_tick');1},
    'late callbacks after scheduler destruction are harmless');

# Repeated task registration/removal must not accumulate the callback cycles.
my @weak;
my $s=Mediabot::Scheduler->new(loop=>$loop);
for my $n (1..20) {
    $s->add(name=>"temporary$n",interval=>3600,cb=>sub{},autostart=>1);
    my $task=$s->{_tasks}{"temporary$n"};my $t=$task->{timer};
    push @weak,$task,$t;weaken($weak[-1]);weaken($weak[-2]);
    $s->remove("temporary$n");
}
is(scalar(grep{defined}@weak),0,'twenty removed tasks and timers are reclaimable');

my $self_remove_runs=0;
$s->add(name=>'self_remove',interval=>3600,cb=>sub{
    $self_remove_runs++;$s->remove('self_remove');
},autostart=>1);
my $self_timer=$s->{_tasks}{self_remove}{timer};
$self_timer->invoke_event('on_tick');$self_timer->invoke_event('on_tick');
is($self_remove_runs,1,'self-removing periodic callback cannot replay from a retained timer');
ok(!defined($s->task_info('self_remove')),'self-removal leaves no registered task');
done_testing;
