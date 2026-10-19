use strict;
use warnings;
use Test::More;
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::RSS::Runtime;

{
    package MB844RSSWorker;
    our (@jobs,$mode);
    sub start {
        my($class,%args)=@_;
        push @jobs,\%args;
        die "synthetic launch exception\n" if $mode eq 'throw';
        return undef if $mode eq 'refuse';
        $args{on_done}->({ok=>1,value=>{ok=>1,announcements=>[]}}) if $mode =~ /^inline/;
        die "exception after completion\n" if $mode eq 'inline_throw';
        return undef if $mode eq 'inline_refuse';
        return bless {},$class;
    }
    package MB844RSSLogger;
    sub log {push @{$_[0]{lines}},$_[2];1}
    package MB844RSSRuntime;
    our @ISA=('Mediabot::RSS::Runtime');
    sub _worker_done {
        my($self,$feed,$result)=@_;
        push @{$self->{completed}},[$feed->{id_rss_feed},$result];
        push @{$self->{busy_at_completion}},$self->inflight_count;
        $self->{completion_hook}->($self,$feed,$result) if $self->{completion_hook};
        return 1;
    }
    sub _drain_ready_channels {$_[0]{drains}++;1}
    sub _child_poll {{ok=>1,announcements=>[]}}
}
sub runtime844 {
    @MB844RSSWorker::jobs=();
    my $loop=IO::Async::Loop->really_new;
    my $r=MB844RSSRuntime->new(bot=>{_start_time=>1,logger=>bless({lines=>[]},'MB844RSSLogger')},
        loop=>$loop,worker_class=>'MB844RSSWorker');
    $r->{completed}=[];$r->{busy_at_completion}=[];
    return($r,$loop);
}
my $feed={id_rss_feed=>7,channel=>'#i/o',label=>'Example'};
for my $mode (qw(throw refuse inline inline_throw inline_refuse)) {
    my($r)=runtime844();$MB844RSSWorker::mode=$mode;
    my $value;my $ok=eval {$value=$r->_start_feed_worker($feed);1};
    ok($ok,"$mode: worker launch failure/completion cannot escape the scheduler");
    is($value//0,$mode eq 'inline'?1:0,"$mode: launch result is bounded");
    is($r->inflight_count,0,"$mode: terminal launch releases worker capacity");
    is(scalar keys %{$r->{inflight_channels}},0,"$mode: terminal launch releases the channel barrier");
    is(scalar keys %{$r->{workers}},0,"$mode: completed handle is not retained");
    is(scalar @{$r->{completed}},1,"$mode: exactly one terminal result reaches RSS processing");
    is($r->{busy_at_completion}[0],0,"$mode: capacity is released before invoking the consumer");
    $MB844RSSWorker::mode='defer';
    is($r->_start_feed_worker($feed),1,"$mode: the same feed can recover on a later attempt");
    is($r->inflight_count,1,"$mode: replacement attempt owns one slot");
}

{
    my($r)=runtime844();$MB844RSSWorker::mode='defer';
    $r->_start_feed_worker($feed);my $old=$MB844RSSWorker::jobs[-1];
    $old->{on_done}->({ok=>1,value=>{ok=>1,announcements=>[]}});
    $r->_start_feed_worker($feed);my $new=$MB844RSSWorker::jobs[-1];my $handle=$r->{workers}{7};
    $old->{on_done}->({ok=>1,value=>{ok=>1,announcements=>[{line=>'obsolete'}]}});
    is($r->inflight_count,1,'duplicate completion cannot release a successor slot');
    is($r->{workers}{7},$handle,'duplicate completion cannot remove the successor handle');
    is(scalar @{$r->{completed}},1,'duplicate completion cannot replace a fresh RSS candidate');
    $new->{on_done}->({ok=>1,value=>{ok=>1,announcements=>[]}});
    is($r->inflight_count,0,'successor releases its own slot');
    is(scalar @{$r->{completed}},2,'successor completion is consumed once');
}

{
    my($r)=runtime844();$MB844RSSWorker::mode='inline';
    my $successor;
    $r->{completion_hook}=sub {
        my($self)=@_;delete $self->{completion_hook};
        $MB844RSSWorker::mode='defer';$self->_start_feed_worker($feed);$successor=$self->{workers}{7};
    };
    $r->_start_feed_worker($feed);
    is($r->inflight_count,1,'inline completion may start a successor without losing its reservation');
    is($r->{workers}{7},$successor,'returning old launch cannot overwrite the successor handle');
    is(scalar @{$r->{completed}},1,'inline reentrancy has one completion');
}

{
    my($r)=runtime844();$MB844RSSWorker::mode='defer';
    $r->{completion_hook}=sub {die "consumer failed\n"};
    $r->_start_feed_worker($feed);my $job=$MB844RSSWorker::jobs[-1];
    ok(eval {$job->{on_done}->({ok=>1,value=>{ok=>1}});1},'a consumer exception is contained');
    is($r->inflight_count,0,'consumer exception does not pin capacity');
    delete $r->{completion_hook};
    is($r->_start_feed_worker($feed),1,'a later poll remains possible after consumer failure');
}

{
    # Real AsyncWorker setup can complete synchronously without a returned
    # handle. Exercise it rather than relying exclusively on injected workers.
    my($r)=runtime844();$r->{worker_class}='Mediabot::AsyncWorker';$r->{loop}=bless({},'MB844NoLoop');
    is($r->_start_feed_worker($feed),0,'native invalid-loop setup refuses the launch');
    is(scalar @{$r->{completed}},1,'native setup error is consumed once');
    is($r->inflight_count,0,'native setup failure releases capacity');
}

{
    my($r,$loop)=runtime844();$r->{worker_class}='Mediabot::AsyncWorker';
    is($r->_start_feed_worker($feed),1,'real offline fork/pipe RSS worker starts');
    my $deadline=time()+3;
    $loop->loop_once(.01) while $r->inflight_count && time()<$deadline;
    is($r->inflight_count,0,'real worker completion releases the slot');
    is(scalar @{$r->{completed}},1,'real worker value reaches RSS exactly once');
    ok($r->{completed}[0][1]{ok} && $r->{completed}[0][1]{value}{ok},'real child packet remains intact');
    is(scalar keys %{$r->{workers}},0,'real completed handle is released');
}
done_testing;
