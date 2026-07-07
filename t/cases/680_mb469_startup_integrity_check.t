# t/cases/680_mb469_startup_integrity_check.t
# =============================================================================
# mb469 — Startup integrity check autonome (direction 3.3, Phase A / A3).
#
# tools/startup_integrity_check.pl doit détecter, AVANT connexion IRC, un arbre
# incohérent — pas seulement un mediabot.pl cassé (perl -c) mais les désyncs de
# RÉSOLUTION runtime que perl -c ne voit pas :
#   [1] un module core qui ne charge pas ;
#   [2] mediabot.pl appelant une méthode $mediabot->X absente des modules
#       (reproduit le crash Undernet du 04/07/2026, mb449) ;
#   [3] un handler de dispatch *_ctx référencé mais non défini (module en
#       retard) — un slot d'export vide ne doit PAS passer pour défini ;
#   [4] via manifest : un module orphelin (ancien .pm resté) ou un module
#       attendu manquant (déploiement partiel).
#
# Ce test ne relance pas le script en sous-processus (pas de dépendances
# runtime dans le conteneur) : il vérifie par SCAN DE SOURCE que le script
# implémente chaque garde et, surtout, qu'il teste `defined &{...}` et non un
# simple ->can pour les handlers (sinon faux négatif sur glob d'export vide).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_680 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $path = File::Spec->catfile('.', 'tools', 'startup_integrity_check.pl');
    $assert->ok(-f $path, 'tools/startup_integrity_check.pl présent');
    return unless -f $path;

    my $src = _slurp_680($path);

    # Le script doit compiler.
    my $compile = system("perl -c \"$path\" >/dev/null 2>&1");
    $assert->is($compile, 0, 'startup_integrity_check.pl : perl -c OK');

    # -------------------------------------------------------------------------
    # [1] Chargement de tout l'arbre
    # -------------------------------------------------------------------------
    $assert->like($src, qr/\[1\].*Loading all Mediabot modules/s,
        '[1] charge tout l\'arbre Mediabot/*.pm');
    $assert->like($src, qr/require \$mod/,
        '[1] require dynamique de chaque module');
    $assert->like($src, qr/Mediabot::Plugin::/,
        '[1] les Plugin::* sont traités comme optionnels');

    # -------------------------------------------------------------------------
    # [2] Méthodes appelées sur $mediabot (garde mb449 généralisé)
    # -------------------------------------------------------------------------
    $assert->like($src, qr/\[2\].*cross-module methods/s,
        '[2] résout les méthodes cross-module');
    $assert->like($src, qr/\$mediabot->\(\[a-zA-Z_\]/,
        '[2] scanne bien $mediabot->method(...)');
    # NE DOIT PAS scanner $self-> (objet IRC dans mediabot.pl => faux positifs).
    $assert->unlike($src, qr/\Q\$self->([a-zA-Z_]\E/,
        '[2] ne scanne PAS $self-> (évite les faux positifs IRC: write/change_nick)');
    $assert->like($src, qr/!Mediabot->can\(\$_\)/,
        '[2] vérifie la résolution via Mediabot->can (héritage OK pour les méthodes)');

    # -------------------------------------------------------------------------
    # [3] Handlers de dispatch — defined &{...}, pas ->can
    # -------------------------------------------------------------------------
    $assert->like($src, qr/\[3\].*dispatch handlers/s,
        '[3] résout les handlers de dispatch');
    $assert->like($src, qr/sub\\s\*\\\{\\s\*\(\[a-zA-Z_\]\[A-Za-z0-9_\]\*_ctx\)/,
        '[3] capte la forme sub { handler_ctx(...) }');
    $assert->like($src, qr/\\\\&\(\[a-zA-Z_\]/,
        '[3] capte la forme \\&handler');
    # Le point critique : defined &{...} et non ->can, sinon un glob d'export
    # vide (module en retard) passerait pour défini.
    $assert->like($src, qr/defined &\{"Mediabot::\$h"\}/,
        '[3] teste defined &{...} sur le package central (pas un ->can trompeur)');
    $assert->like($src, qr/defined &\{"\$\{mod\}::\$h"\}/,
        '[3] teste defined &{...} dans les modules chargés');

    # -------------------------------------------------------------------------
    # [4] Manifest : orphelins + modules manquants
    # -------------------------------------------------------------------------
    $assert->like($src, qr/\[4\].*Orphan/s,
        '[4] détection d\'orphelins via manifest');
    $assert->like($src, qr/orphan module\(s\) present but NOT in manifest/,
        '[4] signale les .pm orphelins (stale)');
    $assert->like($src, qr/expected module\(s\) MISSING from the deployed tree/,
        '[4] signale les modules attendus manquants');
    $assert->like($src, qr/--gen-manifest/,
        '[4] sait générer un manifest de référence');

    # -------------------------------------------------------------------------
    # Verdict : fail-closed, code retour non nul en cas d'erreur
    # -------------------------------------------------------------------------
    $assert->like($src, qr/Verdict: FAIL/, 'verdict FAIL explicite');
    $assert->like($src, qr/exit 1/, 'sort en erreur (exit 1) sur défaut');
    $assert->like($src, qr/Do NOT start\/deploy/,
        'message actionnable : ne pas démarrer/déployer un arbre incohérent');
};
