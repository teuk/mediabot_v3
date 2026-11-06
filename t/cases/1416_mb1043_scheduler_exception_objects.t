use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Scalar::Util qw(refaddr);
use Time::HiRes ();
use Mediabot::Scheduler;

our ($bool_calls, $string_calls) = (0,0);
{
    package MB1043::StringError;
    use overload 'bool' => sub {1}, '""' => sub {$main::string_calls++; die "exception formatter failed\n"}, fallback => 1;
    package MB1043::BoolError;
    use overload 'bool' => sub {$main::bool_calls++; die "exception truth test failed\n"},
        '""' => sub {$main::string_calls++; die "exception formatter failed\n"}, fallback => 1;
    package MB1043::FalseError;
    use overload 'bool' => sub {$main::bool_calls++; 0}, '""' => sub {$main::string_calls++; '0'}, fallback => 1;
    package MB1043::Logger;
    sub log {push @{$_[0]{rows}}, [$_[1],$_[2]]; 1}
    package MB1043::Metrics;
    sub observe {push @{$_[0]{rows}}, [@_[1..$#_]]; 1}
}
my @warnings;
local $SIG{__WARN__} = sub {push @warnings, @_};
my $native_new = IO::Async::Timer::Countdown->can('new');
no warnings qw(redefine once);
# Calendar resolver still returns a real future epoch. Shorten only its native
# countdown delay, so two real occurrences run without a wall-clock wait.
local *IO::Async::Timer::Countdown::new = sub {
    my ($class, %args) = @_; $args{delay}=0; $native_new->($class,%args);
};
sub exercise_1416 {
    my ($mode, $error, %opts) = @_;
    my $loop = IO::Async::Loop->really_new;
    my $logger = $opts{no_logger} ? undef : bless({rows=>[]},'MB1043::Logger');
    my $metrics = $opts{no_metrics} ? undef : bless({rows=>[]},'MB1043::Metrics');
    my $s = Mediabot::Scheduler->new(loop=>$loop, logger=>$logger);
    $s->set_metrics($metrics) if $metrics;
    my ($calls,$healthy,$escaped,$successor)=(0,0,0,0);
    my $old_id;
    $bool_calls=$string_calls=0;
    $s->add(name=>'subject', interval=>3600,
        ($mode eq 'calendar' ? (next_run_cb=>sub {time()+60}) : (first_interval=>0)),
        cb=>sub {
            $calls++;
            if ($opts{replace}) {
                $s->remove('subject');
                $s->add(name=>'subject',interval=>3600,cb=>sub {},autostart=>1);
                $successor=$s->task_info('subject')->{task_id};
            } elsif ($mode eq 'calendar' && $calls==2) {
                $s->stop('subject');
                return 0;
            }
            die $error if defined $error;
            return 0; # A false callback result is not an exception.
        }, autostart=>1);
    $old_id=$s->task_info('subject')->{task_id};
    $s->add(name=>'healthy',interval=>3600,first_interval=>0,
        cb=>sub {$healthy++; $s->stop('healthy')},autostart=>1);
    my $wanted=$mode eq 'calendar' && !$opts{replace} ? 2 : 1;
    my $deadline=Time::HiRes::time()+1;
    while (($calls<$wanted || !$healthy) && Time::HiRes::time()<$deadline) {
        my $ok=eval {$loop->loop_once(.005);1};
        unless ($ok) {$escaped=1;last} # Never coerce the caught object in the test either.
    }
    my $info=$s->task_info('subject');
    my @errors=$logger ? map {$_->[1]} grep {$_->[0]==1} @{$logger->{rows}} : ();
    my @observed=$metrics ? grep {$_->[0] eq 'mediabot_scheduler_tick_seconds'
        && $_->[2]{task} eq 'subject' && $_->[1]>=0} @{$metrics->{rows}} : ();
    my $coercions=[$bool_calls,$string_calls];
    $s->remove($_) for $s->task_names;
    my @notifiers=$loop->notifiers;
    return {escaped=>$escaped,calls=>$calls,healthy=>$healthy,info=>$info,
        errors=>\@errors,observations=>scalar(@observed),coercions=>$coercions,
        notifiers=>scalar(@notifiers),old_id=>$old_id,successor=>$successor};
}
for my $mode (qw(periodic calendar)) {
    for my $class (qw(MB1043::StringError MB1043::BoolError MB1043::FalseError)) {
        my $r=exercise_1416($mode,bless({private_payload=>'fixture'},$class));
        my $ticks=$mode eq 'calendar' ? 2 : 1;
        is_deeply([@$r{qw(escaped calls healthy)},$r->{info}{callback_exceptions},$r->{info}{ticks},
            $r->{info}{started},$r->{coercions},$r->{notifiers}],
            [0,$ticks,1,1,$ticks,$mode eq 'calendar'?0:1,[0,0],0],
            "$mode $class: real timers contain the exception, count it once, run healthy work and clean up");
        is_deeply([$r->{errors},$r->{observations}],
            [["Scheduler: task 'subject' error: non-scalar task exception"],$ticks],
            "$mode $class: logging is scalar and timing observations survive without invoking overloads");
    }
}
{
    my $r=exercise_1416('periodic',"known\nfailure\n");
    is_deeply([@$r{qw(escaped calls healthy)},$r->{info}{callback_exceptions},$r->{errors},$r->{observations}],
        [0,1,1,1,["Scheduler: task 'subject' error: known failure "],1],
        'ordinary scalar exception text keeps its existing whitespace normalization and failure accounting');
}
{
    my $r=exercise_1416('periodic',undef);
    is_deeply([@$r{qw(escaped calls healthy)},$r->{info}{callback_exceptions},$r->{errors},$r->{observations}],
        [0,1,1,0,[],1], 'returning zero remains a successful callback with no fabricated exception');
}
{
    my $r=exercise_1416('periodic',('x'x3000)."\n");
    my $prefix="Scheduler: task 'subject' error: ";
    is_deeply([$r->{escaped},$r->{info}{callback_exceptions},$r->{errors},$r->{observations}],
        [0,1,[$prefix.('x'x512)],1], 'scalar exception diagnostics have a bounded 512-character payload');
}
{
    my $r=exercise_1416('periodic',bless({},'MB1043::BoolError'),replace=>1);
    is_deeply([$r->{escaped},$r->{successor}>$r->{old_id}?1:0,$r->{info}{task_id},
        $r->{info}{ticks},$r->{info}{callback_exceptions},$r->{info}{started},$r->{coercions},$r->{notifiers}],
        [0,1,$r->{successor},0,0,1,[0,0],0],
        'a failing callback that replaces itself cannot escape or charge its exception to the successor');
}
{
    my $r=exercise_1416('periodic',bless({},'MB1043::StringError'),no_logger=>1,no_metrics=>1);
    is_deeply([@$r{qw(escaped calls healthy)},$r->{info}{callback_exceptions},$r->{coercions},$r->{notifiers}],
        [0,1,1,1,[0,0],0], 'exception isolation also works without a logger or metrics projection');
}
for my $class (qw(MB1043::StringError MB1043::BoolError MB1043::FalseError)) {
    my $loop = IO::Async::Loop->really_new;
    my $logger = bless({rows=>[]},'MB1043::Logger');
    my $s = Mediabot::Scheduler->new(loop=>$loop, logger=>$logger);
    my ($runs,$resolutions)=(0,0);
    $bool_calls=$string_calls=0;
    $s->add(name=>'calendar',interval=>3600,autostart=>1,
        cb=>sub {++$runs; $s->stop('calendar') if $runs==2},
        next_run_cb=>sub {
            die bless({},$class) if ++$resolutions==2;
            return time()+60;
        });
    my $first=$s->{_tasks}{calendar}{timer};
    my $safe=eval {$loop->loop_once(0);1};
    my $info=$s->task_info('calendar');
    my @errors=map {$_->[1]} grep {$_->[0]==1} @{$logger->{rows}};
    my $before=[$safe?1:0,$runs,$info->{started},$info->{next_run},$first->loop?1:0,
        [$bool_calls,$string_calls],\@errors];
    my $recovered=eval {
        die "calendar restart refused\n" unless $s->start('calendar');
        $loop->loop_once(0);1;
    };
    $s->remove('calendar');
    is_deeply([$before,$recovered?1:0,$runs,$resolutions,scalar($loop->notifiers)],
        [[1,1,0,0,0,[0,0],[
            "Scheduler: cannot arm calendar task 'calendar': non-scalar task exception",
            "Scheduler: calendar task 'calendar' stopped because re-arm failed",
        ]],1,2,3,0],
        "$class: a failed calendar resolver stops its task cleanly and permits a fresh start");
}
{
    my $loop=IO::Async::Loop->really_new;
    my $s=Mediabot::Scheduler->new(loop=>$loop);
    $s->add(name=>'periodic',interval=>3600,cb=>sub {});
    my $timer=$s->{_tasks}{periodic}{timer};
    my $native=$timer->can('start');
    $bool_calls=$string_calls=0;
    my ($result,$safe);
    {
        local *IO::Async::Timer::Periodic::start=sub {
            $native->(@_);
            die bless({},'MB1043::BoolError');
        };
        $safe=eval {$result=$s->start('periodic');1};
    }
    my $info=$s->task_info('periodic');
    my $before=[$safe?1:0,$result,$info->{started},$info->{next_run},
        $timer->is_running?1:0,$bool_calls,$string_calls];
    my $recovered=$s->start('periodic') && $timer->is_running;
    $s->remove('periodic');
    is_deeply([$before,$recovered?1:0,scalar($loop->notifiers)],
        [[1,0,0,0,0,0,0],1,0],
        'an object exception after a partial periodic start cannot skip rollback or prevent recovery');
}
{
    my $loop=IO::Async::Loop->really_new;
    my $s=Mediabot::Scheduler->new(loop=>$loop);
    my $native=$loop->can('add');
    my $error=bless({},'MB1043::BoolError');
    my $caught;
    $bool_calls=$string_calls=0;
    {
        local *IO::Async::Loop::add=sub {
            $native->(@_);
            die $error;
        };
        eval {$s->add(name=>'periodic',interval=>3600,cb=>sub {});1};
        $caught=$@;
    }
    my $before=[(refaddr($caught)//0)==refaddr($error)?1:0,
        defined($s->task_info('periodic'))?1:0,scalar($loop->notifiers),
        $bool_calls,$string_calls];
    $s->remove('periodic') if $s->task_info('periodic');
    $s->add(name=>'periodic',interval=>3600,cb=>sub {},autostart=>1);
    my $recovered=$s->task_info('periodic')->{started};
    $s->remove('periodic');
    is_deeply([$before,$recovered,scalar($loop->notifiers)],[[1,0,0,0,0],1,0],
        'a failed registration rethrows the original object after detaching the partially added timer');
}
is_deeply(\@warnings, [], 'native periodic/calendar exception and success paths are warning-free');
done_testing;
