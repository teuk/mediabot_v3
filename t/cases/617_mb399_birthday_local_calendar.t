# t/cases/617_mb399_birthday_local_calendar.t
# =============================================================================
# mb399 — "!birthday next" compte en calendrier LOCAL, comme l'annonce auto.
#
# check_birthdays_today (Hailo, annonce automatique) travaille en localtime ;
# _birthday_days_ahead (base de "!birthday next") comptait en gmtime. Sur un
# serveur en Europe/Paris, entre minuit et 01:00/02:00 locales, un anniversaire
# du jour était donc affiché "in 1d" alors qu'il était "today" (et déjà annoncé
# sur le canal). mb399 : timelocal + arrondi au plus proche (un midi->midi
# local vaut 23 h le jour du passage à l'heure d'été — la troncature aurait
# rendu 0 jour).
#
# Le test force TZ=Europe/Paris, extrait la sub réelle et l'exécute.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Time::Local qw(timelocal);

sub _slurp_617 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _extract_sub_617 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\}\n)/s;
    return $body // '';
}

return sub {
    my ($assert) = @_;

    local $ENV{TZ} = 'Europe/Paris';
    eval { POSIX::tzset() };   # applique le TZ au process si dispo

    my $src = _slurp_617(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    my $valid = _extract_sub_617($src, '_birthday_valid_date');
    my $ahead = _extract_sub_617($src, '_birthday_days_ahead');
    $assert->ok($ahead ne '', '_birthday_days_ahead extraite');

    my $fn;
    {
        no strict; no warnings;
        $fn = eval "package T617; use Time::Local qw(timegm timelocal); $valid; $ahead; \\&T617::_birthday_days_ahead";
    }
    $assert->ok(ref($fn) eq 'CODE', 'compilée en isolation');

    # LE cas du bug : 03/07 00:30 locale (22:30 UTC la veille), anniv 03/07.
    my $t0030 = timelocal(0, 30, 0, 3, 6, 2026);
    $assert->is($fn->(7, 3, $t0030), 0, "00:30 locale, anniv du jour -> today (avant: 'in 1d')");
    $assert->is($fn->(7, 4, $t0030), 1, 'anniv de demain -> 1');
    $assert->is($fn->(7, 2, $t0030), 364, 'anniv d\'hier -> 364');

    # DST printemps : 28/03 midi -> 29/03 (jour de 23 h). Troncature aurait dit 0.
    my $spring = timelocal(0, 0, 12, 28, 2, 2026);
    $assert->is($fn->(3, 29, $spring), 1, 'veille du DST printemps -> 1 (arrondi, pas troncature)');

    # DST automne : 24/10 midi -> 25/10 (jour de 25 h).
    my $fall = timelocal(0, 0, 12, 24, 9, 2026);
    $assert->is($fn->(10, 25, $fall), 1, 'veille du DST automne -> 1');

    # 29 février : prochain = 2028.
    my $mid = timelocal(0, 0, 12, 3, 6, 2026);
    my $expected_feb29 = int((timelocal(0,0,12,29,1,2028) - timelocal(0,0,12,3,6,2026)) / 86400 + 0.5);
    $assert->is($fn->(2, 29, $mid), $expected_feb29, '29/02 -> prochaine année bissextile');

    # --- scan source -------------------------------------------------------
    $assert->like($ahead, qr/timelocal\(/,       'compte en calendrier local');
    $assert->unlike($ahead, qr/\bgmtime\(/,      'plus de gmtime dans le helper');
    $assert->like($ahead, qr/\+ 0\.5\)/,         'arrondi DST-safe');
    $assert->like($src, qr/use Time::Local qw\(timegm timelocal\);/, 'import timelocal');
    $assert->like($src, qr/mb399-B1/, 'tag mb399-B1');
};
