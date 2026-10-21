use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken refaddr);
use IO::Async::Timer::Countdown;
use Mediabot::IRC::Timer qw(countdown);
use MB882TimerFixture;

open my $cold, '-|', $^X, '-I.', '-It/lib', '-MMediabot::IRC::Timer', '-e',
    'print join q{,}, map {exists $INC{$_} ? 1 : 0} qw(Mediabot/Helpers.pm IO/Async/Timer/Countdown.pm)'
    or die "cannot start cold module probe: $!";
my $cold_output = do {local $/; <$cold>}; close $cold;
is($? >> 8, 0, 'Timer loads independently in a fresh interpreter');
is($cold_output, '0,0', 'Timer does not load Helpers or IO::Async before scheduling');

no warnings qw(redefine once);
local *IO::Async::Timer::Countdown::new = sub {shift; MB882::Timer->new(@_)};
my $loop = MB882::Loop->new;
my (@calls, $timer);
$timer = countdown(loop => $loop, delay => 0.25, on_expire => sub {push @calls, [@_]; 'callback result'});
my $weak_timer = $timer; weaken($weak_timer);
is_deeply($loop->{delays}, [0.25], 'the requested delay reaches the timer');
is(scalar keys %{$loop->{attached}}, 1, 'a live timer belongs to its loop');
my $callback = $loop->{callbacks}[0];
undef $timer;
$loop->tick;
is(scalar @calls, 1, 'expiration invokes the callback once');
is(scalar @{$calls[0]}, 1, 'IO callback arguments are forwarded');
is(scalar keys %{$loop->{attached}}, 0, 'timer is removed before callback completion');
@calls = ();
ok(!defined $weak_timer, 'an externally retained expiry callback does not keep the expired timer alive');
$callback->();
is(scalar @calls, 0, 'a stale expiry callback cannot invoke completed work again');

for my $stage (qw(new add-before add-after start)) {
    $loop = MB882::Loop->new;
    my $error = bless {stage => $stage}, 'MB882::Error';
    $loop->{stage} = $stage; $loop->{error} = $error;
    local $MB882TimerFixture::new_error = $stage eq 'new' ? $error : undef;
    my $owner = bless {}, 'MB882::Owner';
    my $weak_owner = $owner; weaken($weak_owner);
    my $run = (sub {my ($held) = @_; return sub {push @calls, $held ? 'unwanted' : 'missing'}})->($owner);
    my $ok = eval {countdown(loop => $loop, delay => 1, on_expire => $run); 1};
    my $got = $@;
    ok(!$ok, "$stage: setup failure propagates");
    is(refaddr($got), refaddr($error), "$stage: the original exception object is preserved");
    is(scalar keys %{$loop->{attached}}, 0, "$stage: a partially attached timer is removed");
    is(scalar @{$loop->{pending}}, 0, "$stage: failed setup leaves no pending callback");
    undef $run; undef $owner;
    ok(!defined $weak_owner, "$stage: retained failed expiry does not retain its payload");
    ok(!grep({defined $_} @{$loop->{probes}}), "$stage: timer/callback reference cycles are released");
    $_->() for @{$loop->{callbacks}};
    is(scalar @calls, 0, "$stage: failed expiry cannot run later");
}
$loop = MB882::Loop->new;
my $error = bless {}, 'MB882::CallbackError';
$timer = countdown(loop => $loop, delay => 1, on_expire => sub {die $error});
$weak_timer = $timer; weaken($weak_timer); undef $timer;
my $ok = eval {$loop->tick; 1}; my $got = $@;
ok(!$ok, 'callback exceptions remain visible to the caller');
is(refaddr($got), refaddr($error), 'callback exception identity is preserved');
is(scalar keys %{$loop->{attached}}, 0, 'exceptional callback releases the notifier');
ok(!defined $weak_timer, 'exceptional callback also breaks the timer reference cycle');
ok(eval {$loop->{callbacks}[0]->(); 1}, 'stale exceptional callback is inert');
my $weak_loop = $loop; weaken($weak_loop);
undef $loop;
ok(!defined $weak_loop, 'retained exceptional callback does not retain its completed loop');
$loop = MB882::Loop->new;
my $bad = eval {countdown(loop => $loop, delay => 0, on_expire => 'invalid'); 1};
ok(!$bad && $@ =~ /requires an on_expire callback/, 'invalid callback is refused before scheduling');
done_testing;
