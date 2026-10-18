use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use lib '.', 't/lib';
our @SIGNALS;
our %OWNED;
BEGIN {
    *CORE::GLOBAL::kill=sub {
        if ($_[0] eq 'TERM' || $_[0] eq 'KILL') {
            push @main::SIGNALS, [@_];
            return CORE::kill($_[0],@_[1..$#_]) if $main::OWNED{$_[1]};
            return 1; # Never deliver a signal to an already-reaped test PID.
        }
        return CORE::kill($_[0],@_[1..$#_]);
    };
}
use Mediabot::CommandAsync;
use MB840AsyncFixture qw(fixture pump record_output);
no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg=\&record_output;
local *Mediabot::Helpers::botNotice=\&record_output;
local *Mediabot::Helpers::botAction=\&record_output;

{
    my ($bot,$ctx,$loop)=fixture();
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {Mediabot::Helpers::botPrivmsg($bot,'#test','done')});
    my @resources=grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $loop->notifiers;
    weaken($_) for @resources;
    ok(pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}}),'ordinary real worker completes');
    $loop->loop_once(0);
    is_deeply($bot->{out},[['#test','done']],'ordinary process/EOF barrier still delivers output');
    is(scalar(grep {defined} @resources),0,'completed worker releases its stream and timeout timer objects');
    my $weak_bot=$bot;weaken($weak_bot);undef $bot;
    ok(!defined($weak_bot),'completed callback graph does not retain the bot');
}

for my $mode (qw(current replaced)) {
    my ($bot,$ctx,$loop)=fixture();
    my $reaped=0;
    my $watch=IO::Async::Loop->can('watch_process');
    local *IO::Async::Loop::watch_process=sub {
        my ($l,$pid,$cb)=@_;
        return $watch->($l,$pid,sub {$reaped=1;$cb->(@_)});
    };
    local $Mediabot::CommandAsync::TIMEOUT_S=3600;
    local $Mediabot::CommandAsync::KILL_AFTER_S=3600;
    @SIGNALS=();
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {Mediabot::Helpers::botPrivmsg($bot,'#test','withheld EOF')});
    my ($pid)=map {$_->{pid}} values %{$bot->{_cmd_async_jobs}};
    my ($stream)=grep {$_->isa('IO::Async::Stream')} $loop->notifiers;
    my ($deadline)=grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers;
    # Withhold pipe delivery while retaining actual fork/watch_process events.
    # This models a missing EOF without leaving a background descendant.
    $loop->remove($stream);
    ok(pump($loop,sub {$reaped}),'actual child is reaped while pipe completion is withheld');
    $bot->{irc}=bless({connected=>1},'MB840AsyncFixture::IRC') if $mode eq 'replaced';
    is(scalar(keys %{$bot->{_cmd_async_jobs}}),1,'barrier waits for pipe completion before its deadline');
    $deadline->invoke_event('on_expire');
    my ($backstop)=grep {$_->isa('IO::Async::Timer::Countdown') && refaddr($_)!=refaddr($deadline)} $loop->notifiers;
    ok($backstop,'timeout arms its bounded escalation/backstop');
    $deadline->invoke_event('on_expire');
    is(scalar(grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers),2,'duplicate deadline cannot arm another backstop');
    $backstop->invoke_event('on_expire') if $backstop;
    is(scalar(keys %{$bot->{_cmd_async_jobs}}),0,'timeout finalizes even without an EOF callback');
    is(Mediabot::CommandAsync::async_stats_snapshot($bot)->{timeouts},1,'timeout is counted exactly once');
    is(scalar @{$bot->{out}},$mode eq 'current'?1:0,"$mode: timeout notice respects its captured connection");
    is(scalar(grep {$_->[1]==$pid} @SIGNALS),0,'an already reaped PID receives neither TERM nor KILL');
    my $before=scalar @{$bot->{out}};
    $deadline->invoke_event('on_expire');$backstop->invoke_event('on_expire') if $backstop;
    is(scalar @{$bot->{out}},$before,'retained deadline/backstop callbacks cannot report twice');
    is(scalar(grep {$_->[1]==$pid} @SIGNALS),0,'retained callbacks cannot signal the old PID');
    # Baseline cleanup for the intentionally withheld notifier, even on FAIL.
    if (keys %{$bot->{_cmd_async_jobs}}) {
        $loop->add($stream) unless $stream->loop;
        pump($loop,sub {!keys %{$bot->{_cmd_async_jobs}}});
    }
    eval {$stream->close_now};
    eval {$loop->remove($stream)};
    for my $timer (grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers) {
        $timer->stop;$loop->remove($timer);
    }
}

{
    my ($bot,$ctx,$loop)=fixture();
    my $reaped=0;
    my $watch=IO::Async::Loop->can('watch_process');
    local *IO::Async::Loop::watch_process=sub {
        my ($l,$pid,$cb)=@_;
        return $watch->($l,$pid,sub {$reaped=1;delete $OWNED{$pid};$cb->(@_)});
    };
    local $Mediabot::CommandAsync::TIMEOUT_S=3600;
    local $Mediabot::CommandAsync::KILL_AFTER_S=3600;
    pipe(my $gate_read,my $gate_write) or die $!;
    @SIGNALS=();
    Mediabot::CommandAsync::run_ctx_async($bot,$ctx,'stats',sub {
        my $byte;sysread($gate_read,$byte,1);
    });
    my ($pid)=map {$_->{pid}} values %{$bot->{_cmd_async_jobs}};
    $OWNED{$pid}=1;
    close $gate_read;
    my ($deadline)=grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers;
    $deadline->invoke_event('on_expire');
    my ($backstop)=grep {$_->isa('IO::Async::Timer::Countdown') && refaddr($_)!=refaddr($deadline)} $loop->notifiers;
    $backstop->invoke_event('on_expire');
    is(scalar keys %{$bot->{_cmd_async_jobs}},0,'live-child deadline also releases its job slot');
    is(Mediabot::CommandAsync::async_stats_snapshot($bot)->{timeouts},1,'live-child timeout counted once');
    ok(pump($loop,sub {$reaped}),'real watch_process still reaps the terminated owned child');
    close $gate_write;
    is_deeply([map {$_->[0]} grep {$_->[1]==$pid} @SIGNALS],['TERM','KILL'],
        'live owned child receives the normal TERM/KILL escalation');
    my $before=scalar @SIGNALS;
    $deadline->invoke_event('on_expire');$backstop->invoke_event('on_expire');
    is(scalar @SIGNALS,$before,'retained callbacks are inert after live-child finalization');
    is(scalar @{$bot->{out}},1,'late reap cannot duplicate its timeout notice');
}
done_testing;
