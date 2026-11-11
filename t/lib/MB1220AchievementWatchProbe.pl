use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use Mediabot::Achievements;
{
    package MB1220::RejectLoop;
    sub add {die 'unexpected notifier add'}
    sub remove {die 'unexpected notifier remove'}
    sub watch_process {$_[0]{pid}=$_[1];die "watch rejected\n"}
    package MB1220::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
}
local $SIG{CHLD}='DEFAULT';
my $loop=bless {},'MB1220::RejectLoop';
my $log=bless {},'MB1220::Log';
my $a=bless {bot=>{loop=>$loop},logger=>$log},'Mediabot::Achievements';
my @results;
my $start=time;
my $returned=$a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @results,$_[0]});
my $elapsed=time-$start;
# Observe the postcondition before fixture cleanup: a successful reap means ECHILD.
my $pid=$loop->{pid} or die 'worker was not forked';
my $seen=waitpid($pid,WNOHANG);
my $no_child=$seen==-1 && $!{ECHILD} ? 1:0;
# The baseline leaks ownership; always clean our own child even on a failed test.
if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
my @setup;
require IO::Async::Loop;
require IO::Async::Stream;
require IO::Async::Timer::Countdown;
for my $stage (qw(stream_new stream_add timer_new timer_add timer_start normal inline inline_error)) {
    my $l=IO::Async::Loop->really_new;
    my $a=bless {bot=>{loop=>$l},logger=>bless({},'MB1220::Log'),_worker_timeout=>60},'Mediabot::Achievements';
    my ($pid,$watch_calls,$late_read,$late_tick);$watch_calls=0;
    my @done;my ($ok,$ret);
    my $watch=$l->can('watch_process');my $add=$l->can('add');
    my $sn=IO::Async::Stream->can('new');my $tn=IO::Async::Timer::Countdown->can('new');
    my $ts=IO::Async::Timer::Countdown->can('start');
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::watch_process=sub {
            my ($loop,$p,$cb)=@_;$pid=$p;
            $watch->($loop,$p,sub {$watch_calls++;$cb->(@_)});
        };
        local *IO::Async::Stream::new=sub {
            my ($class,%args)=@_;$late_read=$args{on_read};
            die "injected stream constructor\n" if $stage eq 'stream_new';
            $sn->(@_);
        };
        local *IO::Async::Timer::Countdown::new=sub {
            my ($class,%args)=@_;$late_tick=$args{on_expire};
            die "injected timer constructor\n" if $stage eq 'timer_new';
            $tn->(@_);
        };
        local *IO::Async::Loop::add=sub {
            my ($loop,$obj)=@_;my $v=$add->(@_);
            die "injected partial add\n" if ($stage eq 'stream_add' && $obj->isa('IO::Async::Stream'))
                || ($stage eq 'timer_add' && $obj->isa('IO::Async::Timer::Countdown'));
            if ($stage =~ /^inline/ && $obj->isa('IO::Async::Stream')) {
                my $until=time+2;
                while (!@done && time<$until) {$loop->loop_once(0.01)}
                die "injected error after inline completion\n" if $stage eq 'inline_error';
            }
            $v;
        };
        local *IO::Async::Timer::Countdown::start=sub {
            my $v=$ts->(@_);die "injected timer start\n" if $stage eq 'timer_start';$v;
        };
        $ok=eval {$ret=$a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @done,$_[0]});1};
    }
    my $before=scalar grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    my $registered=exists($a->{_worker_process})?1:0;
    my $successor={pid=>123};
    $a->{_worker_process}=$successor if $stage !~ /^(?:normal|inline)/ && $ok;
    my $until=time+2;
    while (!$watch_calls && time<$until) {$l->loop_once(0.01)}
    # Let buffered stream EOF complete the healthy worker too.
    while ($stage =~ /^(?:normal|inline)/ && !@done && time<$until) {$l->loop_once(0.01)}
    my $after=scalar grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    my $count=@done;
    if ($stage !~ /^(?:normal|inline)/ && $ok) {
        my $buf='late';$late_read->(undef,\$buf,1) if $late_read;
        $late_tick->() if $late_tick;
    }
    my $seen=waitpid($pid,WNOHANG);
    my $collected=$seen==-1 && $!{ECHILD}?1:0;
    # Baseline cleanup, confined to this probe's PID and private loop.
    if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
    for my $obj ($l->notifiers) {eval {$obj->stop};eval {$l->remove($obj)}}
    push @setup,{stage=>$stage,handled=>$ok&&$ret?1:0,before=>$before,after=>$after,
        count=>$count,late_count=>scalar(@done),watch_calls=>$watch_calls,reaped=>$collected,
        result=>$done[0],registered=>$registered,remaining=>scalar(keys %{$a->{_worker_children}||{}}),
        successor=>($stage !~ /^(?:normal|inline)/ && $ok && $a->{_worker_process} && $a->{_worker_process}==$successor)?1:0};
}

