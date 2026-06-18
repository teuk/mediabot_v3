# t/cases/520_mb298_calc_reference_plugin.t
# =============================================================================
# mb298 — plugin Python de référence : plugins/scripts/examples/calc.py
#
# Calculatrice arithmétique SÛRE routée en pcalc, car "calc" existe
# en interne). L'intérêt pédagogique : évaluer une entrée non fiable SANS eval().
# Le script parse l'expression en AST et n'autorise que des littéraux numériques
# et des opérateurs arithmétiques ; il borne aussi exposants et taille du
# résultat (anti-DoS type 9**9**9).
#
# Validé de bout en bout via le vrai bridge (ScriptRunner + ScriptActionRunner).
# Nécessite python3 ; SKIP sinon.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $ex   = File::Spec->catdir($root, 'plugins', 'scripts', 'examples');
my $calc = File::Spec->catfile($ex, 'calc.py');

plan skip_all => "calc.py not found" unless -e $calc;

# --- contrat statique : surtout, PAS d'eval() ni d'exec() --------------------
my $src = do { open my $fh, '<', $calc or die $!; local $/; <$fh> };
# strip comment lines: the header comment intentionally mentions eval() to explain
# why it is NOT used, so we must check the executable code only.
my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
like($src, qr/mediabot-script-v1/, 'calc.py declares the protocol');
unlike($code, qr/\beval\s*\(/,  'calc.py never calls eval()');
unlike($code, qr/\bexec\s*\(/,  'calc.py never calls exec()');
like($code, qr/ast\.parse/,     'calc.py parses expressions with the ast module');

my $have_py = `python3 -c "print(1)" 2>/dev/null` =~ /1/;
SKIP: {
    skip 'python3 not available', 17 unless $have_py;

    require Mediabot::ScriptRunner;
    require Mediabot::ScriptActionRunner;
    my $sr = Mediabot::ScriptRunner->new(script_dir => $ex, timeout => 5);
    my $ar = Mediabot::ScriptActionRunner->new;

    my $reply = sub {
        my (@args) = @_;
        my $r = $sr->run_script('calc.py', 'public_command',
            channel => '#teuk', nick => 'teuk', command => 'pcalc', args => \@args);
        my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
        return ($r, $plan, $plan->{planned}[0]{text} // '');
    };

    # --- calculs corrects -----------------------------------------------------
    {
        my ($r, $plan, $t) = $reply->('2', '+', '2', '*', '3');
        ok($plan->{ok}, '2+2*3 plan ok');
        like($t, qr/=\s*8\b/, '2 + 2 * 3 = 8 (operator precedence honoured)');
        is($plan->{planned}[0]{target}, '#teuk', 'reply defaults to the channel');
    }
    {
        my (undef, undef, $t) = $reply->('(10', '-', '4)', '/', '2');
        like($t, qr/=\s*3\b/, '(10 - 4) / 2 = 3');
    }
    {
        my (undef, undef, $t) = $reply->('2', '**', '10');
        like($t, qr/=\s*1024\b/, '2 ** 10 = 1024');
    }

    # --- erreurs amicales -----------------------------------------------------
    {
        my (undef, undef, $t) = $reply->('1', '/', '0');
        like($t, qr/division by zero/, 'division by zero is reported, not crashed');
    }
    {
        my (undef, undef, $t) = $reply->();
        like($t, qr/usage:/, 'empty input yields a usage hint');
    }

    # --- SÉCURITÉ : aucune exécution de code ---------------------------------
    {
        my ($r, $plan, $t) = $reply->('__import__("os").system("id")');
        ok($r->{response}{ok}, 'code-injection attempt still returns a clean response');
        like($t, qr/unsupported expression/, 'function calls / imports are rejected (no eval)');
    }
    {
        my (undef, undef, $t) = $reply->('open("/etc/passwd")');
        like($t, qr/unsupported expression/, 'open() is rejected');
    }
    {
        my (undef, undef, $t) = $reply->('x', '+', '1');
        like($t, qr/unsupported expression/, 'bare names are rejected');
    }

    # --- DoS : grosses puissances rejetées AVANT calcul ----------------------
    {
        my (undef, undef, $t) = $reply->('9', '**', '9', '**', '9');
        like($t, qr/exponent too large/, '9**9**9 is rejected before evaluation (no DoS)');
    }
    {
        my (undef, undef, $t) = $reply->('(-1)', '**', '0.5');
        like($t, qr/unsupported result/, 'complex result (root of a negative) is rejected');
    }
    {
        my ($r, $plan, $t) = $reply->('1e309');
        ok($r->{ok}, 'non-finite literal still returns a structured response');
        ok($plan->{ok}, 'non-finite literal produces a valid reply plan');
        like($t, qr/number too large/, 'positive infinity literal is rejected cleanly');
    }
    {
        my ($r, $plan, $t) = $reply->('0', '**', '-1');
        ok($r->{ok}, 'zero to a negative power still returns a structured response');
        ok($plan->{ok}, 'zero to a negative power produces a valid reply plan');
        like($t, qr/division by zero/, 'zero to a negative power is reported without crashing');
    }
}

done_testing();
