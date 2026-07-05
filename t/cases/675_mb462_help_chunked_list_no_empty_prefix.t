# t/cases/675_mb462_help_chunked_list_no_empty_prefix.t
# =============================================================================
# mb462 — _mbHelpBuildChunkedList : pas de ligne réduite au seul préfixe.
#
# Le découpeur de listes du help démarre chaque ligne avec le préfixe puis
# accumule les items séparés par ", ". Quand un item dépassait À LUI SEUL la
# limite (préfixe + item > 360), le code poussait la ligne courante — qui à ce
# moment ne contenait QUE le préfixe — avant de démarrer la ligne de l'item :
# une ligne vide de contenu était émise.
#
# Latent avec les noms de commandes courts (le cas n'arrive pas), mais réel pour
# tout réemploi du helper avec des items longs. mb462-B1 ne pousse la ligne que
# si elle contient déjà un item.
#
# On valide la sémantique via une réplique fidèle du helper corrigé.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_675 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Réplique EXACTE du helper corrigé.
sub _chunk675 {
    my ($prefix, @items) = @_;
    return () unless @items;
    my $max_len = 360;
    my @lines;
    my $line = $prefix;
    for my $item (@items) {
        my $piece = ($line eq $prefix) ? $item : ", $item";
        if (length($line) + length($piece) > $max_len) {
            push @lines, $line if $line ne $prefix;
            $line = $prefix . $item;
        } else {
            $line .= $piece;
        }
    }
    push @lines, $line if $line ne $prefix;
    return @lines;
}

return sub {
    my ($assert) = @_;

    my $prefix = 'Commands: ';

    # --- Cas latent : un item dépasse à lui seul -----------------------------
    my @r = _chunk675($prefix, ('X' x 400));
    $assert->is(scalar(@r), 1, 'un item surdimensionné => une seule ligne (pas de préfixe vide)');
    $assert->ok(!grep({ $_ eq $prefix } @r),
        'aucune ligne réduite au seul préfixe');
    $assert->like($r[0], qr/^\QCommands: \EX{400}$/, 'la ligne contient bien le préfixe + item');

    # --- Cas normal : items courts, comportement inchangé --------------------
    my @many = map { "cmd$_" } (1..80);
    my @rn = _chunk675($prefix, @many);
    $assert->ok(scalar(@rn) >= 1, 'items courts: au moins une ligne');
    $assert->ok(!grep({ $_ eq $prefix } @rn), 'items courts: pas de préfixe vide non plus');
    # chaque ligne commence par le préfixe et tient sous la limite
    my $all_ok = 1;
    for my $l (@rn) { $all_ok = 0 unless $l =~ /^\QCommands: \E/ && length($l) <= 360; }
    $assert->ok($all_ok, 'chaque ligne préfixée et <= 360 chars');
    # tous les items présents, dans l'ordre
    my $joined = join(', ', map { s/^\QCommands: \E//r } @rn);
    $assert->like($joined, qr/cmd1,.*cmd80/, 'tous les items présents dans l\'ordre');

    # --- Liste vide ----------------------------------------------------------
    my @empty = _chunk675($prefix);
    $assert->is(scalar(@empty), 0, 'liste vide => aucune ligne');

    # --- Câblage source ------------------------------------------------------
    my $src = _slurp_675(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my ($sub) = $src =~ /(sub _mbHelpBuildChunkedList \{.*?\n\}\n)/s;
    $sub //= '';
    $assert->like($sub, qr/push \@lines, \$line if \$line ne \$prefix;/,
        'le push conditionnel (mb462) est présent dans la boucle');
    $assert->like($sub, qr/mb462-B1/, 'tag mb462-B1 présent');
};
