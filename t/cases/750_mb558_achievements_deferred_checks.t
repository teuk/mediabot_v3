# t/cases/750_mb558_achievements_deferred_checks.t
# =============================================================================
# mb558/mb559 — the PRIVMSG path only queues achievement checks. The queue is
# bounded, case-insensitive for deduplication and preserves original casing.
# The Scheduler launches an async worker; it never calls check_msg directly.
# =============================================================================
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use Mediabot::Achievements;

sub slurp750 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L750;
    sub new { bless { lines => [] }, shift }
    sub log { my ($s,$l,$m)=@_; push @{ $s->{lines} }, [$l,$m]; 1 }
}
{
    package M750;
    sub new { bless { sets=>[], incs=>[] }, shift }
    sub set { my ($s,@a)=@_; push @{ $s->{sets} }, \@a; 1 }
    sub inc { my ($s,@a)=@_; push @{ $s->{incs} }, \@a; 1 }
    sub can { 1 }
}
{
    package B750;
    sub new { bless { metrics => M750->new }, shift }
}

return sub {
    my ($assert)=@_;
    my $tmp=tempdir(CLEANUP=>1);
    my $bot=B750->new;
    my $ach=Mediabot::Achievements->new(path=>"$tmp/a.json",logger=>L750->new,bot=>$bot);

    $assert->ok($ach->queue_check('Te[u]K','#Quebec') == 1,
        'queue: first entry accepted');
    $assert->ok($ach->queue_check('te[u]k','#quebec') == 0,
        'queue: case-insensitive duplicate refused');
    my $entry=$ach->{_pending_checks}{lc('Te[u]K')."\x00".lc('#Quebec')};
    $assert->ok($entry->{nick} eq 'Te[u]K' && $entry->{channel} eq '#Quebec',
        'queue: original casing preserved');
    $assert->ok($ach->queue_check(undef,'#x') == 0
        && $ach->queue_check('x','not-a-channel') == 0,
        'queue: invalid hook inputs refused');

    my $cap=Mediabot::Achievements->new(path=>"$tmp/b.json",logger=>L750->new,bot=>B750->new);
    $cap->queue_check("n$_",'#cap') for 1..250;
    $assert->ok($cap->pending_check_count == 200,
        'queue: hard cap remains 200');
    my @drop=grep { $_->[0] eq 'mediabot_achievement_queue_dropped_total' }
        @{ $cap->{bot}{metrics}{incs} };
    $assert->ok(@drop >= 1, 'queue: full drops are metriced');

    my $main=slurp750('mediabot.pl');
    $assert->like($main, qr/->queue_check\(\$who, \$where\)/,
        'PRIVMSG only enqueues');
    $assert->unlike($main, qr/\{achievements\}->check_msg\(/,
        'PRIVMSG contains no direct check_msg');
    $assert->like($main,
        qr/name\s+=> 'achievements_check',\n\s+interval\s+=> 1,.*?->start_next_check_async/s,
        'Scheduler launches the async consumer every second');
    $assert->unlike($main,
        qr/name\s+=> 'achievements_check'.*?->drain_one_check/s,
        'Scheduler no longer runs the synchronous mb558 drain');
};
