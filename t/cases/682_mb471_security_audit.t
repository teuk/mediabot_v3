# t/cases/682_mb471_security_audit.t
# =============================================================================
# mb471 — Revue de sécurité finale (Phase B / B3, RC 3.3).
#
# tools/security_audit.pl vérifie, en lecture de source, 7 invariants de
# sécurité tenus par le code, et sort en NO-GO si l'un régresse.
#
# Ce test :
#   [A] exécute réellement l'audit sur l'arbre courant : il doit sortir GO
#       (exit 0) — l'arbre sain respecte tous ses invariants ;
#   [B] vérifie par scan que l'audit couvre bien les 7 axes de la liste B3 et
#       qu'il est fail-closed (NO-GO + exit 1 en cas de défaut).
#
# La matrice de détection (secret loggé, flock non exclusif, throttle retiré,
# TLS verify_SSL=0, guard yt-dlp '--' retiré) a été validée hors-ligne en
# fabriquant des arbres cassés ; ici on garde surtout l'invariant « l'arbre
# réel reste GO » pour attraper toute régression future du code lui-même.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_682 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $path = File::Spec->catfile('.', 'tools', 'security_audit.pl');
    $assert->ok(-f $path, 'tools/security_audit.pl présent');
    return unless -f $path;

    # Compile.
    my $compile = system("perl -c \"$path\" >/dev/null 2>&1");
    $assert->is($compile, 0, 'security_audit.pl : perl -c OK');

    # -------------------------------------------------------------------------
    # [A] Exécution réelle : l'arbre courant doit être GO.
    #     (L'audit ne lit que la source, aucune dépendance runtime requise.)
    # -------------------------------------------------------------------------
    my $out = `perl "$path" --quiet 2>&1`;
    my $rc  = $? >> 8;
    $assert->is($rc, 0, '[A] audit GO sur l\'arbre courant (exit 0)');
    $assert->like($out, qr/Verdict: GO/, '[A] verdict GO explicite');
    $assert->unlike($out, qr/\[FAIL\]/, '[A] aucun invariant en échec');

    # -------------------------------------------------------------------------
    # [B] Couverture des 7 axes + fail-closed (scan de source).
    # -------------------------------------------------------------------------
    my $src = _slurp_682($path);

    $assert->like($src, qr/\[1\] Secrets never logged/,        '[B] axe 1 secrets loggés');
    $assert->like($src, qr/\[2\] TLS verification/,            '[B] axe 2 TLS API authentifiées');
    $assert->like($src, qr/\[3\] External commands/,           '[B] axe 3 commandes externes');
    $assert->like($src, qr/\[4\] CR\/LF\/NUL/,                 '[B] axe 4 sanitisation CR/LF/NUL');
    $assert->like($src, qr/\[5\] Process lock/,                '[B] axe 5 verrou de process');
    $assert->like($src, qr/\[6\] HTTP download caps/,          '[B] axe 6 limites HTTP');
    $assert->like($src, qr/\[7\] Authentication throttling/,   '[B] axe 7 throttle auth');

    # Invariants clés testés explicitement.
    $assert->like($src, qr/verify_SSL\s*=>\s*1/,
        '[B] contrôle TLS exige verify_SSL => 1 sur API authentifiées');
    $assert->like($src, qr/exec.{1,6}\\\@cmd/,
        '[B] contrôle yt-dlp exec LIST');
    $assert->like($src, qr/'--'\s*,\s*\\\$query|push.*'--'/,
        '[B] contrôle guard yt-dlp \'--\'');
    $assert->like($src, qr/LOCK_EX.{1,10}LOCK_NB/,
        '[B] contrôle flock exclusif non bloquant');

    # Fail-closed.
    $assert->like($src, qr/Verdict: NO-GO/, '[B] verdict NO-GO sur défaut');
    $assert->like($src, qr/exit 1/,          '[B] sort en erreur (exit 1) sur défaut');
    $assert->like($src, qr/--warn-only/,     '[B] mode --warn-only disponible');
};
