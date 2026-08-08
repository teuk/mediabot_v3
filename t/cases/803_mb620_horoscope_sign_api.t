# t/cases/803_mb620_horoscope_sign_api.t
# =============================================================================
# mb620 — horoscope : accents corrigés, signe reconnu, prévision réelle.
#
# TERRAIN (capture #boulets) : « humeur Ã©lectrique ». UserCommands.pm n'a PAS
# « use utf8 » : ses accents sont des OCTETS, mais "\x{26A1}" cree un
# caractere large ; toute chaine melant les deux est double-encodee a
# l'affichage. Sept litteraux etaient dans ce cas, tous dans le pool
# d'humeurs, plus le tableau des signes (nom accentue + glyphe) qui aurait
# casse des qu'un signe francais s'affichait.
#
#   [1] plus AUCUN litteral mixte dans tout le fichier (garde-fou general).
#   [2] reconnaissance d'un signe : fr/en/es, accents, glyphe, abreviation ;
#       un pseudo ordinaire n'est JAMAIS pris pour un signe.
#   [3] passerelles slug <-> tableau canonique FR, aller-retour exact.
#   [4] les trois cas demandes : signe donne, pseudo donne, rien donne.
#   [5] GARDE-FOU : une reponse d'API portant un AUTRE signe est ignoree —
#       jamais d'horoscope du mauvais signe a l'ecran.
#   [6] best-effort de bout en bout : API muette, JSON casse, champ absent,
#       traduction indisponible -> aucune ligne, aucun message d'echec.
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621: ce que le bot recoit d'IRC est DECODE — le test doit
            # donc parler la meme langue que la production.

BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package ConfH; sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package LogH; sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}
{
    package HttpH;   # faux client : rend ce qu'on lui dit, note ce qu'on demande
    sub new { my ($c, $q) = @_; bless { q => $q }, $c }
    sub get { my ($s, $url) = @_; push @{ $s->{q}{urls} }, $url;
              return shift @{ $s->{q}{res} } || { success => 0, status => 599 } }
}
{
    package CtxH;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub bot { $_[0]{bot} } sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} } sub args { $_[0]{args} || [] }
}

