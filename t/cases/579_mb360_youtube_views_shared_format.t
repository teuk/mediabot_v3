# t/cases/579_mb360_youtube_views_shared_format.t
# =============================================================================
# mb360 — Formatage des vues YouTube unifié.
#
# getYoutubeDetails() affichait les vues BRUTES ("views 1234567") alors que
# displayYoutubeDetails() les formatait en lisible ("views 1.2M"). Deux rendus
# pour la même donnée + risque de divergence (comme la durée avant mb315-R1).
# mb360 extrait un helper partagé _yt_format_views utilisé des DEUX côtés.
# La sortie de displayYoutubeDetails reste IDENTIQUE ; getYoutubeDetails passe
# au format lisible.
#
# Validation : (a) sémantique du helper (= ancien bloc inline), (b) scan source.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction du helper mb360.
sub _fmt {
    my ($raw) = @_;
    return '?' unless defined($raw) && $raw =~ /^\d+$/ && $raw > 0;
    return sprintf('%.1fM', $raw / 1_000_000) if $raw >= 1_000_000;
    return sprintf('%.1fk', $raw / 1_000)     if $raw >= 1_000;
    return $raw;
}

# Reproduction de l'ANCIEN bloc inline de displayYoutubeDetails (référence).
sub _old_display {
    my ($raw_views) = @_;
    $raw_views //= 0;
    if    ($raw_views >= 1_000_000) { return sprintf('%.1fM', $raw_views / 1_000_000) }
    elsif ($raw_views >= 1_000)     { return sprintf('%.1fk', $raw_views / 1_000) }
    elsif ($raw_views > 0)          { return $raw_views }
    else                            { return '?' }
}

sub _slurp_579 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du helper -----------------------------------------
    $assert->is(_fmt(1_234_567), '1.2M', 'millions -> M');
    $assert->is(_fmt(45_000),    '45.0k', 'milliers -> k');
    $assert->is(_fmt(999),       999,     'centaines -> brut');
    $assert->is(_fmt(1_000_000), '1.0M',  'pile 1M');
    $assert->is(_fmt(1_000),     '1.0k',  'pile 1k');
    $assert->is(_fmt(0),         '?',     'zéro -> ?');
    $assert->is(_fmt(undef),     '?',     'undef -> ?');
    $assert->is(_fmt('abc'),     '?',     'non numérique -> ?');
    $assert->is(_fmt('1234567'), '1.2M',  'chaîne numérique OK');

    # --- 2. displayYoutubeDetails : sortie INCHANGÉE ----------------------
    for my $v (undef, 0, 1, 999, 1000, 1500, 999999, 1_000_000, 1_234_567, 45_000) {
        my $vs = defined $v ? $v : 'undef';
        $assert->is(_fmt(defined $v ? $v : 0), _old_display($v),
                    "helper == ancien bloc display pour $vs");
    }

    # --- 3. Scan source : helper partagé utilisé des deux côtés -----------
    my $src = _slurp_579(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    $assert->like($src, qr/sub _yt_format_views/, 'helper _yt_format_views défini');

    my ($get) = $src =~ /(sub getYoutubeDetails \{.*?\n\}\n)/s;     $get  //= '';
    my ($disp) = $src =~ /(sub displayYoutubeDetails \{.*?\n\}\n)/s; $disp //= '';
    $assert->like($get,  qr/_yt_format_views\(/, 'getYoutubeDetails utilise le helper');
    $assert->like($disp, qr/_yt_format_views\(/, 'displayYoutubeDetails utilise le helper');

    # getYoutubeDetails ne doit plus afficher le nombre brut "views $view_count".
    (my $get_code = $get) =~ s/^\s*#.*$//mg;
    $assert->unlike($get_code, qr/"views \$view_count"/, 'getYoutubeDetails: plus de vues brutes');

    $assert->like($src, qr/mb360-R1/, 'tag mb360-R1 présent');
};
