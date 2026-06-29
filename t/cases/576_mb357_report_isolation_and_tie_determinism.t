# t/cases/576_mb357_report_isolation_and_tie_determinism.t
# =============================================================================
# mb357 — Robustesse et déterminisme des rapports daily/weekly.
#
# Deux points :
#  1) Isolation des échecs. Avant, le daily n'avait aucune protection par canal :
#     un die DB (RaiseError, coupure, table absente) avortait toute la boucle et
#     privait les canaux suivants de rapport. Le weekly isolait par canal mais
#     ses deux sections partageaient un seul eval (un échec "speakers" tuait le
#     "karma"). mb357 : eval par canal (daily) + eval par SECTION (daily+weekly).
#  2) Égalités de classement. `ORDER BY cnt DESC LIMIT 3` rend un ordre arbitraire
#     entre ex æquo -> top 3 instable. mb357 ajoute un départage déterministe
#     `, nick ASC` aux 4 requêtes de classement.
#
# Pas de DBI réel : (a) sémantique du tri déterministe, (b) scan de source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Tri déterministe équivalent à "ORDER BY cnt DESC, nick ASC LIMIT 3".
sub _top3 {
    my (@rows) = @_;
    my @sorted = sort {
        $b->{cnt} <=> $a->{cnt}     # cnt décroissant
            or
        $a->{nick} cmp $b->{nick}   # puis nick croissant (départage stable)
    } @rows;
    return [ map { "$_->{nick}($_->{cnt})" } @sorted[0 .. ($#sorted < 2 ? $#sorted : 2)] ];
}

sub _slurp_576 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Déterminisme du classement -----------------------------------
    # 4 nicks, dont 3 ex æquo à 5 : sans départage, l'ordre et la coupe à 3
    # seraient arbitraires ; avec "nick ASC", c'est stable et prévisible.
    my @rows = (
        { nick => 'delta', cnt => 5 },
        { nick => 'alpha', cnt => 5 },
        { nick => 'charlie', cnt => 9 },
        { nick => 'bravo', cnt => 5 },
    );
    # Le tri doit être indépendant de l'ordre d'entrée : on mélange et on revérifie.
    my $expected = 'charlie(9)|alpha(5)|bravo(5)';   # 9 d'abord, puis 5 par ordre alpha
    $assert->is(join('|', @{ _top3(@rows) }), $expected, 'top3 déterministe (cnt DESC, nick ASC)');
    my @shuffled = reverse @rows;
    $assert->is(join('|', @{ _top3(@shuffled) }), $expected, 'top3 identique quel que soit l\'ordre d\'entrée');
    # 'delta' (5, mais alphabétiquement après bravo) est exclu de façon déterministe.
    $assert->ok(!(grep { $_ eq 'delta(5)' } @{ _top3(@rows) }), 'coupe à LIMIT 3 déterministe (delta exclu)');

    # --- 2. Scan source : 4 départages -----------------------------------
    my $main = _slurp_576(File::Spec->catfile('.', 'mediabot.pl'));
    my $n_speakers = () = $main =~ /ORDER BY cnt DESC, cl\.nick ASC LIMIT 3/g;
    $assert->is($n_speakers, 2, 'speakers (daily+weekly): départage cl.nick ASC');
    $assert->like($main, qr/ORDER BY ABS\(net\) DESC, nick ASC LIMIT 3/,    'karma daily: départage nick ASC');
    $assert->like($main, qr/ORDER BY ABS\(net\) DESC, kl\.nick ASC LIMIT 3/, 'karma weekly: départage kl.nick ASC');

    # --- 3. Scan source : isolation par section --------------------------
    my ($daily)  = $main =~ /(name\s*=>\s*'daily_channel_report'.*?autostart)/s;  $daily  //= '';
    my ($weekly) = $main =~ /(name\s*=>\s*'weekly_channel_report'.*?autostart)/s; $weekly //= '';

    $assert->like($daily, qr/speakers section failed for/,  'daily: section speakers isolée (log dédié)');
    $assert->like($daily, qr/karma section failed for/,     'daily: section karma isolée (log dédié)');
    $assert->like($daily, qr/channel \$chan failed/,        'daily: isolation par canal (log dédié)');
    $assert->like($weekly, qr/speakers section failed for/, 'weekly: section speakers isolée');
    $assert->like($weekly, qr/karma section failed for/,    'weekly: section karma isolée');

    # Le daily ne doit plus utiliser "next" nu dans la boucle (remplacé par if),
    # car le corps est désormais sous eval (next dans eval = warning/bug).
    $assert->unlike($daily, qr/\n\s*next unless \@top_msgs/, 'daily: plus de "next" sous eval');

    $assert->like($main, qr/mb357-B1/, 'tag mb357-B1 présent');
};
