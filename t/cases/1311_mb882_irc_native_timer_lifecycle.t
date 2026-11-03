use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::IRC::Timer qw(countdown);
use Mediabot::IRC::PacedOutput qw(queue_notices queue_privmsg_chunks);
use Mediabot::IRC::Output qw(privmsg action);
use MB881OutputFixture;

sub timer_count {scalar grep {$_->isa('IO::Async::Timer::Countdown')} $_[0]->notifiers}
no warnings qw(redefine once);
{
    my $loop = IO::Async::Loop->really_new;
    my $owner = bless {}, 'MB882::NativeOwner';
    my $weak_owner = $owner; weaken($weak_owner);
    my $calls = 0;
    my $timer = countdown(loop => $loop, delay => 0, on_expire => (sub {my ($held) = @_; return sub {$calls++ if $held}})->($owner));
    my $weak_timer = $timer; weaken($weak_timer);
    my $callback = $timer->{on_expire};
    undef $timer;
    $loop->loop_once(0.01);
    undef $owner;
    my @completed=($calls,timer_count($loop),defined($weak_timer)?1:0,defined($weak_owner)?1:0);
    $callback->();
    is_deeply([@completed,$calls],[1,0,0,0,1],
        'native loop owns the pending timer, expires it once, frees timer/payload and leaves retained expiry inert');
}
for my $stage (qw(add-after start)) {
    my $loop = IO::Async::Loop->really_new;
    my $error = bless {}, 'MB882::NativeError';
    my $original_add = $loop->can('add');
    my $original_start = IO::Async::Timer::Countdown->can('start');
    my ($callback, $probe);
    local *IO::Async::Loop::add = sub {
        my ($l, $timer) = @_;
        my $result = $original_add->(@_);
        $callback = $timer->{on_expire}; $probe = $timer; weaken($probe);
        die $error if $stage eq 'add-after';
        $result;
    };
    local *IO::Async::Timer::Countdown::start = sub {die $error if $stage eq 'start'; $original_start->(@_)};
    my $owner = bless {}, 'MB882::NativeOwner'; my $weak_owner = $owner; weaken($weak_owner);
    my $calls = 0;
    my $ok = eval {countdown(loop => $loop, delay => 0, on_expire => (sub {my ($held) = @_; return sub {$calls++ if $held}})->($owner)); 1};
    my $got = $@;
    undef $owner;
    $callback->();
    is_deeply([!$ok && refaddr($got)==refaddr($error)?1:0,timer_count($loop),
        defined($probe)?1:0,defined($weak_owner)?1:0,$calls],[1,0,0,0,0],
        "$stage: native setup preserves the exception, detaches/frees the notifier and releases payload before an inert late callback");
}

