# t/cases/401_mb221_scriptrunner_symlink_and_stdin_hardening.t
# =============================================================================
# Tests du durcissement mb221 de Mediabot::ScriptRunner :
#
#   - B1 : validate_script_path bloquait la traversee textuelle ('..', chemins
#          absolus, backslash, NUL) mais un lien symbolique place DANS
#          script_dir et pointant a l'EXTERIEUR etait accepte et execute
#          (evasion de script_dir). Fix : verification de containment par
#          realpath (Cwd::abs_path) quand le fichier existe.
#
#   - B2 : run_plan ecrivait stdin avec un print bloquant. Si un script ne
#          draine jamais stdin tout en remplissant son stdout, le parent
#          bloquait sur le print AVANT meme d'entrer dans la boucle de lecture
#          bornee par le deadline -> hang non borne (meme classe que mb220,
#          mais sur l'ecriture). Non atteignable aujourd'hui (payload minuscule)
#          mais durci : ecriture non bloquante bornee par le deadline, avec
#          kill TERM->KILL si le script n'accepte pas stdin a temps.
# =============================================================================

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes qw(time);

my $case = sub {
    my ($assert) = @_;

    my $loaded = eval { require Mediabot::ScriptRunner; 1; };
    unless ($loaded) {
        $assert->(0, "setup: chargement Mediabot::ScriptRunner impossible ($@)");
        return;
    }

    my $root = tempdir(CLEANUP => 1);
    my $script_dir = "$root/scripts";
    make_path($script_dir);

    my $write = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "open $path: $!";
        print {$fh} $body;
        close $fh;
    };

    # ---------------------------------------------------------------------
    # B1 — containment symlink
    # ---------------------------------------------------------------------
    $write->("$root/evil_target.pl", 'print q({"actions":[]});' . "\n");
    my $sym_ok = eval { symlink("$root/evil_target.pl", "$script_dir/evil_link.pl"); 1; };

    unless ($sym_ok && -l "$script_dir/evil_link.pl") {
        # Plateforme sans symlink : on ne peut pas tester B1, on le note et on
        # passe a B2 sans echouer.
        $assert->(1, "B1 skip: symlink non supporte sur cette plateforme");
    }
    else {
        $write->("$script_dir/ok.pl", 'print q({"actions":[{"type":"log","text":"ok"}]});' . "\n");
        $write->("$script_dir/real.pl", 'print q({"actions":[]});' . "\n");
        symlink("$script_dir/real.pl", "$script_dir/inside_link.pl");

        my $sr = Mediabot::ScriptRunner->new(script_dir => $script_dir, timeout => 2);

        my ($ok_evil, $err_evil) = $sr->validate_script_path('evil_link.pl');
        $assert->(($ok_evil // 0) == 0,
            "B1 symlink vers l'exterieur : rejete par validate_script_path");
        $assert->(defined($err_evil) && $err_evil =~ /escape/i,
            "B1 message d'erreur explicite ('escapes script directory')");

        my ($ok_inside) = $sr->validate_script_path('inside_link.pl');
        $assert->(($ok_inside // 0) == 1,
            "B1 symlink interne (cible dans script_dir) : autorise");

        my ($ok_plain) = $sr->validate_script_path('ok.pl');
        $assert->(($ok_plain // 0) == 1,
            "B1 fichier normal : autorise");

        # fichier inexistant : autorise a la validation (echouera a l'exec)
        my ($ok_missing) = $sr->validate_script_path('does_not_exist.pl');
        $assert->(($ok_missing // 0) == 1,
            "B1 fichier inexistant : autorise a la validation (containment seulement si -e)");

        # execution reelle : le symlink d'evasion doit echouer, le normal reussir
        my $r_evil = $sr->run_script('evil_link.pl', 'evt');
        $assert->(($r_evil->{ok} // 1) == 0,
            "B1 run du symlink d'evasion : echoue");

        my $r_ok = $sr->run_script('ok.pl', 'evt');
        $assert->(($r_ok->{ok} // 0) == 1,
            "B1 run du script normal : reussit");
    }

    # ---------------------------------------------------------------------
    # B2 — ecriture stdin bornee par le deadline
    # ---------------------------------------------------------------------
    # Script qui ne lit jamais stdin et ne se termine jamais (jusqu'au kill).
    $write->("$script_dir/blackhole.pl", "while (1) { sleep 1 }\n");
    # Script normal pour la non-regression et le test "etat non casse".
    $write->("$script_dir/plain.pl", 'print q({"actions":[]});' . "\n");

    my $timeout = 2;
    my $sr2 = Mediabot::ScriptRunner->new(
        script_dir       => $script_dir,
        timeout          => $timeout,
        max_stdout_bytes => 1048576,
    );

    # Payload volumineux (~2MB) qui ne pourra pas tenir dans le buffer de pipe
    # si le script ne draine pas stdin.
    my @big = ('x' x 700_000, 'y' x 700_000, 'z' x 700_000);

    {
        my $t0 = time();
        my $r  = $sr2->run_script('blackhole.pl', 'evt', blob => \@big);
        my $dt = time() - $t0;

        $assert->(($r->{timeout} // 0) == 1,
            "B2 blackhole + gros stdin : marque comme timeout (pas de hang)");
        $assert->(($r->{ok} // 1) == 0,
            "B2 blackhole : ok=0");
        $assert->($dt < $timeout + 3,
            sprintf("B2 termine sous timeout+marge (%.2fs < %ds) [bug: hang non borne]",
                $dt, $timeout + 3));
        $assert->($dt < 10,
            sprintf("B2 clairement borne (%.2fs << infini)", $dt));
    }

    # Etat non casse : un appel suivant fonctionne encore
    {
        my $r = $sr2->run_script('plain.pl', 'evt');
        $assert->(($r->{ok} // 0) == 1,
            "B2 apres timeout+kill, l'appel suivant fonctionne (etat sain)");
    }

    # Non-regression : petit stdin normal, script qui lit et repond
    {
        $write->("$script_dir/echo.pl",
            'my $in = do { local $/; <STDIN> }; print q({"actions":[{"type":"log","text":"got"}]});' . "\n");
        my $r = $sr2->run_script('echo.pl', 'public_command', command => 'x', nick => 'teuk');
        $assert->(($r->{ok} // 0) == 1,
            "B2 non-regression : petit stdin lu normalement, script OK");
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
