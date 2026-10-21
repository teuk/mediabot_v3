use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use IO::Async::Timer::Countdown;
use Mediabot::Helpers ();
use Mediabot::IRC::Output qw(privmsg);
use Mediabot::IRC::PacedOutput qw(queue_privmsg_chunks queue_notices);
use MB881OutputFixture;
use MB882TimerFixture;

no warnings qw(redefine once);
local *IO::Async::Timer::Countdown::new = sub {shift; MB882::Timer->new(@_)};
my $production_privmsg = Mediabot::Helpers->can('botPrivmsg');
for my $stage (qw(new add-before add-after start)) {
    my $loop = MB882::Loop->new;
    my $error = bless {stage => $stage}, 'MB882::SetupError';
    $loop->{stage} = $stage; $loop->{error} = $error;
    my $bot = bless {loop => $loop, logger => bless({rows => []}, 'MB882::Logger')}, 'MB882::Bot';
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    local $MB882TimerFixture::new_error = $stage eq 'new' ? $error : undef;
    my $ok = eval {queue_privmsg_chunks($bot, '#test', [qw(one two three)], 10_000); 1};
    my $got = $@;
    ok(!$ok, "$stage: paced arm failure propagates without sending a burst");
    is(refaddr($got), refaddr($error), "$stage: paced arm retains the original error");
    is_deeply(\@wire, ['one'], "$stage: only the first chunk was attempted");
    is($bot->{_external_ai_output_queues}{'#test'}{active}, 0, "$stage: failed queue is available for recovery");
    is_deeply($bot->{_external_ai_output_queues}{'#test'}{current}{chunks}, ['two', 'three'], "$stage: unsent chunks remain queued");
    is(scalar keys %{$loop->{attached}}, 0, "$stage: failed arm leaves no notifier");
    $_->() for @{$loop->{callbacks}};
    is_deeply(\@wire, ['one'], "$stage: stale expiry cannot restart failed output");
    delete $loop->{stage}; undef $MB882TimerFixture::new_error;
    is(queue_privmsg_chunks($bot, '#test', [qw(four five)], 20_000), 2, "$stage: a later batch resumes the existing queue");
    $loop->drain;
    is_deeply(\@wire, [qw(one two three four five)], "$stage: recovery keeps unsent data in order without replaying sent data");
    is_deeply($bot->{_external_ai_output_queues}, {}, "$stage: recovered queue finishes");
    is(scalar keys %{$loop->{attached}}, 0, "$stage: recovered timers are removed");

    $loop = MB882::Loop->new; $loop->{stage} = $stage; $loop->{error} = $error;
    $bot = bless {loop => $loop}, 'MB882::Bot'; @wire = ();
    local *Mediabot::Helpers::botNotice = sub {push @wire, $_[2]; 1};
    $MB882TimerFixture::new_error = $stage eq 'new' ? $error : undef;
    is(queue_notices($bot, 'nick', qw(one two)), 1, "$stage: NOTICE keeps immediate fallback on setup failure");
    is_deeply(\@wire, [qw(one two)], "$stage: NOTICE fallback sends each line once");
    is_deeply($bot->{_notice_queue_timers}, [], "$stage: failed NOTICE slots are released");
    is(scalar keys %{$loop->{attached}}, 0, "$stage: failed NOTICE notifiers are removed");
    $_->() for @{$loop->{callbacks}};
    is_deeply(\@wire, [qw(one two)], "$stage: stale NOTICE expiry cannot duplicate fallback");

    MB881OutputFixture::with_policy(sub {
        local *Mediabot::Helpers::botPrivmsg = $production_privmsg;
        $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB882::Loop->new;
        $bot->{loop}{stage} = $stage; $bot->{loop}{error} = $error;
        $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
        $ok = eval {privmsg($bot, '#test', 'queued'); 1}; $got = $@;
        ok(!$ok, "$stage: AntiFlood arm failure remains visible");
        is(refaddr($got), refaddr($error), "$stage: AntiFlood retains original error");
        is($bot->{_flood_outq}{'#test'}{armed}, 0, "$stage: AntiFlood arm flag is reset");
        is_deeply($bot->{_flood_outq}{'#test'}{items}, [['privmsg', 'queued']], "$stage: AntiFlood retains pending payload");
        is(scalar keys %{$bot->{loop}{attached}}, 0, "$stage: AntiFlood partially attached timer is removed");
        $_->() for @{$bot->{loop}{callbacks}};
        is(scalar @{$bot->{irc}{wire}}, 0, "$stage: failed AntiFlood expiry is inert");
        delete $bot->{loop}{stage}; undef $MB882TimerFixture::new_error;
        $bot->{blocked} = 0;
        Mediabot::Helpers::_arm_flood_drain($bot, '#test');
        $bot->{loop}->drain;
        is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['queued'], "$stage: AntiFlood can be rearmed through its existing hook");
    });
}
{
    my $loop = MB882::Loop->new;
    my $bot = bless {loop => $loop}, 'MB882::Bot';
    my @wire; my $error = bless {}, 'MB882::NoticeError';
    local *Mediabot::Helpers::botNotice = sub {die $error if $_[2] eq 'fail'; push @wire, $_[2]; 1};
    queue_notices($bot, 'nick', qw(fail after));
    my $first = $loop->{probes}[0]; weaken($first);
    my $ok = eval {$loop->tick; 1}; my $got = $@;
    ok(!$ok && refaddr($got) == refaddr($error), 'NOTICE send exception is preserved');
    is(scalar @{$bot->{_notice_queue_timers}}, 1, 'only the later NOTICE retains a timer slot after a send exception');
    ok(!defined $first, 'failed NOTICE timer is released despite a retained callback');
    $loop->drain;
    is_deeply(\@wire, ['after'], 'later NOTICE can still run when its caller handles the exception');
    is_deeply($bot->{_notice_queue_timers}, [], 'NOTICE timers finish empty after recovery');
}
{
    my $loop = MB882::Loop->new;
    my $bot = bless {loop => $loop, logger => bless({rows => []}, 'MB882::Logger')}, 'MB882::Bot';
    my @wire;
    local *Mediabot::Helpers::botPrivmsg = sub {push @wire, $_[2]; 1};
    queue_privmsg_chunks($bot, '#test', [qw(one two three)], 10_000);
    queue_privmsg_chunks($bot, '#test', [qw(four five)], 20_000);
    $loop->{stage} = 'start'; $loop->{error} = "mid-batch arm failure\n";
    my $ok = eval {$loop->tick; 1};
    ok(!$ok && $@ =~ /mid-batch/, 'failure when rearming an expired timer is propagated');
    is_deeply(\@wire, [qw(one two)], 'mid-batch failure does not burst the remaining batches');
    is(scalar keys %{$loop->{attached}}, 0, 'expired and failed replacement timers are both removed');
    delete $loop->{stage};
    queue_privmsg_chunks($bot, '#test', [qw(six seven)], 30_000);
    $loop->drain;
    is_deeply(\@wire, [qw(one two three four five six seven)], 'recovery also retains batches already waiting behind the failed one');
}
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB882::Loop->new;
    $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', 'fail'); privmsg($bot, '#test', 'after');
    $bot->{blocked} = 0;
    my $send = Mediabot::Helpers->can('botPrivmsg');
    my $error = bless {}, 'MB882::SendError';
    local *Mediabot::Helpers::botPrivmsg = sub {die $error if $_[2] eq 'fail'; $send->(@_)};
    my $ok = eval {$bot->{loop}->tick; 1}; my $got = $@;
    ok(!$ok && refaddr($got) == refaddr($error), 'AntiFlood send exception remains visible');
    is($bot->{_flood_outq}{'#test'}{armed}, 1, 'remaining AntiFlood work is rearmed after a send exception');
    $bot->{loop}->drain;
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['after'], 'AntiFlood continues with the next item without replaying an uncertain send');
    is(scalar keys %{$bot->{loop}{attached}}, 0, 'AntiFlood final notifier is released');
});
{
    my $loop = MB882::Loop->new;
    my $bot = bless {loop => $loop}, 'MB882::Bot';
    my @wire;
    local *Mediabot::Helpers::botNotice = sub {
        push @wire, $_[2];
        queue_notices($bot, 'nick', 'nested') if $_[2] eq 'one';
        1;
    };
    queue_notices($bot, 'nick', qw(one two));
    $loop->tick;
    is_deeply($loop->{delays}, [0, 1.5, 3], 'reentrant NOTICE enqueue keeps the original in-flight slot and spacing');
    $loop->drain;
    is_deeply(\@wire, [qw(one two nested)], 'reentrant NOTICE enqueue keeps line order');
}
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB882::Loop->new;
    $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', 'fail'); privmsg($bot, '#test', 'after');
    $bot->{blocked} = 0;
    my $error = bless {}, 'MB882::PrimarySendError';
    local *Mediabot::Helpers::botPrivmsg = sub {die $error};
    $bot->{loop}{stage} = 'start'; $bot->{loop}{error} = "secondary rearm failure\n";
    my $ok = eval {$bot->{loop}->tick; 1}; my $got = $@;
    ok(!$ok && refaddr($got) == refaddr($error), 'simultaneous AntiFlood send/rearm failure preserves the primary exception');
    is($bot->{_flood_outq}{'#test'}{armed}, 0, 'simultaneous failure resets the arm flag');
    is_deeply($bot->{_flood_outq}{'#test'}{items}, [['privmsg', 'after']], 'simultaneous failure retains only the unattempted payload');
    is(scalar keys %{$bot->{loop}{attached}}, 0, 'simultaneous failure removes both notifiers');
});
done_testing;
