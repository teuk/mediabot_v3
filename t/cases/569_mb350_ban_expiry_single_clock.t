# t/cases/569_mb350_ban_expiry_single_clock.t
# =============================================================================
# mb350 — Expiration des bans temporisés calculée côté SQL (une seule horloge).
#
# Avant : expires_sql_from_seconds() formatait l'expiration avec l'horloge du
# process Perl (localtime), puis expired_bans comparait `expires_at <= NOW()`
# côté MariaDB. Si le fuseau de la session SQL diffère du fuseau système (DB en
# UTC, conteneur, etc.), les bans temporisés duraient trop ou pas assez.
#
# mb350 : add_ban calcule l'expiration EN SQL via `NOW() + INTERVAL ? SECOND`,
# en bindant le nombre de secondes (ou NULL -> permanent). Les deux côtés
# partagent désormais l'horloge du serveur.
#
# Pas de DBI réel : validation par (a) la garde "secondes" et (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction de la normalisation mb350 du paramètre expires_seconds.
sub _norm_secs {
    my ($s) = @_;
    return (defined($s) && $s =~ /^\d+$/ && $s > 0) ? $s : undef;
}

sub _slurp_569 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Garde "secondes" : timed vs permanent -------------------------
    $assert->is(_norm_secs(3600), 3600, '3600s -> ban temporisé');
    $assert->is(_norm_secs(1),    1,    '1s -> temporisé');
    $assert->ok(!defined _norm_secs(0),     '0 -> permanent (NULL)');
    $assert->ok(!defined _norm_secs(undef), 'undef -> permanent (NULL)');
    $assert->ok(!defined _norm_secs(-5),    'négatif -> permanent (NULL)');
    $assert->ok(!defined _norm_secs('abc'), 'non numérique -> permanent (NULL)');

    # --- 2. Scan source ChannelBan.pm ------------------------------------
    my $cb = _slurp_569(File::Spec->catfile('.', 'Mediabot', 'ChannelBan.pm'));
    my ($add) = $cb =~ /(sub add_ban \{.*?\n\}\n)/s; $add //= '';
    $assert->ok($add ne '', 'sub add_ban extraite');

    # L'INSERT calcule expires_at côté SQL.
    $assert->like($add, qr/\(NOW\(\)\s*\+\s*INTERVAL\s*\?\s*SECOND\)/,
                  'add_ban: expires_at = NOW() + INTERVAL ? SECOND');
    # On binde les secondes, plus la chaîne localtime.
    $assert->like($add, qr/\$expires_seconds/, 'add_ban: binde expires_seconds');
    (my $add_sql = $add) =~ s/^\s*#.*$//mg;
    $assert->unlike($add_sql, qr/\$args\{expires_at\}/,
                    'add_ban: ne binde plus la chaîne expires_at pré-formatée');
    $assert->like($add, qr/mb350-B1/, 'tag mb350-B1 présent');

    # --- 3. Scan des appelants -------------------------------------------
    my $cc = _slurp_569(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    $assert->like($cc, qr/expires_seconds\s*=>\s*\$duration_seconds/,
                  'ChannelCommands (mbBan): passe expires_seconds');
    (my $cc_ban = $cc) =~ /sub .*?\{.*?expires_seconds.*?\}/s;
    $assert->unlike($cc, qr/expires_at\s*=>\s*\$expires_at/,
                    'ChannelCommands: ne passe plus expires_at pré-calculé');

    my $main = _slurp_569(File::Spec->catfile('.', 'mediabot.pl'));
    $assert->like($main, qr/expires_seconds\s*=>\s*\(\s*\$duration\s*>\s*0/,
                  'mediabot.pl (partyline ban): passe expires_seconds');
};
