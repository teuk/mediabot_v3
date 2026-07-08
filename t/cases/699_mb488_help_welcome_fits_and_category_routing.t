# t/cases/699_mb488_help_welcome_fits_and_category_routing.t
# =============================================================================
# mb488 — Deux bugs constatés en production (capture d'écran de Christophe) :
#
#   BUG 1 : l'écran d'accueil "help" (24 lignes) dépassait le plafond de la
#           file de notices (16) et était TRONQUÉ -> la section navigation
#           disparaissait ("... output truncated"). Corrigé : accueil compact.
#
#   BUG 2 : "help general" (un nom de catégorie affiché dans l'index) répondait
#           "No internal help ... found for 'general'". Corrigé : "help <cat>"
#           route vers la catégorie, sauf si le nom est aussi une commande
#           (alors la commande gagne).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_699 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _extract_699 {
    my ($src, $name) = @_;
    return '' unless $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $1;
}

# le plafond réel de la file de notices, à garder synchronisé
my $NOTICE_QUEUE_CAP = 16;

return sub {
    my ($assert) = @_;

    require Mediabot::Mediabot;
    my $src = _slurp_699(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    # =========================================================================
    # BUG 1 : l'accueil doit tenir sous le plafond de la file (sinon tronqué).
    # =========================================================================
    # On reconstruit l'accueil exactement comme _mbHelpSendWelcome (hors I/O).
    my $cc = '!';
    my @welcome;
    push @welcome, "Mediabot help (x)";
    push @welcome, "Categories (name = command count):";
    push @welcome, Mediabot::_mbHelpCategoryIndexCompact();
    push @welcome, "Navigate:";
    push @welcome, "  ${cc}help <category>      ...";
    push @welcome, "  ${cc}help <command>       ...";
    push @welcome, "  ${cc}help search <term>   ...";
    push @welcome, "  ${cc}help level <role>    ...";
    push @welcome, "  ${cc}help chansets        ...";
    push @welcome, "Docs: ...";

    $assert->ok(scalar(@welcome) <= $NOTICE_QUEUE_CAP,
        "[1] écran d'accueil (" . scalar(@welcome) . " lignes) tient sous le cap ($NOTICE_QUEUE_CAP)");

    # l'index compact tient en très peu de lignes, chacune raisonnable
    my @compact = Mediabot::_mbHelpCategoryIndexCompact();
    $assert->ok(scalar(@compact) <= 3, "[1] index compact <=3 lignes");
    my $too_long = grep { length($_) > 400 } @compact;
    $assert->is($too_long, 0, '[1] aucune ligne d\'index > 400 car');

    # toutes les catégories non vides sont présentes, au format name(N)
    my %cats = Mediabot::_mbHelpBuildCategories();
    my $cj = join(' ', @compact);
    for my $cat (qw(general channel radio factoids admin)) {
        my $n = scalar @{ $cats{$cat} || [] };
        next unless $n;
        $assert->like($cj, qr/\Q$cat\E\(\d+\)/, "[1] index compact contient $cat(N)");
    }

    # le welcome utilise bien l'index compact, pas le détaillé
    my $welcome_sub = _extract_699($src, '_mbHelpSendWelcome');
    $assert->like($welcome_sub, qr/_mbHelpCategoryIndexCompact\(\)/,
        '[1] welcome utilise l\'index compact');
    $assert->unlike($welcome_sub, qr/_mbHelpCategoryIndexLines\(\)/,
        '[1] welcome n\'utilise plus l\'index détaillé (trop long)');

    # =========================================================================
    # BUG 2 : routage "help <catégorie>".
    # =========================================================================
    my $help = _extract_699($src, 'mbHelp_ctx');
    # la branche catégorie doit exister, avant la branche commande
    $assert->like($help,
        qr/exists \$cats\{\$canon\} && !exists \$internal\{\$key\}/,
        '[2] branche "help <catégorie>" présente (commande prioritaire)');
    my $pos_cat = index($help, 'exists $cats{$canon}');
    my $pos_cmd = index($help, 'if ($first ne \'\' && !isIrcChannelTarget($first)) {');
    $assert->ok($pos_cat >= 0 && $pos_cmd >= 0 && $pos_cat < $pos_cmd,
        '[2] la branche catégorie est évaluée avant la branche commande');

    # simulation du routage (même logique que le code)
    my %aliases  = Mediabot::_mbHelpCategoryAliases();
    my %internal = Mediabot::_mbHelpInternalCommands();
    my $route = sub {
        my ($first) = @_;
        my $key = lc $first; $key =~ s/[\s-]+/_/g;
        my $canon = exists $aliases{$key} ? $aliases{$key} : $key;
        return "cat:$canon" if exists $cats{$canon} && !exists $internal{$key};
        return "cmd:$key"   if exists $internal{$key};
        return "unknown";
    };

    # noms de catégorie NON-commandes -> catégorie
    for my $c (qw(general radio channel moderation dynamic admin)) {
        $assert->is($route->($c), "cat:$c", "[2] help $c -> catégorie");
    }
    # collisions (nom = commande) -> la commande gagne
    for my $c (qw(stats factoids learn convert auth)) {
        $assert->is($route->($c), "cmd:$c", "[2] help $c -> commande (collision)");
    }
    # inconnu inchangé
    $assert->is($route->('zzznope'), 'unknown', '[2] nom inconnu -> non routé');
};
