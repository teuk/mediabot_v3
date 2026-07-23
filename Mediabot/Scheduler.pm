package Mediabot::Scheduler;
# =============================================================================
# Mediabot::Scheduler — centralised task manager
# =============================================================================
# Periodic tasks keep using IO::Async::Timer::Periodic.
# Calendar tasks use a re-armed IO::Async::Timer::Countdown whose next epoch is
# recalculated after every run. This keeps wall-clock jobs aligned across
# restarts and DST transitions.
# =============================================================================

use strict;
use warnings;
use IO::Async::Timer::Periodic;
use Time::HiRes ();
use IO::Async::Timer::Countdown;
use Scalar::Util qw(weaken refaddr);

our $VERSION = '1.11';

# mb556-B1: optional Prometheus projection (mb550 pattern) plus the timed
# task-callback helper shared by the periodic and calendar paths. Any task
# slower than one second names itself at level 3, and every duration feeds
# the mediabot_scheduler_tick_seconds{task} histogram. Best-effort: without
# Metrics, only the SLOW log remains; errors keep their existing semantics.
sub set_metrics {
    my ($self, $metrics) = @_;
    $self->{metrics} = $metrics;
    return 1;
}

sub _run_task_callback {
    my ($self, $name, $cb) = @_;

    my $t0 = [ Time::HiRes::gettimeofday() ];
    eval { $cb->() };
    my $err = $@;
    my $elapsed = Time::HiRes::tv_interval($t0);

    if ($self->{metrics} && eval { $self->{metrics}->can('observe') }) {
        eval { $self->{metrics}->observe('mediabot_scheduler_tick_seconds',
            $elapsed, { task => $name }); 1 };
    }
    if ($elapsed > 1.0) {
        $self->_log(3, sprintf("SLOW SCHEDULER: task '%s' took %.2fs", $name, $elapsed));
    }
    if ($err) {
        (my $clean = $err) =~ s/\s+/ /g;
        $self->_log(1, "Scheduler: task '$name' error: $clean");
    }

    return 1;
}

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        loop    => $args{loop}    // die("Scheduler: loop required\n"),
        logger  => $args{logger}  // undef,
        _tasks  => {},
    }, $class;
    return $self;
}

# ---------------------------------------------------------------------------
# add(name => $n, interval => $secs, cb => $sub,
#     [first_interval => $secs], [next_run_cb => $sub], [autostart => 1])
#
# next_run_cb receives the current epoch and must return the next absolute epoch.
# It selects calendar mode: a one-shot countdown is re-created after every run.
# ---------------------------------------------------------------------------
sub add {
    my ($self, %args) = @_;

    my $name        = $args{name}        // die("Scheduler::add: name required\n");
    my $interval    = $args{interval}    // die("Scheduler::add: interval required\n");
    my $cb          = $args{cb}          // die("Scheduler::add: cb required\n");
    my $auto        = $args{autostart}   // 0;
    my $first       = $args{first_interval};
    my $next_run_cb = $args{next_run_cb};

    if (defined $first) {
        die("Scheduler: first_interval must be a non-negative integer\n")
            unless $first =~ /^\d+$/;
    }

    die("Scheduler: next_run_cb must be a CODE reference\n")
        if defined($next_run_cb) && ref($next_run_cb) ne 'CODE';

    die("Scheduler: first_interval and next_run_cb are mutually exclusive\n")
        if defined($first) && defined($next_run_cb);

    die("Scheduler: invalid task name\n")
        unless defined($name) && $name =~ /^[A-Za-z0-9_.:-]{1,64}$/;

    die("Scheduler: task '$name' already registered\n")
        if exists $self->{_tasks}{$name};

    die("Scheduler: interval must be a positive integer\n")
        unless defined($interval) && $interval =~ /^\d+$/ && $interval > 0;

    die("Scheduler: cb must be a CODE reference\n")
        unless ref($cb) eq 'CODE';

    my $mode = $next_run_cb ? 'calendar' : 'periodic';
    my $task = {
        mode           => $mode,
        interval       => 0 + $interval,
        first_interval => defined($first) ? 0 + $first : undef,
        next_run_cb    => $next_run_cb,
        cb             => $cb,
        started        => 0,
        ticks          => 0,
        last_tick      => 0,
        start_time     => 0,
        next_run       => 0,
        timer          => undef,
        generation     => 0,   # mb356-B1: invalidate stale lifecycle callbacks
    };

    $self->{_tasks}{$name} = $task;

    if ($mode eq 'periodic') {
        my $timer = IO::Async::Timer::Periodic->new(
            interval => $interval,
            (defined $first ? (first_interval => $first) : ()),
            on_tick  => sub {
                my $now = time();
                $task->{ticks}++;
                $task->{last_tick} = $now;
                $task->{next_run}  = $now + $task->{interval};
                $self->_log(4, "Scheduler: tick '$name' (#$task->{ticks})");

                $self->_run_task_callback($name, $cb);
            },
        );

        $task->{timer} = $timer;
        my $ok = eval {
            $self->{loop}->add($timer);
            1;
        };
        unless ($ok) {
            delete $self->{_tasks}{$name};
            die($@ || "Scheduler: failed to add timer '$name' to loop\n");
        }
    }

    if ($auto) {
        unless ($self->start($name)) {
            my $timer = $task->{timer};
            delete $self->{_tasks}{$name};
            eval { $self->{loop}->remove($timer) if $timer };
            die("Scheduler: failed to autostart '$name'\n");
        }
    }

    $self->_log(3,
        "Scheduler: registered '$name' (mode=$mode interval=${interval}s autostart=$auto)");
    return $self;
}

