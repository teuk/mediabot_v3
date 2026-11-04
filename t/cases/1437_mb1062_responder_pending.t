use strict;
use warnings;
use Test::More;
BEGIN {
    $MB1062::now=1_900_000_000;
    *CORE::GLOBAL::time=sub () {$MB1062::now};
}
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Scalar::Util qw(weaken);
use Time::HiRes ();
use Text::Balanced qw(extract_codeblock);
use Mediabot::DBCommands;
use Mediabot::AI::ConversationRuntimeState;

{
    package MB1062::Log;
    sub log {my ($s,$level,$text)=@_;push @{$s->{attempts}},[$level,$text];die "private logger detail\n" if $level==1 && $s->{throws};push @{$s->{lines}},[$level,$text];1}
    package MB1062::IRC;
    sub is_connected {$_[0]{connected}}
    package MB1062::DB;
    sub prepare {bless {},'MB1062::Statement'}
    package MB1062::Statement;
    sub execute {1} sub fetchrow_hashref {undef} sub finish {1}
    package MB1062::Bot;
    our @ISA=('Mediabot::DBCommands');
    sub getQuit {$_[0]{quit}}
    sub checkResponder {0}
    sub doResponder {
        my ($s,@request)=@_;
        $s->{during}->() if $s->{during};
        die "private responder driver detail\n" if $s->{fail};
        push @{$s->{sent}},\@request;
        $s->setLastReponderTs(time());
        return 1;
    }
}

# Execute the actual responder branch from the main public callback. This
# catches wiring regressions as well as the burst in the original inline timer.
open my $fh,'<:encoding(UTF-8)','mediabot.pl' or die $!;
my $main=do {local $/;<$fh>};close $fh;
my $start=index($main,'my $luckyShot = rand(100);');
my $conditional=index($main,'if ( $luckyShot >=',$start);
my $brace=index($main,'{',$conditional);
die 'native responder branch missing' unless $start>=0 && $conditional>$start && $brace>$conditional;
my ($block)=extract_codeblock(substr($main,$brace));
die 'native responder block is incomplete' unless defined($block) && length($block);
my $branch=eval 'sub {my ($mediabot,$loop,$message,$who,$where,$what,@tArgs)=@_;'.substr($main,$start,$brace-$start).$block.'}';
die $@ unless $branch;

