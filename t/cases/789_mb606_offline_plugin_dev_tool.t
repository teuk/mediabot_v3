# t/cases/789_mb606_offline_plugin_dev_tool.t
# =============================================================================
# mb606 — tools/mb_plugin_dev.pl : valider et exécuter un plugin v2 HORS LIGNE.
#   [1] l'outil compile et s'auto-documente (usage, exit 0 sur --help).
#   [2] validate sur les exemples REELS du depot : karma (2 commandes),
#       daily (1 event cron), greeter (pur event) — exit 0 et fiche juste.
#   [3] REGLE DE CONCEPTION : l'outil ne reimplemente AUCUNE regle. Un
#       sidecar refuse rend le message EXACT du PluginManager, et le
#       fichier ne contient aucune borne recopiee (pas de 16384/256/[a-z]
#       slug en dur cote outil).
#   [4] run reel : karma sans etat repond, karma avec --storage fait
#       apparaitre le store et son document, daily --event cron avec
#       --config annonce sur le canal configure.
#   [5] le contexte vient des DONNEES comme dans le bot : un event reseau
#       (cron) n'a pas de canal, donc un target explicite passe — c'est le
#       piege qui a mordu l'outil avant correction.
#   [6] RIEN n'est applique : aucun fichier de storage cree, meme quand le
#       script emet un store.
#   [7] codes de sortie exploitables en CI (0 / 1).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use JSON::PP ();

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

    # [1] compile + usage
    my $compile = `$^X -c '$TOOL' 2>&1`;
    $assert->like($compile, qr/syntax OK/, 'mb606-789: l outil compile');
    my ($rc, $out) = _run('--help');
    $assert->is($rc, 0, 'mb606-789: --help sort en 0');
    $assert->like($out, qr/validate <script>.*run <script>/s,
        'mb606-789: usage documente les 2 verbes');

    # [2] validate sur les exemples reels du depot
    ($rc, $out) = _run('validate', 'examples-v2/karma.py');
    $assert->is($rc, 0, 'mb606-789: karma valide sort en 0');
    $assert->like($out, qr/sidecar accepted: karma/, 'mb606-789: fiche karma');
    $assert->like($out, qr/commands: karma, thanks/,
        'mb606-789: les commandes declarees sont listees');
    ($rc, $out) = _run('validate', 'examples-v2/daily.tcl');
    $assert->like($out, qr/events:\s+plugin_cron_observed/,
        'mb606-789: l event cron de daily est liste');
    $assert->like($out, qr/config:\s+CHANNEL=/,
        'mb606-789: la config effective est affichee');
    ($rc, $out) = _run('validate', 'examples-v2/greeter.tcl');
    $assert->is($rc, 0, 'mb606-789: greeter (pur event) valide');

    # [3] aucune regle reimplementee : le message vient du PluginManager
    mkdir "$TMP/sd";
    open my $s1, '>', "$TMP/sd/bad.py" or die $!; print $s1 "print(1)\n"; close $s1;
    open my $m1, '>', "$TMP/sd/bad.py.manifest.json" or die $!;
    print $m1 JSON::PP::encode_json({ api => 2, name => 'BAD NAME', version => '1.0' });
    close $m1;
    ($rc, $out) = _run('validate', 'bad.py', '--script-dir', "$TMP/sd");
    $assert->is($rc, 1, 'mb606-789: sidecar invalide sort en 1');
    $assert->like($out, qr/is not a valid slug/,
        'mb606-789: le message EXACT du PluginManager est rendu');
    my $src = do { open my $fh, '<:encoding(UTF-8)', $TOOL or die $!; local $/; <$fh> };
    my $body = $src; $body =~ s/^\s*#.*$//mg;   # les commentaires citent les bornes
    $assert->ok($body !~ /\b(?:16384|256)\b/,
        'mb606-789: aucune borne du contrat recopiee dans l outil');
    $assert->like($src, qr/Mediabot::PluginManager/,
        'mb606-789: l outil monte le vrai PluginManager');

    # [4] run reel
    ($rc, $out) = _run('run', 'examples-v2/karma.py', '--command', 'karma');
    $assert->is($rc, 0, 'mb606-789: run karma sort en 0');
    $assert->like($out, qr/reply\s+#dev: No karma yet/,
        'mb606-789: l action reply est montree avec sa cible');
    open my $st, '>', "$TMP/state.json" or die $!;
    print $st '{"scores":{"slay":3}}'; close $st;
    ($rc, $out) = _run('run', 'examples-v2/karma.py', '--command', 'thanks',
                       '--nick', 'aur', '--arg', 'SlaY', '--storage', "$TMP/state.json");
    $assert->like($out, qr/store\s+\d+ bytes/,
        'mb606-789: le store planifie est montre avec sa taille');
    $assert->like($out, qr/\Qslay":4\E/,
        'mb606-789: --storage a bien nourri data.storage (3 -> 4)');
    $assert->like($out, qr/Nothing was applied/,
        'mb606-789: l outil dit clairement qu il n applique rien');

    # [5] le contexte vient des donnees : cron = pas de canal
    ($rc, $out) = _run('run', 'examples-v2/daily.tcl',
        '--event', 'plugin_cron_observed',
        '--config', 'CHANNEL=#quebec', '--config', 'TEXT=Bonjour!',
        '--data', 'hour=9', '--data', 'minute=0',
        '--data', 'mday=7', '--data', 'month=8', '--data', 'year=2026');
    $assert->is($rc, 0, 'mb606-789: le cron configure sort en 0');
    $assert->like($out, qr/reply\s+#quebec: Bonjour!/,
        'mb606-789: un event reseau accepte un target EXPLICITE (pas de canal au contexte)');
    ($rc, $out) = _run('run', 'examples-v2/karma.py', '--event', 'channel_join_observed');
    $assert->is($rc, 1, 'mb606-789: un event non declare est refuse');

    # [6] zero effet de bord
    $assert->ok(!-e "$ROOT/plugin-data",
        'mb606-789: aucun repertoire de donnees cree par l outil');

    # [7] doc
    my $cb = do { open my $fh, '<:encoding(UTF-8)', "$ROOT/plugins/scripts/COOKBOOK.md"
        or die $!; local $/; <$fh> };
    $assert->like($cb, qr/mb_plugin_dev\.pl/,
        'mb606-789: le cookbook renvoie vers l outil');
};