my @timeout;
for my $stage (qw(kill_new force_new kill_add force_add kill_start force_start)) {
    my $l=IO::Async::Loop->really_new;
    my $a=bless {bot=>{loop=>$l},logger=>bless({},'MB1220::Log'),_worker_timeout=>60},'Mediabot::Achievements';
    my ($pid,$tick,$calls);$calls=0;my @done;
    my $watch=$l->can('watch_process');my $add=$l->can('add');
    my $tn=IO::Async::Timer::Countdown->can('new');
    my $ts=IO::Async::Timer::Countdown->can('start');
    my (%kind,@late);my $number=0;my $handled;
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::watch_process=sub {
            my ($loop,$p,$cb)=@_;$pid=$p;
            $watch->($loop,$p,sub {$calls++;$cb->(@_)});
        };
        local *IO::Async::Timer::Countdown::new=sub {
            my ($class,%args)=@_;my $k=(qw(timeout kill force))[$number++];
            push @late,$args{on_expire};$tick=$args{on_expire} if $k eq 'timeout';
            die "injected escalation constructor\n" if $stage eq "${k}_new";
            my $obj=$tn->(@_);$kind{"$obj"}=$k;return $obj;
        };
        local *IO::Async::Loop::add=sub {
            my ($loop,$obj)=@_;my $v=$add->(@_);
            die "injected escalation add\n" if $stage eq (($kind{"$obj"}//'').'_add');return $v;
        };
        local *IO::Async::Timer::Countdown::start=sub {
            my $v=$ts->(@_);
            die "injected escalation start\n" if $stage eq (($kind{"$_[0]"}//'').'_start');return $v;
        };
        $a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @done,$_[0]});
        # Fire the actual timeout callback without waiting sixty seconds.
        $handled=eval {$tick->();1}?1:0;
    }
    my $immediate=scalar @done;
    my $successor={pid=>123};$a->{_worker_process}=$successor;
    my $until=time+2;
    while (!$calls && time<$until) {$l->loop_once(0.01)}
    my $late_ok=eval {$_->() for @late;1}?1:0;
    my $left=scalar grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    my $seen=waitpid($pid,WNOHANG);my $reaped=$seen==-1 && $!{ECHILD}?1:0;
    if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
    for my $obj ($l->notifiers) {eval {$obj->stop};eval {$l->remove($obj)}}
    push @timeout,{stage=>$stage,handled=>$handled,immediate=>$immediate,count=>scalar(@done),
        result=>$done[0],late_ok=>$late_ok,left=>$left,reaped=>$reaped,calls=>$calls,
        successor=>($a->{_worker_process} && $a->{_worker_process}==$successor)?1:0};
}

# Keep pipe EOF pending after the native process watcher has reaped the child.
my @retired;
for my $inline (0,1) {
    my $l=IO::Async::Loop->really_new;
    my $a=bless {bot=>{loop=>$l},logger=>bless({},'MB1220::Log'),_worker_timeout=>60},'Mediabot::Achievements';
    my ($pid,$read,$stream,$watched);$watched=0;my @done;
    my $watch=$l->can('watch_process');my $add=$l->can('add');
    my $sn=IO::Async::Stream->can('new');
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::watch_process=sub {
            my ($loop,$p,$cb)=@_;$pid=$p;
            $watch->($loop,$p,sub {$watched++;$cb->(@_)});
        };
        local *IO::Async::Stream::new=sub {
            my ($class,%args)=@_;$read=$args{on_read};$stream=$sn->(@_);return $stream;
        };
        local *IO::Async::Loop::add=sub {
            my ($loop,$obj)=@_;
            if ($obj->isa('IO::Async::Stream')) {
                if ($inline) {
                    my $until=time+2;
                    $l->loop_once(0.01) while !$watched && time<$until;
                }
                return $obj; # retain its pipe, but defer reading/EOF
            }
            return $add->(@_);
        };
        $a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @done,$_[0]});
    }
    my $until=time+2;
    $l->loop_once(0.01) while !$watched && time<$until;
    my $seen=waitpid($pid,WNOHANG);my $reaped=$seen==-1 && $!{ECHILD}?1:0;
    my $published=exists($a->{_worker_process})?1:0;
    my $pending=scalar @done;
    $a->shutdown_worker if $reaped; # Never signal an unverified fixture PID.
    my $successor={pid=>123};$a->{_worker_process}=$successor;
    my $buf='{}';$read->($stream,\$buf,1);$read->($stream,\$buf,1);
    my $left=scalar grep {$_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    push @retired,{inline=>$inline,reaped=>$reaped,watched=>$watched,published=>$published,
        pending=>$pending,count=>scalar(@done),left=>$left,
        successor=>($a->{_worker_process} && $a->{_worker_process}==$successor)?1:0};
    if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
    eval {$stream->close_now};
    for my $obj ($l->notifiers) {eval {$obj->stop};eval {$l->remove($obj)}}
}