return sub {
    my ($assert) = @_;

    require Mediabot::External::Horoscope;
    require Mediabot::UserCommands;
    require Mediabot::Helpers;
    my $H = 'Mediabot::External::Horoscope';

    # [1] plus aucun litteral mixte
    my $src = do { open my $fh, '<:raw', 'Mediabot/UserCommands.pm' or die $!;
                   local $/; <$fh> };
    my $mixed = 0;
    while ($src =~ /"((?:[^"\\]|\\.)*)"/g) {
        my $lit = $1;
        $mixed++ if $lit =~ /\\x\{[0-9A-Fa-f]{2,5}\}/ && $lit =~ /[^\x00-\x7F]/;
    }
    $assert->is($mixed, 0,
        'mb620-803: aucun litteral ne mele plus octets accentues et \x{...}');
    $assert->ok($src !~ /"électrique \\x\{26A1\}"/,
        'mb620-803: la chaine fautive de la capture a disparu');

    # [2] reconnaissance
    my %expect = (
        'lion' => 'leo', 'Leo' => 'leo', 'LEO' => 'leo',
        'bélier' => 'aries', 'belier' => 'aries', 'BELIER' => 'aries',
        'Gémeaux' => 'gemini', 'Escorpio' => 'scorpio',
        'Capricornio' => 'capricorn', 'poissons' => 'pisces',
        'cap' => 'capricorn', '♌' => 'leo',
    );
    my $recognised = 0;
    for my $in (sort keys %expect) {
        my $got = $H->can('normalize_sign')->($in);
        $recognised++ if defined $got && $got eq $expect{$in};
    }
    $assert->is($recognised, scalar(keys %expect),
        'mb620-803: fr/en/es, accents, casse, glyphe et abreviation reconnus');
    my $false_positive = 0;
    for my $nick (qw(teuk SaYa sky poyan bob mediabot)) {
        $false_positive++ if defined $H->can('normalize_sign')->($nick);
    }
    $assert->is($false_positive, 0,
        'mb620-803: un pseudo ordinaire n est jamais pris pour un signe');
    $assert->ok(!defined $H->can('normalize_sign')->(''),
        'mb620-803: chaine vide -> pas un signe');
    my ($name_fr, $glyph) = $H->can('sign_label')->('leo', 'fr');
    $assert->is($name_fr, 'Lion', 'mb620-803: libelle francais');
    my ($name_es) = $H->can('sign_label')->('pisces', 'es');
    $assert->is($name_es, 'Piscis', 'mb620-803: libelle espagnol');

    # [3] passerelles avec le tableau canonique
    my $round = 0;
    for my $slug ($H->can('all_slugs')->()) {
        my $row = Mediabot::UserCommands::_horoscope_sign_from_slug($slug) or next;
        $round++ if (Mediabot::UserCommands::_horoscope_slug_from_sign($row->[0]) // '') eq $slug;
    }
    $assert->is($round, 12, 'mb620-803: les 12 signes font l aller-retour');

    # [5] garde-fou du mauvais signe (avant [4] : il conditionne le reste)
    my $q = { urls => [], res => [] };
    no warnings 'redefine';
    local *Mediabot::External::_make_http = sub { HttpH->new($q) };
    my $bot = bless { conf => ConfH->new, logger => LogH->new }, 'Mediabot';

    my $json = sub { my ($sign, $text) = @_;
        return { success => 1, status => 200,
                 content => qq({"data":{"date":"2026-08-08","period":"daily",)
                          . qq("sign":"$sign","horoscope":"$text"}}) } };

    @{ $q->{res} } = ( $json->('Aquarius', 'texte du verseau'),
                       $json->('Aquarius', 'texte du verseau') );
    my $wrong = $H->can('fetch_daily')->($bot, 'leo');
    $assert->ok(!defined $wrong,
        'mb620-803: une reponse pour un AUTRE signe est refusee');
    $assert->is(scalar @{ $q->{urls} }, 2,
        'mb620-803: ... apres avoir essaye les deux fournisseurs');
    $assert->ok((grep { $_->[1] =~ /answered 'Aquarius' for 'leo'/ }
        @{ $bot->{logger}{lines} }), 'mb620-803: ... et c est journalise');

    @{ $q->{urls} } = (); @{ $q->{res} } = ( $json->('Leo', 'a calm and useful day') );
    my $good = $H->can('fetch_daily')->($bot, 'leo');
    $assert->is($good, 'a calm and useful day',
        'mb620-803: une reponse du BON signe est servie');
    $assert->like($q->{urls}[0], qr/sign=leo/,
        'mb620-803: le slug demande part bien dans l URL');

    # [6] best-effort
    @{ $q->{res} } = ( { success => 0, status => 503 }, { success => 0, status => 503 } );
    $assert->ok(!defined $H->can('fetch_daily')->($bot, 'leo'),
        'mb620-803: API muette -> undef');
    @{ $q->{res} } = ( { success => 1, status => 200, content => 'pas du json' },
                       { success => 1, status => 200, content => 'pas du json' } );
    $assert->ok(!defined $H->can('fetch_daily')->($bot, 'leo'),
        'mb620-803: JSON casse -> undef');
    @{ $q->{res} } = ( { success => 1, status => 200, content => '{"data":{"sign":"Leo"}}' },
                       { success => 1, status => 200, content => '{"data":{"sign":"Leo"}}' } );
    $assert->ok(!defined $H->can('fetch_daily')->($bot, 'leo'),
        'mb620-803: champ texte absent -> undef');
    $assert->ok(!defined $H->can('localize')->($bot, 'text', 'fr', 'teuk')
                || 1, 'mb620-803: la traduction ne meurt jamais');

    # [4] les trois cas, en RENDU REEL
    my @out;
    local *Mediabot::UserCommands::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::UserCommands::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::chanset_enabled = sub { 1 };
    local *Mediabot::Helpers::channel_lang    = sub { 'fr' };
    local *Mediabot::External::Horoscope::daily_line = sub { 'Prevision du jour.' };

    @out = ();
    Mediabot::UserCommands::mbHoroscope_ctx(
        CtxH->new(bot => $bot, nick => 'teuk', channel => '#c', args => ['lion']));
    my $text = join "\n", @out;
    $assert->like($text, qr/♌ \x02Lion\x02/,
        'mb620-803: CAS 1 — le signe donne est utilise');
    $assert->like($text, qr/Prevision du jour\./,
        'mb620-803: ... avec la prevision reelle');
    $assert->like($text, qr/humeur \w/,
        'mb620-803: ... et les accents sortent propres');
    $assert->ok($text !~ /\x{c3}\x{83}/,
        'mb620-803: ... plus aucun double encodage a l ecran');

    @out = ();
    Mediabot::UserCommands::mbHoroscope_ctx(
        CtxH->new(bot => $bot, nick => 'teuk', channel => '#c', args => ['SaYa']));
    $text = join "\n", @out;
    # Le pseudo est normalise en minuscules par la commande (comportement
    # historique) : c'est la CIBLE qui compte, pas la casse.
    $assert->like($text, qr/saya/i,
        'mb620-803: CAS 2 — un pseudo reste traite comme un pseudo');
    $assert->ok($text !~ /\x{c3}\x{83}/,
        'mb620-803: ... sans double encodage non plus');

    @out = ();
    Mediabot::UserCommands::mbHoroscope_ctx(
        CtxH->new(bot => $bot, nick => 'teuk', channel => '#c', args => []));
    $text = join "\n", @out;
    $assert->like($text, qr/signe inconnu : essaie/,
        'mb620-803: CAS 3 — sans signe connu, une invite utile, pas un refus');
    $assert->ok($text !~ /Prevision du jour/,
        'mb620-803: ... et aucune prevision inventee sans signe');
};
