#!/usr/bin/perl
# =============================================================================
#  tools/startup_integrity_check.pl — Contrôle d'intégrité d'installation (A3)
# =============================================================================
#  Objectif (direction 3.3, Phase A / A3) : prouver, AVANT de laisser une
#  instance se connecter à IRC, que l'arbre déployé est COHÉRENT — pas un
#  mélange d'un mediabot.pl récent avec des Mediabot/*.pm en retard, ni un
#  module orphelin d'une ancienne version qui traîne à côté du nouveau code.
#
#  Contexte réel : le 04/07/2026, l'instance Undernet a crashé des heures après
#  le démarrage parce qu'un déploiement partiel avait laissé un mediabot.pl
#  appelant une méthode (hailo_record_activity) absente des modules installés.
#  `perl -c` ne détecte PAS ce genre de désync (résolution de méthode/handler
#  = runtime). Ce script comble ce trou et se veut réutilisable :
#     - au démarrage (le noyau du check mb449 est déjà dans mediabot.pl) ;
#     - et SURTOUT dans le déploiement, sur l'arbre STAGÉ, avant bascule.
#
#  Quatre vecteurs vérifiés :
#     [1] Compilation de TOUT l'arbre Mediabot/*.pm (pas juste mediabot.pl).
#     [2] Méthodes appelées sur $self/$mediabot depuis mediabot.pl résolues
#         par le package Mediabot (généralisation du garde mb449).
#     [3] Handlers de dispatch (*_ctx et \&refs) réellement définis après
#         chargement — un handler manquant = crash au 1er usage de la commande.
#     [4] Détection d'orphelins : si un MANIFEST de référence est fourni,
#         aucun .pm présent dans l'arbre ne doit être absent du manifest, et
#         aucun module attendu ne doit manquer.
#
#  Sortie : rapport lisible + code retour 0 (OK) / 1 (au moins un défaut).
#  Aucun effet de bord : ne se connecte à rien, ne modifie rien, n'exécute
#  aucun handler. Il se contente de CHARGER les modules et d'introspecter.
#
#  Usage :
#     perl tools/startup_integrity_check.pl [--root DIR] [--manifest FILE]
#                                           [--gen-manifest FILE] [--quiet]
#
#     --root DIR         Racine de l'arbre à vérifier (défaut: dossier parent
#                        de ce script, soit la racine du projet).
#     --manifest FILE    Liste de référence des modules attendus (un par ligne,
#                        ex. "Mediabot::UserCommands"). Active le vecteur [4].
#     --gen-manifest F   N'exécute AUCUN check : génère le manifest depuis
#                        l'arbre courant (à faire sur l'archive candidate) et
#                        sort. Sert de référence anti-orphelin pour A3/RC.
#     --quiet            N'affiche que les erreurs et le verdict final.
#
#  Intégration déploiement (esprit) : après avoir stagé le nouvel arbre et
#  restauré conf/brain, lancer ce script avec le manifest de l'archive
#  candidate ; ne basculer que s'il sort 0.
# =============================================================================

use strict;
use warnings;
use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long;

my $opt_root        = '';
my $opt_manifest    = '';
my $opt_gen         = '';
my $opt_quiet       = 0;

GetOptions(
    'root=s'         => \$opt_root,
    'manifest=s'     => \$opt_manifest,
    'gen-manifest=s' => \$opt_gen,
    'quiet'          => \$opt_quiet,
) or die "Invalid options.\n";

# Racine du projet : par défaut, le parent de tools/.
my $ROOT = $opt_root ne '' ? $opt_root : File::Spec->rel2abs("$RealBin/..");
$ROOT =~ s{/+$}{};

my $MED_DIR = "$ROOT/Mediabot";

sub say_info { print "$_[0]\n" unless $opt_quiet }
sub say_warn { print "$_[0]\n" }   # les avertissements/erreurs restent visibles

# ---------------------------------------------------------------------------
# Utilitaire : lister tous les .pm de l'arbre Mediabot en noms de packages.
#   Mediabot/UserCommands.pm      -> Mediabot::UserCommands
#   Mediabot/Radio/Request.pm     -> Mediabot::Radio::Request
# ---------------------------------------------------------------------------
sub list_tree_modules {
    my ($dir) = @_;
    my @mods;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (sort readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if (-d $p) { push @stack, $p; next }
            next unless $e =~ /\.pm$/;
            (my $rel = $p) =~ s{^\Q$ROOT\E/}{};
            $rel =~ s{\.pm$}{};
            $rel =~ s{/}{::}g;
            push @mods, $rel;
        }
        closedir $dh;
    }
    return sort @mods;
}

