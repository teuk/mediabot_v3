# t/cases/572_mb353_report_calendar_rearm.t
# mb353 — calendar tasks must re-arm from wall-clock time after every run.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);
use Time::Local qw(timelocal_posix);
use POSIX qw(tzset mktime);

BEGIN {
    unshift @INC, "$Bin/../..";

    package IO::Async::Timer::Periodic;
    sub new {
        my ($class, %args) = @_;
        return bless { %args, started => 0 }, $class;
    }
    sub start { $_[0]{started} = 1; return 1 }
    sub stop  { $_[0]{started} = 0; return 1 }
    $INC{'IO/Async/Timer/Periodic.pm'} = __FILE__;

    package IO::Async::Timer::Countdown;
    our @CREATED;
    sub new {
        my ($class, %args) = @_;
        my $self = bless { %args, started => 0 }, $class;
        push @CREATED, $self;
        return $self;
    }
    sub start { $_[0]{started} = 1; return 1 }
    sub stop  { $_[0]{started} = 0; return 1 }
    sub fire  { $_[0]{on_expire}->() }
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
}

{
    package MB353::Loop;
    sub new { bless { added => [], removed => [] }, shift }
    sub add { push @{ $_[0]{added} }, $_[1]; return $_[1] }
    sub remove { push @{ $_[0]{removed} }, $_[1]; return $_[1] }
}

{
    package MB353::Logger;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; return 1 }
}

require Mediabot::Scheduler;

my $loop = MB353::Loop->new;
my $log  = MB353::Logger->new;
my $schedule_calls = 0;
my $callback_calls = 0;

my $sched = Mediabot::Scheduler->new(loop => $loop, logger => $log);
$sched->add(
    name        => 'calendar_probe',
    interval    => 86400,
    next_run_cb => sub {
        my ($now) = @_;
        $schedule_calls++;
        return $now + 60;
    },
    cb => sub { $callback_calls++ },
    autostart => 1,
);

my $info = $sched->task_info('calendar_probe');
is($info->{mode}, 'calendar', 'calendar mode registered');
ok($info->{started}, 'calendar task autostarted');
ok($info->{next_run} > time(), 'exact next_run epoch exposed');
is($schedule_calls, 1, 'next epoch calculated at start');
is(scalar @IO::Async::Timer::Countdown::CREATED, 1, 'one countdown created initially');

my $first = $IO::Async::Timer::Countdown::CREATED[0];
$first->fire;

$info = $sched->task_info('calendar_probe');
is($callback_calls, 1, 'task callback executed on expiry');
is($info->{ticks}, 1, 'calendar tick counted');
is($schedule_calls, 2, 'next epoch recalculated after callback');
is(scalar @IO::Async::Timer::Countdown::CREATED, 2, 'new one-shot created after callback');
my $second = $IO::Async::Timer::Countdown::CREATED[1];
isnt(refaddr($first), refaddr($second), 're-arm uses a fresh countdown');
ok(grep(refaddr($_) == refaddr($first), @{ $loop->{removed} }), 'expired timer removed from loop');

ok($sched->stop('calendar_probe'), 'calendar task stops cleanly');
$info = $sched->task_info('calendar_probe');
ok(!$info->{started}, 'stopped state recorded');
is($info->{next_run}, 0, 'stopped task has no stale next_run');
ok(grep(refaddr($_) == refaddr($second), @{ $loop->{removed} }), 'armed timer removed on stop');

ok($sched->start('calendar_probe'), 'calendar task restarts cleanly');
is($schedule_calls, 3, 'restart recalculates wall-clock target');
ok($sched->remove('calendar_probe'), 'calendar task removes cleanly');
ok(!defined $sched->task_info('calendar_probe'), 'removed task leaves registry');

my $bad = eval {
    $sched->add(
        name        => 'bad_calendar',
        interval    => 60,
        next_run_cb => sub { return time() },
        cb          => sub { },
        autostart   => 1,
    );
    1;
};
ok(!$bad, 'invalid non-future epoch refuses autostart');
like($@, qr/failed to autostart/, 'invalid epoch has explicit failure');

