use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken refaddr);
use Mediabot::Scheduler;

sub mb853_periodic_count { scalar grep {$_->isa('IO::Async::Timer::Periodic')} $_[0]->notifiers }
for my $stage (qw(constructor add)) {
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my ($timer, $weak_task, $runs);
    $runs = 0;
    my $new = IO::Async::Timer::Periodic->can('new');
    my $add = IO::Async::Loop->can('add');
    my $fail = 1;
    no warnings qw(redefine once);
    local *IO::Async::Timer::Periodic::new = sub {
        my $made = $new->(@_);
        $timer = $made;
        $weak_task = $s->{_tasks}{retry}; weaken($weak_task);
        die "injected periodic constructor failure\n" if $stage eq 'constructor' && $fail-- > 0;
        return $made;
    };
    local *IO::Async::Loop::add = sub {
        my ($l, $obj) = @_;
        $add->(@_);
        die "injected periodic add failure\n" if $stage eq 'add' && $fail-- > 0;
        return;
    };
    my $ok = eval {$s->add(name => 'retry', interval => 3600, cb => sub {$runs++}); 1};
    ok(!$ok, "$stage: registration failure remains explicit");
    like($@, qr/injected periodic \Q$stage\E failure/, "$stage: original constructor/add error is retained");
    ok(!defined $s->task_info('retry'), "$stage: failed task name is available again");
    is(mb853_periodic_count($loop), 0, "$stage: native loop retains no failed periodic notifier");
    ok(!$timer->is_running, "$stage: failed registration has no active countdown");
    ok(!defined $weak_task, "$stage: retained timer callback releases the failed task");
    $timer->invoke_event('on_tick');
    is($runs, 0, "$stage: old callback cannot execute a failed registration");
    my $old = $timer;
    my $replacement_runs = 0;
    $ok = eval {$s->add(name => 'retry', interval => 3600, cb => sub {$replacement_runs++}, autostart => 1); 1};
    ok($ok, "$stage: same name can be registered and started after recovery");
    $old->invoke_event('on_tick');
    is($replacement_runs, 0, "$stage: failed arm cannot execute the replacement callback");
    if (my $current = $s->{_tasks}{retry}) {$current->{timer}->invoke_event('on_tick') if $current->{timer}}
    is($replacement_runs, 1, "$stage: replacement executes its own callback");
    if (my $current = $s->{_tasks}{retry}) {eval {$current->{timer}->stop} if $current->{timer}; $s->remove('retry')}
    eval {$old->stop}; eval {$loop->remove($old)} if $old->loop;
}

# Reentry at the loop boundary must not let the old failure delete a new task.
{
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my $add = IO::Async::Loop->can('add');
    my ($old, $replacement, $runs, $entered) = (undef, undef, 0, 0);
    no warnings qw(redefine once);
    local *IO::Async::Loop::add = sub {
        my ($l, $obj) = @_;
        $add->(@_);
        unless ($entered++) {
            $old = $obj;
            $s->remove('same_name');
            $s->add(name => 'same_name', interval => 7200, cb => sub {$runs++}, autostart => 1);
            $replacement = $s->{_tasks}{same_name}{timer};
            die "injected old registration failure\n";
        }
        return;
    };
    my $ok = eval {$s->add(name => 'same_name', interval => 3600, cb => sub {die 'old callback'}); 1};
    ok(!$ok, 'superseded registration still reports its own failure');
    my $info = $s->task_info('same_name');
    ok($info && $info->{started}, 'old failure preserves the running same-name replacement');
    is($info ? $info->{interval} : 0, 7200, 'replacement schedule metadata survives old rollback');
    is(mb853_periodic_count($loop), 1, 'native loop retains exactly the replacement timer');
    $old->invoke_event('on_tick');
    is($runs, 0, 'old registration callback cannot run the replacement');
    $replacement->invoke_event('on_tick');
    is($runs, 1, 'preserved replacement can still run normally');
    if ($s->task_info('same_name')) {$s->remove('same_name')}
    else {$replacement->stop; $loop->remove($replacement) if $replacement->loop}
    is(mb853_periodic_count($loop), 0, 'replacement remains fully removable after old failure');
}
done_testing;
