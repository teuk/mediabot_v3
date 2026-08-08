package Mediabot::External::Horoscope;

# =============================================================================
# mb620-B1: prévision quotidienne RÉELLE par signe, depuis une API gratuite.
#
# Ce module ne fait que trois choses, et les fait complètement :
#   1. reconnaître un signe écrit par un humain (français, anglais, espagnol,
#      glyphe, abréviation, avec ou sans accent) ;
#   2. aller chercher la prévision du jour pour ce signe (API publique, sans
#      clé) ;
#   3. la rendre dans la langue du canal.
#
# Règle de conception : le bot ne doit JAMAIS afficher d'échec à l'utilisateur
# à cause de ce module. Chaque étape peut rendre undef, et l'appelant retombe
# alors sur l'horoscope local déterministe — qui, lui, ne dépend de rien.
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use JSON::PP ();
use Encode ();

# Fournisseurs essayes dans l'ordre. Le second est un miroir du premier ;
# une conf horoscope.API_URL remplace toute la liste.
our @PROVIDERS = (
    'https://freehoroscopeapi.com/api/v1/get-horoscope/daily?sign=%s',
    'https://horoscope-app-api.vercel.app/api/v1/get-horoscope/daily?sign=%s&day=TODAY',
);
our $API_URL     = $PROVIDERS[0];
our $TIMEOUT_S   = 6;
our $MAX_CHARS   = 380;

# Signe canonique (slug anglais, ce que veut l'API) -> glyphe + noms.
our @SIGNS = (
    [ 'aries',       "\x{2648}", 'Bélier',      'Aries',       'Aries'       ],
    [ 'taurus',      "\x{2649}", 'Taureau',     'Taurus',      'Tauro'       ],
    [ 'gemini',      "\x{264A}", 'Gémeaux',     'Gemini',      'Géminis'     ],
    [ 'cancer',      "\x{264B}", 'Cancer',      'Cancer',      'Cáncer'      ],
    [ 'leo',         "\x{264C}", 'Lion',        'Leo',         'Leo'         ],
    [ 'virgo',       "\x{264D}", 'Vierge',      'Virgo',       'Virgo'       ],
    [ 'libra',       "\x{264E}", 'Balance',     'Libra',       'Libra'       ],
    [ 'scorpio',     "\x{264F}", 'Scorpion',    'Scorpio',     'Escorpio'    ],
    [ 'sagittarius', "\x{2650}", 'Sagittaire',  'Sagittarius', 'Sagitario'   ],
    [ 'capricorn',   "\x{2651}", 'Capricorne',  'Capricorn',   'Capricornio' ],
    [ 'aquarius',    "\x{2652}", 'Verseau',     'Aquarius',    'Acuario'     ],
    [ 'pisces',      "\x{2653}", 'Poissons',    'Pisces',      'Piscis'      ],
);

# Repli ASCII : « bélier », « BELIER », « Bélier » et « belier » sont le même
# mot. Même esprit que le repliement des noms de commandes (mb614). L'entree
# peut etre une chaine DECODEE ou des octets UTF-8, independamment de use utf8
# qui ne concerne que les litteraux du source.
sub _fold {
    my ($text) = @_;
    return '' unless defined $text && !ref $text;

    # mb621-B1: l'entree peut arriver DECODEE (mediabot.pl decode les messages
    # entrants : « belier » tape sur IRC est une chaine de CARACTERES) ou en
    # octets bruts (tests, appels internes). On ramene les deux au meme monde
    # AVANT de replier — sans cela, « m horoscope belier » accentue n'etait
    # tout simplement pas reconnu en production.
    my $t = $text;
    if (!utf8::is_utf8($t) && $t =~ /[^\x00-\x7F]/) {
        my $decoded = eval { Encode::decode('UTF-8', $t, Encode::FB_CROAK()) };
        $t = $decoded if defined $decoded;
    }
    $t = lc $t;

    my %map = (
        "\x{e0}"=>'a', "\x{e1}"=>'a', "\x{e2}"=>'a', "\x{e3}"=>'a', "\x{e4}"=>'a',
        "\x{e5}"=>'a', "\x{e7}"=>'c',
        "\x{e8}"=>'e', "\x{e9}"=>'e', "\x{ea}"=>'e', "\x{eb}"=>'e',
        "\x{ec}"=>'i', "\x{ed}"=>'i', "\x{ee}"=>'i', "\x{ef}"=>'i',
        "\x{f1}"=>'n',
        "\x{f2}"=>'o', "\x{f3}"=>'o', "\x{f4}"=>'o', "\x{f5}"=>'o', "\x{f6}"=>'o',
        "\x{f9}"=>'u', "\x{fa}"=>'u', "\x{fb}"=>'u', "\x{fc}"=>'u',
        "\x{fd}"=>'y', "\x{ff}"=>'y',
    );
    # Delimiteurs {} : avec s/.../.../ la barre oblique du defined-or doit etre
    # echappee, et une echappement de trop rend la substitution SILENCIEUSEMENT
    # destructrice (le caractere disparait au lieu d'etre replie).
    $t =~ s{([^\x00-\x7F])}{ exists $map{$1} ? $map{$1} : $1 }ge;
    $t =~ s/[^a-z0-9]//g;
    return $t;
}

