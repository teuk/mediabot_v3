# t/cases/628_mb410_karma_vote_channel_cache.t
# =============================================================================
# mb410 — Le vote karma (!karma +/- <nick>) résout l'id du canal via le cache
# interne {channels} (clé canonique lc, mb407) au lieu d'un SELECT par vote.
# La requête SQL reste le REPLI si le canal est absent du cache.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_628 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_628(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbKarma_ctx \{.*?\n\}\n)/s; $body //= '';
    $assert->ok($body ne '', 'mbKarma_ctx extraite');
    (my $code = $body) =~ s/^\s*#.*$//mg;

    # Le cache est interrogé en premier (clé lc, cohérente mb407) sur les DEUX
    # chemins (vote et consultation).
    my $ncache = () = $code =~ /\{channels\}\{lc \$channel\}/g;
    $assert->ok($ncache >= 2, 'les deux chemins (vote + consultation) lisent le cache');
    $assert->like($code, qr/\$vote_id_channel = \$vote_chan_obj->get_id if \$vote_chan_obj;/,
        'vote: get_id depuis l\'objet Channel');
    $assert->like($code, qr/\$id_channel = \$kchan_obj->get_id if \$kchan_obj;/,
        'consultation: get_id depuis l\'objet Channel');

    # Chaque SELECT restant est un REPLI : sa ligne est précédée (à ≤ 4 lignes)
    # d'un `unless (...id_channel)`.
    my @lines = split /\n/, $code;
    my ($n_sel, $n_guarded) = (0, 0);
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /SELECT id_channel FROM CHANNEL WHERE name = \?/;
        $n_sel++;
        my $lo = $i >= 4 ? $i - 4 : 0;
        $n_guarded++ if grep { /unless \(\$(?:vote_)?id_channel\)/ } @lines[$lo .. $i];
    }
    $assert->is($n_sel, 2, 'deux SELECT restants dans la sub');
    $assert->is($n_guarded, 2, 'les 2 SELECT sont des replis (précédés d\'un unless)');

    $assert->like($src, qr/mb410-R1/, 'tag mb410-R1');
};
