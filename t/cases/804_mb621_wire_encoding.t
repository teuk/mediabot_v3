# t/cases/804_mb621_wire_encoding.t
# =============================================================================
# mb621 — l'encodage de SORTIE, verifié comme sur le fil.
#
# INCIDENT (deux captures #boulets) : « humeur Ã©lectrique », puis TOUTE la
# ligne en mojibake apres ma correction mb620. Cause reelle, enfin comprise :
#   * mediabot.pl DECODE les messages entrants (ligne ~2089), donc $nick,
#     $target et les arguments sont des chaines de CARACTERES ;
#   * l'envoi (Helpers) encode UNIQUEMENT si la chaine est marquee utf8 ;
#   * un fichier sans « use utf8 » a des litteraux en OCTETS. Interpoler une
#     variable marquee dans un tel litteral fait basculer TOUTE la chaine :
#     les octets sont relus en latin-1 puis re-encodes -> double encodage.
# Le correctif n'est donc pas cosmetique : les litteraux des modules qui
# PARLENT doivent etre des caracteres (« use utf8 »).
#
#   [1] tout module qui emet des litteraux non-ASCII declare « use utf8 ».
#   [2] SIMULATION DU FIL : on rejoue la regle d'envoi reelle sur la sortie
#       de l'horoscope avec un pseudo DECODE (ce que fournit la production)
#       et on verifie que les octets emis sont de l'UTF-8 valide, avec les
#       bons accents et AUCUNE sequence de double encodage.
#   [3] la meme garantie pour un pseudo non decode (appels internes).
#   [4] les signes accentues font l'aller-retour (Bélier, Gémeaux).
#   [5] un signe tape avec accents depuis IRC (donc decode) est reconnu.
# =============================================================================

