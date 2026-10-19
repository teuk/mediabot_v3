use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use MB852WorkerFixture qw(new_loop with_faults pump gated_child cleanup signals);
use Mediabot::AsyncWorker;

for my $kind (qw(timeout cancel)) {
    for my $case (
        ['kill-add', {2 => 'add'}],
        ['force-start', {3 => 'start'}],
        ['both', {2 => 'start', 3 => 'add'}],
    ) {
        my ($name, $faults) = @$case;
        my $label = "$kind/$name";
        my $loop = new_loop($faults);
        my ($child, $ready, $release) = gated_child();
        my @done;
        my $worker = with_faults(sub {Mediabot::AsyncWorker->start(loop => $loop,
            child => $child, timeout => 3600, term_grace => 60, force_grace => 60,
            on_done => sub {push @done, shift})});
        ok($worker, "$label: real worker starts before the injected escalation fault");
        ok($ready->(), "$label: child has installed its TERM-ignore handler");
        my $pid = $worker->pid;
        with_faults(sub {
            $kind eq 'timeout' ? $worker->{timeout_timer}->invoke_event('on_expire') : $worker->cancel('operator cancellation');
        });
        my @retained = @{$loop->{mb852_timers}};
        is_deeply(signals($pid), ['TERM', 'KILL'], "$label: failed timer arm triggers immediate owned-child escalation");
        ok(pump($loop, sub {@done && !keys %{$loop->{mb852_pids}}}, 1), "$label: completion and watcher reap need no functioning grace timer");
        is(scalar @done, 1, "$label: one terminal completion releases consumer capacity");
        is($done[0]{error} // '', $kind eq 'timeout' ? 'worker_timeout' : 'worker_cancelled',
            "$label: original timeout/cancellation result is preserved");
        ok($worker->is_done, "$label: worker is finalized");
        is(scalar(grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $loop->notifiers), 0, "$label: all timer/stream notifiers are removed");
        # Finish the unchanged baseline safely even when its grace timers failed.
        # Only this fixture's owned child can be signalled; its watcher owns reap.
        unless ($worker->is_done) {
            cleanup($loop);
            pump($loop, sub {$worker->is_done});
        }
        my $count = scalar @done;
        my $before = scalar @{signals($pid)};
        $_->invoke_event('on_expire') for @retained;
        is(scalar @done, $count, "$label: retained callbacks cannot complete twice");
        is(scalar @{signals($pid)}, $before, "$label: retained callbacks cannot signal the old PID");
        is($worker->cancel('late cancel'), 0, "$label: finalized cancellation remains idempotent");
        $release->(); cleanup($loop);
    }
}
# Process completion can precede pipe EOF. A failed backstop must finish the
# timeout without signalling the already-reaped process number.
{
    my $loop = new_loop({3 => 'start'});
    my @done;
    my $worker = with_faults(sub {Mediabot::AsyncWorker->start(loop => $loop,
        child => sub {{packet => 'withheld'}}, timeout => 3600,
        on_done => sub {push @done, shift})});
    my $pid = $worker->pid;
    my $stream = $worker->{stream};
    $loop->remove($stream);
    ok(pump($loop, sub {$worker->{child_done}}), 'real watcher reaps child while pipe delivery is withheld');
    ok(!$worker->is_done, 'process/EOF barrier waits before the deadline');
    with_faults(sub {$worker->{timeout_timer}->invoke_event('on_expire')});
    ok($worker->is_done, 'failed force arm finishes an EOF-withheld timeout');
    is(scalar @done, 1, 'EOF-withheld timeout has one terminal result');
    is($done[0]{error} // '', 'worker_timeout', 'EOF-withheld completion retains timeout truth');
    is_deeply(signals($pid), [], 'already-reaped child receives neither TERM nor KILL');
    $_->invoke_event('on_expire') for @{$loop->{mb852_timers}};
    is_deeply(signals($pid), [], 'retained grace callbacks cannot signal the old PID');
    is(scalar @done, 1, 'retained callbacks cannot repeat EOF-withheld completion');
    cleanup($loop);
}
done_testing;
