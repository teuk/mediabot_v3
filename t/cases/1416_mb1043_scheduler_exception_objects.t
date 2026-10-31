use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
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
is_deeply(\@warnings, [], 'native periodic/calendar exception and success paths are warning-free');
done_testing;
