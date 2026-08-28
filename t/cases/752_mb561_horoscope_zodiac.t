# t/cases/752_mb561_horoscope_zodiac.t
# =============================================================================
# mb561 — refonte de l'horoscope :
#   [1] _horoscope_zodiac_sign : bornes standard des 12 signes (les deux
#       extrémités de chaque intervalle), éléments corrects, dates invalides
#       -> liste vide ;
#   [2] le ctx cherche le signe dans USER.birthday (même clé que la commande
#       birthday : USER.nickname = cible), comprend les formats DB MM-DD /
#       YYYY-MM-DD et les anciens dd/mm[/YYYY], en best-effort ;
#       lookup présent, DEUX gabarits d'affichage (avec signe / sans signe),
#       jamais de signe inventé sans birthday ;
#   [3] contenu générique : plus AUCUNE référence interne (personnes, canaux,
#       fichiers du projet, outils nominatifs) dans mbHoroscope_ctx ;
#   [4] le contrat mb444 (LCG local, zéro srand/rand global) reste couvert
#       par le test 659 — ici on vérifie seulement que le LCG est toujours
#       la source des tirages.
# =============================================================================

use strict;
use warnings;
use utf8;
use Encode ();

# Le module n'a pas « use utf8 » (ses littéraux accentués sont des octets),
# ce test si (les siens sont des caractères) : on normalise tout en octets.
sub _norm_752 {
    my ($s) = @_;
    return $s unless defined $s;
    return utf8::is_utf8($s) ? Encode::encode('UTF-8', $s) : $s;
}
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_752 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $ok_load = eval { require Mediabot::UserCommands; 1 };
    $assert->ok($ok_load, 'Mediabot::UserCommands chargeable');

    # ------------------------------------------------------------------
    # [1] Bornes des 12 signes — début et fin de chaque intervalle
    # ------------------------------------------------------------------
    my @cases = (
        # jour, mois, nom attendu, element attendu
        [ 21,  3, 'Bélier',     'feu'   ], [ 19,  4, 'Bélier',     'feu'   ],
        [ 20,  4, 'Taureau',    'terre' ], [ 20,  5, 'Taureau',    'terre' ],
        [ 21,  5, 'Gémeaux',    'air'   ], [ 20,  6, 'Gémeaux',    'air'   ],
        [ 21,  6, 'Cancer',     'eau'   ], [ 22,  7, 'Cancer',     'eau'   ],
        [ 23,  7, 'Lion',       'feu'   ], [ 22,  8, 'Lion',       'feu'   ],
        [ 23,  8, 'Vierge',     'terre' ], [ 22,  9, 'Vierge',     'terre' ],
        [ 23,  9, 'Balance',    'air'   ], [ 22, 10, 'Balance',    'air'   ],
        [ 23, 10, 'Scorpion',   'eau'   ], [ 21, 11, 'Scorpion',   'eau'   ],
        [ 22, 11, 'Sagittaire', 'feu'   ], [ 21, 12, 'Sagittaire', 'feu'   ],
        [ 22, 12, 'Capricorne', 'terre' ], [ 19,  1, 'Capricorne', 'terre' ],
        [ 20,  1, 'Verseau',    'air'   ], [ 18,  2, 'Verseau',    'air'   ],
        [ 19,  2, 'Poissons',   'eau'   ], [ 20,  3, 'Poissons',   'eau'   ],
        [ 29,  2, 'Poissons',   'eau'   ],   # bissextile
    );
    my $all_ok = 1;
    for my $c (@cases) {
        my ($d, $m, $want, $want_el) = @$c;
        my ($name, $glyph, $el) = Mediabot::UserCommands::_horoscope_zodiac_sign($d, $m);
        my ($n_name, $n_want) = (_norm_752($name), _norm_752($want));
        next if defined($n_name) && $n_name eq $n_want && defined($el) && $el eq $want_el
            && defined($glyph) && length($glyph);
        $all_ok = 0;
        $assert->is(($n_name // 'undef') . '/' . ($el // 'undef'), _norm_752("$want/$want_el"),
            "signe $d/$m");
    }
    $assert->ok($all_ok, 'les 25 bornes du zodiaque sont exactes (elements inclus)');

    $assert->ok(scalar(Mediabot::UserCommands::_horoscope_zodiac_sign(32, 1)) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_sign(1, 13)) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_sign(31, 2)) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_sign(31, 4)) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_sign(undef, 5)) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_sign('ab', 5)) == 0,
        'dates invalides ou impossibles -> liste vide');

    my @birthday_cases = (
        [ '07-24',      'Lion' ],
        [ '2026-07-24', 'Lion' ],
        [ '24/07',      'Lion' ],
        [ '24/07/2026', 'Lion' ],
        [ '02-29',      'Poissons' ],
    );
    my $birthday_ok = 1;
    for my $case (@birthday_cases) {
        my ($raw, $want) = @$case;
        my ($name) = Mediabot::UserCommands::_horoscope_zodiac_from_birthday($raw);
        $birthday_ok = 0 unless defined($name) && _norm_752($name) eq _norm_752($want);
    }
    $assert->ok($birthday_ok,
        'formats USER.birthday canoniques et legacy -> signe exact');
    $assert->ok(
        scalar(Mediabot::UserCommands::_horoscope_zodiac_from_birthday('02-31')) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_from_birthday('1900-02-29')) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_from_birthday('31/04')) == 0
        && scalar(Mediabot::UserCommands::_horoscope_zodiac_from_birthday('n/a')) == 0,
        'birthday stocké invalide -> aucun signe inventé');

    # ------------------------------------------------------------------
    # [2] + [3] + [4] Gardes statiques sur mbHoroscope_ctx
    # ------------------------------------------------------------------
    my $src = _slurp_752(File::Spec->catfile('Mediabot', 'UserCommands.pm'));
    my ($ctx) = $src =~ /(sub mbHoroscope_ctx \{.*?\n\})/s;
    $assert->ok(defined $ctx && length $ctx, 'source de mbHoroscope_ctx isolee');

    $assert->like($ctx, qr/SELECT birthday FROM USER WHERE nickname = \?/,
        'lookup birthday: meme cle que la commande birthday');
    $assert->like($ctx, qr/_horoscope_zodiac_from_birthday\(\$bday\)/,
        'le ctx délègue le format DB et le signe à la sub testée');
    $assert->like($ctx, qr/if \(defined \$sign_name\) \{/,
        'gabarit AVEC signe conditionne a un birthday valide');
    $assert->like($ctx, qr/Horoscope du \$date_key pour \$target/,
        'gabarit SANS signe present (horoscope jamais refuse)');
    $assert->like($ctx, qr/signe complice/,
        'signe complice uniquement dans le gabarit avec signe');

    # Plus aucune reference interne (mb561)
    for my $forbidden ('Gwen', '#test', 'BUGFIX_mb83', 'sosreport',
                       '!active', 'git pull', 'commit avant') {
        $assert->unlike($ctx, qr/\Q$forbidden\E/i,
            "aucune reference interne : $forbidden");
    }

    # Le LCG local reste la source des tirages (contrat 659 en detail)
    $assert->like($ctx, qr/1103515245/, 'LCG local toujours en place');

    # Les deux gabarits partagent le meme socle (conseil + chance)
    my $conseil = () = $ctx =~ /Conseil : %s\. Méfiance : %s\./g;
    $assert->ok($conseil == 2, 'ligne conseil presente dans les DEUX gabarits');
};
