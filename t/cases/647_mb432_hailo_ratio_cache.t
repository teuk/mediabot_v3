# t/cases/647_mb432_hailo_ratio_cache.t
# =============================================================================
# mb432 — get_hailo_channel_ratio met en cache le ratio (TTL), au lieu d'un
# SELECT+JOIN par message.
#
# hailo_should_chatter() est appelé à CHAQUE message public d'un canal (branche
# elsif du handler PRIVMSG). Il appelait get_hailo_channel_ratio, qui faisait
# un `SELECT ... JOIN CHANNEL ...` à chaque fois. Le ratio ne change que par
# commande (set_hailo_channel_ratio). mb432 : cache { ts, ratio } avec TTL 60s,
# clé lc (mb407), mémorise aussi -1 (canal non configuré), et set_ invalide
# l'entrée pour une prise en compte immédiate.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_647 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du cache (reproduction) -----------------------------
    my %cache; my $selects = 0;
    my $get = sub {
        my ($chan, $now) = @_;
        my $ck = lc $chan;
        my $c = $cache{$ck};
        return $c->{ratio} if $c && ($now - $c->{ts}) < 60;
        $selects++;
        $cache{$ck} = { ts => $now, ratio => 42 };
        return 42;
    };
    $get->('#Teuk', 1000 + $_) for (0 .. 29);
    $assert->is($selects, 1, '30 messages -> 1 seul SELECT (avant: 30)');
    $get->('#teuk', 1005);                      # même canal, casse différente, dans le TTL
    $assert->is($selects, 1, 'clé lc: la casse ne dédouble pas le cache');
    $get->('#teuk', 1100);                       # TTL expiré
    $assert->is($selects, 2, 'après TTL: une re-lecture');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_647(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));

    my ($get_body) = $src =~ /(sub get_hailo_channel_ratio \{.*?\n\}\n)/s; $get_body //= '';
    (my $gcode = $get_body) =~ s/^\s*#.*$//mg;
    $assert->like($gcode, qr/\$self->\{_hailo_ratio_cache\}\{\$ckey\}/, 'lecture du cache');
    $assert->like($gcode, qr/\(\$now - \$cached->\{ts\}\) < 60/, 'TTL 60s');
    $assert->like($gcode, qr/my \$ckey = lc \$sChannel;/, 'clé lc');
    $assert->like($gcode, qr/\$self->\{_hailo_ratio_cache\}\{\$ckey\} = \{ ts => \$now, ratio => \$ratio \}/,
        'mémorisation après SELECT (y compris -1)');

    my ($set_body) = $src =~ /(sub set_hailo_channel_ratio \{.*?\n\}\n)/s; $set_body //= '';
    $assert->like($set_body, qr/delete \$self->\{_hailo_ratio_cache\}\{lc \$sChannel\}/,
        'set_ invalide le cache pour prise en compte immédiate');

    $assert->like($src, qr/mb432-R1/, 'tag mb432-R1');
};
