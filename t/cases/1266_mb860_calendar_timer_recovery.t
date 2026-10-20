use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Scalar::Util qw(weaken);
use Time::HiRes ();
use Mediabot::Scheduler;

sub countdowns { scalar grep { $_->isa('IO::Async::Timer::Countdown') } $_[0]->notifiers }
for my $stage (qw(constructor add start)) {
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my $runs = 0; my (@retained, $weak_timer);
    $s->add(name => 'recover', interval => 3600, cb => sub { $runs++ },
        next_run_cb => sub { time() + 3600 });
    my $new = IO::Async::Timer::Countdown->can('new');
    my $add = IO::Async::Loop->can('add');
    my $start = IO::Async::Timer::Countdown->can('start');
    {
        no warnings qw(redefine once);
        local *IO::Async::Timer::Countdown::new = sub {
            my ($class, %args) = @_;
            push @retained, $args{on_expire};
            die "injected calendar constructor failure\n" if $stage eq 'constructor';
            my $made = $new->(@_); $weak_timer = $made; weaken($weak_timer);
            return $made;
        };
        local *IO::Async::Loop::add = sub {
            $add->(@_); die "injected calendar add failure\n" if $stage eq 'add'; return $_[1];
        };
        local *IO::Async::Timer::Countdown::start = sub {
            $start->(@_); die "injected calendar start failure\n" if $stage eq 'start'; return $_[0];
        };
        ok(!$s->start('recover'), "$stage: failed calendar start is reported");
    }
    is($s->task_info('recover')->{started}, 0, "$stage: failed task is stopped and registered for retry");
    is($s->task_info('recover')->{next_run}, 0, "$stage: no next occurrence is advertised");
    ok(!$s->{_tasks}{recover}{timer}, "$stage: failed timer ownership is cleared");
    is(countdowns($loop), 0, "$stage: native loop retains no failed countdown");
    ok(!defined($weak_timer), "$stage: retained callback does not retain failed timer");
    $_->() for @retained;
    is($runs, 0, "$stage: retained failed expiry cannot execute a task");
    ok($s->start('recover'), "$stage: original registration can be started after recovery");
    $s->{_tasks}{recover}{timer}->invoke_event('on_expire');
    is($runs, 1, "$stage: recovered occurrence executes once");
    is(countdowns($loop), 1, "$stage: recovered occurrence rearms one timer");
    $s->remove('recover');
    is(countdowns($loop), 0, "$stage: recovered registration remains removable");
    my $weak_scheduler = $s; weaken($weak_scheduler); undef $s;
    ok(!defined($weak_scheduler), "$stage: retained failed callback releases the scheduler");
}
{
    # Exercise an actual expiry, not just a manually invoked timer callback.
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my ($runs, $responsive, $constructors) = (0, 0, 0);
    my $other = IO::Async::Timer::Countdown->new(delay => .02, on_expire => sub { $responsive++ });
    $loop->add($other); $other->start;
    my $new = IO::Async::Timer::Countdown->can('new');
    {
        no warnings qw(redefine once);
        local *IO::Async::Timer::Countdown::new = sub {
            die "injected calendar rearm constructor failure\n" if ++$constructors == 2;
            return $new->(@_);
        };
        $s->add(name => 'live', interval => 60, cb => sub { $runs++ },
            next_run_cb => sub { time() + 1 }, autostart => 1);
        my $end = Time::HiRes::time() + 3;
        my $ok = eval {
            $loop->loop_once(.02) while !$runs && Time::HiRes::time() < $end;
            1;
        };
        ok($ok, 'native expiry contains a constructor exception during rearm');
        is($runs, 1, 'failed rearm preserves the one completed occurrence');
        is($responsive, 1, 'unrelated native countdown runs while the calendar waits');
        is($s->task_info('live')->{started}, 0, 'failed native rearm marks the registration stopped');
        is($s->task_info('live')->{next_run}, 0, 'failed native rearm reports no next occurrence');
        ok(!$s->{_tasks}{live}{timer}, 'failed native rearm leaves no owned timer');
        $loop->remove($other);
        is(countdowns($loop), 0, 'failed native rearm leaves no calendar notifier');
        ok($s->start('live'), 'stopped native registration can be retried');
        $end = Time::HiRes::time() + 3;
        $loop->loop_once(.02) while $runs < 2 && Time::HiRes::time() < $end;
        is($runs, 2, 'retried task executes its next real occurrence');
        is($s->task_info('live')->{ticks}, 2, 'tick statistics count only completed occurrences');
        is(countdowns($loop), 1, 'successful retry owns one next occurrence');
    }
    $s->remove('live');
    is(countdowns($loop), 0, 'native retry leaves no timer after normal removal');
}
done_testing;
