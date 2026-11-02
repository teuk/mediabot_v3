# Native callback timing, clock changes and both scheduler dispatch paths.
use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::Scheduler;
use Mediabot::Metrics;
{
    package MB1072::Log;
    sub log {push @{$_[0]{rows}},[$_[1],$_[2]];1}
    package MB1072::BrokenMetrics;
    sub observe {die "metrics unavailable\n"}
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
my $loop=IO::Async::Loop->really_new;
my $logger=bless {rows=>[]},'MB1072::Log';
my $metrics=Mediabot::Metrics->new(enabled=>1);
my $s=Mediabot::Scheduler->new(loop=>$loop,logger=>$logger);
ok($s->set_metrics($metrics) && $s->{metrics}==$metrics,
    'native scheduler attaches the metrics projection');
$s->add(name=>'clock',interval=>3600,cb=>sub {});
my ($wall,$mono)=(10000,1000);
my $native_interval=\&Time::HiRes::tv_interval;
my $native_clock=\&Time::HiRes::clock_gettime;
my $stamp=sub {my $n=int($wall);[$n,int(($wall-$n)*1_000_000)]};
sub timed_749 {
    my ($cb)=@_;
    no warnings 'redefine';
    # Change only the observation clocks during the native callback. Timer
    # setup, loop dispatch and civil dates retain their actual clocks.
    local *Time::HiRes::gettimeofday=sub {@{$stamp->()}};
    local *Time::HiRes::tv_interval=sub {$native_interval->($_[0],$stamp->())};
    local *Time::HiRes::clock_gettime=sub {
        $_[0]==Time::HiRes::CLOCK_MONOTONIC() ? $mono : $native_clock->(@_)
    };
    return $cb->();
}
sub slow_749 {return [map {$_->[1]} grep {$_->[0]==3 && $_->[1]=~/^SLOW SCHEDULER:/} @{$logger->{rows}}]}
for my $step (
    [-3600,.25,.25,.25,.25,[]],
    [7200,.125,.125,.375,.25,[]],
    [0,1.25,1.25,1.625,1.25,["SLOW SCHEDULER: task 'clock' took 1.25s"]],
) {
    timed_749(sub {$s->_run_task_callback('clock',sub {$wall+=$step->[0];$mono+=$step->[1];0})});
    my $i=$s->task_info('clock');
    is_deeply([@$i{qw(last_duration_s total_duration_s max_duration_s callback_exceptions)},slow_749()],
        [@$step[2,3,4],0,$step->[5]],
        "wall adjustment $step->[0]s: actual elapsed duration drives profile and slow warnings");
}
my $before=CORE::time();
timed_749(sub {$s->_run_task_callback('clock',sub {$wall-=7200;$mono+=.5;die "known\nfailure\n"})});
my $i=$s->task_info('clock');
is_deeply([@$i{qw(last_duration_s total_duration_s max_duration_s callback_exceptions)},
    $i->{last_exception_at}>=$before && $i->{last_exception_at}<=CORE::time()?1:0,
    [map {$_->[1]} grep {$_->[0]==1} @{$logger->{rows}}]],
    [.5,2.125,1.25,1,1,["Scheduler: task 'clock' error: known failure "]],
    'exceptions still record measured cost, existing diagnostic text and a civil timestamp');
my $exposition=$metrics->render_prometheus;
ok($exposition=~/^mediabot_scheduler_tick_seconds_sum\{task="clock"\} 2\.125$/m
    && $exposition=~/^mediabot_scheduler_tick_seconds_count\{task="clock"\} 4$/m
    && $exposition=~/^mediabot_scheduler_tick_seconds_bucket\{task="clock",le="0\.25"\} 2$/m,
    'real Prometheus histogram exposes all four nonnegative samples in the correct buckets');
my @optional;
for my $projection (undef,bless({},'MB1072::BrokenMetrics')) {
    my $plain=Mediabot::Scheduler->new(loop=>$loop);
    $plain->set_metrics($projection) if $projection;
    $plain->add(name=>'optional',interval=>3600,cb=>sub {});
    my $ok=eval {timed_749(sub {$plain->_run_task_callback('optional',sub {$mono+=.125;0})});1};
    push @optional,[$ok?1:0,$plain->task_info('optional')->{last_duration_s}];
    $plain->remove('optional');
}
is_deeply(\@optional,[[1,.125],[1,.125]],
    'no metrics and a failing projection preserve successful callback execution and duration');
for my $mode (qw(periodic calendar)) {
    my $runs=0;
    $s->add(name=>$mode,interval=>3600,
        ($mode eq 'calendar' ? (next_run_cb=>sub {CORE::time()+60}) : ()),
        cb=>sub {$runs++;$wall+=7200;$mono+=.375},autostart=>1);
    my $timer=$s->{_tasks}{$mode}{timer};
    timed_749(sub {$timer->invoke_event($mode eq 'calendar' ? 'on_expire' : 'on_tick')});
    my $state=$s->task_info($mode);
    my $hist=$metrics->get('mediabot_scheduler_tick_seconds',{task=>$mode});
    is_deeply([$runs,@$state{qw(ticks last_duration_s total_duration_s max_duration_s)},
        $hist->{count},$hist->{sum},
        $state->{start_time}>=$before && $state->{start_time}<=CORE::time()?1:0,
        $state->{last_tick}>=$before && $state->{last_tick}<=CORE::time()?1:0,
        $state->{next_run}>CORE::time()?1:0],
        [1,1,.375,.375,.375,1,.375,1,1,1],
        "$mode: native timer dispatch measures duration while retaining epoch dates and rearming");
    $s->remove($mode);
}
$s->remove('clock');
is_deeply(\@warnings,[],'native timing, metrics and cleanup are warning-free');
done_testing;
