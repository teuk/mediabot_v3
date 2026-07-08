# t/cases/694_mb483_channel_predicate_consistency.t
# =============================================================================
# mb483 — Cohérence : les commandes utilisateur récentes (recap + factoids)
#         testent le canal via le prédicat partagé isIrcChannelTarget(), pas
#         un /^#/ codé en dur (qui rate les préfixes RFC &!+ et duplique la
#         règle). MB481 avait aligné factoids/did-you-mean ; mb483 aligne recap.
#
# Garde de cohérence (scan de source) : anti-régression pour le futur.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_694 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# extrait le corps d'un sub par nom (jusqu'au prochain "\n}")
sub _body_694 {
    my ($src, $name) = @_;
    return '' unless $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $1;
}

return sub {
    my ($assert) = @_;

    my $uc = _slurp_694(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    # recap doit désormais utiliser le prédicat partagé, plus /^#/.
    my $recap = _body_694($uc, 'mbRecap_ctx');
    $assert->ok($recap ne '', 'mbRecap_ctx localisé');
    $assert->like($recap, qr/isIrcChannelTarget\(\$channel\)/,
        'recap utilise le prédicat de canal partagé');
    $assert->unlike($recap, qr/\$channel\s*=~\s*\/\^#\//,
        'recap ne code plus /^#/ en dur');

    # les commandes factoid (déjà alignées en MB481) ne doivent pas régresser.
    for my $fn (qw(mbLearn_ctx mbWhatis_ctx mbForget_ctx mbFactoids_ctx mbFactoid_ctx)) {
        my $body = _body_694($uc, $fn);
        $assert->ok($body ne '', "$fn localisé");
        $assert->unlike($body, qr/\$channel\s*=~\s*\/\^#\//,
            "$fn ne code pas /^#/ en dur");
    }
};
