# t/cases/616_mb398_youtube_duration_days.t
# =============================================================================
# mb398 — Les durées YouTube > 24 h (composant D) sont parsées.
#
# L'API YouTube renvoie "P1DT2H3M4S" pour les contenus > 24 h (streams,
# archives). L'ancien parsing ("PT" strip + regex H/M/S sur toute la chaîne)
# ignorait le D : affichage et _yt_duration_seconds faux de 86400 s par jour ;
# "P3D" seul donnait '' / 0. mb398 introduit _yt_parse_duration (partagé par
# _yt_format_duration et _yt_duration_seconds), qui ne lit le M qu'APRÈS le T
# (avant le T, M = mois en ISO-8601).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_616 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _extract_sub_616 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\}\n)/s;
    return $body // '';
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_616(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));

    my $parse_text  = _extract_sub_616($src, '_yt_parse_duration');
    my $fmt_text    = _extract_sub_616($src, '_yt_format_duration');
    my $secs_text   = _extract_sub_616($src, '_yt_duration_seconds');
    $assert->ok($parse_text ne '', '_yt_parse_duration présent');

    my ($fmt, $secs);
    {
        no strict; no warnings;
        $fmt  = eval "package T616; $parse_text; $fmt_text; \\&T616::_yt_format_duration";
        $secs = eval "package T616; $secs_text; \\&T616::_yt_duration_seconds";
    }
    $assert->ok(ref($fmt)  eq 'CODE', '_yt_format_duration compilé en isolation');
    $assert->ok(ref($secs) eq 'CODE', '_yt_duration_seconds compilé en isolation');

    # --- comportement inchangé pour les durées classiques ------------------
    $assert->is($fmt->('PT4M13S'),   '4mn 13s',     'PT4M13S inchangé');
    $assert->is($fmt->('PT1H2M3S'),  '1h 2mn 3s',   'PT1H2M3S inchangé');
    $assert->is($fmt->('PT45S'),     '45s',         'PT45S inchangé');
    $assert->is($fmt->(''),          '',            'vide -> \'\'');
    $assert->is($fmt->('PT0S'),      '',            'PT0S -> \'\' (live, contrat mb315)');
    $assert->is($secs->('PT1H2M3S'), 3723,          'secondes classiques inchangées');

    # --- le composant jours est désormais pris en compte --------------------
    $assert->is($fmt->('P1DT2H3M4S'), '1d 2h 3mn 4s', 'P1DT2H3M4S affiche les jours');
    $assert->is($secs->('P1DT2H3M4S'), 93784,         'P1DT2H3M4S = 93784 s (plus 7384)');
    $assert->is($fmt->('P3D'),         '3d',          'P3D seul affiché (plus \'\')');
    $assert->is($secs->('P3D'),        259200,        'P3D = 259200 s (plus 0)');

    # --- M avant le T = mois, jamais des minutes ----------------------------
    $assert->is($secs->('P1M'), 0, 'P1M (1 mois, pas sur YouTube) ignoré, pas 60 s');

    # --- câblage : les deux fonctions passent par le parseur partagé --------
    $assert->like($fmt_text,  qr/_yt_parse_duration\(/, 'format délègue au parseur partagé');
    $assert->like($secs_text, qr/_yt_parse_duration\(/, 'seconds délègue au parseur partagé');
    $assert->like($src, qr/mb398-B1/, 'tag mb398-B1');
};
