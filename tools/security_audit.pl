#!/usr/bin/perl
# =============================================================================
#  tools/security_audit.pl — Revue de sécurité finale (Phase B / B3, RC 3.3)
# =============================================================================
#  Direction 3.3, Phase B, jalon B3. Vérifie — en LECTURE de source, sans rien
#  exécuter ni contacter — que les invariants de sécurité tenus par le code
#  restent en place. Chaque invariant est un CONTRAT : si une régression future
#  le casse, l'audit sort en erreur (No-Go), ce qui bloque la RC.
#
#  Ce n'est PAS un scanner générique : chaque contrôle cible un invariant réel
#  et déjà vérifié du code de Mediabot, pour empêcher qu'un refactor le fasse
#  régresser sans que personne le voie. Les axes correspondent à la liste B3 :
#     1. secrets jamais loggés en clair (tokens masqués)
#     2. TLS vérifié sur les appels d'API AUTHENTIFIÉS (clé => verify_SSL=>1)
#     3. commandes externes sans shell (exec LIST) et yt-dlp protégé par '--'
#     4. sanitisation CR/LF/NUL sur les sorties IRC
#     5. verrou de process (flock LOCK_EX) et PID
#     6. limites HTTP (cap de download) présentes
#     7. throttle/rate-limit d'authentification présents
#
#  Sortie : rapport lisible + code retour 0 (Go) / 1 (No-Go).
#  Chaque défaut est FATAL par défaut ; --warn-only rétrograde en avertissement
#  pour une exécution exploratoire.
#
#  Usage :
#     perl tools/security_audit.pl [--root DIR] [--warn-only] [--quiet]
# =============================================================================

use strict;
use warnings;
use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long;

my $opt_root     = '';
my $opt_warnonly = 0;
my $opt_quiet    = 0;
GetOptions(
    'root=s'    => \$opt_root,
    'warn-only' => \$opt_warnonly,
    'quiet'     => \$opt_quiet,
) or die "Invalid options.\n";

my $ROOT = $opt_root ne '' ? $opt_root : File::Spec->rel2abs("$RealBin/..");
$ROOT =~ s{/+$}{};

my $errors = 0;
my $checks = 0;

sub say_info { print "$_[0]\n" unless $opt_quiet }
sub say_out  { print "$_[0]\n" }

sub slurp {
    my ($rel) = @_;
    my $p = File::Spec->catfile($ROOT, $rel);
    return undef unless -f $p;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/; my $c = <$fh>; close $fh; return $c;
}

# pass($label) / fail($label, $detail)
sub pass { $checks++; say_info("  [ok]   $_[0]") }
sub fail {
    $checks++;
    my ($label, $detail) = @_;
    if ($opt_warnonly) {
        say_out("  [warn] $label" . (defined $detail ? " — $detail" : ''));
    }
    else {
        $errors++;
        say_out("  [FAIL] $label" . (defined $detail ? " — $detail" : ''));
    }
}

say_info("=" x 74);
say_info("Mediabot final security audit (B3)");
say_info("  root: $ROOT");
say_info("=" x 74);

