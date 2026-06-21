# t/cases/528_youtube_live_duration_guard.t
# =============================================================================
# mb315 — Affichage des durées YouTube nulles (lives / premières).
#
# YouTube renvoie contentDetails.duration = "PT0S" pour un live en cours ou une
# première à venir. _yt_format_duration() doit renvoyer '' dans ce cas (pas
# "0s"), et displayYoutubeDetails() doit alors OMETTRE le bloc durée plutôt que
# d'émettre un slot vide encadré de séparateurs orphelins (« Titre -  - views »).
#
# youtubeSearch_ctx() appliquait déjà cette garde (if $dur_disp ne ''). mb315
# aligne displayYoutubeDetails() dessus en passant par le helper partagé.
#
# Le test extrait _yt_format_duration() du source et l'exécute en isolation
# (la sub n'utilise que du Perl core), pour vérifier le contrat réellement, et
# vérifie par scan de source que displayYoutubeDetails() garde le bloc durée.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_528 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Extrait le texte d'une sub nommée (équilibrage naïf d'accolades suffisant ici).
sub _extract_sub_528 {
    my ($src, $name) = @_;
    return undef unless $src =~ /(sub\s+\Q$name\E\s*\{)/;
    my $start = $-[0];
    my $i     = index($src, '{', $start);
    return undef if $i < 0;
    my $depth = 0;
    for (my $p = $i; $p < length($src); $p++) {
        my $c = substr($src, $p, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        return substr($src, $start, $p - $start + 1) if $depth == 0;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_528(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );

    # --- 1. Contrat réel de _yt_format_duration() ---------------------------
    my $sub_text = _extract_sub_528($src, '_yt_format_duration');
    $assert->ok(
        defined $sub_text && $sub_text ne '',
        '_yt_format_duration source extrait'
    );

    my $fmt;
    {
        no strict; no warnings;
        $fmt = eval "package T528; $sub_text; \\&T528::_yt_format_duration";
    }
    $assert->ok(ref($fmt) eq 'CODE', '_yt_format_duration compilé en isolation');

    $assert->is($fmt->('PT0S'),       '',              'PT0S (live) → durée vide');
    $assert->is($fmt->(''),           '',              'durée absente → vide');
    $assert->is($fmt->('PT45S'),      '45s',           'PT45S → 45s');
    $assert->is($fmt->('PT5M30S'),    '5mn 30s',       'PT5M30S → 5mn 30s');
    $assert->is($fmt->('PT1H23M45S'), '1h 23mn 45s',   'PT1H23M45S → 1h 23mn 45s');
    $assert->is($fmt->('PT2H'),       '2h',            'PT2H → 2h');

    # --- 2. displayYoutubeDetails() garde le bloc durée ---------------------
    my $display = _extract_sub_528($src, 'displayYoutubeDetails');
    $assert->ok(
        defined $display && $display ne '',
        'displayYoutubeDetails source extrait'
    );

    $assert->like(
        $display,
        qr/my\s+\$sDisplayDuration\s*=\s*_yt_format_duration\(\$sDuration\);/,
        'displayYoutubeDetails passe par le helper partagé'
    );

    $assert->like(
        $display,
        qr/if\s*\(\s*defined\s+\$sDisplayDuration\s*&&\s*\$sDisplayDuration\s+ne\s+''\s*\)/,
        'displayYoutubeDetails garde le bloc durée quand elle est vide'
    );

    $assert->unlike(
        $display,
        qr/\$raw\s*=~\s*s\/\^PT\//,
        'displayYoutubeDetails ne re-code plus le parse ISO 8601 inline'
    );
};
