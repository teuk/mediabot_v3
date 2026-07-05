# t/cases/676_mb463_duration_functions_coverage.t
# =============================================================================
# mb463 — Couverture réelle des fonctions de durée (jusqu'ici sans test).
#
# Trois fonctions pures et auto-contenues, critiques mais non couvertes :
#   - ChannelBan::parse_duration            (durée de ban -> secondes)
#   - External::Spotify::_spotify_duration_from_ms   (ms -> "…m …s")
#   - External::Spotify::_spotify_duration_from_iso  (ISO8601 -> "…m …s")
#
# Ce test n'utilise PAS de réplique : il EXTRAIT le corps réel de chaque sub
# depuis le fichier source et l'exécute (eval). Il teste donc le vrai code et
# se ré-extrait à chaque run, donc il protège contre une régression future
# (un refactor qui casse le format ou la décomposition fera échouer la suite).
#
# Aucun de ces subs ne charge le module complet (ils n'appellent ni $self-> ni
# d'autres subs), ce qui permet l'exécution isolée en sandbox.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

my $EVAL_SEQ = 0;

# Extrait `sub NAME { ... }` du fichier et l'installe sous un nom neutre dans un
# package jetable, puis renvoie une coderef vers le vrai code.
sub _load_real_sub {
    my ($relpath, $name) = @_;
    my $path = File::Spec->catfile('.', split(m{/}, $relpath));
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; my $src = <$fh>;
    my ($body) = $src =~ /(^sub \Q$name\E \{.*?\n\}\n)/ms;
    die "sub $name not found in $relpath" unless $body;
    my $pkg = 'T_mb463_' . (++$EVAL_SEQ);
    my $code;
    {
        no strict; no warnings;
        $code = eval "package $pkg; use strict; use warnings;\n$body\n\\&${pkg}::${name};";
    }
    die "eval of $name failed: $@" if $@ || !$code;
    return $code;
}

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # 1. ChannelBan::parse_duration($self, $text) — $self ignoré
    # -------------------------------------------------------------------------
    my $pd = _load_real_sub('Mediabot/ChannelBan.pm', 'parse_duration');
    $assert->ok(defined $pd, 'parse_duration extraite et compilée');

    my @pd_cases = (
        # [ input,        [secs, label, err_defined?] ]
        [ '',    [0, 'permanent', 0] ],
        [ 'perm',      [0, 'permanent', 0] ],
        [ 'permanent', [0, 'permanent', 0] ],
        [ 'never',     [0, 'permanent', 0] ],
        [ '5',    [300, '5m', 0] ],     # nombre nu = minutes
        [ '10m',  [600, '10m', 0] ],
        [ '2h',   [7200, '2h', 0] ],
        [ '3d',   [259200, '3d', 0] ],
        [ '1w',   [604800, '1w', 0] ],
    );
    for my $c (@pd_cases) {
        my ($in, $exp) = @$c;
        my ($secs, $label, $err) = $pd->(undef, $in);
        $assert->is($secs,  $exp->[0], "parse_duration('$in') secondes = $exp->[0]");
        $assert->is($label, $exp->[1], "parse_duration('$in') label = $exp->[1]");
        $assert->ok(!defined($err), "parse_duration('$in') sans erreur");
    }
    # Cas d'erreur : 0, 0m, invalide -> erreur définie, secondes undef
    for my $bad ('0', '0m', 'xyz', '5x') {
        my ($secs, $label, $err) = $pd->(undef, $bad);
        $assert->ok(!defined($secs) && defined($err),
            "parse_duration('$bad') rejeté (erreur définie)");
    }

    # -------------------------------------------------------------------------
    # 2. _spotify_duration_from_ms($ms)
    # -------------------------------------------------------------------------
    my $dm = _load_real_sub('Mediabot/External/Spotify.pm', '_spotify_duration_from_ms');
    $assert->ok(defined $dm, '_spotify_duration_from_ms extraite');
    $assert->ok(!defined $dm->(undef),   'ms undef -> undef');
    $assert->ok(!defined $dm->('abc'),   'ms non numérique -> undef');
    $assert->ok(!defined $dm->('0'),     'ms 0 -> undef (durée nulle)');
    $assert->is($dm->('5000'),    '0m 05s',   '5000ms -> "0m 05s"');
    $assert->is($dm->('65000'),   '1m 05s',   '65000ms -> "1m 05s"');
    $assert->is($dm->('3661000'), '1h01m01s', '3661000ms -> "1h01m01s"');

    # -------------------------------------------------------------------------
    # 3. _spotify_duration_from_iso($d)
    # -------------------------------------------------------------------------
    my $di = _load_real_sub('Mediabot/External/Spotify.pm', '_spotify_duration_from_iso');
    $assert->ok(defined $di, '_spotify_duration_from_iso extraite');
    $assert->ok(!defined $di->(undef),    'iso undef -> undef');
    $assert->ok(!defined $di->('PT0S'),   'PT0S (tout nul) -> undef');
    $assert->ok(!defined $di->('garbage'),'iso invalide -> undef');
    $assert->is($di->('PT5M'),     '5m 00s',   'PT5M -> "5m 00s"');
    $assert->is($di->('PT1H2M3S'), '1h02m03s', 'PT1H2M3S -> "1h02m03s"');
    $assert->is($di->('PT45S'),    '0m 45s',   'PT45S -> "0m 45s"');
};