# Arm one calendar occurrence. The task registry and loop are the strong owners;
# callback lexicals are weak to avoid timer/callback/scheduler reference cycles.
sub _arm_calendar {
    my ($self, $name) = @_;

    my $task = $self->{_tasks}{$name} or return 0;
    return 0 unless $task->{mode} eq 'calendar';
    return 0 unless $task->{started};

    # mb356-B1: capture both the task identity and its lifecycle generation.
    # A callback may restart/remove/re-add its own task. In that case the old
    # callback must not arm another timer after the callback returns.
    my $task_addr  = refaddr($task);
    my $generation = $task->{generation};

    my $now = time();
    my $next = eval { $task->{next_run_cb}->($now) };
    if ($@ || !defined($next) || ref($next) || "$next" !~ /^\d+$/ || $next <= $now) {
        (my $err = $@ || "invalid next epoch") =~ s/\s+/ /g;
        $self->_log(1, "Scheduler: cannot arm calendar task '$name': $err");
        return 0;
    }

    $next = int($next);
    my $delay = $next - $now;
    $delay = 1 if $delay < 1;

    my $weak_self = $self;
    weaken($weak_self);

    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay     => $delay,
        on_expire => sub {
            my $scheduler = $weak_self or return;
            my $fired     = $timer     or return;
            my $current   = $scheduler->{_tasks}{$name} or return;

            # mb356-B1: ignore stale callbacks from a previous lifecycle or a
            # removed/re-added task with the same name.
            return unless refaddr($current) == $task_addr;
            return unless $current->{generation} == $generation;
            return unless $current->{timer}
                && refaddr($current->{timer}) == refaddr($fired);

            eval { $scheduler->{loop}->remove($fired) };
            $current->{timer}    = undef;
            $current->{next_run} = 0;

            return unless $current->{started};

            my $tick_now = time();
            $current->{ticks}++;
            $current->{last_tick} = $tick_now;
            $scheduler->_log(4,
                "Scheduler: calendar tick '$name' (#$current->{ticks})");

            $scheduler->_run_task_callback($name, $current->{cb});

            $current = $scheduler->{_tasks}{$name} or return;
            return unless refaddr($current) == $task_addr;
            return unless $current->{generation} == $generation;
            return unless $current->{started};

            unless ($scheduler->_arm_calendar($name)) {
                $current->{started} = 0;
                $scheduler->_log(1,
                    "Scheduler: calendar task '$name' stopped because re-arm failed");
            }
        },
    );

    my $ok = eval {
        $task->{timer}    = $timer;
        $task->{next_run} = $next;
        $self->{loop}->add($timer);
        weaken($timer);
        $task->{timer}->start;
        1;
    };

    unless ($ok) {
        my $err = $@ || 'unknown error';
        my $owned = $task->{timer};
        eval { $owned->stop if $owned && $owned->can('stop') };
        eval { $self->{loop}->remove($owned) if $owned };
        $task->{timer}    = undef;
        $task->{next_run} = 0;
        $err =~ s/\s+/ /g;
        $self->_log(1, "Scheduler: failed to arm '$name': $err");
        return 0;
    }

    my @lt = localtime($next);
    my $when = sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0]);
    $self->_log(3, "Scheduler: armed '$name' for $when (in ${delay}s)");
    return 1;
}

