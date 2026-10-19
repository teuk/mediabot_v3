use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::AI::MetaRuntime;

my $cfg={pacing_us=>25000};
{
    my (@sent,@done,@arms);
    my $r=Mediabot::AI::MetaRuntime->new(schedule_cb=>sub {push @arms,[@_];1});
    $r->_emit('#test',['answer one','answer two','sources'],$cfg,sub {1},
        sub {push @done,shift},sub {push @sent,shift;1});
    is_deeply(\@sent,['answer one'],'first line remains immediate');
    is($arms[0][0],.025,'configured pacing is retained');
    $arms[0][1]->();$arms[0][1]->();
    is_deeply(\@sent,['answer one','answer two'],'one arm cannot send the following source line early');
    is(scalar @done,0,'old arm cannot prematurely finish delivery');
    is(scalar @arms,2,'source line has its own paced arm');
    $arms[1][1]->();$arms[1][1]->();$arms[0][1]->();
    is_deeply(\@sent,['answer one','answer two','sources'],'all three lines are sent exactly once');
    is_deeply(\@done,['answer one answer two sources'],'one complete terminal value preserves actual delivered text');
    my $weak=$r;weaken($weak);undef $r;
    ok(!defined $weak,'retained timer callbacks do not retain completed runtime');
}
for my $mode (qw(refuse throw)) {
    my (@sent,@done,@retained);
    my $r=Mediabot::AI::MetaRuntime->new(schedule_cb=>sub {
        push @retained,$_[1];die "private scheduler error\n" if $mode eq 'throw';0;
    });
    ok(eval {$r->_emit('#test',['first','second'],$cfg,sub {1},sub {push @done,shift},
        sub {push @sent,shift;1});1},"$mode: scheduling failure is contained");
    is_deeply(\@done,[undef],"$mode: partial answer has one aborted terminal result");
    $retained[0]->();$retained[0]->();
    is_deeply(\@sent,['first'],"$mode: retained failed arm cannot revive output");
    is(scalar @done,1,"$mode: rejected arm cannot repeat completion");
    my $weak=$r;weaken($weak);undef $r;
    ok(!defined $weak,"$mode: aborted runtime is released even if scheduler retains callback");
}
for my $mode (qw(inline inline_refuse inline_throw)) {
    my (@sent,@done,@retained);my $calls=0;
    my $r=Mediabot::AI::MetaRuntime->new(schedule_cb=>sub {
        push @retained,$_[1];
        if (++$calls==1) {
            $_[1]->();
            die "old scheduler frame failed\n" if $mode eq 'inline_throw';
            return 0 if $mode eq 'inline_refuse';
        }
        return 1;
    });
    ok(eval {$r->_emit('#test',['one','two','three'],$cfg,sub {1},sub {push @done,shift},
        sub {push @sent,shift;1});1},"$mode: inline arm is accepted safely");
    is_deeply(\@sent,['one','two'],"$mode: successor remains paced");
    is(scalar @done,0,"$mode: old launch outcome cannot abort successor");
    $retained[0]->();is(scalar @sent,2,"$mode: consumed old arm cannot bypass successor");
    $retained[1]->();is_deeply(\@done,['one two three'],"$mode: successor completes once");
}
for my $mode (qw(revoked guard_throws send_refuses send_throws)) {
    my (@sent,@done,@arms);my $live=1;
    my $r=Mediabot::AI::MetaRuntime->new(schedule_cb=>sub {push @arms,$_[1];1});
    $r->_emit('#test',['one','two','three'],$cfg,sub {
        die "guard failure\n" if !$live && $mode eq 'guard_throws';$live || $mode =~ /^send/;
    },sub {push @done,shift},sub {
        die "transport failure\n" if @sent && $mode eq 'send_throws';
        return 0 if @sent && $mode eq 'send_refuses';push @sent,shift;1;
    });
    $live=0;ok(eval {$arms[0]->();1},"$mode: late failure is contained");
    eval {$arms[0]->()};
    is_deeply(\@sent,['one'],"$mode: no later line is emitted");
    is_deeply(\@done,[undef],"$mode: partial answer completes once as aborted");
    is(scalar @arms,1,"$mode: failed delivery cannot arm a sources line");
}
{
    my (@done,@sent);my $r=Mediabot::AI::MetaRuntime->new;
    $r->_emit('#test',[],$cfg,sub {die 'empty has no guard'},sub {push @done,shift},sub {die 'empty has no output'});
    is_deeply(\@done,[undef],'empty output is aborted once without transport');
    @done=();
    $r->_emit('#test',['single'],$cfg,sub {1},sub {push @done,shift},sub {push @sent,shift;1});
    is_deeply(\@done,['single'],'single line needs no event loop');
    @done=();@sent=();
    $r->_emit('#test',['one','two'],$cfg,sub {1},sub {push @done,shift},sub {push @sent,shift;1});
    is_deeply(\@done,[undef],'missing native event loop releases partial delivery');
    is_deeply(\@sent,['one'],'missing loop never bursts the remaining answer');
}
{
    package MB846LoopBot;
    sub getLoop {$_[0]{loop}}
}
{
    my $loop=IO::Async::Loop->really_new;
    my $r=Mediabot::AI::MetaRuntime->new(bot=>bless({loop=>$loop},'MB846LoopBot'));
    my (@sent,@done);
    $r->_emit('#test',['native one','native two','native sources'],$cfg,sub {1},
        sub {push @done,shift},sub {push @sent,shift;1});
    is(scalar @sent,1,'real countdown defers second line');
    my ($timer)=grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers;
    my $retained=$timer->{on_expire};
    my $until=time()+3;$loop->loop_once(.01) while !@done && time()<$until;
    is_deeply(\@sent,['native one','native two','native sources'],'real loop delivers every paced line in order');
    is_deeply(\@done,['native one native two native sources'],'real loop terminates once');
    is(scalar(grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers),0,'real loop retains no completed pacing timer');
    $retained->();
    is(scalar @sent,3,'retained native expiry cannot repeat completed output');
    my $weak=$r;weaken($weak);undef $r;
    ok(!defined $weak,'retained native expiry does not retain completed runtime');
}
for my $stage (qw(add start)) {
    my $loop=IO::Async::Loop->really_new;
    my $r=Mediabot::AI::MetaRuntime->new(bot=>bless({loop=>$loop},'MB846LoopBot'));
    my (@done,@sent,@retained);my $failed_stage='';
    require IO::Async::Timer::Countdown;
    my $original_add=$loop->can('add');my $original_start=IO::Async::Timer::Countdown->can('start');
    no warnings qw(redefine once);
    local *IO::Async::Loop::add=sub {
        my ($l,$n)=@_;my $v=$original_add->(@_);
        if ($n->isa('IO::Async::Timer::Countdown')) {
            push @retained,$n->{on_expire};
            if ($stage eq 'add') {$failed_stage='add';die "private add failure\n"}
        }
        return $v;
    };
    local *IO::Async::Timer::Countdown::start=sub {
        if ($stage eq 'start') {$failed_stage='start';die "private start failure\n"}
        $original_start->(@_);
    };
    ok(eval {$r->_emit('#test',['one','two'],$cfg,sub {1},sub {push @done,shift},sub {push @sent,shift;1});1},
        "$stage: native partial timer setup is contained");
    is($failed_stage,$stage,"$stage: the requested native failure path was reached");
    is(scalar @retained,1,"$stage: actual timer expiry callback was retained");
    is_deeply(\@done,[undef],"$stage: native setup failure aborts once");
    is(scalar(grep {$_->isa('IO::Async::Timer::Countdown')} $loop->notifiers),0,"$stage: partially added timer is removed");
    $_->() for @retained;
    is_deeply(\@sent,['one'],"$stage: native stale expiry cannot revive failed output");
    is(scalar @done,1,"$stage: native stale expiry cannot repeat completion");
    my $weak=$r;weaken($weak);undef $r;
    ok(!defined $weak,"$stage: native failed timer callback does not retain runtime");
}
{
    my (@sent,@done,@arms);
    my $r=Mediabot::AI::MetaRuntime->new(schedule_cb=>sub {push @arms,$_[1];1});
    $r->_emit('#test',['pending one','pending two'],$cfg,sub {1},
        sub {push @done,shift},sub {push @sent,shift;1});
    my $weak=$r;weaken($weak);undef $r;
    ok(defined $weak,'a pending delivery retains the runtime until its terminal arm');
    $arms[0]->();
    is_deeply(\@done,['pending one pending two'],'pending delivery can finish after caller releases runtime');
    ok(!defined $weak,'terminal arm releases the runtime while old callback remains retained');
}
done_testing;