{
    package MB1224::SlowDB;
    sub connect_isolated_handle {
        my ($self)=@_;
        $SIG{TERM}=$self->{ignore}?'IGNORE':'DEFAULT';
        syswrite($self->{ready},'R');
        while (1) {Time::HiRes::sleep(1)}
    }
}
my @shutdown;
require IO::Select;
for my $ignore (0,1) {
    pipe(my $ready,my $notify) or die "ready pipe: $!";
    my $l=IO::Async::Loop->really_new;
    my $log=bless {},'MB1220::Log';
    my $a=bless {bot=>{loop=>$l,db=>bless({ready=>$notify,ignore=>$ignore},'MB1224::SlowDB')},
        logger=>$log,_worker_timeout=>60},'Mediabot::Achievements';
    my ($pid,$watch_cb,$read);my @ticks;my @done;
    my $watch=$l->can('watch_process');my $sn=IO::Async::Stream->can('new');
    my $tn=IO::Async::Timer::Countdown->can('new');
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::watch_process=sub {
            my ($loop,$p,$cb)=@_;$pid=$p;$watch_cb=$cb;$watch->(@_);
        };
        local *IO::Async::Stream::new=sub {my ($class,%a)=@_;$read=$a{on_read};$sn->(@_)};
        local *IO::Async::Timer::Countdown::new=sub {my ($class,%a)=@_;push @ticks,$a{on_expire};$tn->(@_)};
        $a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @done,$_[0]});
    }
    close $notify;
    die 'child did not become ready' unless IO::Select->new($ready)->can_read(3);
    sysread($ready,my $byte,1)==1 or die 'missing readiness';close $ready;
    # No loop iterations: this models clean_and_exit's stopped event loop.
    my $started=time;my $ret=$a->shutdown_worker;my $elapsed=time-$started;
    my $seen=waitpid($pid,WNOHANG);my $reaped=$seen==-1 && $!{ECHILD}?1:0;
    my $left=scalar grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    my $slot=exists($a->{_worker_process})?1:0;
    $a->shutdown_worker;
    # Baseline cleanup before deliberately replaying retained callbacks.
    if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
    my $late_ok=eval {my $buf='{}';$read->(undef,\$buf,1);$watch_cb->($pid,0);$_->() for @ticks;1}?1:0;
    push @shutdown,{ignore=>$ignore,returned=>$ret,reaped=>$reaped,left=>$left,slot=>$slot,
        elapsed=>$elapsed,late_ok=>$late_ok,count=>scalar(@done)};
    eval {$l->unwatch_process($pid)};
    for my $obj ($l->notifiers) {eval {$obj->stop};eval {$l->remove($obj)}}
}

