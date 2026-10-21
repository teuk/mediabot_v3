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
    is($calls, 1, 'native timer expires through the actual loop');
    is(timer_count($loop), 0, 'native timer removes its notifier on normal expiry');
    ok(!defined $weak_timer, 'native timer is freed even when its expiry callback is retained');
    undef $owner;
    ok(!defined $weak_owner, 'completed native callback releases its payload owner');
    $callback->();
    is($calls, 1, 'retained native expiry cannot duplicate output');
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
    ok(!$ok && refaddr($got) == refaddr($error), "$stage: native setup exception is preserved");
    is(timer_count($loop), 0, "$stage: native partial setup is detached");
    ok(!defined $probe, "$stage: native failed timer is released");
    undef $owner;
    ok(!defined $weak_owner, "$stage: native failed callback releases its owner");
    $callback->();
    is($calls, 0, "$stage: retained failed native expiry is inert");
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
    for my $i (1 .. 50) {
        $bot->{blocked} = 1;
        $i % 2 ? privmsg($bot, '#test', "item$i") : action($bot, '#test', "item$i");
        is(timer_count($bot->{loop}), 1, "round $i: one native AntiFlood arm");
        $bot->{blocked} = 0;
        $bot->{loop}->loop_once(0.01);
        is(timer_count($bot->{loop}), 0, "round $i: expired AntiFlood notifier is removed");
    }
    is(scalar @{$bot->{irc}{wire}}, 50, 'native AntiFlood sends each queued item once');
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}],
        [map {$_ % 2 ? "item$_" : "\1ACTION item$_\1"} 1 .. 50], 'native mixed message kinds retain order and ACTION envelopes');
    is($bot->{_flood_outq}{'#test'}{armed}, 0, 'native AntiFlood final arm is clear');
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
    is_deeply(\@wire, [qw(one two)], 'native paced PRIVMSG still completes its batch');
    is_deeply($bot->{_external_ai_output_queues}, {}, 'native completed batch releases queue state');
    is(timer_count($bot->{loop}), 0, 'native paced PRIVMSG leaves no notifier');
}
done_testing;
