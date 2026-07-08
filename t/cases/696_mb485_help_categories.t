# t/cases/696_mb485_help_categories.t
# =============================================================================
# mb485 — Help nickel : catégories propres et documentation cohérente.
#
#   [1] les lignes de commentaire du heredoc ne sont plus parsées comme des
#       commandes fantômes (# ... n'apparaît plus dans les catégories) ;
#   [2] catégorie dédiée 'factoids' regroupant learn/whatis/forget/factoids/
#       factoid ;
#   [3] classement explicite prioritaire : les commandes que l'heuristique
#       plaçait mal sont au bon endroit (tell/remind/slap/heatmap/karma*/... hors
#       de 'admin' ; recap -> social ; convert -> stats) ;
#   [4] anti-flood : une grande catégorie est émise en quelques lignes chunkées,
#       pas une par commande.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;

    my %internal = Mediabot::_mbHelpInternalCommands();
    my %cats     = Mediabot::_mbHelpBuildCategories();
    my %labels   = Mediabot::_mbHelpCategoryLabels();

    # --- [1] aucune "commande" fantôme issue d'un commentaire ---------------
    my @ghost = grep { /^#/ || /\s/ } keys %internal;
    $assert->is(join(', ', @ghost), '',
        '[1] aucune entrée help fantôme (commentaire du heredoc)');
    # et aucune catégorie ne contient un token commençant par #
    my @cat_ghost;
    for my $c (keys %cats) {
        push @cat_ghost, grep { /^#/ } @{ $cats{$c} };
    }
    $assert->is(join(', ', @cat_ghost), '', '[1] aucune catégorie ne liste de commentaire');

    # --- [2] catégorie factoids ---------------------------------------------
    $assert->ok(exists $cats{factoids}, '[2] catégorie factoids existe');
    $assert->ok(exists $labels{factoids}, '[2] label factoids défini');
    my %fac = map { $_ => 1 } @{ $cats{factoids} || [] };
    for my $c (qw(learn whatis forget factoids factoid)) {
        $assert->ok($fac{$c}, "[2] '$c' dans la catégorie factoids");
    }

    # --- [3] classement explicite (helper) ----------------------------------
    my %want = (
        recap      => 'social',
        tell       => 'general',
        convert    => 'stats',
        remind     => 'general',
        slap       => 'ai_fun',
        heatmap    => 'stats',
        karmawatch => 'stats',
        monthstats => 'stats',
        pollstatus => 'general',
        learn      => 'factoids',
        forget     => 'factoids',
    );
    for my $cmd (sort keys %want) {
        my $got = Mediabot::_mbHelpCategoryForCommand($cmd, $internal{$cmd} || {});
        $assert->is($got, $want{$cmd}, "[3] '$cmd' -> $want{$cmd}");
    }
    # admin ne doit plus contenir ces commandes publiques
    my %admin = map { $_ => 1 } @{ $cats{admin} || [] };
    for my $c (qw(tell remind slap heatmap karmawatch monthstats)) {
        $assert->ok(!$admin{$c}, "[3] '$c' n'est plus dans admin");
    }

    # --- [4] anti-flood : chunking ------------------------------------------
    # la plus grosse catégorie tient en peu de lignes (<= 5), pas une par cmd.
    my ($biggest) = sort { scalar(@{$cats{$b}}) <=> scalar(@{$cats{$a}}) } keys %cats;
    my $n = scalar @{ $cats{$biggest} };
    my @lines = Mediabot::_mbHelpBuildChunkedList("Commands: ", @{ $cats{$biggest} });
    $assert->ok($n > 20, "[4] catégorie la plus grande a >20 commandes ($biggest=$n)");
    $assert->ok(scalar(@lines) <= 5,
        "[4] chunking anti-flood : $n commandes -> " . scalar(@lines) . " ligne(s) (<=5)");
    # chaque ligne reste sous une longueur IRC raisonnable
    my $too_long = grep { length($_) > 400 } @lines;
    $assert->is($too_long, 0, '[4] aucune ligne de liste > 400 caractères');
};