my @detached;
for my $replacement (0,1) {
    my $l=IO::Async::Loop->really_new;
    my $a=bless {bot=>{loop=>$l},logger=>bless({},'MB1220::Log'),_worker_timeout=>60},'Mediabot::Achievements';
    my (@pids,@watchers,@ticks,@done);
    my $watch=$l->can('watch_process');my $tn=IO::Async::Timer::Countdown->can('new');
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::watch_process=sub {
            my ($loop,$p,$cb)=@_;push @pids,$p;push @watchers,$cb;$watch->(@_);
        };
        local *IO::Async::Timer::Countdown::new=sub {
            my ($class,%args)=@_;push @ticks,$args{on_expire};$tn->(@_);
        };
        for my $index (0 .. $replacement) {
            pipe(my $ready,my $notify) or die "ready pipe: $!";
            $a->{bot}{db}=bless {ready=>$notify,ignore=>1},'MB1224::SlowDB';
            $a->_spawn_check_worker({nick=>'Probe',channel=>'#offline'},sub {push @done,$_[0]});
            close $notify;
            die 'detached child not ready' unless IO::Select->new($ready)->can_read(3);
            sysread($ready,my $byte,1)==1 or die 'missing readiness';close $ready;
            if (!$index) {
                $ticks[0]->(); # timeout: TERM ignored, kill/force countdowns armed
                $ticks[2]->(); # force result before the KILL countdown or watcher runs
            }
        }
    }
    my $before=scalar @done;
    my $owned=scalar keys %{$a->{_worker_children}||{}};
    my $started=time;my $ret=$a->shutdown_worker;my $elapsed=time-$started;
    my @reaped;
    for my $pid (@pids) {
        my $seen=waitpid($pid,WNOHANG);push @reaped,($seen==-1 && $!{ECHILD})?1:0;
        if ($seen==0) {kill 'KILL',$pid;while(waitpid($pid,0)==-1 && $!{EINTR}) {}}
    }
    for my $i (0..$#pids) {$watchers[$i]->($pids[$i],0)}
    $_->() for @ticks;
    my $left=scalar grep {$_->isa('IO::Async::Stream') || $_->isa('IO::Async::Timer::Countdown')} $l->notifiers;
    push @detached,{replacement=>$replacement,before=>$before,owned=>$owned,returned=>$ret,
        reaped=>\@reaped,count=>scalar(@done),left=>$left,elapsed=>$elapsed,
        remaining=>scalar(keys %{$a->{_worker_children}||{}}),repeat=>$a->shutdown_worker};
    for my $pid (@pids) {eval {$l->unwatch_process($pid)}}
    for my $obj ($l->notifiers) {eval {$obj->stop};eval {$l->remove($obj)}}
}

print encode_json({detached=>\@detached,shutdown=>\@shutdown,retired=>\@retired,timeout=>\@timeout,setup=>\@setup,returned=>$returned,count=>scalar(@results),result=>$results[0],
    reaped=>$no_child,elapsed=>$elapsed,registered=>exists($a->{_worker_process})?1:0});
