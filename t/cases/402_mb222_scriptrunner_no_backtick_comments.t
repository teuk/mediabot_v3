# t/cases/402_mb222_scriptrunner_no_backtick_comments.t
# =============================================================================
# Test de la correction mb222 :
#
#   - B1 : les commentaires ajoutes en mb220 (reap borne) et mb221 (ecriture
#          stdin non bloquante) citaient du code entre backticks, par exemple
#          `print {$child_in} $stdin` et `close STDOUT; close STDERR; sleep`.
#          Le contrat de pre-commit du projet (t/cases/441_mb204) interdit
#          toute construction d'execution shell via le motif :
#
#              `[^`]+`  |  \bqx\s*(?:/|\(|\{)  |  \bsystem\s*(?:\(| )
#
#          Le sous-motif backtick `[^`]+` matchait donc ces commentaires et
#          FAISAIT ECHOUER le test d'hygiene -> le commit aurait ete bloque.
#
#          Fix : reformuler les deux commentaires en prose, sans backticks.
#
# Ce test verrouille la regression : ScriptRunner.pm ne doit contenir aucun
# backtick et doit passer exactement le meme motif que le garde mb204.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    # Localiser ScriptRunner.pm de facon robuste : on tente plusieurs racines
    # pour ne pas dependre du cwd du lanceur de tests.
    my @candidates = (
        File::Spec->catfile($Bin, '..', '..', 'Mediabot', 'ScriptRunner.pm'),
        File::Spec->catfile('Mediabot', 'ScriptRunner.pm'),
        File::Spec->catfile($Bin, 'Mediabot', 'ScriptRunner.pm'),
    );

    my $path;
    for my $c (@candidates) {
        if (-f $c) { $path = $c; last; }
    }

    unless ($path) {
        $assert->(0, "setup: ScriptRunner.pm introuvable (cwd/Bin)");
        return;
    }

    my $src = do {
        open my $fh, '<', $path or do {
            $assert->(0, "setup: open $path: $!");
            return;
        };
        local $/;
        <$fh>;
    };

    $assert->(length $src, "ScriptRunner.pm lu et non vide");

    # 1) Aucun backtick du tout dans le fichier.
    my $backtick_count = () = ($src =~ /`/g);
    $assert->($backtick_count == 0,
        "ScriptRunner.pm ne contient aucun backtick (trouve: $backtick_count)");

    # 2) Le motif EXACT du garde d'hygiene mb204 ne doit pas matcher.
    my $hygiene_re = qr{`[^`]+`|\bqx\s*(?:/|\(|\{)|\bsystem\s*(?:\(| )};
    my $matched = ($src =~ $hygiene_re) ? 1 : 0;
    $assert->($matched == 0,
        "ScriptRunner.pm passe le garde anti-shell mb204 (pas de match)");

    # 3) Verifier que les protections mb220/mb221 sont toujours en place
    #    (on ne veut pas avoir retire le code en retirant les backticks).
    $assert->($src =~ /mb220-B1/,
        "le fix mb220-B1 (reap borne) est toujours present");
    $assert->($src =~ /mb221-B1/,
        "le fix mb221-B1 (containment symlink) est toujours present");
    $assert->($src =~ /mb221-B2/,
        "le fix mb221-B2 (stdin non bloquant) est toujours present");
    $assert->($src =~ /WNOHANG/,
        "le reap non bloquant (WNOHANG) est toujours present");
    $assert->($src =~ /O_NONBLOCK/,
        "l'ecriture stdin non bloquante (O_NONBLOCK) est toujours presente");
    $assert->($src =~ /escapes script directory/,
        "le message de containment symlink est toujours present");
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
