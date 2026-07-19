# t/cases/736_mb538_cookbook_doc_truth.t
# =============================================================================
# mb538 — cookbook des patterns par langage (plugins/scripts/COOKBOOK.md),
# dernière pièce (documentaire) de l'arc plugins mb524-538.
#
# La règle de l'arc s'applique à sa propre doc : le cookbook est contracté par
# des gardes de vérité, pas publié sur parole.
#
#   [1] tout `examples/<fichier>` cité dans le cookbook existe sur disque
#       (extension du principe mb530 aux pages de doc) ;
#   [2] chaque exemple livré est cité au moins une fois (le cookbook couvre
#       la bibliothèque entière — un futur exemple non documenté fera échouer
#       CE test) et le compte en toutes lettres correspond au réel ;
#   [3] les invariants techniques cités correspondent aux sources : tableau
#       des champs par évènement ↔ clés réellement whitelistées dans le cœur,
#       charset des noms de timers ↔ garde mb235, règle « resserrer
#       seulement » ↔ scripts de référence ;
#   [4] le README renvoie au cookbook, le cookbook renvoie au README.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_736 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

my $examples_dir = File::Spec->catdir('plugins', 'scripts', 'examples');

return sub {
    my ($assert) = @_;

    my $cookbook = _slurp_736(File::Spec->catfile('plugins', 'scripts', 'COOKBOOK.md'));
    my $readme   = _slurp_736(File::Spec->catfile('plugins', 'scripts', 'README.md'));

    # ------------------------------------------------------------------
    # [1] Toute citation examples/<fichier> existe sur disque
    # ------------------------------------------------------------------
    my %cited;
    while ($cookbook =~ /examples\/([A-Za-z0-9_.-]+\.(?:pl|py|tcl))/g) {
        $cited{$1} = 1;
    }
    $assert->ok(scalar(keys %cited) >= 8, 'le cookbook cite au moins huit exemples');
    for my $file (sort keys %cited) {
        $assert->ok(-f File::Spec->catfile($examples_dir, $file),
            "cite -> livre: examples/$file");
    }

    # ------------------------------------------------------------------
    # [2] Couverture complete de la bibliotheque + compte exact
    # ------------------------------------------------------------------
    opendir my $dh, $examples_dir or die "cannot open $examples_dir: $!";
    my @shipped = sort grep { /\.(?:pl|py|tcl)$/ } readdir $dh;
    closedir $dh;

    for my $file (@shipped) {
        $assert->ok($cited{$file},
            "livre -> cite: examples/$file est couvert par le cookbook");
    }

    my %words = (11 => 'eleven', 12 => 'twelve', 13 => 'thirteen',
                 14 => 'fourteen', 15 => 'fifteen', 16 => 'sixteen');
    my $count_word = $words{ scalar @shipped } || scalar @shipped;
    $assert->like($cookbook, qr/\Q$count_word\E shipped scripts/,
        'le compte en toutes lettres correspond au nombre reel d\'exemples');

    # ------------------------------------------------------------------
    # [3] Invariants techniques croises avec les sources
    # ------------------------------------------------------------------
    {
        # Tableau des champs par evenement <-> whitelist du contexte coeur.
        my $core = _slurp_736(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
        my ($ctx_keys) = $core =~ /for my \$key \(qw\(([^)]+)\)\) \{/;
        $ctx_keys ||= '';
        for my $field (qw(ident host message topic kicked)) {
            $assert->ok($ctx_keys =~ /\b$field\b/,
                "coeur: le champ '$field' du tableau cookbook est bien transmis");
        }
        $assert->like($cookbook, qr/\|\s*`kick`\s*\|.*`kicked`.*\|/,
            'cookbook: la ligne kick documente le champ kicked');

        # Charset des noms de timers <-> garde mb235 du runner d'actions.
        my $ar = _slurp_736(File::Spec->catfile('Mediabot', 'ScriptActionRunner.pm'));
        $assert->like($cookbook, qr/\[A-Za-z0-9_\.-\]/,
            'cookbook: charset des noms de timers cite');
        $assert->like($ar, qr/A-Za-z0-9_/,
            'runner: le charset cite correspond a une garde reelle');

        # Regle « resserrer seulement » <-> les deux references configurables.
        for my $pair ([ 'remind.pl', qr/\$configured <= MAX_DELAY/ ],
                      [ 'countdown.py', qr/configured <= MAX_SECONDS/ ]) {
            my ($file, $re) = @$pair;
            my $src = _slurp_736(File::Spec->catfile($examples_dir, $file));
            $assert->like($src, $re,
                "$file: la borne configurable est plafonnee par le protocole (regle du cookbook)");
        }
    }

    # ------------------------------------------------------------------
    # [4] Renvois croises README <-> cookbook
    # ------------------------------------------------------------------
    $assert->like($readme, qr/\[COOKBOOK\.md\]\(COOKBOOK\.md\)/,
        'README: renvoi vers le cookbook');
    $assert->like($cookbook, qr/\[README\]\(README\.md\)/,
        'cookbook: renvoi vers le README');
    $assert->like($cookbook, qr/mediabot-script-v1/,
        'cookbook: nomme le protocole');
};
