# t/cases/788_mb605_precommit_truthfulness.t
# =============================================================================
# mb605 — garde pre-commit mb603/mb604.
# Pins structurels des corrections transverses : annee du cron, plafond karma,
# cycle de vie de la gauge storage, collecteur best-effort et chmod verifie.
# Les chemins reels restent couverts par 782, 786 et 787.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $core   = _slurp('Mediabot/Mediabot.pm');
    my $pm     = _slurp('Mediabot/PluginManager.pm');
    my $karma  = _slurp('plugins/scripts/examples-v2/karma.py');
    my $daily  = _slurp('plugins/scripts/examples-v2/daily.tcl');

    $assert->like($core,
        qr/year\s*=>\s*\$year/,
        'mb605-788: cron core emits the calendar year');
    $assert->like($core,
        qr/%04d-%02d-%02dT%02d:%02d/,
        'mb605-788: cron minute stamp includes the full date');
    $assert->like($pm,
        qr/new_nick minute hour dow mday month year/,
        'mb605-788: sidecar event bridge carries year');
    $assert->like($daily,
        qr/set today "\$year-\$month-\$mday"/,
        'mb605-788: daily idempotence key is year-aware');
    $assert->like($karma,
        qr/kept\.pop\(keep\[-1\]\[0\], None\).*kept\[key\] = scores\[key\]/s,
        'mb605-788: karma keeps the new nick without exceeding its cap');
    $assert->like($pm,
        qr/sub _mark_plugin_storage_invalid .*?mediabot_plugin_storage_bytes/s,
        'mb605-788: invalid storage resets the byte gauge');
    $assert->like($pm,
        qr/existing valid document is still current state.*?_pm_gauge/s,
        'mb605-788: valid reads seed the gauge after restart');
    $assert->like($pm,
        qr/clear means zero bytes now.*?_pm_gauge/s,
        'mb605-788: clear resets the gauge immediately');
    $assert->like($pm,
        qr/ref\(\$plan->\{errors\}\) eq 'ARRAY'.*?ref\(\$plan->\{apply_errors\}\) eq 'ARRAY'/s,
        'mb605-788: malformed runner diagnostics cannot break metrics collection');
    $assert->like($pm,
        qr/unless \(chmod 0600, \$tmp\)/,
        'mb605-788: temporary storage permissions are checked');
};
