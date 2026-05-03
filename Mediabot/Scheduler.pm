package Mediabot::Scheduler;
# =============================================================================
# Mediabot::Scheduler — centralised periodic task manager
# =============================================================================
# Replaces the ad-hoc IO::Async::Timer::Periodic instances scattered across
# mediabot.pl with a single registry. Tasks can be added, removed, started,
# stopped and inspected at runtime (e.g. from the Partyline .timers command).
#
# Usage:
#   my $sched = Mediabot::Scheduler->new(loop => $loop, logger => $logger);
#
#   $sched->add(
#       name     => 'channel_ban_expire',
#       interval => 60,
#       cb       => sub { $bot->process_expired_channel_bans() },
#   );
#
#   $sched->start_all;
#   $sched->stop('channel_ban_expire');
#   my @names = $sched->task_names;
#   my $info  = $sched->task_info('channel_ban_expire');
# =============================================================================

use strict;
use warnings;
use IO::Async::Timer::Periodic;

our $VERSION = '1.00';

# ---------------------------------------------------------------------------
# new(%args)
# ---------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        loop    => $args{loop}    // die("Scheduler: loop required\n"),
        logger  => $args{logger}  // undef,
        _tasks  => {},            # name => { timer, interval, cb, started, ticks, last_tick }
    }, $class;
    return $self;
}

# ---------------------------------------------------------------------------
# add(name => $n, interval => $secs, cb => $sub, [autostart => 1])
# Register a named periodic task.  Croaks if name already registered.
# ---------------------------------------------------------------------------
sub add {
    my ($self, %args) = @_;

    my $name     = $args{name}     // die("Scheduler::add: name required\n");
    my $interval = $args{interval} // die("Scheduler::add: interval required\n");
    my $cb       = $args{cb}       // die("Scheduler::add: cb required\n");
    my $auto     = $args{autostart} // 0;

    die("Scheduler: task '$name' already registered\n")
        if exists $self->{_tasks}{$name};

    die("Scheduler: interval must be > 0\n")
        unless $interval > 0;

    my $task = {
        interval  => $interval,
        cb        => $cb,
        started   => 0,
        ticks     => 0,
        last_tick => 0,
        timer     => undef,
    };

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            $task->{ticks}++;
            $task->{last_tick} = time();
            $self->_log(4, "Scheduler: tick '$name' (#$task->{ticks})");
            eval { $cb->() };
            if ($@) {
                (my $err = $@) =~ s/\s+/ /g;
                $self->_log(1, "Scheduler: task '$name' error: $err");
            }
        },
    );

    $task->{timer} = $timer;
    $self->{_tasks}{$name} = $task;
    $self->{loop}->add($timer);

    $self->start($name) if $auto;
    $self->_log(3, "Scheduler: registered '$name' (interval=${interval}s autostart=$auto)");
    return $self;
}

# ---------------------------------------------------------------------------
# remove($name) — stop and unregister a task
# ---------------------------------------------------------------------------
sub remove {
    my ($self, $name) = @_;
    my $task = $self->{_tasks}{$name} or return;

    $self->stop($name);
    eval { $self->{loop}->remove($task->{timer}) };
    delete $self->{_tasks}{$name};
    $self->_log(3, "Scheduler: removed '$name'");
}

# ---------------------------------------------------------------------------
# start($name) / stop($name) — control individual tasks
# ---------------------------------------------------------------------------
sub start {
    my ($self, $name) = @_;
    my $task = $self->{_tasks}{$name} or return;
    return if $task->{started};
    eval { $task->{timer}->start };
    $task->{started} = 1;
    $self->_log(3, "Scheduler: started '$name'");
}

sub stop {
    my ($self, $name) = @_;
    my $task = $self->{_tasks}{$name} or return;
    return unless $task->{started};
    eval { $task->{timer}->stop };
    $task->{started} = 0;
    $self->_log(3, "Scheduler: stopped '$name'");
}

# ---------------------------------------------------------------------------
# start_all / stop_all
# ---------------------------------------------------------------------------
sub start_all {
    my ($self) = @_;
    $self->start($_) for keys %{ $self->{_tasks} };
}

sub stop_all {
    my ($self) = @_;
    $self->stop($_) for keys %{ $self->{_tasks} };
}

# ---------------------------------------------------------------------------
# task_names() — sorted list of registered task names
# ---------------------------------------------------------------------------
sub task_names {
    my ($self) = @_;
    return sort keys %{ $self->{_tasks} };
}

# ---------------------------------------------------------------------------
# task_info($name) — hashref with status info (for .timers Partyline cmd)
# ---------------------------------------------------------------------------
sub task_info {
    my ($self, $name) = @_;
    my $task = $self->{_tasks}{$name} or return undef;
    return {
        name      => $name,
        interval  => $task->{interval},
        started   => $task->{started},
        ticks     => $task->{ticks},
        last_tick => $task->{last_tick},
    };
}

# ---------------------------------------------------------------------------
# all_info() — list of task_info hashrefs, sorted by name
# ---------------------------------------------------------------------------
sub all_info {
    my ($self) = @_;
    return map { $self->task_info($_) } $self->task_names;
}

# ---------------------------------------------------------------------------
# Internal logger
# ---------------------------------------------------------------------------
sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{logger};
    $self->{logger}->log($level, $msg);
}

1;