use strict;
use warnings;
use utf8;
use Encode qw(encode decode);
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package ConfW; sub new { bless {}, shift } sub get { undef }
}
{
    package LogW; sub new { bless {}, shift } sub log { 1 }
}
{
    package CtxW;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub bot { $_[0]{bot} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

# Regle d'envoi REELLE du bot : encode seulement si la chaine est marquee.
sub _wire { my ($s) = @_; return utf8::is_utf8($s) ? encode('UTF-8', $s) : $s }

return sub {
    my ($assert) = @_;

    require Mediabot::UserCommands;
    require Mediabot::External::Horoscope;
    require Mediabot::Helpers;

    # [1] les modules qui parlent declarent use utf8
    my @speaking = qw(UserCommands Helpers Partyline ChannelCommands DBCommands
                      Quotes Convert LoginCommands AdminCommands CommandAsync
                      External/URL External/YouTube External/Claude
                      External/News External/Horoscope);
    my @missing;
    for my $mod (@speaking) {
        my $path = "Mediabot/$mod.pm";
        next unless -f $path;
        my $src = do { open my $fh, '<:raw', $path or die $!; local $/; <$fh> };
        # litteraux non-ASCII hors commentaires
        my $body = $src; $body =~ s/^\s*#.*$//mg;
        my $has_literal = 0;
        while ($body =~ /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/g) {
            my $lit = defined $1 ? $1 : $2;
            $has_literal = 1, last if defined $lit && $lit =~ /[^\x00-\x7F]/;
        }
        push @missing, $mod if $has_literal && $src !~ /^use utf8/m;
    }
    $assert->is(join(',', @missing), '',
        'mb621-804: tout module qui emet du non-ASCII declare use utf8');

    # [2] SIMULATION DU FIL avec un pseudo DECODE (cas de production)
    my @out;
    no warnings 'redefine';
    local *Mediabot::UserCommands::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::chanset_enabled = sub { 1 };
    local *Mediabot::Helpers::channel_lang    = sub { 'fr' };
    local *Mediabot::External::Horoscope::daily_line = sub { undef };
    my $bot = bless { conf => ConfW->new, logger => LogW->new }, 'Mediabot';

    my $nick_decoded = decode('UTF-8', 'te[u]k');
    @out = ();
    Mediabot::UserCommands::mbHoroscope_ctx(
        CtxW->new(bot => $bot, nick => $nick_decoded, channel => '#boulets',
                  args => ['lion']));
    $assert->ok(scalar @out >= 4, 'mb621-804: l horoscope a repondu');

    my $wire = join "\n", map { _wire($_) } @out;
    $assert->ok($wire !~ /\xC3\x83|\xC3\x82/,
        'mb621-804: AUCUNE sequence de double encodage sur le fil');
    my $back = eval { decode('UTF-8', $wire, Encode::FB_CROAK()) };
    $assert->ok(defined $back, 'mb621-804: les octets emis sont de l UTF-8 valide');
    $assert->like($back, qr/humeur \w+/, 'mb621-804: la ligne d en-tete est lisible');
    $assert->like($back, qr/Côté projets/,
        'mb621-804: les accents du corps sortent justes');
    $assert->like($back, qr/♌ \x02Lion\x02/,
        'mb621-804: le glyphe du signe sort juste');
    # mb631: « â » SEUL n'est pas un symptome — c'est une lettre francaise
    # parfaitement legitime (« âmes », « bâtis », « tâche » sont dans les
    # pools de l'horoscope). Comme le tirage depend de la DATE, cette
    # alternative rendait la suite rouge certains jours et verte d'autres,
    # pour une sortie parfaitement correcte. Le vrai symptome du double
    # encodage est une SEQUENCE : « Ã » suivi d'un caractere de continuation,
    # ou « â€ » / « Â » colles a un signe de ponctuation.
    $assert->ok($back !~ /Ã[\x80-\xBF\xA0-\xFF]|â€|Â[\x80-\xBF\xA0-\xBF]/,
        'mb621-804: aucun mojibake visible (le symptome de la capture)');
    # ... et la garde attrape toujours du VRAI mojibake : sans quoi on aurait
    # remplace un faux positif par un test qui ne teste plus rien.
    my $real = Encode::decode('UTF-8', Encode::encode('UTF-8',
        Encode::decode('ISO-8859-1', Encode::encode('UTF-8', 'humeur électrique'))));
    $assert->ok($real =~ /Ã[\x80-\xBF\xA0-\xFF]|â€|Â[\x80-\xBF\xA0-\xBF]/,
        'mb621-804: la garde reconnait toujours un double encodage reel');
    $assert->ok('une tâche, des âmes, il bâtis' !~ /Ã[\x80-\xBF\xA0-\xFF]|â€|Â[\x80-\xBF\xA0-\xBF]/,
        'mb621-804: ... et laisse passer les accents circonflexes legitimes');

    # [3] meme garantie avec un pseudo NON decode (appels internes)
    @out = ();
    Mediabot::UserCommands::mbHoroscope_ctx(
        CtxW->new(bot => $bot, nick => 'te[u]k', channel => '#boulets', args => ['lion']));
    my $wire2 = join "\n", map { _wire($_) } @out;
    $assert->ok(defined eval { decode('UTF-8', $wire2, Encode::FB_CROAK()) },
        'mb621-804: idem quand le pseudo n est pas decode');
    $assert->ok($wire2 !~ /\xC3\x83/,
        'mb621-804: ... et toujours sans double encodage');

    # [4] aller-retour des signes accentues
    my $round = 0;
    for my $slug (Mediabot::External::Horoscope::all_slugs()) {
        my $row = Mediabot::UserCommands::_horoscope_sign_from_slug($slug) or next;
        $round++ if (Mediabot::UserCommands::_horoscope_slug_from_sign($row->[0]) // '') eq $slug;
    }
    $assert->is($round, 12,
        'mb621-804: les 12 signes font l aller-retour, accents compris');

    # [5] un signe accentue TAPE SUR IRC (donc decode) est reconnu
    my $norm = \&Mediabot::External::Horoscope::normalize_sign;
    my $ok_decoded = 0;
    for my $pair ([ 'bélier', 'aries' ], [ 'Gémeaux', 'gemini' ],
                  [ 'Cáncer', 'cancer' ], [ 'Escorpio', 'scorpio' ]) {
        my $typed = decode('UTF-8', encode('UTF-8', $pair->[0]));   # comme IRC
        $ok_decoded++ if ($norm->($typed) // '') eq $pair->[1];
    }
    $assert->is($ok_decoded, 4,
        'mb621-804: un signe accentue venu d IRC est reconnu (il ne l etait PAS)');
    my $ok_bytes = 0;
    for my $pair ([ 'bélier', 'aries' ], [ 'Gémeaux', 'gemini' ]) {
        $ok_bytes++ if ($norm->(encode('UTF-8', $pair->[0])) // '') eq $pair->[1];
    }
    $assert->is($ok_bytes, 2,
        'mb621-804: ... et la forme en octets marche toujours');
};