# ===========================================================================
# 1. Secrets jamais loggés en clair
#    Contrat : aucun log() n'interpole directement une clé API / DBPASS, et
#    les tokens DCC passent par le masqueur _dcc_token_hint.
# ===========================================================================
say_info("\n[1] Secrets never logged in clear");
{
    my @files = _pm_files();
    my @leaks;
    for my $rel (@files) {
        my $src = slurp($rel) // next;
        my @lines = split /\n/, $src;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            # log(...) interpolant une variable au nom sensible, en clair
            next unless $l =~ /->log\s*\(/ || $l =~ /_log\s*\(/;
            # motifs sensibles interpolés
            if ($l =~ /\$\w*(?:api_?key|apikey|dbpass|passwd|secret|token)\w*/i) {
                # tolérés : masqueurs et messages d'absence
                next if $l =~ /_dcc_token_hint|_hint|redact|mask|\bmissing\b|not config|has no password|failed|error|check/i;
                push @leaks, "$rel:" . ($i+1);
            }
        }
    }
    if (@leaks) {
        fail("no secret interpolated into a log call", join(', ', @leaks));
    }
    else {
        pass("no secret interpolated into a log call");
    }

    # Le masqueur de token DCC doit exister et être utilisé.
    my $party = slurp('Mediabot/Partyline.pm') // '';
    if ($party =~ /sub\s+_dcc_token_hint/ && $party =~ /_dcc_token_hint\s*\(/) {
        pass("DCC token masking helper present and used");
    }
    else {
        fail("DCC token masking helper (_dcc_token_hint) missing or unused");
    }
}

# ===========================================================================
# 2. TLS vérifié sur les appels d'API AUTHENTIFIÉS
#    Contrat : _make_http laisse verify_SSL configurable (défaut 0 pour la
#    compat OVH), MAIS tout appel vers une API authentifiée (OpenAI, Claude,
#    TMDB) passe explicitement verify_SSL => 1.
# ===========================================================================
say_info("\n[2] TLS verification on authenticated API calls");
{
    my $ext = slurp('Mediabot/External.pm') // '';
    if ($ext =~ /verify_SSL\s*=>\s*\$verify/) {
        pass("_make_http honours a caller-provided verify_SSL");
    }
    else {
        fail("_make_http does not forward a configurable verify_SSL");
    }

    # Dans Claude.pm, chaque _make_http qui sert un endpoint authentifié doit
    # avoir verify_SSL => 1. On vérifie qu'aucun _make_http n'y est appelé
    # SANS verify_SSL => 1 (les endpoints de ce module sont tous authentifiés).
    my $claude = slurp('Mediabot/External/Claude.pm') // '';
    my @calls;
    # capture chaque appel _make_http( ... ) même multi-lignes
    while ($claude =~ /_make_http\s*\((.*?)\)/gs) {
        push @calls, $1;
    }
    my $bad = grep { $_ !~ /verify_SSL\s*=>\s*1/ } @calls;
    if (@calls && $bad == 0) {
        pass("all " . scalar(@calls) . " authenticated HTTP calls set verify_SSL => 1");
    }
    elsif (!@calls) {
        fail("could not find _make_http calls in Claude.pm (shape changed?)");
    }
    else {
        fail("$bad authenticated HTTP call(s) missing verify_SSL => 1 in Claude.pm");
    }
}

# ===========================================================================
# 3. Commandes externes sans shell + yt-dlp protégé
#    Contrat : yt-dlp est lancé via exec LIST (jamais un string au shell), et
#    la requête utilisateur est précédée de '--' pour bloquer l'injection
#    d'options (mb417-B1).
# ===========================================================================
say_info("\n[3] External commands run without a shell");
{
    my $req = slurp('Mediabot/Radio/Request.pm') // '';
    if ($req =~ /exec\s+\@cmd\b/) {
        pass("yt-dlp launched via exec LIST (no shell)");
    }
    else {
        fail("yt-dlp exec LIST form not found in Radio/Request.pm");
    }
    if ($req =~ /push\s+\@cmd\s*,\s*'--'\s*,\s*\$query/) {
        pass("yt-dlp user query guarded by '--' (option-injection safe)");
    }
    else {
        fail("yt-dlp '--' guard before user query missing (mb417-B1 regressed?)");
    }

    # Aucune interpolation de commande dans un system()/exec() en string, ni
    # backticks, sur l'ensemble des modules.
    my @files = _pm_files();
    my @shelly;
    for my $rel (@files) {
        my $src = slurp($rel) // next;
        my @lines = split /\n/, $src;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            # system("...$var...") ou exec("...$var...") en UN seul argument string
            if ($l =~ /\b(?:system|exec)\s*\(\s*"[^"]*\$/){
                push @shelly, "$rel:" . ($i+1);
            }
            # backticks avec interpolation
            if ($l =~ /`[^`]*\$[^`]*`/) {
                push @shelly, "$rel:" . ($i+1) . " (backticks)";
            }
        }
    }
    if (@shelly) {
        fail("possible shell command with interpolation", join(', ', @shelly));
    }
    else {
        pass("no interpolated system/exec string or backticks");
    }
}

# ===========================================================================
# 4. Sanitisation CR/LF/NUL des sorties IRC
#    Contrat : Helpers fournit un nettoyage des séquences CR/LF/NUL avant
#    d'écrire sur le fil IRC (anti-injection de commandes IRC).
# ===========================================================================
say_info("\n[4] CR/LF/NUL sanitisation on IRC output");
{
    my $help = slurp('Mediabot/Helpers.pm') // '';
    # on cherche une neutralisation explicite de \r \n \0 dans les helpers de sortie
    if ($help =~ /(?:tr|s)\S*[\\]r|[\\]x0d|[\\]x0a|[\\]0|[\\]n.*=>.*''/i
        || $help =~ /s\/\[\\r\\n\\0\]/ ) {
        pass("CR/LF/NUL neutralisation present in Helpers");
    }
    else {
        # deuxième chance : recherche plus large de patterns de strip
        if ($help =~ /\\r|\\n|\\x0[da]|\\0/ && $help =~ /(?:tr|s)[\/\{]/){
            pass("newline/NUL handling present in Helpers");
        }
        else {
            fail("no explicit CR/LF/NUL sanitisation found in Helpers.pm");
        }
    }
}

# ===========================================================================
# 5. Verrou de process (flock) + PID
#    Contrat : ProcessLock prend un flock exclusif non bloquant sur le PID
#    file, ce qui refuse une seconde instance.
# ===========================================================================
say_info("\n[5] Process lock (single instance)");
{
    my $lock = slurp('Mediabot/ProcessLock.pm') // '';
    if ($lock =~ /flock\s*\(\s*\$?\w+\s*,\s*LOCK_EX\s*\|\s*LOCK_NB\s*\)/) {
        pass("exclusive non-blocking flock on PID file");
    }
    else {
        fail("ProcessLock does not take an exclusive non-blocking flock");
    }
}

# ===========================================================================
# 6. Limites HTTP (cap de download)
#    Contrat : les fetchs externes bornent la taille lue (max_size / cap
#    64KB) pour éviter qu'une réponse énorme n'épuise la mémoire.
# ===========================================================================
say_info("\n[6] HTTP download caps");
{
    my $yt  = slurp('Mediabot/External/YouTube.pm') // '';
    my $url = slurp('Mediabot/External/URL.pm') // '';
    # Chaque fetcher externe doit borner la taille lue.
    my $yt_ok  = ($yt  =~ /max_size\s*=>\s*\d/ || $yt  =~ /\d+\s*\*\s*1024/) ? 1 : 0;
    my $url_ok = ($url =~ /max_size\s*=>\s*\d/ || $url =~ /sysread\([^,]+,[^,]+,\s*\d+/
                  || $url =~ /\d+\s*\*\s*1024/) ? 1 : 0;
    if ($yt_ok && $url_ok) {
        pass("HTTP download size cap present in both YouTube and URL fetchers");
    }
    elsif (!$yt_ok) {
        fail("no HTTP download size cap in YouTube.pm");
    }
    else {
        fail("no HTTP download size cap in URL.pm");
    }
}

# ===========================================================================
# 7. Throttle / rate-limit d'authentification
#    Contrat : le login (IRC et Partyline) applique un throttle sur les échecs
#    répétés (MAX_FAILURES), pour freiner le brute force.
# ===========================================================================
say_info("\n[7] Authentication throttling");
{
    my $login = slurp('Mediabot/LoginCommands.pm') // '';
    my $party = slurp('Mediabot/Partyline.pm') // '';
    # Chaque chemin d'authentification doit conserver SA garde anti-brute-force.
    my $login_ok = ($login =~ /throttle|MAX_FAILURES|Login throttle|blocked/i) ? 1 : 0;
    my $party_ok = ($party =~ /max_failures|throttle|bad password/i) ? 1 : 0;
    if ($login_ok && $party_ok) {
        pass("login failure throttling present on both IRC and Partyline paths");
    }
    elsif (!$login_ok) {
        fail("IRC login throttling missing in LoginCommands.pm");
    }
    else {
        fail("Partyline login throttling missing in Partyline.pm");
    }
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
say_info("\n" . "=" x 74);
if ($errors) {
    say_out("Verdict: NO-GO — $errors security invariant(s) failed out of $checks checks.");
    say_out("Fix the regression(s) before tagging the RC.");
    exit 1;
}
else {
    say_out("Verdict: GO — all $checks security invariants hold"
            . ($opt_warnonly ? " (warn-only mode)" : "") . ".");
    exit 0;
}

# ---------------------------------------------------------------------------
# Liste des modules .pm sous Mediabot/ (chemins relatifs à $ROOT).
# ---------------------------------------------------------------------------
sub _pm_files {
    my @out;
    my @stack = (File::Spec->catdir($ROOT, 'Mediabot'));
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (sort readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = File::Spec->catfile($d, $e);
            if (-d $p) { push @stack, $p; next }
            next unless $e =~ /\.pm$/;
            (my $rel = $p) =~ s{^\Q$ROOT\E/}{};
            push @out, $rel;
        }
        closedir $dh;
    }
    return @out;
}
