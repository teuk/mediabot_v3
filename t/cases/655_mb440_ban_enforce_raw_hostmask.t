# t/cases/655_mb440_ban_enforce_raw_hostmask.t
# =============================================================================
# mb440 — L'application des ChannelBans au JOIN matche le hostmask RÉEL du
# joineur, pas le masque normalisé (nick wildcardé).
#
# Le handler JOIN construisait $norm_mask = mask_from_hostmask(...) =
# "*!*ident@host" (nick remplacé par '*') et le passait à active_ban_for_mask
# comme sujet du matching. Résultat : un ban basé sur le NICK
# (ex. "spammer!*@host.com") n'était JAMAIS appliqué, car son pattern ne peut
# pas matcher un sujet dont le nick est déjà '*'. mb440 : matcher contre le
# hostmask brut "nick!ident@host" ; $norm_mask reste le masque posé (+b).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_655 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du matching IRC (reproduction _mask_matches_irc) ----
    my $match = sub {
        my ($pat, $host) = @_;
        my $re = quotemeta($pat);
        $re =~ s/\\\*/.*/g;
        $re =~ s/\\\?/./g;
        return ($host =~ /^$re$/i) ? 1 : 0;
    };

    my $ban  = 'spammer!*@host.com';           # ban basé sur le nick
    my $raw  = 'spammer!~sp@host.com';          # hostmask réel du joineur
    my $norm = '*!*sp@host.com';                # mask_from_hostmask (nick wildcardé)

    $assert->is($match->($ban, $raw),  1, 'ban nick matche le hostmask RÉEL');
    $assert->is($match->($ban, $norm), 0, 'ban nick NE matche PAS le mask normalisé (ancien bug)');

    # Un ban user@host (nick wildcardé) matche les deux — non régressé.
    my $ban2 = '*!*sp@host.com';
    $assert->is($match->($ban2, $raw),  1, 'ban user@host matche le hostmask réel');

    # --- 2. Câblage réel dans mediabot.pl ----------------------------------
    my $src = _slurp_655(File::Spec->catfile('.', 'mediabot.pl'));
    (my $code = $src) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/my \$raw_hostmask = "\$sNick!\$sIdent\\\@\$sHost";/,
        'hostmask brut construit');
    $assert->like($code, qr/active_ban_for_mask\(\$id_channel, \$raw_hostmask\)/,
        'enforcement matche le hostmask brut');
    $assert->unlike($code, qr/active_ban_for_mask\(\$id_channel, \$norm_mask\)/,
        'plus de matching sur le mask normalisé');
    # $norm_mask reste utilisé pour le MODE +b.
    $assert->like($code, qr/'\+b', \$norm_mask/, '$norm_mask reste le masque posé (+b)');

    $assert->like($src, qr/mb440-B1/, 'tag mb440-B1');
};
