#!/usr/bin/perl
# =============================================================================
#  tools/security_audit.pl — Contrat de sécurité transversal (B3 + MB724, 3.5)
# =============================================================================
#  Le socle historique B3 est conservé. MB724 l'étend à toute la surface 3.5
#  acceptée. L'outil vérifie — en LECTURE de source, sans rien
#  exécuter ni contacter — que les invariants de sécurité tenus par le code
#  restent en place. Chaque invariant est un CONTRAT : si une régression future
#  le casse, l'audit sort en erreur (No-Go), ce qui bloque la RC.
#
#  Ce n'est PAS un scanner générique : chaque contrôle cible un invariant réel
#  et déjà vérifié du code de Mediabot, pour empêcher qu'un refactor le fasse
#  régresser sans que personne le voie. Les axes correspondent à la liste B3 :
#     1. secrets jamais loggés en clair (tokens masqués)
#     2. TLS vérifié par défaut; bypass explicite borné; API authentifiées explicites
#     3. commandes externes sans shell (exec LIST) et yt-dlp protégé par '--'
#     4. sanitisation CR/LF/NUL sur les sorties IRC
#     5. verrou de process (flock LOCK_EX) et PID
#     6. limites HTTP (cap de download) présentes
#     7. throttle/rate-limit d'authentification présents
#     8. workers et scripts bornés, sans shell implicite
#     9. transport IA HTTPS, TLS, timeout et réponse bornée
#    10. cerveaux Hailo isolés et fallback local déterministe
#    11. observabilité agrégée sans contenu de conversation
#    12. interfaces privilégiées et updater fail-closed
#    13. identités systemd et chemins inscriptibles minimaux
#    14. restauration et archives publiques bornées
#    15. sessions, CSRF, requêtes et upstreams mbweb bornés
#    16. diagnostic DB en lecture seule contre la référence
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
say_info("Mediabot cross-cutting security audit (B3 + MB724)");
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
    # MB678: le transport peut vivre dans Partyline/Transport.pm ; l'invariant
    # de sécurité porte sur l'ensemble de la couche Partyline, pas sur son
    # emplacement physique dans un fichier unique.
    my $party = join "\n",
        (slurp('Mediabot/Partyline.pm') // ''),
        (slurp('Mediabot/Partyline/Transport.pm') // '');

    if ($party =~ /sub\s+_dcc_token_hint/ && $party =~ /_dcc_token_hint\s*\(/) {
        pass("DCC token masking helper present and used");
    }
    else {
        fail("DCC token masking helper (_dcc_token_hint) missing or unused");
    }
}

# ===========================================================================
# 2. TLS vérifié par défaut et exceptions explicites bornées
#    Contrat : _make_http reste configurable mais son défaut est verify_SSL=1.
#    Un opt-out verify_SSL=>0 est une exception de compatibilité et doit rester
#    unique, explicite et localisée au client Icecast configurable. Les appels
#    authentifiés sensibles conservent en plus un verify_SSL=>1 explicite.
# ===========================================================================
say_info("\n[2] TLS verification secure by default");
{
    my $ext = slurp('Mediabot/External.pm') // '';
    if ($ext =~ /exists\s+\$opts\{verify_SSL\}.*?:\s*1\s*;/s
            && $ext =~ /verify_SSL\s*=>\s*\$verify/) {
        pass("_make_http defaults to verified TLS and honours explicit overrides");
    }
    else {
        fail("_make_http is not secure-by-default or no longer forwards verify_SSL");
    }

    my @bypass;
    for my $rel (_pm_files()) {
        my $src = slurp($rel) // next;
        my @lines = split /\n/, $src;

        for my $i (0 .. $#lines) {
            my $line = $lines[$i];

            next if $line =~ /^\s*#/;

            push @bypass, "$rel:" . ($i + 1)
                if $line =~ /verify_SSL\s*=>\s*0/;
        }
    }

    if (@bypass == 1
            && $bypass[0] =~ /^Mediabot\/AdminCommands[.]pm:/) {
        pass("only the reviewed Icecast compatibility path disables TLS verification");
    }
    else {
        fail(
            "unexpected explicit verify_SSL=>0 call(s)",
            join(', ', @bypass)
        );
    }

    my $news = slurp('Mediabot/External/News.pm') // '';

    if ($news =~ /my\s+\$http\s*=\s*Mediabot::External::_make_http\s*\(.*?verify_SSL\s*=>\s*1.*?\);/s
            && $news =~ /api_key\s*=>\s*\$api_key/) {
        pass("Tavily authenticated news search pins verify_SSL => 1");
    }
    else {
        fail("Tavily authenticated news search is not explicitly TLS-verified");
    }

    my $helpers = slurp('Mediabot/Helpers.pm') // '';

    if ($helpers =~ /HTTP::Tiny->new\(timeout\s*=>\s*3,\s*verify_SSL\s*=>\s*1\)->get\(\$whereis_url\)/) {
        pass("country.is HTTPS lookup explicitly verifies TLS");
    }
    else {
        fail("country.is HTTPS lookup does not explicitly verify TLS");
    }

    # Dans Claude.pm, chaque _make_http qui sert un endpoint authentifié doit
    # avoir verify_SSL => 1. On vérifie qu'aucun _make_http n'y est appelé
    # SANS verify_SSL => 1.
    my $claude = slurp('Mediabot/External/Claude.pm') // '';
    my @calls;

    while ($claude =~ /_make_http\s*\((.*?)\)/gs) {
        push @calls, $1;
    }

    my $bad = grep {
        $_ !~ /verify_SSL\s*=>\s*1/
    } @calls;

    if (@calls && $bad == 0) {
        pass(
            "all "
            . scalar(@calls)
            . " authenticated HTTP calls set verify_SSL => 1"
        );
    }
    elsif (!@calls) {
        fail(
            "could not find _make_http calls in Claude.pm (shape changed?)"
        );
    }
    else {
        fail(
            "$bad authenticated HTTP call(s) missing verify_SSL => 1 in Claude.pm"
        );
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
    my $party = join "\n",
        (slurp('Mediabot/Partyline.pm') // ''),
        (slurp('Mediabot/Partyline/SessionAuth.pm') // '');
    # Chaque chemin d'authentification doit conserver SA garde anti-brute-force.
    # MB678-II: l'invariant suit la couche Partyline session/auth au lieu de
    # supposer que toute son implementation vit dans Partyline.pm.
    my $login_ok = ($login =~ /throttle|MAX_FAILURES|Login throttle|blocked/i) ? 1 : 0;
    my $party_ok = ($party =~ /max_failures|throttle|bad password/i) ? 1 : 0;
    if ($login_ok && $party_ok) {
        pass("login failure throttling present on both IRC and Partyline paths");
    }
    elsif (!$login_ok) {
        fail("IRC login throttling missing in LoginCommands.pm");
    }
    else {
        fail("Partyline login throttling missing in Partyline session/auth layer");
    }
}

# ===========================================================================
# 8. Workers et scripts bornés, sans shell implicite
# ===========================================================================
say_info("\n[8] Bounded workers and script execution");
{
    my $worker = slurp('Mediabot/AsyncWorker.pm') // '';
    if ($worker =~ /DEFAULT_TIMEOUT\s*=\s*30/
            && $worker =~ /DEFAULT_MAX_OUTPUT\s*=\s*64\s*\*\s*1024/
            && $worker =~ /_begin_termination\('timeout'\)/
            && $worker =~ /_signal_child\('TERM'\).*?_signal_child\('KILL'\)/s) {
        pass("AsyncWorker enforces timeout, output cap and TERM/KILL escalation");
    }
    else {
        fail("AsyncWorker bounded lifecycle contract is incomplete");
    }

    my $runner = slurp('Mediabot/ScriptRunner.pm') // '';
    if ($runner =~ /validate_script_path\(\$plan->\{script\}\)/
            && $runner =~ /open3\(\$child_in,\s*\$child_out,\s*\$child_err,\s*\@cmd\)/
            && $runner =~ /\$timeout\s*=\s*30\s+if\s+\$timeout\s*>\s*30/
            && $runner =~ /max_stdout_bytes/
            && $runner =~ /max_stderr_bytes/
            && $runner =~ /max_stdin_bytes/
            && $runner =~ /kill\s+'TERM'.*?kill\s+'KILL'/s) {
        pass("ScriptRunner validates argv/path and bounds time, stdin, stdout and stderr");
    }
    else {
        fail("ScriptRunner execution boundary is incomplete");
    }
}

# ===========================================================================
# 9. HTTP et transport IA provider-neutral
# ===========================================================================
say_info("\n[9] HTTP and provider-neutral AI boundaries");
{
    my $client = slurp('Mediabot/AI/Client.pm') // '';
    my $transport = slurp('Mediabot/AI/Transport.pm') // '';

    if ($client =~ /sub\s+_https_url\s*\{.*?https:/s
            && $client =~ /verify_SSL\s*=>\s*1/
            && $client =~ /max_size\s*=>\s*1024\s*\*\s*1024/) {
        pass("AI endpoints require HTTPS and the shared client verifies TLS with a 1 MiB cap");
    }
    else {
        fail("AI HTTPS/TLS/response-size boundary is incomplete");
    }

    if ($transport =~ /timeout must be a positive number/
            && $transport =~ /timeout\s*=>\s*0\s*\+\s*\$args\{timeout\}/
            && $transport =~ /verify_SSL\s*=>\s*1/) {
        pass("provider-neutral AI transport requires a positive timeout and verified TLS");
    }
    else {
        fail("provider-neutral AI transport timeout/TLS contract is incomplete");
    }

    if ($client =~ /never return raw HTTP\s*\n?\s*# bodies, request headers or credentials/s
            && $client =~ /for my \$key \(qw\(error_type error_code error_message\)\)/) {
        pass("AI failure envelopes expose only the bounded diagnostic tuple");
    }
    else {
        fail("AI failure envelope may expose raw provider material");
    }
}

# ===========================================================================
# 10. Isolation Hailo et fallback local déterministe
# ===========================================================================
say_info("\n[10] Hailo isolation and deterministic fallback");
{
    my $registry = slurp('Mediabot/Hailo/BrainRegistry.pm') // '';
    my $post = slurp('Mediabot/Hailo/PostEditor.pm') // '';
    my $runtime = slurp('Mediabot/Hailo/PostEditRuntime.pm') // '';

    if ($registry =~ /sha256_hex\(join\s+"\\x00",\s*\$self->\{network\},\s*\$key\)/
            && $registry =~ /Hailo brain path must not be a symbolic link/
            && $registry =~ /umask\s+0077/) {
        pass("Hailo brain identity is network/channel-scoped and private symlinks are refused");
    }
    else {
        fail("Hailo per-channel brain isolation contract is incomplete");
    }

    if ($post =~ /reason\s*=>\s*'provider_error'.*?line\s*=>\s*\$fallback/s
            && $post =~ /_preserves_anchor\(\$fallback,\s*\$edited\)/) {
        pass("Hailo provider failure preserves the local draft and edits preserve its anchor");
    }
    else {
        fail("Hailo deterministic fallback/anchor contract is incomplete");
    }

    if ($runtime =~ /disabled.*?runtime_inactive.*?irc_disconnected.*?not_joined.*?stale_generation/s
            && $runtime =~ /\{post_editor\}->submit\(/
            && $runtime !~ /\{post_editor\}->execute\(/) {
        pass("Hailo post-edit stays asynchronous and rechecks late authorization/runtime state");
    }
    else {
        fail("Hailo asynchronous late-authorization boundary is incomplete");
    }
}

# ===========================================================================
# 11. Observabilité agrégée et vie privée
# ===========================================================================
say_info("\n[11] Privacy-safe aggregate observability");
{
    my $metrics = slurp('Mediabot/Metrics.pm') // '';
    my $runtime = slurp('Mediabot/Hailo/PostEditRuntime.pm') // '';
    my $main = slurp('mediabot.pl') // '';
    my $core = slurp('Mediabot/Mediabot.pm') // '';

    if ($metrics =~ /bind\s*=>\s*\$args\{bind\}\s*\|\|\s*'127[.]0[.]0[.]1'/
            && $metrics =~ /MAX_HTTP_HEADER_BYTES\s*=>\s*16\s*\*\s*1024/
            && $metrics =~ /mediabot_hailo_post_edit_total'.*?\['result'\]/s) {
        pass("metrics default to loopback, bound request headers and aggregate Hailo results");
    }
    else {
        fail("metrics loopback/size/aggregate contract is incomplete");
    }

    my ($summary) = $runtime =~ /my\s+\$summary\s*=\s*\{(.*?)\n\s*\};/s;
    if (defined($summary)
            && $summary !~ /\b(?:trigger|candidate|line|context)\s*=>/
            && $main !~ /Hailo(?:Chatter)? channel candidate for .*\$sAnswer/
            && $core !~ /Hailo channel candidate for .*\$sAnswer/) {
        pass("Hailo summaries and logs exclude trigger, draft, edited line and context text");
    }
    else {
        fail("raw Hailo conversation content may cross observability boundary");
    }

    my $social = slurp('Mediabot/SocialHistory.pm') // '';
    my $social_code = $social;
    $social_code =~ s/^\s*#.*$//mg;
    if ($social_code !~ /(?:q|qq)\s*\{\s*(?:INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/is
            && $social_code !~ /\$dbh->(?:prepare|do)\(\s*["']\s*(?:INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/is) {
        pass("social-history remains a read-only data surface");
    }
    else {
        fail("social-history contains a write-SQL path");
    }
}

# ===========================================================================
# 12. Interfaces privilégiées fail-closed
# ===========================================================================
say_info("\n[12] Privileged interfaces fail closed");
{
    my $priv = slurp('Mediabot/Partyline/Privileged.pm') // '';
    my $owner_guards = () = $priv =~ /unless\s*\(defined\(\$level\)\s*&&\s*\$level\s*==\s*0\)/g;
    if ($owner_guards >= 2
            && $priv =~ /PARTYLINE_EVAL_ENABLED'\)\s*\}\s*\/\/\s*0/) {
        pass("Partyline eval/die remain Owner-only and eval defaults disabled");
    }
    else {
        fail("Partyline privileged command boundary is incomplete");
    }

    my $update = slurp('Mediabot/Update.pm') // '';
    if ($update =~ /return unless \$ctx->require_level\('Master'\)/
            && $update =~ /BUILTIN_PROTECTED.*?\/home\/mediabot\/mediabot_v3.*?teuk[.]org/s
            && $update =~ /update_eligibility\(.*?unless \(\$ok\)/s) {
        pass("updater requires Master and refuses the protected development installation");
    }
    else {
        fail("updater authorization/protected-installation boundary is incomplete");
    }

    my $fullop = slurp('Mediabot/Fullop.pm') // '';
    if ($fullop =~ /authorize_delegated_ban.*?return 0 unless \$self->enabled/s
            && $fullop =~ /_consume_delegated_ban.*?splice \@\$pending, \$idx, 1/s
            && $fullop =~ /refusing unmanaged IRC ban.*?return 0/s) {
        pass("Fullop delegation is enabled-only, one-shot and refuses unmanaged bans");
    }
    else {
        fail("Fullop delegated/durable sanction boundary is incomplete");
    }
}

# ===========================================================================
# 13. Identités systemd et chemins inscriptibles
# ===========================================================================
say_info("\n[13] systemd identities and writable paths");
{
    my $irc_unit = slurp('tools/systemd/mediabot@.service.example') // '';
    if ($irc_unit =~ /^User=mediabot$/m
            && $irc_unit =~ /^Group=mediabot$/m
            && $irc_unit =~ /^EnvironmentFile=\/etc\/default\/mediabot-%i$/m
            && $irc_unit !~ /^ReadWritePaths=/m) {
        pass("IRC systemd template uses the mediabot identity without added writable paths");
    }
    else {
        fail("IRC systemd identity/writable-path contract is incomplete");
    }

    my $web_unit = slurp('install/systemd/mbweb.service') // '';
    my @required = (
        'User=mediabot', 'Group=mediabot', 'UMask=0077',
        'NoNewPrivileges=true', 'ProtectSystem=strict',
        'ProtectHome=read-only', 'PrivateTmp=true',
        'ReadOnlyPaths=/opt/mbweb/app',
    );
    my @missing = grep { $web_unit !~ /^\Q$_\E$/m } @required;
    if (!@missing && $web_unit !~ /^ReadWritePaths=/m) {
        pass("mbweb systemd unit is sandboxed with no persistent writable path");
    }
    else {
        fail("mbweb systemd hardening contract is incomplete", join(', ', @missing));
    }
}

# ===========================================================================
# 14. Restauration et archives publiques
# ===========================================================================
say_info("\n[14] Restore and public archive boundaries");
{
    my $deploy = slurp('install/deploy_update.sh') // '';
    if ($deploy =~ /Archiving current release:.*?\$\{BACKUP_DIR\}/s
            && $deploy =~ /Attempting rollback.*?mv -v "\$\{BACKUP_DIR\}"\s+"\$\{PROJECT_DIR\}"/s
            && $deploy =~ /rollback completed successfully; previous release restored/) {
        pass("IRC updater keeps and restores the previous release on activation failure");
    }
    else {
        fail("IRC updater rollback contract is incomplete");
    }

    my $web = slurp('install/mbweb_deploy.sh') // '';
    if ($web =~ /deployment failed; restoring \$ACTIVE_BACKUP/
            && $web =~ /rsync -a --delete "\$candidate\/runtime\/" "\$APP_DIR\/"/
            && $web =~ /READY/
            && $web =~ /rollback failed: \$BACKUP/) {
        pass("mbweb deployment arms an exact private backup and bounded rollback");
    }
    else {
        fail("mbweb private backup/rollback contract is incomplete");
    }

    my $archive = slurp('tools/build_release_artifacts.sh') // '';
    if ($archive =~ /git archive --format=tar/
            && $archive =~ /commit\\[.]sh\$/
            && $archive =~ /mediabot\\[.]conf\$/
            && $archive =~ /node_modules/
            && $archive =~ /[.]log\(\$\|\\[.]\)/
            && $archive =~ /[.]pem\$/
            && $archive =~ /snap_mediabot/
            && $archive =~ /gzip -n -9/) {
        pass("release archives are commit-derived, deterministic and reject private/generated material");
    }
    else {
        fail("public release archive exclusion/determinism contract is incomplete");
    }
}

# ===========================================================================
# 15. Sessions et requêtes mbweb
# ===========================================================================
say_info("\n[15] mbweb session and request boundaries");
{
    my $app = slurp('contrib/mbweb/app.js') // '';
    my $config = slurp('contrib/mbweb/lib/configCore.js') // '';
    my $csrf = slurp('contrib/mbweb/lib/csrf.js') // '';
    my $metrics = slurp('contrib/mbweb/lib/metrics.js') // '';
    my $radio = slurp('contrib/mbweb/lib/radio.js') // '';

    if ($config =~ /Production requires MBWEB_SESSION_STORE=mysql; MemoryStore is forbidden[.]/
            && $app =~ /createMySqlSessionStore\(/
            && $app =~ /sessionStore[?][.]assertReady/) {
        pass("mbweb production sessions require the durable MySQL store before listen");
    }
    else {
        fail("mbweb durable production session boundary is incomplete");
    }

    if ($app =~ /express[.]urlencoded\(\{\s*extended:\s*false,\s*limit:\s*'32kb',\s*parameterLimit:\s*64\s*\}\)/
            && $app =~ /express[.]json\(\{\s*limit:\s*'32kb'\s*\}\)/
            && $app =~ /createCsrfProtection\(\)/
            && $csrf =~ /timingSafeEqual/) {
        pass("mbweb bounds request bodies and protects state changes with constant-time CSRF checks");
    }
    else {
        fail("mbweb request/CSRF boundary is incomplete");
    }

    if ($config =~ /Production MBWEB_HOST must be an explicit loopback address[.]/
            && $metrics =~ /new AbortController\(\)/
            && $metrics =~ /max:\s*30000/
            && $radio =~ /new AbortController\(\)/) {
        pass("mbweb production listener is loopback-only and upstream requests are timeout-bounded");
    }
    else {
        fail("mbweb loopback/upstream timeout boundary is incomplete");
    }
}

# ===========================================================================
# 16. Référence DB et diagnostic en lecture seule
# ===========================================================================
say_info("\n[16] Database reference and read-only diagnosis");
{
    my $doctor = slurp('tools/mediabot_doctor.pl') // '';
    if ($doctor =~ /SET SESSION TRANSACTION READ ONLY/
            && $doctor =~ /check_schema_drift[.]pl'.*?'--strict',\s*'--types',\s*'--indexes'/s
            && $doctor =~ /required live schema\/reference data match install\/mediabot[.]sql/) {
        pass("Doctor enforces a read-only session and delegates types/indexes to the schema reference checker");
    }
    else {
        fail("read-only database/reference diagnostic contract is incomplete");
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
