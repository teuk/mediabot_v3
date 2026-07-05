# t/cases/664_mb449_startup_integrity_check.t
# =============================================================================
# mb449 — Contrôle d'intégrité de l'installation au démarrage.
#
# Crash réel (instance Undernet, 04/07/2026) : déploiement partiel = mediabot.pl
# plus récent que Mediabot/*.pm -> "Can't locate object method
# hailo_record_activity" au premier message privé -> boucle IO::Async tuée ->
# bot mort. `perl -c` ne détecte pas ce désync (résolution runtime). mb449 :
# au boot, mediabot.pl inventorie les méthodes qu'il appelle sur $mediabot
# (auto-dérivé de son propre source) et vérifie Mediabot->can() pour chacune ;
# échec immédiat et actionnable si l'arbre est désynchronisé.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_664 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Reproduction fidèle de l'extraction (doit rester synchrone avec mediabot.pl).
sub _extract_methods_664 {
    my ($path) = @_;
    my %m;
    open my $fh, '<', $path or die "$path: $!";
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        $m{$1} = 1 while $line =~ /\$mediabot->([a-zA-Z_][A-Za-z0-9_]*)\(/g;
    }
    close $fh;
    return \%m;
}

return sub {
    my ($assert) = @_;

    # --- 1. Comportemental : inventaire réel + résolution réelle -----------
    require Mediabot::Mediabot;

    my $methods = _extract_methods_664('mediabot.pl');
    $assert->ok(scalar(keys %$methods) >= 60,
        'inventaire substantiel (>= 60 méthodes cross-module)');
    $assert->ok($methods->{hailo_record_activity},
        'la méthode du crash Undernet est dans l\'inventaire');

    my @missing = grep { !Mediabot->can($_) } sort keys %$methods;
    $assert->is(scalar @missing, 0,
        'arbre sain : toutes les méthodes se résolvent (0 faux positif)')
        or $assert->ok(0, "manquantes: @missing");

    # Simulation du désync : retirer la méthode du namespace -> détectée.
    {
        no strict 'refs';
        local *{'Mediabot::hailo_record_activity'};
        delete $Mediabot::{hailo_record_activity};
        my @miss2 = grep { !Mediabot->can($_) } sort keys %$methods;
        $assert->ok((grep { $_ eq 'hailo_record_activity' } @miss2),
            'simulation Hailo.pm ancien : le désync est détecté');
    }
    # Restaurer le namespace pour la suite des tests du harness.
    { no strict 'refs'; *{'Mediabot::hailo_record_activity'} = \&Mediabot::Hailo::hailo_record_activity; }
    $assert->ok(Mediabot->can('hailo_record_activity'), 'namespace restauré');

    # --- 2. Câblage réel dans mediabot.pl ----------------------------------
    my $src = _slurp_664('mediabot.pl');
    (my $code = $src) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/\$called_methods\{\$1\} = 1/,
        'inventaire auto-dérivé du source');
    $assert->like($code, qr/grep \{ !Mediabot->can\(\$_\) \} sort keys %called_methods/,
        'résolution vérifiée via Mediabot->can');
    $assert->like($code, qr/installation mismatch/,
        'message fatal actionnable');
    $assert->like($code, qr/exit 1;/, 'échec immédiat (fail fast)');
    # Le check tourne AVANT la boucle IRC.
    my $check_pos = index($code, 'installation mismatch');
    my $loop_pos  = index($code, '$loop->run');
    $assert->ok($check_pos >= 0 && ($loop_pos < 0 || $check_pos < $loop_pos),
        'contrôle exécuté avant loop->run');

    $assert->like($src, qr/mb449-B1/, 'tag mb449-B1');
};
