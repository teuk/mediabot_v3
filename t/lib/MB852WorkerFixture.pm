package MB852WorkerFixture;
use strict;
use warnings;
use Exporter 'import';
use Time::HiRes qw(time);
use IO::Select;
use IO::Async::Loop::Poll;
use IO::Async::Timer::Countdown;
use IO::Async::Stream;
our @EXPORT_OK = qw(new_loop with_faults pump gated_child cleanup signals);
our (@SIGNALS, %OWNED);
BEGIN {
    *CORE::GLOBAL::kill = sub {
        if ($_[0] eq 'TERM' || $_[0] eq 'KILL') {
            push @MB852WorkerFixture::SIGNALS, [@_];
            return CORE::kill($_[0], @_[1..$#_]) if $MB852WorkerFixture::OWNED{$_[1]};
            return 1; # A retained callback must never signal a reaped PID.
        }
        return CORE::kill($_[0], @_[1..$#_]);
    };
}
{
    package MB852WorkerFixture::Loop;
    our @ISA = ('IO::Async::Loop::Poll');
    sub add {
        my ($self, $obj) = @_;
        if ($obj->isa('IO::Async::Timer::Countdown')) {
            $obj->{mb852_number} = 1 + @{$self->{mb852_timers} ||= []};
            push @{$self->{mb852_timers}}, $obj;
        }
        $self->SUPER::add($obj);
        die "injected timer add failure\n" if $obj->{mb852_number}
            && ($self->{mb852_faults}{$obj->{mb852_number}} // '') eq 'add';
        return;
    }
    sub watch_process {
        my ($self, $pid, $cb) = @_;
        $MB852WorkerFixture::OWNED{$pid} = 1;
        $self->{mb852_pids}{$pid} = 1;
        return $self->SUPER::watch_process($pid, sub {
            delete $MB852WorkerFixture::OWNED{$_[0]};
            delete $self->{mb852_pids}{$_[0]};
            $self->{mb852_reaped}++;
            $cb->(@_);
        });
    }
}
sub new_loop {
    my ($faults) = @_;
    my $loop = MB852WorkerFixture::Loop->new;
    $loop->{mb852_faults} = $faults || {};
    $loop->{mb852_pids} = {};
    $loop->{mb852_timers} = [];
    @SIGNALS = ();
    return $loop;
}
sub with_faults {
    my ($code) = @_;
    my $start = IO::Async::Timer::Countdown->can('start');
    no warnings qw(redefine once);
    local *IO::Async::Timer::Countdown::start = sub {
        my ($timer) = @_;
        $start->(@_);
        my $loop = $timer->loop;
        die "injected timer start failure\n" if $loop && $timer->{mb852_number}
            && ($loop->{mb852_faults}{$timer->{mb852_number}} // '') eq 'start';
        return $timer;
    };
    return $code->();
}
sub pump {
    my ($loop, $until, $seconds) = @_;
    my $end = time() + ($seconds // 2);
    $loop->loop_once(0.005) while !$until->() && time() < $end;
    return $until->() ? 1 : 0;
}
sub gated_child {
    pipe(my $gate_read, my $gate_write) or die $!;
    pipe(my $ready_read, my $ready_write) or die $!;
    my $child = sub {
        close $gate_write; close $ready_read;
        local $SIG{TERM} = 'IGNORE';
        syswrite($ready_write, 'R'); close $ready_write;
        my $byte; sysread($gate_read, $byte, 1); close $gate_read;
        return {released => 1};
    };
    my $ready = sub {
        close $gate_read; close $ready_write;
        return 0 unless IO::Select->new($ready_read)->can_read(2);
        my $byte; return sysread($ready_read, $byte, 1) && $byte eq 'R';
    };
    my $release = sub {
        close $gate_read if defined fileno($gate_read);
        close $gate_write if defined fileno($gate_write);
        close $ready_read if defined fileno($ready_read);
        close $ready_write if defined fileno($ready_write);
    };
    return ($child, $ready, $release);
}
sub signals { my ($pid) = @_; return [map {$_->[0]} grep {$_->[1] == $pid} @SIGNALS] }
sub cleanup {
    my ($loop) = @_;
    CORE::kill('KILL', $_) for grep {$OWNED{$_}} keys %{$loop->{mb852_pids}};
    pump($loop, sub {!keys %{$loop->{mb852_pids}}});
    for my $obj ($loop->notifiers) {
        eval {$obj->stop} if $obj->isa('IO::Async::Timer::Countdown');
        eval {$obj->close_now} if $obj->isa('IO::Async::Stream');
        eval {$loop->remove($obj)};
    }
    $loop->{mb852_timers} = [];
}
1;
