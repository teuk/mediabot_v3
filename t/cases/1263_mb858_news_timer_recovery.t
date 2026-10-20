use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use IO::Async::Timer::Countdown;
use Mediabot::CommandAsync;
use lib 't/lib';
use MB858NewsFixture qw(new_bot queue fire active);
MB858NewsFixture::install();

for my $stage (qw(add start)) {
    my $bot = new_bot(); $bot->{loop}{fail} = $stage;
    my $weak_q;
    $bot->{loop}{on_add} = sub { $weak_q = $bot->{_news_output_q}; weaken($weak_q) };
    ok(!queue($bot, qw(one abandoned)), "$stage: setup failure refuses remaining news");
    my $failed = $bot->{loop}{made}[0];
    delete $bot->{loop}{on_add};
    ok(!$bot->{_news_output_q}, "$stage: failed queue is detached");
    ok(!defined($weak_q), "$stage: retained failed timer releases abandoned queue immediately");
    is(active($bot), 0, "$stage: partial timer registration is removed");
    ok(!$failed->{started}, "$stage: failed countdown is stopped");
    unlike(join('|', @{$bot->{logger}{lines}}), qr/private .* failure/, "$stage: diagnostics omit private exception text");
    delete $bot->{loop}{fail}; queue($bot, qw(recovered later));
    my $current = $bot->{_news_output_q}{timer}; fire($failed);
    is(refaddr($bot->{_news_output_q}{timer}), refaddr($current), "$stage: failed expiry cannot revoke retry");
    $MB858NewsFixture::clock += 1.5; fire($current);
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(one recovered later)], "$stage: retry recovers without abandoned lines");
    my $weak = $bot->{_news_output_q}; weaken($weak);
    undef $bot;
    ok(!defined($weak), "$stage: retained failed callback releases queue state");
}
{
    my $bot = new_bot(); queue($bot, qw(first pending));
    my $old = $bot->{_news_output_q}{timer};
    my $once = 0;
    $bot->{loop}{on_remove} = sub {
        return if $once++;
        delete $bot->{loop}{on_remove};
        queue($bot, qw(replacement final));
    };
    Mediabot::CommandAsync::_clear_news_output($bot, $bot->{_news_output_q}, 'test_cleanup');
    ok($bot->{_news_output_q}, 'cleanup hook can create an independent replacement queue');
    is(active($bot), 1, 'old cleanup preserves the replacement countdown');
    my $current = $bot->{_news_output_q} && $bot->{_news_output_q}{timer};
    fire($old);
    if ($current) { $MB858NewsFixture::clock += 1.5; fire($current) }
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(first replacement final)], 'replacement queue survives old cleanup and expiry');
}
{
    my $bot = new_bot(); queue($bot, qw(old discarded));
    my $old = $bot->{_news_output_q}{timer};
    $bot->{irc} = bless({connected => 1}, 'MB858NewsIRC');
    $bot->{loop}{on_remove} = sub {
        delete $bot->{loop}{on_remove};
        queue($bot, qw(hook_first hook_last));
    };
    queue($bot, qw(outer_first outer_last));
    is(active($bot), 1, 'connection-change cleanup preserves one replacement countdown');
    is_deeply([map { $_->{intent}[2] } @{$bot->{_news_output_q}{items}}],
        [qw(hook_last outer_first outer_last)], 'outer enqueue joins the queue created by cleanup');
    fire($old);
    for (1..3) {
        $MB858NewsFixture::clock += 1.5;
        my $timer = $bot->{_news_output_q}{timer}; fire($timer) if $timer;
    }
    is_deeply([map { $_->[2] } @{$bot->{sent}}],
        [qw(old hook_first hook_last outer_first outer_last)], 'connection-change reentry loses neither replacement nor outer batch');
    is(active($bot), 0, 'connection-change reentry leaves no abandoned countdown');
}
{
    my $bot = new_bot();
    $bot->{during_send} = sub {
        return unless $_[0] eq 'first';
        queue($bot, qw(nested last));
    };
    queue($bot, qw(first second));
    is_deeply([map { $_->[2] } @{$bot->{sent}}], ['first'], 'reentrant enqueue cannot burst while delivery is in progress');
    is(active($bot), 1, 'reentrant enqueue shares the one current countdown');
    for (1..3) {
        $MB858NewsFixture::clock += 1.5;
        my $timer = $bot->{_news_output_q}{timer}; fire($timer) if $timer;
    }
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(first second nested last)], 'reentrant batch preserves FIFO and paced delivery');
    for my $i (1..3) {
        cmp_ok($bot->{sent}[$i][0] - $bot->{sent}[$i-1][0], '>=', 1.5, "reentrant line $i respects the shared interval");
    }
    is(active($bot), 0, 'reentrant delivery leaves no orphaned timers');
    delete $bot->{during_send};
}
done_testing;
