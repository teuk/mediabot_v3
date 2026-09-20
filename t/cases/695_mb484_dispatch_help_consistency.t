# t/cases/695_mb484_dispatch_help_consistency.t
# =============================================================================
# mb484 — Garde de cohérence : le dispatch public et la documentation help
#         restent synchronisés.
#
#   [1] tout handler public du registre a une entrée dans le heredoc help ;
#   [2] toute entrée help de niveau 'public' correspond à une commande du
#       dispatch (pas d'entrée fantôme qui trompe l'utilisateur).
#
# Invariant vérifié comme parfait sur ce snap (0/0). Ce test le VERROUILLE :
# un futur ajout de commande sans help (ou un help orphelin) échouera ici,
# avant la release 3.3.
#
# Note : les alias enregistrés hors du catalogue (ex. quelques alias définis
# ailleurs) et les commandes non-public sont hors périmètre de [2] par design.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_695 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_695(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    # --- extraire les handlers publics natifs du registre --------------------
    my ($block) = $src =~
        /sub _builtin_public_command_handlers \{\s*return \((.*?)\n    \);\s*\}/s;
    $assert->ok(defined $block && $block ne '',
        'catalogue de handlers publics localisé');
    my %dispatch;
    while ($block =~ /^\s*'?([a-z0-9_]+)'?\s*=>\s*sub/mg) { $dispatch{$1} = 1; }
    $assert->ok(scalar(keys %dispatch) > 100,
        'catalogue public non vide (>100 commandes)');

    # --- extraire les entrées du heredoc help --------------------------------
    my ($help_block) = $src =~ /MEDIABOT_INTERNAL_HELP(.*?)MEDIABOT_INTERNAL_HELP/s;
    $assert->ok(defined $help_block && $help_block ne '', 'heredoc help localisé');
    my (%help_all, %help_public);
    for my $line (split /\n/, $help_block // '') {
        next unless $line =~ /^([a-z0-9_]+)\|/;
        my $cmd = $1;
        $help_all{$cmd} = 1;
        $help_public{$cmd} = 1 if $line =~ /^[a-z0-9_]+\|.*\|public\|/;
    }

    # --- [1] toute commande du dispatch a une entrée help --------------------
    my @missing_help = sort grep { !$help_all{$_} } keys %dispatch;
    $assert->is(join(', ', @missing_help), '',
        '[1] toute commande du dispatch public a une entrée help');

    # --- [2] toute entrée help 'public' a une commande de dispatch -----------
    my @ghost = sort grep { !$dispatch{$_} } keys %help_public;
    $assert->is(join(', ', @ghost), '',
        '[2] aucune entrée help publique fantôme (sans commande de dispatch)');

    # --- sanity : quelques commandes récentes bien présentes des deux côtés --
    for my $cmd (qw(recap learn whatis forget factoids factoid convert tell)) {
        $assert->ok($dispatch{$cmd}, "commande '$cmd' dans le dispatch");
        $assert->ok($help_all{$cmd}, "commande '$cmd' documentée");
    }
};
