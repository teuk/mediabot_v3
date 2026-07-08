# t/cases/691_mb480_stats_achievements.t
# =============================================================================
# mb480 — !stats affiche le nombre d'achievements débloqués sur le canal.
#
# mbStats_ctx est une commande riche (nombreuses requêtes DB) : plutôt que de
# tout rejouer, on vérifie [A] le câblage exact de l'ajout dans le code, et
# [B] la logique de comptage attendue (get_for_nick -> "achievements: N",
# masqué si 0) via un petit mock de l'objet achievements.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_691 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# reproduit la logique d'affichage introduite par mb480, pour la tester isolément
sub _ach_suffix {
    my ($mgr, $target, $channel) = @_;
    my $out = '';
    if ($mgr) {
        my $ach = eval { $mgr->get_for_nick($target, $channel) };
        if (ref($ach) eq 'HASH') {
            my $n = scalar keys %$ach;
            $out .= " | achievements: $n" if $n > 0;
        }
    }
    return $out;
}

{
    package FakeAch691;
    sub new { bless { data => $_[1] // {} }, $_[0] }
    sub get_for_nick {
        my ($self, $nick, $chan) = @_;
        my $key = lc($nick) . "\x00" . lc($chan // '');
        return $self->{data}{$key} // {};
    }
}

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # [A] Câblage dans le code source.
    # -------------------------------------------------------------------------
    my $uc = _slurp_691(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    $assert->like($uc, qr/mb480/, 'ajout mb480 tracé dans le code');
    $assert->like($uc,
        qr/\$self->\{achievements\}->get_for_nick\(\$target,\s*\$channel\)/,
        'lit get_for_nick(target, channel)');
    $assert->like($uc, qr/achievements:\s*\$n/, 'compose "achievements: N"');
    # placé avant l'envoi de la ligne stats
    $assert->like($uc,
        qr/achievements:\s*\$n.*?botPrivmsg\(\$self,\s*\$channel,\s*\$out\);/s,
        'ajout inséré avant botPrivmsg de la ligne stats');
    # défensif : ne s'exécute que si l'objet achievements est présent
    $assert->like($uc, qr/if\s*\(\$self->\{achievements\}\)\s*\{/,
        'garde la présence de l\'objet achievements');

    # -------------------------------------------------------------------------
    # [B] Logique de comptage.
    # -------------------------------------------------------------------------
    # 3 achievements sur #test pour alice
    my $mgr = FakeAch691->new({
        "alice\x00#test" => { 1 => 111, 2 => 222, 3 => 333 },
        "bob\x00#test"   => {},                       # aucun
    });

    $assert->is(_ach_suffix($mgr, 'alice', '#test'), ' | achievements: 3',
        'alice (3) -> suffixe affiché');
    $assert->is(_ach_suffix($mgr, 'Alice', '#test'), ' | achievements: 3',
        'insensible à la casse du nick');
    $assert->is(_ach_suffix($mgr, 'bob', '#test'), '',
        'bob (0) -> pas de suffixe');
    $assert->is(_ach_suffix($mgr, 'carol', '#test'), '',
        'nick inconnu -> pas de suffixe');
    $assert->is(_ach_suffix(undef, 'alice', '#test'), '',
        'pas d\'objet achievements -> pas de suffixe (défensif)');
};
