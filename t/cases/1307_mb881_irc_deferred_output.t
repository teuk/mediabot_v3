use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Timer::Countdown;
use Mediabot::IRC::Output qw(privmsg action);
use Mediabot::Helpers ();
use MB881OutputFixture;

no warnings 'redefine';
local *IO::Async::Timer::Countdown::new = sub {shift; MB881::Timer->new(@_)};
MB881OutputFixture::with_policy(sub {
    my $bot = MB881OutputFixture::new_bot();
    $bot->{loop} = MB881::Loop->new; $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', 'A'); action($bot, '#test', 'B'); privmsg($bot, '#test', 'C');
    is(scalar @{$bot->{loop}{pending}}, 1, 'several blocked sends arm only one drain timer');
    is_deeply($bot->{loop}{delays}, [2], 'drain keeps its two-second delay');
    is(scalar @{$bot->{irc}{wire}}, 0, 'blocked sends have no wire output');
    is(scalar @{$bot->{events}}, 0, 'blocked sends have no accepted history');
    is(scalar @{$bot->{dbh}{queries}}, 0, 'badword query is deferred until output can be accepted');
    $bot->{blocked} = 0; $bot->{loop}->tick;
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['A'], 'one timer tick sends one queued item');
    $bot->{blocked} = 1; $bot->{loop}->tick;
    is_deeply($bot->{_flood_outq}{'#test'}{items}, [['action', 'B'], ['privmsg', 'C']], 'reblocked item returns to the head with its kind');
    is(scalar @{$bot->{irc}{wire}}, 1, 'reblocking cannot leak a wire send');
    $bot->{blocked} = 0; $bot->{loop}->drain;
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['A', "\1ACTION B\1", 'C'], 'mixed PRIVMSG/ACTION order and envelopes survive deferral');
    is_deeply($bot->{_flood_outq}{'#test'}{items}, [], 'completed deferred queue is empty');
    is($bot->{_flood_outq}{'#test'}{armed}, 0, 'completed queue keeps the historical unarmed state');
    ok(!grep({$_ != 2} @{$bot->{loop}{delays}}), 'every rearm retains the drain delay');

    $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB881::Loop->new;
    $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', "\x0304red\x0f");
    $bot->{policy}{NoColors} = 1; $bot->{blocked} = 0; $bot->{loop}->drain;
    is($bot->{irc}{wire}[0]{text}, 'red', 'drain rechecks NoColors at actual delivery');
    $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB881::Loop->new;
    $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#test', 'blocked'); privmsg($bot, '#test', 'allowed');
    $bot->{dbh}{words} = ['blocked']; $bot->{blocked} = 0; $bot->{loop}->drain;
    is_deeply([map {$_->{text}} @{$bot->{irc}{wire}}], ['allowed'], 'drain rechecks fresh badwords and continues with the next item');
    is(scalar(grep {$_->[0] eq 'history'} @{$bot->{events}}), 1, 'only the accepted deferred item reaches history');

    $bot = MB881OutputFixture::new_bot(); $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#full', "line$_") for 1 .. 31;
    is(scalar @{$bot->{_flood_outq}{'#full'}{items}}, 30, 'deferred queue retains its thirty-item cap');
    ok(grep({$_->[0] == 3 && $_->[1] =~ /flood queue full/} @{$bot->{logger}{rows}}), 'queue overflow retains its diagnostic');
    is($bot->{_flood_outq}{'#full'}{armed}, 0, 'without a loop work remains queued and unarmed');
    $bot->{loop} = MB881::Loop->new;
    Mediabot::Helpers::_arm_flood_drain($bot, '#full');
    $bot->{blocked} = 0; $bot->{loop}->drain;
    is(scalar @{$bot->{irc}{wire}}, 30, 'queued work can be armed later through the existing hook');

    $bot = MB881OutputFixture::new_bot(); $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    privmsg($bot, '#Test', 'upper'); privmsg($bot, '#test', 'lower');
    is_deeply([sort keys %{$bot->{_flood_outq}}], ['#Test', '#test'], 'deferred keys retain exact target spelling');
    my $armed = 0;
    local *Mediabot::Helpers::_arm_flood_drain = sub {$armed++; 1};
    privmsg($bot, '#hook', 'dynamic');
    is($armed, 1, 'defer still resolves the legacy arm hook dynamically');
});
my $bot = MB881OutputFixture::new_bot(); $bot->{loop} = MB881::Loop->new;
$bot->{_flood_outq}{'#test'} = {items => [], armed => 0};
my $drained = 0;
{
    local *Mediabot::Helpers::_drain_flood_queue = sub {$drained++; 1};
    Mediabot::Helpers::_arm_flood_drain($bot, '#test');
    $bot->{loop}->tick;
}
is($drained, 1, 'armed timer still resolves the legacy drain hook dynamically');
done_testing;
