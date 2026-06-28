# t/cases/575_mb356_scheduler_lifecycle_generation.t
# mb356 — calendar callbacks must not double-arm after restart/remove/re-add.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);

BEGIN {
    unshift @INC, "$Bin/../..";

    package IO::Async::Timer::Periodic;
    sub new {
        my ($class, %args) = @_;
        return bless { %args, started => 0 }, $class;
    }
    sub start { $_[0]{started} = 1; return 1 }
    sub stop  { $_[0]{started} = 0; return 1 }
    $INC{'IO/Async/Timer/Periodic.pm'} = __FILE__;

    package IO::Async::Timer::Countdown;
    our @CREATED;
    sub new {
        my ($class, %args) = @_;
        my $self = bless { %args, started => 0 }, $class;
        push @CREATED, $self;
        return $self;
    }
    sub start { $_[0]{started} = 1; return 1 }
    sub stop  { $_[0]{started} = 0; return 1 }
    sub fire  { $_[0]{on_expire}->() }
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
}

{
    package MB356::Loop;
    use Scalar::Util qw(refaddr);
    sub new { bless { active => {}, fail_remove => 0 }, shift }
    sub add {
        my ($self, $timer) = @_;
        $self->{active}{refaddr($timer)} = $timer;
        return $timer;
    }
    sub remove {
        my ($self, $timer) = @_;
        die "forced remove failure\n" if $self->{fail_remove};
        delete $self->{active}{refaddr($timer)} if $timer;
        return $timer;
    }
    sub active_count { scalar keys %{ $_[0]{active} } }
}

{
    package MB356::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; return 1 }
}

require Mediabot::Scheduler;

@IO::Async::Timer::Countdown::CREATED = ();
my $loop = MB356::Loop->new;
my $log  = MB356::Logger->new;
my $sched = Mediabot::Scheduler->new(loop => $loop, logger => $log);
my $callback_calls = 0;

$sched->add(
    name        => 'self_restart',
    interval    => 86400,
    next_run_cb => sub { time() + 60 },
    cb          => sub {
        $callback_calls++;
        ok($sched->restart('self_restart'),
            'calendar callback can restart its own task');
    },
    autostart => 1,
);

is(scalar @IO::Async::Timer::Countdown::CREATED, 1,
    'self-restarting task starts with one timer');
my $first = $IO::Async::Timer::Countdown::CREATED[0];
$first->fire;

is($callback_calls, 1, 'self-restarting callback ran once');
is(scalar @IO::Async::Timer::Countdown::CREATED, 2,
    'callback restart creates exactly one replacement timer');
is($loop->active_count, 1,
    'only one timer remains owned by the loop after callback restart');
my $restart_info = $sched->task_info('self_restart');
ok($restart_info->{started}, 'self-restarted task remains running');
ok($restart_info->{generation} >= 3,
    'restart changed the lifecycle generation');

@IO::Async::Timer::Countdown::CREATED = ();
my $loop2 = MB356::Loop->new;
my $sched2 = Mediabot::Scheduler->new(loop => $loop2, logger => $log);
my $replacement_runs = 0;

$sched2->add(
    name        => 'replace_self',
    interval    => 86400,
    next_run_cb => sub { time() + 60 },
    cb          => sub {
        ok($sched2->remove('replace_self'),
            'calendar callback can remove its own task');
        $sched2->add(
            name        => 'replace_self',
            interval    => 86400,
            next_run_cb => sub { time() + 120 },
            cb          => sub { $replacement_runs++ },
            autostart   => 1,
        );
    },
    autostart => 1,
);

my $old_task_timer = $IO::Async::Timer::Countdown::CREATED[0];
$old_task_timer->fire;
is(scalar @IO::Async::Timer::Countdown::CREATED, 2,
    'remove/re-add creates only the replacement task timer');
is($loop2->active_count, 1,
    'old callback does not double-arm the replacement task');
my $replacement_info = $sched2->task_info('replace_self');
ok($replacement_info->{started}, 'replacement task is running');
is($replacement_runs, 0, 'replacement callback has not fired spuriously');

@IO::Async::Timer::Countdown::CREATED = ();
my $loop3 = MB356::Loop->new;
my $sched3 = Mediabot::Scheduler->new(loop => $loop3, logger => $log);
$sched3->add(
    name        => 'remove_failure',
    interval    => 86400,
    next_run_cb => sub { time() + 60 },
    cb          => sub { },
    autostart   => 1,
);
$loop3->{fail_remove} = 1;
ok(!$sched3->remove('remove_failure'),
    'remove fails when stopping the owned timer fails');
ok(defined $sched3->task_info('remove_failure'),
    'failed remove keeps the task registry entry');
ok($sched3->task_info('remove_failure')->{started},
    'failed stop leaves the task marked running');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $scheduler_src = slurp('Mediabot/Scheduler.pm');
like($scheduler_src, qr/generation\s*=>\s*0/,
    'Scheduler stores a lifecycle generation');
like($scheduler_src, qr/refaddr\(\$current\) == \$task_addr/,
    'calendar callback verifies task identity');
like($scheduler_src, qr/\$current->\{generation\} == \$generation/,
    'calendar callback verifies lifecycle generation');
like($scheduler_src, qr/return 0 if \$task->\{started\} && !\$self->stop\(\$name\)/,
    'remove refuses to orphan a timer after stop failure');
like($scheduler_src, qr/mb356-B1/,
    'Scheduler carries the mb356 marker');

my $partyline_src = slurp('Mediabot/Partyline.pm');
like($partyline_src, qr/Scheduler action failed for '\$name'/,
    'Partyline reports actual scheduler failures');
like($partyline_src, qr/is already running/,
    'Partyline distinguishes already-running tasks');
like($partyline_src, qr/is already stopped/,
    'Partyline distinguishes already-stopped tasks');
like($partyline_src, qr/mb356-B2/,
    'Partyline carries the mb356 marker');

done_testing();
