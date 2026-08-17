# t/cases/833_mb651_asyncworker_contract.t
# =============================================================================
# MB651 — shared AsyncWorker contract.
#
# The abstraction is introduced and tested in isolation only. No existing
# consumer is migrated in this round.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";

    # Minimal deterministic IO::Async substitutes for this contract test.
    # Production code still lazy-loads the real IO::Async classes.
    $INC{'IO/Async/Stream.pm'} = __FILE__;
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
}

use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX qw(WNOHANG);
use Time::HiRes ();
use Mediabot::AsyncWorker;

{
    package IO::Async::Stream;

    sub new {
        my ($class, %args) = @_;
        my $fh = $args{read_handle};
        if ($fh) {
            my $flags = fcntl($fh, Fcntl::F_GETFL(), 0);
            fcntl($fh, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK())
                if defined $flags;
        }
        return bless {
            kind        => 'stream',
            read_handle => $fh,
            on_read     => $args{on_read},
            removed     => 0,
            eof_seen    => 0,
        }, $class;
    }
}

{
    package IO::Async::Timer::Countdown;

    sub new {
        my ($class, %args) = @_;
        return bless {
            kind      => 'timer',
            delay     => 0 + ($args{delay} // 0),
            on_expire => $args{on_expire},
            started   => 0,
            stopped   => 0,
            fired     => 0,
        }, $class;
    }

    sub start {
        my ($self) = @_;
        $self->{started} = Time::HiRes::time();
        $self->{stopped} = 0;
        return $self;
    }

    sub stop {
        my ($self) = @_;
        $self->{stopped} = 1;
        return $self;
    }
}

{
    package AW651::Loop;

    sub new {
        my ($class, %args) = @_;
        return bless {
            objects    => [],
            watchers   => {},
            fail_watch => $args{fail_watch} ? 1 : 0,
        }, $class;
    }

    sub add {
        my ($self, $obj) = @_;
        push @{ $self->{objects} }, $obj;
        return $obj;
    }

    sub remove {
        my ($self, $obj) = @_;
        $obj->{removed} = 1 if ref($obj) eq 'IO::Async::Stream';
        $obj->{stopped} = 1 if ref($obj) eq 'IO::Async::Timer::Countdown';
        return $obj;
    }

    sub watch_process {
        my ($self, $pid, $callback) = @_;
        die "synthetic watch_process failure\n" if $self->{fail_watch};
        $self->{watchers}{$pid} = $callback;
        return 1;
    }

    sub _pump_streams {
        my ($self) = @_;

        for my $obj (@{ $self->{objects} }) {
            next unless ref($obj) eq 'IO::Async::Stream';
            next if $obj->{removed} || $obj->{eof_seen};

            my $fh = $obj->{read_handle};
            next unless $fh;

            my $data = '';
            my $read = sysread($fh, $data, 8192);

            if (defined($read) && $read > 0) {
                my $buffer = $data;
                $obj->{on_read}->($obj, \$buffer, 0);
            }
            elsif (defined($read) && $read == 0) {
                $obj->{eof_seen} = 1;
                my $buffer = '';
                $obj->{on_read}->($obj, \$buffer, 1);
            }
            elsif ($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK}) {
                next;
            }
            else {
                $obj->{eof_seen} = 1;
                my $buffer = '';
                $obj->{on_read}->($obj, \$buffer, 1);
            }
        }
    }

    sub _pump_processes {
        my ($self) = @_;

        for my $pid (keys %{ $self->{watchers} }) {
            my $seen = waitpid($pid, POSIX::WNOHANG());
            next unless $seen == $pid;

            my $status = $?;
            my $callback = delete $self->{watchers}{$pid};
            $callback->($pid, $status) if $callback;
        }
    }

    sub _pump_timers {
        my ($self) = @_;
        my $now = Time::HiRes::time();

        for my $obj (@{ $self->{objects} }) {
            next unless ref($obj) eq 'IO::Async::Timer::Countdown';
            next if $obj->{stopped} || $obj->{fired} || !$obj->{started};
            next if $now < $obj->{started} + $obj->{delay};

            $obj->{fired} = 1;
            $obj->{on_expire}->();
        }
    }

    sub run_until {
        my ($self, $predicate, $limit) = @_;
        $limit = 2 unless defined $limit;
        my $deadline = Time::HiRes::time() + $limit;

        while (Time::HiRes::time() < $deadline) {
            $self->_pump_streams;
            $self->_pump_processes;
            $self->_pump_timers;

            return 1 if $predicate->();
            Time::HiRes::sleep(0.002);
        }

        return $predicate->() ? 1 : 0;
    }

    sub pump_for {
        my ($self, $seconds) = @_;
        my $deadline = Time::HiRes::time() + $seconds;
        while (Time::HiRes::time() < $deadline) {
            $self->_pump_streams;
            $self->_pump_processes;
            $self->_pump_timers;
            Time::HiRes::sleep(0.002);
        }
        return 1;
    }
}

