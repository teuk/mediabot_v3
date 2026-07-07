# t/cases/679_mb466_bcrypt_installer_and_ident_upgrade.t
# =============================================================================
# mb466 — Complétion de la migration bcrypt lazy (plan §2.5, direction 3.3).
#
# Deux défauts corrigés au-dessus de mb465 :
#   B1. install/cpan_install.sh n'installait PAS Crypt::Bcrypt. Sur une fresh
#       install (jalon RC B1), le module manquait, $HAVE_BCRYPT valait 0, et
#       TOUS les nouveaux mots de passe retombaient silencieusement en
#       double-SHA1 — mb465 devenait inerte là où on veut le tester.
#   B2. Le chemin `ident` (checkAuthByUser) vérifiait en multi-format (mb465-B6)
#       mais ne migrait JAMAIS les hashes legacy, contrairement au chemin
#       `login` (verify_credentials). La logique de re-hash est désormais
#       factorisée dans Auth::maybe_upgrade_hash() et appelée par les DEUX
#       chemins.
#
# La sandbox n'a pas Crypt::Bcrypt : on exécute donc réellement le contrat de
# gating de maybe_upgrade_hash (qui court-circuite proprement sans le module et
# sans DB), et on vérifie le câblage par scan de source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_679 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # MB466-B1 — Crypt::Bcrypt est dans le programme d'installation CPAN
    # -------------------------------------------------------------------------
    my $inst = _slurp_679(File::Spec->catfile('.', 'install', 'cpan_install.sh'));

    # Le module doit figurer dans le tableau PERL_MODULES (entrée entre guillemets).
    $assert->like($inst, qr/"Crypt::Bcrypt"/,
        'cpan_install.sh: Crypt::Bcrypt présent dans PERL_MODULES (mb466-B1)');

    # Garde-fou : il doit être DANS le tableau PERL_MODULES, pas ailleurs.
    my ($modules_block) = $inst =~ /PERL_MODULES=\((.*?)\)/s;
    $modules_block //= '';
    $assert->like($modules_block, qr/"Crypt::Bcrypt"/,
        'cpan_install.sh: l\'entrée est bien dans le tableau PERL_MODULES');

    # -------------------------------------------------------------------------
    # MB466-B2 — maybe_upgrade_hash existe et respecte son contrat de gating
    # -------------------------------------------------------------------------
    my $auth_ok = eval { require Mediabot::Auth; 1 };
    $assert->ok($auth_ok, 'Mediabot::Auth se charge');

    if ($auth_ok) {
        $assert->ok(Mediabot::Auth->can('maybe_upgrade_hash'),
            'Auth::maybe_upgrade_hash défini (helper partagé mb466-B2)');

        # Objet Auth minimal : pas de dbh -> l'upgrade doit court-circuiter à 0
        # sans jamais toucher la base ni mourir.
        my $auth = bless { logger => undef, dbh => undef }, 'Mediabot::Auth';

        # Sans Crypt::Bcrypt (sandbox) OU sans dbh : retour 0, pas d'exception.
        my $r1 = eval { $auth->maybe_upgrade_hash(42, 's3cret', 'mysql_password_hash', 'bob') };
        $assert->ok(!$@, 'maybe_upgrade_hash ne meurt jamais (best-effort)' . ($@ ? " ($@)" : ''));
        $assert->is($r1, 0, 'sans dbh/bcrypt: aucun upgrade, retour 0');

        # $why == 'bcrypt' : rien à upgrader, court-circuit immédiat (retour 0)
        # même si un jour un dbh est présent — on teste la garde en amont.
        my $r2 = eval { $auth->maybe_upgrade_hash(42, 's3cret', 'bcrypt', 'bob') };
        $assert->is($r2, 0, 'why=bcrypt: pas de re-hash inutile (retour 0)');

        # $why undef : garde défensive, pas d'exception.
        my $r3 = eval { $auth->maybe_upgrade_hash(42, 's3cret', undef, 'bob') };
        $assert->ok(!$@, 'why undef: pas d\'exception');
        $assert->is($r3, 0, 'why undef: retour 0');
    }

    # -------------------------------------------------------------------------
    # MB466-B2 — câblage : les DEUX chemins appellent le helper partagé
    # -------------------------------------------------------------------------
    my $asrc = _slurp_679(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));

    my ($mu) = $asrc =~ /(sub maybe_upgrade_hash \{.*?\n\}\n)/s; $mu //= '';
    $assert->like($mu, qr/\$HAVE_BCRYPT/,
        'maybe_upgrade_hash: gated sur la disponibilité de Crypt::Bcrypt');
    $assert->like($mu, qr/\$why ne 'bcrypt'/,
        'maybe_upgrade_hash: ne re-hash que les hashes NON-bcrypt');
    $assert->like($mu, qr/UPDATE USER SET password = \? WHERE id_user = \?/,
        'maybe_upgrade_hash: UPDATE paramétré (aucun changement de schéma)');
    $assert->like($mu, qr/eval \{/,
        'maybe_upgrade_hash: best-effort sous eval');

    # Chemin `login` : verify_credentials délègue.
    my ($vc) = $asrc =~ /(sub verify_credentials \{.*?\n\}\n)/s; $vc //= '';
    $assert->like($vc, qr/maybe_upgrade_hash\(/,
        'verify_credentials (login): appelle maybe_upgrade_hash');
    # Le login ne doit jamais être altéré par l'upgrade.
    $assert->like($vc, qr/\$ok \? 1 : 0;\n\}/s,
        'verify_credentials: le résultat du login reste best-effort-safe');

    # Chemin `ident` : checkAuthByUser délègue aussi (nouveauté mb466).
    my $lsrc = _slurp_679(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my ($cabu) = $lsrc =~ /(sub checkAuthByUser \{.*?\n\}\n)/s; $cabu //= '';
    $assert->like($cabu, qr/mb466-B2/,
        'checkAuthByUser: chemin ident documenté mb466-B2');
    $assert->like($cabu, qr/maybe_upgrade_hash\(/,
        'checkAuthByUser (ident): appelle maybe_upgrade_hash');
    # Il faut le $why du matcher pour gater : la capture doit être en liste.
    $assert->like($cabu, qr/my \(\$pw_ok, \$pw_why\) = eval \{ Mediabot::Auth::password_matches\(/,
        'checkAuthByUser: capture ($pw_ok,$pw_why) pour gater l\'upgrade');
    # L'upgrade ne doit se faire qu'APRÈS le contrôle de succès.
    $assert->like($cabu, qr/return \(0, 0\) unless \$pw_ok;.*?maybe_upgrade_hash\(/s,
        'checkAuthByUser: upgrade seulement après un ident réussi');
    # Best-effort : appel sous eval, ne casse pas l'ident.
    $assert->like($cabu, qr/eval \{ \$self->\{auth\}->maybe_upgrade_hash\(/,
        'checkAuthByUser: upgrade best-effort sous eval');
};
