# t/cases/648_mb433_birthday_feb29_observance.t
# =============================================================================
# mb433 — Les anniversaires du 29 février sont annoncés le 28 février des
# années non bissextiles.
#
# check_birthdays_today() matche le MM-DD du jour. Comme le 29 février n'existe
# pas 3 années sur 4, les personnes nées ce jour-là n'étaient JAMAIS fêtées
# hors année bissextile. mb433 : les années NON bissextiles, le 28 février, on
# observe aussi les anniversaires 02-29 (convention cohérente avec le "prochain
# 29 février valide" de mb399). Les années bissextiles, le 29 février est
# matché normalement (pas de double le 28).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_648 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique de sélection des MM-DD ------------------------------
    my $match = sub {
        my ($year, $mmdd) = @_;
        my $is_leap = ($year % 4 == 0 && ($year % 100 != 0 || $year % 400 == 0)) ? 1 : 0;
        my @m = ($mmdd);
        push @m, '02-29' if !$is_leap && $mmdd eq '02-28';
        return @m;
    };

    $assert->is(join(',', $match->(2024, '07-04')), '07-04', 'jour normal: un seul MM-DD');
    $assert->is(join(',', $match->(2025, '02-28')), '02-28,02-29',
        'année non bissextile, 28 fév: observe aussi 02-29');
    $assert->is(join(',', $match->(2024, '02-28')), '02-28',
        'année bissextile, 28 fév: pas de 02-29 (existe le 29)');
    $assert->is(join(',', $match->(2024, '02-29')), '02-29',
        'année bissextile, 29 fév: matché normalement');
    $assert->is(join(',', $match->(2100, '02-28')), '02-28,02-29',
        '2100 non bissextile (siècle non /400): observe 02-29');
    $assert->is(join(',', $match->(2000, '02-28')), '02-28',
        '2000 bissextile (/400): pas de 02-29 le 28');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_648(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    my ($body) = $src =~ /(sub check_birthdays_today \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/\$year % 4 == 0 && \(\$year % 100 != 0 \|\| \$year % 400 == 0\)/,
        'calcul année bissextile');
    $assert->like($code, qr/push \@match_mmdd, '02-29' if !\$is_leap && \$mmdd eq '02-28';/,
        'observance 02-29 le 28 fév non bissextile');
    $assert->like($code, qr/my \@binds = map \{ \(\$_, "%-\$_"\) \} \@match_mmdd;/,
        'binds construits pour chaque MM-DD observé');
    $assert->like($code, qr/'birthday = \? OR birthday LIKE \?'/,
        'match MM-DD et YYYY-MM-DD préservé');

    $assert->like($src, qr/mb433-B1/, 'tag mb433-B1');
};
