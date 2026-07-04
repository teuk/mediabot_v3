# t/cases/627_mb409_antiflood_negative_cache.t
# =============================================================================
# mb409 — checkAntiFlood met en cache l'ABSENCE de configuration.
#
# Sans ligne CHANNEL_FLOOD (le cas par défaut d'un canal sans antiflood), le
# résultat n'était pas mémorisé : le SELECT était relancé à CHAQUE message
# sortant — à rebours de l'objectif AF1 « zero DB queries per outgoing
# message ». mb409 : cache négatif { ts, unconfigured } avec le même TTL que
# les paramètres ; le chemin chaud court-circuite sans SQL ; activer
# l'antiflood en base est pris en compte au prochain rafraîchissement.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_627 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du cache négatif (reproduction) ---------------------
    my %af_params; my $selects = 0;
    my $check = sub {
        my ($chan, $now) = @_;
        my $ttl = 60;
        my $pc  = $af_params{$chan} // {};
        if (!$pc->{ts} || ($now - $pc->{ts}) >= $ttl) {
            $selects++;                              # <- le SELECT
            my $ref = undef;                         # pas de ligne CHANNEL_FLOOD
            if ($ref) { }
            else { $af_params{$chan} = { ts => $now, unconfigured => 1 }; return 0; }
        }
        return 0 if $pc->{unconfigured};
        return 0;
    };
    $check->('#teuk', 1000 + $_) for (1 .. 10);
    $assert->is($selects, 1, '10 messages, 1 seul SELECT (avant: 10)');
    $check->('#teuk', 1100);   # TTL expiré
    $assert->is($selects, 2, 'après TTL: une seule re-vérification');
    $check->('#teuk', 1101);
    $assert->is($selects, 2, 'le cache négatif repart pour un TTL');

    # --- 2. Scan source ------------------------------------------------------
    my $src = _slurp_627(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my ($body) = $src =~ /(sub checkAntiFlood \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/\{ ts => \$now, unconfigured => 1 \}/,
        'absence de CHANNEL_FLOOD mémorisée avec TTL');
    $assert->like($code, qr/return 0 if \$pc->\{unconfigured\};/,
        'chemin chaud: court-circuit sans SQL');
    $assert->like($src, qr/mb409-B1/, 'tag mb409-B1');
};
