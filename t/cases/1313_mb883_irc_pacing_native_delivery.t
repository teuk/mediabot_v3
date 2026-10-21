use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Scalar::Util qw(weaken);
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::Helpers ();
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks);
use MB881OutputFixture;

sub timer_count {scalar grep {$_->isa('IO::Async::Timer::Countdown')} $_[0]->notifiers}
sub finish_loop {
    my ($loop) = @_;
    for (1 .. 30) {last unless timer_count($loop); $loop->loop_once(0.01)}
    is(timer_count($loop), 0, 'all native paced countdowns complete and detach within the bounded drain');
}
no warnings qw(redefine once);
my (@requested_delays, @callbacks);
my $original_new = IO::Async::Timer::Countdown->can('new');
local *IO::Async::Timer::Countdown::new = sub {
    my ($class, %args) = @_;
    push @requested_delays, $args{delay}; push @callbacks, $args{on_expire};
    # Keep actual IO::Async ownership/callbacks, avoiding production waits.
    $args{delay} = 0; $original_new->($class, %args);
};
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    my @first = ('first', 'été 🙂', encode('UTF-8', 'bytes 🙂'));
    my @copy = @first;
    is(queue_privmsg_chunks($bot, '#test', \@first, 10_000), 3, 'native initial batch retains its count');
    is(queue_privmsg_chunks($bot, '#test', ['single'], 0), 1, 'native zero-delay single joins behind existing work');
    is(queue_privmsg_chunks($bot, '#test', [qw(zero1 zero2)], 0), 2, 'native zero-delay multi-line batch joins behind existing work');
    queue_privmsg_chunks($bot, '#test', ['last'], 20_000);
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['first'], 'native later short/unpaced replies have no early wire send');
    is(timer_count($bot->{loop}), 1, 'native joined batches retain exactly one active countdown');
    finish_loop($bot->{loop});
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}],
        ['first', encode('UTF-8', 'été 🙂'), encode('UTF-8', 'bytes 🙂'), 'single', 'zero1', 'zero2', 'last'],
        'native production Sender preserves order and wire encoding across mixed batches');
    is_deeply(\@requested_delays, [0.01, 0.01, 0.01, 0, 0, 0], 'native batches request the existing per-batch and boundary delays');
    is_deeply(\@first, \@copy, 'queue does not consume or mutate the caller chunk array');
    ok(utf8::is_utf8($first[1]) && !utf8::is_utf8($first[2]), 'caller character/buffer representations are retained');
    is($bot->{metrics}{counts}{mediabot_privmsg_out_total}, 7, 'actual Sender metrics count each emitted payload once');
    is_deeply($bot->{_external_ai_output_queues}, {}, 'native completed queue releases its state');
    $_->() for @callbacks;
    is(scalar @{$bot->{irc}{wire}}, 7, 'retained old expiries cannot replay completed mixed replies');
    my $weak = $bot; weaken($weak); undef $bot;
    ok(!defined $weak, 'retained native expiry callbacks release the completed bot');
});
MB881OutputFixture::with_policy(sub {
    @callbacks = (); @requested_delays = ();
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    $bot->{dbh}{words} = ['blocked'];
    queue_privmsg_chunks($bot, '#test', [qw(old1 old2)], 10_000);
    queue_privmsg_chunks($bot, '#test', ["\x0304red\x0f"], 10_000);
    queue_privmsg_chunks($bot, '#test', ['blocked'], 0);
    $bot->{policy}{NoColors} = 1;
    finish_loop($bot->{loop});
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], [qw(old1 old2 red)], 'late single replies still re-enter current color/badword policy');
    is(scalar(grep {$_->[0] eq 'history'} @{$bot->{events}}), 3, 'only accepted late replies reach actual history hooks');
    is($bot->{metrics}{counts}{mediabot_privmsg_out_total}, 3, 'rejected late single reply adds no wire metric');
    ok(grep({$_->[0] eq 'console' && $_->[1] =~ /Badword/} @{$bot->{events}}), 'late single rejection retains its operational diagnostic');
    is_deeply($bot->{_external_ai_output_queues}, {}, 'a rejected late single does not block queue completion');
});
MB881OutputFixture::with_policy(sub {
    @callbacks = (); @requested_delays = ();
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = IO::Async::Loop->really_new;
    {
        local *IO::Async::Timer::Countdown::start = sub {die "native startup failure\n"};
        my $ok = eval {queue_privmsg_chunks($bot, '#test', [qw(old1 old2 old3)], 10_000); 1};
        ok(!$ok && $@ =~ /native startup failure/, 'actual native start failure remains visible');
        is(timer_count($bot->{loop}), 0, 'native failed arm leaves no notifier');
    }
    is(queue_privmsg_chunks($bot, '#test', ['single'], 0), 1, 'native single request can resume the retained earlier batch');
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], [qw(old1 old2)], 'native recovery attempts the older pending chunk first');
    finish_loop($bot->{loop});
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], [qw(old1 old2 old3 single)], 'native single recovery finishes in order without replaying the earlier send');
    $_->() for @callbacks;
    is(scalar @{$bot->{irc}{wire}}, 4, 'retained failed and completed native expiries remain inert after single recovery');
    is_deeply($bot->{_external_ai_output_queues}, {}, 'native recovered queue is removed');
});
done_testing;
