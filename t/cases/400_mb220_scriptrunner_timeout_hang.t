# t/cases/400_mb220_scriptrunner_timeout_hang.t
# =============================================================================
# Test de la correction mb220 :
#
#   - B1 : Mediabot::ScriptRunner::run_plan terminait sa boucle de lecture des
#          que les deux descripteurs (stdout/stderr) du process enfant
#          atteignaient EOF. Si un script fermait stdout+stderr PUIS continuait
#          a tourner (ex: `close STDOUT; close STDERR; sleep 3600`), la boucle
#          select se terminait immediatement et le waitpid($pid, 0) final
#          bloquait jusqu'a la fin naturelle de l'enfant -> le timeout etait
#          contourne et le bot pouvait etre gele arbitrairement longtemps
#          (l'execution en mode apply tourne dans l'event loop IRC).
#
#          Fix : reap borne par la meme deadline, avec escalade TERM -> KILL.
#
# Ce test cree des scripts Perl temporaires et les execute reellement via
# ScriptRunner pour verifier que le timeout est respecte dans les deux cas :
#   1. script qui dort (cas classique, deja correct)
#   2. script qui ferme ses descripteurs puis dort (cas du bug)
# =============================================================================

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes qw(time);

my $case = sub {
    my ($assert) = @_;

    # ScriptRunner est chargeable sans dependances DB.
    my $loaded = eval {
        require Mediabot::ScriptRunner;
        1;
    };
    unless ($loaded) {
        $assert->(0, "B1 setup: impossible de charger Mediabot::ScriptRunner ($@)");
        return;
    }

    # Arbre temporaire: <dir>/plugins/scripts/<scripts>
    my $root = tempdir(CLEANUP => 1);
    my $script_dir = "$root/scripts";
    make_path($script_dir);

    my $write = sub {
        my ($name, $body) = @_;
        my $path = "$script_dir/$name";
        open my $fh, '>', $path or die "open $path: $!";
        print {$fh} $body;
        close $fh;
        return $name;
    };

    # Script 1 : dort plus longtemps que le timeout (cas classique)
    $write->('sleep.pl', '$|=1; sleep 10; print q({"actions":[]});' . "\n");

    # Script 2 : ferme stdout+stderr puis dort (cas du bug mb220-B1)
    $write->('close_then_hang.pl', "close STDOUT; close STDERR; sleep 30;\n");

    # Script 3 : repond normalement et vite (non-regression)
    $write->('normal.pl', 'print q({"actions":[{"type":"reply","text":"hi"}]});' . "\n");

    my $timeout = 2;
    my $sr = Mediabot::ScriptRunner->new(script_dir => $script_dir, timeout => $timeout);

    # -------------------------------------------------------------------------
    # Cas 1 : script normal -> rapide, ok, pas de timeout
    # -------------------------------------------------------------------------
    {
        my $t0 = time();
        my $r  = $sr->run_script('normal.pl', 'evt');
        my $dt = time() - $t0;

        $assert->(ref($r) eq 'HASH', "B1 normal: resultat est un hash");
        $assert->(($r->{timeout} // 0) == 0, "B1 normal: pas de timeout");
        $assert->(($r->{ok} // 0) == 1, "B1 normal: ok=1");
        $assert->($dt < $timeout, "B1 normal: termine bien avant le timeout (${timeout}s)");
        $assert->(scalar(@{ $r->{response}{actions} || [] }) == 1,
            "B1 normal: 1 action retournee");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : script qui dort -> timeout respecte (cas deja correct avant)
    # -------------------------------------------------------------------------
    {
        my $t0 = time();
        my $r  = $sr->run_script('sleep.pl', 'evt');
        my $dt = time() - $t0;

        $assert->(($r->{timeout} // 0) == 1, "B1 sleep: timeout=1");
        $assert->(($r->{ok} // 1) == 0, "B1 sleep: ok=0");
        # marge: timeout + 0.2s (TERM->KILL) + un peu d'overhead
        $assert->($dt < $timeout + 2,
            sprintf("B1 sleep: termine sous timeout+marge (%.2fs < %ds)", $dt, $timeout + 2));
    }

    # -------------------------------------------------------------------------
    # Cas 3 : REGRESSION-POC / FIX — close stdout+stderr puis hang
    # -------------------------------------------------------------------------
    # Avant mb220-B1: ce cas durait ~30s (la duree du sleep du script) car
    # waitpid bloquait. Apres le fix: ~timeout secondes.
    {
        my $t0 = time();
        my $r  = $sr->run_script('close_then_hang.pl', 'evt');
        my $dt = time() - $t0;

        $assert->(($r->{timeout} // 0) == 1,
            "B1 FIX close+hang: marque comme timeout");
        $assert->(($r->{ok} // 1) == 0,
            "B1 FIX close+hang: ok=0");
        $assert->($dt < $timeout + 3,
            sprintf("B1 FIX close+hang: tue sous timeout+marge (%.2fs < %ds) [bug: ~30s]",
                $dt, $timeout + 3));
        # Le script dort 30s; si le fix marche, on est tres en dessous.
        $assert->($dt < 10,
            sprintf("B1 FIX close+hang: clairement < duree du sleep script (%.2fs << 30s)", $dt));
    }

    # -------------------------------------------------------------------------
    # Cas 4 : le process enfant ne reste pas zombie / le bot continue
    # -------------------------------------------------------------------------
    # Apres un timeout avec KILL, un nouvel appel doit fonctionner normalement
    # (preuve que run_plan n'a pas laisse l'etat casse).
    {
        my $r = $sr->run_script('normal.pl', 'evt');
        $assert->(($r->{ok} // 0) == 1,
            "B1 FIX: apres un timeout+kill, un appel suivant fonctionne encore");
    }
};

# mb223-B1: direct-run harness for Claude mb22x test.
if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
