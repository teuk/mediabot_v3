use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use IO::Async::Timer::Countdown;
use Mediabot::Helpers ();
use Mediabot::External::Claude ();
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks);
use MB882TimerFixture;

no warnings qw(redefine once);
local *IO::Async::Timer::Countdown::new = sub {shift; MB882::Timer->new(@_)};
my @wire;
local *Mediabot::Helpers::botPrivmsg = sub {push @wire, [$_[1], $_[2]]; 1};
sub new_bot {bless {loop => MB882::Loop->new, logger => bless({rows => []}, 'MB882::Logger')}, 'MB882::Bot'}

for my $row (
    ['single positive', ['b1'], 20_000, 0.02],
    ['single zero', ['b1'], 0, 0],
    ['single undefined', ['b1'], undef, 0],
    ['multiple zero', ['b1', 'b2'], 0, 0],
    ['multiple negative', ['b1', 'b2'], -1, 0],
    ['multiple malformed', ['b1', 'b2'], 'invalid', 0],
    ['filtered scalar zero', [undef, '', '0'], 30_000, 0.03],
) {
    my ($label, $payload, $delay, $seconds) = @$row;
    @wire = (); my $bot = new_bot();
    my @retained = grep {defined($_) && $_ ne ''} @$payload;
    is(queue_privmsg_chunks($bot, '#Test', [qw(a1 a2 a3)], 10_000), 3, "$label: first batch count");
    my $original_timer = $bot->{_external_ai_output_queues}{'#test'}{timer};
    is(queue_privmsg_chunks($bot, '#test', $payload, $delay), scalar @retained, "$label: later retained count");
    is(Mediabot::External::Claude::_queue_irc_chunks($bot, '#TEST', ['c1'], 40_000), 1, "$label: legacy facade joins the same queue");
    is_deeply([map {$_->[1]} @wire], ['a1'], "$label: later short or unpaced replies cannot overtake old output");
    is(scalar @{$bot->{loop}{pending}}, 1, "$label: joining creates no competing timer");
    is(refaddr($bot->{_external_ai_output_queues}{'#test'}{timer}), refaddr($original_timer), "$label: existing timer remains the owner");
    $bot->{loop}->tick;
    is_deeply([map {$_->[1]} @wire], ['a1', 'a2'], "$label: next tick sends only the older second chunk");
    $bot->{loop}->drain;
    is_deeply([map {$_->[1]} @wire], ['a1', 'a2', 'a3', @retained, 'c1'], "$label: all batches finish in enqueue order");
    is_deeply($bot->{loop}{delays}, [0.01, 0.01, 0.01, (($seconds) x scalar @retained)], "$label: batch delays and inter-batch delay stay explicit");
    ok(!grep({$_->[0] ne '#Test'} @wire), "$label: existing lowercase key and original delivery target are retained");
    is_deeply($bot->{_external_ai_output_queues}, {}, "$label: finished queue state is released");
    is(scalar keys %{$bot->{loop}{attached}}, 0, "$label: finished timers are detached");
}
{
    @wire = (); my $bot = new_bot();
    is(queue_privmsg_chunks($bot, '#test', ['single'], 20_000), 1, 'idle single reply keeps immediate count');
    is(queue_privmsg_chunks($bot, '#test', [qw(zero1 zero2)], 0), 2, 'idle zero-delay batch keeps immediate count');
    is_deeply([map {$_->[1]} @wire], [qw(single zero1 zero2)], 'idle short and unpaced replies stay immediate');
    ok(!exists $bot->{_external_ai_output_queues}, 'idle immediate replies allocate no queue state');
    is_deeply($bot->{loop}{delays}, [], 'idle immediate replies create no timer');
    my $fallback = bless {}, 'MB882::Bot';
    queue_privmsg_chunks($fallback, '#test', [qw(no loop)], 10_000);
    is_deeply([map {$_->[1]} @wire], [qw(single zero1 zero2 no loop)], 'no-loop fallback keeps immediate output');
    ok(!exists $fallback->{_external_ai_output_queues}, 'no-loop fallback allocates no queue state');
}
{
    @wire = (); my $bot = new_bot();
    queue_privmsg_chunks($bot, '#first', [qw(old1 old2)], 10_000);
    queue_privmsg_chunks($bot, '#other', ['separate'], 10_000);
    is_deeply([map {$_->[1]} @wire], ['old1', 'separate'], 'a different target keeps its independent immediate single reply');
    ok(!exists $bot->{_external_ai_output_queues}{'#other'}, 'different-target single reply creates no queue');
    $bot->{loop}->drain;
    is_deeply([map {$_->[1]} @wire], ['old1', 'separate', 'old2'], 'different targets are not serialized together');
}
{
    @wire = (); my $bot = new_bot(); my $loop = $bot->{loop};
    queue_privmsg_chunks($bot, '#test', [qw(old1 old2)], 10_000);
    delete $bot->{loop};
    queue_privmsg_chunks($bot, '#test', ['single'], 0);
    is_deeply([map {$_->[1]} @wire], ['old1'], 'an active owner can accept a new reply without rediscovering its loop');
    $loop->drain;
    is_deeply([map {$_->[1]} @wire], [qw(old1 old2 single)], 'the original live owner completes the newly joined reply');
}
for my $stage (qw(new add-before add-after start)) {
    for my $payload (['short'], ['zero1', 'zero2']) {
        my $label = "$stage/" . scalar @$payload;
        @wire = (); my $bot = new_bot();
        my $error = bless {}, 'MB883::ArmError';
        $bot->{loop}{stage} = $stage; $bot->{loop}{error} = $error;
        local $MB882TimerFixture::new_error = $stage eq 'new' ? $error : undef;
        my $ok = eval {queue_privmsg_chunks($bot, '#test', [qw(old1 old2 old3)], 10_000); 1};
        my $got = $@;
        ok(!$ok && refaddr($got) == refaddr($error), "$label: original arm failure stays visible");
        is(queue_privmsg_chunks($bot, '#test', [], 0), 0, "$label: empty input cannot resume or alter work");
        is_deeply([map {$_->[1]} @wire], ['old1'], "$label: failure does not burst pending work");
        delete $bot->{loop}{stage}; undef $MB882TimerFixture::new_error;
        is(queue_privmsg_chunks($bot, '#test', $payload, 0), scalar @$payload, "$label: short or zero-delay request resumes pending work");
        is_deeply([map {$_->[1]} @wire], ['old1', 'old2'], "$label: recovery resumes the older batch first");
        $bot->{loop}->drain;
        is_deeply([map {$_->[1]} @wire], ['old1', 'old2', 'old3', @$payload], "$label: recovery retains order without replay");
        is_deeply($bot->{_external_ai_output_queues}, {}, "$label: resumed queue finishes empty");
    }
}
{
    @wire = (); my $bot = new_bot();
    $bot->{loop}{stage} = 'start'; $bot->{loop}{error} = "fixture arm failed\n";
    eval {queue_privmsg_chunks($bot, '#test', [qw(a1 a2 a3)], 10_000)};
    my $ok = eval {queue_privmsg_chunks($bot, '#test', ['b1'], 0); 1};
    ok(!$ok && $@ =~ /fixture arm failed/, 'a short recovery request also preserves a repeated arm failure');
    is_deeply([map {$_->[1]} @wire], ['a1', 'a2'], 'repeated arm failure attempts no later reply');
    delete $bot->{loop}{stage};
    queue_privmsg_chunks($bot, '#test', ['c1'], 0);
    $bot->{loop}->drain;
    is_deeply([map {$_->[1]} @wire], [qw(a1 a2 a3 b1 c1)], 'another recovery retains every waiting short reply without duplicate attempts');
}
{
    @wire = (); my $bot = new_bot();
    my $joined = 0;
    local *Mediabot::Helpers::botPrivmsg = sub {
        push @wire, [$_[1], $_[2]];
        queue_privmsg_chunks($bot, '#test', ['nested'], 0) if !$joined++;
        1;
    };
    queue_privmsg_chunks($bot, '#test', [qw(first last)], 10_000);
    is_deeply([map {$_->[1]} @wire], ['first'], 'reentrant single reply waits behind the currently sending batch');
    $bot->{loop}->drain;
    is_deeply([map {$_->[1]} @wire], [qw(first last nested)], 'reentrant single reply keeps enqueue order');
}
done_testing;
