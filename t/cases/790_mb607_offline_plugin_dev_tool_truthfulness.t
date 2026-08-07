# t/cases/790_mb607_offline_plugin_dev_tool_truthfulness.t
# =============================================================================
# mb607 — garde de fidelite / truthfulness de tools/mb_plugin_dev.pl.
#   [1] `run` dit explicitement qu'il execute un subprocessus NON sandboxe.
#   [2] le sidecar n'est jamais pre-lu hors du vrai PluginManager.
#   [3] les fixtures d'events reproduisent les event_type du coeur
#       (join -> join, plugin_cron_observed -> cron), pas un nom devine.
#   [4] --storage passe par le vrai validateur de storage.
#   [5] une commande privilegee est dry-runnable mais le bypass USER_LEVEL
#       offline est annonce sans ambiguite.
#   [6] l'outil garde son contrat dry-run : aucune action Mediabot appliquee.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $ROOT = "$Bin/../..";
my $TOOL = "$ROOT/tools/mb_plugin_dev.pl";
my $TMP  = tempdir(CLEANUP => 1);

sub _run {
    my (@argv) = @_;
    my $cmd = join ' ', map { "'$_'" } ($^X, $TOOL, @argv);
    my $out = `cd '$ROOT' && $cmd 2>&1`;
    return ($? >> 8, $out);
}

return sub {
    my ($assert) = @_;

    my ($rc, $out) = _run('--help');
    $assert->is($rc, 0, 'mb607-790: --help sort en 0');
    $assert->like($out, qr/NOT sandboxed|unsandboxed/i,
        'mb607-790: run annonce le subprocessus reel non sandboxe');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', $TOOL or die $!;
        local $/;
        <$fh>
    };
    my $body = $src;
    $body =~ s/^\s*#.*$//mg;
    $assert->ok($body !~ /sidecar_json|open\s+my\s+\$\w+[^\n]*sidecar/,
        'mb607-790: aucun pre-read manuel du sidecar avant PluginManager');
    $assert->like($src, qr/ROUTABLE_SCRIPT_EVENTS/,
        'mb607-790: le mapping de fixture est garde par la whitelist runtime');

    ($rc, $out) = _run('run', 'examples-v2/daily.tcl',
        '--event', 'plugin_cron_observed',
        '--config', 'CHANNEL=#quebec', '--config', 'TEXT=Bonjour!',
        '--data', 'hour=9', '--data', 'minute=0',
        '--data', 'mday=7', '--data', 'month=8', '--data', 'year=2026',
        '--show-envelope');
    $assert->is($rc, 0, 'mb607-790: cron offline sort en 0');
    $assert->like($out, qr/"event_type"\s*:\s*"cron"/,
        'mb607-790: cron reproduit event_type=cron du coeur');
    $assert->unlike($out, qr/"event_type"\s*:\s*"plugin_cron"/,
        'mb607-790: cron ne fabrique plus event_type=plugin_cron');

    ($rc, $out) = _run('run', 'examples-v2/greeter.tcl',
        '--event', 'channel_join_observed', '--nick', 'SlaY',
        '--channel', '#dev', '--show-envelope');
    $assert->is($rc, 0, 'mb607-790: join offline sort en 0');
    $assert->like($out, qr/"event_type"\s*:\s*"join"/,
        'mb607-790: join reproduit event_type=join du coeur');

    open my $badst, '>', "$TMP/bad-storage.json" or die $!;
    print $badst '{"a":{"b":{"c":{"d":1}}}}';
    close $badst;
    ($rc, $out) = _run('run', 'examples-v2/karma.py', '--command', 'karma',
                       '--storage', "$TMP/bad-storage.json");
    $assert->is($rc, 1, 'mb607-790: storage hors contrat sort en 1');
    $assert->like($out,
        qr/storage fixture rejected: storage nesting deeper than 3 levels/,
        'mb607-790: --storage reutilise le vrai validateur');

    ($rc, $out) = _run('run', 'examples-v2/fortune.pl', '--command', 'fortunes');
    $assert->is($rc, 0, 'mb607-790: commande Master peut etre dry-run offline');
    $assert->like($out, qr/requires level Master.*does not emulate USER_LEVEL/s,
        'mb607-790: absence d auth USER_LEVEL offline explicitement annonce');
    $assert->like($out, qr/Nothing was applied by Mediabot/,
        'mb607-790: seules les actions Mediabot restent non appliquees');
};