# Table de reconnaissance, construite une fois : tous les noms de @SIGNS
# replies, plus les glyphes et quelques abreviations d'usage.
our %ALIAS;
{
    for my $row (@SIGNS) {
        my ($slug, $glyph, @names) = @$row;
        $ALIAS{$glyph} = $slug;   # glyphe (caractere)
        $ALIAS{ _fold($_) } = $slug for ($slug, @names);
    }
    my %extra = (
        belier => 'aries', ram => 'aries', bull => 'taurus',
        gemeaux => 'gemini', twins => 'gemini', crab => 'cancer',
        lion => 'leo', vierge => 'virgo', virgin => 'virgo',
        balance => 'libra', scales => 'libra', scorpion => 'scorpio',
        sagittaire => 'sagittarius', archer => 'sagittarius',
        capricorne => 'capricorn', goat => 'capricorn',
        verseau => 'aquarius', poissons => 'pisces', fish => 'pisces',
        cap => 'capricorn', sag => 'sagittarius', scorp => 'scorpio',
        aqua => 'aquarius', gem => 'gemini', pisce => 'pisces',
    );
    $ALIAS{$_} = $extra{$_} for keys %extra;
}

# Rend le slug canonique, ou undef si le texte n'est pas un signe. C'est ce
# « undef » qui permet a la commande de savoir si l'argument etait un signe
# ou un pseudo — sans jamais se tromper sur un pseudo nomme « Leo ».
sub normalize_sign {
    my ($text) = @_;
    return undef unless defined $text && !ref $text && length $text;
    return $ALIAS{$text} if exists $ALIAS{$text};   # glyphe brut
    my $key = _fold($text);
    return undef unless length $key;
    return $ALIAS{$key};
}

# Nom affichable + glyphe, dans la langue demandee.
sub sign_label {
    my ($slug, $lang) = @_;
    return () unless defined $slug;
    for my $row (@SIGNS) {
        next unless $row->[0] eq $slug;
        my $idx = ($lang || '') eq 'fr' ? 2 : (($lang || '') eq 'es' ? 4 : 3);
        return ($row->[$idx], $row->[1]);
    }
    return ();
}

sub all_slugs { return map { $_->[0] } @SIGNS }

# --- appel de l'API ----------------------------------------------------------

# Rend le texte anglais du jour, ou undef. Ne journalise qu'en cas d'echec :
# un horoscope n'est pas une operation critique, il ne doit pas bavarder.
sub fetch_daily {
    my ($self, $slug) = @_;
    return undef unless defined $slug && $slug =~ /\A[a-z]+\z/;

    my @urls = @PROVIDERS;
    my $conf_url = eval { $self->{conf}->get('horoscope.API_URL') };
    @urls = ($conf_url) if defined $conf_url && !ref $conf_url && $conf_url =~ /%s/;

    my $timeout = eval { $self->{conf}->get('horoscope.TIMEOUT') };
    $timeout = $TIMEOUT_S unless defined $timeout && $timeout =~ /\A\d+\z/ && $timeout > 0;

    for my $tpl (@urls) {
        my $text = _fetch_one($self, $tpl, $slug, $timeout);
        return $text if defined $text;
    }
    return undef;
}

