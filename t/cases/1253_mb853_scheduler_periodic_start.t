use strict;
use warnings;
use lib '.', 't/lib';
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Time::HiRes qw(time);
use Mediabot::Scheduler;

sub mb853_pump {
    my ($loop, $until) = @_;
    my $end = time() + 1;
    $loop->loop_once(.005) while !$until->() && time() < $end;
    return $until->() ? 1 : 0;
}
for my $mode (qw(manual autostart)) {
    my $loop = IO::Async::Loop->really_new;
    my $s = Mediabot::Scheduler->new(loop => $loop);
    my $runs = 0;
    my $start = IO::Async::Timer::Periodic->can('start');
    my $fail = 1;
    my $old;
    no warnings qw(redefine once);
    local *IO::Async::Timer::Periodic::start = sub {
        $start->(@_);
        if ($fail-- > 0) {$old = $_[0]; die "injected start after native arm\n"}
        return $_[0];
    };
    if ($mode eq 'manual') {
        $s->add(name => 'recover', interval => 3600, first_interval => 0, cb => sub {$runs++});
        ok(!$s->start('recover'), 'manual: partial native start reports failure');
        ok(!$old->is_running, 'manual: failed start stops the partially running timer');
        is($s->task_info('recover')->{started}, 0, 'manual: failed task remains registered but stopped');
        is($s->task_info('recover')->{next_run}, 0, 'manual: failed task advertises no next occurrence');
        $old->invoke_event('on_tick');
        is($runs, 0, 'manual: retained failed tick remains suppressed');
        ok($s->start('recover'), 'manual: same registered timer can start after transient failure');
    } else {
        my $ok = eval {$s->add(name => 'recover', interval => 3600, first_interval => 0,
            cb => sub {$runs++}, autostart => 1); 1};
        ok(!$ok, 'autostart: partial native start reports registration failure');
        ok(!$old->is_running, 'autostart: failed timer is stopped before ownership is discarded');
        ok(!$s->task_info('recover'), 'autostart: failed original registration is rolled back');
        is(scalar(grep {$_->isa('IO::Async::Timer::Periodic')} $loop->notifiers), 0,
            'autostart: failed original timer leaves the native loop');
        $old->invoke_event('on_tick');
        is($runs, 0, 'autostart: failed arm cannot execute after rollback');
        ok(eval {$s->add(name => 'recover', interval => 3600, first_interval => 0,
            cb => sub {$runs++}, autostart => 1); 1}, 'autostart: same name can be added after the failure');
    }
    ok(mb853_pump($loop, sub {$runs == 1}), "$mode: actual recovered periodic timer executes its first tick");
    is($s->task_info('recover')->{ticks}, 1, "$mode: successful recovery updates tick statistics once");
    ok($s->stop('recover'), "$mode: recovered task stops normally");
    $s->{_tasks}{recover}{timer}->invoke_event('on_tick');
    is($runs, 1, "$mode: stop still suppresses a retained tick");
    ok($s->remove('recover'), "$mode: recovered registration is removable");
    is(scalar(grep {$_->isa('IO::Async::Timer::Periodic')} $loop->notifiers), 0,
        "$mode: normal removal leaves no periodic timer");
}
done_testing;