my $both = eval {
    $sched->add(
        name           => 'ambiguous_schedule',
        interval       => 60,
        first_interval => 10,
        next_run_cb    => sub { time() + 10 },
        cb             => sub { },
    );
    1;
};
ok(!$both, 'first_interval and next_run_cb cannot be mixed');
like($@, qr/mutually exclusive/, 'ambiguous schedule is explained');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub extract_sub {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;
    my $brace = index($src, '{', $start);
    my $depth = 0;
    my ($single, $double, $comment, $escape) = (0, 0, 0, 0);
    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);
        if ($comment) { $comment = 0 if $c eq "\n"; next }
        if ($single) {
            if ($c eq '\\' && !$escape) { $escape = 1; next }
            $single = 0 if $c eq "'" && !$escape;
            $escape = 0; next;
        }
        if ($double) {
            if ($c eq '\\' && !$escape) { $escape = 1; next }
            $double = 0 if $c eq '"' && !$escape;
            $escape = 0; next;
        }
        if ($c eq '#') { $comment = 1; next }
        if ($c eq "'") { $single = 1; next }
        if ($c eq '"') { $double = 1; next }
        $depth++ if $c eq '{';
        if ($c eq '}') {
            $depth--;
            return substr($src, $start, $i - $start + 1) if $depth == 0;
        }
    }
    die "end of sub $name not found";
}

my $main = slurp('mediabot.pl');
my $helpers = join "\n", map { extract_sub($main, $_) }
    qw(_local_epoch_for_day_offset _next_daily_epoch _next_weekly_epoch);
my $compiled = eval "$helpers\n1;";
ok($compiled, 'calendar helpers compile in isolation') or diag($@);

{
    local $ENV{TZ} = 'Europe/Paris';
    tzset();

    my $spring_1 = timelocal_posix(0, 0, 0, 28, 2, 126); # 2026-03-28 00:00
    my $spring_2 = _next_daily_epoch($spring_1, 0, 0);
    my $spring_3 = _next_daily_epoch($spring_2, 0, 0);
    is($spring_2 - $spring_1, 86400, 'day before spring DST is 24h');
    is($spring_3 - $spring_2, 82800, 'spring DST day is re-armed to 23h');

    my $fall_1 = timelocal_posix(0, 0, 0, 24, 9, 126); # 2026-10-24 00:00
    my $fall_2 = _next_daily_epoch($fall_1, 0, 0);
    my $fall_3 = _next_daily_epoch($fall_2, 0, 0);
    is($fall_2 - $fall_1, 86400, 'day before autumn DST is 24h');
    is($fall_3 - $fall_2, 90000, 'autumn DST day is re-armed to 25h');

    my $weekly = _next_weekly_epoch($spring_2, 1, 0, 0);
    is($weekly - $spring_2, 82800, 'weekly Monday target also follows spring DST');
}

tzset();

like($main, qr/name\s*=>\s*'daily_channel_report'.*?next_run_cb\s*=>\s*sub\s*\{\s*_next_daily_epoch/s,
    'daily report uses dynamic calendar re-arm');
like($main, qr/name\s*=>\s*'weekly_channel_report'.*?next_run_cb\s*=>\s*sub\s*\{\s*_next_weekly_epoch/s,
    'weekly report uses dynamic calendar re-arm');

my $partyline = slurp('Mediabot/Partyline.pm');
like($partyline, qr/my \$next = \$t->\{next_run\} \/\/ 0/,
    '.timers uses Scheduler exact next_run');
like($partyline, qr/%04d-%02d-%02d %02d:%02d:%02d/,
    '.timers displays the full local date and time');

my $scheduler_src = slurp('Mediabot/Scheduler.pm');
like($scheduler_src, qr/weaken\(\$weak_self\)/,
    'calendar callback does not strongly retain Scheduler');
like($scheduler_src, qr/weaken\(\$timer\)/,
    'calendar callback does not retain its own timer');
like($scheduler_src, qr/mb353|calendar task/s,
    'calendar scheduling implementation is present');

done_testing();