sub fixture_1437 {
    $MB1062::now=1_900_000_000;
    my $loop=IO::Async::Loop->really_new;
    my $state=Mediabot::AI::ConversationRuntimeState->new;
    $state->mark_connected;$state->mark_joined('#test');$state->mark_joined('#other');
    return bless {loop=>$loop,irc=>bless({connected=>1},'MB1062::IRC'),wit_runtime_state=>$state,
        logger=>bless({lines=>[]},'MB1062::Log'),dbh=>bless({},'MB1062::DB'),
        last_responder_ts=>0,sent=>[]},'MB1062::Bot';
}
sub invoke_1437 {
    my ($bot,$label,$channel)=@_;
    return eval {$branch->($bot,$bot->{loop},undef,$label// 'Alice',$channel// '#test','ping','argument');1} ? '' : "$@";
}
sub timers_1437 {grep {$_->isa('IO::Async::Timer::Countdown')} $_[0]{loop}->notifiers}
sub cleanup_1437 {my ($b)=@_;for my $t(timers_1437($b)) {$t->stop;$b->{loop}->remove($t)}}

my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
{
    my $b=fixture_1437();invoke_1437($b,'Alice');invoke_1437($b,'Bob');invoke_1437($b,'Carol','#other');
    my @timers=timers_1437($b);
    is(scalar(@timers),1,'a burst across callers/channels reserves one delayed response for the global cooldown');
    $_->invoke_event('on_expire') for @timers;
    is_deeply($b->{sent},[[undef,'Alice','#test','ping','argument']],'only the first accepted request is delivered');
    is_deeply([scalar(timers_1437($b)),exists($b->{_responder_pending})?1:0],[0,0],
        'completion removes the native countdown and releases its slot');
    $_->invoke_event('on_expire') for @timers;
    is(scalar(@{$b->{sent}}),1,'a duplicate expiry cannot repeat the response');
    cleanup_1437($b);
}
{
    my $b=fixture_1437();$b->{last_responder_ts}=$MB1062::now-599;
    invoke_1437($b);is(scalar(timers_1437($b)),0,'the last second of the ten-minute cooldown remains blocked');
    ++$MB1062::now;invoke_1437($b);my ($t)=timers_1437($b);
    ok($t,'the exact ten-minute deadline accepts a response');
    $b->{last_responder_ts}=$MB1062::now;
    $t->invoke_event('on_expire') if $t;
    is_deeply([scalar(@{$b->{sent}}),scalar(timers_1437($b))],[0,0],
        'a newer successful response revokes the old pending attempt at delivery');
    cleanup_1437($b);
}
for my $mode (qw(disconnected replaced quit left rejoined)) {
    my $b=fixture_1437();invoke_1437($b);my ($t)=timers_1437($b);
    if ($mode eq 'disconnected') {$b->{irc}{connected}=0}
    elsif ($mode eq 'replaced') {$b->{irc}=bless({connected=>1},'MB1062::IRC')}
    elsif ($mode eq 'quit') {$b->{quit}=1}
    else {$b->{wit_runtime_state}->mark_left('#test');$b->{wit_runtime_state}->mark_joined('#test') if $mode eq 'rejoined'}
    $t->invoke_event('on_expire') if $t;
    is_deeply([scalar(@{$b->{sent}}),scalar(timers_1437($b))],[0,0],"$mode: stale output is discarded and its timer is removed");
    cleanup_1437($b);
}
{
    my $b=fixture_1437();invoke_1437($b);my ($old)=timers_1437($b);
    $b->onStartTimers();invoke_1437($b,'Bob');my @current=timers_1437($b);
    $old->invoke_event('on_expire') if $old;
    is_deeply([scalar(@current),scalar(@{$b->{sent}})],[1,0],
        'native login timer reload cancels pending work and an old callback cannot consume its replacement');
    $_->invoke_event('on_expire') for @current;
    is_deeply([map {$_->[1]} @{$b->{sent}}],['Bob'],'the replacement request still delivers normally');
    cleanup_1437($b);
}
for my $stage (qw(add start callback)) {
    my $b=fixture_1437();my ($t,$error);$b->{logger}{throws}=1;
    my $add=IO::Async::Loop->can('add');my $start=IO::Async::Timer::Countdown->can('start');
    {
        no warnings qw(redefine once);
        local *IO::Async::Loop::add=sub {my $r=$add->(@_);$t=$_[1];die "private timer add detail\n" if $stage eq 'add';return $r};
        local *IO::Async::Timer::Countdown::start=sub {my $r=$start->(@_);die "private timer start detail\n" if $stage eq 'start';return $r};
        $error=invoke_1437($b);
        if ($stage eq 'callback') {$b->{fail}=1;my ($timer)=timers_1437($b);$error=eval {$timer->invoke_event('on_expire');1}?'':"$@"}
    }
    my @errors=map {$_->[1]} grep {$_->[0]==1} @{$b->{logger}{attempts}};
    is_deeply([$error,scalar(timers_1437($b)),exists($b->{_responder_pending})?1:0,\@errors],
        ['',0,0,[$stage eq 'callback'?'Responder delivery failed':'Responder scheduling failed']],
        "$stage: partial setup/response failure and a broken logger cannot escape or retain the slot");
    $b->{fail}=0;$b->{logger}{throws}=0;invoke_1437($b,'Recovered');my ($next)=timers_1437($b);
    $next->invoke_event('on_expire') if $next;
    is_deeply([map {$_->[1]} @{$b->{sent}}],['Recovered'],"$stage: recovery schedules and delivers once");
    cleanup_1437($b);
}
{
    my $b=fixture_1437();invoke_1437($b);my ($old)=timers_1437($b);my ($error,$reloaded);
    {
        no warnings 'redefine';
        local *MB1062::DB::prepare=sub {die "private reload detail\n"};
        eval {$reloaded=$b->onStartTimers();1} or $error=$@;
    }
    $old->invoke_event('on_expire') if $old;
    is_deeply([$error,$reloaded,scalar(timers_1437($b)),scalar(@{$b->{sent}})],
        [undef,0,0,0],
        'login cancels the old automatic reply while containing a failed independent DB timer reload');
    cleanup_1437($b);
}
{
    my $b=fixture_1437();my $during=[];
    $b->{during}=sub {push @$during,invoke_1437($b,'Reentrant')};
    invoke_1437($b);my ($t)=timers_1437($b);$t->invoke_event('on_expire') if $t;
    is_deeply([$during,scalar(@{$b->{sent}}),scalar(timers_1437($b))],[[''],1,0],
        'response-side reentry cannot reserve another countdown before the cooldown is recorded');
    delete $b->{during};cleanup_1437($b);
}
{
    my $b=fixture_1437();invoke_1437($b);my ($t)=timers_1437($b);my $weak=$b;weaken($weak);
    undef $b;
    ok(!defined($weak),'a pending countdown never retains its bot through its callback');
    if ($t && $t->loop) {$t->stop;$t->loop->remove($t)}
}
{
    my $b=fixture_1437();invoke_1437($b);my ($t)=timers_1437($b);my $ticks=0;
    my $heartbeat=IO::Async::Timer::Countdown->new(delay=>0.001,on_expire=>sub {$ticks++});
    $b->{loop}->add($heartbeat);$heartbeat->start;
    $t->stop;$t->configure(delay=>0.005);$t->start;
    my $end=Time::HiRes::time()+1;
    $b->{loop}->loop_once(0.01) while !@{$b->{sent}} && Time::HiRes::time()<$end;
    is_deeply([$ticks,scalar(@{$b->{sent}}),exists($b->{_responder_pending})?1:0],[1,1,0],
        'the real event loop remains responsive and consumes a real countdown once');
    cleanup_1437($b);
}
is_deeply(\@warnings,[],'native scheduling, cancellation and expiry remain warning-free');
done_testing;
