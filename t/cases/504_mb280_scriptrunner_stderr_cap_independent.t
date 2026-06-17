# t/cases/504_mb280_scriptrunner_stderr_cap_independent.t
# =============================================================================
# Régression mb280-B1 (Mediabot::ScriptRunner) :
#
#   Bug : le constructeur lisait `max_stdout_bytes` mais JAMAIS
#   `max_stderr_bytes` (silencieusement ignoré), et run_plan() retombait sur
#   `$self->{max_stdout_bytes}` pour le plafond stderr. Conséquence :
#   `max_stderr_bytes` passé au constructeur n'avait aucun effet, et stderr ne
#   pouvait pas être plafonné indépendamment de stdout.
#
#   Fix : `max_stderr_bytes` devient un plafond runtime de première classe
#   (lu + borné au constructeur, accesseur dédié, propagé dans le plan, et
#   utilisé comme fallback stderr dans run_plan). Défaut inchangé (64 KiB).
#
# Exécutable sans DBI ni tclsh (vérifications unitaires + sous-processus perl).
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Temp qw(tempdir);
use Test::More;

require Mediabot::ScriptRunner;

# --- Le constructeur honore désormais max_stderr_bytes ---
{
    my $r = Mediabot::ScriptRunner->new(
        max_stdout_bytes => 200000,
        max_stderr_bytes => 4096,
    );
    is($r->max_stderr_bytes, 4096, 'max_stderr_bytes is honored at construction');
    is($r->max_stdout_bytes, 200000, 'max_stdout_bytes stays independent');
    isnt($r->max_stderr_bytes, $r->max_stdout_bytes,
        'stderr and stdout caps are independent');
}

# --- Défaut conservé (64 KiB) quand non fourni ---
{
    my $r = Mediabot::ScriptRunner->new(max_stdout_bytes => 200000);
    is($r->max_stderr_bytes, 65536, 'max_stderr_bytes defaults to 64 KiB (unchanged behavior)');
}

# --- Une ref est ignorée et retombe sur le défaut (contrat scalaire) ---
{
    my $r = Mediabot::ScriptRunner->new(max_stderr_bytes => [ 1 ]);
    is($r->max_stderr_bytes, 65536, 'ARRAY ref max_stderr_bytes falls back to default');
}

# --- Borne basse/haute appliquées ---
{
    my $lo = Mediabot::ScriptRunner->new(max_stderr_bytes => 10);
    is($lo->max_stderr_bytes, 1024, 'max_stderr_bytes clamps to 1 KiB lower bound');
    my $hi = Mediabot::ScriptRunner->new(max_stderr_bytes => 50 * 1024 * 1024);
    is($hi->max_stderr_bytes, 1048576, 'max_stderr_bytes clamps to 1 MiB upper bound');
}

# --- Bout-en-bout : stderr réellement plafonné au niveau configuré ---
SKIP: {
    my $perl = $^X;
    skip 'perl interpreter not found', 2 unless $perl && -x $perl;

    my $dir = tempdir(CLEANUP => 1);
    # script qui écrit beaucoup sur stderr puis renvoie un plan d'actions valide
    open my $fh, '>', "$dir/noisy.pl" or die $!;
    print {$fh} <<'PL';
my $in = do { local $/; <STDIN> };
print STDERR ('E' x 200000);
print STDOUT '{"ok":true,"actions":[]}';
PL
    close $fh;

    my $r = Mediabot::ScriptRunner->new(
        script_dir       => $dir,
        timeout          => 5,
        max_stdout_bytes => 65536,
        max_stderr_bytes => 4096,
    );
    my $res = $r->run_script('noisy.pl', 'public_command', command => 'x');
    ok($res->{ok}, 'noisy script still produces a valid response');
    ok(length($res->{stderr} // '') <= 4096,
        'stderr is capped at the configured max_stderr_bytes (4096), not the stdout cap');
}

done_testing();
