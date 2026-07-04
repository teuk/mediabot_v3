# t/cases/637_mb422_ytsearch_duration_days.t
# =============================================================================
# mb422 — ytSearch_ctx affiche les durées via le parseur partagé (jours inclus).
#
# Un SECOND parseur de durée, dupliqué inline dans ytSearch_ctx, souffrait du
# même défaut que mb398 avant correction : composant JOURS ignoré
# (P1DT2H3M4S -> 2:03:04 au lieu de 26:03:04 ; P3D -> 0:00) et lecture du M sur
# toute la chaîne (confusion mois/minutes ISO-8601). mb422 réutilise
# _yt_parse_duration (mb398) et replie les jours dans les heures pour un
# affichage compact.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_637 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Reproduction : parseur partagé + repli jours->heures + format compact.
sub _parse {
    my ($iso) = @_;
    return (0,0,0,0) unless defined $iso && $iso ne '';
    my ($dp,$tp) = $iso =~ /\AP([^Tt]*)(?:[Tt](.*))?\z/;
    return (0,0,0,0) unless defined $dp || defined $tp;
    my ($d)=($dp//'')=~/(\d+)D/i; my ($h)=($tp//'')=~/(\d+)H/i;
    my ($m)=($tp//'')=~/(\d+)M/i; my ($s)=($tp//'')=~/(\d+)S/i;
    return ($d||0,$h||0,$m||0,$s||0);
}
sub _dur {
    my ($iso) = @_;
    my ($dd,$h,$m,$s) = _parse($iso); $h += $dd*24;
    return $h ? sprintf('%d:%02d:%02d',$h,$m,$s) : sprintf('%d:%02d',$m,$s);
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique -----------------------------------------------------
    $assert->is(_dur('PT4M13S'),   '4:13',      'minutes:secondes');
    $assert->is(_dur('PT1H2M3S'),  '1:02:03',   'heures:min:sec');
    $assert->is(_dur('P1DT2H3M4S'),'26:03:04',  'jours repliés dans les heures (plus 2:03:04)');
    $assert->is(_dur('P3D'),       '72:00:00',  'P3D = 72h (plus 0:00)');
    $assert->is(_dur('PT45S'),     '0:45',      'secondes seules');
    $assert->is(_dur('PT0S'),      '0:00',      'zéro');

    # --- 2. Câblage réel : plus de parsing H/M/S inline dans ytSearch_ctx ---
    my $src = _slurp_637(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my ($body) = $src =~ /(sub ytSearch_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/_yt_parse_duration\(\$dur\)/, 'ytSearch réutilise le parseur partagé');
    $assert->like($code, qr/\$h \+= \$dd \* 24;/,          'jours repliés dans les heures');
    $assert->unlike($code, qr/my \(\$h\) = \(\$dur =~/,    'plus de parsing H inline');
    $assert->like($src, qr/mb422-B1/, 'tag mb422-B1');
};
