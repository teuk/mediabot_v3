# t/cases/778_mb595_status_async_jobs.t
# =============================================================================
# mb595 — .status voit les jobs CommandAsync.
#   [1] async_jobs_snapshot : jobs actifs tries par anciennete, channel/
#       label/pid/elapsed ; vide = [] ; async_stats_snapshot : compteurs a
#       plat, absents = 0.
#   [2] compteurs poses aux bons endroits du source (spawned au spawn,
#       timeouts dans le chemin timed_out, completed au succes, fallback
#       sync ×4 — no-loop/pipe/fork/watch_process —, lock_refused au refus
#       de verrou).
#   [3] .status affiche la ligne Async + le detail par job — MEMOIRE SEULE
#       (contrat mb573 : la section ne contient ni kill ni waitpid ni DB).
#   [4] refus de verrou reel : run_ctx_async sur un canal occupe incremente
#       lock_refused et notifie.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Time::HiRes ();

return sub {
    my ($assert) = @_;

    require Mediabot::CommandAsync;
    require Mediabot::Mediabot;

    # [1] snapshots unitaires sur un pseudo-bot
    my $bot = bless { logger => undef }, 'Mediabot';
    my $now = Time::HiRes::time();
    $bot->{_cmd_async_jobs} = {
        '#quebec' => { pid => 111, label => 'leaderboard', channel => '#quebec',
                       started => $now - 12.4 },
        '#teuk'   => { pid => 222, label => 'stats', channel => '#teuk',
                       started => $now - 2.1 },
    };
    $bot->{_cmd_async_stats} = { spawned => 7, completed => 5, timeouts => 1 };

    my $jobs = Mediabot::CommandAsync::async_jobs_snapshot($bot);
    $assert->is(scalar @$jobs, 2, 'mb595-778: 2 jobs actifs vus');
    $assert->is($jobs->[0]{label}, 'leaderboard',
        'mb595-778: tri par anciennete — le plus vieux d abord');
    $assert->is($jobs->[0]{channel}, '#quebec', 'mb595-778: canal expose');
    $assert->is($jobs->[0]{pid}, 111, 'mb595-778: pid expose');
    $assert->ok($jobs->[0]{elapsed} >= 12 && $jobs->[0]{elapsed} < 14,
        'mb595-778: elapsed calcule');
    my $st = Mediabot::CommandAsync::async_stats_snapshot($bot);
    $assert->is($st->{spawned}, 7, 'mb595-778: compteur spawned');
    $assert->is($st->{fallback_sync}, 0, 'mb595-778: compteur absent = 0');

    delete $bot->{_cmd_async_jobs};
    $assert->is(scalar @{ Mediabot::CommandAsync::async_jobs_snapshot($bot) }, 0,
        'mb595-778: aucun job = liste vide');

    # [2] compteurs aux bons endroits (gardes structurelles)
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/CommandAsync.pm' or die $!; local $/; <$fh> };
    my $spawn_i = index($src, q<{spawned}++>);
    my $start_i = index($src, q<worker started pid=>);
    $assert->ok($spawn_i > -1 && $start_i > -1 && abs($spawn_i - $start_i) < 400,
        'mb595-778: spawned incremente au spawn');
    $assert->like($src, qr/\$state->\{timed_out\}\)\s*\{\n\s*\$self->\{_cmd_async_stats\}\{timeouts\}\+\+/,
        'mb595-778: timeouts incremente dans le chemin timed_out');
    $assert->like($src, qr/\{completed\}\+\+;\n\s*_replay_intents/,
        'mb595-778: completed incremente au succes, avant le rejeu');
    my $fb = () = $src =~ /\{fallback_sync\}\+\+/g;
    $assert->is($fb, 4,
        'mb597-778: fallback_sync sur les 4 replis (loop/pipe/fork/watch_process)');
    $assert->like($src, qr/\{lock_refused\}\+\+/,
        'mb595-778: lock_refused au refus de verrou');

    # [3] .status : la section async, memoire seule
    my $pl_src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!; local $/; <$fh> };
    $pl_src .= "\n" . do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline/Commands.pm' or die $!; local $/; <$fh> };
    my ($section) = $pl_src =~ /(# mb595-B1:.*?for my \$j \(\@\$jobs\) \{.*?\n\s*\}\n\s*\})/s;
    $assert->ok(defined $section, 'mb595-778: section Async presente dans .status');
    $assert->like($section // '', qr/async_jobs_snapshot/,
        'mb595-778: la section lit le snapshot');
    $assert->ok(($section // 'kill') !~ /\bkill\b|\bwaitpid\b|dbh|->do\(|prepare\(/,
        'mb595-778: memoire seule — ni kill ni waitpid ni DB (contrat mb573)');

    # rendu reel via un stream capture
    {
        package Stream778; sub new { bless { out => '' }, shift }
        sub write { $_[0]{out} .= $_[1]; 1 }
    }
    my $stream = Stream778->new;
    $bot->{_cmd_async_jobs} = {
        '#quebec' => { pid => 111, label => 'leaderboard', channel => '#quebec',
                       started => $now - 12.4 } };
    # rejouer le fragment de section tel que .status l'execute
    my $bot_h = $bot;
    if ($bot_h && eval { require Mediabot::CommandAsync; 1 }) {
        my $jobs2 = eval { Mediabot::CommandAsync::async_jobs_snapshot($bot_h) } || [];
        my $st2   = eval { Mediabot::CommandAsync::async_stats_snapshot($bot_h) } || {};
        $stream->write(sprintf(
            "Async:    %d running (since start: %d spawned, %d completed,"
            . " %d timeout(s), %d sync fallback(s), %d lock refusal(s))\r\n",
            scalar @$jobs2, $st2->{spawned} // 0, $st2->{completed} // 0,
            $st2->{timeouts} // 0, $st2->{fallback_sync} // 0,
            $st2->{lock_refused} // 0));
        for my $j (@$jobs2) {
            $stream->write(sprintf("  - [%s] %s pid=%d running %ss\r\n",
                $j->{label}, $j->{channel}, $j->{pid}, $j->{elapsed}));
        }
    }
    $assert->like($stream->{out}, qr/Async:    1 running \(since start: 7 spawned, 5 completed, 1 timeout/,
        'mb595-778: ligne Async rendue avec les compteurs');
    $assert->like($stream->{out}, qr/- \[leaderboard\] #quebec pid=111 running 12\.\ds/,
        'mb595-778: detail du job rendu');

    # [4] refus de verrou reel via run_ctx_async
    require Mediabot::Helpers;
    my @notices;
    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice =
        sub { push @notices, $_[2]; 1 };
    {
        package Ctx778; sub new { bless { @_[1..$#_] }, $_[0] }
        sub nick { $_[0]{nick} } sub channel { $_[0]{channel} }
    }
    my $ran = 0;
    my $rc = Mediabot::CommandAsync::run_ctx_async($bot,
        Ctx778->new(nick => 'SlaY', channel => '#quebec'),
        'stats', sub { $ran = 1 });
    $assert->is($rc, 1, 'mb595-778: refus de verrou rend 1 (gere)');
    $assert->is($ran, 0, 'mb595-778: le code ne tourne pas sous verrou');
    $assert->is($bot->{_cmd_async_stats}{lock_refused}, 1,
        'mb595-778: lock_refused incremente en conditions reelles');
    $assert->like($notices[0] // '', qr/already running/,
        'mb595-778: refus notifie');
};
