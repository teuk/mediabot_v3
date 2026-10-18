use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use Scalar::Util qw(refaddr);
use Mediabot::Scheduler;

sub timers {
    my ($loop) = @_;
    return scalar grep { $_->isa('IO::Async::Timer::Countdown') } $loop->notifiers;
}
sub fixture {
    my $loop = IO::Async::Loop->really_new;
    return ($loop, Mediabot::Scheduler->new(loop => $loop));
}

{
    my ($loop, $s) = fixture();
    $s->add(name => 'stop_in_resolver', interval => 3600, cb => sub {},
        next_run_cb => sub { $s->stop('stop_in_resolver'); return time() + 3600 });
    ok(!$s->start('stop_in_resolver'), 'a start superseded by stop does not report success');
    is($s->task_info('stop_in_resolver')->{started}, 0, 'resolver stop remains effective');
    is($s->task_info('stop_in_resolver')->{next_run}, 0, 'stopped task has no claimed next occurrence');
    ok(!$s->{_tasks}{stop_in_resolver}{timer}, 'stopped resolver cannot publish a timer');
    is(timers($loop), 0, 'real loop has no orphan countdown after resolver stop');
    ok($s->remove('stop_in_resolver'), 'stopped registration can be removed');
}

{
    my ($loop, $s) = fixture();
    my ($calls, $runs, $replacement) = (0, 0);
    $s->add(name => 'restart_in_resolver', interval => 3600, cb => sub { $runs++ },
        next_run_cb => sub {
            if (++$calls == 1) {
                ok($s->restart('restart_in_resolver'), 'resolver can establish a newer lifecycle');
                $replacement = $s->{_tasks}{restart_in_resolver}{timer};
            }
            return time() + 3600;
        });
    ok(!$s->start('restart_in_resolver'), 'superseded outer start returns false');
    ok($s->task_info('restart_in_resolver')->{started}, 'newer start remains running');
    is(refaddr($s->{_tasks}{restart_in_resolver}{timer}), refaddr($replacement),
        'outer resolver cannot replace the newer lifecycle timer');
    is(timers($loop), 1, 'exactly one real countdown remains after resolver restart');
    $replacement->invoke_event('on_expire');
    is($runs, 1, 'preserved timer executes its own callback');
    is(timers($loop), 1, 'normal execution rearms exactly one occurrence');
    $s->remove('restart_in_resolver');
    is(timers($loop), 0, 'removal reclaims the current timer');
}

for my $outcome (qw(invalid throw valid)) {
    my ($loop, $s) = fixture();
    my $runs = 0;
    my $ok = eval {
        $s->add(name => 'replace_in_resolver', interval => 3600, cb => sub {}, autostart => 1,
            next_run_cb => sub {
                $s->remove('replace_in_resolver');
                $s->add(name => 'replace_in_resolver', interval => 7200, cb => sub { $runs++ },
                    next_run_cb => sub { time() + 7200 }, autostart => 1);
                die "resolver failure\n" if $outcome eq 'throw';
                return time() + 3600 if $outcome eq 'valid';
                return undef;
            });
        1;
    };
    ok(!$ok, "$outcome: superseded autostart reports failure");
    my $info = $s->task_info('replace_in_resolver');
    ok($info && $info->{started}, "$outcome: rollback preserves replacement registration");
    is($info ? $info->{interval} : 0, 7200, "$outcome: replacement metadata survives");
    is(timers($loop), 1, "$outcome: replacement has exactly one loop-owned timer");
    if (my $task = $s->{_tasks}{replace_in_resolver}) {
        $task->{timer}->invoke_event('on_expire');
    }
    is($runs, 1, "$outcome: replacement callback remains reachable");
    $s->remove('replace_in_resolver');
    is(timers($loop), 0, "$outcome: no timer is orphaned by old autostart cleanup");
}

{
    my ($loop, $s) = fixture();
    my $calls = 0;
    my $ok = eval {
        $s->add(name => 'autostart_restart', interval => 3600, cb => sub {}, autostart => 1,
            next_run_cb => sub {
                if (++$calls == 1) {
                    $s->restart('autostart_restart');
                    die "superseded resolver\n";
                }
                return time() + 3600;
            });
        1;
    };
    ok(!$ok, 'superseded original autostart reports its failure');
    my $info = $s->task_info('autostart_restart');
    ok($info && $info->{started}, 'autostart rollback preserves same-object newer lifecycle');
    is(timers($loop), 1, 'autostart restart retains exactly its newer timer');
    $s->remove('autostart_restart');
    is(timers($loop), 0, 'same-object replacement can be fully removed');
}

{
    my ($loop, $s) = fixture();
    $s->add(name => 'remove_in_resolver', interval => 3600, cb => sub {},
        next_run_cb => sub { $s->remove('remove_in_resolver'); return time() + 3600 });
    ok(!$s->start('remove_in_resolver'), 'resolver removal cancels the outer start');
    ok(!defined $s->task_info('remove_in_resolver'), 'resolver removal remains effective');
    is(timers($loop), 0, 'removed task cannot publish an abandoned timer');
}

{
    my ($loop, $s) = fixture();
    my ($calls, $runs, $new_timer) = (0, 0);
    $s->add(name => 'rearm_restart', interval => 3600, cb => sub { $runs++ }, autostart => 1,
        next_run_cb => sub {
            if (++$calls == 2) {
                ok($s->restart('rearm_restart'), 're-arm resolver can restart its task');
                $new_timer = $s->{_tasks}{rearm_restart}{timer};
                return undef;
            }
            return time() + 3600;
        });
    my $old = $s->{_tasks}{rearm_restart}{timer};
    $old->invoke_event('on_expire');
    is($runs, 1, 'original occurrence executed once');
    ok($s->task_info('rearm_restart')->{started}, 'old re-arm failure cannot stop a newer lifecycle');
    is(refaddr($s->{_tasks}{rearm_restart}{timer}), refaddr($new_timer), 'newer timer remains current');
    is(timers($loop), 1, 'one timer after re-entrant re-arm');
    $old->invoke_event('on_expire');
    is($runs, 1, 'retained stale occurrence cannot execute twice');
    $new_timer->invoke_event('on_expire');
    is($runs, 2, 'new lifecycle can execute normally');
    $s->remove('rearm_restart');
    is(timers($loop), 0, 're-arm restart leaves no abandoned notifier');
}

{
    my ($loop, $s) = fixture();
    my $ok = eval { $s->add(name => 'invalid', interval => 3600, cb => sub {},
        next_run_cb => sub { time() }, autostart => 1); 1 };
    ok(!$ok, 'ordinary invalid schedule is still rejected');
    ok(!defined $s->task_info('invalid'), 'failed original autostart still rolls back its own entry');
    is(timers($loop), 0, 'invalid schedule creates no notifier');
}

done_testing;
