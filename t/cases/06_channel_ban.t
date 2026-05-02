# t/cases/06_channel_ban.t
# =============================================================================
#  Tests unitaires de Mediabot::ChannelBan
#  - parse_duration : tous les formats, cas limites, erreurs
#  - parse_ban_level : niveaux valides, refus, minimum
#  - validate_mask : masques valides, trop larges, malformés
#  - normalize_mask : normalisation user@host → *!user@host
#  - mask_from_hostmask : extraction depuis nick!user@host
#  - looks_like_duration / looks_like_level
# =============================================================================

use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}
use Mediabot::ChannelBan;
use Mediabot::Log;

return sub {
    my ($assert) = @_;

    my $logger = Mediabot::Log->new(debug_level => -1);
    # ChannelBan::new requiert dbh — on passe un stub minimal
    my $fake_dbh = bless {}, 'FakeDBH';

    my $cb = Mediabot::ChannelBan->new(
        bot    => undef,
        dbh    => $fake_dbh,
        logger => $logger,
    );

    # -------------------------------------------------------------------------
    # 1. parse_duration — formats valides
    # -------------------------------------------------------------------------
    {
        my ($secs, $label, $err);

        # permanent / perm / 0
        ($secs, $label, $err) = $cb->parse_duration('');
        $assert->ok(!defined $err && $secs == 0 && $label eq 'permanent',
            'parse_duration("") → permanent');

        ($secs, $label, $err) = $cb->parse_duration('perm');
        $assert->ok(!defined $err && $secs == 0, 'parse_duration("perm")');

        ($secs, $label, $err) = $cb->parse_duration('permanent');
        $assert->ok(!defined $err && $secs == 0, 'parse_duration("permanent")');

        ($secs, $label, $err) = $cb->parse_duration('never');
        $assert->ok(!defined $err && $secs == 0, 'parse_duration("never")');

        ($secs, $label, $err) = $cb->parse_duration('0');
        $assert->ok(defined $err, 'parse_duration("0") → erreur (pas perm)');

        # minutes
        ($secs, $label, $err) = $cb->parse_duration('10m');
        $assert->ok(!defined $err, 'parse_duration("10m") : pas d\'erreur');
        $assert->is($secs, 600, 'parse_duration("10m") = 600s');
        $assert->is($label, '10m', 'parse_duration("10m") label');

        ($secs, $label, $err) = $cb->parse_duration('30');
        $assert->ok(!defined $err, 'parse_duration("30") bare = 30 minutes');
        $assert->is($secs, 1800, 'parse_duration("30") = 1800s');

        # heures
        ($secs, $label, $err) = $cb->parse_duration('2h');
        $assert->is($secs, 7200, 'parse_duration("2h") = 7200s');

        # jours
        ($secs, $label, $err) = $cb->parse_duration('3d');
        $assert->is($secs, 259200, 'parse_duration("3d") = 259200s');

        # semaines
        ($secs, $label, $err) = $cb->parse_duration('1w');
        $assert->is($secs, 604800, 'parse_duration("1w") = 604800s');
    }

    # -------------------------------------------------------------------------
    # 2. parse_duration — cas d'erreur
    # -------------------------------------------------------------------------
    {
        my (undef, undef, $err);

        (undef, undef, $err) = $cb->parse_duration('abc');
        $assert->ok(defined $err, 'parse_duration("abc") → erreur');

        (undef, undef, $err) = $cb->parse_duration('10x');
        $assert->ok(defined $err, 'parse_duration("10x") → erreur (unité invalide)');

        (undef, undef, $err) = $cb->parse_duration('0m');
        $assert->ok(defined $err, 'parse_duration("0m") → erreur (zéro non permanent)');
    }

    # -------------------------------------------------------------------------
    # 3. parse_ban_level
    # -------------------------------------------------------------------------
    {
        my ($level, $err);

        # Niveau par défaut = actor level (si >= 75)
        ($level, $err) = $cb->parse_ban_level(undef, 100);
        $assert->ok(!defined $err, 'parse_ban_level(undef, 100) : pas d\'erreur');
        $assert->is($level, 100, 'parse_ban_level défaut = actor level');

        # Actor en dessous du minimum
        ($level, $err) = $cb->parse_ban_level(undef, 50);
        $assert->ok(defined $err, 'parse_ban_level actor<75 → erreur');

        # Niveau explicite valide
        ($level, $err) = $cb->parse_ban_level('75', 100);
        $assert->is($level, 75, 'parse_ban_level explicite 75');
        $assert->ok(!defined $err, 'parse_ban_level 75 : pas d\'erreur');

        # Niveau explicite trop bas
        ($level, $err) = $cb->parse_ban_level('50', 100);
        $assert->ok(defined $err, 'parse_ban_level 50 < min(75) → erreur');

        # Niveau explicite supérieur à actor
        ($level, $err) = $cb->parse_ban_level('200', 100);
        $assert->ok(defined $err, 'parse_ban_level 200 > actor(100) → erreur');

        # Niveau non numérique
        ($level, $err) = $cb->parse_ban_level('abc', 100);
        $assert->ok(defined $err, 'parse_ban_level "abc" → erreur');
    }

    # -------------------------------------------------------------------------
    # 4. validate_mask — masques valides
    # -------------------------------------------------------------------------
    {
        my @valid = (
            '*!*user@hostname.com',
            '*!*user@192.168.1.1',
            '*!*user@*.wanadoo.fr',
            '*!user@some.host.net',
            'nick!user@host',
        );
        for my $m (@valid) {
            my $err = $cb->validate_mask($m);
            $assert->ok(!defined $err, "validate_mask('$m') valide");
        }
    }

    # -------------------------------------------------------------------------
    # 5. validate_mask — masques refusés
    # -------------------------------------------------------------------------
    {
        my @invalid = (
            '',
            '*!*@*',
            '*!*@*.*',
            '*@*',
            '*!*',
            '*',
            '*!*@**',
            undef,
        );
        for my $m (@invalid) {
            my $label = defined $m ? "'$m'" : 'undef';
            my $err = $cb->validate_mask($m);
            $assert->ok(defined $err, "validate_mask($label) refusé : $err");
        }
    }

    # -------------------------------------------------------------------------
    # 6. validate_mask — host sans partie utile
    # -------------------------------------------------------------------------
    {
        my $err = $cb->validate_mask('*!*user@*.*');
        $assert->ok(defined $err, 'validate_mask host wildcard pur → refusé');
    }

    # -------------------------------------------------------------------------
    # 7. normalize_mask
    # -------------------------------------------------------------------------
    {
        # user@host → *!user@host
        my $m = $cb->normalize_mask('user@host.com');
        $assert->is($m, '*!user@host.com', 'normalize_mask user@host');

        # masque déjà complet → inchangé
        $m = $cb->normalize_mask('*!*user@host.com');
        $assert->is($m, '*!*user@host.com', 'normalize_mask masque complet');

        # nick pur → retourné tel quel (pas de @)
        $m = $cb->normalize_mask('badenick');
        $assert->is($m, 'badenick', 'normalize_mask nick pur retourné');

        # undef → undef
        $m = $cb->normalize_mask(undef);
        $assert->ok(!defined $m, 'normalize_mask(undef) → undef');

        # vide → undef
        $m = $cb->normalize_mask('');
        $assert->ok(!defined $m, 'normalize_mask("") → undef');
    }

    # -------------------------------------------------------------------------
    # 8. mask_from_hostmask
    # -------------------------------------------------------------------------
    {
        # nick!ident@host → *!*ident@host (strip leading ~)
        my $m = $cb->mask_from_hostmask('badnick!~user@evil.host.com');
        $assert->is($m, '*!*user@evil.host.com', 'mask_from_hostmask avec ~');

        # sans ~
        $m = $cb->mask_from_hostmask('badnick!user@evil.host.com');
        $assert->is($m, '*!*user@evil.host.com', 'mask_from_hostmask sans ~');

        # ident@host (sans nick)
        $m = $cb->mask_from_hostmask('~user@host.net');
        $assert->is($m, '*!*user@host.net', 'mask_from_hostmask ident@host');

        # invalide → undef
        $m = $cb->mask_from_hostmask('just_a_nick');
        $assert->ok(!defined $m, 'mask_from_hostmask invalide → undef');

        $m = $cb->mask_from_hostmask(undef);
        $assert->ok(!defined $m, 'mask_from_hostmask undef → undef');
    }

    # -------------------------------------------------------------------------
    # 9. looks_like_duration / looks_like_level
    # -------------------------------------------------------------------------
    {
        $assert->ok($cb->looks_like_duration('10m'),       'looks_like_duration 10m');
        $assert->ok($cb->looks_like_duration('2h'),        'looks_like_duration 2h');
        $assert->ok($cb->looks_like_duration('perm'),      'looks_like_duration perm');
        $assert->ok($cb->looks_like_duration('never'),     'looks_like_duration never');
        $assert->ok($cb->looks_like_duration('30'),        'looks_like_duration bare int');
        $assert->ok(!$cb->looks_like_duration('abc'),      'looks_like_duration abc → non');
        $assert->ok(!$cb->looks_like_duration(undef),      'looks_like_duration undef → non');

        $assert->ok($cb->looks_like_level('100'),          'looks_like_level 100');
        $assert->ok($cb->looks_like_level('0'),            'looks_like_level 0');
        $assert->ok(!$cb->looks_like_level('abc'),         'looks_like_level abc → non');
        $assert->ok(!$cb->looks_like_level('10m'),         'looks_like_level 10m → non');
        $assert->ok(!$cb->looks_like_level(undef),         'looks_like_level undef → non');
    }

    # -------------------------------------------------------------------------
    # 10. min_ban_level
    # -------------------------------------------------------------------------
    {
        $assert->is($cb->min_ban_level, 75, 'min_ban_level = 75');
    }
};