# ---------------------------------------------------------------------------
# Mode génération de manifest : on écrit la liste des modules et on sort.
# ---------------------------------------------------------------------------
if ($opt_gen ne '') {
    unless (-d $MED_DIR) {
        say_warn("FATAL: no Mediabot/ directory under $ROOT");
        exit 1;
    }
    my @mods = list_tree_modules($MED_DIR);
    open my $out, '>', $opt_gen or do {
        say_warn("FATAL: cannot write manifest $opt_gen: $!");
        exit 1;
    };
    print $out "# Mediabot module manifest — generated by startup_integrity_check.pl\n";
    print $out "# root: $ROOT\n";
    print $out "$_\n" for @mods;
    close $out;
    say_info("Manifest written: $opt_gen (" . scalar(@mods) . " modules)");
    exit 0;
}

# ---------------------------------------------------------------------------
# Préambule
# ---------------------------------------------------------------------------
say_info("=" x 70);
say_info("Mediabot startup integrity check (A3)");
say_info("  root : $ROOT");
say_info("=" x 70);

unless (-f "$ROOT/mediabot.pl") {
    say_warn("FATAL: $ROOT/mediabot.pl not found — wrong --root?");
    exit 1;
}
unless (-d $MED_DIR) {
    say_warn("FATAL: $MED_DIR not found — wrong --root?");
    exit 1;
}

# On charge l'arbre depuis $ROOT (et pas depuis un autre @INC).
unshift @INC, $ROOT;

my $errors = 0;    # défauts bloquants
my $warns  = 0;    # anomalies non bloquantes

# ---------------------------------------------------------------------------
# [1] Compilation/chargement de TOUT l'arbre Mediabot/*.pm
#     On require chaque module : un module cassé ou incohérent échoue ici.
#     Les modules Plugin::* sont optionnels (chargés dynamiquement) : un échec
#     y est un avertissement, pas un blocage.
# ---------------------------------------------------------------------------
say_info("\n[1] Loading all Mediabot modules ...");
my @all_mods = list_tree_modules($MED_DIR);
my %loaded;
for my $mod (@all_mods) {
    my $optional = ($mod =~ /^Mediabot::Plugin::/);
    my $ok = eval "require $mod; 1";
    if ($ok) {
        $loaded{$mod} = 1;
    }
    else {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+at .*//s;
        if ($optional) {
            say_warn("  [warn] optional module $mod failed to load: $err");
            $warns++;
        }
        else {
            say_warn("  [FAIL] core module $mod failed to load: $err");
            $errors++;
        }
    }
}
say_info("  loaded " . scalar(keys %loaded) . "/" . scalar(@all_mods) . " module(s)");

# Si le paquet central n'a pas pu charger, inutile d'aller plus loin.
unless ($loaded{'Mediabot::Mediabot'} || Mediabot->can('new')) {
    say_warn("\nFATAL: Mediabot core package did not load — aborting deeper checks.");
    say_warn("Verdict: FAIL ($errors error(s), $warns warning(s))");
    exit 1;
}

# ---------------------------------------------------------------------------
# [2] Méthodes appelées sur $self/$mediabot depuis mediabot.pl (garde mb449
#     généralisé) : elles doivent être fournies par le package Mediabot.
# ---------------------------------------------------------------------------
say_info("\n[2] Resolving cross-module methods called from mediabot.pl ...");
my %called;
if (open my $fh, '<', "$ROOT/mediabot.pl") {
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        # IMPORTANT : ne scanner que $mediabot->method(...). Dans mediabot.pl,
        # $self à l'intérieur des callbacks IRC désigne l'objet Net::Async::IRC
        # (write, change_nick, is_nick_me, ...) et PAS le bot Mediabot ; scanner
        # $self-> produirait de faux positifs. C'est le choix délibéré du garde
        # mb449 d'origine, qu'on conserve.
        $called{$1} = 1 while $line =~ /\$mediabot->([a-zA-Z_][A-Za-z0-9_]*)\(/g;
    }
    close $fh;
}
if (!keys %called) {
    say_warn("  [FAIL] no method calls found in mediabot.pl (unreadable/empty scan)");
    $errors++;
}
else {
    my @missing = grep { !Mediabot->can($_) } sort keys %called;
    if (@missing) {
        say_warn("  [FAIL] mediabot.pl calls method(s) not provided by installed modules:");
        say_warn("         " . join(', ', @missing));
        say_warn("         => Mediabot/*.pm tree is out of sync with mediabot.pl. Redeploy the FULL tree.");
        $errors++;
    }
    else {
        say_info("  " . scalar(keys %called) . " cross-module method(s) resolved OK");
    }
}

