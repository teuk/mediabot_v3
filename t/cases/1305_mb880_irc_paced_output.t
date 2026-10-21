use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);
use IO::Async::Timer::Countdown;
use Mediabot::Helpers ();
use Mediabot::External::Claude ();
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks queue_notices);
use Mediabot::CommandAsync ();

{
    package MB880::Timer;
    sub new {my ($class, %args) = @_; bless \%args, $class}
    sub start {$_[0]{started} = 1}
    sub stop {$_[0]{stopped} = 1}
}
{
    package MB880::Loop;
    sub new {bless {pending => [], delays => []}, shift}
    sub add {
        my ($self, $timer) = @_;
        die "fixture add failed\n" if $self->{reject};
        push @{$self->{pending}}, $timer;
        push @{$self->{delays}}, $timer->{delay};
    }
    sub remove {$_[1]{removed} = 1}
    sub tick {my $timer = shift @{$_[0]{pending}}; $timer->{on_expire}->() if $timer}
    sub drain {my ($self) = @_; my $n = 0; while (@{$self->{pending}}) {die 'fixture loop did not finish' if ++$n > 100; $self->tick}}
}
{
    package MB880::Bot;
    sub getLoop {$_[0]{loop}}
}
{
    package MB880::Logger;
    sub log {push @{$_[0]{rows}}, [$_[1], $_[2]]; 1}
}
no warnings 'redefine';
local *IO::Async::Timer::Countdown::new = sub {shift; MB880::Timer->new(@_)};
my @wire;
local *Mediabot::Helpers::botPrivmsg = sub {
    die "fixture send failed\n" if $_[2] eq 'FAIL';
    push @wire, ['privmsg', $_[1], $_[2]]; 1;
};
local *Mediabot::Helpers::botNotice = sub {push @wire, ['notice', $_[1], $_[2]]; 1};
my $bot = bless {loop => MB880::Loop->new, logger => bless({rows => []}, 'MB880::Logger')}, 'MB880::Bot';
is(queue_privmsg_chunks($bot, '#test', undef, 50_000), 0, 'invalid chunk list retains zero result');
is(queue_privmsg_chunks($bot, '#test', [], 50_000), 0, 'empty chunk list retains zero result');
is(Mediabot::External::Claude::_queue_irc_chunks($bot, '#test', ['a1', undef, '', 'a2'], 50_000), 2,
    'legacy wrapper returns the count of retained chunks');
is_deeply(\@wire, [['privmsg', '#test', 'a1']], 'only the first chunk is immediate');
is(queue_privmsg_chunks($bot, '#test', ['b1', 'b2'], 100_000), 2, 'generic API joins the existing per-target queue');
is_deeply($bot->{loop}{delays}, [0.05], 'joining a batch does not arm a second competing timer');
my $chunk_timer = $bot->{loop}{pending}[0];
weaken($chunk_timer);
$bot->{loop}->tick;
ok(!defined $chunk_timer, 'expired chunk timer is released after breaking its closure cycle');
is_deeply([map {$_->[2]} @wire], ['a1', 'a2'], 'first timer completes the first batch');
$bot->{loop}->tick;
is_deeply([map {$_->[2]} @wire], ['a1', 'a2', 'b1'], 'next batch waits for the established inter-batch delay');
$bot->{loop}->drain;
is_deeply([map {$_->[2]} @wire], ['a1', 'a2', 'b1', 'b2'], 'all batches retain their order');
is_deeply($bot->{loop}{delays}, [0.05, 0.05, 0.1], 'each batch keeps its original delay policy');
is_deeply($bot->{_external_ai_output_queues}, {}, 'completed queue state is removed');

@wire = ();
queue_privmsg_chunks($bot, 'Nick[', ['x1', 'x2'], 10_000);
queue_privmsg_chunks($bot, 'nick{', ['y1', 'y2'], 10_000);
is_deeply([map {$_->[2]} @wire], ['x1', 'y1'], 'queue identity keeps its historical lc policy, independent of RFC case mapping');
$bot->{loop}->drain;
is(scalar @wire, 4, 'separate targets both complete');

@wire = ();
queue_privmsg_chunks($bot, '#fail', ['FAIL', 'after'], 10_000, 'fixture');
$bot->{loop}->drain;
is_deeply([map {$_->[2]} @wire], ['after'], 'scheduled send failure keeps the remaining batch moving');
like($bot->{logger}{rows}[-1][1], qr/fixture paced output failed.*fixture send failed/, 'scheduled send failure retains its diagnostic');
@wire = ();
my $fallback = bless {logger => $bot->{logger}}, 'MB880::Bot';
is(queue_privmsg_chunks($fallback, 'nick', ['0', 'tail'], 50_000), 2, 'no-loop fallback remains immediate and retains zero text');
is_deeply([map {$_->[2]} @wire], ['0', 'tail'], 'fallback emits every retained chunk');
my $ok = eval {queue_privmsg_chunks($fallback, 'nick', ['FAIL'], 0); 1};
ok(!$ok && $@ =~ /fixture send failed/, 'immediate fallback retains its existing exception policy');

@wire = ();
my $notices = bless {loop => MB880::Loop->new}, 'MB880::Bot';
is(Mediabot::Helpers::queueBotNotices($notices, 'nick', qw(one two three)), 1, 'legacy NOTICE wrapper accepts a batch');
queue_notices($notices, 'nick', qw(four five));
is(scalar @wire, 0, 'NOTICE queue schedules the first line too');
is_deeply($notices->{loop}{delays}, [0, 1.5, 3, 4.5, 6], 'concurrent NOTICE batches retain their shared FIFO spacing');
my $notice_timer = $notices->{loop}{pending}[0];
weaken($notice_timer);
$notices->{loop}->drain;
ok(!defined $notice_timer, 'expired NOTICE timer is released after breaking its closure cycle');
is_deeply([map {$_->[2]} @wire], [qw(one two three four five)], 'NOTICE order remains intact');
is_deeply($notices->{_notice_queue_timers}, [], 'expired NOTICE timers are released');
@wire = ();
queue_notices($fallback, 'nick', map {"line$_"} 1 .. 20);
is(scalar @wire, 16, 'NOTICE retains the per-request cap');
like($wire[-1][2], qr/output truncated; use help search/, 'NOTICE keeps the existing truncation hint');
@wire = ();
my $reject = bless {loop => MB880::Loop->new}, 'MB880::Bot';
$reject->{loop}{reject} = 1;
queue_notices($reject, 'nick', 'rescue');
is_deeply(\@wire, [['notice', 'nick', 'rescue']], 'failed NOTICE scheduling retains immediate fallback');
is_deeply($reject->{_notice_queue_timers}, [], 'failed scheduling releases its timer slot');

@wire = ();
my ($intents, $truncated, $collected, $error) = Mediabot::CommandAsync::_collect_intents_run(sub {
    queue_privmsg_chunks($fallback, '#test', ['worker one', 'worker two'], 0);
    queue_notices($fallback, 'nick', 'worker notice');
    1;
});
ok($collected, 'generic APIs still execute under the actual worker output facade');
is($error // '', '', 'worker collection completes without error');
is_deeply([map {[@$_[0 .. 2]]} @$intents], [
    ['privmsg', '#test', 'worker one'], ['privmsg', '#test', 'worker two'], ['notice', 'nick', 'worker notice']],
    'worker facade captures every generic output with its kind and target');
is(scalar @wire, 0, 'generic APIs cannot bypass worker output collection');
done_testing;