# MB1081: real early removal must release a never-fired notifier and payload.
# No retained callback or payload-created timer reference is part of this case.
{
    my $loop=IO::Async::Loop->really_new;my $weak_loop=$loop;weaken($weak_loop);
    my (@states,$calls);$calls=0;
    for (1..24) {
        my $payload=bless {},'MB1081::Payload';my $weak_payload=$payload;weaken($weak_payload);
        my $timer=countdown(loop=>$loop,delay=>3600,
            on_expire=>(sub {my $held=shift;return sub {$calls++ if $held}})->($payload));
        my $probe=$timer;weaken($probe);undef $payload;
        my @active=(timer_count($loop),$timer->is_running?1:0,defined($weak_payload)?1:0);
        $timer->stop;$loop->remove($timer);undef $timer;
        push @states,[@active,timer_count($loop),defined($probe)?1:0,defined($weak_payload)?1:0];
    }
    undef $loop;
    is_deeply([\@states,$calls,defined($weak_loop)?1:0],
        [[map {[1,1,1,0,0,0]} 1..24],0,0],
        'MB1081: repeated native stop/remove frees unexpired notifiers, payloads and the loop without running user callbacks');
}
{
    my $start=IO::Async::Timer::Countdown->can('start');my @states;
    for my $throws (0,1) {
        my $loop=IO::Async::Loop->really_new;
        my $payload={};my $weak_payload=$payload;weaken($weak_payload);
        my $error=bless {},'MB1081::InlineError';my ($probe,$calls);$calls=0;
        local *IO::Async::Timer::Countdown::start=sub {
            my $self=shift;$probe=$self;weaken($probe);
            my $rv=$start->($self,@_);
            $self->{on_expire}->($self); # native notifier, inline expiry seam
            die $error if $throws;
            return $rv;
        };
        my $result;
        my $ok=eval {$result=countdown(loop=>$loop,delay=>0,
            on_expire=>(sub {my $held=shift;return sub {$calls++ if $held}})->($payload));1};
        my $got=$@;undef $payload;
        push @states,[$ok?1:0,defined($result)?1:0,$calls,timer_count($loop),
            defined($probe)?1:0,defined($weak_payload)?1:0,
            $throws && refaddr($got)==refaddr($error)?1:0];
    }
    is_deeply(\@states,[[1,0,1,0,0,0,0],[0,0,1,0,0,0,1]],
        'MB1081: inline expiry stays single-use and a subsequent start exception retains its original object after cleanup');
}
my $original_new = IO::Async::Timer::Countdown->can('new');
# Exercise production callbacks with real native timers, without waiting for
# the production delays already asserted by deterministic tests.
local *IO::Async::Timer::Countdown::new = sub {
    my ($class, %args) = @_; $args{delay} = 0; $original_new->($class, %args);
};
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    $bot->{policy}{AntiFlood} = 1;
    my @states;
    for my $i (1 .. 6) {
        $bot->{blocked} = 1;
        $i % 2 ? privmsg($bot, '#test', "item$i") : action($bot, '#test', "item$i");
        my $armed=timer_count($bot->{loop});
        $bot->{blocked} = 0;
        $bot->{loop}->loop_once(0.01);
        push @states,[$armed,timer_count($bot->{loop})];
    }
    is_deeply(\@states,[[1,0],[1,0],[1,0],[1,0],[1,0],[1,0]],
        'native AntiFlood owns exactly one notifier per arm and detaches it after every mixed output round');
    is_deeply([[map {$_->{text}} @{$bot->{irc}{wire}}],$bot->{_flood_outq}{'#test'}{armed}],
        [[map {$_ % 2 ? "item$_" : "\1ACTION item$_\1"} 1 .. 6],0],
        'native mixed messages preserve exact count/order, ACTION envelopes and the final cleared arm');
});
{
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    my @wire; my $error = bless {}, 'MB882::NativeNoticeError';
    local *Mediabot::Helpers::botNotice = sub {die $error if $_[2] eq 'fail'; push @wire, $_[2]; 1};
    queue_notices($bot, 'nick', 'fail');
    my ($timer) = $bot->{loop}->notifiers;
    my $callback = $timer->{on_expire}; my $probe = $timer; weaken($probe); undef $timer;
    my $ok = eval {$bot->{loop}->loop_once(0.01); 1}; my $got = $@;
    ok(!$ok && refaddr($got) == refaddr($error), 'native NOTICE transport exception is preserved');
    is(timer_count($bot->{loop}), 0, 'native failed NOTICE leaves no notifier');
    is_deeply($bot->{_notice_queue_timers}, [], 'native failed NOTICE leaves no queue slot');
    ok(!defined $probe, 'native failed NOTICE timer is freed');
    $callback->();
    is_deeply(\@wire, [], 'retained failed NOTICE expiry cannot resend');
    queue_notices($bot, 'nick', 'recovered'); $bot->{loop}->loop_once(0.01);
    is_deeply(\@wire, ['recovered'], 'a later native NOTICE still works');
    is(timer_count($bot->{loop}), 0, 'later native NOTICE also cleans up');
}
{
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    queue_privmsg_chunks($bot, '#test', [qw(one two)], 10_000);
    $bot->{loop}->loop_once(0.01);
    is_deeply([\@wire,$bot->{_external_ai_output_queues},timer_count($bot->{loop})],
        [[qw(one two)],{},0], 'native paced PRIVMSG completes its batch and releases queue state and notifier');
}
done_testing;
