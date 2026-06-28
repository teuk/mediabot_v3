# t/cases/562_mb343_partyline_bruteforce_per_ip.t
# =============================================================================
# mb343 — Anti-brute-force du login partyline PAR IP.
#
# login_failures est porté par connexion (fd) : se reconnecter remet le compteur
# à zéro, annulant la protection. mb343 ajoute un suivi par IP distante (peer_ip,
# fiable IPv4+IPv6 depuis mb340) qui persiste à travers les reconnexions, dans
# une fenêtre temporelle, clé sur l'IP (jamais le login -> pas de lockout-DoS).
#
# Ce test exécute les VRAIS helpers (extraits du source) et vérifie le câblage
# dans _do_login (check de blocage + record sur les 3 chemins d'échec + clear au
# succès).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_562 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_562(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));

    # Compile les vrais helpers dans un package de test.
    for my $n (qw(_pl_bf_blocked _pl_bf_record _pl_bf_clear)) {
        my ($s) = $src =~ /(sub \Q$n\E \{.*?\n\})/s;
        $assert->ok(defined($s) && $s ne '', "$n extrait du source");
        my $ok = eval "package T562::BF; $s 1";
        $assert->ok($ok, "$n compilé en isolation");
    }

    my $max = 15;
    my $win = 600;
    my $now = 1_000_000;

    # --- Comportement -----------------------------------------------------
    my %map;
    T562::BF::_pl_bf_record(\%map, '203.0.113.7', $now, $win) for 1 .. 14;
    $assert->is(T562::BF::_pl_bf_blocked(\%map, '203.0.113.7', $now, $max, $win), 0,
                '14 échecs : pas encore bloqué');

    T562::BF::_pl_bf_record(\%map, '203.0.113.7', $now, $win);
    $assert->is(T562::BF::_pl_bf_blocked(\%map, '203.0.113.7', $now, $max, $win), 1,
                '15 échecs : bloqué');

    $assert->is(T562::BF::_pl_bf_blocked(\%map, '203.0.113.7', $now + $win + 1, $max, $win), 0,
                'fenêtre expirée : débloqué');

    $assert->is(T562::BF::_pl_bf_blocked(\%map, '198.51.100.9', $now, $max, $win), 0,
                'autre IP : non affectée (pas de lockout collatéral)');

    T562::BF::_pl_bf_clear(\%map, '203.0.113.7');
    $assert->is(T562::BF::_pl_bf_blocked(\%map, '203.0.113.7', $now, $max, $win), 0,
                'clear (succès) : compteur remis à zéro');

    # IPv6 fonctionne comme clé
    T562::BF::_pl_bf_record(\%map, '2001:db8::1', $now, $win) for 1 .. 15;
    $assert->is(T562::BF::_pl_bf_blocked(\%map, '2001:db8::1', $now, $max, $win), 1,
                'clé IPv6 supportée');

    # IP vide / unknown ignorée (pas de bucket partagé -> pas de lockout global)
    my %m2;
    T562::BF::_pl_bf_record(\%m2, '', $now, $win) for 1 .. 50;
    $assert->is(scalar(keys %m2), 0, 'IP vide : non suivie (pas de bucket partagé)');
    $assert->is(T562::BF::_pl_bf_blocked(\%m2, '', $now, $max, $win), 0, 'IP vide : jamais bloquée');

    # --- Câblage dans _do_login ------------------------------------------
    my ($login) = $src =~ /(sub _do_login \{.*?\n\})/s;
    $login //= '';
    $assert->ok($login ne '', '_do_login extrait');
    $assert->like($login, qr/_pl_bf_blocked\(\$bf_map/, '_do_login: check de blocage par IP');
    $assert->like($login, qr/peer_ip.*\n.*unknown|\$bf_ip = '' if \$bf_ip eq 'unknown'/s,
                  '_do_login: repli si IP unknown');
    my $records = () = $login =~ /_pl_bf_record\(\$bf_map/g;
    $assert->is($records, 3, '_do_login: record sur les 3 chemins d\'échec');
    $assert->like($login, qr/_pl_bf_clear\(\$bf_map/, '_do_login: clear au succès');
    $assert->like($login, qr/mb343-B1/, 'tag mb343-B1 présent');
};
