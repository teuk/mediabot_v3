#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../..";
use Test::More;
use Scalar::Util qw(refaddr);
use Time::HiRes ();
use Mediabot::CommandAsync;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;

{
    package MB815DeliveryIRC;
    sub is_connected { $_[0]{connected} }
    package MB815DeliveryBot;
    sub getLoop { $_[0]{loop} }
    sub getQuit { $_[0]{quit} || 0 }
    package MB815DeliveryLogger;
    sub log { push @{$_[0]{lines}}, $_[2] }
    package MB815DeliveryLoop;
    sub add {
        die "scheduler failed\n" if $_[0]{fail};
        $_[0]{timers}{Scalar::Util::refaddr($_[1])} = $_[1];
    }
    sub remove { delete $_[0]{timers}{Scalar::Util::refaddr($_[1])} }
    package MB815DeliveryTimer;
    sub start { $_[0]{started} = 1 }
    sub stop { $_[0]{started} = 0 }
    sub fire { $_[0]{on_expire}->($_[0]) }
}

sub new_bot {
    return bless {
        irc => bless({connected => 1}, 'MB815DeliveryIRC'),
        loop => bless({timers => {}}, 'MB815DeliveryLoop'),
        logger => bless({lines => []}, 'MB815DeliveryLogger'),
    }, 'MB815DeliveryBot';
}

my $A = 'Mediabot::CommandAsync';
is($Mediabot::CommandAsync::NEWS_OUTPUT_STEP, 1.5, 'news interval is 1.5 seconds');
my ($clock, @sent);
my $record = sub { push @sent, [$clock, @_[1,2]]; 1 };
{
    no warnings qw(redefine once);
    local *Mediabot::CommandAsync::_news_output_now = sub { $clock };
    local *IO::Async::Timer::Countdown::new = sub {
        my ($class, %args) = @_;
        return bless \%args, 'MB815DeliveryTimer';
    };
    local *Mediabot::Helpers::botPrivmsg = $record;
    local *Mediabot::Helpers::botNotice = $record;
    local *Mediabot::Helpers::botAction = $record;

    $clock = 100;
    my $bot = new_bot();
    my $batch = [['privmsg', '#a', 'opening'], ['privmsg', '#a', 'links'],
                 ['notice', 'reader', 'private result']];
    ok($A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc}), 'news batch accepted');
    is_deeply(\@sent, [[100, '#a', 'opening']], 'first line is immediate, later lines stay in parent queue');
    is(scalar keys %{$bot->{loop}{timers}}, 1, 'one timer covers all queued news');
    is($bot->{_news_output_q}{timer}{delay}, 1.5, 'second line waits the selected interval');
    $clock += 1.5;
    $bot->{_news_output_q}{timer}->fire;
    is_deeply($sent[-1], [101.5, '#a', 'links'], 'second line uses normal helper after 1.5 seconds');
    $A->can('_replay_intents')->($bot, [['privmsg', '#b', 'another channel']], 'actualites', $bot->{irc});
    is(scalar @sent, 2, 'another channel cannot start a simultaneous news burst');
    is(scalar keys %{$bot->{loop}{timers}}, 1, 'another bulletin does not create another timer');
    $clock = 110;
    $bot->{_news_output_q}{timer}->fire;
    is(scalar @sent, 3, 'a late event loop sends only one pending line');
    is_deeply($sent[-1], [110, 'reader', 'private result'], 'FIFO preserves public and private destinations');
    is($bot->{_news_output_q}{timer}{delay}, 1.5, 'late delivery starts a fresh interval, without catchup');
    $clock += 1.5;
    $bot->{_news_output_q}{timer}->fire;
    is_deeply($sent[-1], [111.5, '#b', 'another channel'], 'next channel follows the same pacing');
    is(scalar keys %{$bot->{loop}{timers}}, 0, 'empty queue leaves no active timer');
    $clock += .25;
    $A->can('_replay_intents')->($bot, [['privmsg', '#a', 'rapid next bulletin']], 'actualites', $bot->{irc});
    is(scalar @sent, 4, 'recent last line still limits an otherwise idle queue');
    cmp_ok(abs($bot->{_news_output_q}{timer}{delay} - 1.25), '<', .001, 'idle queue waits only the remaining interval');
    $clock += 1.25;
    $bot->{_news_output_q}{timer}->fire;
    is($sent[-1][2], 'rapid next bulletin', 'idle queue eventually delivers the next bulletin');
    my $before = scalar @sent;
    $A->can('_replay_intents')->($bot, [['privmsg', '#a', 'regular one'], ['privmsg', '#a', 'regular two']], 'career');
    is(scalar @sent, $before + 2, 'other command workers retain their existing replay behavior');

    @sent = (); $clock = 200;
    $bot = new_bot();
    $A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc});
    my $old_irc = $bot->{irc};
    $bot->{irc} = bless({connected => 1}, 'MB815DeliveryIRC');
    $clock += 1.5;
    $bot->{_news_output_q}{timer}->fire;
    is(scalar @sent, 1, 'old queued bulletin is dropped after replacing the IRC connection');
    ok(!$bot->{_news_output_q}, 'reconnect clears stale pending state');
    ok(!$A->can('_replay_intents')->($bot, $batch, 'actualites', $old_irc), 'late completion from an old worker is rejected');
    is(scalar @sent, 1, 'stale worker cannot send on the new connection');
    for my $reason ('disconnect', 'quit') {
        $bot = new_bot(); @sent = ();
        $A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc});
        if ($reason eq 'quit') { $bot->{quit} = 1 }
        else { $bot->{irc}{connected} = 0 }
        $clock += 1.5;
        $bot->{_news_output_q}{timer}->fire;
        is(scalar @sent, 1, "$reason drops pending news instead of sending stale lines");
        is(scalar keys %{$bot->{loop}{timers}}, 0, "$reason removes the countdown");
    }

    $bot = new_bot(); @sent = (); $clock = 300;
    $A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc});
    $clock += $Mediabot::CommandAsync::NEWS_OUTPUT_TTL + 1;
    $bot->{_news_output_q}{timer}->fire;
    is(scalar @sent, 1, 'expired delayed lines are not advertised as current news');
    like(join('|', @{$bot->{logger}{lines}}), qr/news output expired/, 'expiry is visible through a fixed diagnostic');

    $bot = new_bot(); @sent = (); $clock = 400;
    $A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc});
    my $pending = scalar @{$bot->{_news_output_q}{items}};
    my @overflow = map { ['privmsg', '#b', "overflow $_"] } 1..60;
    ok(!$A->can('_replay_intents')->($bot, \@overflow, 'actualites', $bot->{irc}), 'overflow batch is refused as a whole');
    is(scalar @{$bot->{_news_output_q}{items}}, $pending, 'overflow preserves earlier pending lines and order');
    like(join('|', @{$bot->{logger}{lines}}), qr/news output queue_full/, 'capacity refusal has a bounded diagnostic');
    $A->can('_clear_news_output')->($bot, $bot->{_news_output_q}, 'test_cleanup');

    $bot = new_bot(); @sent = ();
    $bot->{loop}{fail} = 1;
    ok(!$A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc}), 'timer failure rejects remaining delivery');
    is(scalar @sent, 1, 'scheduler failure does not flush the remaining lines as a burst');
    ok(!$bot->{_news_output_q}, 'scheduler failure clears incomplete queue');
    like(join('|', @{$bot->{logger}{lines}}), qr/news output timer_unavailable/, 'timer failure logs a fixed reason');
    $bot = new_bot(); @sent = (); delete $bot->{loop};
    ok(!$A->can('_replay_intents')->($bot, $batch, 'actualites', $bot->{irc}), 'absent loop cannot replay news');
    is(scalar @sent, 0, 'absent loop never falls back to an immediate public burst');

    $bot = new_bot(); @sent = (); $clock = 500;
    my $during;
    $A->can('_run_sync')->($bot, 'actualites', sub {
        Mediabot::Helpers::botPrivmsg($bot, '#a', 'sync opening');
        Mediabot::Helpers::botPrivmsg($bot, '#a', 'sync links');
        $during = scalar @sent;
    });
    is($during, 0, 'synchronous worker fallback captures output before parent delivery');
    is_deeply(\@sent, [[500, '#a', 'sync opening']], 'synchronous fallback uses the same first-line behavior');
    $clock += 1.5; $bot->{_news_output_q}{timer}->fire;
    is_deeply($sent[-1], [501.5, '#a', 'sync links'], 'synchronous fallback also spaces later lines');
    is($A->can('_run_sync')->($bot, 'career', sub { 42 }), 42, 'other synchronous fallbacks preserve their return value');
    @sent = ();
    eval { $A->can('_run_sync')->($bot, 'actualites', sub {
        Mediabot::Helpers::botPrivmsg($bot, '#a', 'partial result'); die "command failed\n";
    }) };
    like($@, qr/command failed/, 'failed fallback propagates the command error');
    is(scalar @sent, 0, 'failed fallback cannot send a partial bulletin');
}