sub _slurp_833 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_833('Mediabot/AsyncWorker.pm');

    $assert->like(
        $src,
        qr/package\s+Mediabot::AsyncWorker;/,
        'mb651-833: shared AsyncWorker module exists',
    );
    $assert->like(
        $src,
        qr/\bpipe\(\$read_fh,\s*\$write_fh\).*?\bmy \$pid = fork\(\)/s,
        'mb651-833: worker uses explicit pipe + fork',
    );
    $assert->like(
        $src,
        qr/->watch_process\(\s*\$pid,/s,
        'mb651-833: IO::Async owns normal child completion',
    );
    $assert->unlike(
        $src,
        qr/open\s*\([^;\n]*['"]-\|['"]/,
        'mb651-833: shared worker never uses Perl piped-open',
    );
    $assert->like(
        $src,
        qr/kill\(\$signal,\s*\$self->\{pid\}\)/,
        'mb651-833: TERM/KILL escalation is centralized',
    );
    $assert->like(
        $src,
        qr/\$self->\{forced\}\s*\|\|.*?\$self->\{child_done\}/s,
        'mb651-833: finalization has a liveness backstop',
    );
    $assert->like(
        $src,
        qr/worker_output_limit/,
        'mb651-833: bounded output has an explicit failure result',
    );
    $assert->like(
        $src,
        qr/POSIX::_exit\(0\)/,
        'mb651-833: child exits without inherited Perl destructors',
    );
    $assert->like(
        $src,
        qr/return 0 if \$self->\{finalized\}/,
        'mb651-833: completion is guarded against duplicate callbacks',
    );

    # Success path: the launcher returns before completion, the child result
    # crosses JSON, and the callback fires exactly once.
    my $loop = AW651::Loop->new;
    my @done;
    my $worker = Mediabot::AsyncWorker->start(
        loop       => $loop,
        label      => 'success-test',
        timeout    => 1,
        max_output => 4096,
        child      => sub {
            return {
                answer => 42,
                nested => [qw(alpha beta)],
            };
        },
        on_done => sub { push @done, shift },
    );

    $assert->ok($worker && $worker->pid,
        'mb651-833: successful launch returns a worker handle with pid');
    $assert->is(scalar(@done), 0,
        'mb651-833: launch is asynchronous and callback has not fired inline');
    $assert->ok(
        $loop->run_until(sub { @done == 1 }, 2),
        'mb651-833: success callback arrives through event-loop ownership',
    );
    $assert->is(scalar(@done), 1,
        'mb651-833: success callback fires exactly once');
    $assert->ok($done[0]{ok},
        'mb651-833: successful child produces ok result');
    $assert->is($done[0]{value}{answer}, 42,
        'mb651-833: JSON payload returns structured child value');
    $assert->is(
        join(',', @{ $done[0]{value}{nested} || [] }),
        'alpha,beta',
        'mb651-833: nested JSON value survives child-to-parent transport',
    );
    $assert->is($done[0]{exit}, 0,
        'mb651-833: normal exit status is reported');
    $assert->is($done[0]{signal}, 0,
        'mb651-833: normal completion reports no signal');
    $assert->ok($done[0]{elapsed_s} >= 0 && $done[0]{bytes} > 0,
        'mb651-833: completion contains bounded timing and byte metadata');
    $loop->pump_for(0.03);
    $assert->is(scalar(@done), 1,
        'mb651-833: late loop activity cannot duplicate completion');

    # Child exception becomes data rather than an inherited die in the parent.
    my $loop_die = AW651::Loop->new;
    my @died;
    my $worker_die = Mediabot::AsyncWorker->start(
        loop    => $loop_die,
        timeout => 1,
        child   => sub { die "synthetic child explosion\n" },
        on_done => sub { push @died, shift },
    );
    $assert->ok($worker_die,
        'mb651-833: exception scenario still launches asynchronously');
    $assert->ok(
        $loop_die->run_until(sub { @died == 1 }, 2),
        'mb651-833: child exception completes',
    );
    $assert->is($died[0]{error}, 'worker_exception',
        'mb651-833: child exception has stable error code');
    $assert->is($died[0]{stage}, 'child',
        'mb651-833: child exception identifies its stage');
    $assert->like($died[0]{detail}, qr/synthetic child explosion/,
        'mb651-833: bounded exception detail reaches the parent');

    # Oversized JSON is replaced inside the child by a bounded error envelope.
    my $loop_big = AW651::Loop->new;
    my @big;
    my $worker_big = Mediabot::AsyncWorker->start(
        loop       => $loop_big,
        timeout    => 1,
        max_output => 256,
        child      => sub { return { blob => ('x' x 8192) } },
        on_done    => sub { push @big, shift },
    );
    $assert->ok($worker_big,
        'mb651-833: bounded-output scenario launches');
    $assert->ok(
        $loop_big->run_until(sub { @big == 1 }, 2),
        'mb651-833: bounded-output scenario completes',
    );
    $assert->is($big[0]{error}, 'worker_output_limit',
        'mb651-833: oversized child value becomes worker_output_limit');
    $assert->ok(($big[0]{bytes} // 0) <= 256,
        'mb651-833: oversized value is replaced before crossing the pipe');

    # Timeout path: TERM then KILL for a TERM-resistant child, with callback
    # once and no need for caller-side waitpid.
    my $loop_timeout = AW651::Loop->new;
    my @timed;
    my $worker_timeout = Mediabot::AsyncWorker->start(
        loop        => $loop_timeout,
        label       => 'hung-test',
        timeout     => 0.05,
        term_grace  => 0.03,
        force_grace => 0.30,
        child       => sub {
            local $SIG{TERM} = 'IGNORE';
            Time::HiRes::sleep(5);
            return { impossible => 1 };
        },
        on_done => sub { push @timed, shift },
    );
    $assert->ok($worker_timeout,
        'mb651-833: timeout scenario launches');
    $assert->ok(
        $loop_timeout->run_until(sub { @timed == 1 }, 1),
        'mb651-833: TERM-resistant worker is bounded by timeout escalation',
    );
    $assert->is($timed[0]{error}, 'worker_timeout',
        'mb651-833: timeout has stable error code');
    $assert->ok($timed[0]{timed_out},
        'mb651-833: timeout metadata is explicit');
    $assert->ok($worker_timeout->{term_sent} && $worker_timeout->{kill_sent},
        'mb651-833: timeout path attempted TERM then KILL');
    $loop_timeout->pump_for(0.05);
    $assert->is(scalar(@timed), 1,
        'mb651-833: process/pipe/timer races still complete callback once');

    # Explicit cancellation reuses the same bounded termination contract.
    my $loop_cancel = AW651::Loop->new;
    my @cancelled;
    my $worker_cancel = Mediabot::AsyncWorker->start(
        loop        => $loop_cancel,
        timeout     => 5,
        term_grace  => 0.03,
        force_grace => 0.30,
        child       => sub {
            Time::HiRes::sleep(5);
            return { impossible => 1 };
        },
        on_done => sub { push @cancelled, shift },
    );
    $assert->ok($worker_cancel && $worker_cancel->cancel('shutdown requested'),
        'mb651-833: caller can cancel an in-flight worker');
    $assert->ok(
        $loop_cancel->run_until(sub { @cancelled == 1 }, 1),
        'mb651-833: cancelled worker completes',
    );
    $assert->is($cancelled[0]{error}, 'worker_cancelled',
        'mb651-833: cancellation has stable error code');
    $assert->like($cancelled[0]{detail}, qr/shutdown requested/,
        'mb651-833: cancellation preserves bounded reason');
    $assert->ok($cancelled[0]{cancelled},
        'mb651-833: cancellation metadata is explicit');


    # If watch_process rejects ownership, setup fails closed. This exceptional
    # path may reap manually because IO::Async never accepted the PID.
    my $loop_watch_fail = AW651::Loop->new(fail_watch => 1);
    my @watch_fail;
    my $watch_fail_worker = Mediabot::AsyncWorker->start(
        loop    => $loop_watch_fail,
        child   => sub {
            Time::HiRes::sleep(1);
            return { never => 'delivered' };
        },
        on_done => sub { push @watch_fail, shift },
    );
    $assert->ok(!defined $watch_fail_worker,
        'mb651-833: watch_process registration failure refuses launch');
    $assert->is(scalar(@watch_fail), 1,
        'mb651-833: watch_process setup failure completes exactly once');
    $assert->is($watch_fail[0]{error}, 'worker_setup',
        'mb651-833: watch_process setup failure is structured');
    $assert->is($watch_fail[0]{stage}, 'watch_process',
        'mb651-833: watch_process setup failure identifies ownership stage');

    # Invalid event-loop contract fails before fork and still reports once.
    {
        package AW651::BadLoop;
        sub new { bless {}, shift }
    }
    my @setup;
    my $bad = Mediabot::AsyncWorker->start(
        loop    => AW651::BadLoop->new,
        child   => sub { return { ok => 1 } },
        on_done => sub { push @setup, shift },
    );
    $assert->ok(!defined $bad,
        'mb651-833: missing event-loop contract refuses launch');
    $assert->is(scalar(@setup), 1,
        'mb651-833: setup failure callback fires exactly once');
    $assert->is($setup[0]{error}, 'worker_setup',
        'mb651-833: setup failure has stable error code');
    $assert->is($setup[0]{stage}, 'event_loop',
        'mb651-833: setup failure identifies event-loop stage');

    # This round must only introduce the abstraction; consumers stay untouched.
    for my $consumer (
        'Mediabot/Helpers.pm',
        'Mediabot/UserCommands.pm',
        'Mediabot/Achievements.pm',
        'Mediabot/CommandAsync.pm',
        'Mediabot/External/YouTube.pm',
    ) {
        my $consumer_src = _slurp_833($consumer);
        $assert->unlike(
            $consumer_src,
            qr/Mediabot::AsyncWorker/,
            "mb651-833: $consumer is not migrated in the abstraction-only round",
        );
    }
};
