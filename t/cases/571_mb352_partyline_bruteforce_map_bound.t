# t/cases/571_mb352_partyline_bruteforce_map_bound.t
# =============================================================================
# mb352 — La map anti-brute-force Partyline doit être réellement bornée.
#
# mb343 annonçait une limite de 1024 IP, mais au-delà de ce seuil il ne
# supprimait que les entrées expirées. Plus de 1024 IP encore actives pouvaient
# donc faire croître la map sans borne. mb352 purge les expirées puis évince les
# plus anciennes entrées actives, en conservant toujours l'IP courante.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_571 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_571(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my ($record) = $src =~ /(sub _pl_bf_record \{.*?\n\})/s;
    $record //= '';

    $assert->ok($record ne '', '_pl_bf_record extrait du source');
    my $compiled = eval "package T571::BF; $record 1";
    $assert->ok($compiled, '_pl_bf_record compile en isolation');

    my $window = 100_000;
    my $limit  = 32;
    my %map;

    for my $i (1 .. 80) {
        T571::BF::_pl_bf_record(\%map, sprintf('ip-%03d', $i), 10_000 + $i,
                                $window, $limit);
    }

    $assert->is(scalar(keys %map), $limit,
                'la map respecte exactement la limite avec des entrées toutes actives');
    $assert->ok(exists $map{'ip-080'}, 'le bucket courant est toujours conservé');
    $assert->ok(!exists $map{'ip-001'}, 'la plus ancienne entrée active est évincée');
    $assert->ok(!exists $map{'ip-048'}, 'les entrées au-delà de la fenêtre conservée sont évincées');
    $assert->ok(exists $map{'ip-049'}, 'la première entrée encore dans la borne est conservée');

    # Une entrée expirée doit partir avant une entrée active, sans consommer de
    # place dans la borne.
    my %expiry = (
        stale  => { count => 9, first_ts => 1 },
        active => { count => 1, first_ts => 9_950 },
    );
    T571::BF::_pl_bf_record(\%expiry, 'current', 10_000, 100, 2);
    $assert->ok(!exists $expiry{stale}, 'entrée expirée supprimée en priorité');
    $assert->ok(exists $expiry{active}, 'entrée active préexistante conservée');
    $assert->ok(exists $expiry{current}, 'entrée courante conservée après la purge');
    $assert->is(scalar(keys %expiry), 2, 'borne respectée après purge des expirées');

    # Compatibilité : un appelant historique sans 5e argument garde la limite
    # par défaut de 1024.
    my %compat;
    T571::BF::_pl_bf_record(\%compat, "compat-$_", 20_000 + $_, 100_000)
        for 1 .. 1030;
    $assert->is(scalar(keys %compat), 1024,
                'ancien appel à 4 arguments utilise la borne par défaut 1024');
    $assert->ok(exists $compat{'compat-1030'}, 'compatibilité : IP courante conservée');

    # Entrée corrompue : le helper doit la nettoyer au lieu de mourir sur une
    # déréférence de scalaire.
    my %bad = (broken => 'not-a-hash');
    my $ok = eval {
        T571::BF::_pl_bf_record(\%bad, 'good', 30_000, 600, 4);
        1;
    };
    $assert->ok($ok, 'entrée mal formée nettoyée sans exception');
    $assert->ok(!exists $bad{broken}, 'entrée mal formée supprimée');

    $assert->like($record, qr/\$max_entries\s*=\s*1024/,
                  'borne par défaut explicite dans le helper');
    $assert->like($record, qr/while \(keys\(%\$map\) > \$max_entries/,
                  'éviction active jusqu’au respect réel de la borne');
    $assert->like($record, qr/grep \{ \$_ ne \$ip \}/,
                  'l’IP courante est exclue des candidats à l’éviction');

    my ($login) = $src =~ /(sub _do_login \{.*?\n\})/s;
    $login //= '';
    $assert->like($login, qr/PARTYLINE_LOGIN_IP_MAX_ENTRIES/,
                  '_do_login lit explicitement la borne configurée');
    my $wired = () = $login =~ /_pl_bf_record\(\$bf_map, \$bf_ip, \$bf_now, \$bf_window, \$bf_entries\)/g;
    $assert->is($wired, 3, '_do_login passe la borne sur les trois chemins d’échec');
    $assert->like($src, qr/mb352-B1/, 'tag mb352-B1 présent');
};
