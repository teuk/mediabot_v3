use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Scalar::Util qw(refaddr);
use Mediabot::Scheduler;

sub countdowns { scalar grep { $_->isa('IO::Async::Timer::Countdown') } $_[0]->notifiers }
for my $stage (qw(constructor add start)) {
    for my $outcome (qw(return throw)) {
        my $loop = IO::Async::Loop->really_new;
        my $s = Mediabot::Scheduler->new(loop => $loop);
        my ($runs, $entered, $replacement) = (0, 0);
        $s->add(name => 'same', interval => 3600, cb => sub { $runs++ },
            next_run_cb => sub { time() + 3600 });
        my $new = IO::Async::Timer::Countdown->can('new');
        my $add = IO::Async::Loop->can('add');
        my $start = IO::Async::Timer::Countdown->can('start');
        my $reenter = sub {
            return if $entered++;
            $s->restart('same');
            $replacement = $s->{_tasks}{same}{timer};
            die "injected old calendar arm failure\n" if $outcome eq 'throw';
        };
        {
            no warnings qw(redefine once);
            local *IO::Async::Timer::Countdown::new = sub {
                my $made = $new->(@_); $reenter->() if $stage eq 'constructor'; return $made;
            };
            local *IO::Async::Loop::add = sub {
                $add->(@_); $reenter->() if $stage eq 'add'; return $_[1];
            };
            local *IO::Async::Timer::Countdown::start = sub {
                $start->(@_); $reenter->() if $stage eq 'start'; return $_[0];
            };
            ok(!$s->start('same'), "$stage/$outcome: superseded start cannot report success");
        }
        ok($s->task_info('same')->{started}, "$stage/$outcome: newer lifecycle stays started");
        is(refaddr($s->{_tasks}{same}{timer}), refaddr($replacement), "$stage/$outcome: newer timer retains ownership");
        is(countdowns($loop), 1, "$stage/$outcome: only the newer countdown remains in the loop");
        is($runs, 0, "$stage/$outcome: setup does not execute a task");
        $replacement->invoke_event('on_expire');
        is($runs, 1, "$stage/$outcome: preserved lifecycle remains runnable");
        $s->remove('same');
        is(countdowns($loop), 0, "$stage/$outcome: normal removal leaves no orphan timer");
    }
}
for my $stage (qw(constructor add)) {
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my ($old_runs, $new_runs, $entered, $replacement) = (0, 0, 0);
    $s->add(name => 'replace', interval => 3600, cb => sub { $old_runs++ },
        next_run_cb => sub { time() + 3600 });
    my $new = IO::Async::Timer::Countdown->can('new');
    my $add = IO::Async::Loop->can('add');
    my $replace = sub {
        return if $entered++;
        $s->remove('replace');
        $s->add(name => 'replace', interval => 7200, cb => sub { $new_runs++ },
            next_run_cb => sub { time() + 7200 }, autostart => 1);
        $replacement = $s->{_tasks}{replace}{timer};
    };
    {
        no warnings qw(redefine once);
        local *IO::Async::Timer::Countdown::new = sub {
            my $made = $new->(@_); $replace->() if $stage eq 'constructor'; return $made;
        };
        local *IO::Async::Loop::add = sub {
            $add->(@_);
            if ($stage eq 'add' && !$entered) { $replace->(); die "injected replaced arm failure\n" }
            return $_[1];
        };
        ok(!$s->start('replace'), "$stage: replaced registration supersedes the outer start");
    }
    ok($s->task_info('replace')->{started}, "$stage: distinct replacement stays running");
    is($s->task_info('replace')->{interval}, 7200, "$stage: distinct replacement retains its schedule");
    is(refaddr($s->{_tasks}{replace}{timer}), refaddr($replacement), "$stage: distinct replacement retains its timer");
    is(countdowns($loop), 1, "$stage: distinct replacement has no companion orphan timer");
    $replacement->invoke_event('on_expire');
    is_deeply([$old_runs, $new_runs], [0, 1], "$stage: only the replacement callback executes");
    $s->remove('replace');
    is(countdowns($loop), 0, "$stage: distinct replacement remains fully removable");
}
{
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my $runs = 0;
    $s->add(name => 'expiry', interval => 3600, cb => sub { $runs++ },
        next_run_cb => sub { time() + 3600 }, autostart => 1);
    my $old = $s->{_tasks}{expiry}{timer};
    my $remove = IO::Async::Loop->can('remove');
    my ($entered, $replacement) = (0);
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::remove = sub {
            $remove->(@_);
            unless ($entered++) {
                $s->restart('expiry');
                $replacement = $s->{_tasks}{expiry}{timer};
            }
            return $_[1];
        };
        $old->invoke_event('on_expire');
    }
    is($runs, 0, 'expiry cleanup restart revokes the old occurrence before invocation');
    is($s->task_info('expiry')->{ticks}, 0, 'revoked occurrence is excluded from tick statistics');
    is(refaddr($s->{_tasks}{expiry}{timer}), refaddr($replacement), 'expiry cleanup cannot erase the new lifecycle timer');
    is(countdowns($loop), 1, 'expiry cleanup restart retains one timer');
    $old->invoke_event('on_expire');
    is($runs, 0, 'retained old expiry cannot run after cleanup restart');
    $replacement->invoke_event('on_expire');
    is($runs, 1, 'new lifecycle runs normally after old cleanup returns');
    $s->remove('expiry');
    is(countdowns($loop), 0, 'expiry cleanup replacement remains fully removable');
}
done_testing;