sub _fetch_one {
    my ($self, $tpl, $slug, $timeout) = @_;
    my $url = sprintf($tpl, $slug);

    my $res = eval {
        my $http = Mediabot::External::_make_http(timeout => $timeout,
                                                  max_size => 256 * 1024);
        $http->get($url);
    };
    unless (ref $res eq 'HASH' && $res->{success}) {
        eval { $self->{logger}->log(2, 'horoscope: API unavailable ('
            . ((ref $res eq 'HASH' ? $res->{status} : undef) // 'no response') . ')') };
        return undef;
    }
    my $data = eval { JSON::PP->new->utf8->decode($res->{content} // '{}') };
    return undef unless ref $data eq 'HASH';

    # Deux formes rencontrees selon l'hebergeur : {data}{horoscope} ou
    # {data}{horoscope_data}. On accepte les deux plutot que de casser le jour
    # ou l'API change de robe.
    my $node = ref $data->{data} eq 'HASH' ? $data->{data} : $data;
    my $text = $node->{horoscope} // $node->{horoscope_data} // $node->{description};
    return undef unless defined $text && !ref $text && $text =~ /\S/;

    # GARDE-FOU CENTRAL : la reponse doit concerner le signe DEMANDE. Un
    # fournisseur qui ignore son parametre (ou un cache mal regle en amont)
    # servirait sinon le meme signe a tout le monde — le genre de detail qui
    # fait rire un canal entier aux depens du bot. En cas de doute, on ne
    # montre RIEN et l'horoscope local prend le relais.
    my $got = $node->{sign};
    if (defined $got && !ref $got) {
        my $got_slug = normalize_sign($got);
        unless (defined $got_slug && $got_slug eq $slug) {
            eval { $self->{logger}->log(2,
                "horoscope: provider answered '$got' for '$slug' - ignored") };
            return undef;
        }
    }

    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    if (length($text) > $MAX_CHARS) {
        $text = substr($text, 0, $MAX_CHARS);
        $text =~ s/\s+\S*\z//;
        $text .= '...';
    }
    return $text;
}

# --- mise dans la langue du canal --------------------------------------------

# L'API ne parle qu'anglais. Sur un canal francais ou espagnol, on demande a
# Claude une traduction courte. Si Claude n'est pas la, ou echoue, on rend
# undef : l'appelant preferera son texte local dans la bonne langue plutot
# qu'une phrase anglaise au milieu d'un horoscope francais.
sub localize {
    my ($self, $text, $lang, $nick) = @_;
    return undef unless defined $text && length $text;
    return $text if ($lang || 'en') eq 'en';
    return undef unless Mediabot::External::Claude->can('claudeAI');

    my $name = Mediabot::External::Claude->can('ai_lang_name')
        ? Mediabot::External::Claude::ai_lang_name($lang) : 'French';
    my $prompt = "Translate this daily horoscope into $name. Keep it under "
        . "$MAX_CHARS characters, one single line, same tone, no preamble, "
        . "no quotes, no Markdown:\n\n$text";

    my $out = '';
    my $emit = sub { $out .= (length $out ? ' ' : '') . ($_[0] // '') };
    my $ok = eval {
        Mediabot::External::Claude::claudeAI($self, $prompt, $nick, undef, $emit, $prompt);
        1;
    };
    $out =~ s/\s+/ /g;
    $out =~ s/^\s+|\s+$//g;
    return undef unless $ok && length $out;
    return length($out) > $MAX_CHARS ? substr($out, 0, $MAX_CHARS) : $out;
}

# Prevision prete a afficher, ou undef. Point d'entree unique de la commande.
sub daily_line {
    my ($self, $slug, $lang, $nick) = @_;
    my $text = fetch_daily($self, $slug) or return undef;
    return $text if ($lang || 'en') eq 'en';
    return localize($self, $text, $lang, $nick);
}

1;
