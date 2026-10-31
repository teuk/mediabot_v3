use strict;
use warnings;
use utf8;
use Test::More;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Time::HiRes ();
use Mediabot::Helpers ();
use Mediabot::IRC::Output qw(privmsg action);
use Mediabot::Log;
use MB881OutputFixture;

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
sub quiet_1415 {
    my ($cb) = @_;
    local *STDOUT;
    open STDOUT, '>', \my $log_text or die $!;
    return $cb->();
}
sub bot_1415 {
    my ($native) = @_;
    my $bot = MB881OutputFixture::new_bot();
    $bot->{logger} = Mediabot::Log->new(debug_level => 0);
    $bot->{loop} = $native ? IO::Async::Loop->really_new : MB881::Loop->new;
    $bot->{policy}{AntiFlood} = 1;
    $bot->{blocked_targets} = {'#source' => 1, '#other' => 1};
    return $bot;
}
sub hook_1415 {
    my ($bot, $cb) = @_;
    my $fired = 0;
    $bot->{logger}->add_console_hook('fixture', 0, sub {
        return unless $_[0] =~ /\[LIVE\] #source:/;
        return if $fired++;
        $cb->();
    });
}
sub wire_1415 { [map {[$_->{target}, $_->{text}]} @{$_[0]{irc}{wire}}] }
sub pending_1415 { scalar @{$_[0]{loop}{pending}} }
sub with_policy_1415 {
    my ($cb) = @_;
    MB881OutputFixture::with_policy(sub {
        no warnings 'redefine';
        local *Mediabot::Helpers::checkAntiFlood = sub {$_[0]{blocked_targets}{$_[1]} ? 1 : 0};
        $cb->();
    });
}
my $native_new = IO::Async::Timer::Countdown->can('new');
{
    no warnings 'redefine';
    local *IO::Async::Timer::Countdown::new = sub {shift; MB881::Timer->new(@_)};
    with_policy_1415(sub {
        my $b = bot_1415(0);
        privmsg($b, '#source', 'source');
        hook_1415($b, sub { privmsg($b, '#other', 'first'); action($b, '#other', 'second') });
        $b->{blocked_targets}{'#source'} = 0;
        quiet_1415(sub {$b->{loop}->tick});
        my $q = $b->{_flood_outq}{'#other'};
        is_deeply([$q->{items}, $q->{armed}, pending_1415($b)],
            [[['privmsg','first'],['action','second']],1,1],
            'a new target enqueued by the real log callback keeps FIFO order and arms its own drain');
        $b->{blocked_targets}{'#other'} = 0;
        quiet_1415(sub {$b->{loop}->drain});
        is_deeply(wire_1415($b), [['#source','source'],['#other','first'],['#other',"\1ACTION second\1"]],
            'cross-target work reaches the production sender once with its original message kinds');
        is_deeply([$q->{items}, $q->{armed}, pending_1415($b), $b->{_flood_draining}], [[],0,0,undef],
            'new target completes without stranded payloads, timers or an active drain marker');
        $b->{logger}->remove_console_hook('fixture');

        $b = bot_1415(0);
        privmsg($b, '#source', 'source'); privmsg($b, '#other', 'older');
        hook_1415($b, sub {privmsg($b, '#other', 'newer')});
        $b->{blocked_targets}{'#source'} = 0;
        quiet_1415(sub {$b->{loop}->tick});
        $q = $b->{_flood_outq}{'#other'};
        is_deeply([$q->{items}, $q->{armed}, pending_1415($b)],
            [[['privmsg','older'],['privmsg','newer']],1,1],
            'an already armed target retains its older head without adding a duplicate timer');
        $b->{blocked_targets}{'#other'} = 0;
        quiet_1415(sub {$b->{loop}->drain});
        is_deeply(wire_1415($b), [['#source','source'],['#other','older'],['#other','newer']],
            'a cross-target callback cannot overtake an older message');
        ok(!grep({$_ != 2} @{$b->{loop}{delays}}), 'production drain arms retain their two-second delay');
        $b->{logger}->remove_console_hook('fixture');

        $b = bot_1415(0);
        privmsg($b, '#source', 'source');
        privmsg($b, '#other', "item$_") for 1..30;
        hook_1415($b, sub {privmsg($b, '#other', 'overflow')});
        $b->{blocked_targets}{'#source'} = 0;
        quiet_1415(sub {$b->{loop}->tick});
        $q = $b->{_flood_outq}{'#other'};
        is_deeply([scalar(@{$q->{items}}), $q->{items}[0], $q->{items}[-1], pending_1415($b)],
            [30,['privmsg','item1'],['privmsg','item30'],1],
            'cross-target enqueue obeys the thirty-item cap and preserves the existing queue');
        $b->{blocked_targets}{'#other'} = 0;
        quiet_1415(sub {$b->{loop}->drain});
        is_deeply(wire_1415($b), [['#source','source'],map {['#other',"item$_"]} 1..30],
            'overflow is not sent later and accepted messages keep their order');
        is_deeply([$q->{items}, $q->{armed}, pending_1415($b)], [[],0,0],
            'the capped queue still drains completely');
        $b->{logger}->remove_console_hook('fixture');

        $b = bot_1415(0);
        privmsg($b, '#source', 'retry'); action($b, '#source', 'after');
        quiet_1415(sub {$b->{loop}->tick}); # Still blocked at its own handoff.
        $q = $b->{_flood_outq}{'#source'};
        is_deeply([$q->{items}, $q->{armed}, pending_1415($b)],
            [[['privmsg','retry'],['action','after']],1,1],
            'a genuinely reblocked item for the current target still returns to its head and rearms once');
        $b->{blocked_targets}{'#source'} = 0;
        quiet_1415(sub {$b->{loop}->drain});
        is_deeply(wire_1415($b), [['#source','retry'],['#source',"\1ACTION after\1"]],
            'same-target recovery retains the original PRIVMSG/ACTION sequence');
    });
}
{
    # Also exercise actual IO::Async countdown ownership. Only shorten its
    # delay; deterministic cases above check the production scheduling delay.
    no warnings 'redefine';
    local *IO::Async::Timer::Countdown::new = sub {
        my ($class, %args) = @_; $args{delay} = 0; $native_new->($class, %args);
    };
    with_policy_1415(sub {
        my $b = bot_1415(1);
        privmsg($b, '#source', 'native source');
        hook_1415($b, sub {privmsg($b, '#other', 'native other'); $b->{blocked_targets}{'#other'} = 0});
        $b->{blocked_targets}{'#source'} = 0;
        my $deadline = Time::HiRes::time() + 1;
        quiet_1415(sub {$b->{loop}->loop_once(.01) while @{$b->{irc}{wire}} < 2 && Time::HiRes::time() < $deadline});
        is_deeply(wire_1415($b), [['#source','native source'],['#other','native other']],
            'native countdown callbacks deliver a second target without any later enqueue to wake it');
        is(scalar(grep {$_->[0] eq 'history'} @{$b->{events}}), 2,
            'only the two accepted native sends reach history');
        my @notifiers = $b->{loop}->notifiers;
        is_deeply([scalar(@notifiers), $b->{_flood_outq}{'#other'}{items}, $b->{_flood_draining}], [0,[],undef],
            'native completion leaves no notifier, stranded second-target work or drain marker');
        $b->{logger}->remove_console_hook('fixture');
    });
}
is_deeply(\@warnings, [], 'cross-target, full-queue and same-target handoffs are warning-free');
done_testing;
