use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use Scalar::Util qw(weaken);
use MB852WorkerFixture qw(new_loop with_faults pump gated_child cleanup);
use Mediabot::AsyncWorker;

sub mb852_callback { my ($context) = @_; return sub {$context->{calls}++} }
for my $stage (qw(add start)) {
    my $loop = new_loop({1 => $stage});
    my $context = {calls => 0};
    my $weak = $context; weaken($weak);
    my $worker = bless {loop => $loop}, 'Mediabot::AsyncWorker';
    my $ok = eval {with_faults(sub {$worker->_new_timer(3600, mb852_callback($context))}); 1};
    ok(!$ok, "$stage: timer failure is propagated");
    like($@, qr/injected timer \Q$stage\E failure/, "$stage: original setup error survives rollback");
    my $timer = $loop->{mb852_timers}[0];
    ok($timer, "$stage: actual IO::Async timer reached registration");
    ok(!$timer->is_running, "$stage: failed timer is stopped");
    ok(!$timer->loop, "$stage: failed timer is detached from its real loop");
    is(scalar($loop->notifiers), 0, "$stage: no orphan notifier remains");
    $timer->invoke_event('on_expire');
    is($context->{calls}, 0, "$stage: retained failed timer cannot call its consumer");
    undef $context;
    ok(!defined $weak, "$stage: retained failed timer releases callback context");
    cleanup($loop);
}
for my $stage (qw(add start)) {
    my $loop = new_loop({1 => $stage});
    my ($child, $ready, $release) = gated_child();
    my (@done, $weak_worker);
    my $native = Mediabot::AsyncWorker->can('_new_timer');
    no warnings 'redefine';
    local *Mediabot::AsyncWorker::_new_timer = sub {
        $weak_worker = $_[0]; weaken($weak_worker);
        return $native->(@_);
    };
    my $worker = with_faults(sub {
        Mediabot::AsyncWorker->start(loop => $loop, child => $child,
            timeout => 3600, on_done => sub {push @done, shift});
    });
    ok(!defined $worker, "$stage: real worker refuses failed deadline setup");
    is(scalar @done, 1, "$stage: setup completion is terminal once");
    is($done[0]{error}, 'worker_setup', "$stage: setup error envelope is preserved");
    is($done[0]{stage}, 'timeout_timer', "$stage: failed deadline stage is identified");
    ok(pump($loop, sub {!keys %{$loop->{mb852_pids}}}), "$stage: real watcher reaps the killed setup child");
    is(scalar(grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $loop->notifiers), 0, "$stage: failed setup leaves no stream or deadline notifier");
    ok(!defined $weak_worker, "$stage: completed setup worker is released even with the failed timer retained");
    my @recovery;
    my $next = with_faults(sub {Mediabot::AsyncWorker->start(loop => $loop,
        child => sub {{packet => 'next request'}}, timeout => 5,
        on_done => sub {push @recovery, shift})});
    ok($next && pump($loop, sub {@recovery && !keys %{$loop->{mb852_pids}}}), "$stage: same real loop accepts the next worker");
    is_deeply($recovery[0]{value}, {packet => 'next request'}, "$stage: successor fork/pipe result remains intact");
    is(scalar @done, 1, "$stage: successor cannot repeat failed setup completion");
    $release->(); cleanup($loop);
}
done_testing;
