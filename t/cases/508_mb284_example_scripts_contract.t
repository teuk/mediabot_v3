# t/cases/508_mb284_example_scripts_contract.t
# =============================================================================
# mb284 — exemples de plugins : correction de bug + contrat best-practice.
#
#   B1 (bug) : dans plugins/scripts/examples/hello_tcl.tcl, json_escape utilisait
#   `[list \\\\ \\\\\\\\ ...]` -> la CLÉ d'échappement du backslash valait DEUX
#   backslashes (et la valeur QUATRE) au lieu d'UN -> DEUX. Un backslash isolé
#   dans le texte n'était donc pas échappé, produisant du JSON invalide/corrompu.
#   Latent dans l'exemple (les commandes sont alphanumériques) mais c'est un
#   script de RÉFÉRENCE que les auteurs copient. Corrigé en `[list \\ \\\\ ...]`.
#
#   Amélioration : les trois exemples (perl/python/tcl) émettent désormais
#   explicitement `"ok": true` et `"protocol": "mediabot-script-v1"` (le contrat
#   recommandé), tout en conservant le comportement testé (perl: target=canal ;
#   python: pas de target -> défaut contexte ; texte de reply inchangé).
#
# Le check statique des octets tourne partout ; le check fonctionnel Tcl ne
# tourne que si `tclsh` est présent (sandbox : SKIP).
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $ex   = File::Spec->catdir($root, 'plugins', 'scripts', 'examples');

sub slurp { my $p = shift; open my $fh, '<', $p or die "$p: $!"; local $/; <$fh> }

my $tcl_src = slurp(File::Spec->catfile($ex, 'hello_tcl.tcl'));

# --- B1 : check statique de la correction du json_escape (sans tclsh) --------
# La forme correcte est `[list \\ \\\\ ...]` : en Tcl, après substitution de la
# commande, la clé = 1 backslash, la valeur = 2 backslashes.
like($tcl_src, qr/string map \[list \\\\ \\\\\\\\ /,
    'Tcl json_escape uses the correct single-backslash key (\\ -> \\\\)');
unlike($tcl_src, qr/string map \[list \\\\\\\\ \\\\\\\\\\\\\\\\ /,
    'Tcl json_escape no longer uses the buggy double-backslash key');

# --- contrat best-practice présent dans les trois exemples -------------------
my $perl_src = slurp(File::Spec->catfile($ex, 'hello_perl.pl'));
my $py_src   = slurp(File::Spec->catfile($ex, 'hello_python.py'));

like($perl_src, qr/mediabot-script-v1/, 'Perl example declares the protocol');
like($py_src,   qr/mediabot-script-v1/, 'Python example declares the protocol');
like($tcl_src,  qr/mediabot-script-v1/, 'Tcl example declares the protocol');
like($perl_src, qr/ok\s*=>\s*JSON::PP::true/, 'Perl example sets ok => true explicitly');
like($py_src,   qr/"ok":\s*True/,            'Python example sets ok: True explicitly');
like($tcl_src,  qr/"ok":true/,               'Tcl example sets ok:true explicitly');

# --- perl/python : run réel + contrat préservé (sans DBI) --------------------
require Mediabot::ScriptRunner;
require Mediabot::ScriptActionRunner;

my $runner = Mediabot::ScriptRunner->new(script_dir => $ex, timeout => 5);
my $ar     = Mediabot::ScriptActionRunner->new;

SKIP: {
    skip 'perl interpreter not found', 4 unless $^X && -x $^X;
    my $r = $runner->run_script('hello_perl.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'mb284');
    ok($r->{ok}, 'Perl example run is ok');
    ok($r->{response}{ok}, 'Perl example response ok flag is true');
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    is($plan->{planned}[0]{target}, '#teuk', 'Perl example reply target is the explicit channel');
    like($plan->{planned}[0]{text}, qr/Perl script bridge OK/, 'Perl reply text preserved');
}

SKIP: {
    my $py = `python3 -c "print(1)" 2>/dev/null`;
    skip 'python3 not found', 3 unless $py =~ /1/;
    my $r = $runner->run_script('hello_python.py', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'mb284');
    ok($r->{response}{ok}, 'Python example response ok flag is true');
    my $plan = $ar->apply_actions_dry($r, { channel => '#teuk' });
    is($plan->{planned}[0]{target}, '#teuk',
        'Python example reply target defaults from context channel');
    like($plan->{planned}[0]{text}, qr/Python script bridge OK/, 'Python reply text preserved');
}

# --- B1 : check FONCTIONNEL Tcl (si tclsh présent) ---------------------------
# Vérifie que json_escape échappe correctement un backslash isolé : la sortie,
# entourée de guillemets, doit être du JSON valide qui re-décode en a\b"c.
SKIP: {
    my $tclsh;
    for my $dir (split /:/, $ENV{PATH} || '') {
        my $cand = File::Spec->catfile($dir, 'tclsh');
        if (-x $cand) { $tclsh = $cand; last; }
    }
    skip 'tclsh not available (validate this on the bot host / CI)', 1 unless $tclsh;

    # extrait le corps de la proc json_escape depuis le fichier réel
    my ($body) = $tcl_src =~ /proc\s+json_escape\s+\{value\}\s+\{(.*?)\}/s;
    skip 'could not extract json_escape proc', 1 unless defined $body;

    my $dir = tempdir(CLEANUP => 1);
    my $drv = File::Spec->catfile($dir, 'drv.tcl');
    open my $fh, '>', $drv or die $!;
    # valeur de test contenant un backslash isolé, un guillemet et une tabulation
    print {$fh} qq{proc json_escape {value} {$body}\n};
    print {$fh} qq{puts -nonewline [json_escape "a\\\\b\\"c\\td"]\n};
    close $fh;

    my $escaped = `"$tclsh" "$drv" 2>/dev/null`;
    require JSON::PP;
    my $decoded = eval { JSON::PP->new->decode(qq{"$escaped"}) };
    ok(defined $decoded && $decoded eq qq{a\\b"c\td},
        'Tcl json_escape correctly escapes a lone backslash/quote/tab into valid JSON')
        or diag("escaped='$escaped' decoded=" . (defined $decoded ? $decoded : '(decode failed)'));
}

done_testing();