# ---------------------------------------------------------------------------
# [3] Handlers de dispatch : tous les *_ctx et \&refs référencés dans le code
#     doivent être définis après chargement. Un handler manquant ne casse pas
#     le démarrage mais explose au 1er usage de la commande correspondante.
# ---------------------------------------------------------------------------
say_info("\n[3] Resolving dispatch handlers (*_ctx and \\&refs) ...");
my %handlers;
# On scanne le dispatcher principal + les modules de commandes, là où les
# tables de dispatch vivent.
my @dispatch_sources = (
    "$ROOT/Mediabot/Mediabot.pm",
    "$ROOT/Mediabot/Partyline.pm",
);
for my $src (@dispatch_sources) {
    next unless -f $src;
    open my $fh, '<', $src or next;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        # Formes : "=> \&handler_ctx", "sub { handler_ctx(", "=> \&handler"
        $handlers{$1} = 1 while $line =~ /\\&([a-zA-Z_][A-Za-z0-9_]*)/g;
        $handlers{$1} = 1 while $line =~ /\bsub\s*\{\s*([a-zA-Z_][A-Za-z0-9_]*_ctx)\s*\(/g;
    }
    close $fh;
}
if (!keys %handlers) {
    say_warn("  [warn] no dispatch handlers detected (dispatch table shape changed?)");
    $warns++;
}
else {
    # Un handler est résolu s'il est défini dans le package Mediabot (les _ctx
    # importés y vivent) OU dans son module d'origine déjà chargé.
    # Un handler est résolu s'il est RÉELLEMENT défini (slot CODE non vide),
    # soit dans le package Mediabot (les _ctx importés y vivent), soit dans un
    # module chargé. On teste defined &{...} et PAS seulement ->can : Exporter
    # crée un glob à l'import même si le sub source a été supprimé (module en
    # retard), et ->can renverrait alors un faux positif sur un slot vide.
    my @unresolved;
    for my $h (sort keys %handlers) {
        no strict 'refs';
        my $found = 0;
        # package central
        $found = 1 if defined &{"Mediabot::$h"};
        # sinon, n'importe quel module chargé
        unless ($found) {
            for my $mod (keys %loaded) {
                if (defined &{"${mod}::$h"}) { $found = 1; last }
            }
        }
        push @unresolved, $h unless $found;
    }
    if (@unresolved) {
        say_warn("  [FAIL] dispatch handler(s) referenced but not defined after load:");
        say_warn("         " . join(', ', @unresolved));
        say_warn("         => a command would crash on first use. Redeploy the FULL tree.");
        $errors++;
    }
    else {
        say_info("  " . scalar(keys %handlers) . " dispatch handler(s) resolved OK");
    }
}

# ---------------------------------------------------------------------------
# [4] Détection d'orphelins via manifest de référence (optionnel mais
#     recommandé pour A3/RC). Le manifest est généré depuis l'archive
#     candidate propre ; on compare l'arbre déployé à cette référence.
# ---------------------------------------------------------------------------
if ($opt_manifest ne '') {
    say_info("\n[4] Orphan/mismatch detection against manifest ...");
    if (!-f $opt_manifest) {
        say_warn("  [FAIL] manifest not found: $opt_manifest");
        $errors++;
    }
    else {
        my %expected;
        open my $mf, '<', $opt_manifest or do {
            say_warn("  [FAIL] cannot read manifest: $!"); $errors++;
        };
        if ($mf) {
            while (my $l = <$mf>) {
                chomp $l; $l =~ s/^\s+|\s+$//g;
                next if $l eq '' || $l =~ /^#/;
                $expected{$l} = 1;
            }
            close $mf;

            my %present = map { $_ => 1 } @all_mods;

            my @orphans = grep { !$expected{$_} } sort keys %present;
            my @missing = grep { !$present{$_} }  sort keys %expected;

            if (@orphans) {
                say_warn("  [FAIL] orphan module(s) present but NOT in manifest (stale files?):");
                say_warn("         " . join(', ', @orphans));
                say_warn("         => remove leftover .pm from a previous version, or redeploy clean.");
                $errors++;
            }
            if (@missing) {
                say_warn("  [FAIL] expected module(s) MISSING from the deployed tree:");
                say_warn("         " . join(', ', @missing));
                say_warn("         => partial deployment. Redeploy the FULL tree.");
                $errors++;
            }
            if (!@orphans && !@missing) {
                say_info("  tree matches manifest exactly (" . scalar(keys %expected) . " modules)");
            }
        }
    }
}
else {
    say_info("\n[4] Orphan detection skipped (no --manifest provided).");
    say_info("    Tip: generate one from the candidate archive with --gen-manifest,");
    say_info("    then pass it here to catch stale/leftover modules.");
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
say_info("\n" . "=" x 70);
if ($errors) {
    say_warn("Verdict: FAIL — $errors error(s), $warns warning(s).");
    say_warn("Do NOT start/deploy this tree until the mismatch is fixed.");
    exit 1;
}
else {
    say_info("Verdict: OK — installation is internally consistent"
             . ($warns ? " ($warns warning(s))" : "") . ".");
    exit 0;
}
