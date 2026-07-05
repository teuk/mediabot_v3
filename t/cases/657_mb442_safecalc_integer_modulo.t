# t/cases/657_mb442_safecalc_integer_modulo.t
# =============================================================================
# mb442 — L'opérateur % de !calc refuse les opérandes non entiers.
#
# Perl calcule % sur des ENTIERS et tronque silencieusement des opérandes
# flottants (10.5 % 3 -> 10 % 3 = 1), une perte de données muette incohérente
# avec la rigueur de SafeCalc (qui die sur overflow / non-fini / domaine
# invalide). mb442 : % exige des opérandes entiers et renvoie vers fmod() pour
# le modulo flottant. Le modulo entier (convention Perl) reste inchangé.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_657 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    require Mediabot::SafeCalc;
    my $eval = sub {
        my ($expr) = @_;
        my $r = eval { Mediabot::SafeCalc::evaluate_expression($expr) };
        return ($@ ? undef : $r, $@);
    };

    # --- 1. Modulo entier inchangé ----------------------------------------
    my ($v, $e);
    ($v, $e) = $eval->('7 % 3');   $assert->is($v, 1, '7 % 3 = 1');
    ($v, $e) = $eval->('10 % 4');  $assert->is($v, 2, '10 % 4 = 2');
    ($v, $e) = $eval->('-7 % 3');  $assert->is($v, 2, '-7 % 3 = 2 (convention Perl inchangée)');

    # --- 2. Opérandes flottants refusés -----------------------------------
    ($v, $e) = $eval->('10.5 % 3');
    $assert->ok(defined $e && $e =~ /integer operands/, 'dividende flottant refusé');
    ($v, $e) = $eval->('10 % 2.5');
    $assert->ok(defined $e && $e =~ /integer operands/, 'diviseur flottant refusé');
    ($v, $e) = $eval->('10.5 % 3');
    $assert->ok(defined $e && $e =~ /fmod/, 'message renvoie vers fmod');

    # --- 3. fmod reste disponible pour le modulo flottant -----------------
    ($v, $e) = $eval->('fmod(10.5, 3)');
    $assert->ok(abs($v - 1.5) < 1e-9, 'fmod(10.5, 3) = 1.5');

    # Division par zéro toujours prioritaire / gérée
    ($v, $e) = $eval->('10 % 0');
    $assert->ok(defined $e && $e =~ /zero/i, '10 % 0 -> division par zéro');

    # --- 4. Câblage réel ---------------------------------------------------
    my $src = _slurp_657(File::Spec->catfile('.', 'Mediabot', 'SafeCalc.pm'));
    $assert->like($src, qr/Modulo requires integer operands/, 'garde présente');
    $assert->like($src, qr/\$value != int\(\$value\) \|\| \$right != int\(\$right\)/,
        'détection des opérandes non entiers');
    $assert->like($src, qr/mb442-B1/, 'tag mb442-B1');
};
