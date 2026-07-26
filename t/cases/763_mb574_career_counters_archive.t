# t/cases/763_mb574_career_counters_archive.t
# =============================================================================
# mb574 (refondu par mb576) — les compteurs CARRIERE voient vif + archive via
# des requetes PAR TABLE fusionnees en Perl (Helpers::channel_log_gather).
# Le UNION ALL derive de la premiere mouture est banni : MariaDB pousse les
# WHERE dans les branches mais pas les ORDER BY/LIMIT, et meme les COUNT
# materialisaient les lignes filtrees avant d'agreger.
#   [1] stats / top / streak / leaderboard utilisent channel_log_gather ;
#   [2] plus aucune reference a l'ancien helper channel_log_from ;
#   [3] la garde d'interpolation tient : aucun qq{} contenant la sequence
#       REGEXP « $) » (variable GID Perl) dans tout le fichier.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_763 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_763 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_763(File::Spec->catfile('Mediabot', 'UserCommands.pm'));

    # [1] chaque compteur carriere passe par le gather par table
    for my $sub_name (qw(mbStats_ctx mbTop_ctx mbStreak_ctx mbLeaderboard_ctx)) {
        my $body = _sub_src_763($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        $assert->like($body, qr/Mediabot::Helpers::channel_log_gather/,
            "$sub_name: requetes par table via channel_log_gather");
        $assert->like($body, qr/__CLSRC__/,
            "$sub_name: template avec token __CLSRC__");
    }

    # les fusions sensibles : rank de stats et podium du leaderboard se font
    # sur des GROUP BY complets par table (pas de HAVING/LIMIT par branche)
    my $stats = _sub_src_763($src, 'mbStats_ctx');
    $assert->like($stats, qr/%rank_counts/,
        'stats: fusion des comptes par nick avant le seuil de rank');
    my @having = grep { $_ !~ /^\s*#/ && /HAVING/i } split /\n/, $stats;
    $assert->is(join('|', @having), '',
        'stats: aucun HAVING par branche (le seuil est applique en Perl)');
    my $lb = _sub_src_763($src, 'mbLeaderboard_ctx');
    $assert->like($lb, qr/%lb_counts/,
        'leaderboard: fusion par nick avant le podium');

    # [2] l'ancien helper n'existe plus nulle part
    $assert->ok($src !~ /channel_log_from/,
        'UserCommands: plus aucune reference a channel_log_from');
    my $helpers = _slurp_763(File::Spec->catfile('Mediabot', 'Helpers.pm'));
    $assert->ok($helpers !~ /sub channel_log_from/,
        'Helpers: sub channel_log_from supprimee');

    # [3] garde interpolation
    my @danger;
    while ($src =~ /qq\{([^}]*)\}/gs) {
        push @danger, substr($1, 0, 40) if $1 =~ /\[\[:space:\]\]\|\$\)/;
    }
    $assert->is(join('|', @danger), '', 'aucun qq{} avec la sequence $)');
};