sub remove {
    my ($self, $name) = @_;

    my $task = $self->{_tasks}{$name} or return 0;

    # mb356-B1: never delete the registry entry when stop failed. Otherwise a
    # still-owned timer can survive without a task record.
    return 0 if $task->{started} && !$self->stop($name);

    my $timer = $task->{timer};
    my $ok = eval {
        $self->{loop}->remove($timer) if $timer;
        1;
    };

    if (!$ok) {
        (my $err = $@ || 'unknown error') =~ s/\s+/ /g;
        $self->_log(1, "Scheduler: failed to remove '$name': $err");
        return 0;
    }

    $task->{generation}++;
    delete $self->{_tasks}{$name};
    $self->_log(3, "Scheduler: removed '$name'");
    return 1;
}

sub start {
    my ($self, $name) = @_;

    my $task = $self->{_tasks}{$name} or return 0;
    return 1 if $task->{started};

    # mb356-B1: publish the new lifecycle before arming. The calendar callback
    # captures this generation and can detect a restart performed by its own cb.
    my $now = time();
    $task->{generation}++;
    $task->{started}    = 1;
    $task->{start_time} = $now;
    $task->{next_run}   = 0;

    my $ok = eval {
        if ($task->{mode} eq 'calendar') {
            die("calendar arm failed\n") unless $self->_arm_calendar($name);
        }
        else {
            $task->{timer}->start;
            my $first = defined($task->{first_interval})
                ? $task->{first_interval}
                : $task->{interval};
            $task->{next_run} = $now + $first;
        }
        1;
    };

    if (!$ok) {
        (my $err = $@ || 'unknown error') =~ s/\s+/ /g;
        $task->{generation}++;
        $task->{started}  = 0;
        $task->{next_run} = 0;
        $self->_log(1, "Scheduler: failed to start '$name': $err");
        return 0;
    }

    $self->_log(3, "Scheduler: started '$name'");
    return 1;
}

sub stop {
    my ($self, $name) = @_;

    my $task = $self->{_tasks}{$name} or return 0;
    return 1 unless $task->{started};

    my $ok = eval {
        if ($task->{mode} eq 'calendar') {
            my $timer = $task->{timer};
            if ($timer) {
                $timer->stop if $timer->can('stop');
                $self->{loop}->remove($timer);
            }
            $task->{timer} = undef;
        }
        else {
            $task->{timer}->stop;
        }
        1;
    };

    if (!$ok) {
        (my $err = $@ || 'unknown error') =~ s/\s+/ /g;
        $self->_log(1, "Scheduler: failed to stop '$name': $err");
        return 0;
    }

    # mb356-B1: changing generation invalidates any callback that was already
    # executing when stop/restart/remove changed the task lifecycle.
    $task->{generation}++;
    $task->{started}  = 0;
    $task->{next_run} = 0;
    $self->_log(3, "Scheduler: stopped '$name'");
    return 1;
}

sub restart {
    my ($self, $name) = @_;

    my $task = $self->{_tasks}{$name} or return 0;

    return 0 unless $self->stop($name);
    return 0 unless $self->start($name);

    $self->_log(3, "Scheduler: restarted '$name'");
    return 1;
}

sub start_all {
    my ($self) = @_;
    $self->start($_) for keys %{ $self->{_tasks} };
}

sub stop_all {
    my ($self) = @_;
    $self->stop($_) for keys %{ $self->{_tasks} };
}

sub task_names {
    my ($self) = @_;
    return sort keys %{ $self->{_tasks} };
}

sub task_info {
    my ($self, $name) = @_;
    my $task = $self->{_tasks}{$name} or return undef;
    return {
        name           => $name,
        mode           => $task->{mode},
        interval       => $task->{interval},
        first_interval => $task->{first_interval},
        started        => $task->{started},
        ticks          => $task->{ticks},
        last_tick      => $task->{last_tick},
        start_time     => $task->{start_time} // 0,
        next_run       => $task->{next_run} // 0,
        generation     => $task->{generation} // 0,
    };
}

sub all_info {
    my ($self) = @_;
    return map { $self->task_info($_) } $self->task_names;
}

sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{logger};
    $self->{logger}->log($level, $msg);
}

1;
