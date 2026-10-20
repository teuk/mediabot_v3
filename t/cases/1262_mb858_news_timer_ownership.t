use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use Time::HiRes ();
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::CommandAsync;
use lib 't/lib';
use MB858NewsFixture qw(new_bot queue fire active);
my $native_new = IO::Async::Timer::Countdown->can('new');
my $native_now = Mediabot::CommandAsync->can('_news_output_now');
MB858NewsFixture::install();

{
    my $bot = new_bot();
    ok(queue($bot, qw(one two three)), 'news batch is accepted');
    is(scalar @{$bot->{sent}}, 1, 'only first line is immediate');
    my $old = $bot->{_news_output_q}{timer};
    $MB858NewsFixture::clock += 1.5; fire($old);
    my $current = $bot->{_news_output_q}{timer};
    is(scalar @{$bot->{sent}}, 2, 'expiry advances one line');
    fire($old);
    is(refaddr($bot->{_news_output_q}{timer}), refaddr($current), 'repeated old expiry preserves the successor timer');
    is(active($bot), 1, 'repeated expiry cannot orphan another live timer');
    is(scalar @{$bot->{loop}{made}}, 2, 'repeated expiry cannot schedule another arm');
    $MB858NewsFixture::clock += 1.5; fire($current);
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(one two three)], 'FIFO output remains exact');
    is(active($bot), 0, 'completed batch has no live timer');
    $MB858NewsFixture::clock += .25; queue($bot, 'next bulletin');
    my $next = $bot->{_news_output_q}{timer};
    fire($old); fire($current);
    is(refaddr($bot->{_news_output_q}{timer}), refaddr($next), 'completed arms cannot take ownership of a later bulletin');
    is(active($bot), 1, 'later bulletin retains one timer');
    is(scalar @{$bot->{sent}}, 3, 'late callbacks cannot send the next bulletin early');
    $MB858NewsFixture::clock += 1.25; fire($next);
    is($bot->{sent}[-1][2], 'next bulletin', 'valid successor eventually delivers');
    my $weak_q = $bot->{_news_output_q}; weaken($weak_q);
    my $weak_bot = $bot; weaken($weak_bot); undef $bot;
    ok(!defined($weak_bot), 'retained timer callbacks do not keep the bot alive');
    ok(!defined($weak_q), 'retained timer callbacks do not keep completed queue state alive');
}
{
    my $bot = new_bot(); queue($bot, qw(old pending));
    my $old = $bot->{_news_output_q}{timer};
    $bot->{irc} = bless({connected => 1}, 'MB858NewsIRC');
    queue($bot, qw(fresh successor));
    my $current = $bot->{_news_output_q}{timer};
    fire($old);
    is(refaddr($bot->{_news_output_q}{timer}), refaddr($current), 'old connection expiry leaves replacement timer intact');
    is(active($bot), 1, 'connection replacement retains only its own countdown');
    $MB858NewsFixture::clock += 1.5; fire($current);
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(old fresh successor)], 'old pending news never enters new connection');
}
{
    no warnings qw(redefine once);
    local *IO::Async::Timer::Countdown::new = $native_new;
    local *Mediabot::CommandAsync::_news_output_now = $native_now;
    local $Mediabot::CommandAsync::NEWS_OUTPUT_STEP = .03;
    my $bot = new_bot(); my $loop = IO::Async::Loop->really_new;
    $bot->{loop} = $loop;
    queue($bot, qw(native_first native_second native_last));
    my $first = $bot->{_news_output_q}{timer};
    my $retained = $first->{on_expire};
    my $until = Time::HiRes::time() + 2;
    $loop->loop_once(.01) while @{$bot->{sent}} < 2 && Time::HiRes::time() < $until;
    is(scalar @{$bot->{sent}}, 2, 'real countdown advances the pending bulletin');
    my $current = $bot->{_news_output_q}{timer};
    $retained->($first);
    is(refaddr($bot->{_news_output_q}{timer}), refaddr($current), 'retained real expiry leaves successor ownership intact');
    is(scalar(grep { $_->isa('IO::Async::Timer::Countdown') } $loop->notifiers), 1, 'real loop retains exactly one pending news timer');
    $loop->loop_once(.01) while @{$bot->{sent}} < 3 && Time::HiRes::time() < $until;
    is_deeply([map { $_->[2] } @{$bot->{sent}}], [qw(native_first native_second native_last)], 'real loop finishes FIFO delivery');
    is(scalar(grep { $_->isa('IO::Async::Timer::Countdown') } $loop->notifiers), 0, 'real loop releases all completed news timers');
    my $weak = $bot->{_news_output_q}; weaken($weak); undef $bot;
    ok(!defined($weak), 'retained real countdown callback releases completed queue state');
    ok(eval { $retained->($first); 1 }, 'released real queue makes late expiry a harmless no-op');
}
done_testing;
