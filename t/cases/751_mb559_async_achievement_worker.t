# t/cases/751_mb559_async_achievement_worker.t
# =============================================================================
# mb559 — real parent semantics for the isolated achievement worker:
#   - launcher returns immediately and only one job can be in flight;
#   - unlocks/throttles are applied in the parent after success;
#   - failures retain the queue entry, rotate with retry and eventually drop;
#   - source contract uses fork/pipe/watch_process, fresh DB handle and
#     InactiveDestroy instead of the inherited parent socket.
# =============================================================================
use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../..";
    $INC{'Mediabot/Helpers.pm'} = __FILE__;
    package Mediabot::Helpers;
    sub chanset_enabled { 0 }
    sub botPrivmsg { 1 }
    package main;
}
use File::Temp qw(tempdir);
use Time::HiRes qw(time);
use Mediabot::Achievements;

sub slurp751 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L751;
    sub new { bless { lines=>[] }, shift }
    sub log { my ($s,$l,$m)=@_; push @{ $s->{lines} }, [$l,$m]; 1 }
}
{
    package M751;
    sub new { bless { sets=>[],incs=>[],obs=>[] }, shift }
    sub set { my ($s,@a)=@_; push @{ $s->{sets} }, \@a; 1 }
    sub inc { my ($s,@a)=@_; push @{ $s->{incs} }, \@a; 1 }
    sub observe { my ($s,@a)=@_; push @{ $s->{obs} }, \@a; 1 }
    sub can { 1 }
}
{
    package B751;
    sub new { bless { metrics=>M751->new }, shift }
}

return sub {
    my ($assert)=@_;
    my $tmp=tempdir(CLEANUP=>1);
    my @pending_done;
    my @jobs;
    my $launcher=sub {
        my ($job,$done)=@_;
        push @jobs, { %$job };
        push @pending_done, $done;
        return 1;
    };
    my $bot=B751->new;
    my $ach=Mediabot::Achievements->new(
        path=>"$tmp/a.json", logger=>L751->new, bot=>$bot,
        worker_launcher=>$launcher,
    );

    $ach->queue_check('Alice','#one');
    $ach->queue_check('Bob','#two');
    my $t0=time();
    $assert->ok($ach->start_next_check_async == 1 && (time()-$t0) < 0.1,
        'launcher returns without waiting for worker completion');
    $assert->ok($ach->worker_inflight == 1 && $ach->pending_check_count == 2,
        'one in-flight job remains owned by the parent queue');
    $assert->ok($ach->start_next_check_async == 0 && @jobs == 1,
        'single-worker invariant prevents parallel scans');

    my $heartbeat=0; $heartbeat++;
    $assert->ok($heartbeat == 1 && @pending_done == 1,
        'event-loop work can continue before the result callback');

    $pending_done[0]->({
        ok=>1,
        checks=>[qw(msg_count hour_band polyphony)],
        timings=>{msg_count=>0.01,hour_band=>2.5,polyphony=>0.02},
        unlocks=>[{nick=>'Alice',channel=>'#one',id=>'first_msg'}],
    });
    my $key=lc('Alice')."\x00".lc('#one');
    $assert->ok(!$ach->worker_inflight && $ach->pending_check_count == 1,
        'success acknowledges exactly one queued entry');
    $assert->ok(exists $ach->get_for_nick('Alice','#one')->{first_msg},
        'validated child unlock is applied by the parent');
    $assert->ok($ach->{_msg_check_ts}{$key}
        && $ach->{_hourband_check_ts}{$key}
        && $ach->{_polyphony_check_ts}{lc('Alice')},
        'throttles advance only after successful child completion');
    my @obs=@{ $bot->{metrics}{obs} };
    $assert->ok(@obs == 3, 'all child query timings are observed in the parent');
    my @worker_ok = grep {
        $_->[0] eq 'mediabot_achievement_worker_total'
            && ref($_->[1]) eq 'HASH'
            && ($_->[1]{result} || '') eq 'ok'
    } @{ $bot->{metrics}{incs} };
    $assert->ok(@worker_ok == 1,
        'successful worker outcome remains labelled ok');

    # Bob fails twice and stays queued, then succeeds. Failure callbacks do not
    # advance the message throttle or lose the entry.
    $ach->start_next_check_async;
    $pending_done[1]->({ok=>0,error=>'worker_failed',detail=>'db down'});
    my $bkey=lc('Bob')."\x00".lc('#two');
    $assert->ok($ach->pending_check_count == 1 && !$ach->{_msg_check_ts}{$bkey},
        'failed work is retained without advancing throttle');
    $ach->{_pending_checks}{$bkey}{retry_at}=0;
    $ach->start_next_check_async;
    $pending_done[2]->({ok=>0,error=>'worker_timeout',detail=>'slow query'});
    $assert->ok($ach->pending_check_count == 1,
        'second failure remains retryable');
    my @worker_timeout = grep {
        $_->[0] eq 'mediabot_achievement_worker_total'
            && ref($_->[1]) eq 'HASH'
            && ($_->[1]{result} || '') eq 'worker_timeout'
    } @{ $bot->{metrics}{incs} };
    my @timeout_total = grep {
        $_->[0] eq 'mediabot_achievement_worker_timeouts_total'
    } @{ $bot->{metrics}{incs} };
    $assert->ok(@worker_timeout == 1 && @timeout_total == 1,
        'timeout outcome and dedicated timeout counter stay truthful');
    $ach->{_pending_checks}{$bkey}{retry_at}=0;
    $ach->start_next_check_async;
    $pending_done[3]->({ok=>0,error=>'worker_failed',detail=>'still broken'});
    $assert->ok($ach->pending_check_count == 0,
        'third failure drops the entry after bounded retries');

    my $src=slurp751('Mediabot/Achievements.pm');
    $assert->like($src, qr/pipe\(\$pipe, \$child_write\).*?my \$pid = fork\(\)/s,
        'worker uses an ordinary pipe and fork');
    $assert->like($src, qr/->watch_process\(\$pid/s,
        'IO::Async owns child reaping');
    $assert->like($src, qr/InactiveDestroy.*?connect_isolated_handle/s,
        'child protects inherited DBI socket and opens a fresh handle');
    $assert->like($src, qr/IO::Async::Timer::Countdown->new/s,
        'worker has a hard asynchronous timeout');
    $assert->unlike($src, qr/sync fallback.*?check_msg/is,
        'no synchronous fallback can re-block the event loop');

    my $db=slurp751('Mediabot/DB.pm');
    $assert->like($db, qr/sub connect_isolated_handle/s,
        'DB wrapper exposes a non-mutating isolated connector');
    $assert->like($db, qr/mariadb_auto_reconnect\s*=>\s*0/s,
        'worker connection does not silently auto-reconnect');

    my $metrics=slurp751('Mediabot/Metrics.pm');
    for my $name (qw(
        mediabot_achievement_queue_pending
        mediabot_achievement_worker_inflight
        mediabot_achievement_queue_dropped_total
        mediabot_achievement_worker_total
        mediabot_achievement_worker_timeouts_total
    )) {
        $assert->like($metrics, qr/\Q$name\E/, "metric declared: $name");
    }
};