# Exercise the actual IO::Async countdown too, with a short test interval.
# An unrelated timer must run while the news line is pending; no blocking sleep.
{
    no warnings qw(redefine once);
    my @real_sent;
    local *Mediabot::Helpers::botPrivmsg = sub {
        push @real_sent, [Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()), $_[2]]; 1;
    };
    local $Mediabot::CommandAsync::NEWS_OUTPUT_STEP = .03;
    my $bot = new_bot();
    my $loop = IO::Async::Loop->new;
    $bot->{loop} = $loop;
    my $responsive = 0;
    my $other = IO::Async::Timer::Countdown->new(delay => .005, on_expire => sub { $responsive = 1 });
    $loop->add($other); $other->start;
    $A->can('_replay_intents')->($bot, [['privmsg', '#a', 'first'], ['privmsg', '#a', 'second']], 'actualites', $bot->{irc});
    is(scalar @real_sent, 1, 'real countdown defers the second line');
    my $deadline = Time::HiRes::time() + 1;
    $loop->loop_once(.01) while @real_sent < 2 && Time::HiRes::time() < $deadline;
    is(scalar @real_sent, 2, 'real countdown completes parent delivery');
    ok($responsive, 'unrelated event executes while the news line is waiting');
    if (@real_sent == 2) {
        cmp_ok($real_sent[1][0] - $real_sent[0][0], '>=', .029, 'real countdown preserves the selected minimum interval');
    } else { fail('real countdown preserves the selected minimum interval') }
    ok(!$bot->{_news_output_q}{timer}, 'real countdown is removed after delivery');
    $loop->remove($other);
}

done_testing();
