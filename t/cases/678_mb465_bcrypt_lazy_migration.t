# t/cases/678_mb465_bcrypt_lazy_migration.t
# =============================================================================
# mb465 — Migration bcrypt lazy (plan §2.5 de la direction 3.3 corrigée).
#
# Changements couverts :
#   B1. Helpers::make_password_hash émet du bcrypt ($2b$, coût 12) quand
#       Crypt::Bcrypt est présent ; fallback legacy '*'+SHA1(SHA1) sinon.
#       AUCUN changement de schéma (préfixe = identification d'algorithme).
#   B2. Auth::password_matches : wrapper public multi-format.
#   B3. verify_credentials : re-hash lazy vers bcrypt après un login réussi sur
#       un hash legacy (best-effort, n'échoue jamais le login).
#   B4. userPass : l'ancien mot de passe est vérifié via password_matches —
#       corrige le bug latent où un compte DÉJÀ en bcrypt ne pouvait plus
#       changer son mot de passe (égalité de re-hash impossible avec du salé).
#   B5. checkAuth : le fallback SQL-égalité reste sur le hash legacy
#       DÉTERMINISTE (il ne peut pas fonctionner avec du bcrypt salé).
#
# Le test s'adapte au runtime : sur teuk.org Crypt::Bcrypt est installé par
# MB466 ; dans une sandbox minimale il peut être absent. Les deux chemins sont
# contractuels et doivent rester déterministes.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Digest::SHA qw(sha1 sha1_hex);

