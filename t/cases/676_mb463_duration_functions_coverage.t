# t/cases/676_mb463_duration_functions_coverage.t
# =============================================================================
# mb463 — Couverture réelle des fonctions de durée (jusqu'ici sans test).
#
# MB1103: ChannelBan parsing is exercised through its real module in cases
# 06/69 and real commands in case 09. Keep only the two independent Spotify
# formatting helpers here; copying one function out of ChannelBan drops its
# validation helpers and no longer exercises the native duration contract.
# No network or bot process is used by these Spotify checks.
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
