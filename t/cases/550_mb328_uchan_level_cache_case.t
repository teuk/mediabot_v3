# t/cases/550_mb328_uchan_level_cache_case.t
# =============================================================================
# mb328 — Clé de cache de niveau canal insensible à la casse.
#
# checkUserChannelLevel() met en cache (TTL 60s) le niveau d'un user sur un
# canal, sous la clé "$id_user\x00$sChannel". channelAddUser_ctx /
# channelDelUser_ctx invalidaient cette entrée par un delete à clé EXACTE
# "$id\x00$channel". Comme les canaux IRC sont insensibles à la casse (et que le
# SQL matche en collation _ci), une population sous "#Foo" et une invalidation
# sous "#foo" ne correspondaient pas → niveau de privilège périmé jusqu'à 60s
# (un user fraîchement rétrogradé gardait son accès). mb328 normalise la clé en
# minuscules à la population ET aux invalidations.
#
# Le test :
#   1. reproduit le format de clé corrigé et prouve que #Foo et #foo donnent la
#      MÊME clé (donc l'invalidation atteint l'entrée quelle que soit la casse) ;
#   2. vérifie par scan de source que les 3 sites utilisent lc() sur le canal.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_550 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Clé telle que normalisée par le code après mb328.
sub _key { my ($id, $chan) = @_; return "$id\x00" . lc($chan); }

return sub {
    my ($assert) = @_;

    # --- 1. Invariant fonctionnel : casse du canal sans effet --------------
    $assert->is(
        _key(42, '#Foo'),
        _key(42, '#foo'),
        'clé identique pour #Foo et #foo (invalidation atteint l\'entrée)'
    );
    $assert->is(
        _key(42, '#Foo'),
        _key(42, '#FOO'),
        'clé identique pour #Foo et #FOO'
    );
    $assert->isnt(
        _key(42, '#foo'),
        _key(42, '#bar'),
        'canaux distincts → clés distinctes'
    );
    $assert->isnt(
        _key(42, '#foo'),
        _key(43, '#foo'),
        'users distincts → clés distinctes'
    );

    # --- 2. Scan de source : lc() aux 3 sites -----------------------------
    my $helpers = _slurp_550(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $chancmd = _slurp_550(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));

    $assert->like(
        $helpers,
        qr/my \$cache_key = "\$id_user\\x00" \. lc\(\$sChannel\)/,
        'checkUserChannelLevel: clé de cache en lc($sChannel)'
    );
    $assert->like(
        $chancmd,
        qr/_uchan_level_cache\}\{"\$id_target_user\\x00" \. lc\(\$channel\)\}/,
        'channelAddUser: invalidation en lc($channel)'
    );
    $assert->like(
        $chancmd,
        qr/_uchan_level_cache\}\{"\$id_target\\x00" \. lc\(\$channel\)\}/,
        'channelDelUser: invalidation en lc($channel)'
    );
};
