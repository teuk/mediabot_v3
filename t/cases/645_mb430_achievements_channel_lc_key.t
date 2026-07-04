# t/cases/645_mb430_achievements_channel_lc_key.t
# =============================================================================
# mb430 — Les clés d'achievements replient le canal en lc (IRC insensible à la
# casse), avec migration des clés existantes en casse mixte.
#
# Avant, la clé était "lc(nick)\x00<canal>" — le canal n'était PAS replié. Un
# même canal pouvait donc occuper deux clés selon la casse (#Teuk vs #teuk) :
# la dédup `return 0 if exists {$id}` échouait -> unlock/annonce en double, et
# get_for_nick sur une casse ratait les achievements stockés sous l'autre.
# mb430 : canal en lc dans les 3 constructions de clé (get_for_nick, unlock,
# check_msg) + migration au chargement (_load) qui fusionne les clés casse
# mixte en gardant le timestamp le plus ancien. Aucune donnée perdue.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_645 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique de la migration (reproduction) ----------------------
    my %data = (
        "teuk\x00#Teuk" => { karma_star => 100, trivia_ace => 200 },
        "teuk\x00#teuk" => { karma_star => 50 },      # ts plus ancien
        "bob\x00#chan"  => { duel_win => 300 },        # déjà lc
    );
    my $migrated = 0;
    for my $k (keys %data) {
        my ($n, $ch) = split /\x00/, $k, 2; $ch //= '';
        my $lc = lc $ch; next if $ch eq $lc;
        my $nk = $n . "\x00" . $lc; my $src = delete $data{$k};
        for my $id (keys %$src) {
            my $ts = $src->{$id};
            $data{$nk}{$id} = $ts if !exists $data{$nk}{$id} || $ts < $data{$nk}{$id};
        }
        $migrated++;
    }
    $assert->is($migrated, 1, 'une clé casse-mixte migrée');
    $assert->ok(!exists $data{"teuk\x00#Teuk"}, 'ancienne clé #Teuk supprimée');
    $assert->is($data{"teuk\x00#teuk"}{karma_star}, 50, 'karma_star garde le ts le plus ancien');
    $assert->is($data{"teuk\x00#teuk"}{trivia_ace}, 200, 'trivia_ace fusionné');
    $assert->is($data{"bob\x00#chan"}{duel_win}, 300, 'clé déjà lc intacte');
    $assert->is(scalar(keys %data), 2, 'pas de clé en double après fusion');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_645(File::Spec->catfile('.', 'Mediabot', 'Achievements.pm'));
    (my $code = $src) =~ s/^\s*#.*$//mg;

    my $n_lc_key = () = $code =~ /defined \$channel \? lc\(\$channel\) : ""/g;
    $assert->ok($n_lc_key >= 2, 'get_for_nick et unlock replient le canal en lc');
    $assert->like($code, qr/my \$cache_key = lc\(\$nick\) \. "\\x00" \. lc\(\$channel \/\/ ""\)/,
        'check_msg: cache_key canal en lc');
    $assert->unlike($code, qr/lc\(\$nick\) \. "\\x00" \. \(defined \$channel \? \$channel :/,
        'plus de canal en casse brute dans les clés');

    # Migration présente dans _load
    my ($load) = $code =~ /(sub _load \{.*?\n\}\n)/s; $load //= '';
    $assert->like($load, qr/folded .* mixed-case channel key/,
        'migration de casse dans _load');
    $assert->like($load, qr/\$ts < \$self->\{data\}\{\$new_k\}\{\$id\}/,
        'fusion : garde le timestamp le plus ancien');

    $assert->like($src, qr/mb430-B1/, 'tag mb430-B1');
};
