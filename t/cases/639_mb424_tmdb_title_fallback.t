# t/cases/639_mb424_tmdb_title_fallback.t
# =============================================================================
# mb424 — TMDB : titre robuste + type dérivé de media_type.
#
# TMDB renvoie parfois un titre LOCALISÉ vide (film sans traduction dans la
# langue demandée) alors que original_title/original_name est rempli :
# l'ancien "$info->{title} || $info->{name}" affichait "Unknown title". Et le
# type était déduit de exists($info->{title}) au lieu du media_type déjà
# validé par get_tmdb_info. mb424 déroule les champs de titre et dérive le
# type de media_type (source de vérité).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_639 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_639(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));

    # --- 1. Le helper de titre, exécuté ------------------------------------
    my ($body) = $src =~ /(sub _tmdb_first_nonempty \{.*?\n\}\n)/s;
    my $fn;
    { no strict; no warnings; $fn = eval "package T639; $body; \\&T639::_tmdb_first_nonempty"; }
    $assert->ok(ref($fn) eq 'CODE', '_tmdb_first_nonempty compilé');

    $assert->is($fn->('', undef, 'Le Voyage de Chihiro', undef), 'Le Voyage de Chihiro',
        'titre localisé vide -> original_title');
    $assert->is($fn->(undef, 'Breaking Bad', undef, undef), 'Breaking Bad',
        'série -> name');
    $assert->is($fn->('Inception', '', '', ''), 'Inception', 'titre normal préservé');
    $assert->is($fn->('  Dune  ', undef), 'Dune', 'trim appliqué');
    $assert->ok(!defined $fn->('', undef, '   ', undef), 'tout vide -> undef');
    $assert->ok(!defined $fn->({}, [], undef), 'refs ignorées -> undef');

    # --- 2. Câblage réel dans mbTMDBSearch_ctx -----------------------------
    my ($disp) = $src =~ /(sub mbTMDBSearch_ctx \{.*?\n\}\n)/s; $disp //= '';
    (my $code = $disp) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/_tmdb_first_nonempty\(\s*\$info->\{title\}, \$info->\{name\},/s,
        'titre via _tmdb_first_nonempty (title, name, original_*)');
    $assert->like($code, qr/original_title.*original_name/s,
        'fallback vers les titres originaux');
    $assert->like($code, qr/\(\(\$info->\{media_type\} \/\/ ''\) eq 'tv'\) \? "TV Series" : "Movie"/,
        'type dérivé de media_type (source de vérité)');
    $assert->unlike($code, qr/exists\(\$info->\{title\}\) \? "Movie"/,
        'plus d\'heuristique exists(title)');

    $assert->like($src, qr/mb424-R1/, 'tag mb424-R1');
};
