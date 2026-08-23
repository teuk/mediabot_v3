# t/cases/820_mb640_version_check_never_silent.t
# =============================================================================
# mb640 — le check de version ne peut plus echouer EN SILENCE.
#
# TERRAIN (#teuk, 2 fois de suite) :
#     local: 3.4dev-20260814_134746  |  github: Undefined
#     Cannot check: version could not be determined (local or GitHub)
# Aucune raison, alors que mb638/mb639 etaient censes en fournir une.
#
# DEUX defauts, tous deux de MOI :
#
#  (A) mb637 forgeait un client HTTP a part et divergeait de la politique
#      commune. MB696 a depuis revalide la chaine CA/TLS sur le serveur reel :
#      _make_http est maintenant verify_SSL=1 par defaut. Le contrat important
#      reste une seule politique HTTP commune, secure-by-default.
#
#  (B) Plus grave : une EXCEPTION de getVersion etait avalee par un eval nu.
#      Le fils n'ecrivait alors rien, le parent retombait sur le local EN
#      CACHE, et aucune raison n'existait. Bon local + « Undefined » + zero
#      explication : la capture, mot pour mot. Une panne reseau et un crash
#      du code produisaient le meme ecran.
#
#   [1] le fetch utilise le client COMMUN (politique TLS unique du bot).
#   [2] une exception devient une RAISON, sur les deux chemins (fork et
#       compatibilite sans event loop).
#   [3] un fils muet produit lui aussi une raison.
#   [4] le message est nettoye (pas de « at ... line N ») et borne.
#   [5] le chemin nominal reste sans raison : on n'invente pas d'alarme.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{ package ConfW; sub new { bless {}, shift } sub get { undef } }
{ package LogW;  sub new { bless {}, shift } sub log { 1 } }

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Helpers.pm'
        or die $!; local $/; <$fh> };

    # [1] un seul client HTTP pour tout le bot
    my ($fetch) = $src =~ /(sub fetch_remote_version \{.*?\n\})/s;
    $assert->ok(defined $fetch, 'mb640-820: fetch_remote_version localisee');
    $assert->like($fetch, qr/Mediabot::External::_make_http\(/,
        'mb640-820: le fetch passe par le client COMMUN du bot');
    # On regarde le CODE, pas les commentaires (qui citent volontairement la
    # regle qu'on a enfreinte).
    my $fetch_code = $fetch;
    $fetch_code =~ s/^\s*#.*$//mg;
    $assert->ok($fetch_code !~ /verify_SSL\s*=>\s*0/,
        'mb640-820: le fetch ne desactive jamais la verification TLS');
    $assert->ok($fetch_code !~ /HTTP::Tiny->new\(/,
        'mb640-820: ... et plus aucun client HTTP forge a part');
    my $ext = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/External.pm'
        or die $!; local $/; <$fh> };
    $assert->like($ext, qr/exists\s+\$opts\{verify_SSL\}.*?:\s*1\s*;/s,
        'mb640-820: ... politique commune verify_SSL=1 par defaut');

    # [2] une exception devient une raison — sur les DEUX chemins
    my $crashes = () = $src =~ /'version check crashed: '/g;
    $assert->is($crashes, 2,
        'mb640-820: le crash est capture sur le chemin fork ET le chemin sans loop');

    {
        no warnings 'redefine';
        my $boom = sub { die "kaboom in getVersion at Mediabot/Helpers.pm line 42.\n" };
        local *Mediabot::Helpers::getVersion = $boom;
        my $bot = bless { conf => ConfW->new, logger => LogW->new,
                          main_prog_version => '3.4dev-20260101_000000' }, 'Mediabot';
        my @got;
        Mediabot::Helpers::getVersion_async($bot, sub { @got = @_ });
        $assert->is($got[0], '3.4dev-20260101_000000',
            'mb640-820: le local en cache est conserve');
        $assert->is($got[1], 'Undefined', 'mb640-820: le distant reste Undefined');
        $assert->ok(defined $got[2] && length $got[2],
            'mb640-820: ... mais une RAISON accompagne desormais l echec');
        $assert->like($got[2], qr/version check crashed/,
            'mb640-820: ... et elle dit qu il s agit d un plantage, pas du reseau');
        $assert->like($got[2], qr/kaboom/,
            'mb640-820: ... en citant le message d origine');

        # [4] propre et borne
        $assert->ok($got[2] !~ /line \d+/,
            'mb640-820: le « at ... line N » est retire (illisible sur IRC)');
        $assert->ok($got[2] !~ /\n/, 'mb640-820: une seule ligne');
        $assert->ok(length($got[2]) <= 200, 'mb640-820: message borne');

        # un pave d exception ne doit pas partir en entier sur le canal
        local *Mediabot::Helpers::getVersion = sub { die 'X' x 900 };
        my @big;
        Mediabot::Helpers::getVersion_async($bot, sub { @big = @_ });
        $assert->ok(length($big[2]) <= 200,
            'mb640-820: une exception geante reste bornee');
    }

    # [3] fils muet : une raison quand meme.
    # mb641 porte maintenant les details structurels des sorties terminales
    # dans le test 821. Ici, le contrat historique mb640 reste volontairement
    # simple : un resultat vide ou illisible doit toujours avoir une raison.
    $assert->like($src, qr/version check worker produced no result/,
        'mb640-820: un fils sans resultat produit une raison');
    $assert->like($src, qr/worker_empty/,
        'mb652-820: worker_empty est traduit explicitement');
    $assert->like($src, qr/worker_decode/,
        'mb652-820: worker_decode est traduit explicitement');

    # [5] chemin nominal : aucune alarme inventee
    {
        no warnings 'redefine';
        local *Mediabot::Helpers::getVersion = sub {
            $_[0]{_version_fetch_error} = undef;
            return ('3.4dev-20260101_000000', '3.4dev-20260814_134746');
        };
        my $bot = bless { conf => ConfW->new, logger => LogW->new }, 'Mediabot';
        my @ok;
        Mediabot::Helpers::getVersion_async($bot, sub { @ok = @_ });
        $assert->is($ok[1], '3.4dev-20260814_134746',
            'mb640-820: le distant remonte quand tout va bien');
        $assert->ok(!defined $ok[2],
            'mb640-820: ... et AUCUNE raison n est inventee');
    }

    # la raison vierge a chaque check (acquis mb639, verifie ici aussi)
    $assert->like($src, qr/\$self->\{_version_fetch_error\} = undef if ref\(\$self\);/,
        'mb640-820: chaque check repart d une raison vierge');
};
