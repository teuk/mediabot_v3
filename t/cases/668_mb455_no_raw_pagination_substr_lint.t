# t/cases/668_mb455_no_raw_pagination_substr_lint.t
# =============================================================================
# mb455 — Éradication + lint de la troncature de pagination `substr` brute.
#
# L'idiome `$x = substr($x, 0, 357) . '...'` (gardé par `length($x) > 360`)
# tronque des lignes d'affichage à l'OCTET 357 : sur du texte DB accentué
# (octets UTF-8), il peut couper un caractère multi-octets en deux -> séquence
# invalide -> mojibake au point de coupe.
#
# mb454 a converti les 8 sites de DBCommands. mb455 termine le travail sur les
# 11 sites restants (ChannelCommands x3, Helpers x3, LoginCommands x1,
# Partyline x1, UserCommands x3) via le helper partagé truncate_utf8 (mb429),
# et pose un LINT : plus AUCUN `substr($x, 0, 357) . '...'` brut dans le dépôt.
# Toute réintroduction fait échouer la suite.
#
# Le comportement du helper est couvert par 644_mb429 ; ici, lint de source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_668 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

sub _all_sources {
    my @files = glob(File::Spec->catfile('.', 'Mediabot', '*.pm'));
    push @files, glob(File::Spec->catfile('.', 'Mediabot', '*', '*.pm'));
    my $main = File::Spec->catfile('.', 'mediabot.pl');
    push @files, $main if -f $main;
    return @files;
}

return sub {
    my ($assert) = @_;

    # --- 1. LINT repo-wide : plus aucun idiome substr-357 brut ----------------
    my @offenders;
    my $total_convert = 0;
    for my $f (_all_sources()) {
        my $src = _slurp_668($f);
        my $raw = () = $src =~ /substr\(\$\w+, 0, 357\) \. '\.\.\.'/g;
        push @offenders, "$f ($raw)" if $raw;
        $total_convert += () = $src =~ /truncate_utf8\(\$line, 357\)/g;
    }
    $assert->is(scalar(@offenders), 0,
        'aucun `substr($x, 0, 357) . "..."` brut dans le dépôt'
        . (@offenders ? ' — coupables: ' . join(', ', @offenders) : ''));

    # --- 2. Les 11 sites de ce round sont convertis ($line) -------------------
    $assert->ok($total_convert >= 11,
        "au moins 11 troncatures de pagination \$line routées via truncate_utf8 (vu: $total_convert)");

    # --- 3. Comptes par module (mb455) ---------------------------------------
    my %expect = (
        'ChannelCommands.pm' => 3,
        'Helpers.pm'         => 3,
        'LoginCommands.pm'   => 1,
        'Partyline.pm'       => 1,
        'UserCommands.pm'    => 3,
    );
    for my $mod (sort keys %expect) {
        my $src  = _slurp_668(File::Spec->catfile('.', 'Mediabot', $mod));
        my $conv = () = $src =~ /truncate_utf8\(\$line, 357\)/g;
        $assert->ok($conv >= $expect{$mod},
            "$mod: >= $expect{$mod} conversion(s) truncate_utf8(\$line,357) (vu: $conv)");
        # la garde de longueur reste présente (on ne tronque que le trop-long)
        my $guard = () = $src =~ /if \(length\(\$line\) > 360\) \{/g;
        $assert->ok($guard >= $expect{$mod},
            "$mod: garde `length(\$line) > 360` conservée (vu: $guard)");
    }

    # --- 4. DBCommands (mb454) reste converti : non-régression ----------------
    my $db = _slurp_668(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $db_raw = () = $db =~ /substr\(\$\w+, 0, 357\)/g;
    $assert->is($db_raw, 0, 'DBCommands: toujours 0 substr-357 brut (mb454 préservé)');
};