sub _slurp_678 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # 1. Exécution réelle : Auth::password_matches (le module compile en sandbox)
    # -------------------------------------------------------------------------
    my $auth_ok = eval { require Mediabot::Auth; 1 };
    $assert->ok($auth_ok, 'Mediabot::Auth se charge');

    if ($auth_ok) {
        my $legacy = '*' . uc(sha1_hex(sha1('s3cret')));
        $assert->is(scalar(Mediabot::Auth::password_matches('s3cret', $legacy)), 1,
            'password_matches: legacy MySQL double-SHA1 accepté');
        $assert->is(scalar(Mediabot::Auth::password_matches('wrong', $legacy)), 0,
            'password_matches: mauvais mot de passe refusé');

        my $hex = sha1_hex(pack('H*', sha1_hex('s3cret')));
        $assert->is(scalar(Mediabot::Auth::password_matches('s3cret', $hex)), 1,
            'password_matches: variante hex sans étoile acceptée');

        $assert->is(scalar(Mediabot::Auth::password_matches('abc', 'abc')), 1,
            'password_matches: plaintext historique accepté');

        # mb473-B1: adapt the bcrypt reason assertion to the real runtime.
        # MB466 installs Crypt::Bcrypt on teuk.org, while the offline sandbox may
        # still lack it. Exercise a VALID bcrypt hash when the module exists so
        # the test checks a normal password mismatch rather than library-specific
        # behaviour for a deliberately malformed hash.
        my $have_bcrypt = eval { require Crypt::Bcrypt; 1 } ? 1 : 0;
        my $stored_bc = '$2b$12$' . ('a' x 53);
        if ($have_bcrypt) {
            $stored_bc = Crypt::Bcrypt::bcrypt(
                'correct-password', '2b', 4, '0123456789abcdef');
        }
        my ($ok_bc, $why_bc) =
            Mediabot::Auth::password_matches('wrong-password', $stored_bc);
        $assert->is($ok_bc, 0, 'hash bcrypt: mauvais mot de passe refusé proprement');
        $assert->is($why_bc, $have_bcrypt ? 'bcrypt' : 'bcrypt_not_available',
            'raison bcrypt adaptée à la disponibilité réelle du module');
    }

    # -------------------------------------------------------------------------
    # 2. Exécution réelle : make_password_hash — chemin fallback (sandbox)
    # -------------------------------------------------------------------------
    # On extrait le sub + son flag depuis Helpers.pm et on l'exécute isolément
    # (Helpers.pm complet ne compile pas en sandbox).
    my $hsrc = _slurp_678(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my ($flag)  = $hsrc =~ /(my \$HAVE_BCRYPT_H = eval \{ require Crypt::Bcrypt; 1 \} \? 1 : 0;)/;
    my ($salt)  = $hsrc =~ /(sub _bcrypt_salt16 \{.*?\n\}\n)/s;
    my ($mkpwd) = $hsrc =~ /(sub make_password_hash \{.*?\n\}\n)/s;
    $assert->ok(defined $flag && defined $salt && defined $mkpwd,
        'flag + _bcrypt_salt16 + make_password_hash extraits de Helpers.pm');

    my $code = eval "package T_mb465; use strict; use warnings;\n"
             . "use Digest::SHA qw(sha1 sha1_hex);\n"
             . "$flag\n$salt\n$mkpwd\n\\&T_mb465::make_password_hash;";
    $assert->ok(!$@ && $code, 'make_password_hash compilé isolément' . ($@ ? " ($@)" : ''));

    if ($code) {
        my $h = $code->('s3cret');
        $assert->ok(defined $h, 'make_password_hash renvoie un hash');
        if (eval { require Crypt::Bcrypt; 1 }) {
            $assert->like($h, qr/^\$2b\$12\$/, 'avec Crypt::Bcrypt: hash $2b$ coût 12');
            $assert->ok(Crypt::Bcrypt::bcrypt_check('s3cret', $h),
                'le hash bcrypt vérifie le mot de passe');
        } else {
            $assert->is($h, '*' . uc(sha1_hex(sha1('s3cret'))),
                'sans Crypt::Bcrypt: fallback legacy déterministe exact');
        }
        $assert->ok(!defined $code->(undef), 'undef -> undef');
        $assert->ok(!defined $code->(''),    'vide -> undef');
    }

    # -------------------------------------------------------------------------
    # 3. Câblages (scan de source)
    # -------------------------------------------------------------------------
    my $asrc = _slurp_678(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));
    $assert->like($asrc, qr/sub password_matches \{/,
        'Auth: wrapper public password_matches présent (mb465-B2)');
    my ($vc) = $asrc =~ /(sub verify_credentials \{.*?\n\}\n)/s; $vc //= '';
    # mb466-B2: la logique de re-hash est factorisée dans maybe_upgrade_hash ;
    # verify_credentials se contente de l'appeler après un login réussi.
    $assert->like($vc, qr/maybe_upgrade_hash\(/,
        'verify_credentials: délègue le re-hash lazy à maybe_upgrade_hash (mb466-B2)');
    $assert->like($vc, qr/if \(\$ok\) \{/,
        're-hash seulement après un login réussi');
    $assert->like($vc, qr/\$ok \? 1 : 0;\n\}/s,
        'le résultat du login reste inchangé par le re-hash (best-effort)');

    # Le helper factorisé porte désormais le contrat B3 (gating + UPDATE).
    my ($mu) = $asrc =~ /(sub maybe_upgrade_hash \{.*?\n\}\n)/s; $mu //= '';
    $assert->like($mu, qr/mb466-B2/, 'maybe_upgrade_hash: helper factorisé présent');
    $assert->like($mu, qr/\$why ne 'bcrypt'/,
        'maybe_upgrade_hash: re-hash seulement pour un hash NON-bcrypt');
    $assert->like($mu, qr/UPDATE USER SET password = \? WHERE id_user = \?/,
        'maybe_upgrade_hash: UPDATE paramétré du hash');

    my $lsrc = _slurp_678(File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm'));
    my ($up) = $lsrc =~ /(sub userPass \{.*?\n\}\n)/s; $up //= '';
    $assert->like($up, qr/Mediabot::Auth::password_matches\(\$old_password, \$stored_hash\)/,
        'userPass: ancien mot de passe vérifié multi-format (mb465-B4)');
    $assert->unlike($up, qr/\$stored_hash eq \$old_hash/,
        'userPass: l\'égalité de re-hash (cassée avec bcrypt) est supprimée');

    my ($cabu) = $lsrc =~ /(sub checkAuthByUser \{.*?\n\}\n)/s; $cabu //= '';
    $assert->like($cabu, qr/SELECT id_user, password FROM USER WHERE nickname = \?/,
        'checkAuthByUser: lit le hash stocké (mb465-B6)');
    $assert->like($cabu, qr/Mediabot::Auth::password_matches\(\$sPassword/,
        'checkAuthByUser: vérifie multi-format');
    $assert->unlike($cabu, qr/AND password = \?/,
        'checkAuthByUser: l\'égalité SQL (cassée avec bcrypt) est supprimée');

    my ($ca) = $lsrc =~ /(sub checkAuth \{.*?\n\}\n)/s; $ca //= '';
    $assert->like($ca, qr/mb465-B5/,
        'checkAuth: fallback legacy déterministe conservé et documenté');
    $assert->like($ca, qr/Digest::SHA::sha1_hex\(Digest::SHA::sha1\(/,
        'checkAuth: hash legacy calculé inline (indépendant de make_password_hash)');
};
