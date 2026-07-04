# t/cases/638_mb423_youtube_views_single_formatter.t
# =============================================================================
# mb423 — Un seul formateur de vues YouTube (_yt_format_views, mb360).
#
# Deux formateurs inline subsistaient : _youtube_search_format_entry (identique
# au partagé, mais dupliqué) et ytSearch_ctx, qui DIVERGEAIT (%.0fK majuscule
# sans décimale au lieu de %.1fk). mb423 route les deux via _yt_format_views —
# un seul point de vérité, format cohérent. Les vues inconnues ('?' du
# formateur) sont omises de la ligne de recherche plutôt qu'affichées.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_638 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_638(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));

    # --- 1. Le formateur partagé, exécuté ---------------------------------
    my ($body) = $src =~ /(sub _yt_format_views \{.*?\n\}\n)/s;
    my $fn;
    { no strict; no warnings; $fn = eval "package T638; $body; \\&T638::_yt_format_views"; }
    $assert->ok(ref($fn) eq 'CODE', '_yt_format_views compilé');
    $assert->is($fn->(0),         '?',     '0 vue -> ?');
    $assert->is($fn->(5),         '5',     '5 -> 5');
    $assert->is($fn->(1234),      '1.2k',  '1234 -> 1.2k (minuscule, 1 décimale)');
    $assert->is($fn->(1_200_000), '1.2M',  '1.2M');
    $assert->is($fn->(undef),     '?',     'undef -> ?');
    $assert->is($fn->('x'),       '?',     'non numérique -> ?');

    # --- 2. Plus aucun formateur de vues inline ---------------------------
    # Le seul sprintf('%.1f[Mk]') autorisé est DANS _yt_format_views.
    (my $code = $src) =~ s/^\s*#.*$//mg;
    my $shared = $body;
    (my $rest = $code) =~ s/\Q$shared\E//;   # retirer le corps du helper
    $assert->unlike($rest, qr/sprintf\('%\.[01]f[MkK]'/,
        'aucun formateur de vues inline hors _yt_format_views');
    $assert->unlike($rest, qr/%\.0fK/, 'le %.0fK divergent de ytSearch a disparu');

    # --- 3. Les deux sites appellent le helper ----------------------------
    my ($entry) = $src =~ /(sub _youtube_search_format_entry \{.*?\n\}\n)/s; $entry //= '';
    $assert->like($entry, qr/_yt_format_views\(\$info->\{views\}\)/,
        '_youtube_search_format_entry utilise le helper');
    my ($ysearch) = $src =~ /(sub ytSearch_ctx \{.*?\n\}\n)/s; $ysearch //= '';
    $assert->like($ysearch, qr/_yt_format_views\(\$v->\{statistics\}\{viewCount\}\)/,
        'ytSearch_ctx utilise le helper');
    $assert->like($ysearch, qr/\$meta->\{views\} ne '\?'/,
        'ytSearch omet les vues inconnues (?)');

    $assert->like($src, qr/mb423-R1/, 'tag mb423-R1');
};
