# t/cases/698_mb487_help_category_detailed.t
# =============================================================================
# mb487 — "help commands <category>" devient utile : pour une PETITE catégorie,
# chaque commande est listée avec une description courte (name - desc) ; pour
# une GROSSE catégorie, on garde la liste compacte chunkée (anti-flood).
#
# [A] câblage (seuil + branche détaillée/compacte) ;
# [B] rendu détaillé d'une petite catégorie (factoids) via le vrai builder ;
# [C] rendu compact d'une grosse catégorie (channel) : pas une ligne/commande ;
# [D] bornes : lignes raisonnables, descriptions tronquées.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_698 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _extract_698 {
    my ($src, $name) = @_;
    return '' unless $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $1;
}

# reproduit la logique d'affichage d'une catégorie (mode adaptatif), pour la
# tester sur les vraies données sans dépendre de l'IRC.
sub _render_category {
    my ($category) = @_;
    require Mediabot::Mediabot;
    my %cats = Mediabot::_mbHelpBuildCategories();
    my %int  = Mediabot::_mbHelpInternalCommands();
    my @cmds = @{ $cats{$category} || [] };
    my $DETAILED_MAX = 12;
    my @lines;
    if (@cmds && @cmds <= $DETAILED_MAX) {
        my $w = 0; for (@cmds) { $w = length if length > $w; }
        for my $c (@cmds) {
            my $d = $int{$c}{desc} // ''; $d =~ s/\s+/ /g; $d =~ s/^\s+|\s+$//g;
            $d = Mediabot::Helpers::truncate_utf8($d, 90, '...') if length($d) > 90;
            push @lines, $d ne '' ? sprintf("  %-*s - %s", $w, $c, $d) : "  $c";
        }
    }
    else {
        push @lines, Mediabot::_mbHelpBuildChunkedList("Commands: ", @cmds);
    }
    return @lines;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;
    my $src = _slurp_698(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    # --- [A] câblage --------------------------------------------------------
    my $fn = _extract_698($src, '_mbHelpSendCategoryCommands');
    $assert->ok($fn ne '', '_mbHelpSendCategoryCommands localisé');
    $assert->like($fn, qr/DETAILED_MAX\s*=\s*12/, '[A] seuil détaillé = 12');
    $assert->like($fn, qr/\@cmds\s*<=\s*\$DETAILED_MAX/, '[A] branche selon la taille');
    $assert->like($fn, qr/_mbHelpBuildChunkedList/, '[A] fallback compact conservé');
    $assert->like($fn, qr/truncate_utf8/, '[A] descriptions tronquées proprement');

    # --- [B] petite catégorie : détaillé ------------------------------------
    my %cats = Mediabot::_mbHelpBuildCategories();
    $assert->ok(scalar(@{$cats{factoids}}) <= 12, 'factoids est une petite catégorie');
    my @fac = _render_category('factoids');
    # une ligne par commande (5)
    $assert->is(scalar(@fac), scalar(@{$cats{factoids}}),
        '[B] factoids : une ligne par commande');
    my $joined = join("\n", @fac);
    $assert->like($joined, qr/learn\s+- Store a shared channel fact/,
        '[B] la description de learn est affichée');
    $assert->like($joined, qr/whatis\s+- Recall a shared channel fact/,
        '[B] la description de whatis est affichée');
    # format "name - desc"
    $assert->ok((grep { /^\s+\S+\s+- \S/ } @fac) == scalar(@fac),
        '[B] chaque ligne est au format "name - description"');

    # --- [C] grosse catégorie : compact -------------------------------------
    $assert->ok(scalar(@{$cats{channel}}) > 12, 'channel est une grosse catégorie');
    my @chan = _render_category('channel');
    # bien moins de lignes que de commandes (liste chunkée)
    $assert->ok(scalar(@chan) < scalar(@{$cats{channel}}) / 3,
        '[C] channel : liste compacte (pas une ligne par commande)');
    $assert->ok((grep { /^Commands: / } @chan) > 0,
        '[C] channel : format compact "Commands: ..."');

    # --- [D] bornes ---------------------------------------------------------
    my $too_long = grep { length($_) > 400 } (@fac, @chan);
    $assert->is($too_long, 0, '[D] aucune ligne > 400 caractères');
    # ai_fun = 12 -> encore détaillé, borne haute du mode détaillé
    if (exists $cats{ai_fun} && scalar(@{$cats{ai_fun}}) == 12) {
        my @ai = _render_category('ai_fun');
        $assert->is(scalar(@ai), 12, '[D] ai_fun (12) reste en mode détaillé');
    } else {
        $assert->ok(1, '[D] ai_fun skip (taille != 12)');
    }
};
