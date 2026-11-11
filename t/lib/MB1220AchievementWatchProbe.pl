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
        result=>$done[0],registered=>$registered,
        successor=>($stage !~ /^(?:normal|inline)/ && $ok && $a->{_worker_process} && $a->{_worker_process}==$successor)?1:0};
}

print encode_json({setup=>\@setup,returned=>$returned,count=>scalar(@results),result=>$results[0],
    reaped=>$no_child,elapsed=>$elapsed,registered=>exists($a->{_worker_process})?1:0});
