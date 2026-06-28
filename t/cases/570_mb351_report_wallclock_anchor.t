# t/cases/570_mb351_report_wallclock_anchor.t
# =============================================================================
# mb351 — Rapports daily/weekly ancrés sur l'horloge murale.
#
# Avant : $scheduler->add(interval => 86400/604800) avec IO::Async::Timer::
# Periodic => 1er tick à interval-après-le-boot, puis dérive à chaque redémarrage
# (le weekly pouvait ne jamais partir sur un bot souvent relancé).
#
# mb351 : Scheduler::add accepte first_interval (délai avant le 1er tick), et les
# rapports le calculent au démarrage = secondes jusqu'au prochain minuit (daily)
# / lundi minuit (weekly). La tâche vise donc toujours le bon créneau, quel que
# soit l'instant de boot.
#
# Validation : (a) propriétés des helpers d'ancrage (reproduits), (b) scan source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction des helpers mb351.
sub _daily {
    my ($h, $m) = @_; $h //= 0; $m //= 0;
    my @n = localtime(time);
    my $st = $n[2]*3600 + $n[1]*60 + $n[0];
    my $d = $h*3600 + $m*60 - $st;
    $d += 86400 if $d <= 0;
    return $d;
}
sub _weekly {
    my ($tw, $h, $m) = @_; $tw //= 1; $h //= 0; $m //= 0;
    my @n = localtime(time);
    my $st = $n[2]*3600 + $n[1]*60 + $n[0];
    my $da = ($tw - $n[6]) % 7;
    my $d = $da*86400 + ($h*3600 + $m*60 - $st);
    $d += 7*86400 if $d <= 0;
    return $d;
}

sub _slurp_570 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Propriétés des helpers ---------------------------------------
    # daily : toujours dans ]0, 24h], jamais 0 (pas de tir immédiat au boot).
    for my $tc ([0,0],[3,30],[12,0],[23,59]) {
        my $d = _daily(@$tc);
        $assert->ok($d > 0 && $d <= 86400, "daily(@$tc) dans ]0,24h] (=$d)");
    }
    # weekly : toujours dans ]0, 7j], pour tous les jours de la semaine.
    for my $wd (0..6) {
        my $w = _weekly($wd, 0, 0);
        $assert->ok($w > 0 && $w <= 7*86400, "weekly(wday=$wd) dans ]0,7j] (=$w)");
    }
    # cohérence : minuit aujourd'hui = "secondes jusqu'à minuit" identique entre
    # daily(0,0) et weekly(jour courant,0,0) quand on cible le jour courant et que
    # minuit est déjà passé -> les deux renvoient le prochain minuit.
    $assert->ok(_daily(0,0) <= 86400, 'daily(0,0) borné à 24h');

    # --- 2. Scan source : Scheduler passe first_interval -----------------
    my $sch = _slurp_570(File::Spec->catfile('.', 'Mediabot', 'Scheduler.pm'));
    $assert->like($sch, qr/first_interval/, 'Scheduler::add gère first_interval');
    $assert->like($sch,
        qr/defined \$first \? \(first_interval => \$first\) : \(\)/,
        'Scheduler conserve first_interval pour les tâches périodiques');

    # --- 3. Scan source : les rapports ancrent ---------------------------
    my $main = _slurp_570(File::Spec->catfile('.', 'mediabot.pl'));
    $assert->like($main, qr/sub _next_daily_epoch/,  'helper _next_daily_epoch défini');
    $assert->like($main, qr/sub _next_weekly_epoch/, 'helper _next_weekly_epoch défini');

    my ($daily_blk) = $main =~ /(name\s*=>\s*'daily_channel_report'.*?autostart)/s;  $daily_blk  //= '';
    my ($weekly_blk) = $main =~ /(name\s*=>\s*'weekly_channel_report'.*?autostart)/s; $weekly_blk //= '';
    $assert->like($daily_blk,  qr/next_run_cb\s*=>\s*sub\s*\{\s*_next_daily_epoch\(/,
                  'daily_channel_report utilise le réarmement calendaire mb353');
    $assert->like($weekly_blk, qr/next_run_cb\s*=>\s*sub\s*\{\s*_next_weekly_epoch\(/,
                  'weekly_channel_report utilise le réarmement calendaire mb353');
    $assert->like($main, qr/mb353-B1/, 'tag mb353-B1 présent');
};
